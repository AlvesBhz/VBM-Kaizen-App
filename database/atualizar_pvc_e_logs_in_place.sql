/* =====================================================================
   Atualiza IN-PLACE (sem apagar nada) as 3 tabelas do bloco do Kaizen
     CI.KZN_PEDRAVISAOCONSOLIDADA
     CI.KZN_LOG_PEDRAVISAOCONSOLIDADA
     CI.KZN_LOG_PEDRAVISAOCONSOLIDADA_DETALHE
   ---------------------------------------------------------------------
   NENHUM DROP TABLE, NENHUMA RECRIACAO: todos os registros existentes
   sao preservados. O script leva as tabelas do estado antigo para o
   formato final, aplicando so o que ainda estiver faltando.

   O QUE FAZ, POR TABELA:

   KZN_PEDRAVISAOCONSOLIDADA
     E1. SG_STATUS (VARCHAR(30)) -> ID_STATUS (INT), com o ID BUSCADO em
         ci.kzn_status pelo nome (sem mapa fixo).
     E2. ID_MOTIVO (INT) -> DS_MOTIVO (VARCHAR(300)), migrando o TEXTO
         REAL de ci.kzn_motivo_reprovacao.DS_MOTIVO.
     E3. 10 campos de texto para VARCHAR(300) (so ampliacao).

   KZN_LOG_PEDRAVISAOCONSOLIDADA
     E4. Garante a SEQUENCE de ID_LOG. A coluna e NOT NULL sem IDENTITY
         nem DEFAULT e os triggers nunca a informavam - todo INSERT ou
         UPDATE na tabela principal falhava com "Cannot insert the value
         NULL into column 'ID_LOG'". A sequence nasce alinhada ao maior
         ID_LOG ja gravado, entao nao colide com o historico existente.

   KZN_LOG_PEDRAVISAOCONSOLIDADA_DETALHE
     E5. Cria a tabela e sua sequence se ainda nao existirem, e amplia
         VL_ANTERIOR/VL_NOVO para VARCHAR(300) - senao o historico
         truncaria em 200 os campos que agora tem 300.

   E6. Recria os triggers TR_KZN_PVC_INS / TR_KZN_PVC_UPD na versao
       atual: usam a sequence e auditam ID_STATUS e DS_MOTIVO.

   IDEMPOTENTE: cada etapa checa antes de agir; rodar de novo nao
   duplica nem desfaz nada. As etapas que nao se aplicam sao puladas
   com um PRINT.

   *** QUEBRA A APLICACAO ATE O DEPLOY DO APP AJUSTADO ***
   server.js ainda usa SG_STATUS, ID_MOTIVO e PVC_LIMITES com os
   tamanhos antigos.

   Schema: 'CI'.
   ===================================================================== */

SET NOCOUNT ON;

/* =====================================================================
   E1 - KZN_PEDRAVISAOCONSOLIDADA: SG_STATUS -> ID_STATUS
   ===================================================================== */
IF NOT EXISTS (SELECT 1 FROM sys.columns
               WHERE object_id = OBJECT_ID('CI.KZN_PEDRAVISAOCONSOLIDADA') AND name = 'SG_STATUS')
    PRINT 'E1 pulada - SG_STATUS ja foi removida.';
ELSE IF OBJECT_ID('CI.KZN_STATUS','U') IS NULL OR NOT EXISTS (SELECT 1 FROM CI.KZN_STATUS)
BEGIN
    RAISERROR('Abortado em E1: CI.KZN_STATUS nao existe ou esta vazia - nao ha de onde buscar o ID_STATUS.', 16, 1);
    RETURN;
END
GO

IF EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('CI.KZN_PEDRAVISAOCONSOLIDADA') AND name = 'SG_STATUS')
   AND NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('CI.KZN_PEDRAVISAOCONSOLIDADA') AND name = 'ID_STATUS')
    ALTER TABLE CI.KZN_PEDRAVISAOCONSOLIDADA ADD ID_STATUS INT NULL;
GO

