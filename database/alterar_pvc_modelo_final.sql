/* =====================================================================
   CI.KZN_PEDRAVISAOCONSOLIDADA -> formato final (conforme o DER)
   ---------------------------------------------------------------------
   Aplica APENAS as duas trocas de coluna que faltam nesta tabela:

     SG_STATUS  VARCHAR(30)  ->  ID_STATUS  INT           (9a coluna)
     ID_MOTIVO  INT          ->  DS_MOTIVO  VARCHAR(100)  (23a coluna)

   Nao mexe em nenhuma outra tabela. O DROP de ci.kzn_motivo_reprovacao
   NAO esta aqui - fica na ETAPA 3 de database/migrar_motivo_para_ds_motivo.sql.

   DE ONDE VEM CADA VALOR:
     ID_STATUS - BUSCADO em ci.kzn_status, casando SG_STATUS com
       NM_STATUS ignorando caixa e acento (COLLATE Latin1_General_CI_AI)
       e tratando espaco como underscore: 'Em aprovacao' casa com
       'EM_APROVACAO', 'Concluido' com 'CONCLUIDO'. Sem mapa fixo, entao
       funciona com quaisquer IDs que o cadastro tenha. Cadastro
       bilingue: usa o menor ID_IDIOMA que casar (o ID e o mesmo).
     DS_MOTIVO - TEXTO REAL de ci.kzn_motivo_reprovacao.DS_MOTIVO, que
       ja e VARCHAR(100): mesmo tipo e tamanho, sem truncamento. A
       tabela guarda 1 linha por idioma com o mesmo texto, entao usa o
       portugues (ID_IDIOMA = 1) e, na falta dele, o menor ID_IDIOMA.

   Os DROPs de CK_KZN_PVC_STATUS, DF_KZN_PVC_STATUS e IX_KZN_PVC_STATUS
   nao sao escopo extra: o SQL Server nao remove uma coluna enquanto
   houver CHECK, DEFAULT ou indice sobre ela. O indice e recriado sobre
   ID_STATUS so para manter o que ja existia.

   *** QUEBRA A APLICACAO ATE O DEPLOY DO APP AJUSTADO ***
   server.js ainda usa SG_STATUS (fila de aprovacao, dashboard,
   listagens) e ID_MOTIVO (POST /kaizens/:id/reprovar).

   IDEMPOTENTE. Schema: 'ci' (AZURE_SQL_SCHEMA em app.yaml).
   ===================================================================== */

SET NOCOUNT ON;

/* =====================================================================
   ETAPA 1 - SG_STATUS -> ID_STATUS
   ===================================================================== */
IF NOT EXISTS (SELECT 1 FROM sys.columns
               WHERE object_id = OBJECT_ID('ci.kzn_pedravisaoconsolidada') AND name = 'SG_STATUS')
    PRINT 'ETAPA 1 pulada - SG_STATUS ja foi removida.';
ELSE IF OBJECT_ID('ci.kzn_status','U') IS NULL OR NOT EXISTS (SELECT 1 FROM [ci].[kzn_status])
BEGIN
    RAISERROR('Abortado: ci.kzn_status nao existe ou esta vazia - nao ha de onde buscar o ID_STATUS.', 16, 1);
    RETURN;
END
GO

IF EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('ci.kzn_pedravisaoconsolidada') AND name = 'SG_STATUS')
   AND NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('ci.kzn_pedravisaoconsolidada') AND name = 'ID_STATUS')
    ALTER TABLE [ci].[kzn_pedravisaoconsolidada] ADD ID_STATUS INT NULL;
GO

IF EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('ci.kzn_pedravisaoconsolidada') AND name = 'SG_STATUS')
BEGIN
    -- SQL dinamico: SG_STATUS pode nao existir numa 2a execucao, e a
    -- referencia estatica quebraria a compilacao do batch inteiro.
    EXEC sp_executesql N'
        UPDATE p
        SET    p.ID_STATUS = m.ID_STATUS
        FROM   [ci].[kzn_pedravisaoconsolidada] p
        CROSS APPLY (
            SELECT TOP (1) s.ID_STATUS
            FROM   [ci].[kzn_status] s
            WHERE  UPPER(REPLACE(s.NM_STATUS, '' '', ''_'')) COLLATE Latin1_General_CI_AI
                 = UPPER(LTRIM(RTRIM(p.SG_STATUS)))          COLLATE Latin1_General_CI_AI
            ORDER BY s.ID_IDIOMA
        ) m
        WHERE  p.ID_STATUS IS NULL;';

    DECLARE @semMapa INT;
    EXEC sp_executesql N'SELECT @qt = COUNT(*) FROM [ci].[kzn_pedravisaoconsolidada] WHERE ID_STATUS IS NULL',
                       N'@qt INT OUTPUT', @qt = @semMapa OUTPUT;
    IF @semMapa > 0
    BEGIN
        RAISERROR('Abortado: %d Kaizen(s) com SG_STATUS sem correspondencia em ci.kzn_status. NADA foi removido - ID_STATUS ja existe e pode ser preenchida a mao.', 16, 1, @semMapa);
        RETURN;
    END

    IF OBJECT_ID('ci.CK_KZN_PVC_STATUS','C') IS NOT NULL
        ALTER TABLE [ci].[kzn_pedravisaoconsolidada] DROP CONSTRAINT CK_KZN_PVC_STATUS;
    IF OBJECT_ID('ci.DF_KZN_PVC_STATUS','D') IS NOT NULL
        ALTER TABLE [ci].[kzn_pedravisaoconsolidada] DROP CONSTRAINT DF_KZN_PVC_STATUS;
    IF EXISTS (SELECT 1 FROM sys.indexes
               WHERE object_id = OBJECT_ID('ci.kzn_pedravisaoconsolidada') AND name = 'IX_KZN_PVC_STATUS')
        DROP INDEX IX_KZN_PVC_STATUS ON [ci].[kzn_pedravisaoconsolidada];

    ALTER TABLE [ci].[kzn_pedravisaoconsolidada] DROP COLUMN SG_STATUS;
    CREATE NONCLUSTERED INDEX IX_KZN_PVC_STATUS ON [ci].[kzn_pedravisaoconsolidada] (ID_STATUS);

    PRINT 'ETAPA 1 ok - SG_STATUS removida, ID_STATUS preenchida a partir de ci.kzn_status.';
