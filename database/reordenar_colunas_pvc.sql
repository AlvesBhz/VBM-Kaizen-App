/* =====================================================================
   Reordena as colunas fisicas de CI.KZN_PEDRAVISAOCONSOLIDADA
   ---------------------------------------------------------------------
   OBJETIVO: colocar ID_STATUS na 9a posicao e DS_MOTIVO na 23a, deixando
   a ordem fisica das 25 colunas identica a do DER. As duas entraram por
   "ALTER TABLE ... ADD" em migracoes anteriores e foram parar no fim da
   tabela.

   O SQL Server NAO tem "mover coluna": o column_id e definido na criacao
   e nunca muda. Reordenar coluna E recriar a tabela - e exatamente isso
   que o designer do SSMS faz por baixo. Este script faz o mesmo, mas de
   forma auditavel e PRESERVANDO OS DADOS:

     1. captura, por metadados, tudo que esta amarrado a tabela hoje
        (FKs que entram, FKs que saem, PK, indices, defaults, checks,
        constraints unique e os triggers);
     2. cria CI.KZN_PVC_NEW com as colunas na ordem correta;
     3. copia todas as linhas e CONFERE a contagem;
     4. dropa a tabela antiga e renomeia a nova;
     5. recria tudo que capturou no passo 1.

   NADA e escrito a mao aqui: tipos, nulidade, nomes de constraint e
   corpo dos triggers saem do proprio banco. Se o banco real divergir do
   DDL de referencia (ja aconteceu nesta aplicacao), o script segue a
   realidade do banco, nao a minha lista.

   ---------------------------------------------------------------------
   SEGURANCA

   - TUDO roda em UMA transacao com TRY/CATCH + XACT_ABORT ON. Qualquer
     erro em qualquer etapa faz ROLLBACK e a tabela original volta
     intacta, com todas as amarracoes. Nao existe estado "pela metade".
   - A copia so prossegue se a contagem de linhas da tabela nova bater
     exatamente com a da antiga.
   - E IDEMPOTENTE: se a ordem ja estiver correta, o script avisa e sai
     sem tocar em nada.

   ---------------------------------------------------------------------
   PRE-REQUISITO - LEIA ANTES DE RODAR

   Rode ANTES o atualizar_pvc_e_logs_in_place.sql. Este script recria os
   triggers a partir do que esta gravado no banco AGORA: se os triggers
   ainda forem a versao antiga (a que cita ID_MOTIVO), ele restauraria
   fielmente a versao quebrada. Por isso a etapa E0 aborta se encontrar
   ID_MOTIVO ou SG_STATUS no corpo de algum trigger.

   RECOMENDADO: faca backup do banco antes. E uma operacao destrutiva por
   natureza (DROP TABLE), ainda que transacionada.

   JANELA: a tabela fica inacessivel durante a execucao. Rode fora do
   horario de uso.

   ---------------------------------------------------------------------
   IMPACTO NA APLICACAO: nenhum. O server.js nomeia todas as colunas
   explicitamente em todas as consultas (nao ha nenhum "SELECT *"), entao
   a ordem fisica e cosmetica para o codigo - ela so muda o que se ve ao
   abrir a tabela no SSMS.

   Schema: 'ci' (AZURE_SQL_SCHEMA em app.yaml).
   ===================================================================== */

SET NOCOUNT ON;
SET XACT_ABORT ON;

/* Tudo num unico batch, de proposito: as etapas compartilham variaveis de
   tabela e o RETURN das pre-checagens precisa impedir a parte destrutiva.
   Toda DDL vai por sp_executesql - alem de permitir CREATE TRIGGER dentro
   da transacao (precisa ser a 1a instrucao do seu batch), evita que uma
   referencia estatica a KZN_PVC_NEW (que ainda nao existe na compilacao)
   quebre o batch inteiro: T-SQL nao faz resolucao de nomes adiada. */

