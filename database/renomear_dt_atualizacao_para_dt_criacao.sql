/* =====================================================================
   CI.KZN_PEDRAVISAOCONSOLIDADA — DT_ATUALIZACAO passa a DT_CRIACAO
   ---------------------------------------------------------------------
   Renomeia a coluna (e o DEFAULT que a acompanha) e reescreve o trigger
   de UPDATE, que hoje depende do nome antigo.

   ---------------------------------------------------------------------
   ATENÇÃO — ESTA NÃO É UMA RENOMEAÇÃO PURAMENTE COSMÉTICA

   O trigger TR_KZN_PVC_UPD faz hoje duas coisas com essa coluna:

     1. carimba SYSDATETIME() nela a CADA UPDATE ("auto-touch"), que é o
        comportamento correto para uma data de ATUALIZAÇÃO;
     2. usa o valor dela como DT_OPERACAO da linha de auditoria.

   Com a coluna virando DT_CRIACAO, manter o item 1 seria destrutivo: a
   data de criação seria SOBRESCRITA a cada edição do Kaizen, e a
   informação original se perderia em silêncio, sem erro nenhum.

   Por isso o trigger é reescrito COM DUAS MUDANÇAS DE COMPORTAMENTO:

     - o auto-touch é REMOVIDO. DT_CRIACAO passa a guardar o valor
       gravado no INSERT e não é mais alterada por UPDATE;
     - o DT_OPERACAO do log passa a vir de SYSDATETIME() (o instante real
       da operação) em vez da coluna — que agora significa outra coisa.

   Se você QUISER manter o auto-touch (ou seja, tratar DT_CRIACAO como
   "última alteração" apesar do nome), reinsira estas 3 linhas no início
   do corpo do trigger, logo após o SET NOCOUNT ON:

       IF NOT UPDATE(DT_CRIACAO)
           UPDATE T SET DT_CRIACAO = SYSDATETIME()
           FROM CI.KZN_PEDRAVISAOCONSOLIDADA T JOIN inserted i ON i.ID_KAIZEN = T.ID_KAIZEN;

   ---------------------------------------------------------------------
   OBSERVAÇÃO DE MODELAGEM

   Numa rodada anterior a coluna DT_CRIACAO foi REMOVIDA desta tabela, e
   a data de criação passou a viver na linha 'C' de
   CI.KZN_LOG_PEDRAVISAOCONSOLIDADA (DT_OPERACAO). Com esta alteração o
   nome DT_CRIACAO volta à tabela — mas carregando os valores que hoje
   estão em DT_ATUALIZACAO, que são de ÚLTIMA ALTERAÇÃO, não de criação.

   Ou seja: para os Kaizens já existentes, DT_CRIACAO passará a conter a
   data da última edição. Se a intenção é ter a data de criação de
   verdade, o valor correto está no log e pode ser trazido com:

       UPDATE p SET p.DT_CRIACAO = l.DT_OPERACAO
       FROM   CI.KZN_PEDRAVISAOCONSOLIDADA p
       JOIN   CI.KZN_LOG_PEDRAVISAOCONSOLIDADA l
              ON l.ID_KAIZEN = p.ID_KAIZEN AND l.TP_OPERACAO = 'C';

   Esse UPDATE NÃO é executado por este script — é decisão sua.

   ---------------------------------------------------------------------
   IMPACTO NA APLICAÇÃO: server.js referencia DT_ATUALIZACAO em 28
   pontos. Todos quebram até serem ajustados.

   É IDEMPOTENTE: se a coluna já se chamar DT_CRIACAO, não faz nada.

   Schema: 'ci'.
   ===================================================================== */

SET NOCOUNT ON;
SET XACT_ABORT ON;

/* =====================================================================
   E0 - PRÉ-CHECAGENS
   ===================================================================== */
