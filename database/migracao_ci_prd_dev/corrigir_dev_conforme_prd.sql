/* =====================================================================
   CORRIGIR O SCHEMA CI DO BDIBPBMSA_DEV CONFORME A PRD
   (executar conectado ao BDIBPBMSA_DEV)
   ---------------------------------------------------------------------
   Base: dicionário da PRD "Estrutura_Atual_do_banco.xlsx" (30/09/2026),
   comparado com o DEV criado pelo criar_estrutura_ci_dev.sql.

   Correções (cada uma só é aplicada se o DEV ainda estiver diferente):
    1 KZN_MDM_HIERARQUIA      NM_USUARIO varchar(80) NULL; CD_EMAIL NULL;
                              NM_SITUACAO/NM_POSICAO/NM_EMPRESA varchar(80)
    2 KZN_HIST_MDM_VBM_TERC   NM_SITUACAO/NM_POSICAO/NM_EMPRESA varchar(80);
                              NM_USUARIO NULL
    3 KZN_HIST_PEDRAVISAOCONSOLIDADA
                              DT_CRIACAO NOT NULL; remove SG_GM, URL_GM e
                              ID_TIPO_KAIZEN (não existem na PRD) — antes,
                              cópia em dbo.BKP_KZN_HIST_PVC_CAMPOS_GM
    4 KZN_ADMIN               CD_MATRICULA int; PK_KZN_ADMIN (ID_ADMIN,
                              CD_MATRICULA); remove FK_KZN_ADMIN_MATRICULA
                              (não existe na PRD: lá a coluna é int)
    5 KZN_APROVADOR           FK_KZN_APROVADOR_MATRICULA renomeada para
                              FK_KZN_APROVADOR_MDM_MATRICULA; UQ_KZN_APROVADOR_ID
    6 KZN_KAIZEN_HIERARQUIA   FK_KZN_KAIZEN_HIERARQUIA_USUARIO (ID_USUARIO_LIDER
                              -> MDM.ID_USUARIO); IX_KZN_KAIZEN_HIERARQUIA_KAIZEN
    7 KZN_PEDRAVISAOCONSOLIDADA  IX_KZN_PVC_TIPO_KAIZEN
    8 KZN_MEMBROS_EQUIPE      remove FK_KZN_MEMBROS_EQUIPE_KAIZEN; PK renomeada
                              para PK_kzn_membros_equipe
    9 KZN_STATUS              remove FK_KZN_STATUS_USUARIO
   10 KZN_MDM_TERCEIROS_USUARIO  tabela criada (existe só na PRD)
   11 Collation Latin1_General_CI_AS (a da PRD) nas colunas texto de
      KZN_MDM_HIERARQUIA e em KZN_APROVADOR.CD_MATRICULA (tem FK para a
      matrícula do MDM). Exige remover e recriar, na mesma transação e
      com a mesma definição: PK_KZN_MDM_HIERARQUIA, UQ_KZN_MDM_HIERARQUIA_MATR,
      IX_KZN_MDM_HIERARQUIA_EMAIL e FK_KZN_APROVADOR_MDM_MATRICULA (WITH CHECK).

   Não corrigido: ordem física das colunas da PVC e da HIST PVC (sem
   efeito em consultas com lista de colunas; exigiria recriar a tabela).
   O dicionário não traz collation, defaults, CHECKs nem triggers: esses
   ficam como estão no DEV; colunas novas usam a collation do banco.

   Validação prévia: se algum dado do DEV impedir uma correção, nada é
   alterado e o motivo é listado. Tudo numa transação (ROLLBACK total em
   erro). Idempotente. Ao final: conferência item a item.
   ===================================================================== */

SET NOCOUNT ON;
SET XACT_ABORT ON;

IF DB_NAME() = N'BDIBPBMSA_PRD'
BEGIN
    RAISERROR('Abortado: este script é para o BDIBPBMSA_DEV.', 16, 1);
    RETURN;
END

DECLARE @PROBLEMA TABLE (ITEM NVARCHAR(200), DETALHE NVARCHAR(2000));
DECLARE @sql NVARCHAR(MAX), @n INT, @lista NVARCHAR(2000);

/* ── Validação prévia ───────────────────────────────────────────────── */
INSERT @PROBLEMA
SELECT N'Tabela ausente no DEV', N'CI.' + t.NOME
FROM (VALUES (N'KZN_MDM_HIERARQUIA'), (N'KZN_HIST_MDM_VBM_TERC'), (N'KZN_HIST_PEDRAVISAOCONSOLIDADA'), (N'KZN_ADMIN'),
             (N'KZN_APROVADOR'), (N'KZN_KAIZEN_HIERARQUIA'), (N'KZN_PEDRAVISAOCONSOLIDADA'), (N'KZN_MEMBROS_EQUIPE'),
             (N'KZN_STATUS')) t (NOME)
