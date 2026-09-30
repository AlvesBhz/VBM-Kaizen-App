/* =====================================================================
   02 - CRIAR ESTRUTURA  (conectado ao BDIBPBMSA_DEV)
   ---------------------------------------------------------------------
   Gera o DDL a partir do catálogo da PRD capturado no 01 e cria, numa
   transação única: schema CI, sequences e tabelas (colunas, tipos,
   collation, identity, colunas calculadas, defaults nomeados, PK e
   UNIQUE com as mesmas opções). Índices, CHECKs, FKs, módulos e
   triggers ficam para o 04, depois da carga: FK criada WITH CHECK sobre
   os dados carregados é a prova de integridade, e trigger inexistente
   durante a carga não grava log falso.

   Com @RECRIAR = 1 (00), apaga ANTES os objetos CI que já existirem no
   DEV. Reversão: restauração point-in-time do BDIBPBMSA_DEV no Azure
   para o instante anterior à execução.
   ===================================================================== */

SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @ini INT = ISNULL((SELECT MAX(ID) FROM MIG.EVIDENCIA), 0);
DECLARE @recriar BIT = (SELECT RECRIAR FROM MIG.PARAMETRO);
DECLARE @sql NVARCHAR(MAX), @nome SYSNAME, @n INT, @d NVARCHAR(MAX);

/* ── Trava: última pré-checagem sem FALHA ─────────────────────────── */
DECLARE @ult01 INT = (SELECT MAX(ID) FROM MIG.EVIDENCIA WHERE ETAPA = '01' AND ITEM = N'Collation e nível de compatibilidade');
IF @ult01 IS NULL
BEGIN
    RAISERROR('Abortado: rode o 01 antes.', 16, 1);
    RETURN;
END
IF EXISTS (SELECT 1 FROM MIG.EVIDENCIA WHERE ETAPA = '01' AND ID >= @ult01 AND RESULTADO = 'FALHA')
BEGIN
    SELECT RESULTADO, ITEM, DETALHE FROM MIG.EVIDENCIA WHERE ETAPA = '01' AND ID >= @ult01 AND RESULTADO = 'FALHA';
    RAISERROR('Abortado: a última pré-checagem (01) tem FALHA (lista acima).', 16, 1);
    RETURN;
END

/* O DEV pode ter mudado desde o 01: recaptura só o DEV. */
EXEC MIG.SP_SNAPSHOT 'DEV';
IF @recriar = 0 AND (EXISTS (SELECT 1 FROM MIG.CAT_TABELA WHERE ORIGEM = 'DEV')
                  OR EXISTS (SELECT 1 FROM MIG.CAT_MODULO WHERE ORIGEM = 'DEV')
                  OR EXISTS (SELECT 1 FROM MIG.CAT_SEQUENCIA WHERE ORIGEM = 'DEV')
                  OR EXISTS (SELECT 1 FROM MIG.CAT_SINONIMO WHERE ORIGEM = 'DEV'))
BEGIN
    RAISERROR('Abortado: já existem objetos CI no DEV e @RECRIAR = 0.', 16, 1);
    RETURN;
END

