/* =====================================================================
   04 - OBJETOS PÓS-CARGA  (conectado ao BDIBPBMSA_DEV)
   ---------------------------------------------------------------------
   Na ordem: views/funções/procedures, índices, CHECKs, FKs, reseed de
   identity, triggers, sinônimos e propriedades estendidas — tudo a
   partir do catálogo da PRD.

   CHECK e FK entram WITH CHECK quando são confiáveis na PRD: a criação
   valida TODAS as linhas carregadas, e é essa a prova de integridade
   referencial. Constraint não confiável/desabilitada na PRD é recriada
   no mesmo estado (WITH NOCHECK / NOCHECK CONSTRAINT).

   Cada objeto é independente: falha vira FALHA na evidência e o script
   segue, para listar todos os problemas de uma vez. Idempotente: objeto
   que já existe é pulado.
   ===================================================================== */

SET NOCOUNT ON;

DECLARE @ini INT = ISNULL((SELECT MAX(ID) FROM MIG.EVIDENCIA), 0);
DECLARE @sql NVARCHAR(MAX), @def NVARCHAR(MAX), @nome SYSNAME, @tab SYSNAME, @tipo CHAR(2), @d NVARCHAR(MAX),
        @an BIT, @qi BIT, @desab BIT, @ordem NVARCHAR(400), @ok INT = 0, @falha INT = 0;

IF NOT EXISTS (SELECT 1 FROM MIG.CARGA_LOG) OR EXISTS (SELECT 1 FROM MIG.CARGA_LOG WHERE STATUS <> 'OK')
BEGIN
    RAISERROR('Abortado: a carga (03) não terminou com todas as tabelas OK.', 16, 1);
    RETURN;
END

/* ── 1. Views, funções e procedures ───────────────────────────────────
   Em passadas: uma view sobre outra view só compila depois dela. As
   opções ANSI_NULLS e QUOTED_IDENTIFIER com que o módulo foi criado na
   PRD ficam gravadas nele e mudam o comportamento — são reaplicadas num
   EXEC externo, porque CREATE precisa ser a primeira instrução do lote. */
DECLARE @pend TABLE (NOME SYSNAME PRIMARY KEY, TIPO CHAR(2), DEFINICAO NVARCHAR(MAX), AN BIT, QI BIT, CRIADO DATETIME2(3), ERRO NVARCHAR(MAX));
INSERT @pend (NOME, TIPO, DEFINICAO, AN, QI, CRIADO)
SELECT NOME, TIPO, DEFINICAO, ANSI_NULLS_, QUOTED_ID, CRIADO FROM MIG.CAT_MODULO
WHERE ORIGEM = 'PRD' AND TIPO IN ('V','P','FN','IF','TF') AND OBJECT_ID(N'CI.' + QUOTENAME(NOME)) IS NULL;

DECLARE @restam INT = (SELECT COUNT(*) FROM @pend), @antes INT = -1;
WHILE @restam > 0 AND @restam <> @antes
BEGIN
    SET @antes = @restam;
    DECLARE m CURSOR LOCAL FAST_FORWARD FOR SELECT NOME, DEFINICAO, AN, QI FROM @pend ORDER BY CRIADO, NOME;
    OPEN m;
    FETCH NEXT FROM m INTO @nome, @def, @an, @qi;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @sql = N'SET ANSI_NULLS ' + CASE WHEN @an = 1 THEN N'ON' ELSE N'OFF' END
                 + N'; SET QUOTED_IDENTIFIER ' + CASE WHEN @qi = 1 THEN N'ON' ELSE N'OFF' END
                 + N'; EXEC sp_executesql @def;';
        BEGIN TRY
            EXEC sp_executesql @sql, N'@def NVARCHAR(MAX)', @def = @def;
            DELETE @pend WHERE NOME = @nome;
        END TRY
        BEGIN CATCH
            UPDATE @pend SET ERRO = ERROR_MESSAGE() WHERE NOME = @nome;
        END CATCH
        FETCH NEXT FROM m INTO @nome, @def, @an, @qi;
    END
    CLOSE m; DEALLOCATE m;
    SELECT @restam = COUNT(*) FROM @pend;
END
INSERT MIG.EVIDENCIA (ETAPA, ITEM, RESULTADO, DETALHE)
SELECT '04', N'Módulo não criado: CI.' + NOME, 'FALHA', ERRO FROM @pend;

