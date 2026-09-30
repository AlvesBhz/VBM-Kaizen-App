/* =====================================================================
   00 - PREPARAR  (executar conectado ao BDIBPBMSA_DEV)
   ---------------------------------------------------------------------
   Cria o schema de trabalho MIG (catálogo capturado, evidências e
   procedures) e a ligação de leitura com a PRD.

   Azure SQL Database não aceita nome de três partes entre bancos: a
   leitura da PRD usa Elastic Query (EXTERNAL DATA SOURCE TYPE = RDBMS).
   Elastic Query só aceita autenticação SQL na credencial — use o usuário
   de leitura criado pelo 00a_prd_usuario_leitura.sql.

   Pré-requisitos no Azure:
     - Firewall do servidor da PRD: permitir acesso de serviços do Azure
       (ou endpoint privado entre os servidores).
     - Usuário de leitura na PRD (00a).

   Nada aqui altera a PRD. Idempotente.
   ===================================================================== */

SET NOCOUNT ON;
SET XACT_ABORT ON;

/* ── PARÂMETROS ─────────────────────────────────────────────────────── */
DECLARE @MODO              VARCHAR(10)   = 'AZURE';   -- 'AZURE' (produção) | 'LOCAL' (teste na mesma instância)
DECLARE @SERVIDOR_ORIGEM   NVARCHAR(256) = N'rdb-ibp-bmsa-prd.database.windows.net';
DECLARE @BANCO_ORIGEM      SYSNAME       = N'BDIBPBMSA_PRD';
DECLARE @LOGIN_ORIGEM      NVARCHAR(128) = N'<usuario de leitura criado no 00a>';
DECLARE @SENHA_ORIGEM      NVARCHAR(256) = N'<senha do usuario de leitura>';
DECLARE @SENHA_MASTER_KEY  NVARCHAR(256) = N'<senha forte para a master key do DEV>';  -- só se o DEV ainda não tiver master key
DECLARE @RECRIAR           BIT           = 0;         -- 1 = apaga os objetos CI que JÁ existirem no DEV antes de criar (02)
/* ─────────────────────────────────────────────────────────────────── */

IF DB_NAME() = @BANCO_ORIGEM
BEGIN
    RAISERROR('Abortado: conectado na ORIGEM (%s). Conecte no BDIBPBMSA_DEV.', 16, 1, @BANCO_ORIGEM);
    RETURN;
END
IF @MODO NOT IN ('AZURE', 'LOCAL')
BEGIN
    RAISERROR('Abortado: @MODO deve ser AZURE ou LOCAL.', 16, 1);
    RETURN;
END

IF SCHEMA_ID('MIG') IS NULL EXEC (N'CREATE SCHEMA MIG AUTHORIZATION dbo;');
IF SCHEMA_ID('MIG_EXT') IS NULL EXEC (N'CREATE SCHEMA MIG_EXT AUTHORIZATION dbo;');