WHERE OBJECT_ID(N'CI.' + t.NOME, N'U') IS NULL;
IF EXISTS (SELECT 1 FROM @PROBLEMA)
BEGIN
    SELECT * FROM @PROBLEMA;
    RAISERROR('Abortado: rode antes o criar_estrutura_ci_dev.sql. Nada foi alterado.', 16, 1);
    RETURN;
END

-- 3: DT_CRIACAO vai a NOT NULL
IF COLUMNPROPERTY(OBJECT_ID(N'CI.KZN_HIST_PEDRAVISAOCONSOLIDADA'), N'DT_CRIACAO', 'AllowsNull') = 1
BEGIN
    SELECT @n = COUNT(*) FROM CI.KZN_HIST_PEDRAVISAOCONSOLIDADA WHERE DT_CRIACAO IS NULL;
    IF @n > 0 INSERT @PROBLEMA VALUES (N'KZN_HIST_PEDRAVISAOCONSOLIDADA.DT_CRIACAO',
        CAST(@n AS NVARCHAR(10)) + N' linha(s) com NULL; na PRD a coluna é NOT NULL. Preencha ou recarregue a HIST.');
END
-- 3: colunas a remover não podem ser usadas por view/procedure/função/trigger nem por índice
IF COL_LENGTH(N'CI.KZN_HIST_PEDRAVISAOCONSOLIDADA', N'SG_GM') IS NOT NULL
   OR COL_LENGTH(N'CI.KZN_HIST_PEDRAVISAOCONSOLIDADA', N'URL_GM') IS NOT NULL
   OR COL_LENGTH(N'CI.KZN_HIST_PEDRAVISAOCONSOLIDADA', N'ID_TIPO_KAIZEN') IS NOT NULL
BEGIN
    INSERT @PROBLEMA
    SELECT DISTINCT N'Objeto usa coluna a remover da HIST PVC', SCHEMA_NAME(o.schema_id) + N'.' + o.name
    FROM sys.sql_expression_dependencies d JOIN sys.objects o ON o.object_id = d.referencing_id
    JOIN sys.sql_modules m ON m.object_id = o.object_id
    WHERE d.referenced_id = OBJECT_ID(N'CI.KZN_HIST_PEDRAVISAOCONSOLIDADA')
      AND (m.definition LIKE N'%SG[_]GM%' OR m.definition LIKE N'%URL[_]GM%' OR m.definition LIKE N'%ID[_]TIPO[_]KAIZEN%');
    INSERT @PROBLEMA
    SELECT DISTINCT N'Índice usa coluna a remover da HIST PVC', i.name
    FROM sys.indexes i JOIN sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id
    WHERE i.object_id = OBJECT_ID(N'CI.KZN_HIST_PEDRAVISAOCONSOLIDADA')
      AND COL_NAME(ic.object_id, ic.column_id) IN (N'SG_GM', N'URL_GM', N'ID_TIPO_KAIZEN');
    IF OBJECT_ID(N'dbo.BKP_KZN_HIST_PVC_CAMPOS_GM', N'U') IS NOT NULL
        INSERT @PROBLEMA VALUES (N'dbo.BKP_KZN_HIST_PVC_CAMPOS_GM', N'já existe (execução anterior?). Renomeie ou remova antes.');
END
-- 4: CD_MATRICULA vai a int e entra na PK
IF EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID(N'CI.KZN_ADMIN') AND name = N'CD_MATRICULA' AND TYPE_NAME(user_type_id) <> N'int')
BEGIN
    SELECT @n = COUNT(*), @lista = LEFT(STRING_AGG(CONVERT(NVARCHAR(MAX), ISNULL(CD_MATRICULA, N'NULL')), N', '), 1000)
    FROM CI.KZN_ADMIN WHERE TRY_CONVERT(INT, CD_MATRICULA) IS NULL;
    IF @n > 0 INSERT @PROBLEMA VALUES (N'KZN_ADMIN.CD_MATRICULA',
        CAST(@n AS NVARCHAR(10)) + N' valor(es) não numérico(s) — na PRD a coluna é int: ' + @lista);
