/* =====================================================================
   Apaga os dados das tabelas KZN_HIST_*
   ---------------------------------------------------------------------
   Por padrao apaga SO a faixa carregada (7281-12267), nao a tabela toda.
   Para limpar tudo, troque @SOMENTE_FAIXA para 0.

   ORDEM: auxiliares -> principal -> aprovadores. A principal tem FK para
   CI.KZN_HIST_APROVADOR (FK_KZN_HIST_PVC_APROVADOR), entao o aprovador so
   pode sair depois dos Kaizens que o usam. As auxiliares nao tem FK, mas
   saem antes para que uma interrupcao nunca deixe auxiliar apontando
   para Kaizen inexistente.

   APROVADORES nao tem ID_KAIZEN, entao nao ha "faixa" para eles. Com
   @APAGAR_APROVADORES = 1 (padrao) saem os que ficarem SEM NENHUM Kaizen
   depois da exclusao — com @SOMENTE_FAIXA = 0 isso e a tabela toda; com
   a faixa, o aprovador que ainda atende Kaizen de fora dela fica. Com 0,
   a tabela de aprovadores nao e tocada (util se CD_MATRICULA/ID_USUARIO
   ja foram preenchidos a mao). A carga recria os que faltarem (E1c).

   DELETE, nao TRUNCATE: TRUNCATE ignoraria o filtro de faixa e e barrado
   pela FK na tabela de aprovadores.

   Tudo em UMA transacao com contagem previa: erro em qualquer etapa
   desfaz tudo. Schema: 'ci'.
   ===================================================================== */

SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @SOMENTE_FAIXA      BIT = 1;   -- 1 = so 7281-12267 | 0 = todas as linhas
DECLARE @APAGAR_APROVADORES BIT = 1;   -- 1 = remove aprovadores que ficarem sem Kaizen | 0 = nao toca
DECLARE @ID_INI INT = 7281, @ID_FIM INT = 12267;

DECLARE @tabelas TABLE (ORDEM INT PRIMARY KEY, NOME SYSNAME);
INSERT INTO @tabelas (ORDEM, NOME) VALUES
    (1, 'KZN_HIST_KAIZEN_DESPERDICIO'),
    (2, 'KZN_HIST_KAIZEN_HIERARQUIA'),
    (3, 'KZN_HIST_RESULTADO_KAIZEN'),
    (4, 'KZN_HIST_MEMBROS_EQUIPE'),
    (5, 'KZN_HIST_PEDRAVISAOCONSOLIDADA');

DECLARE @i INT = 1, @n INT, @tab SYSNAME, @sql NVARCHAR(MAX), @qt INT, @total INT = 0;
SELECT @n = MAX(ORDEM) FROM @tabelas;

/* Aprovador orfao = nenhum Kaizen da principal o referencia. Na previa
   (E1) conta-se o que ficara orfao DEPOIS da exclusao; na E2/E3, com a
   principal ja limpa, a mesma consulta sem o filtro de faixa. */
DECLARE @sqlOrfaosPrevia NVARCHAR(MAX) = N'
SELECT @c = COUNT(*)
FROM   CI.KZN_HIST_APROVADOR a
WHERE  NOT EXISTS (SELECT 1 FROM CI.KZN_HIST_PEDRAVISAOCONSOLIDADA p
                   WHERE p.ID_APROVADOR = a.ID_APROVADOR
                     AND @f = 1 AND p.ID_KAIZEN NOT BETWEEN @a AND @b);';

DECLARE @sqlOrfaosAgora NVARCHAR(MAX) = N'
SELECT @c = COUNT(*)
FROM   CI.KZN_HIST_APROVADOR a
WHERE  NOT EXISTS (SELECT 1 FROM CI.KZN_HIST_PEDRAVISAOCONSOLIDADA p WHERE p.ID_APROVADOR = a.ID_APROVADOR);';

DECLARE @temAprovador BIT = CASE WHEN @APAGAR_APROVADORES = 1
                                  AND OBJECT_ID('CI.KZN_HIST_APROVADOR', 'U') IS NOT NULL
                                  AND OBJECT_ID('CI.KZN_HIST_PEDRAVISAOCONSOLIDADA', 'U') IS NOT NULL
                                 THEN 1 ELSE 0 END;

/* =====================================================================
   E1 - PREVIA: o que sera apagado
   ===================================================================== */
PRINT CASE WHEN @SOMENTE_FAIXA = 1
           THEN 'Escopo: Kaizens ' + CAST(@ID_INI AS VARCHAR(10)) + '-' + CAST(@ID_FIM AS VARCHAR(10))
           ELSE 'Escopo: TODAS as linhas das tabelas KZN_HIST_*' END;

WHILE @i <= @n
BEGIN
    SELECT @tab = NOME FROM @tabelas WHERE ORDEM = @i;
    IF OBJECT_ID('CI.' + @tab, 'U') IS NULL
        PRINT '  - CI.' + @tab + ': tabela nao existe (sera pulada).';
    ELSE
    BEGIN
        /* SQL dinamico: nome vem da lista fixa acima, nao de entrada externa. */
        SET @sql = N'SELECT @c = COUNT(*) FROM CI.' + QUOTENAME(@tab)
                 + CASE WHEN @SOMENTE_FAIXA = 1 THEN N' WHERE ID_KAIZEN BETWEEN @a AND @b' ELSE N'' END + N';';
        EXEC sp_executesql @sql, N'@a INT, @b INT, @c INT OUTPUT', @a = @ID_INI, @b = @ID_FIM, @c = @qt OUTPUT;
        SET @total += @qt;
        PRINT '  - CI.' + @tab + ': ' + CAST(@qt AS VARCHAR(10)) + ' linha(s).';
    END
    SET @i += 1;
