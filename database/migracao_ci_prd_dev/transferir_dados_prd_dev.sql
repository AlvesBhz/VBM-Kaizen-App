/* =====================================================================
   TRANSFERIR DADOS DO SCHEMA CI: BDIBPBMSA_PRD -> BDIBPBMSA_DEV
   (executar conectado ao BDIBPBMSA_DEV — na PRD só LÊ)
   ---------------------------------------------------------------------
   Copia todas as linhas de cada tabela do schema CI que existe no DEV
   (criado pelo criar_estrutura_ci_dev.sql). Tabelas que só existem na
   PRD são listadas no relatório e não são copiadas.

   Etapas
     1. Travas: não roda na PRD; a estrutura de cada tabela no DEV tem de
        ser igual à da PRD (colunas, tipos, tamanhos, collation) — se não
        for, aborta listando as diferenças, sem alterar nada.
     2. Leitura: cada tabela da PRD é lida (Elastic Query) para uma área
        temporária no DEV (schema TRF_STG), com contagem e soma de
        verificação calculadas na própria PRD no mesmo momento.
     3. Gravação no DEV numa ÚNICA transação (tudo ou nada):
        - FKs/CHECKs e triggers do CI desligados só durante a cópia — os
          triggers de log não geram linhas novas e a ordem entre tabelas
          não importa (há ciclo MDM <-> TIPO_USUARIO);
        - cópia com IDENTITY_INSERT (mantém os IDs);
        - contagem e soma de verificação DEV x leitura da PRD;
        - identity no mesmo ponto da PRD;
        - FKs/CHECKs religados no MESMO estado de antes: os confiáveis
          voltam WITH CHECK (revalida toda a integridade referencial);
        - triggers religados como estavam.
        Qualquer erro: ROLLBACK — o DEV fica exatamente como estava.
     4. Sequences avançadas até o próximo valor da PRD (o log continua
        numerando depois do último ID copiado).
     5. Limpeza: área temporária, tabelas externas, fonte externa,
        credencial (e a master key, se foi criada aqui) são removidas
        mesmo em caso de erro.

   Leitura da PRD: autenticação SQL (exigência do Elastic Query). Use o
   usuário só-leitura do 00a_prd_usuario_leitura.sql e remova-o depois
   com o 06a. Não grave a senha neste arquivo no repositório.

   Se o DEV já tiver dados no CI, aborta — a não ser que
   @SUBSTITUIR_DADOS_DEV = 1 (apaga os dados do CI no DEV dentro da mesma
   transação e copia de novo).

   Rode com a aplicação do DEV parada. Na PRD, prefira um horário sem
   uso: se a PRD mudar entre a leitura de uma tabela e a de outra, a
   revalidação das FKs acusa e nada é gravado; basta repetir.
   ===================================================================== */

SET NOCOUNT ON;
SET XACT_ABORT ON;
SET ANSI_WARNINGS ON;

DECLARE @MODO                  VARCHAR(10)   = 'AZURE';   -- 'AZURE' | 'LOCAL' (origem na mesma instância)
DECLARE @SERVIDOR_ORIGEM       NVARCHAR(256) = N'rdb-ibp-bmsa-prd.database.windows.net';
DECLARE @BANCO_ORIGEM          SYSNAME       = N'BDIBPBMSA_PRD';
DECLARE @LOGIN_ORIGEM          NVARCHAR(128) = N'<usuario de leitura criado no 00a>';
DECLARE @SENHA_ORIGEM          NVARCHAR(256) = N'<senha do usuario de leitura>';
DECLARE @SENHA_MASTER_KEY      NVARCHAR(256) = N'<senha forte para a master key do DEV>';  -- só se o DEV ainda não tiver master key
DECLARE @SUBSTITUIR_DADOS_DEV  BIT           = 0;         -- 1 = apaga os dados do CI no DEV e copia de novo
-- Tabelas do DEV que ficam de fora (não são comparadas, apagadas nem copiadas)
DECLARE @EXCLUIR TABLE (TABELA SYSNAME PRIMARY KEY);
INSERT @EXCLUIR VALUES (N'KZN_MDM_TERCEIROS_USUARIO');   -- ID_USUARIO é IDENTITY na PRD e não no DEV

/* ── 1. Travas ──────────────────────────────────────────────────────── */
IF @MODO NOT IN ('AZURE', 'LOCAL')
BEGIN
    RAISERROR('Abortado: @MODO deve ser AZURE ou LOCAL.', 16, 1);
    RETURN;
END
IF DB_NAME() IN (N'BDIBPBMSA_PRD', @BANCO_ORIGEM)
BEGIN
    RAISERROR('Abortado: conecte no BDIBPBMSA_DEV. Este script grava no banco em que é executado.', 16, 1);
    RETURN;
END
IF @MODO = 'AZURE' AND (@LOGIN_ORIGEM LIKE N'<%' OR @SENHA_ORIGEM LIKE N'<%')
BEGIN
    RAISERROR('Abortado: preencha @LOGIN_ORIGEM e @SENHA_ORIGEM.', 16, 1);
    RETURN;
