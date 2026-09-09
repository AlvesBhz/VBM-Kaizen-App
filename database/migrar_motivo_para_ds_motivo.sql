/* =====================================================================
   ID_MOTIVO -> DS_MOTIVO e aposentadoria de ci.kzn_motivo_reprovacao
   ---------------------------------------------------------------------
   A justificativa da reprovacao deixa de ser um ID apontando para um
   cadastro e passa a ser gravada em TEXTO na propria linha do Kaizen:

     ci.kzn_pedravisaoconsolidada.ID_MOTIVO  (INT)
       -> ci.kzn_pedravisaoconsolidada.DS_MOTIVO (VARCHAR(100))

   O texto vem de ci.kzn_motivo_reprovacao.DS_MOTIVO, que ja e
   VARCHAR(100) - mesmo tipo e tamanho, entao nao ha truncamento nem
   perda de conteudo. A tabela guarda 1 linha por idioma com o MESMO
   texto (o app grava assim: texto livre nao e traduzido), entao a
   migracao usa o portugues (ID_IDIOMA = 1) e, se nao houver, o menor
   ID_IDIOMA daquele motivo.

   Ao final a tabela ci.kzn_motivo_reprovacao e REMOVIDA.

   *** QUEBRA A APLICACAO ATE O DEPLOY DO APP AJUSTADO ***
   No server.js a tabela e usada em dois lugares:
     - aba admin "Motivos de Reprovacao" (rota /motivosreprovacao)
     - POST /kaizens/:id/reprovar, que hoje INSERE uma linha nela e
       grava o ID em kzn_pedravisaoconsolidada.ID_MOTIVO
   Rode a ETAPA 1, confira, e so rode as ETAPAS 2/3 em janela combinada
   com o deploy do app.

   IDEMPOTENTE: reexecutar nao refaz o que ja foi aplicado.
   Schema: 'ci' (AZURE_SQL_SCHEMA em app.yaml).
   ===================================================================== */

SET NOCOUNT ON;

/* =====================================================================
   ETAPA 1 - DIAGNOSTICO (so leitura, nao altera nada)
   Mostra o que sera migrado e sinaliza Kaizens cujo ID_MOTIVO nao tem
   linha correspondente (esses ficariam com DS_MOTIVO nulo).
   ===================================================================== */
IF NOT EXISTS (SELECT 1 FROM sys.columns
               WHERE object_id = OBJECT_ID('ci.kzn_pedravisaoconsolidada') AND name = 'ID_MOTIVO')
    PRINT 'ID_MOTIVO nao existe mais - migracao ja aplicada.';
ELSE IF OBJECT_ID('ci.kzn_motivo_reprovacao', 'U') IS NULL
    PRINT 'ATENCAO: ci.kzn_motivo_reprovacao nao existe. DS_MOTIVO sera criada vazia (nao ha texto de origem para migrar).';
ELSE
    EXEC sp_executesql N'
        SELECT  p.ID_KAIZEN,
                p.ID_MOTIVO,
                TEXTO_QUE_SERA_GRAVADO = m.DS_MOTIVO,
                SITUACAO = CASE WHEN m.DS_MOTIVO IS NULL
                                THEN ''SEM TEXTO NA ORIGEM - DS_MOTIVO ficara nulo''
                                ELSE ''ok - texto sera migrado'' END
        FROM        [ci].[kzn_pedravisaoconsolidada] p
        OUTER APPLY (
            SELECT TOP (1) x.DS_MOTIVO
            FROM   [ci].[kzn_motivo_reprovacao] x
            WHERE  x.ID_MOTIVO = p.ID_MOTIVO
            ORDER BY CASE WHEN x.ID_IDIOMA = 1 THEN 0 ELSE 1 END, x.ID_IDIOMA
        ) m
        WHERE   p.ID_MOTIVO IS NOT NULL
        ORDER BY SITUACAO DESC, p.ID_KAIZEN;';
GO

/* =====================================================================
   ETAPA 2 - MIGRA O TEXTO E REMOVE ID_MOTIVO
   ===================================================================== */