END
GO

/* =====================================================================
   ETAPA 2 - ID_MOTIVO -> DS_MOTIVO
   ===================================================================== */
IF NOT EXISTS (SELECT 1 FROM sys.columns
               WHERE object_id = OBJECT_ID('ci.kzn_pedravisaoconsolidada') AND name = 'ID_MOTIVO')
    PRINT 'ETAPA 2 pulada - ID_MOTIVO ja foi removida.';
GO

IF EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('ci.kzn_pedravisaoconsolidada') AND name = 'ID_MOTIVO')
   AND NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('ci.kzn_pedravisaoconsolidada') AND name = 'DS_MOTIVO')
    ALTER TABLE [ci].[kzn_pedravisaoconsolidada] ADD DS_MOTIVO VARCHAR(100) NULL;
GO

IF EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('ci.kzn_pedravisaoconsolidada') AND name = 'ID_MOTIVO')
BEGIN
    IF OBJECT_ID('ci.kzn_motivo_reprovacao','U') IS NOT NULL
        EXEC sp_executesql N'
            UPDATE p
            SET    p.DS_MOTIVO = m.DS_MOTIVO
            FROM   [ci].[kzn_pedravisaoconsolidada] p
            CROSS APPLY (
                SELECT TOP (1) x.DS_MOTIVO
                FROM   [ci].[kzn_motivo_reprovacao] x
                WHERE  x.ID_MOTIVO = p.ID_MOTIVO
                ORDER BY CASE WHEN x.ID_IDIOMA = 1 THEN 0 ELSE 1 END, x.ID_IDIOMA
            ) m
            WHERE  p.ID_MOTIVO IS NOT NULL AND p.DS_MOTIVO IS NULL;';
    ELSE
        PRINT 'AVISO: ci.kzn_motivo_reprovacao nao existe - DS_MOTIVO fica vazia (sem texto de origem).';

    DECLARE @orfaos INT;
    EXEC sp_executesql N'SELECT @qt = COUNT(*) FROM [ci].[kzn_pedravisaoconsolidada] WHERE ID_MOTIVO IS NOT NULL AND DS_MOTIVO IS NULL',
                       N'@qt INT OUTPUT', @qt = @orfaos OUTPUT;
    IF @orfaos > 0
        PRINT 'AVISO: ' + CAST(@orfaos AS VARCHAR(10)) + ' Kaizen(s) tinham ID_MOTIVO sem texto correspondente - DS_MOTIVO ficou nula neles.';

    EXEC sp_executesql N'ALTER TABLE [ci].[kzn_pedravisaoconsolidada] DROP COLUMN ID_MOTIVO;';
    PRINT 'ETAPA 2 ok - ID_MOTIVO removida, justificativa agora em DS_MOTIVO.';
END
GO

/* =====================================================================
   ETAPA 3 - CONFERENCIA (estrutura final; deve bater com o DER)
   ===================================================================== */
SELECT  ORDEM   = c.column_id,
        COLUNA  = c.name,
        TIPO    = ty.name + CASE
                    WHEN ty.name IN ('varchar','char')   THEN '(' + CAST(c.max_length AS VARCHAR(10)) + ')'
                    WHEN ty.name = 'decimal'             THEN '(' + CAST(c.precision AS VARCHAR(10)) + ',' + CAST(c.scale AS VARCHAR(10)) + ')'
                    ELSE '' END,
        ACEITA_NULO = CASE WHEN c.is_nullable = 1 THEN 'sim' ELSE 'NAO' END
FROM        sys.columns c
INNER JOIN  sys.types   ty ON ty.user_type_id = c.user_type_id
WHERE       c.object_id = OBJECT_ID('ci.kzn_pedravisaoconsolidada')
ORDER BY    c.column_id;
GO