IF EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('CI.KZN_PEDRAVISAOCONSOLIDADA') AND name = 'SG_STATUS')
BEGIN
    -- SQL dinamico: SG_STATUS pode nao existir numa 2a execucao, e a
    -- referencia estatica quebraria a compilacao do batch inteiro.
    EXEC sp_executesql N'
        UPDATE p
        SET    p.ID_STATUS = m.ID_STATUS
        FROM   CI.KZN_PEDRAVISAOCONSOLIDADA p
        CROSS APPLY (
            SELECT TOP (1) s.ID_STATUS
            FROM   CI.KZN_STATUS s
            WHERE  UPPER(REPLACE(s.NM_STATUS, '' '', ''_'')) COLLATE Latin1_General_CI_AI
                 = UPPER(LTRIM(RTRIM(p.SG_STATUS)))          COLLATE Latin1_General_CI_AI
            ORDER BY s.ID_IDIOMA
        ) m
        WHERE  p.ID_STATUS IS NULL;';

    DECLARE @semMapa INT;
    EXEC sp_executesql N'SELECT @qt = COUNT(*) FROM CI.KZN_PEDRAVISAOCONSOLIDADA WHERE ID_STATUS IS NULL',
                       N'@qt INT OUTPUT', @qt = @semMapa OUTPUT;
    IF @semMapa > 0
    BEGIN
        RAISERROR('Abortado em E1: %d Kaizen(s) com SG_STATUS sem correspondencia em CI.KZN_STATUS. NADA foi removido - ID_STATUS ja existe e pode ser preenchida a mao.', 16, 1, @semMapa);
        RETURN;
    END

    IF OBJECT_ID('CI.CK_KZN_PVC_STATUS','C') IS NOT NULL
        ALTER TABLE CI.KZN_PEDRAVISAOCONSOLIDADA DROP CONSTRAINT CK_KZN_PVC_STATUS;
    IF OBJECT_ID('CI.DF_KZN_PVC_STATUS','D') IS NOT NULL
        ALTER TABLE CI.KZN_PEDRAVISAOCONSOLIDADA DROP CONSTRAINT DF_KZN_PVC_STATUS;
    IF EXISTS (SELECT 1 FROM sys.indexes
               WHERE object_id = OBJECT_ID('CI.KZN_PEDRAVISAOCONSOLIDADA') AND name = 'IX_KZN_PVC_STATUS')
        DROP INDEX IX_KZN_PVC_STATUS ON CI.KZN_PEDRAVISAOCONSOLIDADA;

    ALTER TABLE CI.KZN_PEDRAVISAOCONSOLIDADA DROP COLUMN SG_STATUS;
    CREATE NONCLUSTERED INDEX IX_KZN_PVC_STATUS ON CI.KZN_PEDRAVISAOCONSOLIDADA (ID_STATUS);
    PRINT 'E1 ok - ID_STATUS preenchida a partir de CI.KZN_STATUS; SG_STATUS removida.';
END
GO

/* =====================================================================
   E2 - KZN_PEDRAVISAOCONSOLIDADA: ID_MOTIVO -> DS_MOTIVO
   ===================================================================== */
IF NOT EXISTS (SELECT 1 FROM sys.columns
               WHERE object_id = OBJECT_ID('CI.KZN_PEDRAVISAOCONSOLIDADA') AND name = 'ID_MOTIVO')
    PRINT 'E2 pulada - ID_MOTIVO ja foi removida.';
GO

IF EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('CI.KZN_PEDRAVISAOCONSOLIDADA') AND name = 'ID_MOTIVO')
   AND NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('CI.KZN_PEDRAVISAOCONSOLIDADA') AND name = 'DS_MOTIVO')
    ALTER TABLE CI.KZN_PEDRAVISAOCONSOLIDADA ADD DS_MOTIVO VARCHAR(300) NULL;
GO

IF EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('CI.KZN_PEDRAVISAOCONSOLIDADA') AND name = 'ID_MOTIVO')
BEGIN
    IF OBJECT_ID('CI.KZN_MOTIVO_REPROVACAO','U') IS NOT NULL
        EXEC sp_executesql N'
            UPDATE p
            SET    p.DS_MOTIVO = m.DS_MOTIVO
            FROM   CI.KZN_PEDRAVISAOCONSOLIDADA p
            CROSS APPLY (
                SELECT TOP (1) x.DS_MOTIVO
                FROM   CI.KZN_MOTIVO_REPROVACAO x
                WHERE  x.ID_MOTIVO = p.ID_MOTIVO
                ORDER BY CASE WHEN x.ID_IDIOMA = 1 THEN 0 ELSE 1 END, x.ID_IDIOMA
            ) m
            WHERE  p.ID_MOTIVO IS NOT NULL AND p.DS_MOTIVO IS NULL;';
    ELSE
        PRINT 'AVISO: CI.KZN_MOTIVO_REPROVACAO nao existe - DS_MOTIVO fica vazia (sem texto de origem).';

    DECLARE @orfaos INT;
    EXEC sp_executesql N'SELECT @qt = COUNT(*) FROM CI.KZN_PEDRAVISAOCONSOLIDADA WHERE ID_MOTIVO IS NOT NULL AND DS_MOTIVO IS NULL',
                       N'@qt INT OUTPUT', @qt = @orfaos OUTPUT;
    IF @orfaos > 0
        PRINT 'AVISO: ' + CAST(@orfaos AS VARCHAR(10)) + ' Kaizen(s) tinham ID_MOTIVO sem texto correspondente - DS_MOTIVO ficou nula neles.';

    EXEC sp_executesql N'ALTER TABLE CI.KZN_PEDRAVISAOCONSOLIDADA DROP COLUMN ID_MOTIVO;';
    PRINT 'E2 ok - justificativa migrada para DS_MOTIVO; ID_MOTIVO removida.';