END
IF @MODO = 'LOCAL' AND DB_ID(@BANCO_ORIGEM) IS NULL
BEGIN
    RAISERROR('Abortado: modo LOCAL e o banco de origem %s não existe nesta instância.', 16, 1, @BANCO_ORIGEM);
    RETURN;
END
IF @MODO = 'AZURE' AND NOT EXISTS (SELECT 1 FROM sys.symmetric_keys WHERE name = N'##MS_DatabaseMasterKey##')
   AND @SENHA_MASTER_KEY LIKE N'<%'
BEGIN
    RAISERROR('Abortado: o DEV não tem master key. Preencha @SENHA_MASTER_KEY.', 16, 1);
    RETURN;
END
IF EXISTS (SELECT 1 FROM sys.schemas WHERE name IN (N'TRF_EXT', N'TRF_STG'))
BEGIN
    RAISERROR('Abortado: os schemas TRF_EXT/TRF_STG já existem no DEV (execução anterior interrompida?). Remova-os e rode de novo.', 16, 1);
    RETURN;
END

DECLARE @sql NVARCHAR(MAX), @q NVARCHAR(MAX), @tab SYSNAME, @erro NVARCHAR(4000), @passo NVARCHAR(400),
        @criouMasterKey BIT = 0, @ligou BIT = 0, @n BIGINT, @proc NVARCHAR(400) = QUOTENAME(@BANCO_ORIGEM) + N'.sys.sp_executesql';

/* Catálogo do DEV (tabelas de trabalho: nenhuma comparação direta com
   sys.* — no Azure a collation do catálogo pode diferir da do banco). */
DECLARE @DEV_COL TABLE (TABELA SYSNAME, ORDEM INT, COLUNA SYSNAME, TIPO SYSNAME, TAM INT, PREC INT, ESC INT,
                        COLL SYSNAME NULL, CALC BIT, IDENT BIT);
INSERT @DEV_COL
SELECT t.name, c.column_id, c.name, TYPE_NAME(c.user_type_id), c.max_length, c.precision, c.scale,
       c.collation_name, c.is_computed, c.is_identity
FROM sys.tables t JOIN sys.columns c ON c.object_id = t.object_id
WHERE t.schema_id = SCHEMA_ID(N'CI');
DELETE d FROM @DEV_COL d WHERE EXISTS (SELECT 1 FROM @EXCLUIR e WHERE e.TABELA = d.TABELA);

IF NOT EXISTS (SELECT 1 FROM @DEV_COL)
BEGIN
    RAISERROR('Abortado: não há tabelas no schema CI do DEV. Rode antes o criar_estrutura_ci_dev.sql.', 16, 1);
    RETURN;
END

DECLARE @PRD_COL TABLE (TABELA SYSNAME, COLUNA SYSNAME, TIPO SYSNAME, TAM INT, PREC INT, ESC INT, COLL SYSNAME NULL,
                        CALC BIT, NULO BIT, SHARD NVARCHAR(500));
DECLARE @PRD_IDENT TABLE (TABELA SYSNAME, ULTIMO NVARCHAR(40) NULL, INCREMENTO NVARCHAR(40), SHARD NVARCHAR(500));
DECLARE @PRD_SEQ TABLE (NOME SYSNAME, PROXIMO NVARCHAR(40), INCREMENTO NVARCHAR(40), SHARD NVARCHAR(500));
DECLARE @PRD_CONF TABLE (TABELA SYSNAME, QTD BIGINT, SOMA INT NULL, SHARD NVARCHAR(500));
DECLARE @RESULTADO TABLE (TABELA SYSNAME, LINHAS_PRD BIGINT NULL, SOMA_PRD INT NULL, LINHAS_LIDAS BIGINT NULL,
                          SOMA_LIDA INT NULL, LINHAS_DEV BIGINT NULL, SOMA_DEV INT NULL);
DECLARE @DIF TABLE (TABELA SYSNAME, COLUNA SYSNAME NULL, PRD NVARCHAR(400) NULL, DEV NVARCHAR(400) NULL);
DECLARE @AVISO TABLE (TABELA SYSNAME, COLUNA SYSNAME, PRD SYSNAME NULL, DEV SYSNAME NULL);
DECLARE @TRG TABLE (NOME SYSNAME, TABELA SYSNAME, DESABILITADO BIT);
DECLARE @CON TABLE (TABELA SYSNAME, NOME SYSNAME, DESABILITADA BIT, NAO_CONFIAVEL BIT);
DECLARE @SEQ_FIM TABLE (NOME SYSNAME, PROXIMO_PRD NVARCHAR(40), PROXIMO_DEV NVARCHAR(40));

