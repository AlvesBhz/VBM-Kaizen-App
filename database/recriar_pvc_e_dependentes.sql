/* =====================================================================
   RECRIAR do zero CI.KZN_PEDRAVISAOCONSOLIDADA e suas dependentes
   ---------------------------------------------------------------------
   *** APAGA DADOS DE FORMA DEFINITIVA - USO EM TESTE/VALIDACAO ***

   Derruba e recria, ja no formato final (ID_STATUS, DS_MOTIVO e os
   campos de texto em VARCHAR(300)), as 7 tabelas do bloco do Kaizen:

     DROP  (dependentes primeiro)      CREATE (o pai primeiro)
     1. KZN_LOG_..._DETALHE            1. KZN_PEDRAVISAOCONSOLIDADA
     2. KZN_LOG_PEDRAVISAOCONSOLIDADA  2. KZN_LOG_PEDRAVISAOCONSOLIDADA
     3. KZN_MEMBROS_EQUIPE             3. KZN_LOG_..._DETALHE
     4. KZN_RESULTADO_KAIZEN           4. KZN_MEMBROS_EQUIPE
     5. KZN_KAIZEN_HIERARQUIA          5. KZN_RESULTADO_KAIZEN
     6. KZN_KAIZEN_DESPERDICIO         6. KZN_KAIZEN_HIERARQUIA
     7. KZN_PEDRAVISAOCONSOLIDADA      7. KZN_KAIZEN_DESPERDICIO

   NAO toca nas tabelas de cadastro (KZN_STATUS, KZN_CATEGORIA,
   KZN_MDM_HIERARQUIA, KZN_APROVADOR, KZN_MOEDA, ...): elas sao o
   destino das FKs, nao dependentes.

   TRAVA: a ETAPA 1 (DROP) so roda com @CONFIRMO = 'SIM'. Sem isso o
   script nao apaga nada, e as etapas seguintes viram no-op (as tabelas
   ja existem). Ajuste a variavel logo abaixo.

   Os CREATE e os triggers abaixo sao copia fiel do script completo
   (DDL_SCRIPT_DB.sql), secoes 13 a 17b, 18 e 19.

   Schema: 'CI'.
   ===================================================================== */

SET NOCOUNT ON;
SET XACT_ABORT ON;

/* =====================================================================
   ETAPA 1 - DROP (ordem inversa das dependencias)
   ===================================================================== */
DECLARE @CONFIRMO VARCHAR(3) = 'NAO';   -- <<< troque para 'SIM' para apagar de verdade

IF @CONFIRMO <> 'SIM'
BEGIN
    PRINT 'ETAPA 1 NAO executada - @CONFIRMO diferente de ''SIM''. Nada foi apagado.';
    PRINT 'As etapas seguintes so criam o que estiver faltando.';
END
ELSE
BEGIN
    -- Derruba qualquer FK que aponte para as 7 tabelas, venha de onde vier
    DECLARE @sqlFk nvarchar(max) = N'';
    SELECT @sqlFk = @sqlFk + N'ALTER TABLE ' + QUOTENAME(OBJECT_SCHEMA_NAME(fk.parent_object_id)) + N'.'
                  + QUOTENAME(OBJECT_NAME(fk.parent_object_id)) + N' DROP CONSTRAINT ' + QUOTENAME(fk.name) + N';'
    FROM   sys.foreign_keys fk
    WHERE  fk.referenced_object_id IN (
               OBJECT_ID('CI.KZN_PEDRAVISAOCONSOLIDADA'), OBJECT_ID('CI.KZN_LOG_PEDRAVISAOCONSOLIDADA'),
               OBJECT_ID('CI.KZN_LOG_PEDRAVISAOCONSOLIDADA_DETALHE'), OBJECT_ID('CI.KZN_MEMBROS_EQUIPE'),
               OBJECT_ID('CI.KZN_RESULTADO_KAIZEN'), OBJECT_ID('CI.KZN_KAIZEN_HIERARQUIA'),
               OBJECT_ID('CI.KZN_KAIZEN_DESPERDICIO'));
    IF @sqlFk <> N'' EXEC sp_executesql @sqlFk;

    DROP TABLE IF EXISTS CI.KZN_LOG_PEDRAVISAOCONSOLIDADA_DETALHE;
    DROP TABLE IF EXISTS CI.KZN_LOG_PEDRAVISAOCONSOLIDADA;
    DROP TABLE IF EXISTS CI.KZN_MEMBROS_EQUIPE;
    DROP TABLE IF EXISTS CI.KZN_RESULTADO_KAIZEN;
    DROP TABLE IF EXISTS CI.KZN_KAIZEN_HIERARQUIA;
    DROP TABLE IF EXISTS CI.KZN_KAIZEN_DESPERDICIO;
    DROP TABLE IF EXISTS CI.KZN_PEDRAVISAOCONSOLIDADA;

    -- Tabelas vazias de novo: as sequences do log voltam a contar do 1
    IF EXISTS (SELECT 1 FROM sys.sequences WHERE schema_id = SCHEMA_ID('CI') AND name = 'SEQ_KZN_LOG_PVC')
        ALTER SEQUENCE CI.SEQ_KZN_LOG_PVC RESTART WITH 1;
    IF EXISTS (SELECT 1 FROM sys.sequences WHERE schema_id = SCHEMA_ID('CI') AND name = 'SEQ_KZN_LOG_PVC_DETALHE')
        ALTER SEQUENCE CI.SEQ_KZN_LOG_PVC_DETALHE RESTART WITH 1;

    PRINT 'ETAPA 1 ok - 7 tabelas removidas e sequences reiniciadas.';