END
IF EXISTS (SELECT 1 FROM sys.foreign_keys WHERE referenced_object_id = OBJECT_ID(N'CI.KZN_ADMIN'))
    INSERT @PROBLEMA SELECT N'FK aponta para a PK de KZN_ADMIN', name FROM sys.foreign_keys WHERE referenced_object_id = OBJECT_ID(N'CI.KZN_ADMIN');
-- 6: FK nova precisa dos dados íntegros
IF OBJECT_ID(N'CI.FK_KZN_KAIZEN_HIERARQUIA_USUARIO', N'F') IS NULL
BEGIN
    SELECT @n = COUNT(*), @lista = LEFT(STRING_AGG(CONVERT(NVARCHAR(MAX), CAST(k.ID_KAIZEN AS NVARCHAR(12)) + N'/' + CAST(k.ID_USUARIO_LIDER AS NVARCHAR(12))), N', '), 1000)
    FROM CI.KZN_KAIZEN_HIERARQUIA k
    WHERE NOT EXISTS (SELECT 1 FROM CI.KZN_MDM_HIERARQUIA m WHERE m.ID_USUARIO = k.ID_USUARIO_LIDER);
    IF @n > 0 INSERT @PROBLEMA VALUES (N'KZN_KAIZEN_HIERARQUIA.ID_USUARIO_LIDER',
        CAST(@n AS NVARCHAR(10)) + N' linha(s) sem usuário no MDM (ID_KAIZEN/ID_USUARIO_LIDER): ' + @lista);
END
-- 11: só estes objetos podem depender das colunas cuja collation muda
IF EXISTS (SELECT 1 FROM sys.columns c WHERE c.object_id IN (OBJECT_ID(N'CI.KZN_MDM_HIERARQUIA'), OBJECT_ID(N'CI.KZN_APROVADOR'))
             AND c.collation_name IS NOT NULL AND c.collation_name <> N'Latin1_General_CI_AS'
             AND (c.object_id = OBJECT_ID(N'CI.KZN_MDM_HIERARQUIA') OR c.name = N'CD_MATRICULA'))
BEGIN
    INSERT @PROBLEMA
    SELECT N'Índice inesperado em coluna texto do MDM/APROVADOR', OBJECT_NAME(i.object_id) + N'.' + i.name
    FROM sys.indexes i JOIN sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id
    JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
    WHERE c.collation_name IS NOT NULL
      AND (i.object_id = OBJECT_ID(N'CI.KZN_MDM_HIERARQUIA') OR (i.object_id = OBJECT_ID(N'CI.KZN_APROVADOR') AND c.name = N'CD_MATRICULA'))
      AND i.name NOT IN (N'PK_KZN_MDM_HIERARQUIA', N'UQ_KZN_MDM_HIERARQUIA_MATR', N'IX_KZN_MDM_HIERARQUIA_EMAIL');
    INSERT @PROBLEMA
    SELECT N'FK inesperada em coluna texto do MDM/APROVADOR', fk.name
    FROM sys.foreign_keys fk JOIN sys.foreign_key_columns fc ON fc.constraint_object_id = fk.object_id
    JOIN sys.columns c ON c.object_id = fc.referenced_object_id AND c.column_id = fc.referenced_column_id
    WHERE fc.referenced_object_id = OBJECT_ID(N'CI.KZN_MDM_HIERARQUIA') AND c.collation_name IS NOT NULL
      AND fk.name NOT IN (N'FK_KZN_APROVADOR_MDM_MATRICULA', N'FK_KZN_APROVADOR_MATRICULA', N'FK_KZN_ADMIN_MATRICULA');  -- tratadas nos itens 4 e 5
    INSERT @PROBLEMA
    SELECT N'Estatística manual em coluna texto do MDM', s.name
    FROM sys.stats s JOIN sys.stats_columns sc ON sc.object_id = s.object_id AND sc.stats_id = s.stats_id
    JOIN sys.columns c ON c.object_id = sc.object_id AND c.column_id = sc.column_id
    WHERE s.object_id = OBJECT_ID(N'CI.KZN_MDM_HIERARQUIA') AND s.user_created = 1 AND c.collation_name IS NOT NULL;
    INSERT @PROBLEMA
    SELECT N'Módulo com SCHEMABINDING usa o MDM', OBJECT_NAME(d.referencing_id)
    FROM sys.sql_expression_dependencies d JOIN sys.sql_modules m ON m.object_id = d.referencing_id
    WHERE d.referenced_id = OBJECT_ID(N'CI.KZN_MDM_HIERARQUIA') AND m.is_schema_bound = 1;
END