DECLARE @tbl     SYSNAME = 'CI.KZN_PEDRAVISAOCONSOLIDADA';
DECLARE @tblNew  SYSNAME = 'CI.KZN_PVC_NEW';
DECLARE @objId   INT     = OBJECT_ID(@tbl, 'U');
DECLARE @sql     NVARCHAR(MAX);
DECLARE @cols    NVARCHAR(MAX);
DECLARE @colList NVARCHAR(MAX);
DECLARE @qt      INT;

/* =====================================================================
   E0 - PRE-CHECAGENS
   ===================================================================== */
IF @objId IS NULL
BEGIN
    RAISERROR('Abortado: CI.KZN_PEDRAVISAOCONSOLIDADA nao existe neste banco.', 16, 1);
    RETURN;
END

/* Ordem-alvo: as 25 colunas exatamente como aparecem no DER. */
DECLARE @ordem TABLE (POS INT PRIMARY KEY, NM SYSNAME);
INSERT INTO @ordem (POS, NM) VALUES
    ( 1, 'ID_KAIZEN'),              ( 2, 'ID_USUARIO_CADASTRO'),
    ( 3, 'ID_USUARIO_LIDER'),       ( 4, 'NM_KAIZEN'),
    ( 5, 'ID_CATEGORIA'),           ( 6, 'ID_REPLICACAO'),
    ( 7, 'DS_PROBLEMA'),            ( 8, 'DS_OBJETIVO'),
    ( 9, 'ID_STATUS'),              (10, 'ID_APROVADOR'),
    (11, 'URL_IMG_ANTES'),          (12, 'DS_ESTADO_ANTES'),
    (13, 'URL_IMG_DEPOIS'),         (14, 'DS_ESTADO_DEPOIS'),
    (15, 'URL_REFERENCIA'),         (16, 'ID_DESPERDICIO'),
    (17, 'DS_LICOES_APRENDIDAS'),   (18, 'VL_RESULTADO_FINANCEIRO'),
    (19, 'ID_MOEDA'),               (20, 'DS_RESULTADO_ESPERADO'),
    (21, 'DT_CRIACAO'),             (22, 'DT_CONCLUSAO'),
    (23, 'DS_MOTIVO'),              (24, 'DT_ATUALIZACAO'),
    (25, 'ID_USUARIO_ATUALIZACAO');

/* E0.1 - a tabela real precisa ter EXATAMENTE essas 25 colunas. Um
   descompasso (coluna faltando ou coluna extra que a lista nao preve)
   significaria perda silenciosa de dados na copia - entao aborta. */
SELECT @qt = COUNT(*) FROM @ordem o
WHERE NOT EXISTS (SELECT 1 FROM sys.columns c WHERE c.object_id = @objId AND c.name = o.NM);
IF @qt > 0
BEGIN
    SELECT COLUNA_ESPERADA_QUE_NAO_EXISTE = o.NM FROM @ordem o
    WHERE NOT EXISTS (SELECT 1 FROM sys.columns c WHERE c.object_id = @objId AND c.name = o.NM)
    ORDER BY o.POS;
    RAISERROR('Abortado: %d coluna(s) da ordem-alvo nao existem na tabela (lista acima). Rode o atualizar_pvc_e_logs_in_place.sql antes.', 16, 1, @qt);
    RETURN;
END

SELECT @qt = COUNT(*) FROM sys.columns c
WHERE c.object_id = @objId AND NOT EXISTS (SELECT 1 FROM @ordem o WHERE o.NM = c.name);
IF @qt > 0
BEGIN
    SELECT COLUNA_NA_TABELA_FORA_DA_ORDEM_ALVO = c.name FROM sys.columns c
    WHERE c.object_id = @objId AND NOT EXISTS (SELECT 1 FROM @ordem o WHERE o.NM = c.name)
    ORDER BY c.column_id;
    RAISERROR('Abortado: a tabela tem %d coluna(s) que a ordem-alvo nao preve (lista acima). Copiar assim perderia esses dados - atualize a lista @ordem antes.', 16, 1, @qt);
    RETURN;
END

/* E0.2 - colunas calculadas ou IDENTITY nao sao tratadas pelo gerador de
   tipos abaixo; se aparecerem, e mais seguro parar do que gerar DDL errada. */