END
GO

/* =====================================================================
   ETAPA 2 - Sequences do log (criadas se ainda nao existirem)
   ===================================================================== */
IF NOT EXISTS (SELECT 1 FROM sys.sequences WHERE schema_id = SCHEMA_ID('CI') AND name = 'SEQ_KZN_LOG_PVC')
    CREATE SEQUENCE CI.SEQ_KZN_LOG_PVC AS INT START WITH 1 INCREMENT BY 1;
IF NOT EXISTS (SELECT 1 FROM sys.sequences WHERE schema_id = SCHEMA_ID('CI') AND name = 'SEQ_KZN_LOG_PVC_DETALHE')
    CREATE SEQUENCE CI.SEQ_KZN_LOG_PVC_DETALHE AS INT START WITH 1 INCREMENT BY 1;
GO

/* =====================================================================
   ETAPA 3 - CREATE (o pai primeiro, depois as dependentes)
   ===================================================================== */
/* --- 1. CI.KZN_PEDRAVISAOCONSOLIDADA --- */
IF OBJECT_ID('CI.KZN_PEDRAVISAOCONSOLIDADA', 'U') IS NULL
BEGIN
    CREATE TABLE CI.KZN_PEDRAVISAOCONSOLIDADA
    (
        ID_KAIZEN                  INT                             NOT NULL,
        ID_USUARIO_CADASTRO        INT                             NOT NULL,   -- FK -> MDM: quem registrou
        ID_USUARIO_LIDER           INT                             NOT NULL,   -- FK -> MDM: líder do Kaizen  -- ASSUNÇÃO: NOT NULL
        NM_KAIZEN                  VARCHAR(30)                     NOT NULL,
        ID_CATEGORIA               INT                             NOT NULL,
        ID_REPLICACAO              INT                                 NULL,   -- ASSUNÇÃO: opcional
        DS_PROBLEMA                VARCHAR(300)                        NULL,
        DS_OBJETIVO                VARCHAR(300)                        NULL,
        ID_STATUS                  INT                                 NULL,   -- status do Kaizen (CI.KZN_STATUS). Sem FK de banco: KZN_STATUS tem PK composta (ID_STATUS, ID_IDIOMA) e o SQL Server não permite FK pra parte de chave composta — mesma regra já aplicada a ID_CATEGORIA/ID_REPLICACAO/ID_DESPERDICIO/ID_MOTIVO
        ID_APROVADOR               INT                                 NULL,   -- só preenchido quando alguém aprova/reprova
        URL_IMG_ANTES               VARCHAR(300)                       NULL,
        DS_ESTADO_ANTES            VARCHAR(300)                        NULL,
        URL_IMG_DEPOIS              VARCHAR(300)                       NULL,
        DS_ESTADO_DEPOIS           VARCHAR(300)                        NULL,
        URL_REFERENCIA             VARCHAR(300)                       NULL,
        ID_DESPERDICIO             INT                                 NULL,
        DS_LICOES_APRENDIDAS       VARCHAR(300)                        NULL,
        VL_RESULTADO_FINANCEIRO    DECIMAL(18,2)                      NULL,
        ID_MOEDA                   INT                                 NULL,
        DS_RESULTADO_ESPERADO      VARCHAR(300)                        NULL,
        DT_CRIACAO                 DATETIME2(3)                    NOT NULL
            CONSTRAINT DF_KZN_PVC_DT_CRIACAO DEFAULT (SYSDATETIME()),
        DT_CONCLUSAO               DATE                                NULL,
        DS_MOTIVO                  VARCHAR(300)                        NULL,   -- justificativa da reprovação, em texto livre (antes era ID_MOTIVO -> CI.KZN_MOTIVO_REPROVACAO, tabela aposentada)
        DT_ATUALIZACAO             DATETIME2(3)                    NOT NULL
            CONSTRAINT DF_KZN_PVC_DT_ATUALIZACAO DEFAULT (SYSDATETIME()),
        ID_USUARIO_ATUALIZACAO     INT                             NOT NULL,   -- app envia a cada INSERT/UPDATE (quem está agindo)

        CONSTRAINT PK_KZN_PVC                      PRIMARY KEY CLUSTERED (ID_KAIZEN),
        CONSTRAINT FK_KZN_PVC_USUARIO_CADASTRO     FOREIGN KEY (ID_USUARIO_CADASTRO)
            REFERENCES CI.KZN_MDM_HIERARQUIA (ID_USUARIO),
        CONSTRAINT FK_KZN_PVC_USUARIO_LIDER        FOREIGN KEY (ID_USUARIO_LIDER)
            REFERENCES CI.KZN_MDM_HIERARQUIA (ID_USUARIO),
        CONSTRAINT FK_KZN_PVC_USUARIO_ATUALIZACAO  FOREIGN KEY (ID_USUARIO_ATUALIZACAO)
            REFERENCES CI.KZN_MDM_HIERARQUIA (ID_USUARIO),
        -- ID_CATEGORIA, ID_REPLICACAO e ID_DESPERDICIO NÃO têm FK de banco:
        -- as tabelas de destino agora têm PK composta (ID_X, ID_IDIOMA) e o SQL Server não
        -- permite FK apontando para parte de uma chave composta; a integridade referencial
        -- dessas colunas fica sob responsabilidade da aplicação (decisão confirmada com o time)
        CONSTRAINT FK_KZN_PVC_APROVADOR            FOREIGN KEY (ID_APROVADOR)
            REFERENCES CI.KZN_APROVADOR (ID_APROVADOR),
        CONSTRAINT FK_KZN_PVC_MOEDA                FOREIGN KEY (ID_MOEDA)
            REFERENCES CI.KZN_MOEDA (ID_MOEDA)
        -- CK_KZN_PVC_STATUS removido: o domínio de status deixou de ser uma
        -- lista fixa de strings e passou a ser a tabela CI.KZN_STATUS
    );

    CREATE NONCLUSTERED INDEX IX_KZN_PVC_STATUS        ON CI.KZN_PEDRAVISAOCONSOLIDADA (ID_STATUS);
    CREATE NONCLUSTERED INDEX IX_KZN_PVC_CATEGORIA     ON CI.KZN_PEDRAVISAOCONSOLIDADA (ID_CATEGORIA);
    CREATE NONCLUSTERED INDEX IX_KZN_PVC_USUARIO_LIDER ON CI.KZN_PEDRAVISAOCONSOLIDADA (ID_USUARIO_LIDER);
