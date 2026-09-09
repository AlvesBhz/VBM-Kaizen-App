/* =====================================================================
   Remove a coluna DT_CRIACAO de CI.KZN_PEDRAVISAOCONSOLIDADA
   ---------------------------------------------------------------------
   A tabela passa de 25 para 24 colunas.

   ---------------------------------------------------------------------
   ATENCAO - A DATA DE CRIACAO NAO SE PERDE, MAS MUDA DE LUGAR

   DT_CRIACAO e hoje a unica coluna que guarda QUANDO o Kaizen foi
   criado. Apagar a coluna sem mais nada destruiria esse dado.

   Este script NAO faz isso: a etapa E1 garante, ANTES de qualquer
   remocao, que todo Kaizen tenha sua linha de criacao ('C') em
   CI.KZN_LOG_PEDRAVISAOCONSOLIDADA com o DT_OPERACAO igual ao
   DT_CRIACAO atual. Depois da remocao, a data de criacao continua
   disponivel assim:

       SELECT p.ID_KAIZEN, DT_CRIACAO = l.DT_OPERACAO
       FROM   CI.KZN_PEDRAVISAOCONSOLIDADA p
       LEFT JOIN CI.KZN_LOG_PEDRAVISAOCONSOLIDADA l
              ON l.ID_KAIZEN = p.ID_KAIZEN AND l.TP_OPERACAO = 'C';

   Se a tabela de log nao existir, o script ABORTA sem apagar nada -
   nesse cenario a remocao seria perda definitiva de dado.

   ---------------------------------------------------------------------
   IMPACTO NA APLICACAO - LEIA ANTES DE RODAR

   Diferente das mudancas anteriores, esta QUEBRA o codigo hoje em
   producao. DT_CRIACAO aparece 13 vezes no server.js e mais 4 no
   front-end (aprovacao.html, biblioteca.html), entre elas:

     - rotuloIdKaizen(): monta o codigo exibido do Kaizen ("KZN25-001")
       a partir do ANO de DT_CRIACAO. Sem a coluna, cai no ano corrente
       e o codigo exibido muda para Kaizens antigos;
     - filtro e agrupamento por ano (YEAR(DT_CRIACAO));
     - ordenacao da Biblioteca (ORDER BY ISNULL(DT_CONCLUSAO, DT_CRIACAO));
     - o INSERT de Kaizen, que ainda lista DT_CRIACAO nas colunas.

   O server.js e o front-end precisam ser ajustados para ler a data do
   log (consulta acima) ANTES ou JUNTO com a execucao deste script.
   Rodar so o script deixa a aplicacao com erro nesses pontos.

   ---------------------------------------------------------------------
   ORDEM DAS ETAPAS (importa)

   Os triggers sao recriados na versao nova ANTES de a coluna ser
   removida - assim nao existe nenhum instante em que um trigger ativo
   referencia uma coluna que ja nao existe (foi exatamente esse tipo de
   janela que produziu os erros "Invalid column name 'ID_MOTIVO'").

   E idempotente: pode ser reexecutado sem efeito se a coluna ja tiver
   sido removida.

   PRE-REQUISITO: rode antes o atualizar_pvc_e_logs_in_place.sql.
   RECOMENDADO: backup do banco.

   Schema: 'ci' (AZURE_SQL_SCHEMA em app.yaml).
   ===================================================================== */

SET NOCOUNT ON;
SET XACT_ABORT ON;

/* =====================================================================
   E0 - PRE-CHECAGENS
   ===================================================================== */
IF OBJECT_ID('CI.KZN_PEDRAVISAOCONSOLIDADA', 'U') IS NULL
BEGIN
    RAISERROR('Abortado: CI.KZN_PEDRAVISAOCONSOLIDADA nao existe neste banco.', 16, 1);
    RETURN;
END

IF NOT EXISTS (SELECT 1 FROM sys.columns
               WHERE object_id = OBJECT_ID('CI.KZN_PEDRAVISAOCONSOLIDADA') AND name = 'DT_CRIACAO')
BEGIN
    PRINT 'Nada a fazer - DT_CRIACAO ja foi removida de CI.KZN_PEDRAVISAOCONSOLIDADA.';
    RETURN;
END

/* Sem a tabela de log, remover a coluna seria perder a data de criacao
   em definitivo. Melhor parar. */
IF OBJECT_ID('CI.KZN_LOG_PEDRAVISAOCONSOLIDADA', 'U') IS NULL
BEGIN
    RAISERROR('Abortado: CI.KZN_LOG_PEDRAVISAOCONSOLIDADA nao existe - sem ela, remover DT_CRIACAO destruiria a data de criacao sem backup. Rode o atualizar_pvc_e_logs_in_place.sql primeiro.', 16, 1);
    RETURN;