IF EXISTS (SELECT 1 FROM @PROBLEMA)
BEGIN
    SELECT ITEM, DETALHE FROM @PROBLEMA;
    SELECT @lista = LEFT(STRING_AGG(CONVERT(NVARCHAR(MAX), ITEM + N': ' + DETALHE), N' | '), 1900) FROM @PROBLEMA;
    RAISERROR(N'Abortado, nada foi alterado. %s', 16, 1, @lista);
    RETURN;
END

/* ── Correções ──────────────────────────────────────────────────────── */
DECLARE @COL TABLE (TABELA SYSNAME, COLUNA SYSNAME, TIPO NVARCHAR(40), TAM SMALLINT, NULO BIT);
INSERT @COL VALUES
    (N'KZN_MDM_HIERARQUIA',             N'NM_USUARIO',  N'varchar(80)',  80,  1),
    (N'KZN_MDM_HIERARQUIA',             N'CD_EMAIL',    N'varchar(100)', 100, 1),
    (N'KZN_MDM_HIERARQUIA',             N'NM_SITUACAO', N'varchar(80)',  80,  1),
    (N'KZN_MDM_HIERARQUIA',             N'NM_POSICAO',  N'varchar(80)',  80,  1),
    (N'KZN_MDM_HIERARQUIA',             N'NM_EMPRESA',  N'varchar(80)',  80,  1),
    (N'KZN_HIST_MDM_VBM_TERC',          N'NM_SITUACAO', N'varchar(80)',  80,  1),
    (N'KZN_HIST_MDM_VBM_TERC',          N'NM_POSICAO',  N'varchar(80)',  80,  1),
    (N'KZN_HIST_MDM_VBM_TERC',          N'NM_EMPRESA',  N'varchar(80)',  80,  1),
    (N'KZN_HIST_MDM_VBM_TERC',          N'NM_USUARIO',  N'varchar(100)', 100, 1),
    (N'KZN_HIST_PEDRAVISAOCONSOLIDADA', N'DT_CRIACAO',  N'datetime2(3)', 8,   0);