END
GO

/* --- 2. CI.KZN_LOG_PEDRAVISAOCONSOLIDADA --- */
IF OBJECT_ID('CI.KZN_LOG_PEDRAVISAOCONSOLIDADA', 'U') IS NULL
BEGIN
    CREATE TABLE CI.KZN_LOG_PEDRAVISAOCONSOLIDADA
    (
        ID_LOG                INT                             NOT NULL,
        ID_KAIZEN             INT                             NOT NULL,
        TP_OPERACAO           CHAR(1)                         NOT NULL,   -- 'C' Criado / 'A' Atualizado
        DT_OPERACAO           DATETIME2(3)                    NOT NULL
            CONSTRAINT DF_KZN_LOG_PVC_DT_OPERACAO DEFAULT (SYSDATETIME()),
        ID_USUARIO_OPERACAO   INT                             NOT NULL,

        CONSTRAINT PK_KZN_LOG_PVC           PRIMARY KEY CLUSTERED (ID_LOG),
        CONSTRAINT FK_KZN_LOG_PVC_KAIZEN    FOREIGN KEY (ID_KAIZEN)
            REFERENCES CI.KZN_PEDRAVISAOCONSOLIDADA (ID_KAIZEN),
        CONSTRAINT FK_KZN_LOG_PVC_USUARIO   FOREIGN KEY (ID_USUARIO_OPERACAO)
            REFERENCES CI.KZN_MDM_HIERARQUIA (ID_USUARIO),
        CONSTRAINT CK_KZN_LOG_PVC_TIPO      CHECK (TP_OPERACAO IN ('C','A'))
    );

    CREATE NONCLUSTERED INDEX IX_KZN_LOG_PVC_KAIZEN
        ON CI.KZN_LOG_PEDRAVISAOCONSOLIDADA (ID_KAIZEN, DT_OPERACAO DESC);
END
GO

/* --- 3. CI.KZN_LOG_PEDRAVISAOCONSOLIDADA_DETALHE --- */
IF OBJECT_ID('CI.KZN_LOG_PEDRAVISAOCONSOLIDADA_DETALHE', 'U') IS NULL
BEGIN
    CREATE TABLE CI.KZN_LOG_PEDRAVISAOCONSOLIDADA_DETALHE
    (
        ID_LOG_DETALHE   INT                             NOT NULL,
        ID_LOG           INT                             NOT NULL,
        NM_CAMPO         VARCHAR(30)                     NOT NULL,   -- nome da coluna alterada, ex.: 'ID_STATUS'
        VL_ANTERIOR      VARCHAR(300)                        NULL,   -- ASSUNÇÃO: texto — ver comentário acima; 300 acompanha o maior VARCHAR auditado em KZN_PEDRAVISAOCONSOLIDADA
        VL_NOVO          VARCHAR(300)                        NULL,

        CONSTRAINT PK_KZN_LOG_PVC_DETALHE PRIMARY KEY CLUSTERED (ID_LOG_DETALHE),
        CONSTRAINT FK_KZN_LOG_PVC_DETALHE_LOG FOREIGN KEY (ID_LOG)
            REFERENCES CI.KZN_LOG_PEDRAVISAOCONSOLIDADA (ID_LOG)
    );

    CREATE NONCLUSTERED INDEX IX_KZN_LOG_PVC_DETALHE_LOG
        ON CI.KZN_LOG_PEDRAVISAOCONSOLIDADA_DETALHE (ID_LOG, NM_CAMPO);
END
GO

