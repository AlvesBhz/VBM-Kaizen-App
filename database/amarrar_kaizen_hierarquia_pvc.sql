/* =====================================================================
   CI.KZN_KAIZEN_HIERARQUIA — ID_KAIZEN e ID_USUARIO_LIDER viram FK
   para CI.KZN_PEDRAVISAOCONSOLIDADA
   ---------------------------------------------------------------------
   Cria duas chaves estrangeiras:

     1. FK_KZN_KAIZEN_HIERARQUIA_KAIZEN
          KZN_KAIZEN_HIERARQUIA (ID_KAIZEN)
       -> KZN_PEDRAVISAOCONSOLIDADA (ID_KAIZEN)

     2. FK_KZN_KAIZEN_HIERARQUIA_LIDER
          KZN_KAIZEN_HIERARQUIA (ID_KAIZEN, ID_USUARIO_LIDER)
       -> KZN_PEDRAVISAOCONSOLIDADA (ID_KAIZEN, ID_USUARIO_LIDER)

   Depois disso as DUAS colunas aparecem como (FK) no SSMS, que e o
   resultado pedido.

   ---------------------------------------------------------------------
   POR QUE A 2a FK E COMPOSTA (e nao so ID_USUARIO_LIDER -> ID_USUARIO_LIDER)

   O SQL Server so aceita FK apontando para coluna com PK ou UNIQUE. E
   KZN_PEDRAVISAOCONSOLIDADA.ID_USUARIO_LIDER NAO e unica - nem poderia
   ser: um mesmo lider toca varios Kaizens. Uma FK simples
   ID_USUARIO_LIDER -> ID_USUARIO_LIDER e IMPOSSIVEL, e a unica forma de
   viabiliza-la seria criar UNIQUE(ID_USUARIO_LIDER) na tabela principal,
   o que passaria a proibir que um lider tivesse mais de um Kaizen - um
   estrago grande e silencioso.

   A saida e a FK COMPOSTA, apoiada em
   UNIQUE (ID_KAIZEN, ID_USUARIO_LIDER) na tabela principal. Esse UNIQUE
   e inofensivo: ID_KAIZEN ja e a PK, entao o par ja e unico por
   construcao e a constraint nunca rejeita nada que hoje passa. Nenhuma
   regra de negocio muda.

   E o resultado e MAIS forte do que o pedido literal: alem de exigir que
   o lider exista, a FK composta garante que o lider gravado na
   fotografia da hierarquia seja exatamente o lider daquele Kaizen - nao
   um lider de outro Kaizen qualquer.

   ---------------------------------------------------------------------
   CONSEQUENCIA A CONHECER

   Com a FK composta, trocar o lider de um Kaizen
   (UPDATE em KZN_PEDRAVISAOCONSOLIDADA.ID_USUARIO_LIDER) passa a ser
   BLOQUEADO enquanto houver linha de hierarquia apontando para o lider
   antigo; a linha filha precisa ser atualizada junto.

   Hoje isso nao afeta nada: o server.js so grava ID_USUARIO_LIDER no
   INSERT do Kaizen e nunca faz UPDATE nessa coluna. Se um dia passar a
   trocar o lider, ha duas saidas: atualizar as duas tabelas na mesma
   transacao, ou recriar a FK 2 com ON UPDATE CASCADE (que propaga a
   troca automaticamente).

   ---------------------------------------------------------------------
   PRE-REQUISITO DE DADO

   As FKs so podem nascer se os dados ja forem consistentes. A E1 checa e,
   se encontrar divergencia, o script PARA sem criar nada e lista as
   linhas problematicas:

     - hierarquia apontando para ID_KAIZEN que nao existe na principal;
     - hierarquia cujo ID_USUARIO_LIDER difere do lider do proprio Kaizen.

   Nada de dado e alterado por este script - ele so cria constraints.

   E IDEMPOTENTE: cada objeto so e criado se ainda nao existir.

   Schema: 'ci' (AZURE_SQL_SCHEMA em app.yaml).
   ===================================================================== */

SET NOCOUNT ON;
SET XACT_ABORT ON;

