/* =====================================================================
   AJUSTAR CI.KZN_MDM_HIERARQUIA NO BDIBPBMSA_DEV À ESTRUTURA DA PRD
   (executar conectado ao BDIBPBMSA_DEV)
   ---------------------------------------------------------------------
   Na PRD (conferido no SSMS em 30/09/2026) cinco colunas são maiores ou
   aceitam NULL; no DEV estão como no repositório. Sem este ajuste o
   merge (merge_kzn_mdm_hierarquia_prd_dev.sql) bloqueia, porque o dado
   da PRD poderia não caber.

       Coluna        DEV (antes)               PRD / DEV (depois)
       NM_USUARIO    varchar(30)  NOT NULL  -> varchar(80)  NULL
       CD_EMAIL      varchar(100) NOT NULL  -> varchar(100) NULL
       NM_SITUACAO   varchar(30)  NULL      -> varchar(80)  NULL
       NM_POSICAO    varchar(30)  NULL      -> varchar(80)  NULL
       NM_EMPRESA    varchar(30)  NULL      -> varchar(80)  NULL

   Só aumenta tamanho e libera NULL: nenhum dado muda, nenhuma
   constraint, índice ou FK é removido (nenhuma dessas colunas é chave;
   IX_KZN_MDM_HIERARQUIA_EMAIL em CD_EMAIL continua como está). A
   collation atual de cada coluna é mantida. Tudo numa transação.
   Idempotente: coluna que já está como a PRD não é tocada.

   REVERSÃO: @REVERTER = 1 volta ao estado anterior — só se os dados
   couberem (nenhum NULL em NM_USUARIO/CD_EMAIL e nenhum valor maior que
   30 nas outras); senão aborta listando o que impede, sem alterar nada.
   Voltar CD_EMAIL a NOT NULL exige recriar IX_KZN_MDM_HIERARQUIA_EMAIL:
   o script faz isso com a mesma definição, na mesma transação.
   ===================================================================== */

SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @REVERTER BIT = 0;   -- 1 = volta à estrutura anterior (a do repositório)

IF DB_NAME() = N'BDIBPBMSA_PRD'
BEGIN
    RAISERROR('Abortado: este ajuste é para o BDIBPBMSA_DEV. A PRD já está assim.', 16, 1);
    RETURN;
END
IF OBJECT_ID(N'CI.KZN_MDM_HIERARQUIA', N'U') IS NULL
BEGIN
    RAISERROR('Abortado: CI.KZN_MDM_HIERARQUIA não existe neste banco.', 16, 1);
    RETURN;
END

DECLARE @ALVO TABLE (COLUNA SYSNAME PRIMARY KEY, TAM_PRD INT, NULO_PRD BIT, TAM_ANTES INT, NULO_ANTES BIT);
INSERT @ALVO VALUES
    (N'NM_USUARIO',   80, 1,  30, 0),
    (N'CD_EMAIL',    100, 1, 100, 0),
    (N'NM_SITUACAO',  80, 1,  30, 1),
    (N'NM_POSICAO',   80, 1,  30, 1),
    (N'NM_EMPRESA',   80, 1,  30, 1);

DECLARE @ATUAL TABLE (COLUNA SYSNAME, TIPO SYSNAME, TAM INT, NULO BIT, COLL SYSNAME NULL);
INSERT @ATUAL
SELECT c.name, TYPE_NAME(c.user_type_id), c.max_length, c.is_nullable, c.collation_name
FROM sys.columns c WHERE c.object_id = OBJECT_ID(N'CI.KZN_MDM_HIERARQUIA');

/* Plano: tamanho e nulidade de destino conforme o modo */
DECLARE @PLANO TABLE (COLUNA SYSNAME, TIPO SYSNAME NULL, TAM_ATUAL INT NULL, NULO_ATUAL BIT NULL, COLL SYSNAME NULL,
                      TAM_NOVO INT, NULO_NOVO BIT, PROBLEMA NVARCHAR(300) NULL);
INSERT @PLANO (COLUNA, TIPO, TAM_ATUAL, NULO_ATUAL, COLL, TAM_NOVO, NULO_NOVO)
SELECT a.COLUNA, t.TIPO, t.TAM, t.NULO, t.COLL,
       CASE WHEN @REVERTER = 1 THEN a.TAM_ANTES ELSE a.TAM_PRD END,
       CASE WHEN @REVERTER = 1 THEN a.NULO_ANTES ELSE a.NULO_PRD END
FROM @ALVO a LEFT JOIN @ATUAL t ON t.COLUNA = a.COLUNA;

/* ── Validação prévia ───────────────────────────────────────────────── */
UPDATE @PLANO SET PROBLEMA = N'coluna não existe no DEV' WHERE TIPO IS NULL;
UPDATE @PLANO SET PROBLEMA = N'tipo ' + TIPO + N' (esperado varchar) — estrutura diferente da conhecida' WHERE PROBLEMA IS NULL AND TIPO <> N'varchar';
UPDATE @PLANO SET PROBLEMA = N'já é maior (' + CAST(TAM_ATUAL AS NVARCHAR(10)) + N') que o destino — não será reduzida'
WHERE PROBLEMA IS NULL AND @REVERTER = 0 AND (TAM_ATUAL = -1 OR TAM_ATUAL > TAM_NOVO);