/* --- 4. CI.KZN_MEMBROS_EQUIPE --- */
IF OBJECT_ID('CI.KZN_MEMBROS_EQUIPE', 'U') IS NULL
BEGIN
    CREATE TABLE CI.KZN_MEMBROS_EQUIPE
    (
        ID_KAIZEN       INT                             NOT NULL,
        ID_USUARIO      INT                             NOT NULL,
        DT_ATUALIZACAO  DATETIME2(7)                        NULL,

        CONSTRAINT PK_KZN_MEMBROS_EQUIPE           PRIMARY KEY CLUSTERED (ID_KAIZEN, ID_USUARIO),
        CONSTRAINT FK_KZN_MEMBROS_EQUIPE_KAIZEN    FOREIGN KEY (ID_KAIZEN)
            REFERENCES CI.KZN_PEDRAVISAOCONSOLIDADA (ID_KAIZEN) ON DELETE CASCADE
        -- ID_USUARIO NÃO tem FK de banco: CI.KZN_MDM_HIERARQUIA não tem
        -- UNIQUE/PK cobrindo ID_USUARIO sozinho (confirmado — ver correção acima)
    );
END
GO

/* --- 5. CI.KZN_RESULTADO_KAIZEN --- */
IF OBJECT_ID('CI.KZN_RESULTADO_KAIZEN', 'U') IS NULL
BEGIN
    CREATE TABLE CI.KZN_RESULTADO_KAIZEN
    (
        ID_KAIZEN       INT                             NOT NULL,
        ID_RESULTADO    INT                             NOT NULL,
        URL_ICONE       VARCHAR(200)                        NULL,
        DT_ATUALIZACAO  DATETIME2(3)                    NOT NULL
            CONSTRAINT DF_KZN_RESULTADO_KAIZEN_DT_ATUALIZACAO DEFAULT (SYSDATETIME()),

        CONSTRAINT PK_KZN_RESULTADO_KAIZEN          PRIMARY KEY CLUSTERED (ID_KAIZEN, ID_RESULTADO),
        CONSTRAINT FK_KZN_RESULTADO_KAIZEN_KAIZEN   FOREIGN KEY (ID_KAIZEN)
            REFERENCES CI.KZN_PEDRAVISAOCONSOLIDADA (ID_KAIZEN)
        -- ID_RESULTADO NÃO tem FK de banco: KZN_RESULTADOS agora tem PK composta
        -- (ID_RESULTADO, ID_IDIOMA); integridade fica sob responsabilidade da aplicação
    );
END
GO

/* --- 6. CI.KZN_KAIZEN_HIERARQUIA --- */
IF OBJECT_ID('CI.KZN_KAIZEN_HIERARQUIA', 'U') IS NULL
BEGIN
    CREATE TABLE CI.KZN_KAIZEN_HIERARQUIA
    (
        ID_KAIZEN_HIERARQUIA   INT                             NOT NULL,
        ID_KAIZEN              INT                             NOT NULL,
        NM_HIERARQUIA_N1       VARCHAR(80)                         NULL,
        NM_HIERARQUIA_N2       VARCHAR(80)                         NULL,
        NM_HIERARQUIA_N3       VARCHAR(80)                         NULL,
        NM_HIERARQUIA_N4       VARCHAR(80)                         NULL,
        NM_HIERARQUIA_N5       VARCHAR(80)                         NULL,
        NM_HIERARQUIA_N6       VARCHAR(80)                         NULL,
        NM_HIERARQUIA_N7       VARCHAR(80)                         NULL,
        NM_HIERARQUIA_N8       VARCHAR(80)                         NULL,
        DT_ATUALIZACAO         DATETIME2(3)                    NOT NULL
            CONSTRAINT DF_KZN_KAIZEN_HIERARQUIA_DT_ATUALIZACAO DEFAULT (SYSDATETIME()),

        CONSTRAINT PK_KZN_KAIZEN_HIERARQUIA        PRIMARY KEY CLUSTERED (ID_KAIZEN_HIERARQUIA),
        CONSTRAINT FK_KZN_KAIZEN_HIERARQUIA_KAIZEN FOREIGN KEY (ID_KAIZEN)
            REFERENCES CI.KZN_PEDRAVISAOCONSOLIDADA (ID_KAIZEN)
    );

    CREATE NONCLUSTERED INDEX IX_KZN_KAIZEN_HIERARQUIA_KAIZEN
        ON CI.KZN_KAIZEN_HIERARQUIA (ID_KAIZEN);
END
GO

/* --- 7. CI.KZN_KAIZEN_DESPERDICIO --- */
IF OBJECT_ID('CI.KZN_KAIZEN_DESPERDICIO', 'U') IS NULL
BEGIN
    CREATE TABLE CI.KZN_KAIZEN_DESPERDICIO
    (
        ID_KAIZEN       INT                             NOT NULL,
        ID_DESPERDICIO  INT                             NOT NULL,
        DT_ATUALIZACAO  DATETIME2(7)                    NOT NULL
            CONSTRAINT DF_KZN_KZDESP_DT_ATUALIZACAO DEFAULT (SYSDATETIME()),

        CONSTRAINT PK_KZN_KZDESP        PRIMARY KEY CLUSTERED (ID_KAIZEN, ID_DESPERDICIO),
        CONSTRAINT FK_KZN_KZDESP_KAIZEN FOREIGN KEY (ID_KAIZEN)
            REFERENCES CI.KZN_PEDRAVISAOCONSOLIDADA (ID_KAIZEN)
        -- ID_DESPERDICIO NÃO tem FK de banco: KZN_DESPERDICIO tem PK composta
        -- (ID_DESPERDICIO, ID_IDIOMA); integridade fica sob responsabilidade da aplicação
    );
END
GO

/* =====================================================================
   ETAPA 4 - TRIGGERS (vao junto com as tabelas no DROP)
   ===================================================================== */