END

IF @temAprovador = 1
BEGIN
    EXEC sp_executesql @sqlOrfaosPrevia, N'@f BIT, @a INT, @b INT, @c INT OUTPUT',
         @f = @SOMENTE_FAIXA, @a = @ID_INI, @b = @ID_FIM, @c = @qt OUTPUT;
    SET @total += @qt;
    PRINT '  - CI.KZN_HIST_APROVADOR: ' + CAST(@qt AS VARCHAR(10)) + ' aprovador(es) sem Kaizen apos a exclusao.';
END
ELSE IF @APAGAR_APROVADORES = 0
    PRINT '  - CI.KZN_HIST_APROVADOR: nao sera tocada (@APAGAR_APROVADORES = 0).';

IF @total = 0
BEGIN
    PRINT 'Nada a apagar.';
    RETURN;
END

/* Sem GO ate o fim: RAISERROR + RETURN so encerram o batch em que
   aparecem, e um GO aqui deixaria o DELETE rodar apos um aborto. */

/* =====================================================================
   E2 - EXCLUSAO
   ===================================================================== */
BEGIN TRANSACTION;
BEGIN TRY

    SET @i = 1;
    WHILE @i <= @n
    BEGIN
        SELECT @tab = NOME FROM @tabelas WHERE ORDEM = @i;

        IF OBJECT_ID('CI.' + @tab, 'U') IS NOT NULL
        BEGIN
            SET @sql = N'DELETE FROM CI.' + QUOTENAME(@tab)
                     + CASE WHEN @SOMENTE_FAIXA = 1 THEN N' WHERE ID_KAIZEN BETWEEN @a AND @b' ELSE N'' END
                     + N'; SET @c = @@ROWCOUNT;';
            /* @c por OUTPUT, medido dentro do batch dinamico: ler
               @@ROWCOUNT aqui fora, depois do EXEC, e fragil. */
            EXEC sp_executesql @sql, N'@a INT, @b INT, @c INT OUTPUT', @a = @ID_INI, @b = @ID_FIM, @c = @qt OUTPUT;
            PRINT '  - CI.' + @tab + ': ' + CAST(@qt AS VARCHAR(10)) + ' linha(s) excluida(s).';
        END

        SET @i += 1;
    END

    /* Aprovadores por ultimo: a principal ja nao os referencia. */
    IF @temAprovador = 1
    BEGIN
        SET @sql = N'DELETE a FROM CI.KZN_HIST_APROVADOR a
                     WHERE NOT EXISTS (SELECT 1 FROM CI.KZN_HIST_PEDRAVISAOCONSOLIDADA p
                                       WHERE p.ID_APROVADOR = a.ID_APROVADOR);
                     SET @c = @@ROWCOUNT;';
        EXEC sp_executesql @sql, N'@c INT OUTPUT', @c = @qt OUTPUT;
        PRINT '  - CI.KZN_HIST_APROVADOR: ' + CAST(@qt AS VARCHAR(10)) + ' aprovador(es) excluido(s).';
    END

    /* =================================================================
       E3 - VERIFICACAO ANTES DO COMMIT
       ================================================================= */
    DECLARE @msg NVARCHAR(400);

    SET @i = 1;
    WHILE @i <= @n
    BEGIN
        SELECT @tab = NOME FROM @tabelas WHERE ORDEM = @i;

        IF OBJECT_ID('CI.' + @tab, 'U') IS NOT NULL
        BEGIN
            SET @sql = N'SELECT @c = COUNT(*) FROM CI.' + QUOTENAME(@tab)
                     + CASE WHEN @SOMENTE_FAIXA = 1 THEN N' WHERE ID_KAIZEN BETWEEN @a AND @b' ELSE N'' END + N';';
            EXEC sp_executesql @sql, N'@a INT, @b INT, @c INT OUTPUT', @a = @ID_INI, @b = @ID_FIM, @c = @qt OUTPUT;

            IF @qt > 0
            BEGIN
                SET @msg = 'Abortado na verificacao: restam ' + CAST(@qt AS VARCHAR(10))
                    + ' linha(s) em CI.' + @tab + '. ROLLBACK aplicado — nada foi excluido.';
                RAISERROR(@msg, 16, 1);
            END
        END

        SET @i += 1;
    END

    IF @temAprovador = 1
    BEGIN
        EXEC sp_executesql @sqlOrfaosAgora, N'@c INT OUTPUT', @c = @qt OUTPUT;
        IF @qt > 0
        BEGIN
            SET @msg = 'Abortado na verificacao: restam ' + CAST(@qt AS VARCHAR(10))
                + ' aprovador(es) sem Kaizen em CI.KZN_HIST_APROVADOR. ROLLBACK aplicado — nada foi excluido.';
            RAISERROR(@msg, 16, 1);
        END
    END

    COMMIT TRANSACTION;
    PRINT 'Exclusao concluida e conferida.';

END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    PRINT 'ERRO - nada foi excluido (rollback aplicado): ' + ERROR_MESSAGE();
    THROW;
END CATCH
GO

/* =====================================================================
   E4 - CONFERENCIA (total remanescente em cada tabela)
   ===================================================================== */
SELECT  TABELA = t.name,
        LINHAS = (SELECT ISNULL(SUM(rows),0) FROM sys.partitions
                  WHERE object_id = t.object_id AND index_id IN (0,1))
FROM    sys.tables t
WHERE   t.schema_id = SCHEMA_ID('CI') AND t.name LIKE 'KZN_HIST[_]%'
ORDER BY t.name;
GO