END

IF OBJECT_ID('CI.SEQ_KZN_LOG_PVC', 'SO') IS NULL
BEGIN
    RAISERROR('Abortado: a sequence CI.SEQ_KZN_LOG_PVC nao existe - sem ela nao da para gerar ID_LOG no backfill. Rode o atualizar_pvc_e_logs_in_place.sql primeiro.', 16, 1);
    RETURN;
END
GO

/* =====================================================================
   E1 - BACKFILL: preserva a data de criacao no log de auditoria
   ---------------------------------------------------------------------
   Cria a linha 'C' que estiver faltando, carimbando DT_OPERACAO com o
   DT_CRIACAO atual. Kaizens que JA tem linha 'C' nao sao tocados: o log
   e o registro do que de fato aconteceu e nao deve ser reescrito.

   SQL dinamico: DT_CRIACAO pode nao existir numa 2a execucao, e uma
   referencia estatica a coluna ausente quebraria a compilacao do batch
   inteiro (T-SQL nao faz resolucao de nomes adiada em batch avulso).
   ===================================================================== */
DECLARE @criadas INT = 0;

IF OBJECT_ID('CI.KZN_LOG_PEDRAVISAOCONSOLIDADA','U') IS NOT NULL
   AND EXISTS (SELECT 1 FROM sys.columns
               WHERE object_id = OBJECT_ID('CI.KZN_PEDRAVISAOCONSOLIDADA') AND name = 'DT_CRIACAO')
BEGIN
    /* @@ROWCOUNT depois de um EXEC e fragil - o valor volta por OUTPUT. */
    EXEC sp_executesql N'
        INSERT INTO CI.KZN_LOG_PEDRAVISAOCONSOLIDADA (ID_LOG, ID_KAIZEN, TP_OPERACAO, DT_OPERACAO, ID_USUARIO_OPERACAO)
        SELECT NEXT VALUE FOR CI.SEQ_KZN_LOG_PVC, p.ID_KAIZEN, ''C'', p.DT_CRIACAO, p.ID_USUARIO_CADASTRO
        FROM   CI.KZN_PEDRAVISAOCONSOLIDADA p
        WHERE  NOT EXISTS (SELECT 1 FROM CI.KZN_LOG_PEDRAVISAOCONSOLIDADA l
                           WHERE l.ID_KAIZEN = p.ID_KAIZEN AND l.TP_OPERACAO = ''C'');
        SET @qt = @@ROWCOUNT;',
        N'@qt INT OUTPUT', @qt = @criadas OUTPUT;

    PRINT 'E1 ok - ' + CAST(@criadas AS VARCHAR(10)) + ' linha(s) de criacao gravada(s) no log a partir de DT_CRIACAO.';
END
ELSE
    PRINT 'E1 pulada - DT_CRIACAO ja removida ou tabela de log ausente.';
GO

/* =====================================================================
   E2 - TRIGGERS na versao sem DT_CRIACAO
   ---------------------------------------------------------------------
   Recriados ANTES do DROP COLUMN, para que nunca exista um trigger ativo
   citando uma coluna inexistente.

   TR_KZN_PVC_INS: DT_OPERACAO passa a vir de SYSDATETIME() em vez de
   DT_CRIACAO - e o mesmo instante, ja que o trigger roda no INSERT.
   TR_KZN_PVC_UPD: o bloco de diff de DT_CRIACAO some (a coluna nao
   existe mais para ser auditada).
   ===================================================================== */
CREATE OR ALTER TRIGGER CI.TR_KZN_PVC_INS ON CI.KZN_PEDRAVISAOCONSOLIDADA AFTER INSERT AS
BEGIN
    SET NOCOUNT ON;
    INSERT INTO CI.KZN_LOG_PEDRAVISAOCONSOLIDADA (ID_LOG, ID_KAIZEN, TP_OPERACAO, DT_OPERACAO, ID_USUARIO_OPERACAO)
    SELECT NEXT VALUE FOR CI.SEQ_KZN_LOG_PVC, ID_KAIZEN, 'C', SYSDATETIME(), ID_USUARIO_CADASTRO
    FROM inserted;
    -- Sem linha de detalhe aqui: criacao nao tem "valor anterior" a comparar.
    -- Esta linha 'C' passou a ser o UNICO registro da data de criacao do
    -- Kaizen, no lugar da antiga coluna DT_CRIACAO.
END
GO

