/* =====================================================================
   Torna NULL-áveis as colunas que travam a carga do histórico
   ---------------------------------------------------------------------
   Duas colunas herdaram NOT NULL das tabelas de produção, mas vêm VAZIAS
   na planilha. Enquanto estiverem NOT NULL, a carga falha com
   "Cannot insert the value NULL":

     CI.KZN_HIST_PEDRAVISAOCONSOLIDADA.ID_CATEGORIA
         16 de 16 linhas sem categoria na planilha.

     CI.KZN_HIST_KAIZEN_DESPERDICIO.ID_DESPERDICIO
         25 de 25 linhas com o ID vazio — na planilha só vem o NOME
         (NM_DESPERDICIO), e o ID é resolvido por lookup em
         CI.KZN_DESPERDICIO. Todo nome que não casar vira NULL, e aí o
         INSERT quebra. Você pediu só a primeira, mas esta trava a carga
         logo em seguida pelo mesmo motivo — por isso está aqui. Se
         preferir tratar depois, comente o bloco E2.

   Só afeta tabelas KZN_HIST_*. NENHUMA tabela de produção é tocada: a
   E0 recusa qualquer alvo cujo nome não comece com KZN_HIST_.

   É IDEMPOTENTE: coluna que já for NULL-ável é pulada.

   NOTA: ampliar nulidade não mexe em dado nenhum e é reversível
   (ALTER COLUMN ... NOT NULL volta atrás, desde que não haja NULL
   gravado).

   Schema: 'ci'.
   ===================================================================== */

SET NOCOUNT ON;
SET XACT_ABORT ON;

/* Colunas a relaxar: tabela, coluna e o tipo COMPLETO a repetir.
   O tipo precisa ser repetido porque ALTER COLUMN reescreve a definição
   inteira — omitir o tipo não é permitido, e omitir a nulidade tornaria
   a coluna NULL-ável por acidente (é justamente o que queremos aqui,
   mas em outros contextos é uma pegadinha clássica). */
DECLARE @alvos TABLE (ORDEM INT PRIMARY KEY, TABELA SYSNAME, COLUNA SYSNAME, TIPO NVARCHAR(50));
INSERT INTO @alvos (ORDEM, TABELA, COLUNA, TIPO) VALUES
    (1, 'KZN_HIST_PEDRAVISAOCONSOLIDADA', 'ID_CATEGORIA',   'INT'),
    (2, 'KZN_HIST_KAIZEN_DESPERDICIO',    'ID_DESPERDICIO', 'INT');

DECLARE @i INT = 1, @n INT, @tab SYSNAME, @col SYSNAME, @tipo NVARCHAR(50),
        @sql NVARCHAR(MAX), @objId INT, @alteradas INT = 0;

SELECT @n = MAX(ORDEM) FROM @alvos;

/* =====================================================================
   E0 - TRAVA DE SEGURANÇA: só tabelas KZN_HIST_
   ===================================================================== */
IF EXISTS (SELECT 1 FROM @alvos WHERE TABELA NOT LIKE 'KZN_HIST_%')
BEGIN
    RAISERROR('Abortado: a lista contém tabela fora do prefixo KZN_HIST_. Este script não altera tabelas de produção.', 16, 1);
    RETURN;
END

/* =====================================================================
   E1/E2 - RELAXA CADA COLUNA
   ===================================================================== */
WHILE @i <= @n
BEGIN
    SELECT @tab = TABELA, @col = COLUNA, @tipo = TIPO FROM @alvos WHERE ORDEM = @i;
    SET @objId = OBJECT_ID('CI.' + @tab, 'U');

    IF @objId IS NULL
        PRINT '  - CI.' + @tab + ': tabela não existe (pulada).';
    ELSE IF NOT EXISTS (SELECT 1 FROM sys.columns
                        WHERE object_id = @objId AND name = @col COLLATE DATABASE_DEFAULT)
        PRINT '  - CI.' + @tab + '.' + @col + ': coluna não existe (pulada).';
    ELSE IF EXISTS (SELECT 1 FROM sys.columns
                    WHERE object_id = @objId AND name = @col COLLATE DATABASE_DEFAULT AND is_nullable = 1)
        PRINT '  - CI.' + @tab + '.' + @col + ': ja e NULL-avel (pulada).';
    ELSE
    BEGIN
        SET @sql = N'ALTER TABLE CI.' + QUOTENAME(@tab)
                 + N' ALTER COLUMN ' + QUOTENAME(@col) + N' ' + @tipo + N' NULL;';
        EXEC sp_executesql @sql;
        SET @alteradas += 1;
        PRINT '  - CI.' + @tab + '.' + @col + ': agora aceita NULL.';
    END

    SET @i += 1;
END

PRINT 'Concluido: ' + CAST(@alteradas AS VARCHAR(10)) + ' coluna(s) alterada(s).';
GO

/* =====================================================================
   E3 - CONFERÊNCIA
   ---------------------------------------------------------------------
   Lista TODAS as colunas ainda NOT NULL nas tabelas HIST. Use para
   antecipar a próxima trava, caso a carga ainda pare por nulidade: o que
   aparecer aqui e vier vazio na planilha é candidato ao mesmo ajuste.
   ===================================================================== */
SELECT  TABELA = t.name,
        COLUNA = c.name,
        TIPO   = ty.name + CASE
                   WHEN ty.name IN ('varchar','char','nvarchar','nchar')
                        THEN '(' + CASE WHEN c.max_length = -1 THEN 'MAX'
                                        WHEN ty.name IN ('nvarchar','nchar') THEN CAST(c.max_length/2 AS VARCHAR(10))
                                        ELSE CAST(c.max_length AS VARCHAR(10)) END + ')'
                   WHEN ty.name IN ('decimal','numeric')
                        THEN '(' + CAST(c.precision AS VARCHAR(10)) + ',' + CAST(c.scale AS VARCHAR(10)) + ')'
                   WHEN ty.name IN ('datetime2','time','datetimeoffset')
                        THEN '(' + CAST(c.scale AS VARCHAR(10)) + ')'
                   ELSE '' END,
        SITUACAO = 'ainda NOT NULL'
FROM        sys.tables  t
JOIN        sys.columns c  ON c.object_id = t.object_id
JOIN        sys.types   ty ON ty.user_type_id = c.user_type_id
WHERE       t.schema_id = SCHEMA_ID('CI')
  AND       t.name LIKE 'KZN_HIST_%'
  AND       c.is_nullable = 0
ORDER BY    t.name, c.column_id;
GO
