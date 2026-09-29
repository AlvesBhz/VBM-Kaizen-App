/* =====================================================================
   CI.KZN_HIST_MDM_VBM_TERC — flexibiliza para receber a guia da planilha
   ---------------------------------------------------------------------
   A guia KZN_HIST_MDM_VBM_TERC so traz ID_USUARIO, CD_MATRICULA e
   NM_USUARIO. A tabela (copia de CI.KZN_MDM_HIERARQUIA) recusava:
     - ID_TIPO_USUARIO, CD_EMAIL, SG_ATIVO, DT_ATUALIZACAO NOT NULL e
       vazias nas 1724 linhas;
     - NM_USUARIO VARCHAR(30), guia chega a 38.

   O que muda (tabela so de historico — autorizado):
     1. PK passa a ser so (ID_USUARIO). A PK copiada incluia
        ID_TIPO_USUARIO, e coluna de PK nao pode ser NULL. ID_USUARIO ja
        era unico sozinho na origem (UQ_KZN_MDM_HIERARQUIA_USUARIO).
     2. Toda coluna NOT NULL vira NULL, exceto ID_USUARIO (chave),
        CD_MATRICULA e NM_USUARIO (os tres que a guia preenche).
     3. NM_USUARIO passa a 100 caracteres.
   Tipo e collation de cada coluna sao REPETIDOS no ALTER: ALTER COLUMN
   sem COLLATE troca a collation pela do banco sem avisar.

   Nenhuma linha e alterada. CI.KZN_MDM_HIERARQUIA nao e tocada.
   Idempotente. Transacionado. Schema: 'ci'.
   ===================================================================== */

SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @tab NVARCHAR(300) = N'CI.KZN_HIST_MDM_VBM_TERC', @objId INT,
        @sql NVARCHAR(MAX), @pkNome SYSNAME, @pkCols NVARCHAR(MAX), @qt INT;

/* =====================================================================
   E0 - PRE-CHECAGENS
   ===================================================================== */
SET @objId = OBJECT_ID(@tab, 'U');
IF @objId IS NULL
BEGIN
    RAISERROR('Abortado: CI.KZN_HIST_MDM_VBM_TERC nao existe. Rode criar_kzn_hist_mdm_vbm_terc.sql antes.', 16, 1);
    RETURN;
END

/* A nova PK exige ID_USUARIO unico e preenchido nas linhas que ja existem. */
EXEC sp_executesql N'
SELECT @c = COUNT(*) FROM (
    SELECT ID_USUARIO FROM CI.KZN_HIST_MDM_VBM_TERC
    GROUP BY ID_USUARIO HAVING COUNT(*) > 1 OR ID_USUARIO IS NULL) d;', N'@c INT OUTPUT', @c = @qt OUTPUT;
IF @qt > 0
BEGIN
    EXEC sp_executesql N'
    SELECT ID_USUARIO, QT = COUNT(*) FROM CI.KZN_HIST_MDM_VBM_TERC
    GROUP BY ID_USUARIO HAVING COUNT(*) > 1 OR ID_USUARIO IS NULL ORDER BY ID_USUARIO;';
    RAISERROR('Abortado: ID_USUARIO repetido ou vazio na tabela (lista acima) — nao da para ser a PK.', 16, 1);
    RETURN;
END

SELECT  @pkNome = CONVERT(NVARCHAR(128), i.name) COLLATE DATABASE_DEFAULT
FROM    sys.indexes i WHERE i.object_id = @objId AND i.is_primary_key = 1;

SELECT  @pkCols = STRING_AGG(CONVERT(NVARCHAR(MAX), CONVERT(NVARCHAR(128), c.name) COLLATE DATABASE_DEFAULT), N',')
                  WITHIN GROUP (ORDER BY ic.key_ordinal)
FROM    sys.index_columns ic
JOIN    sys.indexes i  ON i.object_id = ic.object_id AND i.index_id = ic.index_id AND i.is_primary_key = 1
JOIN    sys.columns c  ON c.object_id = ic.object_id AND c.column_id = ic.column_id
WHERE   ic.object_id = @objId AND ic.key_ordinal > 0;

/* Colunas a alterar, com a definicao atual repetida (tipo + collation). */
DECLARE @alvo TABLE (ORDEM INT IDENTITY(1,1), COLUNA SYSNAME, DEF NVARCHAR(400));
INSERT INTO @alvo (COLUNA, DEF)
SELECT  x.nm,
        CASE
          WHEN x.nm = N'NM_USUARIO' AND x.tp IN (N'varchar',N'nvarchar')
               THEN x.tp + N'(' + CASE WHEN c.max_length = -1 THEN N'MAX'
                                       WHEN c.max_length / CASE WHEN x.tp = N'nvarchar' THEN 2 ELSE 1 END >= 100
                                            THEN CAST(c.max_length / CASE WHEN x.tp = N'nvarchar' THEN 2 ELSE 1 END AS NVARCHAR(10))
                                       ELSE N'100' END + N')'
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
      + CASE WHEN x.nm IN (N'ID_USUARIO', N'CD_MATRICULA', N'NM_USUARIO') AND c.is_nullable = 0
             THEN N' NOT NULL' ELSE N' NULL' END