BEGIN TRY
    /* ── Ligação com a PRD ──────────────────────────────────────────── */
    IF @MODO = 'AZURE'
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM sys.symmetric_keys WHERE name = N'##MS_DatabaseMasterKey##')
        BEGIN
            SET @sql = N'CREATE MASTER KEY ENCRYPTION BY PASSWORD = ' + QUOTENAME(@SENHA_MASTER_KEY, '''') + N';';
            EXEC (@sql);
            SET @criouMasterKey = 1;
        END
        IF EXISTS (SELECT 1 FROM sys.external_data_sources WHERE name = N'TRF_DS_PRD') EXEC (N'DROP EXTERNAL DATA SOURCE TRF_DS_PRD;');
        IF EXISTS (SELECT 1 FROM sys.database_scoped_credentials WHERE name = N'TRF_CRED_PRD') EXEC (N'DROP DATABASE SCOPED CREDENTIAL TRF_CRED_PRD;');
        SET @sql = N'CREATE DATABASE SCOPED CREDENTIAL TRF_CRED_PRD WITH IDENTITY = ' + QUOTENAME(@LOGIN_ORIGEM, '''')
                 + N', SECRET = ' + QUOTENAME(@SENHA_ORIGEM, '''') + N';';
        EXEC (@sql);
        SET @sql = N'CREATE EXTERNAL DATA SOURCE TRF_DS_PRD WITH (TYPE = RDBMS, LOCATION = ' + QUOTENAME(@SERVIDOR_ORIGEM, '''')
                 + N', DATABASE_NAME = ' + QUOTENAME(@BANCO_ORIGEM, '''') + N', CREDENTIAL = TRF_CRED_PRD);';
        EXEC (@sql);
    END
    SET @ligou = 1;
    EXEC (N'CREATE SCHEMA TRF_EXT AUTHORIZATION dbo;');
    EXEC (N'CREATE SCHEMA TRF_STG AUTHORIZATION dbo;');

    /* Catálogo da PRD. Toda consulta à PRD devolve SHARD como última
       coluna: o sp_execute_remote acrescenta $ShardName; no LOCAL ela
       é acrescentada aqui. */
    SET @passo = N'ler o catálogo da PRD';
    SET @q = N'SELECT t.name, c.name, TYPE_NAME(c.user_type_id), c.max_length, c.precision, c.scale, c.collation_name,
                      c.is_computed, c.is_nullable
               FROM sys.tables t JOIN sys.columns c ON c.object_id = t.object_id WHERE t.schema_id = SCHEMA_ID(N''CI'')';
    IF @MODO = 'AZURE' INSERT @PRD_COL EXEC sp_execute_remote @data_source_name = N'TRF_DS_PRD', @stmt = @q;
    ELSE BEGIN SET @q = N'SELECT q.*, CAST(N''LOCAL'' AS NVARCHAR(500)) FROM (' + @q + N') q (a,b,c,d,e,f,g,h,i);'; INSERT @PRD_COL EXEC @proc @q; END

    IF NOT EXISTS (SELECT 1 FROM @PRD_COL)
        THROW 50001, N'A PRD respondeu, mas o usuário de leitura não enxerga nenhuma tabela do schema CI (falta GRANT SELECT/VIEW DEFINITION — ver 00a).', 1;

    /* Estrutura DEV x PRD: tabelas do DEV que faltam na PRD e colunas diferentes */
    INSERT @DIF (TABELA, COLUNA, PRD, DEV)
    SELECT DISTINCT d.TABELA, NULL, N'(tabela não existe)', N'existe'
    FROM @DEV_COL d WHERE NOT EXISTS (SELECT 1 FROM @PRD_COL p WHERE p.TABELA = d.TABELA);

    ;WITH D AS (SELECT TABELA, COLUNA, TIPO, TAM, PREC, ESC, CALC FROM @DEV_COL),
          P AS (SELECT TABELA, COLUNA, TIPO, TAM, PREC, ESC, CALC FROM @PRD_COL WHERE TABELA IN (SELECT TABELA FROM @DEV_COL)),
          X AS (SELECT 'PRD' AS LADO, * FROM (SELECT * FROM P EXCEPT SELECT * FROM D) a
                UNION ALL
                SELECT 'DEV', * FROM (SELECT * FROM D EXCEPT SELECT * FROM P) b)
    INSERT @DIF (TABELA, COLUNA, PRD, DEV)
    SELECT TABELA, COLUNA,
           MAX(CASE WHEN LADO = 'PRD' THEN CONCAT(TIPO, N' tam=', TAM, N' prec=', PREC, N' esc=', ESC, CASE WHEN CALC = 1 THEN N' calculada' END) END),
           MAX(CASE WHEN LADO = 'DEV' THEN CONCAT(TIPO, N' tam=', TAM, N' prec=', PREC, N' esc=', ESC, CASE WHEN CALC = 1 THEN N' calculada' END) END)
    FROM X GROUP BY TABELA, COLUNA;

    /* Collation diferente: com a mesma página de código (ou texto Unicode) o
       dado é convertido sem perda para a do DEV -> AVISO; página de código
       diferente em char/varchar -> bloqueia. */
    INSERT @AVISO (TABELA, COLUNA, PRD, DEV)
    SELECT d.TABELA, d.COLUNA, p.COLL, d.COLL
    FROM @DEV_COL d JOIN @PRD_COL p ON p.TABELA = d.TABELA AND p.COLUNA = d.COLUNA
    WHERE ISNULL(p.COLL, N'') <> ISNULL(d.COLL, N'');
    INSERT @DIF (TABELA, COLUNA, PRD, DEV)
    SELECT TABELA, COLUNA, N'collation ' + PRD + N' (página ' + CAST(COLLATIONPROPERTY(PRD, 'CodePage') AS NVARCHAR(10)) + N')',
           N'collation ' + DEV + N' (página ' + CAST(COLLATIONPROPERTY(DEV, 'CodePage') AS NVARCHAR(10)) + N')'
    FROM @AVISO a
    WHERE (PRD IS NULL OR DEV IS NULL OR CAST(COLLATIONPROPERTY(PRD, 'CodePage') AS INT) <> CAST(COLLATIONPROPERTY(DEV, 'CodePage') AS INT))
      AND EXISTS (SELECT 1 FROM @DEV_COL d WHERE d.TABELA = a.TABELA AND d.COLUNA = a.COLUNA AND d.TIPO IN (N'char', N'varchar', N'text'));

    IF EXISTS (SELECT 1 FROM @DIF)
    BEGIN
        SELECT TABELA = N'CI.' + TABELA, COLUNA = ISNULL(COLUNA, N'-'), NA_PRD = ISNULL(PRD, N'(não existe)'), NO_DEV = ISNULL(DEV, N'(não existe)')
        FROM @DIF ORDER BY TABELA, COLUNA;
        THROW 50002, N'A estrutura do DEV difere da PRD (lista acima). Nenhum dado foi copiado. Ajuste a estrutura e rode de novo.', 1;
    END

    /* DEV já tem dados? */
    DECLARE @comDados NVARCHAR(MAX);
    SELECT @comDados = STRING_AGG(CONVERT(NVARCHAR(MAX), N'CI.' + t.name COLLATE DATABASE_DEFAULT + N' (' + CAST(p.linhas AS NVARCHAR(20)) + N')'), N', ')
    FROM sys.tables t
    CROSS APPLY (SELECT linhas = SUM(ps.rows) FROM sys.partitions ps WHERE ps.object_id = t.object_id AND ps.index_id IN (0,1)) p
    WHERE t.schema_id = SCHEMA_ID(N'CI') AND p.linhas > 0
      AND NOT EXISTS (SELECT 1 FROM @EXCLUIR e WHERE e.TABELA = t.name COLLATE DATABASE_DEFAULT);
    IF @comDados IS NOT NULL AND @SUBSTITUIR_DADOS_DEV = 0
    BEGIN
        SET @erro = N'O DEV já tem dados no CI: ' + LEFT(@comDados, 3500) + N'. Nada foi alterado. Para apagar e copiar de novo: @SUBSTITUIR_DADOS_DEV = 1.';
        THROW 50003, @erro, 1;
    END

    /* ── 2. Leitura da PRD para a área temporária ──────────────────── */
    DECLARE @colsDef NVARCHAR(MAX), @colsExt NVARCHAR(MAX), @cols NVARCHAR(MAX), @confPrd NVARCHAR(MAX) = NULL;
    DECLARE t CURSOR LOCAL FAST_FORWARD FOR SELECT DISTINCT TABELA FROM @DEV_COL ORDER BY TABELA;
    OPEN t;
    FETCH NEXT FROM t INTO @tab;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @passo = N'ler CI.' + @tab + N' da PRD';
        /* colunas copiáveis: sem calculadas e sem rowversion (o DEV gera) */
        SELECT @cols = STRING_AGG(CONVERT(NVARCHAR(MAX), QUOTENAME(d.COLUNA)), N', ') WITHIN GROUP (ORDER BY d.ORDEM),
               @colsDef = STRING_AGG(CONVERT(NVARCHAR(MAX), QUOTENAME(d.COLUNA) + N' ' + x.TIPO_TXT + ISNULL(N' COLLATE ' + d.COLL, N'')
                    + CASE WHEN p.NULO = 1 THEN N' NULL' ELSE N' NOT NULL' END), N', ') WITHIN GROUP (ORDER BY d.ORDEM),
               @colsExt = STRING_AGG(CONVERT(NVARCHAR(MAX), QUOTENAME(d.COLUNA) + N' ' + x.TIPO_TXT + ISNULL(N' COLLATE ' + p.COLL, N'')
                    + CASE WHEN p.NULO = 1 THEN N' NULL' ELSE N' NOT NULL' END), N', ') WITHIN GROUP (ORDER BY d.ORDEM)
        FROM @DEV_COL d JOIN @PRD_COL p ON p.TABELA = d.TABELA AND p.COLUNA = d.COLUNA
        CROSS APPLY (SELECT TIPO_TXT = CASE WHEN d.TIPO IN (N'varchar', N'char', N'varbinary', N'binary')
                                THEN d.TIPO + N'(' + CASE WHEN d.TAM = -1 THEN N'max' ELSE CAST(d.TAM AS NVARCHAR(10)) END + N')'
                           WHEN d.TIPO IN (N'nvarchar', N'nchar')
                                THEN d.TIPO + N'(' + CASE WHEN d.TAM = -1 THEN N'max' ELSE CAST(d.TAM / 2 AS NVARCHAR(10)) END + N')'
                           WHEN d.TIPO IN (N'decimal', N'numeric')
                                THEN d.TIPO + N'(' + CAST(d.PREC AS NVARCHAR(3)) + N',' + CAST(d.ESC AS NVARCHAR(3)) + N')'
                           WHEN d.TIPO IN (N'datetime2', N'time', N'datetimeoffset') THEN d.TIPO + N'(' + CAST(d.ESC AS NVARCHAR(3)) + N')'
                           WHEN d.TIPO = N'float' THEN N'float(' + CAST(d.PREC AS NVARCHAR(3)) + N')'
                           ELSE d.TIPO END) x
        WHERE d.TABELA = @tab AND d.CALC = 0 AND d.TIPO <> N'timestamp';

        IF @MODO = 'AZURE'
            SET @sql = N'CREATE EXTERNAL TABLE TRF_EXT.' + QUOTENAME(@tab) + N' (' + @colsExt + N') WITH (DATA_SOURCE = TRF_DS_PRD, '
                     + N'SCHEMA_NAME = N''CI'', OBJECT_NAME = N''' + REPLACE(@tab, N'''', N'''''') + N''');';
        ELSE
            SET @sql = N'CREATE VIEW TRF_EXT.' + QUOTENAME(@tab) + N' AS SELECT ' + @cols + N' FROM '
                     + QUOTENAME(@BANCO_ORIGEM) + N'.CI.' + QUOTENAME(@tab) + N';';
        EXEC (@sql);
        SET @sql = N'CREATE TABLE TRF_STG.' + QUOTENAME(@tab) + N' (' + @colsDef + N');';
        EXEC (@sql);
        SET @sql = N'INSERT INTO TRF_STG.' + QUOTENAME(@tab) + N' WITH (TABLOCK) (' + @cols + N') SELECT ' + @cols
                 + N' FROM TRF_EXT.' + QUOTENAME(@tab) + N';';
        EXEC (@sql);

        SET @sql = N'SELECT @n = COUNT_BIG(*), @s = CHECKSUM_AGG(BINARY_CHECKSUM(' + @cols + N')) FROM TRF_STG.' + QUOTENAME(@tab) + N';';
        DECLARE @s INT;
        EXEC sp_executesql @sql, N'@n BIGINT OUTPUT, @s INT OUTPUT', @n = @n OUTPUT, @s = @s OUTPUT;
        INSERT @RESULTADO (TABELA, LINHAS_LIDAS, SOMA_LIDA) VALUES (@tab, @n, @s);
        RAISERROR('Lida da PRD: CI.%s (%I64d linhas)', 0, 1, @tab, @n) WITH NOWAIT;

        -- mesma contagem/soma calculada na PRD (conferência ponta a ponta)
        SET @confPrd = ISNULL(@confPrd + N' UNION ALL ', N'') + N'SELECT N''' + REPLACE(@tab, N'''', N'''''') + N''', COUNT_BIG(*), CHECKSUM_AGG(BINARY_CHECKSUM('
                     + @cols + N')) FROM CI.' + QUOTENAME(@tab);
        FETCH NEXT FROM t INTO @tab;
    END
    CLOSE t; DEALLOCATE t;

    SET @passo = N'conferir contagem/soma na PRD';
    SET @q = @confPrd;
    IF @MODO = 'AZURE' INSERT @PRD_CONF EXEC sp_execute_remote @data_source_name = N'TRF_DS_PRD', @stmt = @q;
    ELSE BEGIN SET @q = N'SELECT q.*, CAST(N''LOCAL'' AS NVARCHAR(500)) FROM (' + @q + N') q (a,b,c);'; INSERT @PRD_CONF EXEC @proc @q; END
    UPDATE r SET LINHAS_PRD = c.QTD, SOMA_PRD = c.SOMA FROM @RESULTADO r JOIN @PRD_CONF c ON c.TABELA = r.TABELA;

    SET @passo = N'ler identity e sequences da PRD';
    SET @q = N'SELECT t.name, CAST(ic.last_value AS NVARCHAR(40)), CAST(ic.increment_value AS NVARCHAR(40))
               FROM sys.identity_columns ic JOIN sys.tables t ON t.object_id = ic.object_id WHERE t.schema_id = SCHEMA_ID(N''CI'')';
    IF @MODO = 'AZURE' INSERT @PRD_IDENT EXEC sp_execute_remote @data_source_name = N'TRF_DS_PRD', @stmt = @q;
    ELSE BEGIN SET @q = N'SELECT q.*, CAST(N''LOCAL'' AS NVARCHAR(500)) FROM (' + @q + N') q (a,b,c);'; INSERT @PRD_IDENT EXEC @proc @q; END
    SET @q = N'SELECT s.name, CAST(CASE WHEN s.last_used_value IS NULL THEN CAST(s.current_value AS DECIMAL(38,0))
                                        ELSE CAST(s.last_used_value AS DECIMAL(38,0)) + CAST(s.increment AS DECIMAL(38,0)) END AS NVARCHAR(40)),
                      CAST(s.increment AS NVARCHAR(40))
               FROM sys.sequences s WHERE s.schema_id = SCHEMA_ID(N''CI'')';
    IF @MODO = 'AZURE' INSERT @PRD_SEQ EXEC sp_execute_remote @data_source_name = N'TRF_DS_PRD', @stmt = @q;
    ELSE BEGIN SET @q = N'SELECT q.*, CAST(N''LOCAL'' AS NVARCHAR(500)) FROM (' + @q + N') q (a,b,c);'; INSERT @PRD_SEQ EXEC @proc @q; END

    /* ── 3. Gravação no DEV: uma transação ─────────────────────────── */
    INSERT @TRG (NOME, TABELA, DESABILITADO)
    SELECT tr.name, OBJECT_NAME(tr.parent_id), tr.is_disabled
    FROM sys.triggers tr JOIN sys.tables t ON t.object_id = tr.parent_id WHERE t.schema_id = SCHEMA_ID(N'CI');
    INSERT @CON (TABELA, NOME, DESABILITADA, NAO_CONFIAVEL)
    SELECT OBJECT_NAME(parent_object_id), name, is_disabled, is_not_trusted FROM sys.foreign_keys
    WHERE parent_object_id IN (SELECT object_id FROM sys.tables WHERE schema_id = SCHEMA_ID(N'CI'))
    UNION ALL
    SELECT OBJECT_NAME(parent_object_id), name, is_disabled, is_not_trusted FROM sys.check_constraints
    WHERE parent_object_id IN (SELECT object_id FROM sys.tables WHERE schema_id = SCHEMA_ID(N'CI'));

    BEGIN TRANSACTION;

    SET @passo = N'desligar FKs/CHECKs e triggers do CI';
    SELECT @sql = STRING_AGG(CONVERT(NVARCHAR(MAX), N'ALTER TABLE CI.' + QUOTENAME(TABELA) + N' NOCHECK CONSTRAINT ALL; '
                  + N'DISABLE TRIGGER ALL ON CI.' + QUOTENAME(TABELA) + N';'), NCHAR(10))
    FROM (SELECT DISTINCT TABELA FROM @DEV_COL) x;
    EXEC (@sql);

    IF @SUBSTITUIR_DADOS_DEV = 1
    BEGIN
        SET @passo = N'apagar os dados atuais do CI no DEV';
        SELECT @sql = STRING_AGG(CONVERT(NVARCHAR(MAX), N'DELETE FROM CI.' + QUOTENAME(TABELA) + N';'), NCHAR(10))
        FROM (SELECT DISTINCT TABELA FROM @DEV_COL) x;
        EXEC (@sql);
    END

    DECLARE t CURSOR LOCAL FAST_FORWARD FOR SELECT DISTINCT TABELA FROM @DEV_COL ORDER BY TABELA;
    OPEN t;
    FETCH NEXT FROM t INTO @tab;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @passo = N'gravar CI.' + @tab + N' no DEV';
        SELECT @cols = STRING_AGG(CONVERT(NVARCHAR(MAX), QUOTENAME(COLUNA)), N', ') WITHIN GROUP (ORDER BY ORDEM)
        FROM @DEV_COL WHERE TABELA = @tab AND CALC = 0 AND TIPO <> N'timestamp';
        DECLARE @ident BIT = CASE WHEN EXISTS (SELECT 1 FROM @DEV_COL WHERE TABELA = @tab AND IDENT = 1) THEN 1 ELSE 0 END;

        SET @sql = CASE WHEN @ident = 1 THEN N'SET IDENTITY_INSERT CI.' + QUOTENAME(@tab) + N' ON; ' ELSE N'' END
                 + N'INSERT INTO CI.' + QUOTENAME(@tab) + N' WITH (TABLOCK) (' + @cols + N') SELECT ' + @cols
                 + N' FROM TRF_STG.' + QUOTENAME(@tab) + N'; '
                 + CASE WHEN @ident = 1 THEN N'SET IDENTITY_INSERT CI.' + QUOTENAME(@tab) + N' OFF; ' ELSE N'' END
                 + N'SELECT @n = COUNT_BIG(*), @s = CHECKSUM_AGG(BINARY_CHECKSUM(' + @cols + N')) FROM CI.' + QUOTENAME(@tab) + N';';
        EXEC sp_executesql @sql, N'@n BIGINT OUTPUT, @s INT OUTPUT', @n = @n OUTPUT, @s = @s OUTPUT;
        UPDATE @RESULTADO SET LINHAS_DEV = @n, SOMA_DEV = @s WHERE TABELA = @tab;
        FETCH NEXT FROM t INTO @tab;
    END
    CLOSE t; DEALLOCATE t;

    /* Conferência antes de confirmar: DEV = o que foi lido da PRD */
    IF EXISTS (SELECT 1 FROM @RESULTADO WHERE LINHAS_DEV <> LINHAS_LIDAS OR ISNULL(SOMA_DEV, 0) <> ISNULL(SOMA_LIDA, 0))
        THROW 50004, N'Contagem ou soma de verificação do DEV diferente da lida da PRD. Nada foi gravado.', 1;

    /* Identity no mesmo ponto da PRD (próximo valor igual) */
    SET @passo = N'ajustar identity';
    SELECT @sql = STRING_AGG(CONVERT(NVARCHAR(MAX),
            N'DBCC CHECKIDENT (N''CI.' + REPLACE(QUOTENAME(i.TABELA), N'''', N'''''') + N''', RESEED, '
          + CASE WHEN r.LINHAS_DEV > 0 THEN i.ULTIMO
                 ELSE CAST(CAST(i.ULTIMO AS DECIMAL(38,0)) + CAST(i.INCREMENTO AS DECIMAL(38,0)) AS NVARCHAR(40)) END
          + N') WITH NO_INFOMSGS;'), NCHAR(10))
    FROM @PRD_IDENT i JOIN @RESULTADO r ON r.TABELA = i.TABELA
    WHERE i.ULTIMO IS NOT NULL
      AND EXISTS (SELECT 1 FROM @DEV_COL d WHERE d.TABELA = i.TABELA AND d.IDENT = 1);
    IF @sql IS NOT NULL EXEC (@sql);

    /* Religar no estado anterior. WITH CHECK revalida todas as linhas. */
    DECLARE @nome SYSNAME, @des BIT, @nc BIT;
    DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT TABELA, NOME, DESABILITADA, NAO_CONFIAVEL FROM @CON ORDER BY TABELA, NOME;
    OPEN c;
    FETCH NEXT FROM c INTO @tab, @nome, @des, @nc;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        IF @des = 0
        BEGIN
            SET @passo = N'revalidar ' + @nome + N' em CI.' + @tab;
            SET @sql = N'ALTER TABLE CI.' + QUOTENAME(@tab) + CASE WHEN @nc = 0 THEN N' WITH CHECK' ELSE N' WITH NOCHECK' END
                     + N' CHECK CONSTRAINT ' + QUOTENAME(@nome) + N';';
            EXEC (@sql);
        END
        FETCH NEXT FROM c INTO @tab, @nome, @des, @nc;
    END
    CLOSE c; DEALLOCATE c;

    SET @passo = N'religar triggers';
    SELECT @sql = STRING_AGG(CONVERT(NVARCHAR(MAX), N'ENABLE TRIGGER CI.' + QUOTENAME(NOME) + N' ON CI.' + QUOTENAME(TABELA) + N';'), NCHAR(10))
    FROM @TRG WHERE DESABILITADO = 0;
    IF @sql IS NOT NULL EXEC (@sql);

    COMMIT TRANSACTION;

    /* ── 4. Sequences: próximo valor do DEV >= próximo da PRD ─────────
       sp_sequence_get_range consome o intervalo sem trocar o START WITH. */
    SET @passo = N'avançar sequences';
    DECLARE @seq SYSNAME, @prox DECIMAL(38,0), @inc DECIMAL(38,0), @proxDev DECIMAL(38,0), @faixa BIGINT, @primeiro SQL_VARIANT;
    DECLARE sq CURSOR LOCAL FAST_FORWARD FOR SELECT NOME, CAST(PROXIMO AS DECIMAL(38,0)), CAST(INCREMENTO AS DECIMAL(38,0)) FROM @PRD_SEQ;
    OPEN sq;
    FETCH NEXT FROM sq INTO @seq, @prox, @inc;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SELECT @proxDev = CASE WHEN last_used_value IS NULL THEN CAST(current_value AS DECIMAL(38,0))
                               ELSE CAST(last_used_value AS DECIMAL(38,0)) + CAST(increment AS DECIMAL(38,0)) END
        FROM sys.sequences WHERE object_id = OBJECT_ID(N'CI.' + QUOTENAME(@seq), N'SO');
        IF @proxDev IS NOT NULL AND @inc > 0 AND @prox > @proxDev
        BEGIN
            SET @faixa = CAST((@prox - @proxDev) / @inc AS BIGINT);
            SET @sql = N'CI.' + QUOTENAME(@seq);
            EXEC sp_sequence_get_range @sequence_name = @sql, @range_size = @faixa, @range_first_value = @primeiro OUTPUT;
        END
        INSERT @SEQ_FIM (NOME, PROXIMO_PRD, PROXIMO_DEV)
        SELECT @seq, CAST(@prox AS NVARCHAR(40)),
               CAST(CASE WHEN last_used_value IS NULL THEN CAST(current_value AS DECIMAL(38,0))
                         ELSE CAST(last_used_value AS DECIMAL(38,0)) + CAST(increment AS DECIMAL(38,0)) END AS NVARCHAR(40))
        FROM sys.sequences WHERE object_id = OBJECT_ID(N'CI.' + QUOTENAME(@seq), N'SO');
        FETCH NEXT FROM sq INTO @seq, @prox, @inc;
    END
    CLOSE sq; DEALLOCATE sq;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    SET @erro = CASE WHEN ERROR_NUMBER() BETWEEN 50001 AND 50099 THEN ERROR_MESSAGE()
                     ELSE N'Falha ao ' + ISNULL(@passo, N'preparar') + N': ' + ERROR_MESSAGE() + N' Nenhum dado foi gravado no DEV.' END;
END CATCH

/* ── 5. Limpeza (sempre) ────────────────────────────────────────────── */
BEGIN TRY
    SELECT @sql = STRING_AGG(CONVERT(NVARCHAR(MAX),
               CASE WHEN o.type = 'V' THEN N'DROP VIEW ' WHEN o.type = 'U' AND o.schema_id = SCHEMA_ID(N'TRF_STG') THEN N'DROP TABLE '
                    ELSE N'DROP EXTERNAL TABLE ' END
             + QUOTENAME(SCHEMA_NAME(o.schema_id)) + N'.' + QUOTENAME(o.name) + N';'), NCHAR(10))
    FROM sys.objects o WHERE o.schema_id IN (SCHEMA_ID(N'TRF_EXT'), SCHEMA_ID(N'TRF_STG')) AND o.type IN ('U', 'V');
    IF @sql IS NOT NULL EXEC (@sql);
    IF SCHEMA_ID(N'TRF_EXT') IS NOT NULL EXEC (N'DROP SCHEMA TRF_EXT;');
    IF SCHEMA_ID(N'TRF_STG') IS NOT NULL EXEC (N'DROP SCHEMA TRF_STG;');
    IF EXISTS (SELECT 1 FROM sys.external_data_sources WHERE name = N'TRF_DS_PRD') EXEC (N'DROP EXTERNAL DATA SOURCE TRF_DS_PRD;');
    IF EXISTS (SELECT 1 FROM sys.database_scoped_credentials WHERE name = N'TRF_CRED_PRD') EXEC (N'DROP DATABASE SCOPED CREDENTIAL TRF_CRED_PRD;');
    IF @criouMasterKey = 1 AND NOT EXISTS (SELECT 1 FROM sys.database_scoped_credentials)
        EXEC (N'DROP MASTER KEY;');
END TRY
BEGIN CATCH
    SET @erro = ISNULL(@erro + N' | ', N'') + N'Limpeza incompleta (remova TRF_EXT/TRF_STG/TRF_DS_PRD/TRF_CRED_PRD à mão): ' + ERROR_MESSAGE();
END CATCH

/* ── Relatório ──────────────────────────────────────────────────────── */
IF @erro IS NULL
BEGIN
    SELECT TABELA = N'CI.' + TABELA, LINHAS_PRD, LINHAS_DEV,
           RESULTADO = CASE WHEN LINHAS_DEV = LINHAS_LIDAS AND ISNULL(SOMA_DEV, 0) = ISNULL(SOMA_LIDA, 0)
                             AND LINHAS_PRD = LINHAS_LIDAS AND ISNULL(SOMA_PRD, 0) = ISNULL(SOMA_LIDA, 0) THEN 'OK'
                            WHEN LINHAS_DEV = LINHAS_LIDAS AND ISNULL(SOMA_DEV, 0) = ISNULL(SOMA_LIDA, 0)
                                 THEN 'OK (a PRD mudou durante a leitura)'
                            ELSE 'DIVERGE' END
    FROM @RESULTADO
    UNION ALL
    SELECT DISTINCT N'CI.' + p.TABELA, NULL, NULL,
           CASE WHEN EXISTS (SELECT 1 FROM @EXCLUIR e WHERE e.TABELA = p.TABELA) THEN 'NAO COPIADA (em @EXCLUIR)'
                ELSE 'NAO COPIADA (tabela nao existe no DEV)' END
    FROM @PRD_COL p WHERE NOT EXISTS (SELECT 1 FROM @DEV_COL d WHERE d.TABELA = p.TABELA)
    ORDER BY 1;

    SELECT ITEM = N'FKs e CHECKs', ANTES = CAST(COUNT(*) AS NVARCHAR(20)) + N' (' + CAST(SUM(CASE WHEN NAO_CONFIAVEL = 0 THEN 1 ELSE 0 END) AS NVARCHAR(20)) + N' confiáveis)',
           DEPOIS = (SELECT CAST(COUNT(*) AS NVARCHAR(20)) + N' (' + CAST(SUM(CASE WHEN is_not_trusted = 0 THEN 1 ELSE 0 END) AS NVARCHAR(20)) + N' confiáveis)'
                     FROM (SELECT is_not_trusted, parent_object_id FROM sys.foreign_keys UNION ALL SELECT is_not_trusted, parent_object_id FROM sys.check_constraints) k
                     WHERE k.parent_object_id IN (SELECT object_id FROM sys.tables WHERE schema_id = SCHEMA_ID(N'CI')))
    FROM @CON
    UNION ALL
    SELECT N'Triggers habilitados', CAST(SUM(CASE WHEN DESABILITADO = 0 THEN 1 ELSE 0 END) AS NVARCHAR(20)),
           (SELECT CAST(COUNT(*) AS NVARCHAR(20)) FROM sys.triggers tr JOIN sys.tables t ON t.object_id = tr.parent_id
            WHERE t.schema_id = SCHEMA_ID(N'CI') AND tr.is_disabled = 0)
    FROM @TRG
    UNION ALL
    SELECT N'Sequence CI.' + NOME + N' (próximo valor PRD / DEV)', PROXIMO_PRD, PROXIMO_DEV FROM @SEQ_FIM;

    IF EXISTS (SELECT 1 FROM @AVISO)
        SELECT AVISO = N'collation diferente, mesma página de código — dado convertido sem perda', TABELAS = COUNT(DISTINCT TABELA), COLUNAS = COUNT(*),
               PRD = MIN(PRD), DEV = MIN(DEV) FROM @AVISO;
    PRINT N'Transferência concluída. Confira RESULTADO = OK em todas as tabelas.';
END
ELSE
    RAISERROR(N'%s', 16, 1, @erro);
GO
