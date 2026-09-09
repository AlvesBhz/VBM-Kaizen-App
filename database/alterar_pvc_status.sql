/* =====================================================================
   CI.KZN_PEDRAVISAOCONSOLIDADA — SG_STATUS (texto) -> ID_STATUS (INT)
   ---------------------------------------------------------------------
   ESCOPO: SOMENTE esta tabela. Este script NAO cria e NAO popula
   ci.kzn_status, e NAO toca em ID_MOTIVO nem em kzn_motivo_reprovacao.

   O que faz:
     1. Cria a coluna ID_STATUS INT NULL.
     2. Converte o texto atual de SG_STATUS para o ID correspondente.
     3. Remove CK_KZN_PVC_STATUS, DF_KZN_PVC_STATUS, o indice antigo e a
        propria coluna SG_STATUS.
     4. Recria IX_KZN_PVC_STATUS apontando para ID_STATUS.

   SEM FK de banco, de proposito: ci.kzn_status tem PK composta
   (ID_STATUS, ID_IDIOMA) e o SQL Server nao aceita FK para parte de
   chave composta - mesma regra ja aplicada a ID_CATEGORIA,
   ID_REPLICACAO, ID_DESPERDICIO e ID_MOTIVO nesta mesma tabela.

   PRE-REQUISITO: ci.kzn_status precisa existir e ja conter os IDs 1..5
   (1=Aberto, 2=Em aprovacao, 3=Aprovado, 4=Reprovado, 5=Concluido). O
   script CONFERE e aborta se faltar - popular o cadastro nao e escopo
   daqui (use database/migrar_status_kaizen.sql, ETAPA 2, ou cadastre
   pela tela).

   *** QUEBRA A APLICACAO ATE O DEPLOY DO APP AJUSTADO ***
   server.js e o front ainda leem/gravam SG_STATUS (fila de aprovacao,
   dashboard, listagens, POST /kaizens/:id/reprovar). Rode a ETAPA 1,
   confira, e so rode a ETAPA 2 em janela combinada com o deploy.

   IDEMPOTENTE: reexecutar nao refaz o que ja foi aplicado.
   Schema: 'ci' (AZURE_SQL_SCHEMA em app.yaml).
   ===================================================================== */

SET NOCOUNT ON;

/* =====================================================================
   ETAPA 1 - DIAGNOSTICO (so leitura, nao altera nada)
   ===================================================================== */
IF NOT EXISTS (SELECT 1 FROM sys.columns
               WHERE object_id = OBJECT_ID('ci.kzn_pedravisaoconsolidada') AND name = 'SG_STATUS')
    PRINT 'SG_STATUS nao existe mais - alteracao ja aplicada.';
ELSE
    EXEC sp_executesql N'
        SELECT  SG_STATUS,
                QTD = COUNT(*),
                ID_STATUS_DESTINO = CASE UPPER(LTRIM(RTRIM(SG_STATUS)))
                        WHEN ''ABERTO'' THEN 1 WHEN ''EM_APROVACAO'' THEN 2
                        WHEN ''APROVADO'' THEN 3 WHEN ''REPROVADO'' THEN 4
                        WHEN ''CONCLUIDO'' THEN 5 END,
                SITUACAO = CASE WHEN UPPER(LTRIM(RTRIM(SG_STATUS)))
                                     IN (''ABERTO'',''EM_APROVACAO'',''APROVADO'',''REPROVADO'',''CONCLUIDO'')
                                THEN ''ok - sera convertido''
                                ELSE ''FORA DO DOMINIO - tratar antes'' END
        FROM    [ci].[kzn_pedravisaoconsolidada]
        GROUP BY SG_STATUS
        ORDER BY SITUACAO DESC, SG_STATUS;';

-- Pre-requisito: os 5 IDs precisam existir no cadastro
SELECT  ID_STATUS_ESPERADO = v.ID,
        SITUACAO = CASE WHEN EXISTS (SELECT 1 FROM [ci].[kzn_status] s WHERE s.ID_STATUS = v.ID)
                        THEN 'ok - existe em ci.kzn_status'
                        ELSE 'FALTA - cadastrar antes da ETAPA 2' END
