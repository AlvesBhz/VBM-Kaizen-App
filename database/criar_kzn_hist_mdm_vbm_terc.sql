/* =====================================================================
   CI.KZN_HIST_MDM_VBM_TERC — copia de CI.KZN_MDM_HIERARQUIA
   ---------------------------------------------------------------------
   Estrutura lida do CATALOGO em tempo de execucao, nao do DDL do repo:
   mesmas colunas, mesma ordem, mesmo tipo/tamanho, mesma nulidade e
   mesma collation da tabela real — e a mesma PK. Sem DEFAULT, UNIQUE,
   FK, indice extra ou trigger: segue o padrao das KZN_HIST_* (copia
   inerte, sem amarracao com a producao).

   Dados: fotografia da CI.KZN_MDM_HIERARQUIA no momento da execucao.
   Se a tabela nova ja tiver linhas, ABORTA — para recarregar a
   fotografia, troque @RECARREGAR para 1 (apaga e copia de novo).

   Nao altera CI.KZN_MDM_HIERARQUIA (so leitura). Idempotente.
   Transacionado: erro em qualquer etapa desfaz tudo. Schema: 'ci'.
   ===================================================================== */

SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @RECARREGAR BIT = 0;   -- 1 = apaga as linhas da copia e copia de novo

DECLARE @origem  NVARCHAR(300) = N'CI.KZN_MDM_HIERARQUIA',
        @destino NVARCHAR(300) = N'CI.KZN_HIST_MDM_VBM_TERC',
        @objId INT, @cols NVARCHAR(MAX), @lista NVARCHAR(MAX), @pk NVARCHAR(MAX),
        @sql NVARCHAR(MAX), @qtOrigem INT, @qtDestino INT, @qt INT;

/* =====================================================================
   E0 - PRE-CHECAGENS
   ===================================================================== */
SET @objId = OBJECT_ID(@origem, 'U');
IF @objId IS NULL
BEGIN
    RAISERROR('Abortado: CI.KZN_MDM_HIERARQUIA nao existe.', 16, 1);
    RETURN;
END

IF OBJECT_ID(@destino, 'U') IS NOT NULL AND @RECARREGAR = 0
BEGIN
    EXEC sp_executesql N'SELECT @c = COUNT(*) FROM CI.KZN_HIST_MDM_VBM_TERC;', N'@c INT OUTPUT', @c = @qt OUTPUT;
    IF @qt > 0
    BEGIN
        DECLARE @m NVARCHAR(300) = 'Abortado: CI.KZN_HIST_MDM_VBM_TERC ja tem ' + CAST(@qt AS VARCHAR(10))
            + ' linha(s). Para recarregar a fotografia, troque @RECARREGAR para 1.';
        RAISERROR(@m, 16, 1);
        RETURN;
    END
END

/* =====================================================================
   E1 - ESTRUTURA A PARTIR DO CATALOGO
   Coluna calculada fica de fora (nao ha o que copiar como dado); IDENTITY
   nao e replicado — a copia recebe o valor da origem.

   COLLATE DATABASE_DEFAULT nos nomes vindos do catalogo: sys.columns e
   sys.types usam a collation do catalogo, os literais do script a do
   banco, e o STRING_AGG nao concatena as duas (Msg 4191).
   ===================================================================== */