BEGIN TRY
    BEGIN TRANSACTION;

    -- 1, 2, 3a: tamanho/nulidade (mantém a collation atual)
    SELECT @sql = STRING_AGG(CONVERT(NVARCHAR(MAX),
               N'ALTER TABLE CI.' + QUOTENAME(x.TABELA) + N' ALTER COLUMN ' + QUOTENAME(x.COLUNA) + N' ' + x.TIPO
             + ISNULL(N' COLLATE ' + c.collation_name COLLATE DATABASE_DEFAULT, N'') + CASE WHEN x.NULO = 1 THEN N' NULL;' ELSE N' NOT NULL;' END), NCHAR(10))
    FROM @COL x
    JOIN sys.columns c ON c.object_id = OBJECT_ID(N'CI.' + QUOTENAME(x.TABELA)) AND c.name COLLATE DATABASE_DEFAULT = x.COLUNA
    WHERE c.is_nullable <> x.NULO OR (x.TIPO LIKE N'varchar%' AND c.max_length <> x.TAM);
    IF @sql IS NOT NULL EXEC sp_executesql @sql;

    -- 3b: backup e remoção de SG_GM, URL_GM, ID_TIPO_KAIZEN da HIST PVC
    IF COL_LENGTH(N'CI.KZN_HIST_PEDRAVISAOCONSOLIDADA', N'SG_GM') IS NOT NULL
       OR COL_LENGTH(N'CI.KZN_HIST_PEDRAVISAOCONSOLIDADA', N'URL_GM') IS NOT NULL
       OR COL_LENGTH(N'CI.KZN_HIST_PEDRAVISAOCONSOLIDADA', N'ID_TIPO_KAIZEN') IS NOT NULL
    BEGIN
        SELECT @sql = N'SELECT ID_KAIZEN, ' + STRING_AGG(CONVERT(NVARCHAR(MAX), QUOTENAME(name)), N', ')
                    + N' INTO dbo.BKP_KZN_HIST_PVC_CAMPOS_GM FROM CI.KZN_HIST_PEDRAVISAOCONSOLIDADA;'
        FROM sys.columns WHERE object_id = OBJECT_ID(N'CI.KZN_HIST_PEDRAVISAOCONSOLIDADA') AND name IN (N'SG_GM', N'URL_GM', N'ID_TIPO_KAIZEN');
        EXEC sp_executesql @sql;

        SELECT @sql = STRING_AGG(CONVERT(NVARCHAR(MAX), N'ALTER TABLE CI.KZN_HIST_PEDRAVISAOCONSOLIDADA DROP CONSTRAINT ' + QUOTENAME(k.name) + N';'), NCHAR(10))
        FROM (SELECT dc.name FROM sys.default_constraints dc
              WHERE dc.parent_object_id = OBJECT_ID(N'CI.KZN_HIST_PEDRAVISAOCONSOLIDADA')
                AND COL_NAME(dc.parent_object_id, dc.parent_column_id) IN (N'SG_GM', N'URL_GM', N'ID_TIPO_KAIZEN')
              UNION
              SELECT cc.name FROM sys.check_constraints cc
              WHERE cc.parent_object_id = OBJECT_ID(N'CI.KZN_HIST_PEDRAVISAOCONSOLIDADA')
                AND (COL_NAME(cc.parent_object_id, cc.parent_column_id) IN (N'SG_GM', N'URL_GM', N'ID_TIPO_KAIZEN')
                     OR cc.definition LIKE N'%SG[_]GM%' OR cc.definition LIKE N'%URL[_]GM%' OR cc.definition LIKE N'%ID[_]TIPO[_]KAIZEN%')) k;
        IF @sql IS NOT NULL EXEC sp_executesql @sql;

        SELECT @sql = N'ALTER TABLE CI.KZN_HIST_PEDRAVISAOCONSOLIDADA DROP COLUMN ' + STRING_AGG(CONVERT(NVARCHAR(MAX), QUOTENAME(name)), N', ') + N';'
        FROM sys.columns WHERE object_id = OBJECT_ID(N'CI.KZN_HIST_PEDRAVISAOCONSOLIDADA') AND name IN (N'SG_GM', N'URL_GM', N'ID_TIPO_KAIZEN');
        EXEC sp_executesql @sql;
    END

    -- 4: KZN_ADMIN
    IF OBJECT_ID(N'CI.FK_KZN_ADMIN_MATRICULA', N'F') IS NOT NULL
        ALTER TABLE CI.KZN_ADMIN DROP CONSTRAINT FK_KZN_ADMIN_MATRICULA;
    IF EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID(N'CI.KZN_ADMIN') AND name = N'CD_MATRICULA'
                 AND (TYPE_NAME(user_type_id) <> N'int' OR is_nullable = 1))
       OR NOT EXISTS (SELECT 1 FROM sys.key_constraints kc JOIN sys.index_columns ic ON ic.object_id = kc.parent_object_id AND ic.index_id = kc.unique_index_id
                      WHERE kc.parent_object_id = OBJECT_ID(N'CI.KZN_ADMIN') AND kc.type = 'PK' AND COL_NAME(ic.object_id, ic.column_id) = N'CD_MATRICULA')
    BEGIN
        SELECT @sql = N'ALTER TABLE CI.KZN_ADMIN DROP CONSTRAINT ' + QUOTENAME(name) + N';'
        FROM sys.key_constraints WHERE parent_object_id = OBJECT_ID(N'CI.KZN_ADMIN') AND type = 'PK';
        IF @sql IS NOT NULL EXEC sp_executesql @sql;
        ALTER TABLE CI.KZN_ADMIN ALTER COLUMN CD_MATRICULA INT NOT NULL;
        ALTER TABLE CI.KZN_ADMIN ADD CONSTRAINT PK_KZN_ADMIN PRIMARY KEY CLUSTERED (ID_ADMIN, CD_MATRICULA);
    END

    -- 5: KZN_APROVADOR
    IF OBJECT_ID(N'CI.FK_KZN_APROVADOR_MATRICULA', N'F') IS NOT NULL AND OBJECT_ID(N'CI.FK_KZN_APROVADOR_MDM_MATRICULA', N'F') IS NULL
        EXEC sp_rename N'CI.FK_KZN_APROVADOR_MATRICULA', N'FK_KZN_APROVADOR_MDM_MATRICULA', N'OBJECT';
    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'CI.KZN_APROVADOR') AND name = N'UQ_KZN_APROVADOR_ID')
        ALTER TABLE CI.KZN_APROVADOR ADD CONSTRAINT UQ_KZN_APROVADOR_ID UNIQUE NONCLUSTERED (ID_APROVADOR);

    -- 6: KZN_KAIZEN_HIERARQUIA
    IF OBJECT_ID(N'CI.FK_KZN_KAIZEN_HIERARQUIA_USUARIO', N'F') IS NULL
        ALTER TABLE CI.KZN_KAIZEN_HIERARQUIA WITH CHECK ADD CONSTRAINT FK_KZN_KAIZEN_HIERARQUIA_USUARIO
            FOREIGN KEY (ID_USUARIO_LIDER) REFERENCES CI.KZN_MDM_HIERARQUIA (ID_USUARIO);
    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'CI.KZN_KAIZEN_HIERARQUIA') AND name = N'IX_KZN_KAIZEN_HIERARQUIA_KAIZEN')
        CREATE NONCLUSTERED INDEX IX_KZN_KAIZEN_HIERARQUIA_KAIZEN ON CI.KZN_KAIZEN_HIERARQUIA (ID_USUARIO_LIDER);

    -- 7: KZN_PEDRAVISAOCONSOLIDADA
    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'CI.KZN_PEDRAVISAOCONSOLIDADA') AND name = N'IX_KZN_PVC_TIPO_KAIZEN')
        CREATE NONCLUSTERED INDEX IX_KZN_PVC_TIPO_KAIZEN ON CI.KZN_PEDRAVISAOCONSOLIDADA (ID_TIPO_KAIZEN);

    -- 8: KZN_MEMBROS_EQUIPE
    IF OBJECT_ID(N'CI.FK_KZN_MEMBROS_EQUIPE_KAIZEN', N'F') IS NOT NULL
        ALTER TABLE CI.KZN_MEMBROS_EQUIPE DROP CONSTRAINT FK_KZN_MEMBROS_EQUIPE_KAIZEN;
    SELECT @sql = NULL;
    SELECT @sql = N'CI.' + QUOTENAME(name) FROM sys.key_constraints
    WHERE parent_object_id = OBJECT_ID(N'CI.KZN_MEMBROS_EQUIPE') AND type = 'PK'
      AND name COLLATE Latin1_General_BIN <> N'PK_kzn_membros_equipe' COLLATE Latin1_General_BIN;
    IF @sql IS NOT NULL EXEC sp_rename @sql, N'PK_kzn_membros_equipe', N'OBJECT';

    -- 9: KZN_STATUS
    IF OBJECT_ID(N'CI.FK_KZN_STATUS_USUARIO', N'F') IS NOT NULL
        ALTER TABLE CI.KZN_STATUS DROP CONSTRAINT FK_KZN_STATUS_USUARIO;

    -- 10: KZN_MDM_TERCEIROS_USUARIO
    IF OBJECT_ID(N'CI.KZN_MDM_TERCEIROS_USUARIO', N'U') IS NULL
        CREATE TABLE CI.KZN_MDM_TERCEIROS_USUARIO (
            ID_USUARIO      INT          NOT NULL,
            CD_MATRICULA    VARCHAR(30)  NOT NULL,
            DT_CRIACAO      DATETIME2(3) NOT NULL,
            DT_ATUALIZACAO  DATETIME2(3) NOT NULL,
            CONSTRAINT PK_KZN_MDM_TERCEIROS_USUARIO PRIMARY KEY CLUSTERED (ID_USUARIO),
            CONSTRAINT UQ_KZN_MDM_TERCEIROS_USUARIO_CD_MATRICULA UNIQUE NONCLUSTERED (CD_MATRICULA)
        );

    -- 11: collation da PRD no MDM (e na matrícula do APROVADOR)
    SELECT @sql = STRING_AGG(CONVERT(NVARCHAR(MAX),
               N'ALTER TABLE CI.' + QUOTENAME(OBJECT_NAME(c.object_id)) + N' ALTER COLUMN ' + QUOTENAME(c.name) + N' '
             + TYPE_NAME(c.user_type_id) + N'(' + CASE WHEN c.max_length = -1 THEN N'max'
                                                       WHEN TYPE_NAME(c.user_type_id) IN (N'nvarchar', N'nchar') THEN CAST(c.max_length / 2 AS NVARCHAR(10))
                                                       ELSE CAST(c.max_length AS NVARCHAR(10)) END + N')'
             + N' COLLATE Latin1_General_CI_AS' + CASE WHEN c.is_nullable = 1 THEN N' NULL;' ELSE N' NOT NULL;' END), NCHAR(10))
    FROM sys.columns c
    WHERE c.collation_name IS NOT NULL AND c.collation_name <> N'Latin1_General_CI_AS'
      AND (c.object_id = OBJECT_ID(N'CI.KZN_MDM_HIERARQUIA') OR (c.object_id = OBJECT_ID(N'CI.KZN_APROVADOR') AND c.name = N'CD_MATRICULA'));
    IF @sql IS NOT NULL
    BEGIN
        IF OBJECT_ID(N'CI.FK_KZN_APROVADOR_MDM_MATRICULA', N'F') IS NOT NULL ALTER TABLE CI.KZN_APROVADOR DROP CONSTRAINT FK_KZN_APROVADOR_MDM_MATRICULA;
        IF EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'CI.KZN_MDM_HIERARQUIA') AND name = N'IX_KZN_MDM_HIERARQUIA_EMAIL')
            DROP INDEX IX_KZN_MDM_HIERARQUIA_EMAIL ON CI.KZN_MDM_HIERARQUIA;
        IF OBJECT_ID(N'CI.UQ_KZN_MDM_HIERARQUIA_MATR', N'UQ') IS NOT NULL ALTER TABLE CI.KZN_MDM_HIERARQUIA DROP CONSTRAINT UQ_KZN_MDM_HIERARQUIA_MATR;
        IF OBJECT_ID(N'CI.PK_KZN_MDM_HIERARQUIA', N'PK') IS NOT NULL ALTER TABLE CI.KZN_MDM_HIERARQUIA DROP CONSTRAINT PK_KZN_MDM_HIERARQUIA;

        EXEC sp_executesql @sql;

        ALTER TABLE CI.KZN_MDM_HIERARQUIA ADD CONSTRAINT PK_KZN_MDM_HIERARQUIA PRIMARY KEY CLUSTERED (ID_USUARIO, CD_MATRICULA, ID_TIPO_USUARIO);
        ALTER TABLE CI.KZN_MDM_HIERARQUIA ADD CONSTRAINT UQ_KZN_MDM_HIERARQUIA_MATR UNIQUE NONCLUSTERED (CD_MATRICULA);
        CREATE NONCLUSTERED INDEX IX_KZN_MDM_HIERARQUIA_EMAIL ON CI.KZN_MDM_HIERARQUIA (CD_EMAIL);
        ALTER TABLE CI.KZN_APROVADOR WITH CHECK ADD CONSTRAINT FK_KZN_APROVADOR_MDM_MATRICULA
            FOREIGN KEY (CD_MATRICULA) REFERENCES CI.KZN_MDM_HIERARQUIA (CD_MATRICULA);
    END

    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    DECLARE @e NVARCHAR(2048) = N'Falha, nada foi alterado (ROLLBACK): ' + ERROR_MESSAGE();
    RAISERROR(N'%s', 16, 1, @e);
    RETURN;