/* =====================================================================
   E1 - DIAGNOSTICO E CHECAGEM DE CONSISTENCIA
   ===================================================================== */
IF OBJECT_ID('CI.KZN_KAIZEN_HIERARQUIA', 'U') IS NULL
   OR OBJECT_ID('CI.KZN_PEDRAVISAOCONSOLIDADA', 'U') IS NULL
BEGIN
    RAISERROR('Abortado: CI.KZN_KAIZEN_HIERARQUIA ou CI.KZN_PEDRAVISAOCONSOLIDADA nao existe neste banco.', 16, 1);
    RETURN;
END

IF NOT EXISTS (SELECT 1 FROM sys.columns
               WHERE object_id = OBJECT_ID('CI.KZN_KAIZEN_HIERARQUIA') AND name = 'ID_USUARIO_LIDER')
BEGIN
    RAISERROR('Abortado: CI.KZN_KAIZEN_HIERARQUIA nao tem a coluna ID_USUARIO_LIDER neste banco.', 16, 1);
    RETURN;
END

/* FKs que a tabela ja tem hoje - util pra saber o ponto de partida.
   Uma FK pre-existente de ID_USUARIO_LIDER para KZN_MDM_HIERARQUIA, se
   houver, NAO e removida por este script: ela continua valida e vira
   redundante (a principal ja referencia o MDM por essa mesma coluna).
   Se quiser aposenta-la, faca isso conscientemente, a parte. */