IF NOT EXISTS (SELECT 1 FROM sys.columns
               WHERE object_id = OBJECT_ID('ci.kzn_pedravisaoconsolidada') AND name = 'ID_MOTIVO')
BEGIN
    PRINT 'Nada a fazer - ID_MOTIVO ja foi removida.';
    RETURN;
END

IF NOT EXISTS (SELECT 1 FROM sys.columns
               WHERE object_id = OBJECT_ID('ci.kzn_pedravisaoconsolidada') AND name = 'DS_MOTIVO')
    ALTER TABLE [ci].[kzn_pedravisaoconsolidada] ADD DS_MOTIVO VARCHAR(100) NULL;
GO

-- SQL dinamico: ID_MOTIVO / kzn_motivo_reprovacao podem nao existir numa
-- 2a execucao, e referencia estatica quebraria a compilacao do batch.
IF OBJECT_ID('ci.kzn_motivo_reprovacao', 'U') IS NOT NULL
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

DECLARE @orfaos INT;
EXEC sp_executesql N'SELECT @qt = COUNT(*) FROM [ci].[kzn_pedravisaoconsolidada] WHERE ID_MOTIVO IS NOT NULL AND DS_MOTIVO IS NULL',
                   N'@qt INT OUTPUT', @qt = @orfaos OUTPUT;
IF @orfaos > 0
    PRINT 'AVISO: ' + CAST(@orfaos AS VARCHAR(10)) + ' Kaizen(s) tinham ID_MOTIVO sem texto correspondente - DS_MOTIVO ficou nulo neles (ver ETAPA 1).';

EXEC sp_executesql N'ALTER TABLE [ci].[kzn_pedravisaoconsolidada] DROP COLUMN ID_MOTIVO;';
PRINT 'ID_MOTIVO removida; justificativa agora em DS_MOTIVO.';
GO

/* =====================================================================
   ETAPA 3 - REMOVE ci.kzn_motivo_reprovacao
   So roda depois que ID_MOTIVO ja saiu (garantia de que o texto ja foi
   migrado). Derruba antes qualquer FK que envolva a tabela.
   ===================================================================== */
IF OBJECT_ID('ci.kzn_motivo_reprovacao', 'U') IS NULL
    PRINT 'ci.kzn_motivo_reprovacao ja nao existe.';
ELSE IF EXISTS (SELECT 1 FROM sys.columns
                WHERE object_id = OBJECT_ID('ci.kzn_pedravisaoconsolidada') AND name = 'ID_MOTIVO')
    PRINT 'Pulado: ID_MOTIVO ainda existe - rode a ETAPA 2 primeiro.';
ELSE
BEGIN
    DECLARE @sqlFk nvarchar(max) = N'';
    SELECT @sqlFk = @sqlFk + N'ALTER TABLE ' + QUOTENAME(OBJECT_SCHEMA_NAME(fk.parent_object_id)) + N'.'
                  + QUOTENAME(OBJECT_NAME(fk.parent_object_id)) + N' DROP CONSTRAINT ' + QUOTENAME(fk.name) + N';'
    FROM   sys.foreign_keys fk
    WHERE  fk.parent_object_id = OBJECT_ID('ci.kzn_motivo_reprovacao')
        OR fk.referenced_object_id = OBJECT_ID('ci.kzn_motivo_reprovacao');
    IF @sqlFk <> N'' EXEC sp_executesql @sqlFk;

    DROP TABLE [ci].[kzn_motivo_reprovacao];
    PRINT 'ci.kzn_motivo_reprovacao removida.';
END
GO

/* =====================================================================
   ETAPA 4 - CONFERENCIA
   ===================================================================== */
SELECT  TOTAL_KAIZENS       = COUNT(*),
        COM_JUSTIFICATIVA   = SUM(CASE WHEN DS_MOTIVO IS NOT NULL THEN 1 ELSE 0 END)
FROM    [ci].[kzn_pedravisaoconsolidada];

SELECT  TABELA_AINDA_EXISTE = CASE WHEN OBJECT_ID('ci.kzn_motivo_reprovacao','U') IS NULL
                                   THEN 'nao - removida' ELSE 'SIM - ainda existe' END;
GO