CREATE OR ALTER TRIGGER CI.TR_KZN_PVC_INS ON CI.KZN_PEDRAVISAOCONSOLIDADA AFTER INSERT AS
BEGIN
    SET NOCOUNT ON;
    INSERT INTO CI.KZN_LOG_PEDRAVISAOCONSOLIDADA (ID_LOG, ID_KAIZEN, TP_OPERACAO, DT_OPERACAO, ID_USUARIO_OPERACAO)
    SELECT NEXT VALUE FOR CI.SEQ_KZN_LOG_PVC, ID_KAIZEN, 'C', DT_CRIACAO, ID_USUARIO_CADASTRO
    FROM inserted;
    -- Sem linha de detalhe aqui: criação não tem "valor anterior" a comparar.
END
GO

CREATE OR ALTER TRIGGER CI.TR_KZN_PVC_UPD ON CI.KZN_PEDRAVISAOCONSOLIDADA AFTER UPDATE AS
BEGIN
    SET NOCOUNT ON;

    IF NOT UPDATE(DT_ATUALIZACAO)
        UPDATE T SET DT_ATUALIZACAO = SYSDATETIME()
        FROM CI.KZN_PEDRAVISAOCONSOLIDADA T JOIN inserted i ON i.ID_KAIZEN = T.ID_KAIZEN;

    -- Uma linha de cabeçalho de log por Kaizen afetado, capturando o
    -- ID_LOG recém-gerado (OUTPUT) pra ligar as linhas de detalhe geradas
    -- logo abaixo — necessário porque um único UPDATE pode afetar mais de
    -- um Kaizen de uma vez, cada um com seu próprio ID_LOG.
    DECLARE @logMap TABLE (ID_KAIZEN INT NOT NULL PRIMARY KEY, ID_LOG INT NOT NULL);

    -- Relê DT_ATUALIZACAO já corrigida acima, pra não gravar um SYSDATETIME()
    -- ligeiramente diferente do que efetivamente ficou salvo na linha.
    INSERT INTO CI.KZN_LOG_PEDRAVISAOCONSOLIDADA (ID_LOG, ID_KAIZEN, TP_OPERACAO, DT_OPERACAO, ID_USUARIO_OPERACAO)
    OUTPUT inserted.ID_KAIZEN, inserted.ID_LOG INTO @logMap (ID_KAIZEN, ID_LOG)
    SELECT NEXT VALUE FOR CI.SEQ_KZN_LOG_PVC, i.ID_KAIZEN, 'A', T.DT_ATUALIZACAO, i.ID_USUARIO_ATUALIZACAO
    FROM inserted i
    JOIN CI.KZN_PEDRAVISAOCONSOLIDADA T ON T.ID_KAIZEN = i.ID_KAIZEN;

    -- Diff campo a campo (seção 14b) — 1 linha por coluna de negócio cujo
    -- valor mudou nesta atualização. Comparação NULL-segura: "NOT (d.COL =
    -- i.COL OR (d.COL IS NULL AND i.COL IS NULL))" trata NULL=NULL como
    -- "não mudou" e qualquer outra combinação (incluindo um lado NULL) como
    -- mudança. DT_ATUALIZACAO e ID_USUARIO_ATUALIZACAO ficam de fora: já
    -- são o metadado do cabeçalho gravado acima, não conteúdo auditado.
    INSERT INTO CI.KZN_LOG_PEDRAVISAOCONSOLIDADA_DETALHE (ID_LOG_DETALHE, ID_LOG, NM_CAMPO, VL_ANTERIOR, VL_NOVO)
    SELECT NEXT VALUE FOR CI.SEQ_KZN_LOG_PVC_DETALHE, x.ID_LOG, x.NM_CAMPO, x.VL_ANTERIOR, x.VL_NOVO
    FROM (
        SELECT lm.ID_LOG, 'ID_USUARIO_CADASTRO' AS NM_CAMPO, CONVERT(VARCHAR(300), d.ID_USUARIO_CADASTRO) AS VL_ANTERIOR, CONVERT(VARCHAR(300), i.ID_USUARIO_CADASTRO) AS VL_NOVO
        FROM inserted i JOIN deleted d ON d.ID_KAIZEN = i.ID_KAIZEN JOIN @logMap lm ON lm.ID_KAIZEN = i.ID_KAIZEN
        WHERE NOT (d.ID_USUARIO_CADASTRO = i.ID_USUARIO_CADASTRO OR (d.ID_USUARIO_CADASTRO IS NULL AND i.ID_USUARIO_CADASTRO IS NULL))
        UNION ALL
        SELECT lm.ID_LOG, 'ID_USUARIO_LIDER', CONVERT(VARCHAR(300), d.ID_USUARIO_LIDER), CONVERT(VARCHAR(300), i.ID_USUARIO_LIDER)
        FROM inserted i JOIN deleted d ON d.ID_KAIZEN = i.ID_KAIZEN JOIN @logMap lm ON lm.ID_KAIZEN = i.ID_KAIZEN
        WHERE NOT (d.ID_USUARIO_LIDER = i.ID_USUARIO_LIDER OR (d.ID_USUARIO_LIDER IS NULL AND i.ID_USUARIO_LIDER IS NULL))
        UNION ALL
        SELECT lm.ID_LOG, 'NM_KAIZEN', CONVERT(VARCHAR(300), d.NM_KAIZEN), CONVERT(VARCHAR(300), i.NM_KAIZEN)
        FROM inserted i JOIN deleted d ON d.ID_KAIZEN = i.ID_KAIZEN JOIN @logMap lm ON lm.ID_KAIZEN = i.ID_KAIZEN
        WHERE NOT (d.NM_KAIZEN = i.NM_KAIZEN OR (d.NM_KAIZEN IS NULL AND i.NM_KAIZEN IS NULL))
        UNION ALL
        SELECT lm.ID_LOG, 'ID_CATEGORIA', CONVERT(VARCHAR(300), d.ID_CATEGORIA), CONVERT(VARCHAR(300), i.ID_CATEGORIA)
        FROM inserted i JOIN deleted d ON d.ID_KAIZEN = i.ID_KAIZEN JOIN @logMap lm ON lm.ID_KAIZEN = i.ID_KAIZEN
        WHERE NOT (d.ID_CATEGORIA = i.ID_CATEGORIA OR (d.ID_CATEGORIA IS NULL AND i.ID_CATEGORIA IS NULL))
        UNION ALL
        SELECT lm.ID_LOG, 'ID_REPLICACAO', CONVERT(VARCHAR(300), d.ID_REPLICACAO), CONVERT(VARCHAR(300), i.ID_REPLICACAO)
        FROM inserted i JOIN deleted d ON d.ID_KAIZEN = i.ID_KAIZEN JOIN @logMap lm ON lm.ID_KAIZEN = i.ID_KAIZEN
        WHERE NOT (d.ID_REPLICACAO = i.ID_REPLICACAO OR (d.ID_REPLICACAO IS NULL AND i.ID_REPLICACAO IS NULL))
        UNION ALL
        SELECT lm.ID_LOG, 'DS_PROBLEMA', CONVERT(VARCHAR(300), d.DS_PROBLEMA), CONVERT(VARCHAR(300), i.DS_PROBLEMA)
        FROM inserted i JOIN deleted d ON d.ID_KAIZEN = i.ID_KAIZEN JOIN @logMap lm ON lm.ID_KAIZEN = i.ID_KAIZEN
        WHERE NOT (d.DS_PROBLEMA = i.DS_PROBLEMA OR (d.DS_PROBLEMA IS NULL AND i.DS_PROBLEMA IS NULL))
        UNION ALL
        SELECT lm.ID_LOG, 'DS_OBJETIVO', CONVERT(VARCHAR(300), d.DS_OBJETIVO), CONVERT(VARCHAR(300), i.DS_OBJETIVO)
        FROM inserted i JOIN deleted d ON d.ID_KAIZEN = i.ID_KAIZEN JOIN @logMap lm ON lm.ID_KAIZEN = i.ID_KAIZEN
        WHERE NOT (d.DS_OBJETIVO = i.DS_OBJETIVO OR (d.DS_OBJETIVO IS NULL AND i.DS_OBJETIVO IS NULL))
        UNION ALL
        SELECT lm.ID_LOG, 'ID_STATUS', CONVERT(VARCHAR(300), d.ID_STATUS), CONVERT(VARCHAR(300), i.ID_STATUS)
        FROM inserted i JOIN deleted d ON d.ID_KAIZEN = i.ID_KAIZEN JOIN @logMap lm ON lm.ID_KAIZEN = i.ID_KAIZEN
        WHERE NOT (d.ID_STATUS = i.ID_STATUS OR (d.ID_STATUS IS NULL AND i.ID_STATUS IS NULL))
        UNION ALL
        SELECT lm.ID_LOG, 'ID_APROVADOR', CONVERT(VARCHAR(300), d.ID_APROVADOR), CONVERT(VARCHAR(300), i.ID_APROVADOR)
        FROM inserted i JOIN deleted d ON d.ID_KAIZEN = i.ID_KAIZEN JOIN @logMap lm ON lm.ID_KAIZEN = i.ID_KAIZEN
        WHERE NOT (d.ID_APROVADOR = i.ID_APROVADOR OR (d.ID_APROVADOR IS NULL AND i.ID_APROVADOR IS NULL))
        UNION ALL
        SELECT lm.ID_LOG, 'URL_IMG_ANTES', CONVERT(VARCHAR(300), d.URL_IMG_ANTES), CONVERT(VARCHAR(300), i.URL_IMG_ANTES)
        FROM inserted i JOIN deleted d ON d.ID_KAIZEN = i.ID_KAIZEN JOIN @logMap lm ON lm.ID_KAIZEN = i.ID_KAIZEN
        WHERE NOT (d.URL_IMG_ANTES = i.URL_IMG_ANTES OR (d.URL_IMG_ANTES IS NULL AND i.URL_IMG_ANTES IS NULL))
        UNION ALL
        SELECT lm.ID_LOG, 'DS_ESTADO_ANTES', CONVERT(VARCHAR(300), d.DS_ESTADO_ANTES), CONVERT(VARCHAR(300), i.DS_ESTADO_ANTES)
        FROM inserted i JOIN deleted d ON d.ID_KAIZEN = i.ID_KAIZEN JOIN @logMap lm ON lm.ID_KAIZEN = i.ID_KAIZEN
        WHERE NOT (d.DS_ESTADO_ANTES = i.DS_ESTADO_ANTES OR (d.DS_ESTADO_ANTES IS NULL AND i.DS_ESTADO_ANTES IS NULL))
        UNION ALL
        SELECT lm.ID_LOG, 'URL_IMG_DEPOIS', CONVERT(VARCHAR(300), d.URL_IMG_DEPOIS), CONVERT(VARCHAR(300), i.URL_IMG_DEPOIS)
        FROM inserted i JOIN deleted d ON d.ID_KAIZEN = i.ID_KAIZEN JOIN @logMap lm ON lm.ID_KAIZEN = i.ID_KAIZEN
        WHERE NOT (d.URL_IMG_DEPOIS = i.URL_IMG_DEPOIS OR (d.URL_IMG_DEPOIS IS NULL AND i.URL_IMG_DEPOIS IS NULL))
        UNION ALL
        SELECT lm.ID_LOG, 'DS_ESTADO_DEPOIS', CONVERT(VARCHAR(300), d.DS_ESTADO_DEPOIS), CONVERT(VARCHAR(300), i.DS_ESTADO_DEPOIS)
        FROM inserted i JOIN deleted d ON d.ID_KAIZEN = i.ID_KAIZEN JOIN @logMap lm ON lm.ID_KAIZEN = i.ID_KAIZEN
        WHERE NOT (d.DS_ESTADO_DEPOIS = i.DS_ESTADO_DEPOIS OR (d.DS_ESTADO_DEPOIS IS NULL AND i.DS_ESTADO_DEPOIS IS NULL))
        UNION ALL
        SELECT lm.ID_LOG, 'URL_REFERENCIA', CONVERT(VARCHAR(300), d.URL_REFERENCIA), CONVERT(VARCHAR(300), i.URL_REFERENCIA)
        FROM inserted i JOIN deleted d ON d.ID_KAIZEN = i.ID_KAIZEN JOIN @logMap lm ON lm.ID_KAIZEN = i.ID_KAIZEN
        WHERE NOT (d.URL_REFERENCIA = i.URL_REFERENCIA OR (d.URL_REFERENCIA IS NULL AND i.URL_REFERENCIA IS NULL))
        UNION ALL
        SELECT lm.ID_LOG, 'ID_DESPERDICIO', CONVERT(VARCHAR(300), d.ID_DESPERDICIO), CONVERT(VARCHAR(300), i.ID_DESPERDICIO)
        FROM inserted i JOIN deleted d ON d.ID_KAIZEN = i.ID_KAIZEN JOIN @logMap lm ON lm.ID_KAIZEN = i.ID_KAIZEN
        WHERE NOT (d.ID_DESPERDICIO = i.ID_DESPERDICIO OR (d.ID_DESPERDICIO IS NULL AND i.ID_DESPERDICIO IS NULL))
        UNION ALL
        SELECT lm.ID_LOG, 'DS_LICOES_APRENDIDAS', CONVERT(VARCHAR(300), d.DS_LICOES_APRENDIDAS), CONVERT(VARCHAR(300), i.DS_LICOES_APRENDIDAS)
        FROM inserted i JOIN deleted d ON d.ID_KAIZEN = i.ID_KAIZEN JOIN @logMap lm ON lm.ID_KAIZEN = i.ID_KAIZEN
        WHERE NOT (d.DS_LICOES_APRENDIDAS = i.DS_LICOES_APRENDIDAS OR (d.DS_LICOES_APRENDIDAS IS NULL AND i.DS_LICOES_APRENDIDAS IS NULL))
        UNION ALL
        SELECT lm.ID_LOG, 'VL_RESULTADO_FINANCEIRO', CONVERT(VARCHAR(300), d.VL_RESULTADO_FINANCEIRO), CONVERT(VARCHAR(300), i.VL_RESULTADO_FINANCEIRO)
        FROM inserted i JOIN deleted d ON d.ID_KAIZEN = i.ID_KAIZEN JOIN @logMap lm ON lm.ID_KAIZEN = i.ID_KAIZEN
        WHERE NOT (d.VL_RESULTADO_FINANCEIRO = i.VL_RESULTADO_FINANCEIRO OR (d.VL_RESULTADO_FINANCEIRO IS NULL AND i.VL_RESULTADO_FINANCEIRO IS NULL))
        UNION ALL
        SELECT lm.ID_LOG, 'ID_MOEDA', CONVERT(VARCHAR(300), d.ID_MOEDA), CONVERT(VARCHAR(300), i.ID_MOEDA)
        FROM inserted i JOIN deleted d ON d.ID_KAIZEN = i.ID_KAIZEN JOIN @logMap lm ON lm.ID_KAIZEN = i.ID_KAIZEN
        WHERE NOT (d.ID_MOEDA = i.ID_MOEDA OR (d.ID_MOEDA IS NULL AND i.ID_MOEDA IS NULL))
        UNION ALL
        SELECT lm.ID_LOG, 'DS_RESULTADO_ESPERADO', CONVERT(VARCHAR(300), d.DS_RESULTADO_ESPERADO), CONVERT(VARCHAR(300), i.DS_RESULTADO_ESPERADO)
        FROM inserted i JOIN deleted d ON d.ID_KAIZEN = i.ID_KAIZEN JOIN @logMap lm ON lm.ID_KAIZEN = i.ID_KAIZEN
        WHERE NOT (d.DS_RESULTADO_ESPERADO = i.DS_RESULTADO_ESPERADO OR (d.DS_RESULTADO_ESPERADO IS NULL AND i.DS_RESULTADO_ESPERADO IS NULL))
        UNION ALL
        SELECT lm.ID_LOG, 'DT_CRIACAO', CONVERT(VARCHAR(300), d.DT_CRIACAO, 120), CONVERT(VARCHAR(300), i.DT_CRIACAO, 120)
        FROM inserted i JOIN deleted d ON d.ID_KAIZEN = i.ID_KAIZEN JOIN @logMap lm ON lm.ID_KAIZEN = i.ID_KAIZEN
        WHERE NOT (d.DT_CRIACAO = i.DT_CRIACAO OR (d.DT_CRIACAO IS NULL AND i.DT_CRIACAO IS NULL))
        UNION ALL
        SELECT lm.ID_LOG, 'DT_CONCLUSAO', CONVERT(VARCHAR(300), d.DT_CONCLUSAO, 23), CONVERT(VARCHAR(300), i.DT_CONCLUSAO, 23)
        FROM inserted i JOIN deleted d ON d.ID_KAIZEN = i.ID_KAIZEN JOIN @logMap lm ON lm.ID_KAIZEN = i.ID_KAIZEN
        WHERE NOT (d.DT_CONCLUSAO = i.DT_CONCLUSAO OR (d.DT_CONCLUSAO IS NULL AND i.DT_CONCLUSAO IS NULL))
        UNION ALL
        SELECT lm.ID_LOG, 'DS_MOTIVO', CONVERT(VARCHAR(300), d.DS_MOTIVO), CONVERT(VARCHAR(300), i.DS_MOTIVO)
        FROM inserted i JOIN deleted d ON d.ID_KAIZEN = i.ID_KAIZEN JOIN @logMap lm ON lm.ID_KAIZEN = i.ID_KAIZEN
        WHERE NOT (d.DS_MOTIVO = i.DS_MOTIVO OR (d.DS_MOTIVO IS NULL AND i.DS_MOTIVO IS NULL))
    ) x;