IF @REVERTER = 1
BEGIN
    -- os dados atuais precisam caber no estado anterior
    DECLARE @col SYSNAME, @tam INT, @nulo BIT, @sql NVARCHAR(MAX), @qtNulos BIGINT, @qtGrandes BIGINT;
    DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT COLUNA, TAM_NOVO, NULO_NOVO FROM @PLANO WHERE PROBLEMA IS NULL;
    OPEN c;
    FETCH NEXT FROM c INTO @col, @tam, @nulo;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @sql = N'SELECT @n = SUM(CASE WHEN ' + QUOTENAME(@col) + N' IS NULL THEN 1 ELSE 0 END),
                            @g = SUM(CASE WHEN DATALENGTH(' + QUOTENAME(@col) + N') > @tam THEN 1 ELSE 0 END)
                     FROM CI.KZN_MDM_HIERARQUIA WITH (HOLDLOCK);';
        EXEC sp_executesql @sql, N'@tam INT, @n BIGINT OUTPUT, @g BIGINT OUTPUT', @tam = @tam, @n = @qtNulos OUTPUT, @g = @qtGrandes OUTPUT;
        UPDATE @PLANO SET PROBLEMA = CONCAT_WS(N'; ',
                    CASE WHEN @nulo = 0 AND @qtNulos > 0 THEN CAST(@qtNulos AS NVARCHAR(20)) + N' linha(s) com NULL' END,
                    CASE WHEN @qtGrandes > 0 THEN CAST(@qtGrandes AS NVARCHAR(20)) + N' linha(s) com mais de ' + CAST(@tam AS NVARCHAR(10)) + N' caracteres' END)
        WHERE COLUNA = @col;
        UPDATE @PLANO SET PROBLEMA = NULL WHERE COLUNA = @col AND PROBLEMA = N'';
        FETCH NEXT FROM c INTO @col, @tam, @nulo;
    END
    CLOSE c; DEALLOCATE c;
END

IF EXISTS (SELECT 1 FROM @PLANO WHERE PROBLEMA IS NOT NULL)
BEGIN
    SELECT COLUNA, ATUAL = CONCAT(TIPO, N'(', TAM_ATUAL, N') ', CASE WHEN NULO_ATUAL = 1 THEN N'NULL' ELSE N'NOT NULL' END),
           DESTINO = CONCAT(N'varchar(', TAM_NOVO, N') ', CASE WHEN NULO_NOVO = 1 THEN N'NULL' ELSE N'NOT NULL' END), PROBLEMA
    FROM @PLANO WHERE PROBLEMA IS NOT NULL;
    DECLARE @msg NVARCHAR(2000);
    SELECT @msg = N'Abortado, nada foi alterado: ' + STRING_AGG(CONVERT(NVARCHAR(MAX), COLUNA + N' — ' + PROBLEMA), N'; ')
    FROM @PLANO WHERE PROBLEMA IS NOT NULL;
    RAISERROR(N'%s', 16, 1, @msg);
    RETURN;
END

/* ── Alteração ──────────────────────────────────────────────────────── */
DECLARE @alter NVARCHAR(MAX);
SELECT @alter = STRING_AGG(CONVERT(NVARCHAR(MAX),
           N'ALTER TABLE CI.KZN_MDM_HIERARQUIA ALTER COLUMN ' + QUOTENAME(COLUNA) + N' varchar(' + CAST(TAM_NOVO AS NVARCHAR(10)) + N')'
         + ISNULL(N' COLLATE ' + COLL, N'') + CASE WHEN NULO_NOVO = 1 THEN N' NULL;' ELSE N' NOT NULL;' END), NCHAR(10))
FROM @PLANO WHERE TAM_ATUAL <> TAM_NOVO OR NULO_ATUAL <> NULO_NOVO;

/* NULL -> NOT NULL (só na reversão) não é aceito com a coluna em índice:
   o índice é removido e recriado com a mesma definição, na mesma transação. */
