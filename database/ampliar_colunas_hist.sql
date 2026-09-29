/* =====================================================================
   Amplia as colunas CI.KZN_HIST_* menores que o dado da carga
   ---------------------------------------------------------------------
   Pre-requisito de carga_hist_importe_7281_12267.sql, que abortou na
   E0.1 ("ha coluna menor que o dado desta carga").

   Mesma lista de tamanhos da E0.1 da carga. So altera a coluna cujo
   tamanho DECLARADO e menor que o exigido, e a leva para (N)VARCHAR(MAX):
   mantem o tipo (VARCHAR/NVARCHAR) e REPETE a nulidade atual — ALTER
   COLUMN sem NULL/NOT NULL deixaria a coluna NULL-avel por acidente.

   Seguro nas HIST: sao staging inertes, sem indice, PK, FK, CHECK ou
   DEFAULT em coluna de texto que impeca o ALTER. Nao toca em tabela de
   producao (trava na E0). Idempotente. Transacionado. Schema: 'ci'.
   ===================================================================== */

SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @req TABLE (TABELA SYSNAME, COLUNA SYSNAME, TAM_NECESSARIO INT);
INSERT INTO @req (TABELA, COLUNA, TAM_NECESSARIO) VALUES
    (N'KZN_HIST_PEDRAVISAOCONSOLIDADA', N'NM_KAIZEN', 209),
    (N'KZN_HIST_PEDRAVISAOCONSOLIDADA', N'DS_PROBLEMA', 1260),
    (N'KZN_HIST_PEDRAVISAOCONSOLIDADA', N'DS_OBJETIVO', 785),
    (N'KZN_HIST_PEDRAVISAOCONSOLIDADA', N'URL_IMG_ANTES', 34),
    (N'KZN_HIST_PEDRAVISAOCONSOLIDADA', N'DS_ESTADO_ANTES', 1361),
    (N'KZN_HIST_PEDRAVISAOCONSOLIDADA', N'URL_IMG_DEPOIS', 35),
    (N'KZN_HIST_PEDRAVISAOCONSOLIDADA', N'DS_ESTADO_DEPOIS', 1238),
    (N'KZN_HIST_PEDRAVISAOCONSOLIDADA', N'URL_REFERENCIA', 254),
    (N'KZN_HIST_PEDRAVISAOCONSOLIDADA', N'DS_COMPARA_META', 1000),
    (N'KZN_HIST_PEDRAVISAOCONSOLIDADA', N'DS_LICOES_APRENDIDAS', 1000),
    (N'KZN_HIST_PEDRAVISAOCONSOLIDADA', N'DS_RESULTADO_ALCANCADO', 1000),
    (N'KZN_HIST_KAIZEN_HIERARQUIA', N'NM_HIERARQUIA_N1', 35),
    (N'KZN_HIST_KAIZEN_HIERARQUIA', N'NM_HIERARQUIA_N2', 38),
    (N'KZN_HIST_KAIZEN_HIERARQUIA', N'NM_HIERARQUIA_N3', 56),
    (N'KZN_HIST_KAIZEN_HIERARQUIA', N'NM_HIERARQUIA_N4', 63),
    (N'KZN_HIST_KAIZEN_HIERARQUIA', N'NM_HIERARQUIA_N5', 86),
    (N'KZN_HIST_KAIZEN_HIERARQUIA', N'NM_HIERARQUIA_N6', 76),
    (N'KZN_HIST_KAIZEN_HIERARQUIA', N'NM_HIERARQUIA_N7', 88),
    (N'KZN_HIST_KAIZEN_HIERARQUIA', N'NM_HIERARQUIA_N8', 71);

/* =====================================================================
   E0 - TRAVA: so tabelas KZN_HIST_
   ===================================================================== */
IF EXISTS (SELECT 1 FROM @req WHERE TABELA NOT LIKE N'KZN[_]HIST[_]%')
BEGIN
    RAISERROR('Abortado: a lista contem tabela fora de KZN_HIST_*.', 16, 1);
    RETURN;
END

/* =====================================================================
   E1 - O QUE SERA ALTERADO
   max_length vem em BYTES: NVARCHAR gasta 2 por caractere.
   ===================================================================== */
DECLARE @alvo TABLE (ORDEM INT IDENTITY(1,1), TABELA SYSNAME, COLUNA SYSNAME,
                     TIPO SYSNAME, NULO BIT, TAM_ATUAL INT, TAM_NECESSARIO INT);

INSERT INTO @alvo (TABELA, COLUNA, TIPO, NULO, TAM_ATUAL, TAM_NECESSARIO)
SELECT  r.TABELA, c.name, ty.name, c.is_nullable,
        c.max_length / CASE WHEN ty.name IN ('nvarchar','nchar') THEN 2 ELSE 1 END,
        r.TAM_NECESSARIO
FROM    @req r
JOIN    sys.columns c ON c.object_id = OBJECT_ID('CI.' + r.TABELA)
                     AND c.name COLLATE DATABASE_DEFAULT = r.COLUNA COLLATE DATABASE_DEFAULT
JOIN    sys.types ty ON ty.user_type_id = c.user_type_id
WHERE   c.max_length <> -1
  AND   c.max_length / CASE WHEN ty.name IN ('nvarchar','nchar') THEN 2 ELSE 1 END < r.TAM_NECESSARIO
ORDER BY r.TABELA, c.column_id;

SELECT TABELA, COLUNA, TIPO, TAM_ATUAL, TAM_NECESSARIO,
       NOVO = UPPER(TIPO) + '(MAX) ' + CASE WHEN NULO = 1 THEN 'NULL' ELSE 'NOT NULL' END
FROM   @alvo ORDER BY ORDEM;

IF NOT EXISTS (SELECT 1 FROM @alvo)
BEGIN
    PRINT 'Nada a fazer - todas as colunas ja comportam o dado da carga.';
    RETURN;
END

/* Sem GO ate o fim: RAISERROR + RETURN so encerram o batch em que
   aparecem. */

/* =====================================================================
   E2 - ALTERACAO
   ===================================================================== */
DECLARE @i INT = 1, @n INT, @sql NVARCHAR(MAX), @tab SYSNAME, @col SYSNAME,
        @tipo SYSNAME, @nulo BIT;
SELECT @n = MAX(ORDEM) FROM @alvo;

BEGIN TRANSACTION;
BEGIN TRY
    WHILE @i <= @n
    BEGIN
        SELECT @tab = TABELA, @col = COLUNA, @tipo = TIPO, @nulo = NULO FROM @alvo WHERE ORDEM = @i;

        /* nomes vem do catalogo, nao de entrada externa; QUOTENAME mesmo assim */
        SET @sql = N'ALTER TABLE CI.' + QUOTENAME(@tab) + N' ALTER COLUMN ' + QUOTENAME(@col) + N' '
                 + CASE WHEN @tipo IN ('nvarchar','nchar') THEN N'NVARCHAR(MAX)' ELSE N'VARCHAR(MAX)' END
                 + CASE WHEN @nulo = 1 THEN N' NULL;' ELSE N' NOT NULL;' END;
        EXEC sp_executesql @sql;
        PRINT '  CI.' + @tab + '.' + @col + ' -> ' + UPPER(@tipo) + '(MAX)';

        SET @i += 1;
    END

    COMMIT TRANSACTION;
    PRINT 'Ampliacao concluida. Rode carga_hist_importe_7281_12267.sql.';
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    PRINT 'ERRO - nada foi alterado (rollback aplicado): ' + ERROR_MESSAGE();
    THROW;
END CATCH
GO
