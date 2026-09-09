/* =====================================================================
   CI.KZN_PEDRAVISAOCONSOLIDADA - 10 campos para VARCHAR(300)
   ---------------------------------------------------------------------
   DS_PROBLEMA            100 -> 300
   DS_OBJETIVO            100 -> 300
   URL_IMG_ANTES          200 -> 300
   DS_ESTADO_ANTES        100 -> 300
   URL_IMG_DEPOIS         200 -> 300
   DS_ESTADO_DEPOIS       100 -> 300
   URL_REFERENCIA         200 -> 300
   DS_LICOES_APRENDIDAS   100 -> 300
   DS_RESULTADO_ESPERADO  100 -> 300
   DS_MOTIVO              100 -> 300

   So AMPLIACAO de tamanho: nenhum dado e perdido, a nulidade nao muda e
   nenhuma constraint precisa ser derrubada.

   ETAPA 2 (necessaria, nao e escopo extra): o historico de auditoria
   grava os valores em ci.kzn_log_pedravisaoconsolidada_detalhe
   (VL_ANTERIOR / VL_NOVO), hoje VARCHAR(200) - com campos de 300 ele
   passaria a TRUNCAR silenciosamente o que ficou registrado. As duas
   colunas sobem para VARCHAR(300) junto.

   ATENCAO - APP: o server.js tem a tabela PVC_LIMITES com os tamanhos
   antigos (DS_PROBLEMA 100, URL_IMG_ANTES 200, ...), usada para validar
   e cortar o texto ANTES de gravar. Enquanto ela nao for atualizada, o
   app continua limitando em 100/200 mesmo com a coluna aceitando 300.

   IDEMPOTENTE: reexecutar apenas reaplica o mesmo tipo.
   Schema: 'ci' (AZURE_SQL_SCHEMA em app.yaml).
   ===================================================================== */

SET NOCOUNT ON;

/* =====================================================================
   ETAPA 1 - CI.KZN_PEDRAVISAOCONSOLIDADA
   ===================================================================== */
IF OBJECT_ID('ci.kzn_pedravisaoconsolidada', 'U') IS NULL
BEGIN
    RAISERROR('Abortado: ci.kzn_pedravisaoconsolidada nao existe.', 16, 1);
    RETURN;
END

ALTER TABLE [ci].[kzn_pedravisaoconsolidada] ALTER COLUMN DS_PROBLEMA           VARCHAR(300) NULL;
ALTER TABLE [ci].[kzn_pedravisaoconsolidada] ALTER COLUMN DS_OBJETIVO           VARCHAR(300) NULL;
ALTER TABLE [ci].[kzn_pedravisaoconsolidada] ALTER COLUMN URL_IMG_ANTES         VARCHAR(300) NULL;
ALTER TABLE [ci].[kzn_pedravisaoconsolidada] ALTER COLUMN DS_ESTADO_ANTES       VARCHAR(300) NULL;
ALTER TABLE [ci].[kzn_pedravisaoconsolidada] ALTER COLUMN URL_IMG_DEPOIS        VARCHAR(300) NULL;
ALTER TABLE [ci].[kzn_pedravisaoconsolidada] ALTER COLUMN DS_ESTADO_DEPOIS      VARCHAR(300) NULL;
ALTER TABLE [ci].[kzn_pedravisaoconsolidada] ALTER COLUMN URL_REFERENCIA        VARCHAR(300) NULL;
ALTER TABLE [ci].[kzn_pedravisaoconsolidada] ALTER COLUMN DS_LICOES_APRENDIDAS  VARCHAR(300) NULL;
ALTER TABLE [ci].[kzn_pedravisaoconsolidada] ALTER COLUMN DS_RESULTADO_ESPERADO VARCHAR(300) NULL;
GO

-- DS_MOTIVO so existe depois da troca ID_MOTIVO -> DS_MOTIVO
IF EXISTS (SELECT 1 FROM sys.columns
           WHERE object_id = OBJECT_ID('ci.kzn_pedravisaoconsolidada') AND name = 'DS_MOTIVO')
    ALTER TABLE [ci].[kzn_pedravisaoconsolidada] ALTER COLUMN DS_MOTIVO         VARCHAR(300) NULL;
ELSE
    PRINT 'AVISO: DS_MOTIVO ainda nao existe (rode antes a troca ID_MOTIVO -> DS_MOTIVO). Os demais campos foram ampliados.';
GO

/* =====================================================================
   ETAPA 2 - Auditoria acompanha (senao trunca em 200)
   ===================================================================== */
IF OBJECT_ID('ci.kzn_log_pedravisaoconsolidada_detalhe', 'U') IS NOT NULL
BEGIN
    ALTER TABLE [ci].[kzn_log_pedravisaoconsolidada_detalhe] ALTER COLUMN VL_ANTERIOR VARCHAR(300) NULL;
    ALTER TABLE [ci].[kzn_log_pedravisaoconsolidada_detalhe] ALTER COLUMN VL_NOVO     VARCHAR(300) NULL;
    PRINT 'Auditoria ampliada para VARCHAR(300).';
END
ELSE
    PRINT 'AVISO: ci.kzn_log_pedravisaoconsolidada_detalhe nao existe - nada a ampliar na auditoria.';
GO

/* ---------------------------------------------------------------------
   O trigger de auditoria converte os valores com CONVERT(VARCHAR(...)).
   Recrie-o pela versao atual do script completo (DDL_SCRIPT_DB.sql,
   secao 19) para que ele passe a usar VARCHAR(300) - caso contrario o
   historico continua truncando em 200 na hora de gravar.
   --------------------------------------------------------------------- */

/* =====================================================================
   ETAPA 3 - CONFERENCIA
   ===================================================================== */
SELECT  TABELA = 'kzn_pedravisaoconsolidada', COLUNA = c.name,
        TAMANHO = c.max_length,
        SITUACAO = CASE WHEN c.max_length = 300 THEN 'ok - 300' ELSE 'DIVERGENTE' END
FROM        sys.columns c
WHERE       c.object_id = OBJECT_ID('ci.kzn_pedravisaoconsolidada')
  AND       c.name IN ('DS_PROBLEMA','DS_OBJETIVO','URL_IMG_ANTES','DS_ESTADO_ANTES','URL_IMG_DEPOIS',
                       'DS_ESTADO_DEPOIS','URL_REFERENCIA','DS_LICOES_APRENDIDAS','DS_RESULTADO_ESPERADO','DS_MOTIVO')
UNION ALL
SELECT  'kzn_log_pedravisaoconsolidada_detalhe', c.name, c.max_length,
        CASE WHEN c.max_length = 300 THEN 'ok - 300' ELSE 'DIVERGENTE' END
FROM        sys.columns c
WHERE       c.object_id = OBJECT_ID('ci.kzn_log_pedravisaoconsolidada_detalhe')
  AND       c.name IN ('VL_ANTERIOR','VL_NOVO')
ORDER BY 1, 2;
GO