END CATCH

/* ── Conferência (esperado = PRD) ───────────────────────────────────── */
SELECT ITEM, RESULTADO = CASE WHEN OK = 1 THEN 'OK' ELSE 'DIVERGE' END
FROM (
    SELECT ITEM = N'Colunas ' + x.TABELA + N'.' + x.COLUNA + N' ' + x.TIPO + CASE WHEN x.NULO = 1 THEN N' NULL' ELSE N' NOT NULL' END,
           OK = CASE WHEN c.is_nullable = x.NULO AND (x.TIPO NOT LIKE N'varchar%' OR c.max_length = x.TAM) THEN 1 ELSE 0 END
    FROM @COL x LEFT JOIN sys.columns c ON c.object_id = OBJECT_ID(N'CI.' + QUOTENAME(x.TABELA)) AND c.name COLLATE DATABASE_DEFAULT = x.COLUNA
    UNION ALL SELECT N'HIST PVC sem SG_GM/URL_GM/ID_TIPO_KAIZEN',
           CASE WHEN COL_LENGTH(N'CI.KZN_HIST_PEDRAVISAOCONSOLIDADA', N'SG_GM') IS NULL AND COL_LENGTH(N'CI.KZN_HIST_PEDRAVISAOCONSOLIDADA', N'URL_GM') IS NULL
                     AND COL_LENGTH(N'CI.KZN_HIST_PEDRAVISAOCONSOLIDADA', N'ID_TIPO_KAIZEN') IS NULL THEN 1 ELSE 0 END
    UNION ALL SELECT N'KZN_ADMIN.CD_MATRICULA int NOT NULL',
           CASE WHEN EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID(N'CI.KZN_ADMIN') AND name = N'CD_MATRICULA' AND TYPE_NAME(user_type_id) = N'int' AND is_nullable = 0) THEN 1 ELSE 0 END
    UNION ALL SELECT N'PK_KZN_ADMIN (ID_ADMIN, CD_MATRICULA)',
           CASE WHEN (SELECT COUNT(*) FROM sys.key_constraints kc JOIN sys.index_columns ic ON ic.object_id = kc.parent_object_id AND ic.index_id = kc.unique_index_id
                      WHERE kc.parent_object_id = OBJECT_ID(N'CI.KZN_ADMIN') AND kc.name = N'PK_KZN_ADMIN'
                        AND COL_NAME(ic.object_id, ic.column_id) IN (N'ID_ADMIN', N'CD_MATRICULA')) = 2 THEN 1 ELSE 0 END
    UNION ALL SELECT N'Sem FK_KZN_ADMIN_MATRICULA', CASE WHEN OBJECT_ID(N'CI.FK_KZN_ADMIN_MATRICULA') IS NULL THEN 1 ELSE 0 END
    UNION ALL SELECT N'FK_KZN_APROVADOR_MDM_MATRICULA', CASE WHEN OBJECT_ID(N'CI.FK_KZN_APROVADOR_MDM_MATRICULA', N'F') IS NOT NULL AND OBJECT_ID(N'CI.FK_KZN_APROVADOR_MATRICULA') IS NULL THEN 1 ELSE 0 END
    UNION ALL SELECT N'UQ_KZN_APROVADOR_ID', CASE WHEN EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'CI.KZN_APROVADOR') AND name = N'UQ_KZN_APROVADOR_ID' AND is_unique = 1) THEN 1 ELSE 0 END
    UNION ALL SELECT N'FK_KZN_KAIZEN_HIERARQUIA_USUARIO (confiável)', CASE WHEN EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = N'FK_KZN_KAIZEN_HIERARQUIA_USUARIO' AND is_not_trusted = 0) THEN 1 ELSE 0 END
    UNION ALL SELECT N'IX_KZN_KAIZEN_HIERARQUIA_KAIZEN', CASE WHEN EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'CI.KZN_KAIZEN_HIERARQUIA') AND name = N'IX_KZN_KAIZEN_HIERARQUIA_KAIZEN') THEN 1 ELSE 0 END
    UNION ALL SELECT N'IX_KZN_PVC_TIPO_KAIZEN', CASE WHEN EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'CI.KZN_PEDRAVISAOCONSOLIDADA') AND name = N'IX_KZN_PVC_TIPO_KAIZEN') THEN 1 ELSE 0 END
    UNION ALL SELECT N'Sem FK_KZN_MEMBROS_EQUIPE_KAIZEN', CASE WHEN OBJECT_ID(N'CI.FK_KZN_MEMBROS_EQUIPE_KAIZEN') IS NULL THEN 1 ELSE 0 END
    UNION ALL SELECT N'PK_kzn_membros_equipe', CASE WHEN EXISTS (SELECT 1 FROM sys.key_constraints WHERE parent_object_id = OBJECT_ID(N'CI.KZN_MEMBROS_EQUIPE') AND type = 'PK'
                     AND name COLLATE Latin1_General_BIN = N'PK_kzn_membros_equipe' COLLATE Latin1_General_BIN) THEN 1 ELSE 0 END
    UNION ALL SELECT N'Sem FK_KZN_STATUS_USUARIO', CASE WHEN OBJECT_ID(N'CI.FK_KZN_STATUS_USUARIO') IS NULL THEN 1 ELSE 0 END
    UNION ALL SELECT N'KZN_MDM_TERCEIROS_USUARIO', CASE WHEN OBJECT_ID(N'CI.KZN_MDM_TERCEIROS_USUARIO', N'U') IS NOT NULL THEN 1 ELSE 0 END
    UNION ALL SELECT N'Collation Latin1_General_CI_AS no MDM e em APROVADOR.CD_MATRICULA',
           CASE WHEN NOT EXISTS (SELECT 1 FROM sys.columns c WHERE c.collation_name IS NOT NULL AND c.collation_name <> N'Latin1_General_CI_AS'
                                 AND (c.object_id = OBJECT_ID(N'CI.KZN_MDM_HIERARQUIA') OR (c.object_id = OBJECT_ID(N'CI.KZN_APROVADOR') AND c.name = N'CD_MATRICULA'))) THEN 1 ELSE 0 END
    UNION ALL SELECT N'PK/UQ/IX do MDM e FK_KZN_APROVADOR_MDM_MATRICULA (confiável)',
           CASE WHEN OBJECT_ID(N'CI.PK_KZN_MDM_HIERARQUIA', N'PK') IS NOT NULL AND OBJECT_ID(N'CI.UQ_KZN_MDM_HIERARQUIA_MATR', N'UQ') IS NOT NULL
                     AND EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'CI.KZN_MDM_HIERARQUIA') AND name = N'IX_KZN_MDM_HIERARQUIA_EMAIL')
                     AND EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = N'FK_KZN_APROVADOR_MDM_MATRICULA' AND is_not_trusted = 0) THEN 1 ELSE 0 END
) r;
GO
