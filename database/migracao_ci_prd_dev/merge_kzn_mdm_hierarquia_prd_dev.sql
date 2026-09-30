/* =====================================================================
   MERGE CI.KZN_MDM_HIERARQUIA: BDIBPBMSA_PRD -> BDIBPBMSA_DEV
   (executar conectado ao BDIBPBMSA_DEV — na PRD só LÊ)
   ---------------------------------------------------------------------
   Deixa a KZN_MDM_HIERARQUIA do DEV igual à da PRD, casando por
   ID_USUARIO (é a coluna que as FKs das outras tabelas referenciam):
     - existe na PRD e não no DEV  -> INSERT;
     - existe nos dois e mudou     -> UPDATE das colunas comuns
       (DT_ATUALIZACAO vem da PRD; o trigger TR_KZN_MDM_HIERARQUIA_UPD
       não recarimba porque a coluna é atualizada no mesmo comando);
     - existe só no DEV            -> mantém (padrão) ou DELETE com
       @APAGAR_AUSENTES_NO_DEV = 1.
   Linhas iguais não são tocadas.

   As colunas vêm do catálogo REAL dos dois bancos (nada fixo no script).
   Diferenças de estrutura entre PRD e DEV:
     BLOQUEIA (nada é alterado) — o dado da PRD não caberia no DEV:
       coluna da PRD que não existe no DEV; tipo diferente; tamanho ou
       precisão menor no DEV; coluna só do DEV NOT NULL sem default.
     AVISO (segue) — o dado cabe: tamanho maior no DEV, collation
       diferente, coluna só do DEV que aceita NULL ou tem default
       (fica como está nas linhas atualizadas e NULL/default nas novas).
   A lista sai na aba Resultados em qualquer caso.

   Antes de gravar (nada é alterado se falhar):
     - ID_USUARIO não se repete na PRD;
     - cada FK da tabela no DEV (ex.: ID_TIPO_USUARIO -> KZN_TIPO_USUARIO)
       encontra o valor vindo da PRD.
   Gravação numa única transação, com as FKs ativas: se uma matrícula
   que muda ou uma linha a apagar estiver referenciada por outra tabela
   (ADMIN, APROVADOR, PVC, log...), a FK barra, é feito ROLLBACK e o
   DEV fica como estava. Ao final: conferência PRD x DEV e remoção da
   ligação com a PRD (também em caso de erro).

   Leitura da PRD: autenticação SQL (exigência do Elastic Query) — use o
   usuário do 00a_prd_usuario_leitura.sql. Não grave a senha no repositório.
   ===================================================================== */

SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @MODO                    VARCHAR(10)   = 'AZURE';   -- 'AZURE' | 'LOCAL' (origem na mesma instância)
DECLARE @SERVIDOR_ORIGEM         NVARCHAR(256) = N'rdb-ibp-bmsa-prd.database.windows.net';
DECLARE @BANCO_ORIGEM            SYSNAME       = N'BDIBPBMSA_PRD';
DECLARE @LOGIN_ORIGEM            NVARCHAR(128) = N'<usuario de leitura criado no 00a>';
DECLARE @SENHA_ORIGEM            NVARCHAR(256) = N'<senha do usuario de leitura>';
DECLARE @SENHA_MASTER_KEY        NVARCHAR(256) = N'<senha forte para a master key do DEV>';  -- só se o DEV ainda não tiver master key
DECLARE @APAGAR_AUSENTES_NO_DEV  BIT           = 0;         -- 1 = apaga do DEV quem não existe na PRD

/* ── Travas ─────────────────────────────────────────────────────────── */
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
IF OBJECT_ID(N'CI.KZN_MDM_HIERARQUIA', N'U') IS NULL
BEGIN
    RAISERROR('Abortado: CI.KZN_MDM_HIERARQUIA não existe neste banco.', 16, 1);
    RETURN;
END
IF @MODO = 'AZURE' AND (@LOGIN_ORIGEM LIKE N'<%' OR @SENHA_ORIGEM LIKE N'<%')
BEGIN
    RAISERROR('Abortado: preencha @LOGIN_ORIGEM e @SENHA_ORIGEM.', 16, 1);
    RETURN;
END
IF @MODO = 'AZURE' AND NOT EXISTS (SELECT 1 FROM sys.symmetric_keys WHERE name = N'##MS_DatabaseMasterKey##')
   AND @SENHA_MASTER_KEY LIKE N'<%'