FROM    sys.columns c
JOIN    sys.types ty ON ty.user_type_id = c.user_type_id
CROSS APPLY (SELECT nm  = CONVERT(NVARCHAR(128), c.name)           COLLATE DATABASE_DEFAULT,
                    tp  = CONVERT(NVARCHAR(128), ty.name)          COLLATE DATABASE_DEFAULT,
                    col = CONVERT(NVARCHAR(128), c.collation_name) COLLATE DATABASE_DEFAULT) x
WHERE   c.object_id = @objId
  AND   c.is_computed = 0
  AND   x.nm <> N'ID_USUARIO'
  AND  (   (c.is_nullable = 0 AND x.nm NOT IN (N'CD_MATRICULA', N'NM_USUARIO'))
        OR (x.nm = N'NM_USUARIO' AND c.max_length <> -1
            AND c.max_length / CASE WHEN x.tp IN (N'nvarchar',N'nchar') THEN 2 ELSE 1 END < 100))
ORDER BY c.column_id;

SELECT COLUNA, NOVA_DEFINICAO = DEF FROM @alvo ORDER BY ORDEM;
PRINT 'PK atual: ' + ISNULL(@pkNome + ' (' + @pkCols + ')', '(nenhuma)');

IF NOT EXISTS (SELECT 1 FROM @alvo) AND ISNULL(@pkCols, N'') = N'ID_USUARIO'
BEGIN
    PRINT 'Nada a fazer - tabela ja ajustada.';
    RETURN;
END

/* Sem GO ate o fim: RAISERROR + RETURN so encerram o batch em que
   aparecem. */

BEGIN TRANSACTION;
BEGIN TRY

    /* E1 - PK antiga sai primeiro: ALTER COLUMN em coluna de PK e barrado. */
    IF @pkNome IS NOT NULL AND ISNULL(@pkCols, N'') <> N'ID_USUARIO'
    BEGIN
        SET @sql = N'ALTER TABLE CI.KZN_HIST_MDM_VBM_TERC DROP CONSTRAINT ' + QUOTENAME(@pkNome) + N';';
        EXEC sp_executesql @sql;
        PRINT 'E1 - PK ' + @pkNome + ' (' + @pkCols + ') removida.';
    END

    /* E2 - colunas */
    DECLARE @i INT = 1, @n INT, @col SYSNAME, @def NVARCHAR(400);
    SELECT @n = MAX(ORDEM) FROM @alvo;
    WHILE @i <= ISNULL(@n, 0)
    BEGIN
        SELECT @col = COLUNA, @def = DEF FROM @alvo WHERE ORDEM = @i;
        SET @sql = N'ALTER TABLE CI.KZN_HIST_MDM_VBM_TERC ALTER COLUMN ' + QUOTENAME(@col) + N' ' + @def + N';';
        EXEC sp_executesql @sql;
        PRINT 'E2 - ' + @col + ' -> ' + @def;
        SET @i += 1;
    END

    /* E3 - nova PK */
    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = @objId AND is_primary_key = 1)
    BEGIN
        EXEC sp_executesql N'ALTER TABLE CI.KZN_HIST_MDM_VBM_TERC
            ADD CONSTRAINT PK_KZN_HIST_MDM_VBM_TERC PRIMARY KEY CLUSTERED (ID_USUARIO);';
        PRINT 'E3 - PK_KZN_HIST_MDM_VBM_TERC (ID_USUARIO) criada.';
    END

    COMMIT TRANSACTION;
    PRINT 'Concluido. Rode carga_hist_importe_7281_12267.sql.';
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    PRINT 'ERRO - nada foi alterado (rollback aplicado): ' + ERROR_MESSAGE();
    THROW;
END CATCH
GO

/* =====================================================================
   E4 - CONFERENCIA
   ===================================================================== */
SELECT  COLUNA = c.name,
        TIPO   = ty.name + CASE WHEN ty.name LIKE '%char' THEN '(' + CASE WHEN c.max_length = -1 THEN 'MAX'
                     ELSE CAST(c.max_length / CASE WHEN ty.name LIKE 'n%' THEN 2 ELSE 1 END AS VARCHAR(10)) END + ')' ELSE '' END,
        NULO   = CASE WHEN c.is_nullable = 1 THEN 'SIM' ELSE 'NAO' END,
        NA_PK  = CASE WHEN EXISTS (SELECT 1 FROM sys.index_columns ic JOIN sys.indexes i
                                     ON i.object_id = ic.object_id AND i.index_id = ic.index_id AND i.is_primary_key = 1
                                   WHERE ic.object_id = c.object_id AND ic.column_id = c.column_id) THEN 'SIM' ELSE '' END
FROM    sys.columns c JOIN sys.types ty ON ty.user_type_id = c.user_type_id
WHERE   c.object_id = OBJECT_ID('CI.KZN_HIST_MDM_VBM_TERC')
ORDER BY c.column_id;
GO
