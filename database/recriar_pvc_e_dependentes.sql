/* =====================================================================
   RECRIA CI.KZN_PEDRAVISAOCONSOLIDADA e suas 6 dependentes, do zero
   ---------------------------------------------------------------------
   Recria VAZIO. Só use com a base limpa — a E1 confere isso e ABORTA se
   encontrar qualquer linha, em qualquer uma das 7 tabelas.

   Substitui o recriar_pvc_e_dependentes.sql, que ficou defasado e
   reverteria silenciosamente: NM_KAIZEN(100), DS_COMPARA_META,
   DS_RESULTADO_ALCANCADO, DT_CRIACAO, SG_GM/URL_GM/ID_TIPO_KAIZEN,
   UQ_KZN_PVC_KAIZEN_LIDER e a nova PK de KZN_KAIZEN_HIERARQUIA.

   ORDEM (a FK composta da hierarquia exige o UNIQUE, que exige a PVC):
     DROP   dependentes -> PVC
     CREATE PVC (com PK, UNIQUE, FKs de saida e indices) -> dependentes
            -> sequences -> triggers

   Sequences NAO sao recriadas se ja existirem: sobrevivem ao DROP TABLE e
   recria-las zeraria o contador.

   Tudo em UMA transacao. Schema: 'ci'.
   ===================================================================== */

SET NOCOUNT ON;
SET XACT_ABORT ON;

/* =====================================================================
   E1 - TRAVA: nenhuma das 7 tabelas pode ter linhas
   ===================================================================== */
DECLARE @t TABLE (TABELA SYSNAME, LINHAS INT);
DECLARE @nome SYSNAME, @sql NVARCHAR(MAX), @qt INT, @i INT = 1;
DECLARE @lista TABLE (ORDEM INT, NOME SYSNAME);
INSERT INTO @lista VALUES
  (1,'KZN_LOG_PEDRAVISAOCONSOLIDADA_DETALHE'),(2,'KZN_LOG_PEDRAVISAOCONSOLIDADA'),
  (3,'KZN_MEMBROS_EQUIPE'),(4,'KZN_RESULTADO_KAIZEN'),(5,'KZN_KAIZEN_HIERARQUIA'),
  (6,'KZN_KAIZEN_DESPERDICIO'),(7,'KZN_PEDRAVISAOCONSOLIDADA');

WHILE @i <= 7
BEGIN
    SELECT @nome = NOME FROM @lista WHERE ORDEM = @i;
    IF OBJECT_ID('CI.' + @nome, 'U') IS NOT NULL
    BEGIN
        SET @sql = N'SELECT @c = COUNT(*) FROM CI.' + QUOTENAME(@nome) + N';';
        EXEC sp_executesql @sql, N'@c INT OUTPUT', @c = @qt OUTPUT;
        INSERT INTO @t VALUES (@nome, @qt);
    END
    SET @i += 1;
END

SELECT TABELA, LINHAS FROM @t ORDER BY TABELA;

IF EXISTS (SELECT 1 FROM @t WHERE LINHAS > 0)
BEGIN
    RAISERROR('Abortado: ha tabela(s) com registros (ver acima). Este script recria VAZIO e apagaria esses dados.', 16, 1);
    RETURN;
END

/* Sem GO entre a trava e o DROP, DE PROPOSITO: RAISERROR + RETURN
   encerram apenas o batch em que aparecem. */

BEGIN TRANSACTION;
BEGIN TRY

/* =====================================================================
   E2 - DROP (dependentes primeiro)
   ===================================================================== */
IF OBJECT_ID('CI.KZN_LOG_PEDRAVISAOCONSOLIDADA_DETALHE','U') IS NOT NULL DROP TABLE CI.KZN_LOG_PEDRAVISAOCONSOLIDADA_DETALHE;
IF OBJECT_ID('CI.KZN_LOG_PEDRAVISAOCONSOLIDADA','U')         IS NOT NULL DROP TABLE CI.KZN_LOG_PEDRAVISAOCONSOLIDADA;
IF OBJECT_ID('CI.KZN_MEMBROS_EQUIPE','U')                    IS NOT NULL DROP TABLE CI.KZN_MEMBROS_EQUIPE;
IF OBJECT_ID('CI.KZN_RESULTADO_KAIZEN','U')                  IS NOT NULL DROP TABLE CI.KZN_RESULTADO_KAIZEN;
IF OBJECT_ID('CI.KZN_KAIZEN_HIERARQUIA','U')                 IS NOT NULL DROP TABLE CI.KZN_KAIZEN_HIERARQUIA;
IF OBJECT_ID('CI.KZN_KAIZEN_DESPERDICIO','U')                IS NOT NULL DROP TABLE CI.KZN_KAIZEN_DESPERDICIO;
IF OBJECT_ID('CI.KZN_PEDRAVISAOCONSOLIDADA','U')             IS NOT NULL DROP TABLE CI.KZN_PEDRAVISAOCONSOLIDADA;
PRINT 'E2 ok - 7 tabelas removidas.';

