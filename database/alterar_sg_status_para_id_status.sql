/* =====================================================================
   CI.KZN_PEDRAVISAOCONSOLIDADA: SG_STATUS -> ID_STATUS
   ---------------------------------------------------------------------
   Faz APENAS essa troca de coluna. Nao cria nem popula ci.kzn_status,
   nao toca em DS_MOTIVO/kzn_motivo_reprovacao, nao mexe em mais nada.

   O ID_STATUS e BUSCADO em ci.kzn_status (nao ha mapa fixo): casa o
   texto antigo de SG_STATUS com NM_STATUS, ignorando caixa e acento
   (COLLATE Latin1_General_CI_AI) e tratando espaco como underscore -
   'Em aprovacao' casa com 'EM_APROVACAO', 'Concluido' com 'CONCLUIDO'.
   Cadastro bilingue: usa o menor ID_IDIOMA que casar (o ID e o mesmo).

   Os DROPs de CK_KZN_PVC_STATUS, DF_KZN_PVC_STATUS e IX_KZN_PVC_STATUS
   nao sao escopo extra: o SQL Server nao deixa remover a coluna
   enquanto houver CHECK, DEFAULT ou indice sobre ela. O indice e
   recriado sobre ID_STATUS so para manter o que ja existia.

   ABORTA sem remover nada se ci.kzn_status nao existir, estiver vazia,
   ou se sobrar algum SG_STATUS sem correspondencia.

   *** QUEBRA A APLICACAO ATE O DEPLOY DO APP AJUSTADO ***
   IDEMPOTENTE. Schema: 'ci' (AZURE_SQL_SCHEMA em app.yaml).
   ===================================================================== */

SET NOCOUNT ON;

IF NOT EXISTS (SELECT 1 FROM sys.columns
               WHERE object_id = OBJECT_ID('ci.kzn_pedravisaoconsolidada') AND name = 'SG_STATUS')
BEGIN
    PRINT 'Nada a fazer - SG_STATUS ja foi removida.';
    RETURN;
END

IF OBJECT_ID('ci.kzn_status', 'U') IS NULL OR NOT EXISTS (SELECT 1 FROM [ci].[kzn_status])
BEGIN
    RAISERROR('Abortado: ci.kzn_status nao existe ou esta vazia - nao ha de onde buscar o ID_STATUS.', 16, 1);
    RETURN;
END

IF NOT EXISTS (SELECT 1 FROM sys.columns
               WHERE object_id = OBJECT_ID('ci.kzn_pedravisaoconsolidada') AND name = 'ID_STATUS')
    ALTER TABLE [ci].[kzn_pedravisaoconsolidada] ADD ID_STATUS INT NULL;
GO

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

IF OBJECT_ID('ci.CK_KZN_PVC_STATUS', 'C') IS NOT NULL
    ALTER TABLE [ci].[kzn_pedravisaoconsolidada] DROP CONSTRAINT CK_KZN_PVC_STATUS;
IF OBJECT_ID('ci.DF_KZN_PVC_STATUS', 'D') IS NOT NULL
    ALTER TABLE [ci].[kzn_pedravisaoconsolidada] DROP CONSTRAINT DF_KZN_PVC_STATUS;
IF EXISTS (SELECT 1 FROM sys.indexes
           WHERE object_id = OBJECT_ID('ci.kzn_pedravisaoconsolidada') AND name = 'IX_KZN_PVC_STATUS')
    DROP INDEX IX_KZN_PVC_STATUS ON [ci].[kzn_pedravisaoconsolidada];

ALTER TABLE [ci].[kzn_pedravisaoconsolidada] DROP COLUMN SG_STATUS;

CREATE NONCLUSTERED INDEX IX_KZN_PVC_STATUS ON [ci].[kzn_pedravisaoconsolidada] (ID_STATUS);

PRINT 'Concluido: SG_STATUS removida, ID_STATUS preenchida a partir de ci.kzn_status.';
GO