FROM    (VALUES (1),(2),(3),(4),(5)) AS v(ID)
ORDER BY v.ID;
GO

/* =====================================================================
   ETAPA 2 - APLICACAO (altera estrutura e dados)
   ===================================================================== */
IF NOT EXISTS (SELECT 1 FROM sys.columns
               WHERE object_id = OBJECT_ID('ci.kzn_pedravisaoconsolidada') AND name = 'SG_STATUS')
BEGIN
    PRINT 'Nada a fazer - SG_STATUS ja foi removida.';
    RETURN;
END

IF OBJECT_ID('ci.kzn_status', 'U') IS NULL
BEGIN
    RAISERROR('Abortado: ci.kzn_status nao existe. Crie o cadastro antes (database/criar_kzn_status.sql).', 16, 1);
    RETURN;
END

DECLARE @faltando INT =
    (SELECT COUNT(*) FROM (VALUES (1),(2),(3),(4),(5)) AS v(ID)
      WHERE NOT EXISTS (SELECT 1 FROM [ci].[kzn_status] s WHERE s.ID_STATUS = v.ID));
IF @faltando > 0
BEGIN
    RAISERROR('Abortado: %d dos 5 status (IDs 1..5) nao existem em ci.kzn_status. Popule o cadastro antes - ver ETAPA 1. Nada foi alterado.', 16, 1, @faltando);
    RETURN;
END

PRINT 'Aplicando alteracao em ci.kzn_pedravisaoconsolidada...';

IF NOT EXISTS (SELECT 1 FROM sys.columns
               WHERE object_id = OBJECT_ID('ci.kzn_pedravisaoconsolidada') AND name = 'ID_STATUS')
    ALTER TABLE [ci].[kzn_pedravisaoconsolidada] ADD ID_STATUS INT NULL;
GO

-- SQL dinamico: SG_STATUS pode nao existir numa 2a execucao, e uma
-- referencia estatica quebraria a compilacao do batch inteiro.
EXEC sp_executesql N'
    UPDATE [ci].[kzn_pedravisaoconsolidada]
    SET ID_STATUS = CASE UPPER(LTRIM(RTRIM(SG_STATUS)))
                        WHEN ''ABERTO''       THEN 1
                        WHEN ''EM_APROVACAO'' THEN 2
                        WHEN ''APROVADO''     THEN 3
                        WHEN ''REPROVADO''    THEN 4
                        WHEN ''CONCLUIDO''    THEN 5
                    END
    WHERE ID_STATUS IS NULL;';

DECLARE @semMapa INT;
EXEC sp_executesql N'SELECT @qt = COUNT(*) FROM [ci].[kzn_pedravisaoconsolidada] WHERE ID_STATUS IS NULL',
                   N'@qt INT OUTPUT', @qt = @semMapa OUTPUT;
IF @semMapa > 0
BEGIN
    RAISERROR('Abortado: %d Kaizen(s) com SG_STATUS fora do dominio conhecido. Veja a ETAPA 1. NADA foi removido - ID_STATUS ja existe e pode ser preenchida a mao antes de reexecutar.', 16, 1, @semMapa);
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

PRINT 'Concluido: SG_STATUS removida, ID_STATUS ativa e indexada.';
GO

/* =====================================================================
   ETAPA 3 - CONFERENCIA
   ===================================================================== */
SELECT  p.ID_STATUS,
        STATUS_PT = s.NM_STATUS,
        QTD = COUNT(*)
FROM        [ci].[kzn_pedravisaoconsolidada] p
LEFT JOIN   [ci].[kzn_status] s ON s.ID_STATUS = p.ID_STATUS AND s.ID_IDIOMA = 1
GROUP BY    p.ID_STATUS, s.NM_STATUS
ORDER BY    p.ID_STATUS;
GO