SELECT  FK_EXISTENTE = fk.name,
        COLUNAS      = STUFF((SELECT ', ' + COL_NAME(c.parent_object_id, c.parent_column_id)
                              FROM sys.foreign_key_columns c
                              WHERE c.constraint_object_id = fk.object_id
                              ORDER BY c.constraint_column_id
                              FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, ''),
        APONTA_PARA  = OBJECT_SCHEMA_NAME(fk.referenced_object_id) + '.' + OBJECT_NAME(fk.referenced_object_id)
FROM    sys.foreign_keys fk
WHERE   fk.parent_object_id = OBJECT_ID('CI.KZN_KAIZEN_HIERARQUIA');
GO

DECLARE @orfaos INT, @lideresDivergentes INT;

SELECT @orfaos = COUNT(*)
FROM   CI.KZN_KAIZEN_HIERARQUIA h
WHERE  NOT EXISTS (SELECT 1 FROM CI.KZN_PEDRAVISAOCONSOLIDADA p
                   WHERE p.ID_KAIZEN = h.ID_KAIZEN);

SELECT @lideresDivergentes = COUNT(*)
FROM        CI.KZN_KAIZEN_HIERARQUIA h
JOIN        CI.KZN_PEDRAVISAOCONSOLIDADA p ON p.ID_KAIZEN = h.ID_KAIZEN
WHERE       h.ID_USUARIO_LIDER <> p.ID_USUARIO_LIDER;

PRINT 'E1 - hierarquias com ID_KAIZEN inexistente na principal: ' + CAST(@orfaos AS VARCHAR(10));
PRINT 'E1 - hierarquias cujo lider difere do lider do Kaizen: '   + CAST(@lideresDivergentes AS VARCHAR(10));

IF @orfaos > 0
    SELECT TOP (50) PROBLEMA = 'ID_KAIZEN nao existe na principal',
           h.ID_KAIZEN, h.ID_USUARIO_LIDER
    FROM   CI.KZN_KAIZEN_HIERARQUIA h
    WHERE  NOT EXISTS (SELECT 1 FROM CI.KZN_PEDRAVISAOCONSOLIDADA p WHERE p.ID_KAIZEN = h.ID_KAIZEN)
    ORDER BY h.ID_KAIZEN;

IF @lideresDivergentes > 0
    SELECT TOP (50) PROBLEMA = 'lider da hierarquia difere do lider do Kaizen',
           h.ID_KAIZEN,
           LIDER_NA_HIERARQUIA = h.ID_USUARIO_LIDER,
           LIDER_NO_KAIZEN     = p.ID_USUARIO_LIDER
    FROM        CI.KZN_KAIZEN_HIERARQUIA h
    JOIN        CI.KZN_PEDRAVISAOCONSOLIDADA p ON p.ID_KAIZEN = h.ID_KAIZEN
    WHERE       h.ID_USUARIO_LIDER <> p.ID_USUARIO_LIDER
    ORDER BY    h.ID_KAIZEN;
GO

/* =====================================================================
   E2 - CRIACAO DO UNIQUE E DAS DUAS FKs
   ---------------------------------------------------------------------
   A consistencia e RECONFERIDA aqui, e nao so na E1: RAISERROR + RETURN
   encerram apenas o BATCH em que aparecem - os batches seguintes
   continuam rodando. Uma checagem feita num batch anterior nao protege
   este.
   ===================================================================== */
DECLARE @orfaos INT, @lideresDivergentes INT;

SELECT @orfaos = COUNT(*)
FROM   CI.KZN_KAIZEN_HIERARQUIA h
WHERE  NOT EXISTS (SELECT 1 FROM CI.KZN_PEDRAVISAOCONSOLIDADA p WHERE p.ID_KAIZEN = h.ID_KAIZEN);

SELECT @lideresDivergentes = COUNT(*)
FROM        CI.KZN_KAIZEN_HIERARQUIA h
JOIN        CI.KZN_PEDRAVISAOCONSOLIDADA p ON p.ID_KAIZEN = h.ID_KAIZEN
WHERE       h.ID_USUARIO_LIDER <> p.ID_USUARIO_LIDER;

IF @orfaos > 0 OR @lideresDivergentes > 0
BEGIN
    RAISERROR('E2 NAO EXECUTADA: os dados ainda nao permitem criar as FKs (%d orfao[s], %d lider[es] divergente[s] - listados na E1). NADA foi criado. Corrija os dados e rode de novo.', 16, 1, @orfaos, @lideresDivergentes);
    RETURN;
END

/* 2.1 - UNIQUE que viabiliza a FK composta. Inofensivo: ID_KAIZEN ja e a
   PK, entao (ID_KAIZEN, ID_USUARIO_LIDER) ja e unico por construcao. */
IF NOT EXISTS (SELECT 1 FROM sys.key_constraints
               WHERE parent_object_id = OBJECT_ID('CI.KZN_PEDRAVISAOCONSOLIDADA')
                 AND name = 'UQ_KZN_PVC_KAIZEN_LIDER')
BEGIN
    ALTER TABLE CI.KZN_PEDRAVISAOCONSOLIDADA
        ADD CONSTRAINT UQ_KZN_PVC_KAIZEN_LIDER UNIQUE (ID_KAIZEN, ID_USUARIO_LIDER);
    PRINT '  E2.1 ok - UQ_KZN_PVC_KAIZEN_LIDER criada na tabela principal.';
END
ELSE
    PRINT '  E2.1 - UQ_KZN_PVC_KAIZEN_LIDER ja existia.';

/* 2.2 - FK simples: ID_KAIZEN -> principal
   WITH CHECK explicito: valida os dados existentes e deixa a constraint
   CONFIAVEL (is_not_trusted = 0). Uma FK nao-confiavel continua barrando
   INSERT/UPDATE novos, mas o otimizador a ignora ao montar planos, e ela
   nao prova nada sobre o que ja esta gravado.

   O ELSE IF abaixo cobre o caso que a versao anterior deste script
   deixava passar: a FK JA EXISTIR, porem nao-confiavel (criada com
   WITH NOCHECK em algum momento). Como o guard so olhava existencia, o
   script dava "ja existia" e seguia, sem nunca revalidar - era preciso
   dropar e recriar a mao. Agora ele revalida no lugar. */
IF OBJECT_ID('CI.FK_KZN_KAIZEN_HIERARQUIA_KAIZEN', 'F') IS NULL
BEGIN
    ALTER TABLE CI.KZN_KAIZEN_HIERARQUIA WITH CHECK
        ADD CONSTRAINT FK_KZN_KAIZEN_HIERARQUIA_KAIZEN
            FOREIGN KEY (ID_KAIZEN)
            REFERENCES CI.KZN_PEDRAVISAOCONSOLIDADA (ID_KAIZEN);
    PRINT '  E2.2 ok - FK_KZN_KAIZEN_HIERARQUIA_KAIZEN criada (confiavel).';
END
ELSE IF EXISTS (SELECT 1 FROM sys.foreign_keys
                WHERE name = 'FK_KZN_KAIZEN_HIERARQUIA_KAIZEN' AND is_not_trusted = 1)
BEGIN
    ALTER TABLE CI.KZN_KAIZEN_HIERARQUIA
        WITH CHECK CHECK CONSTRAINT FK_KZN_KAIZEN_HIERARQUIA_KAIZEN;
    PRINT '  E2.2 ok - FK_KZN_KAIZEN_HIERARQUIA_KAIZEN ja existia mas NAO era confiavel; revalidada.';
END
ELSE
    PRINT '  E2.2 - FK_KZN_KAIZEN_HIERARQUIA_KAIZEN ja existia e e confiavel.';

/* 2.3 - FK composta: (ID_KAIZEN, ID_USUARIO_LIDER) -> principal
   Mesmo tratamento da 2.2: cria confiavel, ou revalida se ja existir
   nao-confiavel. */
IF OBJECT_ID('CI.FK_KZN_KAIZEN_HIERARQUIA_LIDER', 'F') IS NULL
BEGIN
    ALTER TABLE CI.KZN_KAIZEN_HIERARQUIA WITH CHECK
        ADD CONSTRAINT FK_KZN_KAIZEN_HIERARQUIA_LIDER
            FOREIGN KEY (ID_KAIZEN, ID_USUARIO_LIDER)
            REFERENCES CI.KZN_PEDRAVISAOCONSOLIDADA (ID_KAIZEN, ID_USUARIO_LIDER);
    PRINT '  E2.3 ok - FK_KZN_KAIZEN_HIERARQUIA_LIDER criada (confiavel).';
END
ELSE IF EXISTS (SELECT 1 FROM sys.foreign_keys
                WHERE name = 'FK_KZN_KAIZEN_HIERARQUIA_LIDER' AND is_not_trusted = 1)
BEGIN
    ALTER TABLE CI.KZN_KAIZEN_HIERARQUIA
        WITH CHECK CHECK CONSTRAINT FK_KZN_KAIZEN_HIERARQUIA_LIDER;
    PRINT '  E2.3 ok - FK_KZN_KAIZEN_HIERARQUIA_LIDER ja existia mas NAO era confiavel; revalidada.';
END
ELSE
    PRINT '  E2.3 - FK_KZN_KAIZEN_HIERARQUIA_LIDER ja existia e e confiavel.';
GO

/* =====================================================================
   E3 - CONFERENCIA
   ===================================================================== */
SELECT  FK           = fk.name,
        COLUNAS_FILHA = STUFF((SELECT ', ' + COL_NAME(c.parent_object_id, c.parent_column_id)
                               FROM sys.foreign_key_columns c
                               WHERE c.constraint_object_id = fk.object_id
                               ORDER BY c.constraint_column_id
                               FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, ''),
        TABELA_PAI   = OBJECT_SCHEMA_NAME(fk.referenced_object_id) + '.' + OBJECT_NAME(fk.referenced_object_id),
        COLUNAS_PAI  = STUFF((SELECT ', ' + COL_NAME(c.referenced_object_id, c.referenced_column_id)
                              FROM sys.foreign_key_columns c
                              WHERE c.constraint_object_id = fk.object_id
                              ORDER BY c.constraint_column_id
                              FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, ''),
        CONFIAVEL    = CASE WHEN fk.is_not_trusted = 1 THEN 'NAO (WITH NOCHECK)' ELSE 'SIM' END
FROM    sys.foreign_keys fk
WHERE   fk.parent_object_id = OBJECT_ID('CI.KZN_KAIZEN_HIERARQUIA')
ORDER BY fk.name;

SELECT  LINHAS_NA_HIERARQUIA = COUNT(*) FROM CI.KZN_KAIZEN_HIERARQUIA;
GO
