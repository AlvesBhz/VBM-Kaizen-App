/* =====================================================================
   CI.KZN_ADMIN.CD_MATRICULA — de INT para VARCHAR(30)
   (executar no BDIBPBMSA_PRD; também serve para o DEV)
   ---------------------------------------------------------------------
   Matrícula não é número (há matrículas como 'FG002634'): passa a
   VARCHAR(30), igual a KZN_MDM_HIERARQUIA.CD_MATRICULA e
   KZN_APROVADOR.CD_MATRICULA, com a mesma collation da matrícula do MDM.

   Só o tipo muda. A PK continua a mesma (nome, colunas, ordem e opções:
   PK_KZN_ADMIN (ID_ADMIN, CD_MATRICULA)); como CD_MATRICULA faz parte
   dela, a PK é removida e recriada na mesma transação. Nenhuma FK nova.
   Os valores atuais são mantidos (81034776 -> '81034776').

   Validação prévia (nada é alterado se falhar): nenhum outro objeto
   pode depender da coluna (FK para a PK, outro índice, CHECK, DEFAULT,
   estatística manual, módulo com SCHEMABINDING). Views/procedures sem
   SCHEMABINDING que citam a coluna são só listadas (continuam válidas).
   Aplicativo: só lê KZN_ADMIN por ID_USUARIO/SG_ATIVO — sem impacto.

   Tudo numa transação; LOCK_TIMEOUT de 10 s para não enfileirar as
   leituras do aplicativo se a tabela estiver em uso. Idempotente.

   REVERSÃO: @REVERTER = 1 volta para INT NOT NULL — só se todas as
   matrículas forem numéricas; senão aborta listando-as.
   ===================================================================== */

SET NOCOUNT ON;
SET XACT_ABORT ON;
SET LOCK_TIMEOUT 10000;

DECLARE @REVERTER BIT = 0;   -- 1 = volta CD_MATRICULA para INT

IF OBJECT_ID(N'CI.KZN_ADMIN', N'U') IS NULL OR COL_LENGTH(N'CI.KZN_ADMIN', N'CD_MATRICULA') IS NULL
BEGIN
    RAISERROR('Abortado: CI.KZN_ADMIN.CD_MATRICULA não existe neste banco.', 16, 1);
    RETURN;
END

DECLARE @obj INT = OBJECT_ID(N'CI.KZN_ADMIN'), @col INT = COLUMNPROPERTY(OBJECT_ID(N'CI.KZN_ADMIN'), N'CD_MATRICULA', 'ColumnId');
DECLARE @tipo SYSNAME, @tam SMALLINT, @nulo BIT, @coll SYSNAME, @n INT, @lista NVARCHAR(2000), @sql NVARCHAR(MAX);
SELECT @tipo = TYPE_NAME(user_type_id), @tam = max_length, @nulo = is_nullable FROM sys.columns WHERE object_id = @obj AND column_id = @col;
SELECT @coll = collation_name FROM sys.columns
WHERE object_id = OBJECT_ID(N'CI.KZN_MDM_HIERARQUIA') AND name = N'CD_MATRICULA';
SET @coll = ISNULL(@coll, CONVERT(SYSNAME, DATABASEPROPERTYEX(DB_NAME(), 'Collation')));

/* Estado já atingido? */
IF (@REVERTER = 0 AND @tipo = N'varchar' AND @tam = 30) OR (@REVERTER = 1 AND @tipo = N'int')
BEGIN
    PRINT N'Nada a fazer: CI.KZN_ADMIN.CD_MATRICULA já é ' + CASE WHEN @REVERTER = 1 THEN N'INT.' ELSE N'VARCHAR(30).' END;
    SELECT COLUNA = N'CD_MATRICULA', TIPO = @tipo + CASE WHEN @tipo = N'varchar' THEN N'(' + CAST(@tam AS NVARCHAR(5)) + N')' ELSE N'' END,
           NULO = CASE WHEN @nulo = 1 THEN 'NULL' ELSE 'NOT NULL' END;
    RETURN;
END

/* ── Validação prévia ───────────────────────────────────────────────── */
DECLARE @PROBLEMA TABLE (ITEM NVARCHAR(200), DETALHE NVARCHAR(2000));
IF @REVERTER = 0 AND @tipo <> N'int'
    INSERT @PROBLEMA VALUES (N'Tipo atual inesperado', @tipo + N'(' + CAST(@tam AS NVARCHAR(5)) + N') — o script espera INT.');
IF @REVERTER = 1 AND NOT (@tipo = N'varchar' AND @tam = 30)
    INSERT @PROBLEMA VALUES (N'Tipo atual inesperado', @tipo + N'(' + CAST(@tam AS NVARCHAR(5)) + N') — a reversão espera VARCHAR(30).');