/* =====================================================================
   E3 - CREATE: PVC primeiro (PK + UNIQUE + FKs de saida + indices)
   ===================================================================== */
    CREATE TABLE CI.KZN_PEDRAVISAOCONSOLIDADA
    (
        ID_KAIZEN                  INT                             NOT NULL,
        ID_USUARIO_CADASTRO        INT                             NOT NULL,   -- FK -> MDM: quem registrou
        ID_USUARIO_LIDER           INT                             NOT NULL,   -- FK -> MDM: líder do Kaizen  -- ASSUNÇÃO: NOT NULL
        NM_KAIZEN                  VARCHAR(100)                    NOT NULL,
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
        DS_COMPARA_META            VARCHAR(300)                        NULL,   -- era ID_DESPERDICIO (INT); virou texto livre
        DS_LICOES_APRENDIDAS       VARCHAR(300)                        NULL,
        VL_RESULTADO_FINANCEIRO    DECIMAL(18,2)                      NULL,
        ID_MOEDA                   INT                                 NULL,
        DS_RESULTADO_ALCANCADO     VARCHAR(300)                        NULL,   -- era DS_RESULTADO_ESPERADO
        -- DT_CRIACAO foi REMOVIDA (pedido do time, nesta rodada). A data de
        -- criação do Kaizen passou a viver exclusivamente na linha 'C' de
        -- CI.KZN_LOG_PEDRAVISAOCONSOLIDADA (DT_OPERACAO), gravada pelo
        -- trigger TR_KZN_PVC_INS — ver seções 14 e 19. Para lê-la:
        --   LEFT JOIN CI.KZN_LOG_PEDRAVISAOCONSOLIDADA l
        --          ON l.ID_KAIZEN = p.ID_KAIZEN AND l.TP_OPERACAO = 'C'
        DT_CONCLUSAO               DATE                                NULL,
        DS_MOTIVO                  VARCHAR(300)                        NULL,   -- justificativa da reprovação, em texto livre (antes era ID_MOTIVO -> CI.KZN_MOTIVO_REPROVACAO, tabela aposentada)
        DT_CRIACAO                 DATETIME2(3)                    NOT NULL
            CONSTRAINT DF_KZN_PVC_DT_CRIACAO DEFAULT (SYSDATETIME()),   -- era DT_ATUALIZACAO
        ID_USUARIO_ATUALIZACAO     INT                             NOT NULL,   -- app envia a cada INSERT/UPDATE (quem está agindo)
        SG_GM                      VARCHAR(1)                      NOT NULL
            CONSTRAINT DF_KZN_PVC_SG_GM DEFAULT ('N'),                          -- ASSUNÇÃO: 'S'/'N'
        URL_GM                     VARCHAR(300)                        NULL,
        ID_TIPO_KAIZEN             INT                             NOT NULL
            CONSTRAINT DF_KZN_PVC_ID_TIPO_KAIZEN DEFAULT (0),                   -- CI.KZN_TIPO_KAIZEN (seção 12c). Sem FK de banco: PK composta no destino

        CONSTRAINT PK_KZN_PVC                      PRIMARY KEY CLUSTERED (ID_KAIZEN),
        -- Apoio pra FK composta de CI.KZN_KAIZEN_HIERARQUIA (seção 17). Não
        -- muda regra nenhuma: ID_KAIZEN já é a PK, então o par já era único.
        CONSTRAINT UQ_KZN_PVC_KAIZEN_LIDER         UNIQUE (ID_KAIZEN, ID_USUARIO_LIDER),
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

    CREATE NONCLUSTERED INDEX IX_KZN_PVC_TIPO_KAIZEN  ON CI.KZN_PEDRAVISAOCONSOLIDADA (ID_TIPO_KAIZEN);

PRINT 'E3 ok - CI.KZN_PEDRAVISAOCONSOLIDADA criada.';

/* =====================================================================
   E4 - CREATE das dependentes
   ===================================================================== */
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
    CREATE TABLE CI.KZN_RESULTADO_KAIZEN
    (
        ID_KAIZEN       INT                             NOT NULL,
        ID_RESULTADO    INT                             NOT NULL,
        -- URL_ICONE foi REMOVIDA (pedido do time, nesta rodada). Era um
        -- "override por ocorrência" do ícone do resultado, nunca usado pela
        -- aplicação. O ícone padrão de cada resultado continua em
        -- CI.KZN_RESULTADOS.URL_ICONE.
        DT_ATUALIZACAO  DATETIME2(3)                    NOT NULL
            CONSTRAINT DF_KZN_RESULTADO_KAIZEN_DT_ATUALIZACAO DEFAULT (SYSDATETIME()),

        CONSTRAINT PK_KZN_RESULTADO_KAIZEN          PRIMARY KEY CLUSTERED (ID_KAIZEN, ID_RESULTADO),
        CONSTRAINT FK_KZN_RESULTADO_KAIZEN_KAIZEN   FOREIGN KEY (ID_KAIZEN)
            REFERENCES CI.KZN_PEDRAVISAOCONSOLIDADA (ID_KAIZEN)
        -- ID_RESULTADO NÃO tem FK de banco: KZN_RESULTADOS agora tem PK composta
        -- (ID_RESULTADO, ID_IDIOMA); integridade fica sob responsabilidade da aplicação
    );
    CREATE TABLE CI.KZN_KAIZEN_HIERARQUIA
    (
        ID_KAIZEN              INT                             NOT NULL,
        ID_USUARIO_LIDER       INT                             NOT NULL,
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

        CONSTRAINT PK_KZN_KAIZEN_HIERARQUIA        PRIMARY KEY CLUSTERED (ID_KAIZEN),
        CONSTRAINT FK_KZN_KAIZEN_HIERARQUIA_KAIZEN FOREIGN KEY (ID_KAIZEN)
            REFERENCES CI.KZN_PEDRAVISAOCONSOLIDADA (ID_KAIZEN),
        -- FK composta: garante que o líder da fotografia seja o líder daquele
        -- Kaizen. Depende de UQ_KZN_PVC_KAIZEN_LIDER na seção 13.
        CONSTRAINT FK_KZN_KAIZEN_HIERARQUIA_LIDER  FOREIGN KEY (ID_KAIZEN, ID_USUARIO_LIDER)
            REFERENCES CI.KZN_PEDRAVISAOCONSOLIDADA (ID_KAIZEN, ID_USUARIO_LIDER)
    );
    -- Sem índice avulso em ID_KAIZEN: agora ele é a PK clusterizada.
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

PRINT 'E4 ok - 6 dependentes criadas.';

/* =====================================================================
   E5 - SEQUENCES (so se nao existirem: recriar zeraria o contador)
   ===================================================================== */
IF OBJECT_ID('CI.SEQ_KZN_LOG_PVC','SO') IS NULL
    CREATE SEQUENCE CI.SEQ_KZN_LOG_PVC AS INT START WITH 1 INCREMENT BY 1;
IF OBJECT_ID('CI.SEQ_KZN_LOG_PVC_DETALHE','SO') IS NULL
    CREATE SEQUENCE CI.SEQ_KZN_LOG_PVC_DETALHE AS INT START WITH 1 INCREMENT BY 1;
PRINT 'E5 ok - sequences conferidas.';

COMMIT TRANSACTION;

END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    PRINT 'ERRO - nada foi alterado (rollback aplicado): ' + ERROR_MESSAGE();
    THROW;
END CATCH
GO

/* =====================================================================
   E6 - TRIGGERS (fora da transacao: CREATE TRIGGER exige batch proprio)
   ===================================================================== */
CREATE OR ALTER TRIGGER CI.TR_KZN_PVC_INS ON CI.KZN_PEDRAVISAOCONSOLIDADA AFTER INSERT AS
BEGIN
    SET NOCOUNT ON;
    INSERT INTO CI.KZN_LOG_PEDRAVISAOCONSOLIDADA (ID_LOG, ID_KAIZEN, TP_OPERACAO, DT_OPERACAO, ID_USUARIO_OPERACAO)
    SELECT NEXT VALUE FOR CI.SEQ_KZN_LOG_PVC, ID_KAIZEN, 'C', SYSDATETIME(), ID_USUARIO_CADASTRO
    FROM inserted;
    -- Sem linha de detalhe aqui: criação não tem "valor anterior" a comparar.
    -- Esta linha 'C' é o ÚNICO registro da data de criação do Kaizen desde
    -- que a coluna DT_CRIACAO foi removida da tabela principal.
END
GO

CREATE OR ALTER TRIGGER CI.TR_KZN_PVC_UPD ON CI.KZN_PEDRAVISAOCONSOLIDADA AFTER UPDATE AS
BEGIN
    SET NOCOUNT ON;

    -- DT_CRIACAO NÃO é carimbada aqui: é data de criação, gravada no INSERT.
    -- Sobrescrevê-la a cada UPDATE destruiria o dado original.

    -- Uma linha de cabeçalho de log por Kaizen afetado, capturando o
    -- ID_LOG recém-gerado (OUTPUT) pra ligar as linhas de detalhe geradas
    -- logo abaixo — necessário porque um único UPDATE pode afetar mais de
    -- um Kaizen de uma vez, cada um com seu próprio ID_LOG.
    DECLARE @logMap TABLE (ID_KAIZEN INT NOT NULL PRIMARY KEY, ID_LOG INT NOT NULL);

    -- DT_OPERACAO = SYSDATETIME(): o instante real da alteração. Antes
    -- vinha da coluna DT_ATUALIZACAO, que deixou de existir na tabela.
    INSERT INTO CI.KZN_LOG_PEDRAVISAOCONSOLIDADA (ID_LOG, ID_KAIZEN, TP_OPERACAO, DT_OPERACAO, ID_USUARIO_OPERACAO)
    OUTPUT inserted.ID_KAIZEN, inserted.ID_LOG INTO @logMap (ID_KAIZEN, ID_LOG)
    SELECT NEXT VALUE FOR CI.SEQ_KZN_LOG_PVC, i.ID_KAIZEN, 'A', SYSDATETIME(), i.ID_USUARIO_ATUALIZACAO
    FROM inserted i;

    -- Diff campo a campo (seção 14b) — 1 linha por coluna de negócio cujo
    -- valor mudou nesta atualização. Comparação NULL-segura: "NOT (d.COL =
    -- i.COL OR (d.COL IS NULL AND i.COL IS NULL))" trata NULL=NULL como
    -- "não mudou" e qualquer outra combinação (incluindo um lado NULL) como
    -- mudança. DT_CRIACAO e ID_USUARIO_ATUALIZACAO ficam de fora: a
    -- primeira não muda, o segundo é metadado do cabeçalho gravado acima.
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
        SELECT lm.ID_LOG, 'DS_COMPARA_META', CONVERT(VARCHAR(300), d.DS_COMPARA_META), CONVERT(VARCHAR(300), i.DS_COMPARA_META)
        FROM inserted i JOIN deleted d ON d.ID_KAIZEN = i.ID_KAIZEN JOIN @logMap lm ON lm.ID_KAIZEN = i.ID_KAIZEN
        WHERE NOT (d.DS_COMPARA_META = i.DS_COMPARA_META OR (d.DS_COMPARA_META IS NULL AND i.DS_COMPARA_META IS NULL))
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
        SELECT lm.ID_LOG, 'DS_RESULTADO_ALCANCADO', CONVERT(VARCHAR(300), d.DS_RESULTADO_ALCANCADO), CONVERT(VARCHAR(300), i.DS_RESULTADO_ALCANCADO)
        FROM inserted i JOIN deleted d ON d.ID_KAIZEN = i.ID_KAIZEN JOIN @logMap lm ON lm.ID_KAIZEN = i.ID_KAIZEN
        WHERE NOT (d.DS_RESULTADO_ALCANCADO = i.DS_RESULTADO_ALCANCADO OR (d.DS_RESULTADO_ALCANCADO IS NULL AND i.DS_RESULTADO_ALCANCADO IS NULL))
        UNION ALL
        SELECT lm.ID_LOG, 'DT_CONCLUSAO', CONVERT(VARCHAR(300), d.DT_CONCLUSAO, 23), CONVERT(VARCHAR(300), i.DT_CONCLUSAO, 23)
        FROM inserted i JOIN deleted d ON d.ID_KAIZEN = i.ID_KAIZEN JOIN @logMap lm ON lm.ID_KAIZEN = i.ID_KAIZEN
        WHERE NOT (d.DT_CONCLUSAO = i.DT_CONCLUSAO OR (d.DT_CONCLUSAO IS NULL AND i.DT_CONCLUSAO IS NULL))
        UNION ALL
        SELECT lm.ID_LOG, 'DS_MOTIVO', CONVERT(VARCHAR(300), d.DS_MOTIVO), CONVERT(VARCHAR(300), i.DS_MOTIVO)
        FROM inserted i JOIN deleted d ON d.ID_KAIZEN = i.ID_KAIZEN JOIN @logMap lm ON lm.ID_KAIZEN = i.ID_KAIZEN
        WHERE NOT (d.DS_MOTIVO = i.DS_MOTIVO OR (d.DS_MOTIVO IS NULL AND i.DS_MOTIVO IS NULL))
        UNION ALL
        SELECT lm.ID_LOG, 'SG_GM', CONVERT(VARCHAR(300), d.SG_GM), CONVERT(VARCHAR(300), i.SG_GM)
        FROM inserted i JOIN deleted d ON d.ID_KAIZEN = i.ID_KAIZEN JOIN @logMap lm ON lm.ID_KAIZEN = i.ID_KAIZEN
        WHERE NOT (d.SG_GM = i.SG_GM OR (d.SG_GM IS NULL AND i.SG_GM IS NULL))
        UNION ALL
        SELECT lm.ID_LOG, 'URL_GM', CONVERT(VARCHAR(300), d.URL_GM), CONVERT(VARCHAR(300), i.URL_GM)
        FROM inserted i JOIN deleted d ON d.ID_KAIZEN = i.ID_KAIZEN JOIN @logMap lm ON lm.ID_KAIZEN = i.ID_KAIZEN
        WHERE NOT (d.URL_GM = i.URL_GM OR (d.URL_GM IS NULL AND i.URL_GM IS NULL))
        UNION ALL
        SELECT lm.ID_LOG, 'ID_TIPO_KAIZEN', CONVERT(VARCHAR(300), d.ID_TIPO_KAIZEN), CONVERT(VARCHAR(300), i.ID_TIPO_KAIZEN)
        FROM inserted i JOIN deleted d ON d.ID_KAIZEN = i.ID_KAIZEN JOIN @logMap lm ON lm.ID_KAIZEN = i.ID_KAIZEN
        WHERE NOT (d.ID_TIPO_KAIZEN = i.ID_TIPO_KAIZEN OR (d.ID_TIPO_KAIZEN IS NULL AND i.ID_TIPO_KAIZEN IS NULL))
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
   E7 - CONFERENCIA
   ===================================================================== */