/* ── 2. Índices: clustered antes dos nonclustered; de tabela antes de view */
DECLARE i CURSOR LOCAL FAST_FORWARD FOR
    SELECT OBJETO, NOME,
           N'CREATE ' + CASE WHEN UNICO = 1 THEN N'UNIQUE ' ELSE N'' END + TIPO + N' INDEX ' + QUOTENAME(NOME)
         + N' ON CI.' + QUOTENAME(OBJETO) + N' (' + COLUNAS + N')'
         + ISNULL(N' INCLUDE (' + INCLUIDAS + N')', N'') + ISNULL(N' WHERE ' + FILTRO, N'')
         + N' WITH (' + OPCOES + N');'
         + CASE WHEN DESABILITADO = 1 THEN N' ALTER INDEX ' + QUOTENAME(NOME) + N' ON CI.' + QUOTENAME(OBJETO) + N' DISABLE;' ELSE N'' END
    FROM MIG.CAT_INDICE
    WHERE ORIGEM = 'PRD'
      AND NOT EXISTS (SELECT 1 FROM sys.indexes x WHERE x.object_id = OBJECT_ID(N'CI.' + QUOTENAME(OBJETO)) AND x.name COLLATE DATABASE_DEFAULT = NOME)
    ORDER BY CASE OBJETO_TIPO WHEN 'U' THEN 0 ELSE 1 END, CASE TIPO WHEN 'CLUSTERED' THEN 0 ELSE 1 END, OBJETO, NOME;
OPEN i;
FETCH NEXT FROM i INTO @tab, @nome, @sql;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY EXEC sp_executesql @sql; SET @ok += 1; END TRY
    BEGIN CATCH
        SET @d = N'CI.' + @tab + N'.' + @nome + N': ' + ERROR_MESSAGE();
        EXEC MIG.SP_EVIDENCIA '04', N'Índice não criado', 'FALHA', @d;
    END CATCH
    FETCH NEXT FROM i INTO @tab, @nome, @sql;
END
CLOSE i; DEALLOCATE i;

/* ── 3. CHECKs e 4. FKs ─────────────────────────────────────────────── */
DECLARE k CURSOR LOCAL FAST_FORWARD FOR
    SELECT TABELA, NOME,
           N'ALTER TABLE CI.' + QUOTENAME(TABELA) + CASE WHEN NAO_CONFIAVEL = 1 THEN N' WITH NOCHECK' ELSE N' WITH CHECK' END
         + N' ADD CONSTRAINT ' + QUOTENAME(NOME) + N' CHECK' + CASE WHEN NAO_REPLICACAO = 1 THEN N' NOT FOR REPLICATION' ELSE N'' END
         + N' ' + DEFINICAO + N';'
         + CASE WHEN DESABILITADA = 1 THEN N' ALTER TABLE CI.' + QUOTENAME(TABELA) + N' NOCHECK CONSTRAINT ' + QUOTENAME(NOME) + N';' ELSE N'' END,
           0 AS ORDEM_
    FROM MIG.CAT_CHECK WHERE ORIGEM = 'PRD' AND OBJECT_ID(N'CI.' + QUOTENAME(NOME), 'C') IS NULL
    UNION ALL
    SELECT TABELA, NOME,
           N'ALTER TABLE CI.' + QUOTENAME(TABELA) + CASE WHEN NAO_CONFIAVEL = 1 THEN N' WITH NOCHECK' ELSE N' WITH CHECK' END
         + N' ADD CONSTRAINT ' + QUOTENAME(NOME) + N' FOREIGN KEY (' + COLUNAS + N') REFERENCES '
         + QUOTENAME(REF_ESQUEMA) + N'.' + QUOTENAME(REF_TABELA) + N' (' + REF_COLUNAS + N') ON DELETE ' + ACAO_DELETE
         + N' ON UPDATE ' + ACAO_UPDATE + CASE WHEN NAO_REPLICACAO = 1 THEN N' NOT FOR REPLICATION' ELSE N'' END + N';'
         + CASE WHEN DESABILITADA = 1 THEN N' ALTER TABLE CI.' + QUOTENAME(TABELA) + N' NOCHECK CONSTRAINT ' + QUOTENAME(NOME) + N';' ELSE N'' END,
           1
    FROM MIG.CAT_FK WHERE ORIGEM = 'PRD' AND OBJECT_ID(N'CI.' + QUOTENAME(NOME), 'F') IS NULL
    ORDER BY 4, 1, 2;