INSERT @PROBLEMA SELECT N'FK aponta para KZN_ADMIN', name FROM sys.foreign_keys WHERE referenced_object_id = @obj;
INSERT @PROBLEMA
SELECT N'Índice (além da PK) usa a coluna', i.name
FROM sys.indexes i JOIN sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id
WHERE i.object_id = @obj AND ic.column_id = @col AND i.is_primary_key = 0;
INSERT @PROBLEMA
SELECT N'FK de KZN_ADMIN usa a coluna', fk.name
FROM sys.foreign_keys fk JOIN sys.foreign_key_columns fc ON fc.constraint_object_id = fk.object_id
WHERE fk.parent_object_id = @obj AND fc.parent_column_id = @col;
INSERT @PROBLEMA SELECT N'CHECK usa a coluna', name FROM sys.check_constraints
WHERE parent_object_id = @obj AND (parent_column_id = @col OR definition LIKE N'%CD[_]MATRICULA%');
INSERT @PROBLEMA SELECT N'DEFAULT na coluna', name FROM sys.default_constraints WHERE parent_object_id = @obj AND parent_column_id = @col;
INSERT @PROBLEMA
SELECT N'Estatística manual usa a coluna', s.name
FROM sys.stats s JOIN sys.stats_columns sc ON sc.object_id = s.object_id AND sc.stats_id = s.stats_id
WHERE s.object_id = @obj AND sc.column_id = @col AND s.user_created = 1;
INSERT @PROBLEMA
SELECT N'Módulo com SCHEMABINDING usa a tabela', OBJECT_SCHEMA_NAME(d.referencing_id) + N'.' + OBJECT_NAME(d.referencing_id)
FROM sys.sql_expression_dependencies d JOIN sys.sql_modules m ON m.object_id = d.referencing_id
WHERE d.referenced_id = @obj AND m.is_schema_bound = 1;
IF NOT EXISTS (SELECT 1 FROM sys.key_constraints WHERE parent_object_id = @obj AND type = 'PK')
    INSERT @PROBLEMA VALUES (N'PK', N'CI.KZN_ADMIN não tem PK — estrutura diferente da conhecida.');

IF @REVERTER = 1
BEGIN
    SELECT @n = COUNT(*), @lista = LEFT(STRING_AGG(CONVERT(NVARCHAR(MAX), ISNULL(CONVERT(NVARCHAR(30), CD_MATRICULA), N'NULL')), N', '), 1500)
    FROM CI.KZN_ADMIN WHERE TRY_CONVERT(INT, CD_MATRICULA) IS NULL;
    IF @n > 0 INSERT @PROBLEMA VALUES (N'Matrícula não numérica', CAST(@n AS NVARCHAR(10)) + N' linha(s): ' + @lista);
END

IF EXISTS (SELECT 1 FROM @PROBLEMA)
BEGIN
    SELECT ITEM, DETALHE FROM @PROBLEMA;
    SELECT @lista = LEFT(STRING_AGG(CONVERT(NVARCHAR(MAX), ITEM + N': ' + DETALHE), N' | '), 1900) FROM @PROBLEMA;
    RAISERROR(N'Abortado, nada foi alterado. %s', 16, 1, @lista);
    RETURN;
END

-- Informativo: módulos sem SCHEMABINDING que citam a coluna continuam válidos
SELECT AVISO_MODULO_CITA_COLUNA = OBJECT_SCHEMA_NAME(m.object_id) + N'.' + OBJECT_NAME(m.object_id)
FROM sys.sql_modules m
WHERE m.definition LIKE N'%KZN[_]ADMIN%' AND m.definition LIKE N'%CD[_]MATRICULA%'
  AND m.object_id <> ISNULL(OBJECT_ID(N'CI.TR_KZN_ADMIN_UPD'), 0);

