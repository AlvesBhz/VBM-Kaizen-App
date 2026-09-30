/* =====================================================================
   MERGE CI.KZN_MDM_HIERARQUIA: BDIBPBMSA_PRD -> BDIBPBMSA_DEV
   (executar conectado ao BDIBPBMSA_DEV — na PRD só LÊ)
   ---------------------------------------------------------------------
   Deixa a KZN_MDM_HIERARQUIA do DEV igual à da PRD, casando por
   ID_USUARIO (único nas duas; é a coluna que as FKs das outras tabelas
   referenciam):
     - existe na PRD e não no DEV  -> INSERT;
     - existe nos dois e mudou     -> UPDATE de todas as colunas
       (DT_ATUALIZACAO vem da PRD; o trigger TR_KZN_MDM_HIERARQUIA_UPD
       não recarimba porque a coluna é atualizada no mesmo comando);
     - existe só no DEV            -> mantém (padrão) ou DELETE com
       @APAGAR_AUSENTES_NO_DEV = 1.
   Linhas iguais não são tocadas.

   Antes de gravar (nada é alterado se alguma falhar):
     - a estrutura da tabela é igual nos dois bancos;
     - todo ID_TIPO_USUARIO vindo da PRD existe em CI.KZN_TIPO_USUARIO
       do DEV (FK_KZN_MDM_TIPO_USUARIO).
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
        @proc NVARCHAR(400) = QUOTENAME(@BANCO_ORIGEM) + N'.sys.sp_executesql';
DECLARE @COL TABLE (LADO CHAR(3), COLUNA SYSNAME, ORDEM INT, TIPO SYSNAME, TAM INT, PREC INT, ESC INT, COLL SYSNAME NULL, NULO BIT);
DECLARE @PRD_COL TABLE (COLUNA SYSNAME, ORDEM INT, TIPO SYSNAME, TAM INT, PREC INT, ESC INT, COLL SYSNAME NULL, NULO BIT, SHARD NVARCHAR(500));
DECLARE @ACAO TABLE (ACAO NVARCHAR(10), ID_USUARIO INT);
DECLARE @antes BIGINT = (SELECT COUNT_BIG(*) FROM CI.KZN_MDM_HIERARQUIA);

/* Área de leitura: mesma definição da tabela */
CREATE TABLE #PRD (
    ID_USUARIO        INT                                          NOT NULL PRIMARY KEY,
    CD_MATRICULA      VARCHAR(30)  COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
    ID_TIPO_USUARIO   INT                                          NOT NULL,
    NM_USUARIO        VARCHAR(30)  COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
    CD_EMAIL          VARCHAR(100) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
    NM_SITUACAO       VARCHAR(30)  COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    SG_ATIVO          VARCHAR(1)   COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
    NM_POSICAO        VARCHAR(30)  COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    NM_EMPRESA        VARCHAR(30)  COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    NM_PAIS           VARCHAR(30)  COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    NM_ESTADO         VARCHAR(30)  COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    NM_CIDADE         VARCHAR(30)  COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    NM_SITE           VARCHAR(30)  COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    NM_HIERARQUIA_N1  VARCHAR(80)  COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    NM_HIERARQUIA_N2  VARCHAR(80)  COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    NM_HIERARQUIA_N3  VARCHAR(80)  COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    NM_HIERARQUIA_N4  VARCHAR(80)  COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    NM_HIERARQUIA_N5  VARCHAR(80)  COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    NM_HIERARQUIA_N6  VARCHAR(80)  COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    NM_HIERARQUIA_N7  VARCHAR(80)  COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    NM_HIERARQUIA_N8  VARCHAR(80)  COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    DT_ATUALIZACAO    DATETIME2(3)                                 NOT NULL
);

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
    SET @q = N'SELECT c.name, c.column_id, TYPE_NAME(c.user_type_id), c.max_length, c.precision, c.scale, c.collation_name, c.is_nullable
               FROM sys.columns c WHERE c.object_id = OBJECT_ID(N''CI.KZN_MDM_HIERARQUIA'')';
    IF @MODO = 'AZURE' INSERT @PRD_COL EXEC sp_execute_remote @data_source_name = N'MRG_DS_PRD', @stmt = @q;
    ELSE BEGIN SET @q = N'SELECT q.*, CAST(N''LOCAL'' AS NVARCHAR(500)) FROM (' + @q + N') q (a,b,c,d,e,f,g,h);'; INSERT @PRD_COL EXEC @proc @q; END

    IF NOT EXISTS (SELECT 1 FROM @PRD_COL)
        THROW 50001, N'A PRD respondeu, mas o usuário de leitura não enxerga CI.KZN_MDM_HIERARQUIA (falta GRANT SELECT/VIEW DEFINITION — ver 00a).', 1;

    INSERT @COL SELECT 'PRD', COLUNA, ORDEM, TIPO, TAM, PREC, ESC, COLL, NULO FROM @PRD_COL;
    INSERT @COL
    SELECT 'DEV', c.name, c.column_id, TYPE_NAME(c.user_type_id), c.max_length, c.precision, c.scale, c.collation_name, c.is_nullable
    FROM sys.columns c WHERE c.object_id = OBJECT_ID(N'CI.KZN_MDM_HIERARQUIA');
    /* e as duas iguais à área de leitura (#PRD) — garante que nenhuma coluna fica de fora do MERGE */
    INSERT @COL
    SELECT 'SCR', c.name, c.column_id, TYPE_NAME(c.user_type_id), c.max_length, c.precision, c.scale, c.collation_name, c.is_nullable
    FROM tempdb.sys.columns c WHERE c.object_id = OBJECT_ID(N'tempdb..#PRD');

    IF EXISTS (SELECT COLUNA, TIPO, TAM, PREC, ESC, COLL FROM @COL WHERE LADO = 'PRD'
               EXCEPT SELECT COLUNA, TIPO, TAM, PREC, ESC, COLL FROM @COL WHERE LADO = 'DEV')
       OR EXISTS (SELECT COLUNA, TIPO, TAM, PREC, ESC, COLL FROM @COL WHERE LADO = 'DEV'
               EXCEPT SELECT COLUNA, TIPO, TAM, PREC, ESC, COLL FROM @COL WHERE LADO = 'PRD')
       OR EXISTS (SELECT COLUNA, TIPO, TAM, PREC, ESC, COLL FROM @COL WHERE LADO = 'PRD'
               EXCEPT SELECT COLUNA, TIPO, TAM, PREC, ESC, COLL FROM @COL WHERE LADO = 'SCR')
    BEGIN
        SELECT COLUNA = ISNULL(p.COLUNA, d.COLUNA),
               NA_PRD = ISNULL(CONCAT(p.TIPO, N'(', p.TAM, N',', p.PREC, N',', p.ESC, N') ', p.COLL), N'(não existe)'),
               NO_DEV = ISNULL(CONCAT(d.TIPO, N'(', d.TAM, N',', d.PREC, N',', d.ESC, N') ', d.COLL), N'(não existe)')
        FROM (SELECT * FROM @COL WHERE LADO = 'PRD') p
        FULL JOIN (SELECT * FROM @COL WHERE LADO = 'DEV') d ON d.COLUNA = p.COLUNA
        WHERE p.COLUNA IS NULL OR d.COLUNA IS NULL OR p.TIPO <> d.TIPO OR p.TAM <> d.TAM OR p.PREC <> d.PREC OR p.ESC <> d.ESC
           OR ISNULL(p.COLL, N'') <> ISNULL(d.COLL, N'');
        THROW 50002, N'A estrutura de CI.KZN_MDM_HIERARQUIA difere entre PRD e DEV, ou deste script (lista acima). Nada foi alterado.', 1;
    END

    /* ── Leitura da PRD ─────────────────────────────────────────────── */
    SET @passo = N'ler os dados da PRD';
    IF @MODO = 'AZURE'
    BEGIN
        EXEC (N'CREATE EXTERNAL TABLE dbo.MRG_EXT_KZN_MDM_HIERARQUIA (
            ID_USUARIO INT NOT NULL, CD_MATRICULA VARCHAR(30) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
            ID_TIPO_USUARIO INT NOT NULL, NM_USUARIO VARCHAR(30) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
            CD_EMAIL VARCHAR(100) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL, NM_SITUACAO VARCHAR(30) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
            SG_ATIVO VARCHAR(1) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL, NM_POSICAO VARCHAR(30) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
            NM_EMPRESA VARCHAR(30) COLLATE SQL_Latin1_General_CP1_CI_AS NULL, NM_PAIS VARCHAR(30) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
            NM_ESTADO VARCHAR(30) COLLATE SQL_Latin1_General_CP1_CI_AS NULL, NM_CIDADE VARCHAR(30) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
            NM_SITE VARCHAR(30) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
            NM_HIERARQUIA_N1 VARCHAR(80) COLLATE SQL_Latin1_General_CP1_CI_AS NULL, NM_HIERARQUIA_N2 VARCHAR(80) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
            NM_HIERARQUIA_N3 VARCHAR(80) COLLATE SQL_Latin1_General_CP1_CI_AS NULL, NM_HIERARQUIA_N4 VARCHAR(80) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
            NM_HIERARQUIA_N5 VARCHAR(80) COLLATE SQL_Latin1_General_CP1_CI_AS NULL, NM_HIERARQUIA_N6 VARCHAR(80) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
            NM_HIERARQUIA_N7 VARCHAR(80) COLLATE SQL_Latin1_General_CP1_CI_AS NULL, NM_HIERARQUIA_N8 VARCHAR(80) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
            DT_ATUALIZACAO DATETIME2(3) NOT NULL
        ) WITH (DATA_SOURCE = MRG_DS_PRD, SCHEMA_NAME = N''CI'', OBJECT_NAME = N''KZN_MDM_HIERARQUIA'');');
        SET @sql = N'INSERT INTO #PRD (ID_USUARIO, CD_MATRICULA, ID_TIPO_USUARIO, NM_USUARIO, CD_EMAIL, NM_SITUACAO, SG_ATIVO, NM_POSICAO, NM_EMPRESA, NM_PAIS, NM_ESTADO, NM_CIDADE, NM_SITE, NM_HIERARQUIA_N1, NM_HIERARQUIA_N2, NM_HIERARQUIA_N3, NM_HIERARQUIA_N4, NM_HIERARQUIA_N5, NM_HIERARQUIA_N6, NM_HIERARQUIA_N7, NM_HIERARQUIA_N8, DT_ATUALIZACAO) SELECT ID_USUARIO, CD_MATRICULA, ID_TIPO_USUARIO, NM_USUARIO, CD_EMAIL, NM_SITUACAO, SG_ATIVO, NM_POSICAO, NM_EMPRESA, NM_PAIS, NM_ESTADO, NM_CIDADE, NM_SITE, NM_HIERARQUIA_N1, NM_HIERARQUIA_N2, NM_HIERARQUIA_N3, NM_HIERARQUIA_N4, NM_HIERARQUIA_N5, NM_HIERARQUIA_N6, NM_HIERARQUIA_N7, NM_HIERARQUIA_N8, DT_ATUALIZACAO FROM dbo.MRG_EXT_KZN_MDM_HIERARQUIA;';
    END
    ELSE
        SET @sql = N'INSERT INTO #PRD (ID_USUARIO, CD_MATRICULA, ID_TIPO_USUARIO, NM_USUARIO, CD_EMAIL, NM_SITUACAO, SG_ATIVO, NM_POSICAO, NM_EMPRESA, NM_PAIS, NM_ESTADO, NM_CIDADE, NM_SITE, NM_HIERARQUIA_N1, NM_HIERARQUIA_N2, NM_HIERARQUIA_N3, NM_HIERARQUIA_N4, NM_HIERARQUIA_N5, NM_HIERARQUIA_N6, NM_HIERARQUIA_N7, NM_HIERARQUIA_N8, DT_ATUALIZACAO) SELECT ID_USUARIO, CD_MATRICULA, ID_TIPO_USUARIO, NM_USUARIO, CD_EMAIL, NM_SITUACAO, SG_ATIVO, NM_POSICAO,
                         NM_EMPRESA, NM_PAIS, NM_ESTADO, NM_CIDADE, NM_SITE, NM_HIERARQUIA_N1, NM_HIERARQUIA_N2, NM_HIERARQUIA_N3,
                         NM_HIERARQUIA_N4, NM_HIERARQUIA_N5, NM_HIERARQUIA_N6, NM_HIERARQUIA_N7, NM_HIERARQUIA_N8, DT_ATUALIZACAO
                     FROM ' + QUOTENAME(@BANCO_ORIGEM) + N'.CI.KZN_MDM_HIERARQUIA;';
    EXEC (@sql);

    /* ── Pré-validação: tipo de usuário ─────────────────────────────── */
    IF EXISTS (SELECT 1 FROM #PRD p WHERE NOT EXISTS (SELECT 1 FROM CI.KZN_TIPO_USUARIO t WHERE t.ID_TIPO_USUARIO = p.ID_TIPO_USUARIO))
    BEGIN
        SELECT ID_TIPO_USUARIO_FALTANDO_NO_DEV = p.ID_TIPO_USUARIO, USUARIOS_DA_PRD = COUNT(*)
        FROM #PRD p WHERE NOT EXISTS (SELECT 1 FROM CI.KZN_TIPO_USUARIO t WHERE t.ID_TIPO_USUARIO = p.ID_TIPO_USUARIO)
        GROUP BY p.ID_TIPO_USUARIO;
        THROW 50003, N'Há ID_TIPO_USUARIO da PRD que não existe em CI.KZN_TIPO_USUARIO do DEV (lista acima). Cadastre-o no DEV e rode de novo. Nada foi alterado.', 1;
    END

    /* ── MERGE ──────────────────────────────────────────────────────── */
    SET @passo = N'gravar no DEV';
    BEGIN TRANSACTION;

    MERGE CI.KZN_MDM_HIERARQUIA WITH (HOLDLOCK) AS t
    USING #PRD AS s
       ON t.ID_USUARIO = s.ID_USUARIO
    WHEN MATCHED AND EXISTS (
            SELECT s.CD_MATRICULA, s.ID_TIPO_USUARIO, s.NM_USUARIO, s.CD_EMAIL, s.NM_SITUACAO, s.SG_ATIVO, s.NM_POSICAO, s.NM_EMPRESA,
                   s.NM_PAIS, s.NM_ESTADO, s.NM_CIDADE, s.NM_SITE, s.NM_HIERARQUIA_N1, s.NM_HIERARQUIA_N2, s.NM_HIERARQUIA_N3,
                   s.NM_HIERARQUIA_N4, s.NM_HIERARQUIA_N5, s.NM_HIERARQUIA_N6, s.NM_HIERARQUIA_N7, s.NM_HIERARQUIA_N8, s.DT_ATUALIZACAO
            EXCEPT
            SELECT t.CD_MATRICULA, t.ID_TIPO_USUARIO, t.NM_USUARIO, t.CD_EMAIL, t.NM_SITUACAO, t.SG_ATIVO, t.NM_POSICAO, t.NM_EMPRESA,
                   t.NM_PAIS, t.NM_ESTADO, t.NM_CIDADE, t.NM_SITE, t.NM_HIERARQUIA_N1, t.NM_HIERARQUIA_N2, t.NM_HIERARQUIA_N3,
                   t.NM_HIERARQUIA_N4, t.NM_HIERARQUIA_N5, t.NM_HIERARQUIA_N6, t.NM_HIERARQUIA_N7, t.NM_HIERARQUIA_N8, t.DT_ATUALIZACAO)
        THEN UPDATE SET
            t.CD_MATRICULA = s.CD_MATRICULA, t.ID_TIPO_USUARIO = s.ID_TIPO_USUARIO, t.NM_USUARIO = s.NM_USUARIO, t.CD_EMAIL = s.CD_EMAIL,
            t.NM_SITUACAO = s.NM_SITUACAO, t.SG_ATIVO = s.SG_ATIVO, t.NM_POSICAO = s.NM_POSICAO, t.NM_EMPRESA = s.NM_EMPRESA,
            t.NM_PAIS = s.NM_PAIS, t.NM_ESTADO = s.NM_ESTADO, t.NM_CIDADE = s.NM_CIDADE, t.NM_SITE = s.NM_SITE,
            t.NM_HIERARQUIA_N1 = s.NM_HIERARQUIA_N1, t.NM_HIERARQUIA_N2 = s.NM_HIERARQUIA_N2, t.NM_HIERARQUIA_N3 = s.NM_HIERARQUIA_N3,
            t.NM_HIERARQUIA_N4 = s.NM_HIERARQUIA_N4, t.NM_HIERARQUIA_N5 = s.NM_HIERARQUIA_N5, t.NM_HIERARQUIA_N6 = s.NM_HIERARQUIA_N6,
            t.NM_HIERARQUIA_N7 = s.NM_HIERARQUIA_N7, t.NM_HIERARQUIA_N8 = s.NM_HIERARQUIA_N8, t.DT_ATUALIZACAO = s.DT_ATUALIZACAO
    WHEN NOT MATCHED BY TARGET THEN
        INSERT (ID_USUARIO, CD_MATRICULA, ID_TIPO_USUARIO, NM_USUARIO, CD_EMAIL, NM_SITUACAO, SG_ATIVO, NM_POSICAO, NM_EMPRESA,
                NM_PAIS, NM_ESTADO, NM_CIDADE, NM_SITE, NM_HIERARQUIA_N1, NM_HIERARQUIA_N2, NM_HIERARQUIA_N3, NM_HIERARQUIA_N4,
                NM_HIERARQUIA_N5, NM_HIERARQUIA_N6, NM_HIERARQUIA_N7, NM_HIERARQUIA_N8, DT_ATUALIZACAO)
        VALUES (s.ID_USUARIO, s.CD_MATRICULA, s.ID_TIPO_USUARIO, s.NM_USUARIO, s.CD_EMAIL, s.NM_SITUACAO, s.SG_ATIVO, s.NM_POSICAO,
                s.NM_EMPRESA, s.NM_PAIS, s.NM_ESTADO, s.NM_CIDADE, s.NM_SITE, s.NM_HIERARQUIA_N1, s.NM_HIERARQUIA_N2, s.NM_HIERARQUIA_N3,
                s.NM_HIERARQUIA_N4, s.NM_HIERARQUIA_N5, s.NM_HIERARQUIA_N6, s.NM_HIERARQUIA_N7, s.NM_HIERARQUIA_N8, s.DT_ATUALIZACAO)
    WHEN NOT MATCHED BY SOURCE AND @APAGAR_AUSENTES_NO_DEV = 1 THEN
        DELETE
    OUTPUT $action, ISNULL(inserted.ID_USUARIO, deleted.ID_USUARIO) INTO @ACAO (ACAO, ID_USUARIO);

    /* Conferência antes de confirmar: toda linha da PRD está igual no DEV */
    IF EXISTS (SELECT ID_USUARIO, CD_MATRICULA, ID_TIPO_USUARIO, NM_USUARIO, CD_EMAIL, NM_SITUACAO, SG_ATIVO, NM_POSICAO, NM_EMPRESA, NM_PAIS, NM_ESTADO, NM_CIDADE, NM_SITE, NM_HIERARQUIA_N1, NM_HIERARQUIA_N2, NM_HIERARQUIA_N3, NM_HIERARQUIA_N4, NM_HIERARQUIA_N5, NM_HIERARQUIA_N6, NM_HIERARQUIA_N7, NM_HIERARQUIA_N8, DT_ATUALIZACAO FROM #PRD
               EXCEPT
               SELECT ID_USUARIO, CD_MATRICULA, ID_TIPO_USUARIO, NM_USUARIO, CD_EMAIL, NM_SITUACAO, SG_ATIVO, NM_POSICAO, NM_EMPRESA, NM_PAIS, NM_ESTADO, NM_CIDADE, NM_SITE, NM_HIERARQUIA_N1, NM_HIERARQUIA_N2, NM_HIERARQUIA_N3, NM_HIERARQUIA_N4, NM_HIERARQUIA_N5, NM_HIERARQUIA_N6, NM_HIERARQUIA_N7, NM_HIERARQUIA_N8, DT_ATUALIZACAO FROM CI.KZN_MDM_HIERARQUIA)
        THROW 50004, N'Após o MERGE ainda há linhas da PRD diferentes no DEV. Nada foi gravado.', 1;

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
    SELECT ITEM = N'Linhas na PRD', QTD = (SELECT COUNT_BIG(*) FROM #PRD)
    UNION ALL SELECT N'Linhas no DEV antes', @antes
    UNION ALL SELECT N'Inseridas', (SELECT COUNT_BIG(*) FROM @ACAO WHERE ACAO = N'INSERT')
    UNION ALL SELECT N'Atualizadas', (SELECT COUNT_BIG(*) FROM @ACAO WHERE ACAO = N'UPDATE')
    UNION ALL SELECT N'Apagadas (só existiam no DEV)', (SELECT COUNT_BIG(*) FROM @ACAO WHERE ACAO = N'DELETE')
    UNION ALL SELECT N'Mantidas (só existem no DEV)', (SELECT COUNT_BIG(*) FROM CI.KZN_MDM_HIERARQUIA t WHERE NOT EXISTS (SELECT 1 FROM #PRD p WHERE p.ID_USUARIO = t.ID_USUARIO))
    UNION ALL SELECT N'Linhas no DEV depois', (SELECT COUNT_BIG(*) FROM CI.KZN_MDM_HIERARQUIA)
    UNION ALL SELECT N'Linhas da PRD diferentes no DEV (deve ser 0)', (SELECT COUNT_BIG(*) FROM (
        SELECT ID_USUARIO, CD_MATRICULA, ID_TIPO_USUARIO, NM_USUARIO, CD_EMAIL, NM_SITUACAO, SG_ATIVO, NM_POSICAO, NM_EMPRESA, NM_PAIS, NM_ESTADO, NM_CIDADE, NM_SITE, NM_HIERARQUIA_N1, NM_HIERARQUIA_N2, NM_HIERARQUIA_N3, NM_HIERARQUIA_N4, NM_HIERARQUIA_N5, NM_HIERARQUIA_N6, NM_HIERARQUIA_N7, NM_HIERARQUIA_N8, DT_ATUALIZACAO FROM #PRD
        EXCEPT
        SELECT ID_USUARIO, CD_MATRICULA, ID_TIPO_USUARIO, NM_USUARIO, CD_EMAIL, NM_SITUACAO, SG_ATIVO, NM_POSICAO, NM_EMPRESA, NM_PAIS, NM_ESTADO, NM_CIDADE, NM_SITE, NM_HIERARQUIA_N1, NM_HIERARQUIA_N2, NM_HIERARQUIA_N3, NM_HIERARQUIA_N4, NM_HIERARQUIA_N5, NM_HIERARQUIA_N6, NM_HIERARQUIA_N7, NM_HIERARQUIA_N8, DT_ATUALIZACAO FROM CI.KZN_MDM_HIERARQUIA) x);
    PRINT N'MERGE concluído.';
END
ELSE
    RAISERROR(N'%s', 16, 1, @erro);

DROP TABLE IF EXISTS #PRD;
GO