BEGIN
    RAISERROR('Abortado: o DEV não tem master key. Preencha @SENHA_MASTER_KEY.', 16, 1);
    RETURN;
END
IF @MODO = 'LOCAL' AND DB_ID(@BANCO_ORIGEM) IS NULL
BEGIN
    RAISERROR('Abortado: modo LOCAL e o banco de origem %s não existe nesta instância.', 16, 1, @BANCO_ORIGEM);
    RETURN;
END

DECLARE @sql NVARCHAR(MAX), @q NVARCHAR(MAX), @erro NVARCHAR(4000), @passo NVARCHAR(200), @criouMasterKey BIT = 0,
        @proc NVARCHAR(400) = QUOTENAME(@BANCO_ORIGEM) + N'.sys.sp_executesql',
        @cols NVARCHAR(MAX), @colsS NVARCHAR(MAX), @colsT NVARCHAR(MAX), @set NVARCHAR(MAX), @defStg NVARCHAR(MAX),
        @defExt NVARCHAR(MAX), @ident BIT, @antes BIGINT, @n BIGINT;

DECLARE @PRD_COL TABLE (COLUNA SYSNAME, ORDEM INT, TIPO SYSNAME, TAM INT, PREC INT, ESC INT, COLL SYSNAME NULL, NULO BIT,
                        CALC BIT, SHARD NVARCHAR(500));
DECLARE @DEV_COL TABLE (COLUNA SYSNAME, ORDEM INT, TIPO SYSNAME, TAM INT, PREC INT, ESC INT, COLL SYSNAME NULL, NULO BIT,
                        CALC BIT, IDENT BIT, TEM_DEFAULT BIT);
DECLARE @DIF TABLE (COLUNA SYSNAME, NA_PRD NVARCHAR(300), NO_DEV NVARCHAR(300), SITUACAO VARCHAR(10), MOTIVO NVARCHAR(300));
DECLARE @COMUM TABLE (COLUNA SYSNAME, ORDEM INT, DEF_EXT NVARCHAR(400), DEF_STG NVARCHAR(400));

/* Catálogo do DEV — copiado para variável de tabela antes de comparar
   (no Azure a collation do catálogo pode diferir da do banco). */
INSERT @DEV_COL
SELECT c.name, c.column_id, TYPE_NAME(c.user_type_id), c.max_length, c.precision, c.scale, c.collation_name, c.is_nullable,
       c.is_computed, c.is_identity, CASE WHEN c.default_object_id <> 0 THEN 1 ELSE 0 END
FROM sys.columns c WHERE c.object_id = OBJECT_ID(N'CI.KZN_MDM_HIERARQUIA');
SELECT @antes = COUNT_BIG(*) FROM CI.KZN_MDM_HIERARQUIA;

DROP TABLE IF EXISTS #PRD, #ACAO;
CREATE TABLE #PRD (_VAZIA_ BIT NULL);        -- colunas reais entram abaixo, conforme a PRD
CREATE TABLE #ACAO (ACAO NVARCHAR(10), ID_USUARIO INT);