/* PK atual, para recriar idêntica */
DECLARE @pkNome SYSNAME, @pkTipo NVARCHAR(60), @pkCols NVARCHAR(MAX), @pkOpc NVARCHAR(MAX);
SELECT @pkNome = kc.name, @pkTipo = i.type_desc,
       @pkCols = (SELECT STRING_AGG(CONVERT(NVARCHAR(MAX), QUOTENAME(c.name) + CASE WHEN ic.is_descending_key = 1 THEN N' DESC' ELSE N' ASC' END), N', ')
                         WITHIN GROUP (ORDER BY ic.key_ordinal)
                  FROM sys.index_columns ic JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
                  WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.key_ordinal > 0),
       @pkOpc = N'PAD_INDEX = ' + CASE WHEN i.is_padded = 1 THEN N'ON' ELSE N'OFF' END
              + CASE WHEN i.fill_factor > 0 THEN N', FILLFACTOR = ' + CAST(i.fill_factor AS NVARCHAR(3)) ELSE N'' END
              + N', ALLOW_ROW_LOCKS = ' + CASE WHEN i.allow_row_locks = 1 THEN N'ON' ELSE N'OFF' END
              + N', ALLOW_PAGE_LOCKS = ' + CASE WHEN i.allow_page_locks = 1 THEN N'ON' ELSE N'OFF' END
              + N', DATA_COMPRESSION = ' + (SELECT TOP (1) p.data_compression_desc FROM sys.partitions p WHERE p.object_id = i.object_id AND p.index_id = i.index_id)
FROM sys.key_constraints kc JOIN sys.indexes i ON i.object_id = kc.parent_object_id AND i.index_id = kc.unique_index_id
WHERE kc.parent_object_id = @obj AND kc.type = 'PK';

DECLARE @antes NVARCHAR(200) = @tipo + CASE WHEN @tipo = N'varchar' THEN N'(' + CAST(@tam AS NVARCHAR(5)) + N')' ELSE N'' END
                             + N'; PK ' + @pkNome + N' (' + @pkCols + N')';

/* ── Alteração ──────────────────────────────────────────────────────── */
BEGIN TRY
    BEGIN TRANSACTION;

    SET @sql = N'ALTER TABLE CI.KZN_ADMIN DROP CONSTRAINT ' + QUOTENAME(@pkNome) + N';';
    EXEC sp_executesql @sql;

    SET @sql = N'ALTER TABLE CI.KZN_ADMIN ALTER COLUMN CD_MATRICULA '
             + CASE WHEN @REVERTER = 1 THEN N'INT' ELSE N'VARCHAR(30) COLLATE ' + @coll END
             + CASE WHEN @nulo = 1 THEN N' NULL;' ELSE N' NOT NULL;' END;
    EXEC sp_executesql @sql;

    SET @sql = N'ALTER TABLE CI.KZN_ADMIN ADD CONSTRAINT ' + QUOTENAME(@pkNome) + N' PRIMARY KEY ' + @pkTipo
             + N' (' + @pkCols + N') WITH (' + @pkOpc + N');';
    EXEC sp_executesql @sql;

    -- conferência antes de confirmar
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = @obj AND column_id = @col
                     AND TYPE_NAME(user_type_id) = CASE WHEN @REVERTER = 1 THEN N'int' ELSE N'varchar' END
                     AND (@REVERTER = 1 OR max_length = 30) AND is_nullable = @nulo)
       OR NOT EXISTS (SELECT 1 FROM sys.key_constraints WHERE parent_object_id = @obj AND type = 'PK' AND name = @pkNome)
        THROW 50001, N'Conferência falhou: estrutura final diferente da esperada.', 1;

    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    DECLARE @e NVARCHAR(2048) = N'Falha, nada foi alterado (ROLLBACK): ' + ERROR_MESSAGE()
                              + CASE WHEN ERROR_NUMBER() = 1222 THEN N' — tabela em uso; rode de novo.' ELSE N'' END;
    RAISERROR(N'%s', 16, 1, @e);
    RETURN;
END CATCH

SELECT COLUNA = N'CI.KZN_ADMIN.CD_MATRICULA', ANTES = @antes,
       DEPOIS = TYPE_NAME(c.user_type_id) + CASE WHEN TYPE_NAME(c.user_type_id) = N'varchar' THEN N'(' + CAST(c.max_length AS NVARCHAR(5)) + N') COLLATE ' + c.collation_name COLLATE DATABASE_DEFAULT ELSE N'' END
              + N'; PK ' + @pkNome + N' (' + @pkCols + N')',
       LINHAS = (SELECT COUNT(*) FROM CI.KZN_ADMIN)
FROM sys.columns c WHERE c.object_id = @obj AND c.column_id = @col;

-- Informativo (não há FK): matrículas do ADMIN que não existem no MDM
IF @REVERTER = 0 AND OBJECT_ID(N'CI.KZN_MDM_HIERARQUIA', N'U') IS NOT NULL
    EXEC (N'SELECT AVISO_MATRICULA_SEM_MDM = a.CD_MATRICULA, a.ID_ADMIN, a.ID_USUARIO
           FROM CI.KZN_ADMIN a WHERE NOT EXISTS (SELECT 1 FROM CI.KZN_MDM_HIERARQUIA m WHERE m.CD_MATRICULA = a.CD_MATRICULA);');
GO