CREATE OR ALTER TRIGGER CI.TR_KZN_PVC_UPD ON CI.KZN_PEDRAVISAOCONSOLIDADA AFTER UPDATE AS
BEGIN
    SET NOCOUNT ON;

    IF NOT UPDATE(DT_ATUALIZACAO)
        UPDATE T SET DT_ATUALIZACAO = SYSDATETIME()
        FROM CI.KZN_PEDRAVISAOCONSOLIDADA T JOIN inserted i ON i.ID_KAIZEN = T.ID_KAIZEN;

    -- Uma linha de cabecalho de log por Kaizen afetado, capturando o
    -- ID_LOG recem-gerado (OUTPUT) pra ligar as linhas de detalhe geradas
    -- logo abaixo — necessario porque um unico UPDATE pode afetar mais de
    -- um Kaizen de uma vez, cada um com seu proprio ID_LOG.
    DECLARE @logMap TABLE (ID_KAIZEN INT NOT NULL PRIMARY KEY, ID_LOG INT NOT NULL);

    -- Rele DT_ATUALIZACAO ja corrigida acima, pra nao gravar um SYSDATETIME()
    -- ligeiramente diferente do que efetivamente ficou salvo na linha.
    INSERT INTO CI.KZN_LOG_PEDRAVISAOCONSOLIDADA (ID_LOG, ID_KAIZEN, TP_OPERACAO, DT_OPERACAO, ID_USUARIO_OPERACAO)
    OUTPUT inserted.ID_KAIZEN, inserted.ID_LOG INTO @logMap (ID_KAIZEN, ID_LOG)
    SELECT NEXT VALUE FOR CI.SEQ_KZN_LOG_PVC, i.ID_KAIZEN, 'A', T.DT_ATUALIZACAO, i.ID_USUARIO_ATUALIZACAO
    FROM inserted i
    JOIN CI.KZN_PEDRAVISAOCONSOLIDADA T ON T.ID_KAIZEN = i.ID_KAIZEN;

    -- Diff campo a campo — 1 linha por coluna de negocio cujo valor mudou
    -- nesta atualizacao. Comparacao NULL-segura: "NOT (d.COL = i.COL OR
    -- (d.COL IS NULL AND i.COL IS NULL))" trata NULL=NULL como "nao mudou"
    -- e qualquer outra combinacao (incluindo um lado NULL) como mudanca.
    -- DT_ATUALIZACAO e ID_USUARIO_ATUALIZACAO ficam de fora: ja sao o
    -- metadado do cabecalho gravado acima, nao conteudo auditado.
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

PRINT 'E2 ok - triggers recriados sem referencia a DT_CRIACAO.';
GO

/* =====================================================================
   E3 - REMOVE AS AMARRACOES DA COLUNA E DEPOIS A COLUNA
   ---------------------------------------------------------------------
   O nome do DEFAULT e descoberto por metadados (sys.default_constraints)
   em vez de fixado como 'DF_KZN_PVC_DT_CRIACAO': em bancos onde a tabela
   nasceu pela migracao 17.3, ele pode ter outro nome.

   TRAVA DE SEGURANCA: esta etapa reverifica as pre-condicoes por conta
   propria, sem depender das checagens anteriores. RAISERROR + RETURN so
   encerram o BATCH em que aparecem - os batches seguintes continuam
   rodando (foi o que aconteceu na execucao anterior, em que a E1 abortou
   e a E2 rodou assim mesmo). Sem esta trava, um aborto la em cima ainda
   deixaria a coluna ser apagada aqui, que e justamente o cenario de
   perda de dado que o script existe para evitar.
   ===================================================================== */
DECLARE @sql NVARCHAR(MAX), @nome SYSNAME, @semLog INT;

IF NOT EXISTS (SELECT 1 FROM sys.columns
               WHERE object_id = OBJECT_ID('CI.KZN_PEDRAVISAOCONSOLIDADA') AND name = 'DT_CRIACAO')
BEGIN
    PRINT 'E3 pulada - DT_CRIACAO ja nao existe.';
    RETURN;
END

IF OBJECT_ID('CI.KZN_LOG_PEDRAVISAOCONSOLIDADA','U') IS NULL
BEGIN
    RAISERROR('E3 NAO EXECUTADA: CI.KZN_LOG_PEDRAVISAOCONSOLIDADA nao existe. DT_CRIACAO foi PRESERVADA - remove-la agora destruiria a data de criacao sem backup.', 16, 1);
    RETURN;
END

/* Nenhum Kaizen pode ficar sem sua linha 'C': e nela que a data de
   criacao passa a viver. Se sobrar algum, a coluna NAO e removida. */
