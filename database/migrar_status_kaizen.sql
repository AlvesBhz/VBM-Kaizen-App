/* =====================================================================
   Status do Kaizen: SG_STATUS (texto) -> ID_STATUS (CI.KZN_STATUS)
   ---------------------------------------------------------------------
   Substitui a coluna de texto CI.KZN_PEDRAVISAOCONSOLIDADA.SG_STATUS
   (VARCHAR(30) + CK_KZN_PVC_STATUS + DEFAULT 'ABERTO') por ID_STATUS INT,
   apontando para o cadastro CI.KZN_STATUS.

   SEM FK de banco, de propósito: KZN_STATUS tem PK composta
   (ID_STATUS, ID_IDIOMA) e o SQL Server não aceita FK para parte de
   chave composta — mesma decisão já aplicada a ID_CATEGORIA,
   ID_REPLICACAO, ID_DESPERDICIO e ID_MOTIVO.

   ID_MOTIVO e CI.KZN_MOTIVO_REPROVACAO NÃO são tocados: guardam a
   justificativa de reprovação escrita pelo aprovador (texto livre), que
   é outro conceito, não o status.

   *** QUEBRA A APLICAÇÃO ATÉ O AJUSTE DO APP SER PUBLICADO ***
   server.js e o front ainda leem/gravam SG_STATUS (fila de aprovação,
   dashboard, listagens, POST /kaizens/:id/reprovar). Rode a ETAPA 1,
   confira, e só rode a ETAPA 3 em janela combinada com o deploy do app.

   IDEMPOTENTE: reexecutar não duplica nada nem refaz o que já foi feito.

   Schema: 'ci' (AZURE_SQL_SCHEMA em app.yaml).
   ===================================================================== */

SET NOCOUNT ON;

/* =====================================================================
   ETAPA 1 — DIAGNÓSTICO (só leitura)
   Mostra a distribuição atual e se algum valor está fora do domínio
   esperado (esses virariam NULL — a ETAPA 3 aborta se houver algum).
   ===================================================================== */
IF EXISTS (SELECT 1 FROM sys.columns
           WHERE object_id = OBJECT_ID('ci.kzn_pedravisaoconsolidada') AND name = 'SG_STATUS')
    EXEC sp_executesql N'
        SELECT  SG_STATUS,
                QTD = COUNT(*),
                SITUACAO = CASE WHEN UPPER(LTRIM(RTRIM(SG_STATUS)))
                                     IN (''ABERTO'',''EM_APROVACAO'',''APROVADO'',''REPROVADO'',''CONCLUIDO'')
                                THEN ''ok - sera mapeado''
                                ELSE ''FORA DO DOMINIO - tratar antes'' END
        FROM    [ci].[kzn_pedravisaoconsolidada]
        GROUP BY SG_STATUS
        ORDER BY SITUACAO DESC, SG_STATUS;';
ELSE
    PRINT 'SG_STATUS nao existe mais - migracao ja aplicada.';
GO

/* =====================================================================
   ETAPA 2 — SEED de ci.kzn_status (os 5 status do domínio antigo)
   Bilíngue (1 = PT, 2 = EN), IDs fixos 1..5 — é o mapa usado na ETAPA 3.
   ===================================================================== */
IF OBJECT_ID('ci.kzn_status', 'U') IS NULL
BEGIN
    RAISERROR('ci.kzn_status nao existe. Rode database/criar_kzn_status.sql antes.', 16, 1);
    RETURN;
END

MERGE [ci].[kzn_status] AS T
USING (VALUES
    (1, 1, 'Aberto',        'Kaizen registrado, ainda nao enviado para aprovacao'),
    (2, 1, 'Em aprovacao',  'Aguardando avaliacao do aprovador'),
    (3, 1, 'Aprovado',      'Aprovado pelo aprovador responsavel'),
    (4, 1, 'Reprovado',     'Reprovado - a justificativa fica em kzn_motivo_reprovacao'),
    (5, 1, 'Concluido',     'Kaizen finalizado'),
    (1, 2, 'Open',          'Kaizen registered, not yet submitted for approval'),
    (2, 2, 'In approval',   'Waiting for the approver review'),
    (3, 2, 'Approved',      'Approved by the responsible approver'),
    (4, 2, 'Rejected',      'Rejected - justification is kept in kzn_motivo_reprovacao'),
    (5, 2, 'Completed',     'Kaizen finished')
) AS S (ID_STATUS, ID_IDIOMA, NM_STATUS, DS_STATUS)
    ON T.ID_STATUS = S.ID_STATUS AND T.ID_IDIOMA = S.ID_IDIOMA
WHEN NOT MATCHED BY TARGET THEN
    INSERT (ID_STATUS, ID_IDIOMA, NM_STATUS, DS_STATUS)
    VALUES (S.ID_STATUS, S.ID_IDIOMA, S.NM_STATUS, S.DS_STATUS);
PRINT 'Seed de ci.kzn_status aplicado.';
GO

/* =====================================================================
   ETAPA 3 — MIGRAÇÃO (altera estrutura e dados)
   Cria ID_STATUS, converte os valores e só então remove SG_STATUS.
   Aborta sem remover nada se sobrar algum status fora do domínio.
   ===================================================================== */
IF NOT EXISTS (SELECT 1 FROM sys.columns
               WHERE object_id = OBJECT_ID('ci.kzn_pedravisaoconsolidada') AND name = 'SG_STATUS')
BEGIN
    PRINT 'Nada a fazer - SG_STATUS ja foi removida.';
    RETURN;
END

IF NOT EXISTS (SELECT 1 FROM sys.columns
               WHERE object_id = OBJECT_ID('ci.kzn_pedravisaoconsolidada') AND name = 'ID_STATUS')
    ALTER TABLE [ci].[kzn_pedravisaoconsolidada] ADD ID_STATUS INT NULL;
GO

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
    RAISERROR('Abortado: %d Kaizen(s) com SG_STATUS fora do dominio conhecido. Veja a ETAPA 1, trate esses registros e reexecute. NADA foi removido - ID_STATUS ja existe e pode ser preenchida a mao.', 16, 1, @semMapa);
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

PRINT 'Migracao concluida: SG_STATUS removida, ID_STATUS ativa e indexada.';
GO

/* =====================================================================
   ETAPA 4 — CONFERÊNCIA
   ===================================================================== */
SELECT  p.ID_STATUS,
        STATUS_PT = s.NM_STATUS,
        QTD = COUNT(*)
FROM        [ci].[kzn_pedravisaoconsolidada] p
LEFT JOIN   [ci].[kzn_status] s ON s.ID_STATUS = p.ID_STATUS AND s.ID_IDIOMA = 1
GROUP BY    p.ID_STATUS, s.NM_STATUS
ORDER BY    p.ID_STATUS;
GO