DECLARE @ordemK INT;
OPEN k;
FETCH NEXT FROM k INTO @tab, @nome, @sql, @ordemK;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY EXEC sp_executesql @sql; SET @ok += 1; END TRY
    BEGIN CATCH
        SET @d = N'CI.' + @tab + N'.' + @nome + N': ' + ERROR_MESSAGE();
        EXEC MIG.SP_EVIDENCIA '04', N'Constraint não criada (CHECK/FK)', 'FALHA', @d;
    END CATCH
    FETCH NEXT FROM k INTO @tab, @nome, @sql, @ordemK;
END
CLOSE k; DEALLOCATE k;

/* ── 5. Identity: o próximo valor igual ao da PRD ─────────────────────
   Tabela com linhas: RESEED no último valor da PRD (o próximo soma o
   incremento). Tabela vazia e nunca usada: o próximo é o próprio valor
   do RESEED, então soma-se o incremento aqui. */
DECLARE r CURSOR LOCAL FAST_FORWARD FOR
    SELECT c.TABELA,
           N'DBCC CHECKIDENT (N''CI.' + REPLACE(QUOTENAME(c.TABELA), N'''', N'''''') + N''', RESEED, '
         + CASE WHEN EXISTS (SELECT 1 FROM sys.partitions p WHERE p.object_id = OBJECT_ID(N'CI.' + QUOTENAME(c.TABELA))
                             AND p.index_id IN (0,1) AND p.rows > 0)
                THEN c.ULTIMO_IDENTITY
                ELSE CAST(CAST(c.ULTIMO_IDENTITY AS DECIMAL(38,0)) + CAST(c.INCREMENTO AS DECIMAL(38,0)) AS NVARCHAR(40)) END
         + N') WITH NO_INFOMSGS;'
    FROM MIG.CAT_COLUNA c
    WHERE c.ORIGEM = 'PRD' AND c.IDENTIDADE = 1 AND c.ULTIMO_IDENTITY IS NOT NULL;
OPEN r;
FETCH NEXT FROM r INTO @tab, @sql;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY EXEC sp_executesql @sql; END TRY
    BEGIN CATCH
        SET @d = N'CI.' + @tab + N': ' + ERROR_MESSAGE();
        EXEC MIG.SP_EVIDENCIA '04', N'Reseed de identity', 'FALHA', @d;
    END CATCH
    FETCH NEXT FROM r INTO @tab, @sql;
END
CLOSE r; DEALLOCATE r;

/* ── 6. Triggers (depois da carga: nenhum disparou nela) ─────────────── */
DECLARE g CURSOR LOCAL FAST_FORWARD FOR
    SELECT NOME, TABELA_PAI, DEFINICAO, ANSI_NULLS_, QUOTED_ID, DESABILITADO, ORDEM_TRIGGER
    FROM MIG.CAT_MODULO WHERE ORIGEM = 'PRD' AND TIPO = 'TR' AND OBJECT_ID(N'CI.' + QUOTENAME(NOME), 'TR') IS NULL
    ORDER BY TABELA_PAI, NOME;
OPEN g;
FETCH NEXT FROM g INTO @nome, @tab, @def, @an, @qi, @desab, @ordem;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @sql = N'SET ANSI_NULLS ' + CASE WHEN @an = 1 THEN N'ON' ELSE N'OFF' END
             + N'; SET QUOTED_IDENTIFIER ' + CASE WHEN @qi = 1 THEN N'ON' ELSE N'OFF' END + N'; EXEC sp_executesql @def;';
    BEGIN TRY
        EXEC sp_executesql @sql, N'@def NVARCHAR(MAX)', @def = @def;
        IF @desab = 1
        BEGIN
            SET @sql = N'DISABLE TRIGGER CI.' + QUOTENAME(@nome) + N' ON CI.' + QUOTENAME(@tab) + N';';
            EXEC sp_executesql @sql;
        END
        IF @ordem IS NOT NULL
        BEGIN
            SELECT @sql = STRING_AGG(CONVERT(NVARCHAR(MAX), N'EXEC sp_settriggerorder @triggername = N''CI.' + REPLACE(QUOTENAME(@nome), N'''', N'''''')
                          + N''', @order = N''' + PARSENAME(REPLACE(LTRIM(value), N':', N'.'), 1)
                          + N''', @stmttype = N''' + PARSENAME(REPLACE(LTRIM(value), N':', N'.'), 2) + N''';'), NCHAR(10))
            FROM STRING_SPLIT(@ordem, N',');
            EXEC sp_executesql @sql;
        END
        SET @ok += 1;
    END TRY
    BEGIN CATCH
        SET @d = N'CI.' + @nome + N' em CI.' + @tab + N': ' + ERROR_MESSAGE();
        EXEC MIG.SP_EVIDENCIA '04', N'Trigger não criado', 'FALHA', @d;
    END CATCH
    FETCH NEXT FROM g INTO @nome, @tab, @def, @an, @qi, @desab, @ordem;
END
CLOSE g; DEALLOCATE g;

/* ── 7. Sinônimos ───────────────────────────────────────────────────── */
DECLARE s CURSOR LOCAL FAST_FORWARD FOR
    SELECT NOME, N'CREATE SYNONYM CI.' + QUOTENAME(NOME) + N' FOR ' + BASE + N';'
    FROM MIG.CAT_SINONIMO WHERE ORIGEM = 'PRD' AND OBJECT_ID(N'CI.' + QUOTENAME(NOME), 'SN') IS NULL;
OPEN s;
FETCH NEXT FROM s INTO @nome, @sql;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY EXEC sp_executesql @sql; SET @ok += 1; END TRY
    BEGIN CATCH
        SET @d = N'CI.' + @nome + N': ' + ERROR_MESSAGE();
        EXEC MIG.SP_EVIDENCIA '04', N'Sinônimo não criado', 'FALHA', @d;
    END CATCH
    FETCH NEXT FROM s INTO @nome, @sql;
END
CLOSE s; DEALLOCATE s;

/* ── 8. Propriedades estendidas ─────────────────────────────────────── */
DECLARE @nm SYSNAME, @valor NVARCHAR(4000), @n1t NVARCHAR(20), @n1 SYSNAME, @n2t NVARCHAR(20), @n2 SYSNAME;
DECLARE e CURSOR LOCAL FAST_FORWARD FOR
    SELECT NOME, VALOR,
           CASE OBJETO_TIPO WHEN 'U' THEN N'TABLE' WHEN 'V' THEN N'VIEW' WHEN 'P' THEN N'PROCEDURE'
                            WHEN 'SO' THEN N'SEQUENCE' WHEN 'SN' THEN N'SYNONYM' ELSE N'FUNCTION' END,
           OBJETO, NIVEL2_TIPO, NIVEL2
    FROM MIG.CAT_EXTPROP x WHERE x.ORIGEM = 'PRD'
      AND NOT EXISTS (SELECT 1 FROM MIG.CAT_EXTPROP d WHERE d.ORIGEM = 'DEV' AND d.OBJETO = x.OBJETO
                      AND ISNULL(d.NIVEL2, N'') = ISNULL(x.NIVEL2, N'') AND d.NOME = x.NOME);
EXEC MIG.SP_SNAPSHOT 'DEV';   -- para o NOT EXISTS acima ver o estado atual
OPEN e;
FETCH NEXT FROM e INTO @nm, @valor, @n1t, @n1, @n2t, @n2;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        EXEC sp_addextendedproperty @name = @nm, @value = @valor, @level0type = N'SCHEMA', @level0name = N'CI',
             @level1type = @n1t, @level1name = @n1, @level2type = @n2t, @level2name = @n2;
        SET @ok += 1;
    END TRY
    BEGIN CATCH
        SET @d = N'CI.' + @n1 + ISNULL(N'.' + @n2, N'') + N' [' + @nm + N']: ' + ERROR_MESSAGE();
        EXEC MIG.SP_EVIDENCIA '04', N'Propriedade estendida não criada', 'FALHA', @d;
    END CATCH
    FETCH NEXT FROM e INTO @nm, @valor, @n1t, @n1, @n2t, @n2;
END
CLOSE e; DEALLOCATE e;

/* ── Resultado ─────────────────────────────────────────────────────── */
SELECT @falha = COUNT(*) FROM MIG.EVIDENCIA WHERE ID > @ini AND RESULTADO = 'FALHA';
SET @d = CAST(@ok AS NVARCHAR(10)) + N' objeto(s) criado(s) além dos módulos; '
       + CAST(@falha AS NVARCHAR(10)) + N' falha(s).';
EXEC MIG.SP_EVIDENCIA '04', N'Objetos pós-carga', 'OK', @d;
UPDATE MIG.EVIDENCIA SET RESULTADO = 'FALHA' WHERE ID = (SELECT MAX(ID) FROM MIG.EVIDENCIA) AND @falha > 0;

SELECT ETAPA, RESULTADO, ITEM, DETALHE FROM MIG.EVIDENCIA WHERE ID > @ini
ORDER BY CASE RESULTADO WHEN 'FALHA' THEN 0 ELSE 1 END, ID;
GO
