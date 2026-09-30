/* =====================================================================
   03 - CARGA DOS DADOS  (conectado ao BDIBPBMSA_DEV)
   ---------------------------------------------------------------------
   Copia todas as linhas de cada tabela CI da PRD para o DEV, na ordem
   de MIG.ORDEM_CARGA (dependências de FK, calculada no 01). Uma
   transação por tabela; para na primeira falha, com o erro no log.

   Leitura da PRD: EXTERNAL TABLE (Elastic Query) em MIG_EXT, uma por
   tabela. Identity preservado (IDENTITY_INSERT). Colunas calculadas e
   rowversion não são copiadas: o DEV as calcula/gera.

   Ainda NÃO há FKs, CHECKs nem triggers no DEV (entram no 04): a carga
   não dispara os triggers de log e o ciclo de FKs não bloqueia.

   Rodar só entre o 02 e o 04. Para repetir: @RECARREGAR = 1 (esvazia as
   tabelas CI do DEV antes; recusa se o 04 já criou as FKs).
   ===================================================================== */

SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @RECARREGAR BIT = 0;

DECLARE @ini INT = ISNULL((SELECT MAX(ID) FROM MIG.EVIDENCIA), 0);
DECLARE @modo VARCHAR(10), @ds SYSNAME, @banco SYSNAME;
SELECT @modo = MODO, @ds = FONTE_DADOS, @banco = BANCO_ORIGEM FROM MIG.PARAMETRO;
DECLARE @tab SYSNAME, @nivel INT, @ordem INT, @sql NVARCHAR(MAX), @colsExt NVARCHAR(MAX), @colsCarga NVARCHAR(MAX),
        @ident BIT, @qt BIGINT, @inicio DATETIME2(3), @d NVARCHAR(MAX);

/* ── Travas ────────────────────────────────────────────────────────── */
IF EXISTS (SELECT 1 FROM MIG.CAT_TABELA p WHERE p.ORIGEM = 'PRD' AND OBJECT_ID(N'CI.' + QUOTENAME(p.TABELA), 'U') IS NULL)
BEGIN
    RAISERROR('Abortado: há tabela da PRD ainda não criada no DEV. Rode o 02.', 16, 1);
    RETURN;
END
IF NOT EXISTS (SELECT 1 FROM MIG.ORDEM_CARGA)
BEGIN
    RAISERROR('Abortado: MIG.ORDEM_CARGA vazia. Rode o 01.', 16, 1);
    RETURN;
END
IF EXISTS (SELECT 1 FROM sys.foreign_keys WHERE OBJECT_SCHEMA_NAME(parent_object_id) = N'CI')
BEGIN
    RAISERROR('Abortado: o 04 já criou FKs no CI do DEV. Para recarregar, refaça a partir do 02 com @RECRIAR = 1.', 16, 1);
    RETURN;
END
IF EXISTS (SELECT 1 FROM sys.partitions p JOIN sys.tables t ON t.object_id = p.object_id
           WHERE t.schema_id = SCHEMA_ID('CI') AND p.index_id IN (0,1) AND p.rows > 0)
BEGIN
    IF @RECARREGAR = 0
    BEGIN
        RAISERROR('Abortado: já há dados no CI do DEV. Para recarregar, troque @RECARREGAR para 1.', 16, 1);
        RETURN;
    END
    SELECT @sql = STRING_AGG(CONVERT(NVARCHAR(MAX), N'TRUNCATE TABLE CI.' + QUOTENAME(name) + N';'), NCHAR(10))
    FROM sys.tables WHERE schema_id = SCHEMA_ID('CI');
    EXEC sp_executesql @sql;
    EXEC MIG.SP_EVIDENCIA '03', N'Tabelas CI do DEV esvaziadas (@RECARREGAR = 1)', 'AVISO', NULL;
END

DELETE MIG.CARGA_LOG;
INSERT MIG.CARGA_LOG (TABELA, NIVEL, ORDEM, STATUS) SELECT TABELA, NIVEL, ORDEM, 'PENDENTE' FROM MIG.ORDEM_CARGA;