END
GO

CREATE OR ALTER TRIGGER CI.TR_KZN_MEMBROS_EQUIPE_UPD ON CI.KZN_MEMBROS_EQUIPE AFTER UPDATE AS
BEGIN
    SET NOCOUNT ON;
    IF NOT UPDATE(DT_ATUALIZACAO)
        UPDATE T SET DT_ATUALIZACAO = SYSDATETIME()
        FROM CI.KZN_MEMBROS_EQUIPE T
        JOIN inserted i ON i.ID_KAIZEN = T.ID_KAIZEN AND i.ID_USUARIO = T.ID_USUARIO;
END
GO

CREATE OR ALTER TRIGGER CI.TR_KZN_RESULTADO_KAIZEN_UPD ON CI.KZN_RESULTADO_KAIZEN AFTER UPDATE AS
BEGIN
    SET NOCOUNT ON;
    IF NOT UPDATE(DT_ATUALIZACAO)
        UPDATE T SET DT_ATUALIZACAO = SYSDATETIME()
        FROM CI.KZN_RESULTADO_KAIZEN T
        JOIN inserted i ON i.ID_KAIZEN = T.ID_KAIZEN AND i.ID_RESULTADO = T.ID_RESULTADO;
END
GO

CREATE OR ALTER TRIGGER CI.TR_KZN_KAIZEN_HIERARQUIA_UPD ON CI.KZN_KAIZEN_HIERARQUIA AFTER UPDATE AS
BEGIN
    SET NOCOUNT ON;
    IF NOT UPDATE(DT_ATUALIZACAO)
        UPDATE T SET DT_ATUALIZACAO = SYSDATETIME()
        FROM CI.KZN_KAIZEN_HIERARQUIA T JOIN inserted i ON i.ID_KAIZEN_HIERARQUIA = T.ID_KAIZEN_HIERARQUIA;