/* ── Ligação com a PRD ─────────────────────────────────────────────── */
DECLARE @criouMasterKey BIT = 0, @sql NVARCHAR(MAX);
IF @MODO = 'AZURE'
BEGIN
    IF @LOGIN_ORIGEM LIKE N'<%' OR @SENHA_ORIGEM LIKE N'<%'
    BEGIN
        RAISERROR('Abortado: preencha @LOGIN_ORIGEM e @SENHA_ORIGEM.', 16, 1);
        RETURN;
    END
    IF NOT EXISTS (SELECT 1 FROM sys.symmetric_keys WHERE name = N'##MS_DatabaseMasterKey##')
    BEGIN
        IF @SENHA_MASTER_KEY LIKE N'<%'
        BEGIN
            RAISERROR('Abortado: o DEV não tem master key. Preencha @SENHA_MASTER_KEY.', 16, 1);
            RETURN;
        END
        SET @sql = N'CREATE MASTER KEY ENCRYPTION BY PASSWORD = ' + QUOTENAME(@SENHA_MASTER_KEY, '''') + N';';
        EXEC (@sql);
        SET @criouMasterKey = 1;
    END

    IF EXISTS (SELECT 1 FROM sys.external_data_sources WHERE name = N'MIG_DS_PRD')
        EXEC (N'DROP EXTERNAL DATA SOURCE MIG_DS_PRD;');
    IF EXISTS (SELECT 1 FROM sys.database_scoped_credentials WHERE name = N'MIG_CRED_PRD')
        EXEC (N'DROP DATABASE SCOPED CREDENTIAL MIG_CRED_PRD;');

    SET @sql = N'CREATE DATABASE SCOPED CREDENTIAL MIG_CRED_PRD WITH IDENTITY = ' + QUOTENAME(@LOGIN_ORIGEM, '''')
             + N', SECRET = ' + QUOTENAME(@SENHA_ORIGEM, '''') + N';';
    EXEC (@sql);
    SET @sql = N'CREATE EXTERNAL DATA SOURCE MIG_DS_PRD WITH (TYPE = RDBMS, LOCATION = ' + QUOTENAME(@SERVIDOR_ORIGEM, '''')
             + N', DATABASE_NAME = ' + QUOTENAME(@BANCO_ORIGEM, '''') + N', CREDENTIAL = MIG_CRED_PRD);';
    EXEC (@sql);
END
ELSE IF DB_ID(@BANCO_ORIGEM) IS NULL
BEGIN
    RAISERROR('Abortado: modo LOCAL e o banco de origem %s não existe nesta instância.', 16, 1, @BANCO_ORIGEM);
    RETURN;
END

/* ── Tabelas de trabalho ───────────────────────────────────────────── */
IF OBJECT_ID('MIG.PARAMETRO') IS NULL
    CREATE TABLE MIG.PARAMETRO (MODO VARCHAR(10) NOT NULL, FONTE_DADOS SYSNAME NULL, BANCO_ORIGEM SYSNAME NOT NULL,
                                RECRIAR BIT NOT NULL, CRIOU_MASTER_KEY BIT NOT NULL, DT_PREPARO DATETIME2(0) NOT NULL);
DELETE MIG.PARAMETRO;
INSERT MIG.PARAMETRO VALUES (@MODO, CASE WHEN @MODO = 'AZURE' THEN N'MIG_DS_PRD' END, @BANCO_ORIGEM, @RECRIAR,
                             @criouMasterKey, SYSDATETIME());

IF OBJECT_ID('MIG.EVIDENCIA') IS NULL
    CREATE TABLE MIG.EVIDENCIA (ID INT IDENTITY PRIMARY KEY, DT DATETIME2(0) NOT NULL DEFAULT SYSDATETIME(),
        ETAPA VARCHAR(20) NOT NULL, ITEM NVARCHAR(400) NOT NULL, RESULTADO VARCHAR(10) NOT NULL, DETALHE NVARCHAR(MAX) NULL);
IF OBJECT_ID('MIG.CARGA_LOG') IS NULL
    CREATE TABLE MIG.CARGA_LOG (TABELA SYSNAME NOT NULL, NIVEL INT NOT NULL, ORDEM INT NOT NULL, LINHAS BIGINT NULL,
        INICIO DATETIME2(3) NULL, FIM DATETIME2(3) NULL, STATUS VARCHAR(10) NOT NULL, ERRO NVARCHAR(MAX) NULL);
IF OBJECT_ID('MIG.CONTAGEM') IS NULL
    CREATE TABLE MIG.CONTAGEM (ORIGEM CHAR(3) NULL, TABELA SYSNAME NULL, QTD BIGINT NULL, SOMA_VERIFICACAO INT NULL, SHARD NVARCHAR(500) NULL);
IF OBJECT_ID('MIG.DIFERENCA') IS NULL
    CREATE TABLE MIG.DIFERENCA (ENTIDADE VARCHAR(20) NOT NULL, LADO VARCHAR(10) NOT NULL, CHAVE NVARCHAR(800) NULL, DETALHE NVARCHAR(MAX) NULL);
IF OBJECT_ID('MIG.VIOLACAO') IS NULL
    CREATE TABLE MIG.VIOLACAO (TABELA NVARCHAR(400) NULL, [CONSTRAINT] NVARCHAR(400) NULL, ONDE NVARCHAR(MAX) NULL);

/* Catálogo capturado. ORIGEM = 'PRD' | 'DEV'. SHARD é a última coluna
   porque o sp_execute_remote acrescenta $ShardName ao resultado. */
IF OBJECT_ID('MIG.CAT_BANCO') IS NULL
    CREATE TABLE MIG.CAT_BANCO (ORIGEM CHAR(3) NULL, COLLATION_ NVARCHAR(128) NULL, COMPAT INT NULL, SHARD NVARCHAR(500) NULL);
IF OBJECT_ID('MIG.CAT_TABELA') IS NULL
    CREATE TABLE MIG.CAT_TABELA (ORIGEM CHAR(3) NULL, TABELA SYSNAME NULL, NAO_SUPORTADO NVARCHAR(4000) NULL,
        ESCALONAMENTO NVARCHAR(60) NULL, COMPRESSAO_HEAP NVARCHAR(60) NULL, LINHAS_CATALOGO BIGINT NULL, SHARD NVARCHAR(500) NULL);
IF OBJECT_ID('MIG.CAT_COLUNA') IS NULL
    CREATE TABLE MIG.CAT_COLUNA (ORIGEM CHAR(3) NULL, TABELA SYSNAME NULL, ORDEM INT NULL, COLUNA SYSNAME NULL,
        TIPO NVARCHAR(300) NULL, COLLATION_ NVARCHAR(128) NULL, NULO BIT NULL, IDENTIDADE BIT NULL, SEMENTE NVARCHAR(40) NULL,
        INCREMENTO NVARCHAR(40) NULL, IDENT_NFR BIT NULL, ULTIMO_IDENTITY NVARCHAR(40) NULL, CALCULADA BIT NULL,
        DEF_CALCULADA NVARCHAR(MAX) NULL, PERSISTIDA BIT NULL, NM_DEFAULT SYSNAME NULL, DEF_DEFAULT NVARCHAR(MAX) NULL,
        ROWGUIDCOL_ BIT NULL, ESPARSA BIT NULL, MASCARA NVARCHAR(4000) NULL, ROWVERSION_ BIT NULL, SHARD NVARCHAR(500) NULL);
IF OBJECT_ID('MIG.CAT_CHAVE') IS NULL
    CREATE TABLE MIG.CAT_CHAVE (ORIGEM CHAR(3) NULL, TABELA SYSNAME NULL, NOME SYSNAME NULL, TIPO CHAR(2) NULL,
        AGRUPAMENTO NVARCHAR(60) NULL, COLUNAS NVARCHAR(4000) NULL, OPCOES NVARCHAR(4000) NULL, SHARD NVARCHAR(500) NULL);
IF OBJECT_ID('MIG.CAT_INDICE') IS NULL
    CREATE TABLE MIG.CAT_INDICE (ORIGEM CHAR(3) NULL, OBJETO SYSNAME NULL, OBJETO_TIPO CHAR(2) NULL, NOME SYSNAME NULL,
        TIPO NVARCHAR(60) NULL, UNICO BIT NULL, COLUNAS NVARCHAR(4000) NULL, INCLUIDAS NVARCHAR(4000) NULL,
        FILTRO NVARCHAR(MAX) NULL, OPCOES NVARCHAR(4000) NULL, DESABILITADO BIT NULL, SHARD NVARCHAR(500) NULL);
IF OBJECT_ID('MIG.CAT_CHECK') IS NULL
    CREATE TABLE MIG.CAT_CHECK (ORIGEM CHAR(3) NULL, TABELA SYSNAME NULL, NOME SYSNAME NULL, DEFINICAO NVARCHAR(MAX) NULL,
        DESABILITADA BIT NULL, NAO_CONFIAVEL BIT NULL, NAO_REPLICACAO BIT NULL, SHARD NVARCHAR(500) NULL);
IF OBJECT_ID('MIG.CAT_FK') IS NULL
    CREATE TABLE MIG.CAT_FK (ORIGEM CHAR(3) NULL, TABELA SYSNAME NULL, NOME SYSNAME NULL, COLUNAS NVARCHAR(4000) NULL,
        REF_ESQUEMA SYSNAME NULL, REF_TABELA SYSNAME NULL, REF_COLUNAS NVARCHAR(4000) NULL, ACAO_DELETE NVARCHAR(60) NULL,
        ACAO_UPDATE NVARCHAR(60) NULL, DESABILITADA BIT NULL, NAO_CONFIAVEL BIT NULL, NAO_REPLICACAO BIT NULL, SHARD NVARCHAR(500) NULL);
IF OBJECT_ID('MIG.CAT_MODULO') IS NULL
    CREATE TABLE MIG.CAT_MODULO (ORIGEM CHAR(3) NULL, NOME SYSNAME NULL, TIPO CHAR(2) NULL, TABELA_PAI SYSNAME NULL,
        DEFINICAO NVARCHAR(MAX) NULL, ANSI_NULLS_ BIT NULL, QUOTED_ID BIT NULL, SCHEMABINDING_ BIT NULL, DESABILITADO BIT NULL,
        INSTEAD_OF BIT NULL, ORDEM_TRIGGER NVARCHAR(400) NULL, CRIADO DATETIME2(3) NULL, SHARD NVARCHAR(500) NULL);
IF OBJECT_ID('MIG.CAT_SEQUENCIA') IS NULL
    CREATE TABLE MIG.CAT_SEQUENCIA (ORIGEM CHAR(3) NULL, NOME SYSNAME NULL, TIPO NVARCHAR(128) NULL, INICIO NVARCHAR(40) NULL,
        INCREMENTO NVARCHAR(40) NULL, MINIMO NVARCHAR(40) NULL, MAXIMO NVARCHAR(40) NULL, CICLO BIT NULL, CACHE_ NVARCHAR(40) NULL,
        PROXIMO NVARCHAR(40) NULL, SHARD NVARCHAR(500) NULL);
IF OBJECT_ID('MIG.CAT_SINONIMO') IS NULL
    CREATE TABLE MIG.CAT_SINONIMO (ORIGEM CHAR(3) NULL, NOME SYSNAME NULL, BASE NVARCHAR(1035) NULL, SHARD NVARCHAR(500) NULL);
IF OBJECT_ID('MIG.CAT_EXTPROP') IS NULL
    CREATE TABLE MIG.CAT_EXTPROP (ORIGEM CHAR(3) NULL, OBJETO SYSNAME NULL, OBJETO_TIPO CHAR(2) NULL, PAI SYSNAME NULL,
        NIVEL2_TIPO NVARCHAR(20) NULL, NIVEL2 SYSNAME NULL, NOME SYSNAME NULL, VALOR NVARCHAR(4000) NULL, SHARD NVARCHAR(500) NULL);
IF OBJECT_ID('MIG.CAT_DEPEXT') IS NULL
    CREATE TABLE MIG.CAT_DEPEXT (ORIGEM CHAR(3) NULL, TIPO NVARCHAR(40) NULL, OBJETO_FORA NVARCHAR(600) NULL,
        OBJETO_CI NVARCHAR(600) NULL, DETALHE NVARCHAR(600) NULL, SHARD NVARCHAR(500) NULL);
IF OBJECT_ID('MIG.CAT_PERMISSAO') IS NULL
    CREATE TABLE MIG.CAT_PERMISSAO (ORIGEM CHAR(3) NULL, PRINCIPAL SYSNAME NULL, PERMISSAO NVARCHAR(128) NULL,
        ESTADO NVARCHAR(60) NULL, OBJETO NVARCHAR(600) NULL, SHARD NVARCHAR(500) NULL);
GO

/* ── Execução na PRD (remota) e no DEV (local) ──────────────────────
   Toda leitura da PRD passa por aqui. AZURE: sp_execute_remote na fonte
   externa. LOCAL: sp_executesql do banco de origem, na mesma instância
   (só para teste). Nos dois casos a última coluna é o SHARD. */
CREATE OR ALTER PROCEDURE MIG.SP_EXEC_ORIGEM @sql NVARCHAR(MAX) AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @modo VARCHAR(10), @ds SYSNAME, @banco SYSNAME;
    SELECT @modo = MODO, @ds = FONTE_DADOS, @banco = BANCO_ORIGEM FROM MIG.PARAMETRO;
    IF @modo = 'AZURE'
        EXEC sp_execute_remote @data_source_name = @ds, @stmt = @sql;
    ELSE
    BEGIN
        DECLARE @q NVARCHAR(MAX) = N'SELECT q.*, CAST(N''LOCAL'' AS NVARCHAR(500)) AS SHARD FROM (' + @sql + N') q;';
        DECLARE @proc NVARCHAR(400) = QUOTENAME(@banco) + N'.sys.sp_executesql';
        EXEC @proc @q;
    END
END;
GO

CREATE OR ALTER PROCEDURE MIG.SP_EXEC_DESTINO @sql NVARCHAR(MAX) AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @q NVARCHAR(MAX) = N'SELECT q.*, CAST(N''DEV'' AS NVARCHAR(500)) AS SHARD FROM (' + @sql + N') q;';
    EXEC sp_executesql @q;
END;
GO

CREATE OR ALTER PROCEDURE MIG.SP_EVIDENCIA @etapa VARCHAR(20), @item NVARCHAR(400), @resultado VARCHAR(10), @detalhe NVARCHAR(MAX) = NULL AS
BEGIN
    SET NOCOUNT ON;
    INSERT MIG.EVIDENCIA (ETAPA, ITEM, RESULTADO, DETALHE) VALUES (@etapa, @item, @resultado, @detalhe);
END;
GO

/* ── Captura do catálogo do schema CI ─────────────────────────────────
   As mesmas consultas rodam na PRD e no DEV: o que se compara na
   validação é a MESMA representação dos dois lados. Nomes vindos do
   catálogo usam COLLATE DATABASE_DEFAULT antes de concatenar (a collation
   do catálogo pode diferir da do banco no Azure SQL — Msg 468/4191). */
CREATE OR ALTER PROCEDURE MIG.SP_SNAPSHOT @origem CHAR(3) AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @exec SYSNAME = CASE @origem WHEN 'PRD' THEN N'MIG.SP_EXEC_ORIGEM' ELSE N'MIG.SP_EXEC_DESTINO' END;
    DECLARE @q NVARCHAR(MAX);

    DELETE MIG.CAT_BANCO WHERE ORIGEM = @origem;     DELETE MIG.CAT_TABELA WHERE ORIGEM = @origem;
    DELETE MIG.CAT_COLUNA WHERE ORIGEM = @origem;    DELETE MIG.CAT_CHAVE WHERE ORIGEM = @origem;
    DELETE MIG.CAT_INDICE WHERE ORIGEM = @origem;    DELETE MIG.CAT_CHECK WHERE ORIGEM = @origem;
    DELETE MIG.CAT_FK WHERE ORIGEM = @origem;        DELETE MIG.CAT_MODULO WHERE ORIGEM = @origem;
    DELETE MIG.CAT_SEQUENCIA WHERE ORIGEM = @origem; DELETE MIG.CAT_SINONIMO WHERE ORIGEM = @origem;
    DELETE MIG.CAT_EXTPROP WHERE ORIGEM = @origem;   DELETE MIG.CAT_DEPEXT WHERE ORIGEM = @origem;
    DELETE MIG.CAT_PERMISSAO WHERE ORIGEM = @origem;

    SET @q = N'SELECT COLLATION_ = CAST(DATABASEPROPERTYEX(DB_NAME(), ''Collation'') AS NVARCHAR(128)) COLLATE DATABASE_DEFAULT,
                      COMPAT = (SELECT compatibility_level FROM sys.databases WHERE database_id = DB_ID())';
    INSERT MIG.CAT_BANCO (COLLATION_, COMPAT, SHARD) EXEC @exec @q;

    SET @q = N'SELECT TABELA = t.name COLLATE DATABASE_DEFAULT,
        NAO_SUPORTADO = NULLIF(CONCAT_WS(N'', '',
            CASE WHEN t.is_memory_optimized = 1 THEN N''memory-optimized'' END,
            CASE WHEN t.temporal_type <> 0 THEN N''temporal'' END,
            CASE WHEN t.is_node = 1 OR t.is_edge = 1 THEN N''graph'' END,
            CASE WHEN t.ledger_type <> 0 THEN N''ledger'' END,
            CASE WHEN t.is_external = 1 THEN N''external table'' END,
            CASE WHEN EXISTS (SELECT 1 FROM sys.indexes i JOIN sys.data_spaces ds ON ds.data_space_id = i.data_space_id
                              WHERE i.object_id = t.object_id AND ds.type = ''PS'') THEN N''particionada'' END,
            CASE WHEN EXISTS (SELECT 1 FROM sys.indexes i WHERE i.object_id = t.object_id AND i.type IN (3,4,5,6,7))
                 THEN N''indice xml/espacial/columnstore/hash'' END,
            CASE WHEN EXISTS (SELECT 1 FROM sys.columns c JOIN sys.types ty ON ty.user_type_id = c.user_type_id
                              WHERE c.object_id = t.object_id
                                AND (ty.is_user_defined = 1 OR c.is_filestream = 1 OR c.is_column_set = 1
                                     OR c.generated_always_type <> 0 OR c.encryption_type IS NOT NULL
                                     OR ty.name IN (''xml'',''geography'',''geometry'',''hierarchyid'',''sql_variant'',''text'',''ntext'',''image'')))
                 THEN N''tipo/atributo de coluna nao suportado'' END), N''''),
        ESCALONAMENTO = t.lock_escalation_desc COLLATE DATABASE_DEFAULT,
        COMPRESSAO_HEAP = (SELECT p.data_compression_desc COLLATE DATABASE_DEFAULT FROM sys.partitions p
                           WHERE p.object_id = t.object_id AND p.index_id = 0 AND p.partition_number = 1),
        LINHAS_CATALOGO = (SELECT SUM(p.rows) FROM sys.partitions p WHERE p.object_id = t.object_id AND p.index_id IN (0,1))
      FROM sys.tables t WHERE t.schema_id = SCHEMA_ID(N''CI'')';
    INSERT MIG.CAT_TABELA (TABELA, NAO_SUPORTADO, ESCALONAMENTO, COMPRESSAO_HEAP, LINHAS_CATALOGO, SHARD) EXEC @exec @q;

    SET @q = N'SELECT TABELA = t.name COLLATE DATABASE_DEFAULT,
        ORDEM = ROW_NUMBER() OVER (PARTITION BY t.object_id ORDER BY c.column_id),
        COLUNA = c.name COLLATE DATABASE_DEFAULT,
        TIPO = CASE
            WHEN ty.name IN (''varchar'',''char'',''varbinary'',''binary'')
                 THEN ty.name COLLATE DATABASE_DEFAULT + N''('' + CASE WHEN c.max_length = -1 THEN N''max'' ELSE CAST(c.max_length AS NVARCHAR(10)) END + N'')''
            WHEN ty.name IN (''nvarchar'',''nchar'')
                 THEN ty.name COLLATE DATABASE_DEFAULT + N''('' + CASE WHEN c.max_length = -1 THEN N''max'' ELSE CAST(c.max_length / 2 AS NVARCHAR(10)) END + N'')''
            WHEN ty.name IN (''decimal'',''numeric'')
                 THEN ty.name COLLATE DATABASE_DEFAULT + N''('' + CAST(c.precision AS NVARCHAR(3)) + N'','' + CAST(c.scale AS NVARCHAR(3)) + N'')''
            WHEN ty.name IN (''datetime2'',''time'',''datetimeoffset'')
                 THEN ty.name COLLATE DATABASE_DEFAULT + N''('' + CAST(c.scale AS NVARCHAR(3)) + N'')''
            WHEN ty.name = ''float'' THEN N''float('' + CAST(c.precision AS NVARCHAR(3)) + N'')''
            ELSE ty.name COLLATE DATABASE_DEFAULT END,
        COLLATION_ = c.collation_name COLLATE DATABASE_DEFAULT,
        NULO = c.is_nullable, IDENTIDADE = c.is_identity,
        SEMENTE = CAST(ic.seed_value AS NVARCHAR(40)), INCREMENTO = CAST(ic.increment_value AS NVARCHAR(40)),
        IDENT_NFR = ic.is_not_for_replication, ULTIMO_IDENTITY = CAST(ic.last_value AS NVARCHAR(40)),
        CALCULADA = c.is_computed, DEF_CALCULADA = cc.definition COLLATE DATABASE_DEFAULT, PERSISTIDA = ISNULL(cc.is_persisted, 0),
        NM_DEFAULT = dc.name COLLATE DATABASE_DEFAULT, DEF_DEFAULT = dc.definition COLLATE DATABASE_DEFAULT,
        ROWGUIDCOL_ = c.is_rowguidcol, ESPARSA = c.is_sparse, MASCARA = mc.masking_function COLLATE DATABASE_DEFAULT,
        ROWVERSION_ = CASE WHEN ty.name = ''timestamp'' THEN 1 ELSE 0 END
      FROM sys.tables t
      JOIN sys.columns c ON c.object_id = t.object_id
      JOIN sys.types ty ON ty.user_type_id = c.user_type_id
      LEFT JOIN sys.identity_columns ic ON ic.object_id = c.object_id AND ic.column_id = c.column_id
      LEFT JOIN sys.computed_columns cc ON cc.object_id = c.object_id AND cc.column_id = c.column_id
      LEFT JOIN sys.default_constraints dc ON dc.object_id = c.default_object_id
      LEFT JOIN sys.masked_columns mc ON mc.object_id = c.object_id AND mc.column_id = c.column_id
      WHERE t.schema_id = SCHEMA_ID(N''CI'')';
    INSERT MIG.CAT_COLUNA (TABELA, ORDEM, COLUNA, TIPO, COLLATION_, NULO, IDENTIDADE, SEMENTE, INCREMENTO, IDENT_NFR,
        ULTIMO_IDENTITY, CALCULADA, DEF_CALCULADA, PERSISTIDA, NM_DEFAULT, DEF_DEFAULT, ROWGUIDCOL_, ESPARSA, MASCARA,
        ROWVERSION_, SHARD) EXEC @exec @q;

    /* Opções de índice numa forma única — usada no DDL e na comparação. */
    DECLARE @opcoes NVARCHAR(MAX) = N'CONCAT_WS(N'', '',
            N''PAD_INDEX = '' + CASE WHEN i.is_padded = 1 THEN N''ON'' ELSE N''OFF'' END,
            CASE WHEN i.fill_factor > 0 THEN N''FILLFACTOR = '' + CAST(i.fill_factor AS NVARCHAR(3)) END,
            N''IGNORE_DUP_KEY = '' + CASE WHEN i.ignore_dup_key = 1 THEN N''ON'' ELSE N''OFF'' END,
            N''STATISTICS_NORECOMPUTE = '' + CASE WHEN st.no_recompute = 1 THEN N''ON'' ELSE N''OFF'' END,
            N''ALLOW_ROW_LOCKS = '' + CASE WHEN i.allow_row_locks = 1 THEN N''ON'' ELSE N''OFF'' END,
            N''ALLOW_PAGE_LOCKS = '' + CASE WHEN i.allow_page_locks = 1 THEN N''ON'' ELSE N''OFF'' END,
            N''OPTIMIZE_FOR_SEQUENTIAL_KEY = '' + CASE WHEN i.optimize_for_sequential_key = 1 THEN N''ON'' ELSE N''OFF'' END,
            N''DATA_COMPRESSION = '' + p.data_compression_desc COLLATE DATABASE_DEFAULT)';
    DECLARE @colunasIndice NVARCHAR(MAX) = N'(SELECT STRING_AGG(QUOTENAME(c.name COLLATE DATABASE_DEFAULT)
                + CASE WHEN ic.is_descending_key = 1 THEN N'' DESC'' ELSE N'' ASC'' END, N'', '') WITHIN GROUP (ORDER BY ic.key_ordinal)
             FROM sys.index_columns ic JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
             WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.key_ordinal > 0)';

    SET @q = N'SELECT TABELA = t.name COLLATE DATABASE_DEFAULT, NOME = kc.name COLLATE DATABASE_DEFAULT,
        TIPO = kc.type COLLATE DATABASE_DEFAULT, AGRUPAMENTO = i.type_desc COLLATE DATABASE_DEFAULT,
        COLUNAS = ' + @colunasIndice + N', OPCOES = ' + @opcoes + N'
      FROM sys.key_constraints kc
      JOIN sys.tables t ON t.object_id = kc.parent_object_id
      JOIN sys.indexes i ON i.object_id = kc.parent_object_id AND i.index_id = kc.unique_index_id
      OUTER APPLY (SELECT s.no_recompute FROM sys.stats s WHERE s.object_id = i.object_id AND s.stats_id = i.index_id) st
      OUTER APPLY (SELECT TOP (1) pp.data_compression_desc FROM sys.partitions pp
                   WHERE pp.object_id = i.object_id AND pp.index_id = i.index_id ORDER BY pp.partition_number) p
      WHERE t.schema_id = SCHEMA_ID(N''CI'')';
    INSERT MIG.CAT_CHAVE (TABELA, NOME, TIPO, AGRUPAMENTO, COLUNAS, OPCOES, SHARD) EXEC @exec @q;

    SET @q = N'SELECT OBJETO = o.name COLLATE DATABASE_DEFAULT, OBJETO_TIPO = o.type COLLATE DATABASE_DEFAULT,
        NOME = i.name COLLATE DATABASE_DEFAULT, TIPO = i.type_desc COLLATE DATABASE_DEFAULT, UNICO = i.is_unique,
        COLUNAS = ' + @colunasIndice + N',
        INCLUIDAS = (SELECT STRING_AGG(QUOTENAME(c.name COLLATE DATABASE_DEFAULT), N'', '') WITHIN GROUP (ORDER BY ic.index_column_id)
                     FROM sys.index_columns ic JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
                     WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.is_included_column = 1),
        FILTRO = i.filter_definition COLLATE DATABASE_DEFAULT, OPCOES = ' + @opcoes + N', DESABILITADO = i.is_disabled
      FROM sys.indexes i
      JOIN sys.objects o ON o.object_id = i.object_id
      OUTER APPLY (SELECT s.no_recompute FROM sys.stats s WHERE s.object_id = i.object_id AND s.stats_id = i.index_id) st
      OUTER APPLY (SELECT TOP (1) pp.data_compression_desc FROM sys.partitions pp
                   WHERE pp.object_id = i.object_id AND pp.index_id = i.index_id ORDER BY pp.partition_number) p
      WHERE o.schema_id = SCHEMA_ID(N''CI'') AND o.type IN (''U'',''V'') AND i.type IN (1,2)
        AND i.is_primary_key = 0 AND i.is_unique_constraint = 0 AND i.is_hypothetical = 0';
    INSERT MIG.CAT_INDICE (OBJETO, OBJETO_TIPO, NOME, TIPO, UNICO, COLUNAS, INCLUIDAS, FILTRO, OPCOES, DESABILITADO, SHARD)
        EXEC @exec @q;

    SET @q = N'SELECT TABELA = t.name COLLATE DATABASE_DEFAULT, NOME = cc.name COLLATE DATABASE_DEFAULT,
        DEFINICAO = cc.definition COLLATE DATABASE_DEFAULT, DESABILITADA = cc.is_disabled, NAO_CONFIAVEL = cc.is_not_trusted,
        NAO_REPLICACAO = cc.is_not_for_replication
      FROM sys.check_constraints cc JOIN sys.tables t ON t.object_id = cc.parent_object_id
      WHERE t.schema_id = SCHEMA_ID(N''CI'')';
    INSERT MIG.CAT_CHECK (TABELA, NOME, DEFINICAO, DESABILITADA, NAO_CONFIAVEL, NAO_REPLICACAO, SHARD) EXEC @exec @q;

    SET @q = N'SELECT TABELA = t.name COLLATE DATABASE_DEFAULT, NOME = fk.name COLLATE DATABASE_DEFAULT,
        COLUNAS = (SELECT STRING_AGG(QUOTENAME(c.name COLLATE DATABASE_DEFAULT), N'', '') WITHIN GROUP (ORDER BY fc.constraint_column_id)
                   FROM sys.foreign_key_columns fc JOIN sys.columns c ON c.object_id = fc.parent_object_id AND c.column_id = fc.parent_column_id
                   WHERE fc.constraint_object_id = fk.object_id),
        REF_ESQUEMA = SCHEMA_NAME(rt.schema_id) COLLATE DATABASE_DEFAULT, REF_TABELA = rt.name COLLATE DATABASE_DEFAULT,
        REF_COLUNAS = (SELECT STRING_AGG(QUOTENAME(c.name COLLATE DATABASE_DEFAULT), N'', '') WITHIN GROUP (ORDER BY fc.constraint_column_id)
                   FROM sys.foreign_key_columns fc JOIN sys.columns c ON c.object_id = fc.referenced_object_id AND c.column_id = fc.referenced_column_id
                   WHERE fc.constraint_object_id = fk.object_id),
        ACAO_DELETE = REPLACE(fk.delete_referential_action_desc COLLATE DATABASE_DEFAULT, N''_'', N'' ''),
        ACAO_UPDATE = REPLACE(fk.update_referential_action_desc COLLATE DATABASE_DEFAULT, N''_'', N'' ''),
        DESABILITADA = fk.is_disabled, NAO_CONFIAVEL = fk.is_not_trusted, NAO_REPLICACAO = fk.is_not_for_replication
      FROM sys.foreign_keys fk
      JOIN sys.tables t ON t.object_id = fk.parent_object_id
      JOIN sys.tables rt ON rt.object_id = fk.referenced_object_id
      WHERE t.schema_id = SCHEMA_ID(N''CI'')';
    INSERT MIG.CAT_FK (TABELA, NOME, COLUNAS, REF_ESQUEMA, REF_TABELA, REF_COLUNAS, ACAO_DELETE, ACAO_UPDATE,
        DESABILITADA, NAO_CONFIAVEL, NAO_REPLICACAO, SHARD) EXEC @exec @q;

    SET @q = N'SELECT NOME = o.name COLLATE DATABASE_DEFAULT, TIPO = o.type COLLATE DATABASE_DEFAULT,
        TABELA_PAI = OBJECT_NAME(o.parent_object_id) COLLATE DATABASE_DEFAULT,
        DEFINICAO = m.definition COLLATE DATABASE_DEFAULT, ANSI_NULLS_ = m.uses_ansi_nulls, QUOTED_ID = m.uses_quoted_identifier,
        SCHEMABINDING_ = m.is_schema_bound, DESABILITADO = tr.is_disabled, INSTEAD_OF = tr.is_instead_of_trigger,
        ORDEM_TRIGGER = (SELECT STRING_AGG(te.type_desc COLLATE DATABASE_DEFAULT
                                + CASE WHEN te.is_first = 1 THEN N'':First'' ELSE N'':Last'' END, N'', '')
                         FROM sys.trigger_events te WHERE te.object_id = o.object_id AND (te.is_first = 1 OR te.is_last = 1)),
        CRIADO = o.create_date
      FROM sys.objects o
      LEFT JOIN sys.sql_modules m ON m.object_id = o.object_id
      LEFT JOIN sys.triggers tr ON tr.object_id = o.object_id
      WHERE o.schema_id = SCHEMA_ID(N''CI'') AND o.type IN (''V'',''P'',''FN'',''IF'',''TF'',''TR'',''R'',''D'',''PC'',''FS'',''FT'',''TA'')
        AND NOT (o.type = ''D'' AND o.parent_object_id <> 0)';
    INSERT MIG.CAT_MODULO (NOME, TIPO, TABELA_PAI, DEFINICAO, ANSI_NULLS_, QUOTED_ID, SCHEMABINDING_, DESABILITADO,
        INSTEAD_OF, ORDEM_TRIGGER, CRIADO, SHARD) EXEC @exec @q;

    SET @q = N'SELECT NOME = s.name COLLATE DATABASE_DEFAULT,
        TIPO = CASE WHEN TYPE_NAME(s.user_type_id) IN (''decimal'',''numeric'')
                    THEN TYPE_NAME(s.user_type_id) COLLATE DATABASE_DEFAULT + N''('' + CAST(s.precision AS NVARCHAR(3)) + N'',0)''
                    ELSE TYPE_NAME(s.user_type_id) COLLATE DATABASE_DEFAULT END,
        INICIO = CAST(s.start_value AS NVARCHAR(40)), INCREMENTO = CAST(s.increment AS NVARCHAR(40)),
        MINIMO = CAST(s.minimum_value AS NVARCHAR(40)), MAXIMO = CAST(s.maximum_value AS NVARCHAR(40)), CICLO = s.is_cycling,
        CACHE_ = CASE WHEN s.is_cached = 0 THEN N''NO CACHE'' ELSE ISNULL(CAST(s.cache_size AS NVARCHAR(40)), N''DEFAULT'') END,
        PROXIMO = CAST(CASE WHEN s.last_used_value IS NULL THEN CAST(s.current_value AS DECIMAL(38,0))
                            ELSE CAST(s.last_used_value AS DECIMAL(38,0)) + CAST(s.increment AS DECIMAL(38,0)) END AS NVARCHAR(40))
      FROM sys.sequences s WHERE s.schema_id = SCHEMA_ID(N''CI'')';
    INSERT MIG.CAT_SEQUENCIA (NOME, TIPO, INICIO, INCREMENTO, MINIMO, MAXIMO, CICLO, CACHE_, PROXIMO, SHARD) EXEC @exec @q;

    SET @q = N'SELECT NOME = sn.name COLLATE DATABASE_DEFAULT, BASE = sn.base_object_name COLLATE DATABASE_DEFAULT
      FROM sys.synonyms sn WHERE sn.schema_id = SCHEMA_ID(N''CI'')';
    INSERT MIG.CAT_SINONIMO (NOME, BASE, SHARD) EXEC @exec @q;

    /* Propriedades estendidas: objetos (classe 1, com coluna quando houver)
       e índices (classe 7). Constraint/trigger ficam no nível 2 do pai. */
    SET @q = N'SELECT OBJETO = COALESCE(pai.name, o.name) COLLATE DATABASE_DEFAULT,
        OBJETO_TIPO = COALESCE(pai.type, o.type) COLLATE DATABASE_DEFAULT,
        PAI = pai.name COLLATE DATABASE_DEFAULT,
        NIVEL2_TIPO = CASE WHEN ep.class = 7 THEN N''INDEX''
                           WHEN ep.minor_id > 0 THEN N''COLUMN''
                           WHEN pai.object_id IS NOT NULL AND o.type = ''TR'' THEN N''TRIGGER''
                           WHEN pai.object_id IS NOT NULL THEN N''CONSTRAINT'' END,
        NIVEL2 = CASE WHEN ep.class = 7 THEN ix.name
                      WHEN ep.minor_id > 0 THEN COL_NAME(ep.major_id, ep.minor_id)
                      WHEN pai.object_id IS NOT NULL THEN o.name END COLLATE DATABASE_DEFAULT,
        NOME = ep.name COLLATE DATABASE_DEFAULT, VALOR = CAST(ep.value AS NVARCHAR(4000))
      FROM sys.extended_properties ep
      JOIN sys.objects o ON o.object_id = ep.major_id
      LEFT JOIN sys.objects pai ON pai.object_id = o.parent_object_id AND o.parent_object_id <> 0
      LEFT JOIN sys.indexes ix ON ep.class = 7 AND ix.object_id = ep.major_id AND ix.index_id = ep.minor_id
      WHERE ep.class IN (1, 7) AND o.schema_id = SCHEMA_ID(N''CI'')';
    INSERT MIG.CAT_EXTPROP (OBJETO, OBJETO_TIPO, PAI, NIVEL2_TIPO, NIVEL2, NOME, VALOR, SHARD) EXEC @exec @q;

    /* Dependências que cruzam a fronteira do schema CI. */
    SET @q = N'SELECT TIPO = N''FK de fora -> CI'',
            OBJETO_FORA = SCHEMA_NAME(t.schema_id) COLLATE DATABASE_DEFAULT + N''.'' + t.name COLLATE DATABASE_DEFAULT,
            OBJETO_CI = rt.name COLLATE DATABASE_DEFAULT, DETALHE = fk.name COLLATE DATABASE_DEFAULT
        FROM sys.foreign_keys fk JOIN sys.tables t ON t.object_id = fk.parent_object_id JOIN sys.tables rt ON rt.object_id = fk.referenced_object_id
        WHERE rt.schema_id = SCHEMA_ID(N''CI'') AND t.schema_id <> SCHEMA_ID(N''CI'')
      UNION ALL
      SELECT N''FK de CI -> fora'', SCHEMA_NAME(rt.schema_id) COLLATE DATABASE_DEFAULT + N''.'' + rt.name COLLATE DATABASE_DEFAULT,
             t.name COLLATE DATABASE_DEFAULT, fk.name COLLATE DATABASE_DEFAULT
        FROM sys.foreign_keys fk JOIN sys.tables t ON t.object_id = fk.parent_object_id JOIN sys.tables rt ON rt.object_id = fk.referenced_object_id
        WHERE t.schema_id = SCHEMA_ID(N''CI'') AND rt.schema_id <> SCHEMA_ID(N''CI'')
      UNION ALL
      SELECT DISTINCT CASE WHEN m.is_schema_bound = 1 THEN N''Modulo de fora -> CI (SCHEMABINDING)'' ELSE N''Modulo de fora -> CI'' END,
             SCHEMA_NAME(o.schema_id) COLLATE DATABASE_DEFAULT + N''.'' + o.name COLLATE DATABASE_DEFAULT,
             d.referenced_entity_name COLLATE DATABASE_DEFAULT, o.type_desc COLLATE DATABASE_DEFAULT
        FROM sys.sql_expression_dependencies d JOIN sys.objects o ON o.object_id = d.referencing_id
        LEFT JOIN sys.sql_modules m ON m.object_id = o.object_id
        WHERE d.referenced_schema_name = N''CI'' AND d.referenced_database_name IS NULL AND o.schema_id <> SCHEMA_ID(N''CI'')
      UNION ALL
      SELECT DISTINCT N''Modulo de CI -> fora'',
             ISNULL(d.referenced_database_name COLLATE DATABASE_DEFAULT + N''.'', N'''') + ISNULL(d.referenced_schema_name COLLATE DATABASE_DEFAULT, N''?'') + N''.'' + d.referenced_entity_name COLLATE DATABASE_DEFAULT,
             o.name COLLATE DATABASE_DEFAULT, o.type_desc COLLATE DATABASE_DEFAULT
        FROM sys.sql_expression_dependencies d JOIN sys.objects o ON o.object_id = d.referencing_id
        WHERE o.schema_id = SCHEMA_ID(N''CI'')
          AND (d.referenced_database_name IS NOT NULL OR (d.referenced_schema_name IS NOT NULL AND d.referenced_schema_name <> N''CI''))
          AND d.referenced_class = 1';
    INSERT MIG.CAT_DEPEXT (TIPO, OBJETO_FORA, OBJETO_CI, DETALHE, SHARD) EXEC @exec @q;

    SET @q = N'SELECT PRINCIPAL = pr.name COLLATE DATABASE_DEFAULT, PERMISSAO = dp.permission_name COLLATE DATABASE_DEFAULT,
        ESTADO = dp.state_desc COLLATE DATABASE_DEFAULT,
        OBJETO = CASE WHEN dp.class = 3 THEN N''SCHEMA::CI'' ELSE N''CI.'' + OBJECT_NAME(dp.major_id) COLLATE DATABASE_DEFAULT END
      FROM sys.database_permissions dp JOIN sys.database_principals pr ON pr.principal_id = dp.grantee_principal_id
      WHERE (dp.class = 3 AND dp.major_id = SCHEMA_ID(N''CI''))
         OR (dp.class = 1 AND OBJECT_SCHEMA_NAME(dp.major_id) = N''CI'')';
    INSERT MIG.CAT_PERMISSAO (PRINCIPAL, PERMISSAO, ESTADO, OBJETO, SHARD) EXEC @exec @q;

    UPDATE MIG.CAT_BANCO SET ORIGEM = @origem WHERE ORIGEM IS NULL;     UPDATE MIG.CAT_TABELA SET ORIGEM = @origem WHERE ORIGEM IS NULL;
    UPDATE MIG.CAT_COLUNA SET ORIGEM = @origem WHERE ORIGEM IS NULL;    UPDATE MIG.CAT_CHAVE SET ORIGEM = @origem WHERE ORIGEM IS NULL;
    UPDATE MIG.CAT_INDICE SET ORIGEM = @origem WHERE ORIGEM IS NULL;    UPDATE MIG.CAT_CHECK SET ORIGEM = @origem WHERE ORIGEM IS NULL;
    UPDATE MIG.CAT_FK SET ORIGEM = @origem WHERE ORIGEM IS NULL;        UPDATE MIG.CAT_MODULO SET ORIGEM = @origem WHERE ORIGEM IS NULL;
    UPDATE MIG.CAT_SEQUENCIA SET ORIGEM = @origem WHERE ORIGEM IS NULL; UPDATE MIG.CAT_SINONIMO SET ORIGEM = @origem WHERE ORIGEM IS NULL;
    UPDATE MIG.CAT_EXTPROP SET ORIGEM = @origem WHERE ORIGEM IS NULL;   UPDATE MIG.CAT_DEPEXT SET ORIGEM = @origem WHERE ORIGEM IS NULL;
    UPDATE MIG.CAT_PERMISSAO SET ORIGEM = @origem WHERE ORIGEM IS NULL;
END;
GO

/* ── Teste de fumaça: a PRD responde e o INSERT...EXEC funciona ─────── */
DECLARE @t TABLE (BANCO SYSNAME, SHARD NVARCHAR(500));
BEGIN TRY
    INSERT @t EXEC MIG.SP_EXEC_ORIGEM N'SELECT BANCO = DB_NAME() COLLATE DATABASE_DEFAULT';
END TRY
BEGIN CATCH
    DECLARE @e NVARCHAR(2000) = N'Abortado: a PRD não respondeu pela ligação configurada: ' + ERROR_MESSAGE();
    RAISERROR(@e, 16, 1);
    RETURN;
END CATCH
DECLARE @banco SYSNAME = (SELECT TOP (1) BANCO FROM @t);
EXEC MIG.SP_EVIDENCIA '00', N'Ligação com a origem', 'OK', @banco;
SELECT ETAPA = '00', LIGACAO = 'OK', BANCO_ORIGEM = @banco, BANCO_DESTINO = DB_NAME(), MODO = (SELECT MODO FROM MIG.PARAMETRO);
GO
