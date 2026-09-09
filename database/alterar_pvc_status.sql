/* =====================================================================
   CI.KZN_PEDRAVISAOCONSOLIDADA — SG_STATUS (texto) -> ID_STATUS (INT)
   ---------------------------------------------------------------------
   ESCOPO: SOMENTE esta tabela. Este script NAO cria e NAO popula
   ci.kzn_status, e NAO toca em kzn_motivo_reprovacao.

   O ID_STATUS NAO usa mapa fixo: e BUSCADO em ci.kzn_status, casando o
   texto antigo de SG_STATUS com NM_STATUS. Assim funciona com qualquer
   ID que o cadastro tenha hoje - inclusive se os status tiverem sido
   cadastrados pela tela, com IDs diferentes de 1..5.

   REGRA DE CASAMENTO (normalizada nos dois lados):
     - caixa e acento ignorados  -> COLLATE Latin1_General_CI_AI
     - espaco equivale a underscore -> REPLACE(' ', '_')
   Com isso 'Em aprovacao' casa com 'EM_APROVACAO', 'Concluido' com
   'CONCLUIDO', e assim por diante. Como o cadastro e bilingue (mesmo
   ID_STATUS em 2 idiomas), pega-se o menor ID_IDIOMA que casar - o ID
   e o mesmo nos dois.

   SEM FK de banco, de proposito: ci.kzn_status tem PK composta
   (ID_STATUS, ID_IDIOMA) e o SQL Server nao aceita FK para parte de
   chave composta - mesma regra ja aplicada a ID_CATEGORIA,
   ID_REPLICACAO e ID_DESPERDICIO nesta mesma tabela.

   *** QUEBRA A APLICACAO ATE O DEPLOY DO APP AJUSTADO ***
   server.js e o front ainda leem/gravam SG_STATUS (fila de aprovacao,
   dashboard, listagens). Rode a ETAPA 1, confira o de-para, e so rode a
   ETAPA 2 em janela combinada com o deploy.

   IDEMPOTENTE: reexecutar nao refaz o que ja foi aplicado.
   Schema: 'ci' (AZURE_SQL_SCHEMA em app.yaml).
   ===================================================================== */

SET NOCOUNT ON;

/* =====================================================================
   ETAPA 1 - DIAGNOSTICO / DE-PARA (so leitura, nao altera nada)
   Mostra, para cada valor atual de SG_STATUS, qual ID_STATUS foi
   encontrado em ci.kzn_status. Qualquer linha "SEM CORRESPONDENCIA"
   precisa ser tratada antes da ETAPA 2 (que aborta se houver).
   ===================================================================== */
IF NOT EXISTS (SELECT 1 FROM sys.columns
               WHERE object_id = OBJECT_ID('ci.kzn_pedravisaoconsolidada') AND name = 'SG_STATUS')
    PRINT 'SG_STATUS nao existe mais - alteracao ja aplicada.';
ELSE IF OBJECT_ID('ci.kzn_status', 'U') IS NULL
    PRINT 'ATENCAO: ci.kzn_status nao existe. Crie o cadastro antes (database/criar_kzn_status.sql).';
ELSE
    EXEC sp_executesql N'
        SELECT  SG_STATUS_ATUAL = p.SG_STATUS,
                QTD             = COUNT(*),
                ID_STATUS_ENCONTRADO = MIN(m.ID_STATUS),
                NM_STATUS_CADASTRO   = MIN(m.NM_STATUS),
                SITUACAO = CASE WHEN MIN(m.ID_STATUS) IS NULL
                                THEN ''SEM CORRESPONDENCIA em ci.kzn_status - tratar antes''
                                ELSE ''ok - sera convertido'' END
        FROM        [ci].[kzn_pedravisaoconsolidada] p
        OUTER APPLY (
            SELECT TOP (1) s.ID_STATUS, s.NM_STATUS
            FROM   [ci].[kzn_status] s
            WHERE  UPPER(REPLACE(s.NM_STATUS, '' '', ''_'')) COLLATE Latin1_General_CI_AI
                 = UPPER(LTRIM(RTRIM(p.SG_STATUS)))          COLLATE Latin1_General_CI_AI
            ORDER BY s.ID_IDIOMA
        ) m
        GROUP BY p.SG_STATUS
        ORDER BY SITUACAO DESC, p.SG_STATUS;';
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
    RAISERROR('Abortado: ci.kzn_status nao existe. Crie e popule o cadastro antes (database/criar_kzn_status.sql).', 16, 1);
    RETURN;
END

IF NOT EXISTS (SELECT 1 FROM [ci].[kzn_status])
BEGIN
    RAISERROR('Abortado: ci.kzn_status esta vazia - nao ha de onde buscar o ID_STATUS. Cadastre os status antes.', 16, 1);
    RETURN;
END

PRINT 'Aplicando alteracao em ci.kzn_pedravisaoconsolidada...';

IF NOT EXISTS (SELECT 1 FROM sys.columns
               WHERE object_id = OBJECT_ID('ci.kzn_pedravisaoconsolidada') AND name = 'ID_STATUS')
    ALTER TABLE [ci].[kzn_pedravisaoconsolidada] ADD ID_STATUS INT NULL;
GO

-- SQL dinamico: SG_STATUS pode nao existir numa 2a execucao, e uma
-- referencia estatica quebraria a compilacao do batch inteiro.
-- O ID vem de ci.kzn_status, nao de mapa fixo.
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
    RAISERROR('Abortado: %d Kaizen(s) com SG_STATUS sem correspondencia em ci.kzn_status. Veja a ETAPA 1 - cadastre o status faltante (ou ajuste NM_STATUS) e reexecute. NADA foi removido; ID_STATUS ja existe e pode ser preenchida a mao.', 16, 1, @semMapa);
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