SELECT @semLog = COUNT(*)
FROM   CI.KZN_PEDRAVISAOCONSOLIDADA p
WHERE  NOT EXISTS (SELECT 1 FROM CI.KZN_LOG_PEDRAVISAOCONSOLIDADA l
                   WHERE l.ID_KAIZEN = p.ID_KAIZEN AND l.TP_OPERACAO = 'C');

IF @semLog > 0
BEGIN
    RAISERROR('E3 NAO EXECUTADA: %d Kaizen(s) sem linha de criacao no log. DT_CRIACAO foi PRESERVADA - a data de criacao desses registros se perderia. Investigue a E1 antes de rodar de novo.', 16, 1, @semLog);
    RETURN;
END

PRINT 'E3 - pre-condicoes reconferidas: a data de criacao de todos os Kaizens esta no log. Prosseguindo.';

/* 3.1 - DEFAULT da coluna */
SELECT @nome = dc.name
FROM   sys.default_constraints dc
WHERE  dc.parent_object_id = OBJECT_ID('CI.KZN_PEDRAVISAOCONSOLIDADA')
  AND  dc.parent_column_id = COLUMNPROPERTY(OBJECT_ID('CI.KZN_PEDRAVISAOCONSOLIDADA'), 'DT_CRIACAO', 'ColumnId');

IF @nome IS NOT NULL
BEGIN
    SET @sql = N'ALTER TABLE CI.KZN_PEDRAVISAOCONSOLIDADA DROP CONSTRAINT ' + QUOTENAME(@nome) + N';';
    EXEC sp_executesql @sql;
    PRINT '  E3.1 ok - DEFAULT ' + @nome + ' removido.';
END
ELSE
    PRINT '  E3.1 - nenhum DEFAULT em DT_CRIACAO.';

/* 3.2 - indices que usem a coluna (chave ou INCLUDE) */
DECLARE @idx TABLE (SEQ INT IDENTITY(1,1) PRIMARY KEY, NOME SYSNAME);
INSERT INTO @idx (NOME)
SELECT DISTINCT i.name
FROM   sys.indexes i
JOIN   sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id
WHERE  i.object_id = OBJECT_ID('CI.KZN_PEDRAVISAOCONSOLIDADA')
  AND  i.is_primary_key = 0 AND i.is_unique_constraint = 0 AND i.name IS NOT NULL
  AND  ic.column_id = COLUMNPROPERTY(OBJECT_ID('CI.KZN_PEDRAVISAOCONSOLIDADA'), 'DT_CRIACAO', 'ColumnId');

DECLARE @i INT = 1, @n INT = (SELECT ISNULL(MAX(SEQ), 0) FROM @idx);
WHILE @i <= @n
BEGIN
    SELECT @nome = NOME FROM @idx WHERE SEQ = @i;
    SET @sql = N'DROP INDEX ' + QUOTENAME(@nome) + N' ON CI.KZN_PEDRAVISAOCONSOLIDADA;';
    EXEC sp_executesql @sql;
    PRINT '  E3.2 ok - indice ' + @nome + ' removido (usava DT_CRIACAO).';
    SET @i += 1;
END
IF @n = 0 PRINT '  E3.2 - nenhum indice usava DT_CRIACAO.';

/* 3.3 - a coluna */
EXEC sp_executesql N'ALTER TABLE CI.KZN_PEDRAVISAOCONSOLIDADA DROP COLUMN DT_CRIACAO;';
PRINT '  E3.3 ok - coluna DT_CRIACAO removida. A tabela agora tem 24 colunas.';
GO

/* =====================================================================
   E4 - CONFERENCIA
   ===================================================================== */
SELECT  COLUNAS_NA_TABELA = COUNT(*),
        AINDA_TEM_DT_CRIACAO = CASE WHEN SUM(CASE WHEN name = 'DT_CRIACAO' THEN 1 ELSE 0 END) > 0 THEN 'SIM' ELSE 'NAO' END
FROM    sys.columns
WHERE   object_id = OBJECT_ID('CI.KZN_PEDRAVISAOCONSOLIDADA');

/* A data de criacao, agora lida do log — e assim que a aplicacao deve
   passar a obte-la. */
SELECT TOP (20)
        p.ID_KAIZEN,
        p.NM_KAIZEN,
        DT_CRIACAO_VIA_LOG = l.DT_OPERACAO,
        CRIADO_POR         = l.ID_USUARIO_OPERACAO
FROM        CI.KZN_PEDRAVISAOCONSOLIDADA p
LEFT JOIN   CI.KZN_LOG_PEDRAVISAOCONSOLIDADA l
       ON   l.ID_KAIZEN = p.ID_KAIZEN AND l.TP_OPERACAO = 'C'
ORDER BY    p.ID_KAIZEN;
GO