IF OBJECT_ID('CI.KZN_PEDRAVISAOCONSOLIDADA', 'U') IS NULL
BEGIN
    RAISERROR('Abortado: CI.KZN_PEDRAVISAOCONSOLIDADA não existe neste banco.', 16, 1);
    RETURN;
END

IF COL_LENGTH('CI.KZN_PEDRAVISAOCONSOLIDADA', 'DT_ATUALIZACAO') IS NULL
BEGIN
    PRINT 'Nada a fazer - DT_ATUALIZACAO já não existe (renomeação provavelmente já aplicada).';
    RETURN;
END

IF COL_LENGTH('CI.KZN_PEDRAVISAOCONSOLIDADA', 'DT_CRIACAO') IS NOT NULL
BEGIN
    RAISERROR('Abortado: já existe uma coluna DT_CRIACAO na tabela. Renomear DT_ATUALIZACAO para esse nome criaria duplicidade.', 16, 1);
    RETURN;
END

/* O trigger recriado na E2 é escrito para o conjunto de colunas ATUAL
   (pós-renomeações DS_COMPARA_META e DS_RESULTADO_ALCANCADO). Se essas
   colunas não existirem, o banco está num estado anterior e o trigger
   sairia referenciando coluna inexistente. */
IF COL_LENGTH('CI.KZN_PEDRAVISAOCONSOLIDADA', 'DS_COMPARA_META') IS NULL
   OR COL_LENGTH('CI.KZN_PEDRAVISAOCONSOLIDADA', 'DS_RESULTADO_ALCANCADO') IS NULL
BEGIN
    RAISERROR('Abortado: faltam DS_COMPARA_META e/ou DS_RESULTADO_ALCANCADO. Rode renomear_campos_pvc.sql antes - o trigger recriado aqui pressupõe o conjunto de colunas atual.', 16, 1);
    RETURN;
END

/* Sem GO até o fim da E1, DE PROPÓSITO: RAISERROR + RETURN encerram
   apenas o batch em que aparecem. Com um GO aqui, um aborto acima não
   impediria a renomeação logo abaixo de acontecer. */

/* =====================================================================
   E1 - RENOMEIA A COLUNA E O DEFAULT
   ===================================================================== */
DECLARE @df SYSNAME, @sql NVARCHAR(MAX);

/* Nome do DEFAULT descoberto por metadados: em bancos migrados a mão ele
   pode não se chamar DF_KZN_PVC_DT_ATUALIZACAO. sp_rename de coluna NÃO
   renomeia a constraint que a acompanha - por isso o passo separado. */
SELECT @df = dc.name
FROM   sys.default_constraints dc
WHERE  dc.parent_object_id = OBJECT_ID('CI.KZN_PEDRAVISAOCONSOLIDADA')
  AND  dc.parent_column_id = COLUMNPROPERTY(OBJECT_ID('CI.KZN_PEDRAVISAOCONSOLIDADA'), 'DT_ATUALIZACAO', 'ColumnId');

EXEC sp_rename 'CI.KZN_PEDRAVISAOCONSOLIDADA.DT_ATUALIZACAO', 'DT_CRIACAO', 'COLUMN';
PRINT 'E1 ok - coluna renomeada para DT_CRIACAO.';