BEGIN TRANSACTION;
BEGIN TRY

    /* ── Apagar o CI do DEV (@RECRIAR = 1) ────────────────────────────── */
    IF @recriar = 1 AND SCHEMA_ID('CI') IS NOT NULL
    BEGIN
        SELECT @sql = STRING_AGG(CONVERT(NVARCHAR(MAX), N'ALTER TABLE CI.' + QUOTENAME(OBJECT_NAME(fk.parent_object_id))
                      + N' DROP CONSTRAINT ' + QUOTENAME(fk.name) + N';'), NCHAR(10))
        FROM sys.foreign_keys fk WHERE OBJECT_SCHEMA_NAME(fk.parent_object_id) = N'CI';
        IF @sql IS NOT NULL EXEC sp_executesql @sql;

        /* Módulos e sinônimos em passadas: um SCHEMABINDING só sai depois
           de quem depende dele. */
        DECLARE @restam INT = 1, @antes INT = -1;
        WHILE @restam > 0 AND @restam <> @antes
        BEGIN
            SET @antes = @restam;
            DECLARE c CURSOR LOCAL FAST_FORWARD FOR
                SELECT N'DROP ' + CASE o.type WHEN 'V' THEN N'VIEW' WHEN 'P' THEN N'PROCEDURE' WHEN 'SN' THEN N'SYNONYM'
                                  ELSE N'FUNCTION' END + N' CI.' + QUOTENAME(o.name) + N';'
                FROM sys.objects o WHERE o.schema_id = SCHEMA_ID('CI') AND o.type IN ('V','P','FN','IF','TF','SN');
            OPEN c;
            FETCH NEXT FROM c INTO @sql;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                BEGIN TRY EXEC sp_executesql @sql; END TRY BEGIN CATCH END CATCH;
                FETCH NEXT FROM c INTO @sql;
            END
            CLOSE c; DEALLOCATE c;
            SELECT @restam = COUNT(*) FROM sys.objects WHERE schema_id = SCHEMA_ID('CI') AND type IN ('V','P','FN','IF','TF','SN');
        END
        IF @restam > 0 RAISERROR('Abortado: módulos CI do DEV não puderam ser apagados (dependência fora do CI).', 16, 1);

        SELECT @sql = STRING_AGG(CONVERT(NVARCHAR(MAX), N'DROP TABLE CI.' + QUOTENAME(name) + N';'), NCHAR(10))
        FROM sys.tables WHERE schema_id = SCHEMA_ID('CI');
        IF @sql IS NOT NULL EXEC sp_executesql @sql;
        SELECT @sql = STRING_AGG(CONVERT(NVARCHAR(MAX), N'DROP SEQUENCE CI.' + QUOTENAME(name) + N';'), NCHAR(10))
        FROM sys.sequences WHERE schema_id = SCHEMA_ID('CI');
        IF @sql IS NOT NULL EXEC sp_executesql @sql;

        EXEC MIG.SP_EVIDENCIA '02', N'Objetos CI pré-existentes no DEV apagados (@RECRIAR = 1)', 'AVISO', NULL;
    END

    IF SCHEMA_ID('CI') IS NULL EXEC (N'CREATE SCHEMA CI AUTHORIZATION dbo;');

    /* ── Sequences (antes das tabelas: DEFAULT pode usar NEXT VALUE FOR) ─ */
    DECLARE c CURSOR LOCAL FAST_FORWARD FOR
        SELECT N'CREATE SEQUENCE CI.' + QUOTENAME(NOME) + N' AS ' + TIPO + N' START WITH ' + INICIO + N' INCREMENT BY ' + INCREMENTO
             + N' MINVALUE ' + MINIMO + N' MAXVALUE ' + MAXIMO + CASE WHEN CICLO = 1 THEN N' CYCLE' ELSE N' NO CYCLE' END
             + CASE WHEN CACHE_ = N'NO CACHE' THEN N' NO CACHE' WHEN CACHE_ = N'DEFAULT' THEN N' CACHE' ELSE N' CACHE ' + CACHE_ END + N';'
             /* Avança até o próximo valor da PRD consumindo o intervalo
                (sp_sequence_get_range): RESTART WITH trocaria o START WITH
                gravado na sequence, e ela deixaria de ser idêntica. */
             + CASE WHEN PROXIMO <> INICIO
                    THEN N' DECLARE @primeiro SQL_VARIANT; EXEC sp_sequence_get_range @sequence_name = N''CI.'
                         + REPLACE(QUOTENAME(NOME), N'''', N'''''') + N''', @range_size = '
                         + CAST((CAST(PROXIMO AS DECIMAL(38,0)) - CAST(INICIO AS DECIMAL(38,0)))
                                / CAST(INCREMENTO AS DECIMAL(38,0)) AS NVARCHAR(40)) + N', @range_first_value = @primeiro OUTPUT;'
                    ELSE N'' END
        FROM MIG.CAT_SEQUENCIA WHERE ORIGEM = 'PRD';
    OPEN c;
    FETCH NEXT FROM c INTO @sql;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        EXEC sp_executesql @sql;
        FETCH NEXT FROM c INTO @sql;
    END
    CLOSE c; DEALLOCATE c;

    /* ── Tabelas ──────────────────────────────────────────────────────── */
    DECLARE t CURSOR LOCAL FAST_FORWARD FOR
        SELECT TABELA FROM MIG.CAT_TABELA WHERE ORIGEM = 'PRD' ORDER BY TABELA;
    OPEN t;
    FETCH NEXT FROM t INTO @nome;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SELECT @sql = N'CREATE TABLE CI.' + QUOTENAME(@nome) + N' (' + NCHAR(10) + N'    '
            + STRING_AGG(CONVERT(NVARCHAR(MAX),
                QUOTENAME(c.COLUNA) + N' ' +
                CASE WHEN c.CALCULADA = 1
                     THEN N'AS ' + c.DEF_CALCULADA
                          + CASE WHEN c.PERSISTIDA = 1 THEN N' PERSISTED' + CASE WHEN c.NULO = 0 THEN N' NOT NULL' ELSE N'' END ELSE N'' END
                     ELSE c.TIPO
                          + ISNULL(N' COLLATE ' + c.COLLATION_, N'')
                          + CASE WHEN c.ESPARSA = 1 THEN N' SPARSE' ELSE N'' END
                          + ISNULL(N' MASKED WITH (FUNCTION = N''' + REPLACE(c.MASCARA, N'''', N'''''') + N''')', N'')
                          + ISNULL(N' CONSTRAINT ' + QUOTENAME(c.NM_DEFAULT) + N' DEFAULT ' + c.DEF_DEFAULT, N'')
                          + CASE WHEN c.IDENTIDADE = 1
                                 THEN N' IDENTITY(' + c.SEMENTE + N', ' + c.INCREMENTO + N')'
                                      + CASE WHEN c.IDENT_NFR = 1 THEN N' NOT FOR REPLICATION' ELSE N'' END
                                 ELSE N'' END
                          + CASE WHEN c.ROWGUIDCOL_ = 1 THEN N' ROWGUIDCOL' ELSE N'' END
                          + CASE WHEN c.NULO = 1 THEN N' NULL' ELSE N' NOT NULL' END
                END), N',' + NCHAR(10) + N'    ') WITHIN GROUP (ORDER BY c.ORDEM)
        FROM MIG.CAT_COLUNA c WHERE c.ORIGEM = 'PRD' AND c.TABELA = @nome;

        SELECT @sql += ISNULL(N',' + NCHAR(10) + N'    ' + STRING_AGG(CONVERT(NVARCHAR(MAX),
                N'CONSTRAINT ' + QUOTENAME(k.NOME) + CASE k.TIPO WHEN 'PK' THEN N' PRIMARY KEY ' ELSE N' UNIQUE ' END
                + k.AGRUPAMENTO + N' (' + k.COLUNAS + N') WITH (' + k.OPCOES + N')'), N',' + NCHAR(10) + N'    ')
                WITHIN GROUP (ORDER BY CASE k.TIPO WHEN 'PK' THEN 0 ELSE 1 END, k.NOME), N'')
        FROM MIG.CAT_CHAVE k WHERE k.ORIGEM = 'PRD' AND k.TABELA = @nome;

        SELECT @sql += NCHAR(10) + N')'
            + CASE WHEN tb.COMPRESSAO_HEAP IS NOT NULL AND tb.COMPRESSAO_HEAP <> N'NONE'
                   THEN N' WITH (DATA_COMPRESSION = ' + tb.COMPRESSAO_HEAP + N')' ELSE N'' END + N';'
            + CASE WHEN tb.ESCALONAMENTO <> N'TABLE'
                   THEN NCHAR(10) + N'ALTER TABLE CI.' + QUOTENAME(@nome) + N' SET (LOCK_ESCALATION = ' + tb.ESCALONAMENTO + N');'
                   ELSE N'' END
        FROM MIG.CAT_TABELA tb WHERE tb.ORIGEM = 'PRD' AND tb.TABELA = @nome;

        EXEC sp_executesql @sql;
        FETCH NEXT FROM t INTO @nome;
    END
    CLOSE t; DEALLOCATE t;

    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    SET @d = N'Objeto: ' + ISNULL(@nome, N'-') + N' | ' + ERROR_MESSAGE() + N' | DDL: ' + ISNULL(LEFT(@sql, 3000), N'');
    EXEC MIG.SP_EVIDENCIA '02', N'Criação da estrutura', 'FALHA', @d;
    THROW;
END CATCH

SELECT @n = COUNT(*) FROM sys.tables WHERE schema_id = SCHEMA_ID('CI');
SET @d = CAST(@n AS NVARCHAR(10)) + N' tabela(s), '
       + CAST((SELECT COUNT(*) FROM sys.sequences WHERE schema_id = SCHEMA_ID('CI')) AS NVARCHAR(10)) + N' sequence(s), '
       + CAST((SELECT COUNT(*) FROM sys.key_constraints k JOIN sys.tables tb ON tb.object_id = k.parent_object_id
               WHERE tb.schema_id = SCHEMA_ID('CI')) AS NVARCHAR(10)) + N' PK/UNIQUE, '
       + CAST((SELECT COUNT(*) FROM sys.default_constraints dc JOIN sys.tables tb ON tb.object_id = dc.parent_object_id
               WHERE tb.schema_id = SCHEMA_ID('CI')) AS NVARCHAR(10)) + N' default(s).';
EXEC MIG.SP_EVIDENCIA '02', N'Estrutura criada', 'OK', @d;

SELECT ETAPA, RESULTADO, ITEM, DETALHE FROM MIG.EVIDENCIA WHERE ID > @ini ORDER BY ID;
GO