SELECT  @cols = STRING_AGG(CONVERT(NVARCHAR(MAX),
            N'    ' + QUOTENAME(x.nm) + N' '
          + CASE
              WHEN x.tp IN (N'varchar',N'char',N'varbinary',N'binary')
                   THEN x.tp + N'(' + CASE WHEN c.max_length = -1 THEN N'MAX' ELSE CAST(c.max_length AS NVARCHAR(10)) END + N')'
              WHEN x.tp IN (N'nvarchar',N'nchar')
                   THEN x.tp + N'(' + CASE WHEN c.max_length = -1 THEN N'MAX' ELSE CAST(c.max_length / 2 AS NVARCHAR(10)) END + N')'
              WHEN x.tp IN (N'decimal',N'numeric')
                   THEN x.tp + N'(' + CAST(c.precision AS NVARCHAR(10)) + N',' + CAST(c.scale AS NVARCHAR(10)) + N')'
              WHEN x.tp IN (N'datetime2',N'time',N'datetimeoffset')
                   THEN x.tp + N'(' + CAST(c.scale AS NVARCHAR(10)) + N')'
              ELSE x.tp
            END
          + CASE WHEN x.col IS NOT NULL THEN N' COLLATE ' + x.col ELSE N'' END
          + CASE WHEN c.is_nullable = 1 THEN N' NULL' ELSE N' NOT NULL' END),
            N',' + NCHAR(13) + NCHAR(10)) WITHIN GROUP (ORDER BY c.column_id),
        @lista = STRING_AGG(CONVERT(NVARCHAR(MAX), QUOTENAME(x.nm)), N', ') WITHIN GROUP (ORDER BY c.column_id)
FROM    sys.columns c
JOIN    sys.types   ty ON ty.user_type_id = c.user_type_id
CROSS APPLY (SELECT nm  = CONVERT(NVARCHAR(128), c.name)           COLLATE DATABASE_DEFAULT,
                    tp  = CONVERT(NVARCHAR(128), ty.name)          COLLATE DATABASE_DEFAULT,
                    col = CONVERT(NVARCHAR(128), c.collation_name) COLLATE DATABASE_DEFAULT) x
WHERE   c.object_id = @objId
  AND   c.is_computed = 0;

SELECT  @pk = STRING_AGG(CONVERT(NVARCHAR(MAX), QUOTENAME(CONVERT(NVARCHAR(128), c.name) COLLATE DATABASE_DEFAULT)
                  + CASE WHEN ic.is_descending_key = 1 THEN N' DESC' ELSE N'' END), N', ')
              WITHIN GROUP (ORDER BY ic.key_ordinal)
FROM    sys.indexes i
JOIN    sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.key_ordinal > 0
JOIN    sys.columns c        ON c.object_id = ic.object_id AND c.column_id = ic.column_id
WHERE   i.object_id = @objId AND i.is_primary_key = 1;

/* Sem GO ate o fim: RAISERROR + RETURN so encerram o batch em que
   aparecem. */

BEGIN TRANSACTION;
BEGIN TRY

    IF OBJECT_ID(@destino, 'U') IS NULL
    BEGIN
        SET @sql = N'CREATE TABLE CI.KZN_HIST_MDM_VBM_TERC
(
' + @cols
          + CASE WHEN @pk IS NOT NULL
                 THEN N',' + CHAR(13) + CHAR(10) + N'    CONSTRAINT PK_KZN_HIST_MDM_VBM_TERC PRIMARY KEY CLUSTERED (' + @pk + N')'
                 ELSE N'' END + N'
);';
        EXEC sp_executesql @sql;
        PRINT 'E1 - CI.KZN_HIST_MDM_VBM_TERC criada.';
    END
    ELSE
    BEGIN
        /* Ja existia: confere que as colunas batem com a origem antes de copiar. */
        IF EXISTS (
            SELECT c.name FROM sys.columns c WHERE c.object_id = @objId AND c.is_computed = 0
            EXCEPT
            SELECT d.name FROM sys.columns d WHERE d.object_id = OBJECT_ID(@destino, 'U'))
            RAISERROR('Abortado: CI.KZN_HIST_MDM_VBM_TERC ja existe e nao tem todas as colunas de CI.KZN_MDM_HIERARQUIA. Dropar e rodar de novo.', 16, 1);
        PRINT 'E1 - CI.KZN_HIST_MDM_VBM_TERC ja existe; estrutura conferida.';

        IF @RECARREGAR = 1
        BEGIN
            EXEC sp_executesql N'DELETE FROM CI.KZN_HIST_MDM_VBM_TERC; SET @c = @@ROWCOUNT;', N'@c INT OUTPUT', @c = @qt OUTPUT;
            PRINT 'E1 - ' + CAST(@qt AS VARCHAR(10)) + ' linha(s) da fotografia anterior apagada(s).';
        END
    END

    /* =================================================================
       E2 - POPULACAO (fotografia da tabela atual)
       ================================================================= */
    SET @sql = N'INSERT INTO CI.KZN_HIST_MDM_VBM_TERC (' + @lista + N')