END
GO

/* =====================================================================
   E3 - KZN_PEDRAVISAOCONSOLIDADA: 10 campos para VARCHAR(300)
   (so ampliacao - nenhum dado e perdido, nulidade inalterada)
   ===================================================================== */
ALTER TABLE CI.KZN_PEDRAVISAOCONSOLIDADA ALTER COLUMN DS_PROBLEMA           VARCHAR(300) NULL;
ALTER TABLE CI.KZN_PEDRAVISAOCONSOLIDADA ALTER COLUMN DS_OBJETIVO           VARCHAR(300) NULL;
ALTER TABLE CI.KZN_PEDRAVISAOCONSOLIDADA ALTER COLUMN URL_IMG_ANTES         VARCHAR(300) NULL;
ALTER TABLE CI.KZN_PEDRAVISAOCONSOLIDADA ALTER COLUMN DS_ESTADO_ANTES       VARCHAR(300) NULL;
ALTER TABLE CI.KZN_PEDRAVISAOCONSOLIDADA ALTER COLUMN URL_IMG_DEPOIS        VARCHAR(300) NULL;
ALTER TABLE CI.KZN_PEDRAVISAOCONSOLIDADA ALTER COLUMN DS_ESTADO_DEPOIS      VARCHAR(300) NULL;
ALTER TABLE CI.KZN_PEDRAVISAOCONSOLIDADA ALTER COLUMN URL_REFERENCIA        VARCHAR(300) NULL;
ALTER TABLE CI.KZN_PEDRAVISAOCONSOLIDADA ALTER COLUMN DS_LICOES_APRENDIDAS  VARCHAR(300) NULL;
ALTER TABLE CI.KZN_PEDRAVISAOCONSOLIDADA ALTER COLUMN DS_RESULTADO_ESPERADO VARCHAR(300) NULL;
GO

IF EXISTS (SELECT 1 FROM sys.columns
           WHERE object_id = OBJECT_ID('CI.KZN_PEDRAVISAOCONSOLIDADA') AND name = 'DS_MOTIVO')
    ALTER TABLE CI.KZN_PEDRAVISAOCONSOLIDADA ALTER COLUMN DS_MOTIVO         VARCHAR(300) NULL;
PRINT 'E3 ok - campos de texto ampliados para VARCHAR(300).';
GO

/* =====================================================================
   E4 - KZN_LOG_PEDRAVISAOCONSOLIDADA: sequence de ID_LOG
   Nasce alinhada ao maior ID_LOG ja gravado (START WITH exige literal,
   por isso o CREATE SEQUENCE e montado via SQL dinamico).
   ===================================================================== */
IF OBJECT_ID('CI.KZN_LOG_PEDRAVISAOCONSOLIDADA','U') IS NULL
    PRINT 'AVISO: CI.KZN_LOG_PEDRAVISAOCONSOLIDADA nao existe - rode o script completo para cria-la.';
ELSE IF NOT EXISTS (SELECT 1 FROM sys.sequences WHERE schema_id = SCHEMA_ID('CI') AND name = 'SEQ_KZN_LOG_PVC')
BEGIN
    DECLARE @prox INT = ISNULL((SELECT MAX(ID_LOG) FROM CI.KZN_LOG_PEDRAVISAOCONSOLIDADA), 0) + 1;
    DECLARE @sqlSeq nvarchar(300) = N'CREATE SEQUENCE CI.SEQ_KZN_LOG_PVC AS INT START WITH '
                                  + CAST(@prox AS nvarchar(20)) + N' INCREMENT BY 1;';
    EXEC sp_executesql @sqlSeq;
    PRINT 'E4 ok - SEQ_KZN_LOG_PVC criada a partir de ' + CAST(@prox AS VARCHAR(20)) + '.';