/* ── Carga, tabela a tabela ────────────────────────────────────────── */
DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT TABELA, NIVEL, ORDEM FROM MIG.ORDEM_CARGA ORDER BY ORDEM;
OPEN c;
FETCH NEXT FROM c INTO @tab, @nivel, @ordem;
WHILE @@FETCH_STATUS = 0
BEGIN
    /* Fonte: todas as colunas (a calculada com o tipo do resultado;
       rowversion como binary(8)). A carga usa só as graváveis. */
    SELECT @colsExt = STRING_AGG(CONVERT(NVARCHAR(MAX),
               QUOTENAME(COLUNA) + N' ' + CASE WHEN ROWVERSION_ = 1 THEN N'binary(8)' ELSE TIPO END
               + ISNULL(N' COLLATE ' + COLLATION_, N'') + CASE WHEN NULO = 1 THEN N' NULL' ELSE N' NOT NULL' END), N', ')
               WITHIN GROUP (ORDER BY ORDEM),
           @colsCarga = STRING_AGG(CASE WHEN CALCULADA = 0 AND ROWVERSION_ = 0 THEN CONVERT(NVARCHAR(MAX), QUOTENAME(COLUNA)) END, N', ')
               WITHIN GROUP (ORDER BY ORDEM),
           @ident = MAX(CAST(IDENTIDADE AS INT))
    FROM MIG.CAT_COLUNA WHERE ORIGEM = 'PRD' AND TABELA = @tab;

    BEGIN TRY
        IF OBJECT_ID(N'MIG_EXT.' + QUOTENAME(@tab)) IS NOT NULL
        BEGIN
            SET @sql = CASE WHEN @modo = 'AZURE' THEN N'DROP EXTERNAL TABLE ' ELSE N'DROP VIEW ' END + N'MIG_EXT.' + QUOTENAME(@tab) + N';';
            EXEC sp_executesql @sql;
        END
        IF @modo = 'AZURE'
            SET @sql = N'CREATE EXTERNAL TABLE MIG_EXT.' + QUOTENAME(@tab) + N' (' + @colsExt + N') WITH (DATA_SOURCE = '
                     + QUOTENAME(@ds) + N', SCHEMA_NAME = N''CI'', OBJECT_NAME = N''' + REPLACE(@tab, N'''', N'''''') + N''');';
        ELSE
            SET @sql = N'CREATE VIEW MIG_EXT.' + QUOTENAME(@tab) + N' AS SELECT '
                     + (SELECT STRING_AGG(CONVERT(NVARCHAR(MAX), QUOTENAME(COLUNA)), N', ') WITHIN GROUP (ORDER BY ORDEM)
                        FROM MIG.CAT_COLUNA WHERE ORIGEM = 'PRD' AND TABELA = @tab)
                     + N' FROM ' + QUOTENAME(@banco) + N'.CI.' + QUOTENAME(@tab) + N';';
        EXEC sp_executesql @sql;

        SET @inicio = SYSDATETIME();
        UPDATE MIG.CARGA_LOG SET INICIO = @inicio, STATUS = 'CARGA' WHERE TABELA = @tab;

        SET @sql = CASE WHEN @ident = 1 THEN N'SET IDENTITY_INSERT CI.' + QUOTENAME(@tab) + N' ON; ' ELSE N'' END
                 + N'INSERT INTO CI.' + QUOTENAME(@tab) + N' WITH (TABLOCK) (' + @colsCarga + N') SELECT ' + @colsCarga
                 + N' FROM MIG_EXT.' + QUOTENAME(@tab) + N'; SET @qt = @@ROWCOUNT; '
                 + CASE WHEN @ident = 1 THEN N'SET IDENTITY_INSERT CI.' + QUOTENAME(@tab) + N' OFF;' ELSE N'' END;
        BEGIN TRANSACTION;
        EXEC sp_executesql @sql, N'@qt BIGINT OUTPUT', @qt = @qt OUTPUT;
        COMMIT TRANSACTION;

        UPDATE MIG.CARGA_LOG SET LINHAS = @qt, FIM = SYSDATETIME(), STATUS = 'OK' WHERE TABELA = @tab;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        SET @d = ERROR_MESSAGE();
        UPDATE MIG.CARGA_LOG SET FIM = SYSDATETIME(), STATUS = 'FALHA', ERRO = @d WHERE TABELA = @tab;
        SET @d = N'CI.' + @tab + N': ' + @d;
        EXEC MIG.SP_EVIDENCIA '03', N'Carga interrompida', 'FALHA', @d;
        CLOSE c; DEALLOCATE c;
        SELECT ORDEM, NIVEL, TABELA, LINHAS, STATUS, ERRO FROM MIG.CARGA_LOG ORDER BY ORDEM;
        THROW;
    END CATCH

    FETCH NEXT FROM c INTO @tab, @nivel, @ordem;
END
CLOSE c; DEALLOCATE c;

SELECT @d = CAST(COUNT(*) AS NVARCHAR(10)) + N' tabela(s), ' + CAST(SUM(LINHAS) AS NVARCHAR(20)) + N' linha(s) em '
          + CAST(DATEDIFF(SECOND, MIN(INICIO), MAX(FIM)) AS NVARCHAR(10)) + N' s.'
FROM MIG.CARGA_LOG WHERE STATUS = 'OK';
EXEC MIG.SP_EVIDENCIA '03', N'Carga concluída', 'OK', @d;

SELECT ORDEM, NIVEL, TABELA, LINHAS, DURACAO_MS = DATEDIFF(MILLISECOND, INICIO, FIM), STATUS
FROM MIG.CARGA_LOG ORDER BY ORDEM;
SELECT ETAPA, RESULTADO, ITEM, DETALHE FROM MIG.EVIDENCIA WHERE ID > @ini ORDER BY ID;
GO