SELECT ' + @lista + N' FROM CI.KZN_MDM_HIERARQUIA;
SET @c = @@ROWCOUNT;';
    EXEC sp_executesql @sql, N'@c INT OUTPUT', @c = @qtDestino OUTPUT;

    /* Conferencia antes do COMMIT: mesma quantidade da origem. */
    EXEC sp_executesql N'SELECT @c = COUNT(*) FROM CI.KZN_MDM_HIERARQUIA;', N'@c INT OUTPUT', @c = @qtOrigem OUTPUT;
    IF @qtDestino <> @qtOrigem
    BEGIN
        DECLARE @m2 NVARCHAR(300) = 'Abortado: copiadas ' + CAST(@qtDestino AS VARCHAR(10)) + ' linha(s), origem tem '
            + CAST(@qtOrigem AS VARCHAR(10)) + '. ROLLBACK aplicado.';
        RAISERROR(@m2, 16, 1);
    END

    COMMIT TRANSACTION;
    PRINT 'E2 - ' + CAST(@qtDestino AS VARCHAR(10)) + ' linha(s) copiada(s) de CI.KZN_MDM_HIERARQUIA.';
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    PRINT 'ERRO - nada foi gravado (rollback aplicado): ' + ERROR_MESSAGE();
    THROW;
END CATCH
GO

/* =====================================================================
   E3 - CONFERENCIA: estrutura lado a lado (vazio = identicas) e totais
   ===================================================================== */
IF OBJECT_ID('CI.KZN_HIST_MDM_VBM_TERC', 'U') IS NOT NULL
SELECT  COLUNA       = ISNULL(o.name, d.name),
        NA_ORIGEM    = ISNULL(o.tipo, '-- ausente --'),
        NA_COPIA     = ISNULL(d.tipo, '-- ausente --')
FROM (
    SELECT c.name, tipo = ty.name + '(' + CAST(c.max_length AS VARCHAR(10)) + ')' + CASE WHEN c.is_nullable = 1 THEN ' NULL' ELSE ' NOT NULL' END
    FROM sys.columns c JOIN sys.types ty ON ty.user_type_id = c.user_type_id
    WHERE c.object_id = OBJECT_ID('CI.KZN_MDM_HIERARQUIA') AND c.is_computed = 0
) o
FULL JOIN (
    SELECT c.name, tipo = ty.name + '(' + CAST(c.max_length AS VARCHAR(10)) + ')' + CASE WHEN c.is_nullable = 1 THEN ' NULL' ELSE ' NOT NULL' END
    FROM sys.columns c JOIN sys.types ty ON ty.user_type_id = c.user_type_id
    WHERE c.object_id = OBJECT_ID('CI.KZN_HIST_MDM_VBM_TERC')
) d ON d.name COLLATE DATABASE_DEFAULT = o.name COLLATE DATABASE_DEFAULT
WHERE   o.name IS NULL OR d.name IS NULL OR o.tipo <> d.tipo;

/* Dinamico e protegido: se o bloco anterior abortou antes do CREATE, a
   copia nao existe e uma referencia estatica daria Msg 208. */
IF OBJECT_ID('CI.KZN_HIST_MDM_VBM_TERC', 'U') IS NULL
    PRINT 'Conferencia: CI.KZN_HIST_MDM_VBM_TERC nao existe (veja o erro acima).';
ELSE
    EXEC sp_executesql N'
    SELECT  ORIGEM = (SELECT COUNT(*) FROM CI.KZN_MDM_HIERARQUIA),
            COPIA  = (SELECT COUNT(*) FROM CI.KZN_HIST_MDM_VBM_TERC);';
GO