END
ELSE
    PRINT 'E4 pulada - SEQ_KZN_LOG_PVC ja existe.';
GO

/* =====================================================================
   E5 - KZN_LOG_PEDRAVISAOCONSOLIDADA_DETALHE
   ===================================================================== */
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

IF NOT EXISTS (SELECT 1 FROM sys.sequences WHERE schema_id = SCHEMA_ID('CI') AND name = 'SEQ_KZN_LOG_PVC_DETALHE')
BEGIN
    DECLARE @proxD INT = ISNULL((SELECT MAX(ID_LOG_DETALHE) FROM CI.KZN_LOG_PEDRAVISAOCONSOLIDADA_DETALHE), 0) + 1;
    DECLARE @sqlSeqD nvarchar(300) = N'CREATE SEQUENCE CI.SEQ_KZN_LOG_PVC_DETALHE AS INT START WITH '
                                   + CAST(@proxD AS nvarchar(20)) + N' INCREMENT BY 1;';
    EXEC sp_executesql @sqlSeqD;
END
GO

-- Acompanha o VARCHAR(300) dos campos auditados (senao trunca em 200)
IF OBJECT_ID('CI.KZN_LOG_PEDRAVISAOCONSOLIDADA_DETALHE','U') IS NOT NULL
BEGIN
    ALTER TABLE CI.KZN_LOG_PEDRAVISAOCONSOLIDADA_DETALHE ALTER COLUMN VL_ANTERIOR VARCHAR(300) NULL;
    ALTER TABLE CI.KZN_LOG_PEDRAVISAOCONSOLIDADA_DETALHE ALTER COLUMN VL_NOVO     VARCHAR(300) NULL;
    PRINT 'E5 ok - tabela de detalhe pronta e ampliada para VARCHAR(300).';
END
GO

/* =====================================================================
   E6 - TRIGGERS na versao atual (usam a sequence; auditam ID_STATUS e
   DS_MOTIVO). CREATE OR ALTER: nao derruba nada, so redefine.
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

/* =====================================================================
   E7 - CONFERENCIA
   ===================================================================== */
SELECT  TABELA = 'KZN_PEDRAVISAOCONSOLIDADA', COLUNA = c.name,
        TIPO = ty.name + CASE WHEN ty.name = 'varchar' THEN '(' + CAST(c.max_length AS VARCHAR(10)) + ')' ELSE '' END
FROM        sys.columns c JOIN sys.types ty ON ty.user_type_id = c.user_type_id
WHERE       c.object_id = OBJECT_ID('CI.KZN_PEDRAVISAOCONSOLIDADA')
  AND       c.name IN ('ID_STATUS','DS_MOTIVO','DS_PROBLEMA','DS_OBJETIVO','URL_IMG_ANTES','DS_ESTADO_ANTES',
                       'URL_IMG_DEPOIS','DS_ESTADO_DEPOIS','URL_REFERENCIA','DS_LICOES_APRENDIDAS','DS_RESULTADO_ESPERADO')
UNION ALL
SELECT  'KZN_LOG_PEDRAVISAOCONSOLIDADA_DETALHE', c.name,
        ty.name + CASE WHEN ty.name = 'varchar' THEN '(' + CAST(c.max_length AS VARCHAR(10)) + ')' ELSE '' END
FROM        sys.columns c JOIN sys.types ty ON ty.user_type_id = c.user_type_id
WHERE       c.object_id = OBJECT_ID('CI.KZN_LOG_PEDRAVISAOCONSOLIDADA_DETALHE')
  AND       c.name IN ('VL_ANTERIOR','VL_NOVO')
ORDER BY 1, 2;

SELECT  SEQUENCE_NAME = name, PROXIMO_VALOR = CAST(current_value AS BIGINT) + increment
FROM    sys.sequences
WHERE   schema_id = SCHEMA_ID('CI') AND name IN ('SEQ_KZN_LOG_PVC','SEQ_KZN_LOG_PVC_DETALHE');

SELECT  LINHAS_PRESERVADAS_PVC = COUNT(*) FROM CI.KZN_PEDRAVISAOCONSOLIDADA;
GO