IF EXISTS (SELECT 1 FROM sys.columns WHERE object_id = @objId AND (is_computed = 1 OR is_identity = 1))
BEGIN
    RAISERROR('Abortado: a tabela tem coluna calculada ou IDENTITY - este script nao script-a esses casos.', 16, 1);
    RETURN;
END

/* E0.3 - triggers na versao antiga restaurariam o bug do ID_MOTIVO. */
IF EXISTS (SELECT 1 FROM sys.triggers t
           JOIN sys.sql_modules m ON m.object_id = t.object_id
           WHERE t.parent_id = @objId
             AND (m.definition LIKE '%ID_MOTIVO%' OR m.definition LIKE '%SG_STATUS%'))
BEGIN
    RAISERROR('Abortado: ha trigger citando ID_MOTIVO/SG_STATUS (versao antiga). Rode o atualizar_pvc_e_logs_in_place.sql primeiro - senao este script restauraria a versao quebrada.', 16, 1);
    RETURN;
END

IF EXISTS (SELECT 1 FROM sys.triggers t
           LEFT JOIN sys.sql_modules m ON m.object_id = t.object_id
           WHERE t.parent_id = @objId AND m.definition IS NULL)
BEGIN
    RAISERROR('Abortado: ha trigger com definicao ilegivel (criptografada) - nao daria para recria-lo.', 16, 1);
    RETURN;
END

/* E0.4 - idempotencia: ja esta na ordem certa? */
IF NOT EXISTS (
    SELECT 1 FROM sys.columns c JOIN @ordem o ON o.NM = c.name
    WHERE c.object_id = @objId AND c.column_id <> o.POS)
BEGIN
    PRINT 'Nada a fazer - as 25 colunas ja estao na ordem do DER (ID_STATUS na 9a, DS_MOTIVO na 23a).';
    RETURN;
END

IF OBJECT_ID(@tblNew, 'U') IS NOT NULL
BEGIN
    RAISERROR('Abortado: CI.KZN_PVC_NEW ja existe (sobra de uma execucao anterior?). Confira o conteudo dela e remova-a antes de rodar de novo.', 16, 1);
    RETURN;
END

PRINT 'Ordem atual difere do DER. Iniciando reconstrucao de CI.KZN_PEDRAVISAOCONSOLIDADA...';

/* =====================================================================
   E1 - CAPTURA DAS AMARRACOES (tudo por metadados, nada fixo)
   ===================================================================== */

/* Scripts DDL de recriacao, na ordem em que devem ser reaplicados. */
DECLARE @recria TABLE (SEQ INT IDENTITY(1,1) PRIMARY KEY, ETAPA VARCHAR(20), NOME SYSNAME NULL, SCRIPT NVARCHAR(MAX));

/* --- defaults (ETAPA 1) --- */
INSERT INTO @recria (ETAPA, NOME, SCRIPT)
SELECT '1-DEFAULT', dc.name,
       'ALTER TABLE ' + @tbl + ' ADD CONSTRAINT ' + QUOTENAME(dc.name)
       + ' DEFAULT ' + dc.definition + ' FOR ' + QUOTENAME(COL_NAME(dc.parent_object_id, dc.parent_column_id)) + ';'
FROM   sys.default_constraints dc
WHERE  dc.parent_object_id = @objId;