IF @df IS NOT NULL AND @df <> 'DF_KZN_PVC_DT_CRIACAO'
BEGIN
    SET @sql = N'EXEC sp_rename ''CI.' + @df + N''', ''DF_KZN_PVC_DT_CRIACAO'', ''OBJECT'';';
    EXEC sp_executesql @sql;
    PRINT '  E1 - DEFAULT ' + @df + ' renomeado para DF_KZN_PVC_DT_CRIACAO.';
END
ELSE
    PRINT '  E1 - nenhum DEFAULT a renomear.';
GO

/* =====================================================================
   E2 - TRIGGER DE UPDATE na versão correta para DT_CRIACAO
   ---------------------------------------------------------------------
   Sem o bloco de auto-touch (ver cabeçalho) e com DT_OPERACAO vindo de
   SYSDATETIME(). O trigger de INSERT não referencia esta coluna e não
   precisa ser tocado.
   ===================================================================== */
CREATE OR ALTER TRIGGER CI.TR_KZN_PVC_UPD ON CI.KZN_PEDRAVISAOCONSOLIDADA AFTER UPDATE AS
BEGIN
    SET NOCOUNT ON;

    -- DT_CRIACAO NÃO é mais carimbada aqui: é data de criação, gravada no
    -- INSERT, e sobrescrevê-la a cada UPDATE destruiria o dado original.

    -- Uma linha de cabeçalho de log por Kaizen afetado, capturando o
    -- ID_LOG recém-gerado (OUTPUT) pra ligar as linhas de detalhe geradas
    -- logo abaixo — necessário porque um único UPDATE pode afetar mais de
    -- um Kaizen de uma vez, cada um com seu próprio ID_LOG.
    DECLARE @logMap TABLE (ID_KAIZEN INT NOT NULL PRIMARY KEY, ID_LOG INT NOT NULL);

    -- DT_OPERACAO = SYSDATETIME(): o instante real da alteração. Antes
    -- vinha da coluna DT_ATUALIZACAO, que deixou de existir.
    INSERT INTO CI.KZN_LOG_PEDRAVISAOCONSOLIDADA (ID_LOG, ID_KAIZEN, TP_OPERACAO, DT_OPERACAO, ID_USUARIO_OPERACAO)
    OUTPUT inserted.ID_KAIZEN, inserted.ID_LOG INTO @logMap (ID_KAIZEN, ID_LOG)
    SELECT NEXT VALUE FOR CI.SEQ_KZN_LOG_PVC, i.ID_KAIZEN, 'A', SYSDATETIME(), i.ID_USUARIO_ATUALIZACAO
    FROM inserted i;

    -- Diff campo a campo — 1 linha por coluna de negócio cujo valor mudou
    -- nesta atualização. Comparação NULL-segura: "NOT (d.COL = i.COL OR
    -- (d.COL IS NULL AND i.COL IS NULL))" trata NULL=NULL como "não mudou"
    -- e qualquer outra combinação (incluindo um lado NULL) como mudança.
    -- DT_CRIACAO e ID_USUARIO_ATUALIZACAO ficam de fora: a primeira não
    -- muda, o segundo é metadado do cabeçalho gravado acima.
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
    ) x;
END
GO

PRINT 'E2 ok - TR_KZN_PVC_UPD recriado sem auto-touch e sem referência a DT_ATUALIZACAO.';
GO

/* =====================================================================
   E3 - CONFERÊNCIA
   ===================================================================== */
SELECT  COLUNA  = c.name,
        TIPO    = ty.name + '(' + CAST(c.scale AS VARCHAR(10)) + ')',
        NULO    = CASE WHEN c.is_nullable = 1 THEN 'SIM' ELSE 'NAO' END,
        POSICAO = c.column_id,
        DEFAULT_ = dc.name
FROM        sys.columns c
JOIN        sys.types  ty ON ty.user_type_id = c.user_type_id
LEFT JOIN   sys.default_constraints dc ON dc.parent_object_id = c.object_id AND dc.parent_column_id = c.column_id
WHERE       c.object_id = OBJECT_ID('CI.KZN_PEDRAVISAOCONSOLIDADA')
  AND       c.name IN ('DT_CRIACAO', 'DT_ATUALIZACAO');

/* Nenhum objeto pode continuar citando o nome antigo. */
SELECT  OBJETO_COM_NOME_ANTIGO = OBJECT_NAME(m.object_id),
        TIPO = o.type_desc
FROM    sys.sql_modules m
JOIN    sys.objects o ON o.object_id = m.object_id
WHERE   m.definition LIKE '%DT_ATUALIZACAO%'
  AND   o.parent_object_id = OBJECT_ID('CI.KZN_PEDRAVISAOCONSOLIDADA');
GO