BEGIN TRY
    /* ── Ligação com a PRD ──────────────────────────────────────────── */
    IF @MODO = 'AZURE'
    BEGIN
        SET @passo = N'criar a ligação com a PRD';
        IF NOT EXISTS (SELECT 1 FROM sys.symmetric_keys WHERE name = N'##MS_DatabaseMasterKey##')
        BEGIN
            SET @sql = N'CREATE MASTER KEY ENCRYPTION BY PASSWORD = ' + QUOTENAME(@SENHA_MASTER_KEY, '''') + N';';
            EXEC (@sql);
            SET @criouMasterKey = 1;
        END
        IF OBJECT_ID(N'dbo.MRG_EXT_KZN_MDM_HIERARQUIA') IS NOT NULL EXEC (N'DROP EXTERNAL TABLE dbo.MRG_EXT_KZN_MDM_HIERARQUIA;');
        IF EXISTS (SELECT 1 FROM sys.external_data_sources WHERE name = N'MRG_DS_PRD') EXEC (N'DROP EXTERNAL DATA SOURCE MRG_DS_PRD;');
        IF EXISTS (SELECT 1 FROM sys.database_scoped_credentials WHERE name = N'MRG_CRED_PRD') EXEC (N'DROP DATABASE SCOPED CREDENTIAL MRG_CRED_PRD;');
        SET @sql = N'CREATE DATABASE SCOPED CREDENTIAL MRG_CRED_PRD WITH IDENTITY = ' + QUOTENAME(@LOGIN_ORIGEM, '''')
                 + N', SECRET = ' + QUOTENAME(@SENHA_ORIGEM, '''') + N';';
        EXEC (@sql);
        SET @sql = N'CREATE EXTERNAL DATA SOURCE MRG_DS_PRD WITH (TYPE = RDBMS, LOCATION = ' + QUOTENAME(@SERVIDOR_ORIGEM, '''')
                 + N', DATABASE_NAME = ' + QUOTENAME(@BANCO_ORIGEM, '''') + N', CREDENTIAL = MRG_CRED_PRD);';
        EXEC (@sql);
    END

    /* ── Estrutura PRD x DEV ────────────────────────────────────────── */
    SET @passo = N'ler a estrutura da tabela na PRD';
    SET @q = N'SELECT c.name, c.column_id, TYPE_NAME(c.user_type_id), c.max_length, c.precision, c.scale, c.collation_name,
                      c.is_nullable, c.is_computed
               FROM sys.columns c WHERE c.object_id = OBJECT_ID(N''CI.KZN_MDM_HIERARQUIA'')';
    IF @MODO = 'AZURE' INSERT @PRD_COL EXEC sp_execute_remote @data_source_name = N'MRG_DS_PRD', @stmt = @q;
    ELSE BEGIN SET @q = N'SELECT q.*, CAST(N''LOCAL'' AS NVARCHAR(500)) FROM (' + @q + N') q (a,b,c,d,e,f,g,h,i);'; INSERT @PRD_COL EXEC @proc @q; END

    IF NOT EXISTS (SELECT 1 FROM @PRD_COL)
        THROW 50001, N'A PRD respondeu, mas o usuário de leitura não enxerga CI.KZN_MDM_HIERARQUIA (falta GRANT SELECT/VIEW DEFINITION — ver 00a).', 1;

    /* Classificação das diferenças (colunas calculadas e rowversion não são copiadas) */
    ;WITH P AS (SELECT * FROM @PRD_COL WHERE CALC = 0 AND TIPO <> N'timestamp'),
          D AS (SELECT * FROM @DEV_COL WHERE CALC = 0 AND TIPO <> N'timestamp'),
          J AS (SELECT COLUNA = ISNULL(p.COLUNA, d.COLUNA),
                       P_TXT = CASE WHEN p.COLUNA IS NOT NULL THEN CONCAT(p.TIPO, N'(', CASE WHEN p.TAM = -1 THEN N'max' ELSE CAST(p.TAM AS NVARCHAR(10)) END,
                                    N',', p.PREC, N',', p.ESC, N') ', p.COLL, CASE WHEN p.NULO = 1 THEN N' NULL' ELSE N' NOT NULL' END) END,
                       D_TXT = CASE WHEN d.COLUNA IS NOT NULL THEN CONCAT(d.TIPO, N'(', CASE WHEN d.TAM = -1 THEN N'max' ELSE CAST(d.TAM AS NVARCHAR(10)) END,
                                    N',', d.PREC, N',', d.ESC, N') ', d.COLL, CASE WHEN d.NULO = 1 THEN N' NULL' ELSE N' NOT NULL' END) END,
                       SITUACAO_MOTIVO =
                       CASE WHEN d.COLUNA IS NULL THEN 'B|coluna da PRD não existe no DEV — o dado seria perdido'
                            WHEN p.COLUNA IS NULL AND d.NULO = 0 AND d.TEM_DEFAULT = 0 AND d.IDENT = 0
                                 THEN 'B|coluna só do DEV, NOT NULL e sem default — a inclusão falharia'
                            WHEN p.COLUNA IS NULL THEN 'A|coluna só do DEV — mantida nas linhas atualizadas; NULL/default nas novas'
                            WHEN p.TIPO <> d.TIPO THEN 'B|tipo diferente'
                            WHEN (d.TAM <> -1 AND (p.TAM = -1 OR d.TAM < p.TAM)) OR d.PREC < p.PREC OR d.ESC < p.ESC
                                 OR (d.PREC - d.ESC) < (p.PREC - p.ESC)
                                 THEN 'B|tamanho/precisão menor no DEV — o dado poderia não caber'
                            WHEN d.TAM <> p.TAM OR d.PREC <> p.PREC OR d.ESC <> p.ESC THEN 'A|tamanho/precisão maior no DEV — o dado cabe'
                            WHEN ISNULL(p.COLL, N'') <> ISNULL(d.COLL, N'') THEN 'A|collation diferente — o dado é convertido para a do DEV'
                            WHEN p.NULO = 1 AND d.NULO = 0 THEN 'A|NULL na PRD e NOT NULL no DEV — se houver NULL, a gravação falha e nada é alterado'
                       END
                FROM P p FULL JOIN D d ON d.COLUNA = p.COLUNA)
    INSERT @DIF (COLUNA, NA_PRD, NO_DEV, SITUACAO, MOTIVO)
    SELECT COLUNA, ISNULL(P_TXT, N'(não existe)'), ISNULL(D_TXT, N'(não existe)'),
           CASE LEFT(SITUACAO_MOTIVO, 1) WHEN 'B' THEN 'BLOQUEIA' ELSE 'AVISO' END, SUBSTRING(SITUACAO_MOTIVO, 3, 300)
    FROM J WHERE SITUACAO_MOTIVO IS NOT NULL;

    IF EXISTS (SELECT 1 FROM @DIF)
        SELECT COLUNA, NA_PRD, NO_DEV, SITUACAO, MOTIVO FROM @DIF ORDER BY CASE SITUACAO WHEN 'BLOQUEIA' THEN 0 ELSE 1 END, COLUNA;
    IF EXISTS (SELECT 1 FROM @DIF WHERE SITUACAO = 'BLOQUEIA')
        THROW 50002, N'A estrutura de CI.KZN_MDM_HIERARQUIA no DEV não comporta os dados da PRD (linhas BLOQUEIA acima). Nada foi alterado.', 1;

    /* Colunas comuns: externa com a definição da PRD; área de leitura com o tipo da PRD e a collation do DEV */
    INSERT @COMUM (COLUNA, ORDEM, DEF_EXT, DEF_STG)
    SELECT p.COLUNA, d.ORDEM,
           QUOTENAME(p.COLUNA) + N' ' + x.TIPO_TXT + ISNULL(N' COLLATE ' + p.COLL, N'') + CASE WHEN p.NULO = 1 THEN N' NULL' ELSE N' NOT NULL' END,
           QUOTENAME(p.COLUNA) + N' ' + x.TIPO_TXT + ISNULL(N' COLLATE ' + d.COLL, N'') + N' NULL'
    FROM @PRD_COL p JOIN @DEV_COL d ON d.COLUNA = p.COLUNA
    CROSS APPLY (SELECT TIPO_TXT = CASE
            WHEN p.TIPO IN (N'varchar', N'char', N'varbinary', N'binary')
                 THEN p.TIPO + N'(' + CASE WHEN p.TAM = -1 THEN N'max' ELSE CAST(p.TAM AS NVARCHAR(10)) END + N')'
            WHEN p.TIPO IN (N'nvarchar', N'nchar')
                 THEN p.TIPO + N'(' + CASE WHEN p.TAM = -1 THEN N'max' ELSE CAST(p.TAM / 2 AS NVARCHAR(10)) END + N')'
            WHEN p.TIPO IN (N'decimal', N'numeric') THEN p.TIPO + N'(' + CAST(p.PREC AS NVARCHAR(3)) + N',' + CAST(p.ESC AS NVARCHAR(3)) + N')'
            WHEN p.TIPO IN (N'datetime2', N'time', N'datetimeoffset') THEN p.TIPO + N'(' + CAST(p.ESC AS NVARCHAR(3)) + N')'
            WHEN p.TIPO = N'float' THEN N'float(' + CAST(p.PREC AS NVARCHAR(3)) + N')'
            ELSE p.TIPO END) x
    WHERE p.CALC = 0 AND d.CALC = 0 AND p.TIPO <> N'timestamp';

    IF NOT EXISTS (SELECT 1 FROM @COMUM WHERE COLUNA = N'ID_USUARIO')
        THROW 50003, N'ID_USUARIO não existe nas duas tabelas: não há como casar as linhas. Nada foi alterado.', 1;

    SELECT @cols    = STRING_AGG(CONVERT(NVARCHAR(MAX), QUOTENAME(COLUNA)), N', ') WITHIN GROUP (ORDER BY ORDEM),
           @colsS   = STRING_AGG(CONVERT(NVARCHAR(MAX), N's.' + QUOTENAME(COLUNA)), N', ') WITHIN GROUP (ORDER BY ORDEM),
           @colsT   = STRING_AGG(CONVERT(NVARCHAR(MAX), N't.' + QUOTENAME(COLUNA)), N', ') WITHIN GROUP (ORDER BY ORDEM),
           @defExt  = STRING_AGG(CONVERT(NVARCHAR(MAX), DEF_EXT), N', ') WITHIN GROUP (ORDER BY ORDEM),
           @defStg  = STRING_AGG(CONVERT(NVARCHAR(MAX), DEF_STG), N', ') WITHIN GROUP (ORDER BY ORDEM)
    FROM @COMUM;
    SELECT @set = STRING_AGG(CONVERT(NVARCHAR(MAX), N't.' + QUOTENAME(COLUNA) + N' = s.' + QUOTENAME(COLUNA)), N', ') WITHIN GROUP (ORDER BY ORDEM)
    FROM @COMUM WHERE COLUNA <> N'ID_USUARIO';
    SET @ident = CASE WHEN EXISTS (SELECT 1 FROM @DEV_COL d JOIN @COMUM c ON c.COLUNA = d.COLUNA WHERE d.IDENT = 1) THEN 1 ELSE 0 END;

    /* ── Leitura da PRD ─────────────────────────────────────────────── */
    SET @passo = N'ler os dados da PRD';
    SET @sql = N'ALTER TABLE #PRD ADD ' + @defStg + N'; ALTER TABLE #PRD DROP COLUMN _VAZIA_;';
    EXEC (@sql);
    IF @MODO = 'AZURE'
    BEGIN
        SET @sql = N'CREATE EXTERNAL TABLE dbo.MRG_EXT_KZN_MDM_HIERARQUIA (' + @defExt + N') WITH (DATA_SOURCE = MRG_DS_PRD, '
                 + N'SCHEMA_NAME = N''CI'', OBJECT_NAME = N''KZN_MDM_HIERARQUIA'');';
        EXEC (@sql);
        SET @sql = N'INSERT INTO #PRD (' + @cols + N') SELECT ' + @cols + N' FROM dbo.MRG_EXT_KZN_MDM_HIERARQUIA;';
    END
    ELSE
        SET @sql = N'INSERT INTO #PRD (' + @cols + N') SELECT ' + @cols + N' FROM ' + QUOTENAME(@BANCO_ORIGEM) + N'.CI.KZN_MDM_HIERARQUIA;';
    EXEC (@sql);

    /* ── Pré-validações ─────────────────────────────────────────────── */
    IF EXISTS (SELECT 1 FROM #PRD GROUP BY ID_USUARIO HAVING COUNT(*) > 1)
    BEGIN
        SELECT ID_USUARIO_REPETIDO_NA_PRD = ID_USUARIO, VEZES = COUNT(*) FROM #PRD GROUP BY ID_USUARIO HAVING COUNT(*) > 1;
        THROW 50004, N'ID_USUARIO se repete na PRD (lista acima): não há como casar as linhas. Nada foi alterado.', 1;
    END
    IF EXISTS (SELECT 1 FROM #PRD WHERE ID_USUARIO IS NULL)
        THROW 50005, N'Há linha com ID_USUARIO nulo na PRD. Nada foi alterado.', 1;

    /* Cada FK da tabela no DEV (exceto a própria tabela) precisa achar o
       valor que vem da PRD — ex.: ID_TIPO_USUARIO em KZN_TIPO_USUARIO. */
    DECLARE @FK TABLE (NOME SYSNAME, REF NVARCHAR(300), COND NVARCHAR(MAX), FILTRO NVARCHAR(MAX), COLS NVARCHAR(MAX));
    INSERT @FK
    SELECT fk.name, QUOTENAME(SCHEMA_NAME(rt.schema_id)) + N'.' + QUOTENAME(rt.name),
           STRING_AGG(CONVERT(NVARCHAR(MAX), N'r.' + QUOTENAME(rc.name) + N' = p.' + QUOTENAME(pc.name)), N' AND '),
           STRING_AGG(CONVERT(NVARCHAR(MAX), N'p.' + QUOTENAME(pc.name) + N' IS NOT NULL'), N' AND '),
           STRING_AGG(CONVERT(NVARCHAR(MAX), N'p.' + QUOTENAME(pc.name)), N', ')
    FROM sys.foreign_keys fk
    JOIN sys.tables rt ON rt.object_id = fk.referenced_object_id
    JOIN sys.foreign_key_columns fc ON fc.constraint_object_id = fk.object_id
    JOIN sys.columns pc ON pc.object_id = fc.parent_object_id AND pc.column_id = fc.parent_column_id
    JOIN sys.columns rc ON rc.object_id = fc.referenced_object_id AND rc.column_id = fc.referenced_column_id
    WHERE fk.parent_object_id = OBJECT_ID(N'CI.KZN_MDM_HIERARQUIA') AND fk.referenced_object_id <> fk.parent_object_id
      AND fk.is_disabled = 0
    GROUP BY fk.name, rt.schema_id, rt.name;

    DECLARE @fkNome SYSNAME, @fkRef NVARCHAR(300), @fkCond NVARCHAR(MAX), @fkFiltro NVARCHAR(MAX), @fkCols NVARCHAR(MAX), @faltas NVARCHAR(MAX) = NULL;
    DECLARE f CURSOR LOCAL FAST_FORWARD FOR SELECT NOME, REF, COND, FILTRO, COLS FROM @FK;
    OPEN f;
    FETCH NEXT FROM f INTO @fkNome, @fkRef, @fkCond, @fkFiltro, @fkCols;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @sql = N'SELECT @n = COUNT(*) FROM #PRD p WHERE ' + @fkFiltro + N' AND NOT EXISTS (SELECT 1 FROM ' + @fkRef + N' r WHERE ' + @fkCond + N');';
        EXEC sp_executesql @sql, N'@n BIGINT OUTPUT', @n = @n OUTPUT;
        IF @n > 0
        BEGIN
            SET @sql = N'SELECT FK = N''' + REPLACE(@fkNome, N'''', N'''''') + N''', VALOR_FALTANDO_NO_DEV = CONCAT_WS(N'', '', ' + @fkCols
                     + N', NULL), USUARIOS_DA_PRD = COUNT(*) FROM #PRD p WHERE ' + @fkFiltro + N' AND NOT EXISTS (SELECT 1 FROM ' + @fkRef
                     + N' r WHERE ' + @fkCond + N') GROUP BY ' + @fkCols + N';';
            EXEC (@sql);
            SET @faltas = ISNULL(@faltas + N', ', N'') + @fkNome + N' -> ' + @fkRef;
        END
        FETCH NEXT FROM f INTO @fkNome, @fkRef, @fkCond, @fkFiltro, @fkCols;
    END
    CLOSE f; DEALLOCATE f;
    IF @faltas IS NOT NULL
    BEGIN
        SET @erro = N'Valores da PRD sem correspondente no DEV (' + @faltas + N'; lista acima). Cadastre-os no DEV e rode de novo. Nada foi alterado.';
        THROW 50006, @erro, 1;
    END

    /* ── MERGE ──────────────────────────────────────────────────────── */
    SET @passo = N'gravar no DEV';
    SET @sql = CASE WHEN @ident = 1 THEN N'SET IDENTITY_INSERT CI.KZN_MDM_HIERARQUIA ON; ' ELSE N'' END + N'
    MERGE CI.KZN_MDM_HIERARQUIA WITH (HOLDLOCK) AS t
    USING #PRD AS s
       ON t.ID_USUARIO = s.ID_USUARIO'
    + CASE WHEN @set IS NOT NULL THEN N'
    WHEN MATCHED AND EXISTS (SELECT ' + @colsS + N' EXCEPT SELECT ' + @colsT + N') THEN
        UPDATE SET ' + @set ELSE N'' END + N'
    WHEN NOT MATCHED BY TARGET THEN
        INSERT (' + @cols + N') VALUES (' + @colsS + N')'
    + CASE WHEN @APAGAR_AUSENTES_NO_DEV = 1 THEN N'
    WHEN NOT MATCHED BY SOURCE THEN
        DELETE' ELSE N'' END + N'
    OUTPUT $action, ISNULL(inserted.ID_USUARIO, deleted.ID_USUARIO) INTO #ACAO (ACAO, ID_USUARIO);'
    + CASE WHEN @ident = 1 THEN N' SET IDENTITY_INSERT CI.KZN_MDM_HIERARQUIA OFF;' ELSE N'' END + N'
    SELECT @n = COUNT_BIG(*) FROM (SELECT ' + @cols + N' FROM #PRD EXCEPT SELECT ' + @cols + N' FROM CI.KZN_MDM_HIERARQUIA) x;';

    BEGIN TRANSACTION;
    EXEC sp_executesql @sql, N'@n BIGINT OUTPUT', @n = @n OUTPUT;
    /* Conferência antes de confirmar: toda linha da PRD está igual no DEV */
    IF @n <> 0
        THROW 50007, N'Após o MERGE ainda há linhas da PRD diferentes no DEV. Nada foi gravado.', 1;
    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    SET @erro = CASE WHEN ERROR_NUMBER() BETWEEN 50001 AND 50099 THEN ERROR_MESSAGE()
                     WHEN ERROR_NUMBER() = 547 THEN N'Uma FK barrou a alteração (linha do DEV referenciada por outra tabela — '
                          + N'matrícula que mudou na PRD ou linha a apagar): ' + ERROR_MESSAGE() + N' ROLLBACK: nada foi alterado.'
                     ELSE N'Falha ao ' + ISNULL(@passo, N'preparar') + N': ' + ERROR_MESSAGE() + N' Nada foi alterado.' END;
END CATCH

/* ── Limpeza da ligação com a PRD (sempre) ──────────────────────────── */
BEGIN TRY
    IF OBJECT_ID(N'dbo.MRG_EXT_KZN_MDM_HIERARQUIA') IS NOT NULL EXEC (N'DROP EXTERNAL TABLE dbo.MRG_EXT_KZN_MDM_HIERARQUIA;');
    IF EXISTS (SELECT 1 FROM sys.external_data_sources WHERE name = N'MRG_DS_PRD') EXEC (N'DROP EXTERNAL DATA SOURCE MRG_DS_PRD;');
    IF EXISTS (SELECT 1 FROM sys.database_scoped_credentials WHERE name = N'MRG_CRED_PRD') EXEC (N'DROP DATABASE SCOPED CREDENTIAL MRG_CRED_PRD;');
    IF @criouMasterKey = 1 AND NOT EXISTS (SELECT 1 FROM sys.database_scoped_credentials) EXEC (N'DROP MASTER KEY;');
END TRY
BEGIN CATCH
    SET @erro = ISNULL(@erro + N' | ', N'') + N'Limpeza incompleta (remova MRG_EXT_KZN_MDM_HIERARQUIA/MRG_DS_PRD/MRG_CRED_PRD à mão): ' + ERROR_MESSAGE();
END CATCH

/* ── Resultado ──────────────────────────────────────────────────────── */
IF @erro IS NULL
BEGIN
    SET @sql = N'
    SELECT ITEM = N''Linhas na PRD'', QTD = (SELECT COUNT_BIG(*) FROM #PRD)
    UNION ALL SELECT N''Linhas no DEV antes'', @antes
    UNION ALL SELECT N''Inseridas'', (SELECT COUNT_BIG(*) FROM #ACAO WHERE ACAO = N''INSERT'')
    UNION ALL SELECT N''Atualizadas'', (SELECT COUNT_BIG(*) FROM #ACAO WHERE ACAO = N''UPDATE'')
    UNION ALL SELECT N''Apagadas (só existiam no DEV)'', (SELECT COUNT_BIG(*) FROM #ACAO WHERE ACAO = N''DELETE'')
    UNION ALL SELECT N''Mantidas (só existem no DEV)'', (SELECT COUNT_BIG(*) FROM CI.KZN_MDM_HIERARQUIA t WHERE NOT EXISTS (SELECT 1 FROM #PRD p WHERE p.ID_USUARIO = t.ID_USUARIO))
    UNION ALL SELECT N''Linhas no DEV depois'', (SELECT COUNT_BIG(*) FROM CI.KZN_MDM_HIERARQUIA)
    UNION ALL SELECT N''Linhas da PRD diferentes no DEV (deve ser 0)'', (SELECT COUNT_BIG(*) FROM (SELECT ' + @cols + N' FROM #PRD EXCEPT SELECT ' + @cols + N' FROM CI.KZN_MDM_HIERARQUIA) x);';
    EXEC sp_executesql @sql, N'@antes BIGINT', @antes = @antes;
    IF EXISTS (SELECT 1 FROM @DIF) PRINT N'MERGE concluído. Há AVISOS de estrutura na primeira grade.';
    ELSE PRINT N'MERGE concluído.';
END
ELSE
    RAISERROR(N'%s', 16, 1, @erro);

DROP TABLE IF EXISTS #PRD, #ACAO;
GO