/* --- PK e constraints UNIQUE (ETAPA 2) --- */
INSERT INTO @recria (ETAPA, NOME, SCRIPT)
SELECT '2-PK_UQ', kc.name,
       'ALTER TABLE ' + @tbl + ' ADD CONSTRAINT ' + QUOTENAME(kc.name) + ' '
       + CASE kc.type WHEN 'PK' THEN 'PRIMARY KEY ' ELSE 'UNIQUE ' END
       + i.type_desc + ' ('
       + STUFF((SELECT ', ' + QUOTENAME(COL_NAME(ic.object_id, ic.column_id))
                       + CASE WHEN ic.is_descending_key = 1 THEN ' DESC' ELSE ' ASC' END
                FROM   sys.index_columns ic
                WHERE  ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.is_included_column = 0
                ORDER BY ic.key_ordinal
                FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, '')
       + ');'
FROM   sys.key_constraints kc
JOIN   sys.indexes i ON i.object_id = kc.parent_object_id AND i.index_id = kc.unique_index_id
WHERE  kc.parent_object_id = @objId;

/* --- CHECK constraints (ETAPA 3) --- */
INSERT INTO @recria (ETAPA, NOME, SCRIPT)
SELECT '3-CHECK', cc.name,
       'ALTER TABLE ' + @tbl + CASE WHEN cc.is_not_trusted = 1 THEN ' WITH NOCHECK' ELSE '' END
       + ' ADD CONSTRAINT ' + QUOTENAME(cc.name) + ' CHECK ' + cc.definition + ';'
FROM   sys.check_constraints cc
WHERE  cc.parent_object_id = @objId;

/* --- indices nao-constraint (ETAPA 4) --- */
INSERT INTO @recria (ETAPA, NOME, SCRIPT)
SELECT '4-INDICE', i.name,
       'CREATE ' + CASE WHEN i.is_unique = 1 THEN 'UNIQUE ' ELSE '' END + i.type_desc
       + ' INDEX ' + QUOTENAME(i.name) + ' ON ' + @tbl + ' ('
       + STUFF((SELECT ', ' + QUOTENAME(COL_NAME(ic.object_id, ic.column_id))
                       + CASE WHEN ic.is_descending_key = 1 THEN ' DESC' ELSE ' ASC' END
                FROM   sys.index_columns ic
                WHERE  ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.is_included_column = 0
                ORDER BY ic.key_ordinal
                FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, '')
       + ')'
       + ISNULL(' INCLUDE (' + STUFF((SELECT ', ' + QUOTENAME(COL_NAME(ic.object_id, ic.column_id))
                FROM   sys.index_columns ic
                WHERE  ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.is_included_column = 1
                ORDER BY ic.index_column_id
                FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, '') + ')', '')
       + ISNULL(' WHERE ' + i.filter_definition, '')
       + ';'
FROM   sys.indexes i
WHERE  i.object_id = @objId AND i.type IN (1, 2)
  AND  i.is_primary_key = 0 AND i.is_unique_constraint = 0;

/* --- FKs que SAEM da tabela (ETAPA 5) e que ENTRAM nela (ETAPA 6) ---
   As que entram tambem precisam ser DROPADAS antes do DROP TABLE: o SQL
   Server nao deixa dropar tabela referenciada por FK. */
INSERT INTO @recria (ETAPA, NOME, SCRIPT)
SELECT CASE WHEN fk.parent_object_id = @objId THEN '5-FK_SAIDA' ELSE '6-FK_ENTRADA' END,
       fk.name,
       'ALTER TABLE ' + QUOTENAME(OBJECT_SCHEMA_NAME(fk.parent_object_id)) + '.' + QUOTENAME(OBJECT_NAME(fk.parent_object_id))
       + CASE WHEN fk.is_not_trusted = 1 THEN ' WITH NOCHECK' ELSE '' END
       + ' ADD CONSTRAINT ' + QUOTENAME(fk.name) + ' FOREIGN KEY ('
       + STUFF((SELECT ', ' + QUOTENAME(COL_NAME(fkc.parent_object_id, fkc.parent_column_id))
                FROM   sys.foreign_key_columns fkc
                WHERE  fkc.constraint_object_id = fk.object_id
                ORDER BY fkc.constraint_column_id
                FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, '')
       + ') REFERENCES ' + QUOTENAME(OBJECT_SCHEMA_NAME(fk.referenced_object_id)) + '.' + QUOTENAME(OBJECT_NAME(fk.referenced_object_id)) + ' ('
       + STUFF((SELECT ', ' + QUOTENAME(COL_NAME(fkc.referenced_object_id, fkc.referenced_column_id))
                FROM   sys.foreign_key_columns fkc
                WHERE  fkc.constraint_object_id = fk.object_id
                ORDER BY fkc.constraint_column_id
                FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, '')
       + ')'
       + CASE fk.delete_referential_action WHEN 1 THEN ' ON DELETE CASCADE' WHEN 2 THEN ' ON DELETE SET NULL' WHEN 3 THEN ' ON DELETE SET DEFAULT' ELSE '' END
       + CASE fk.update_referential_action WHEN 1 THEN ' ON UPDATE CASCADE' WHEN 2 THEN ' ON UPDATE SET NULL' WHEN 3 THEN ' ON UPDATE SET DEFAULT' ELSE '' END
       + ';'
FROM   sys.foreign_keys fk
WHERE  fk.parent_object_id = @objId OR fk.referenced_object_id = @objId;

/* --- triggers (ETAPA 7): o corpo vem literal de sys.sql_modules, entao
   volta identico ao que esta no banco hoje - nada e reescrito aqui. --- */
INSERT INTO @recria (ETAPA, NOME, SCRIPT)
SELECT '7-TRIGGER', t.name, m.definition
FROM   sys.triggers t
JOIN   sys.sql_modules m ON m.object_id = t.object_id
WHERE  t.parent_id = @objId;

/* --- lista das FKs que entram, para dropar antes do DROP TABLE --- */
DECLARE @dropFk TABLE (SEQ INT IDENTITY(1,1) PRIMARY KEY, SCRIPT NVARCHAR(MAX));
INSERT INTO @dropFk (SCRIPT)
SELECT 'ALTER TABLE ' + QUOTENAME(OBJECT_SCHEMA_NAME(fk.parent_object_id)) + '.' + QUOTENAME(OBJECT_NAME(fk.parent_object_id))
       + ' DROP CONSTRAINT ' + QUOTENAME(fk.name) + ';'
FROM   sys.foreign_keys fk
WHERE  fk.referenced_object_id = @objId AND fk.parent_object_id <> @objId;

SELECT @qt = COUNT(*) FROM @recria;
PRINT '  E1 ok - ' + CAST(@qt AS VARCHAR(10)) + ' objeto(s) capturado(s) para recriacao.';

/* =====================================================================
   E2 - MONTA O CREATE TABLE NA ORDEM CORRETA
   Tipo, tamanho, precisao, collation e nulidade saem de sys.columns -
   a nova tabela e byte-a-byte compativel com a antiga, so muda a ordem.
   ===================================================================== */
SELECT @cols = STUFF((
    SELECT ',' + CHAR(13) + CHAR(10) + '    ' + QUOTENAME(c.name) + ' '
           + CASE
               WHEN ty.name IN ('varchar','char','varbinary','binary')
                    THEN ty.name + '(' + CASE WHEN c.max_length = -1 THEN 'MAX' ELSE CAST(c.max_length AS VARCHAR(10)) END + ')'
               WHEN ty.name IN ('nvarchar','nchar')
                    THEN ty.name + '(' + CASE WHEN c.max_length = -1 THEN 'MAX' ELSE CAST(c.max_length / 2 AS VARCHAR(10)) END + ')'
               WHEN ty.name IN ('decimal','numeric')
                    THEN ty.name + '(' + CAST(c.precision AS VARCHAR(10)) + ',' + CAST(c.scale AS VARCHAR(10)) + ')'
               WHEN ty.name IN ('datetime2','time','datetimeoffset')
                    THEN ty.name + '(' + CAST(c.scale AS VARCHAR(10)) + ')'
               ELSE ty.name
             END
           + ISNULL(' COLLATE ' + c.collation_name, '')
           + CASE WHEN c.is_nullable = 1 THEN ' NULL' ELSE ' NOT NULL' END
    FROM   @ordem o
    JOIN   sys.columns c ON c.object_id = @objId AND c.name = o.NM
    JOIN   sys.types   ty ON ty.user_type_id = c.user_type_id
    ORDER BY o.POS
    FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 1, '');

/* Mesma ordem para o INSERT/SELECT da copia. */
SELECT @colList = STUFF((
    SELECT ', ' + QUOTENAME(o.NM) FROM @ordem o ORDER BY o.POS
    FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, '');

/* =====================================================================
   E3 - RECONSTRUCAO (parte destrutiva, toda dentro da transacao)
   ===================================================================== */
DECLARE @linhasAntes INT, @linhasDepois INT;
DECLARE @i INT, @n INT, @etapaAtual VARCHAR(20), @nomeAtual SYSNAME, @msg NVARCHAR(2000);

/* Ordem de recriacao explicita. Nao da para confiar no IDENTITY de
   @recria: as FKs de saida e de entrada entraram num INSERT...SELECT
   unico, e a ordem de atribuicao do IDENTITY nesse caso nao e garantida
   pelo SQL Server. Aqui a sequencia fica deterministica. */
DECLARE @plano TABLE (ORD INT PRIMARY KEY, ETAPA VARCHAR(20), NOME SYSNAME NULL, SCRIPT NVARCHAR(MAX));
INSERT INTO @plano (ORD, ETAPA, NOME, SCRIPT)
SELECT ROW_NUMBER() OVER (ORDER BY ETAPA, SEQ), ETAPA, NOME, SCRIPT FROM @recria;

BEGIN TRANSACTION;

BEGIN TRY

    SELECT @sql = N'SELECT @c = COUNT(*) FROM ' + @tbl;
    EXEC sp_executesql @sql, N'@c INT OUTPUT', @c = @linhasAntes OUTPUT;
    PRINT '  Linhas na tabela original: ' + CAST(@linhasAntes AS VARCHAR(20));

    /* 3.1 - dropa as FKs que apontam para a tabela */
    SELECT @i = 1, @n = ISNULL(MAX(SEQ), 0) FROM @dropFk;
    WHILE @i <= @n
    BEGIN
        SELECT @sql = SCRIPT FROM @dropFk WHERE SEQ = @i;
        EXEC sp_executesql @sql;
        SET @i += 1;
    END
    PRINT '  E3.1 ok - ' + CAST(@n AS VARCHAR(10)) + ' FK(s) de entrada removida(s) temporariamente.';

    /* 3.2 - cria a tabela nova, sem nenhuma constraint (elas voltam no fim,
       com os nomes originais - nomes de constraint sao unicos por schema,
       entao nao podem existir nas duas tabelas ao mesmo tempo) */
    SET @sql = N'CREATE TABLE ' + @tblNew + N'
(' + @cols + N'
);';
    EXEC sp_executesql @sql;
    PRINT '  E3.2 ok - CI.KZN_PVC_NEW criada com as 25 colunas na ordem do DER.';

    /* 3.3 - copia os dados */
    SET @sql = N'INSERT INTO ' + @tblNew + N' (' + @colList + N') SELECT ' + @colList + N' FROM ' + @tbl + N';';
    EXEC sp_executesql @sql;

    SELECT @sql = N'SELECT @c = COUNT(*) FROM ' + @tblNew;
    EXEC sp_executesql @sql, N'@c INT OUTPUT', @c = @linhasDepois OUTPUT;

    /* RAISERROR severidade 16 dentro do TRY desvia para o CATCH, que faz o
       ROLLBACK. Nada de RETURN aqui: RETURN encerraria o batch com a
       transacao ainda ABERTA. */
    IF @linhasDepois <> @linhasAntes
        RAISERROR('Abortado: a copia gravou %d linha(s) mas a origem tem %d. Rollback aplicado - nada foi alterado.', 16, 1, @linhasDepois, @linhasAntes);
    PRINT '  E3.3 ok - ' + CAST(@linhasDepois AS VARCHAR(20)) + ' linha(s) copiada(s) e conferida(s).';

    /* 3.4 - dropa a antiga (leva junto triggers, indices, PK e defaults,
       todos ja capturados na E1) e renomeia a nova */
    SET @sql = N'DROP TABLE ' + @tbl + N';';
    EXEC sp_executesql @sql;

    EXEC sp_rename 'CI.KZN_PVC_NEW', 'KZN_PEDRAVISAOCONSOLIDADA';
    PRINT '  E3.4 ok - tabela antiga removida e a nova renomeada.';

    /* 3.5 - recria tudo na ordem: defaults, PK/UNIQUE, checks, indices,
       FKs de saida, FKs de entrada e triggers. A PK precisa existir antes
       das FKs de entrada, que a referenciam. */
    SELECT @i = 1, @n = ISNULL(MAX(ORD), 0) FROM @plano;
    WHILE @i <= @n
    BEGIN
        SELECT @sql = SCRIPT, @etapaAtual = ETAPA, @nomeAtual = NOME
        FROM   @plano WHERE ORD = @i;
        BEGIN TRY
            EXEC sp_executesql @sql;
        END TRY
        BEGIN CATCH
            /* Nomeia o objeto que falhou - sem isso a mensagem crua do
               SQL Server nao diz qual dos ~15 scripts quebrou. O erro
               levantado aqui sobe para o CATCH externo, que faz o ROLLBACK. */
            SET @msg = 'Falha ao recriar ' + @etapaAtual + ' ' + ISNULL(@nomeAtual, '(sem nome)') + ': ' + ERROR_MESSAGE();
            RAISERROR(@msg, 16, 1);
        END CATCH
        SET @i += 1;
    END
    PRINT '  E3.5 ok - ' + CAST(@n AS VARCHAR(10)) + ' objeto(s) recriado(s).';

    COMMIT TRANSACTION;
    PRINT 'Concluido: CI.KZN_PEDRAVISAOCONSOLIDADA reconstruida com ID_STATUS na 9a posicao e DS_MOTIVO na 23a.';

END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0
        ROLLBACK TRANSACTION;
    PRINT 'ERRO - ROLLBACK aplicado, a tabela original continua intacta com todas as amarracoes: ' + ERROR_MESSAGE();
    THROW;
END CATCH
GO

/* =====================================================================
   E4 - CONFERENCIA
   ===================================================================== */
PRINT '--- Ordem final das colunas ---';
SELECT  POSICAO = c.column_id,
        COLUNA  = c.name,
        TIPO    = ty.name
                  + CASE WHEN ty.name = 'varchar'   THEN '(' + CAST(c.max_length AS VARCHAR(10)) + ')'
                         WHEN ty.name = 'decimal'   THEN '(' + CAST(c.precision AS VARCHAR(10)) + ',' + CAST(c.scale AS VARCHAR(10)) + ')'
                         WHEN ty.name = 'datetime2' THEN '(' + CAST(c.scale AS VARCHAR(10)) + ')'
                         ELSE '' END,
        NULO    = CASE WHEN c.is_nullable = 1 THEN 'SIM' ELSE 'NAO' END
FROM        sys.columns c
JOIN        sys.types  ty ON ty.user_type_id = c.user_type_id
WHERE       c.object_id = OBJECT_ID('CI.KZN_PEDRAVISAOCONSOLIDADA')
ORDER BY    c.column_id;

SELECT  LINHAS          = (SELECT COUNT(*) FROM CI.KZN_PEDRAVISAOCONSOLIDADA),
        FKS_DE_SAIDA    = (SELECT COUNT(*) FROM sys.foreign_keys WHERE parent_object_id     = OBJECT_ID('CI.KZN_PEDRAVISAOCONSOLIDADA')),
        FKS_DE_ENTRADA  = (SELECT COUNT(*) FROM sys.foreign_keys WHERE referenced_object_id = OBJECT_ID('CI.KZN_PEDRAVISAOCONSOLIDADA')),
        INDICES         = (SELECT COUNT(*) FROM sys.indexes      WHERE object_id = OBJECT_ID('CI.KZN_PEDRAVISAOCONSOLIDADA') AND type IN (1,2)),
        TRIGGERS        = (SELECT COUNT(*) FROM sys.triggers     WHERE parent_id = OBJECT_ID('CI.KZN_PEDRAVISAOCONSOLIDADA')),
        TRIGGERS_ATIVOS = (SELECT COUNT(*) FROM sys.triggers     WHERE parent_id = OBJECT_ID('CI.KZN_PEDRAVISAOCONSOLIDADA') AND is_disabled = 0);
GO