END
GO

CREATE OR ALTER TRIGGER CI.TR_KZN_KZDESP_UPD ON CI.KZN_KAIZEN_DESPERDICIO AFTER UPDATE AS
BEGIN
    SET NOCOUNT ON;
    IF NOT UPDATE(DT_ATUALIZACAO)
        UPDATE T SET DT_ATUALIZACAO = SYSDATETIME()
        FROM CI.KZN_KAIZEN_DESPERDICIO T
        JOIN inserted i ON i.ID_KAIZEN = T.ID_KAIZEN AND i.ID_DESPERDICIO = T.ID_DESPERDICIO;
END
GO

/* =====================================================================
   ETAPA 5 - CONFERENCIA
   ===================================================================== */
SELECT  TABELA = t.name,
        LINHAS = SUM(p.rows),
        SITUACAO = 'recriada'
FROM        sys.tables t
JOIN        sys.partitions p ON p.object_id = t.object_id AND p.index_id IN (0,1)
WHERE       t.schema_id = SCHEMA_ID('CI')
  AND       t.name IN ('KZN_PEDRAVISAOCONSOLIDADA','KZN_LOG_PEDRAVISAOCONSOLIDADA',
                       'KZN_LOG_PEDRAVISAOCONSOLIDADA_DETALHE','KZN_MEMBROS_EQUIPE',
                       'KZN_RESULTADO_KAIZEN','KZN_KAIZEN_HIERARQUIA','KZN_KAIZEN_DESPERDICIO')
GROUP BY    t.name
ORDER BY    t.name;
GO