SELECT  TABELA   = t.name,
        COLUNAS  = (SELECT COUNT(*) FROM sys.columns      WHERE object_id = t.object_id),
        PK_UQ    = (SELECT COUNT(*) FROM sys.key_constraints WHERE parent_object_id = t.object_id),
        FK_SAIDA = (SELECT COUNT(*) FROM sys.foreign_keys WHERE parent_object_id = t.object_id),
        INDICES  = (SELECT COUNT(*) FROM sys.indexes      WHERE object_id = t.object_id AND type IN (1,2)),
        TRIGGERS = (SELECT COUNT(*) FROM sys.triggers     WHERE parent_id = t.object_id),
        LINHAS   = (SELECT ISNULL(SUM(rows),0) FROM sys.partitions WHERE object_id = t.object_id AND index_id IN (0,1))
FROM    sys.tables t
WHERE   t.schema_id = SCHEMA_ID('CI')
  AND   t.name IN ('KZN_PEDRAVISAOCONSOLIDADA','KZN_LOG_PEDRAVISAOCONSOLIDADA',
                   'KZN_LOG_PEDRAVISAOCONSOLIDADA_DETALHE','KZN_MEMBROS_EQUIPE',
                   'KZN_RESULTADO_KAIZEN','KZN_KAIZEN_HIERARQUIA','KZN_KAIZEN_DESPERDICIO')
ORDER BY t.name;

SELECT FK_DE_ENTRADA = fk.name,
       FILHA = OBJECT_NAME(fk.parent_object_id),
       CONFIAVEL = CASE WHEN fk.is_not_trusted = 1 THEN 'NAO' ELSE 'SIM' END
FROM   sys.foreign_keys fk
WHERE  fk.referenced_object_id = OBJECT_ID('CI.KZN_PEDRAVISAOCONSOLIDADA')
ORDER BY fk.name;
GO
