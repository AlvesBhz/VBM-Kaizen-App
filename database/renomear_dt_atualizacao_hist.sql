/* =====================================================================
   CI.KZN_HIST_PEDRAVISAOCONSOLIDADA — DT_ATUALIZACAO passa a DT_CRIACAO
   ---------------------------------------------------------------------
   Espelha na tabela de histórico a mesma renomeação já aplicada em
   CI.KZN_PEDRAVISAOCONSOLIDADA, para que as duas voltem a ter estrutura
   idêntica.

   Aqui é MUITO mais simples que na tabela de produção: as tabelas HIST
   foram criadas sem trigger, sem índice, sem PK e sem DEFAULT (staging
   inerte), então não há nada além da coluna para renomear. Não existe o
   problema do auto-touch que obrigou a reescrever o trigger na PVC —
   não há trigger nenhum aqui.

   O DEFAULT é procurado por metadados mesmo assim: se a tabela tiver
   sido criada ou ajustada por outro caminho, ele é renomeado junto
   (sp_rename de coluna NÃO renomeia a constraint que a acompanha).

   Só as OUTRAS quatro tabelas HIST ficam como estão: o DT_ATUALIZACAO
   delas espelha as auxiliares de produção, que não foram renomeadas.

   ---------------------------------------------------------------------
   ORDEM IMPORTA — SE A CARGA DO HISTÓRICO AINDA NÃO RODOU

   O script carga_hist_2026_7281_7296.sql insere na coluna pelo nome
   ANTIGO (DT_ATUALIZACAO). Se você renomear antes de carregar, aquele
   script falha com "Invalid column name 'DT_ATUALIZACAO'".

       Ainda não carregou  ->  rode a CARGA primeiro, depois este script.
       Já carregou         ->  pode rodar este agora.

   A E2 avisa se a tabela estiver vazia, que é o sinal de que a carga
   provavelmente ainda não rodou.

   É IDEMPOTENTE: se a coluna já se chamar DT_CRIACAO, não faz nada.

   Schema: 'ci'.
   ===================================================================== */

SET NOCOUNT ON;
SET XACT_ABORT ON;

/* =====================================================================
   E0 - PRÉ-CHECAGENS
   ===================================================================== */
IF OBJECT_ID('CI.KZN_HIST_PEDRAVISAOCONSOLIDADA', 'U') IS NULL
BEGIN
    RAISERROR('Abortado: CI.KZN_HIST_PEDRAVISAOCONSOLIDADA não existe. Rode criar_tabelas_hist.sql antes.', 16, 1);
    RETURN;
END

IF COL_LENGTH('CI.KZN_HIST_PEDRAVISAOCONSOLIDADA', 'DT_ATUALIZACAO') IS NULL
BEGIN
    PRINT 'Nada a fazer - DT_ATUALIZACAO já não existe em CI.KZN_HIST_PEDRAVISAOCONSOLIDADA.';
    RETURN;
END

IF COL_LENGTH('CI.KZN_HIST_PEDRAVISAOCONSOLIDADA', 'DT_CRIACAO') IS NOT NULL
BEGIN
    RAISERROR('Abortado: já existe uma coluna DT_CRIACAO na tabela. Renomear DT_ATUALIZACAO para esse nome criaria duplicidade.', 16, 1);
    RETURN;
END

/* Sem GO até o fim da E1, DE PROPÓSITO: RAISERROR + RETURN encerram
   apenas o batch em que aparecem. Com um GO aqui, um aborto acima não
   impediria a renomeação logo abaixo. */

/* =====================================================================
   E1 - RENOMEIA A COLUNA (e o DEFAULT, se houver)
   ===================================================================== */
DECLARE @df SYSNAME, @sql NVARCHAR(MAX);

SELECT @df = dc.name
FROM   sys.default_constraints dc
WHERE  dc.parent_object_id = OBJECT_ID('CI.KZN_HIST_PEDRAVISAOCONSOLIDADA')
  AND  dc.parent_column_id = COLUMNPROPERTY(OBJECT_ID('CI.KZN_HIST_PEDRAVISAOCONSOLIDADA'), 'DT_ATUALIZACAO', 'ColumnId');

EXEC sp_rename 'CI.KZN_HIST_PEDRAVISAOCONSOLIDADA.DT_ATUALIZACAO', 'DT_CRIACAO', 'COLUMN';
PRINT 'E1 ok - coluna renomeada para DT_CRIACAO.';

IF @df IS NOT NULL
BEGIN
    SET @sql = N'EXEC sp_rename ''CI.' + @df + N''', ''DF_KZN_HIST_PVC_DT_CRIACAO'', ''OBJECT'';';
    EXEC sp_executesql @sql;
    PRINT '  E1 - DEFAULT ' + @df + ' renomeado para DF_KZN_HIST_PVC_DT_CRIACAO.';
END
ELSE
    PRINT '  E1 - nenhum DEFAULT nessa coluna (esperado: as HIST nasceram sem DEFAULT).';
GO

/* =====================================================================
   E2 - CONFERÊNCIA
   ===================================================================== */
SELECT  COLUNA  = c.name,
        TIPO    = ty.name + '(' + CAST(c.scale AS VARCHAR(10)) + ')',
        NULO    = CASE WHEN c.is_nullable = 1 THEN 'SIM' ELSE 'NAO' END,
        POSICAO = c.column_id
FROM        sys.columns c
JOIN        sys.types  ty ON ty.user_type_id = c.user_type_id
WHERE       c.object_id = OBJECT_ID('CI.KZN_HIST_PEDRAVISAOCONSOLIDADA')
  AND       c.name IN ('DT_CRIACAO', 'DT_ATUALIZACAO');

/* Tabela vazia = a carga provavelmente ainda não rodou, e o
   carga_hist_2026_7281_7296.sql ainda cita o nome antigo. */
DECLARE @linhas INT = (SELECT COUNT(*) FROM CI.KZN_HIST_PEDRAVISAOCONSOLIDADA);
PRINT 'Linhas em CI.KZN_HIST_PEDRAVISAOCONSOLIDADA: ' + CAST(@linhas AS VARCHAR(20));
IF @linhas = 0
    PRINT 'AVISO: tabela vazia. Se a carga ainda nao rodou, o carga_hist_2026_7281_7296.sql precisa ter DT_ATUALIZACAO trocado por DT_CRIACAO na lista de colunas do INSERT antes de rodar.';

/* Estrutura das duas tabelas lado a lado: o que aparecer aqui está
   divergente entre produção e histórico. */
SELECT  COLUNA       = ISNULL(p.name, h.name),
        NA_PRODUCAO  = ISNULL(p.name, '-- ausente --'),
        NO_HISTORICO = ISNULL(h.name, '-- ausente --')
FROM        (SELECT name FROM sys.columns WHERE object_id = OBJECT_ID('CI.KZN_PEDRAVISAOCONSOLIDADA')) p
FULL JOIN   (SELECT name FROM sys.columns WHERE object_id = OBJECT_ID('CI.KZN_HIST_PEDRAVISAOCONSOLIDADA')) h
       ON   h.name COLLATE DATABASE_DEFAULT = p.name COLLATE DATABASE_DEFAULT
WHERE       p.name IS NULL OR h.name IS NULL;
GO