DECLARE @dropIx NVARCHAR(MAX), @criaIx NVARCHAR(MAX);
SELECT @dropIx = STRING_AGG(CONVERT(NVARCHAR(MAX), N'DROP INDEX ' + QUOTENAME(i.name) + N' ON CI.KZN_MDM_HIERARQUIA;'), NCHAR(10)),
       @criaIx = STRING_AGG(CONVERT(NVARCHAR(MAX),
           N'CREATE ' + CASE WHEN i.is_unique = 1 THEN N'UNIQUE ' ELSE N'' END + i.type_desc COLLATE DATABASE_DEFAULT
         + N' INDEX ' + QUOTENAME(i.name) + N' ON CI.KZN_MDM_HIERARQUIA (' + k.CHAVE + N')'
         + ISNULL(N' INCLUDE (' + inc.INCL + N')', N'') + ISNULL(N' WHERE ' + i.filter_definition COLLATE DATABASE_DEFAULT, N'')
         + N' WITH (PAD_INDEX = ' + CASE WHEN i.is_padded = 1 THEN N'ON' ELSE N'OFF' END
         + CASE WHEN i.fill_factor > 0 THEN N', FILLFACTOR = ' + CAST(i.fill_factor AS NVARCHAR(3)) ELSE N'' END
         + N', IGNORE_DUP_KEY = ' + CASE WHEN i.ignore_dup_key = 1 THEN N'ON' ELSE N'OFF' END
         + N', ALLOW_ROW_LOCKS = ' + CASE WHEN i.allow_row_locks = 1 THEN N'ON' ELSE N'OFF' END
         + N', ALLOW_PAGE_LOCKS = ' + CASE WHEN i.allow_page_locks = 1 THEN N'ON' ELSE N'OFF' END
         + N', DATA_COMPRESSION = ' + pt.data_compression_desc COLLATE DATABASE_DEFAULT + N');'), NCHAR(10))
FROM sys.indexes i
CROSS APPLY (SELECT CHAVE = STRING_AGG(CONVERT(NVARCHAR(MAX), QUOTENAME(c.name) + CASE WHEN ic.is_descending_key = 1 THEN N' DESC' ELSE N' ASC' END), N', ')
                            WITHIN GROUP (ORDER BY ic.key_ordinal)
             FROM sys.index_columns ic JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
             WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.key_ordinal > 0) k
OUTER APPLY (SELECT INCL = STRING_AGG(CONVERT(NVARCHAR(MAX), QUOTENAME(c.name)), N', ')
             FROM sys.index_columns ic JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
             WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.is_included_column = 1) inc
CROSS APPLY (SELECT TOP (1) data_compression_desc FROM sys.partitions WHERE object_id = i.object_id AND index_id = i.index_id) pt
WHERE i.object_id = OBJECT_ID(N'CI.KZN_MDM_HIERARQUIA') AND i.type = 2 AND i.is_primary_key = 0 AND i.is_unique_constraint = 0
  AND EXISTS (SELECT 1 FROM sys.index_columns ic JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
              JOIN @PLANO p ON p.COLUNA = c.name COLLATE DATABASE_DEFAULT
              WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id AND p.NULO_ATUAL = 1 AND p.NULO_NOVO = 0);
IF @alter IS NOT NULL AND @dropIx IS NOT NULL
    SET @alter = @dropIx + NCHAR(10) + @alter + NCHAR(10) + @criaIx;

IF @alter IS NULL
    PRINT N'Nada a fazer: as colunas já estão como ' + CASE WHEN @REVERTER = 1 THEN N'antes do ajuste.' ELSE N'na PRD.' END;
ELSE
BEGIN
    BEGIN TRY
        BEGIN TRANSACTION;
        EXEC sp_executesql @alter;
        -- conferência antes de confirmar
        IF EXISTS (SELECT 1 FROM @PLANO p JOIN sys.columns c ON c.object_id = OBJECT_ID(N'CI.KZN_MDM_HIERARQUIA') AND c.name COLLATE DATABASE_DEFAULT = p.COLUNA
                   WHERE c.max_length <> p.TAM_NOVO OR c.is_nullable <> p.NULO_NOVO)
            THROW 50001, N'Conferência falhou: a estrutura final não é a esperada.', 1;
        IF @criaIx IS NOT NULL AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'CI.KZN_MDM_HIERARQUIA') AND name = N'IX_KZN_MDM_HIERARQUIA_EMAIL')
            THROW 50002, N'Conferência falhou: índice não foi recriado.', 1;
        COMMIT TRANSACTION;
        PRINT N'Ajuste aplicado' + CASE WHEN @REVERTER = 1 THEN N' (reversão).' ELSE N'.' END;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        DECLARE @e NVARCHAR(2000) = N'Falha, nada foi alterado (ROLLBACK): ' + ERROR_MESSAGE();
        RAISERROR(N'%s', 16, 1, @e);
        RETURN;
    END CATCH
END

SELECT p.COLUNA,
       ANTES  = CONCAT(N'varchar(', p.TAM_ATUAL, N') ', CASE WHEN p.NULO_ATUAL = 1 THEN N'NULL' ELSE N'NOT NULL' END),
       AGORA  = CONCAT(TYPE_NAME(c.user_type_id), N'(', c.max_length, N') ', CASE WHEN c.is_nullable = 1 THEN N'NULL' ELSE N'NOT NULL' END),
       COLLATION_MANTIDA = c.collation_name
FROM @PLANO p JOIN sys.columns c ON c.object_id = OBJECT_ID(N'CI.KZN_MDM_HIERARQUIA') AND c.name COLLATE DATABASE_DEFAULT = p.COLUNA
ORDER BY c.column_id;
GO
