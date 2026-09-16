/* =====================================================================
   CI.KZN_PEDRAVISAOCONSOLIDADA — renomeia 2 colunas
   ---------------------------------------------------------------------
     DS_RESULTADO_ESPERADO -> DS_RESULTADO_ALCANCADO  (segue VARCHAR(300))
     ID_DESPERDICIO        -> DS_COMPARA_META         (INT -> VARCHAR(300) NULL)

   Idempotente. A posição das colunas não muda (sp_rename só troca o nome).

   ATENÇÃO — os triggers da tabela citam os nomes antigos e NÃO se
   atualizam sozinhos com sp_rename. A E3 os reescreve a partir da
   definição que está no banco (sys.sql_modules), trocando os nomes. Sem
   isso, o próximo UPDATE na tabela estoura "Invalid column name" — mesmo
   sintoma da migração de ID_MOTIVO.

   IMPACTO NA APLICAÇÃO: server.js referencia essas colunas em 13 pontos
   (e biblioteca.html em 1). Precisam ser ajustados junto.
   ===================================================================== */

SET NOCOUNT ON;
SET XACT_ABORT ON;

/* E1 - DS_RESULTADO_ESPERADO -> DS_RESULTADO_ALCANCADO */
IF COL_LENGTH('CI.KZN_PEDRAVISAOCONSOLIDADA', 'DS_RESULTADO_ESPERADO') IS NOT NULL
BEGIN
    EXEC sp_rename 'CI.KZN_PEDRAVISAOCONSOLIDADA.DS_RESULTADO_ESPERADO', 'DS_RESULTADO_ALCANCADO', 'COLUMN';
    PRINT 'E1 ok - DS_RESULTADO_ALCANCADO.';
END
ELSE PRINT 'E1 pulada - ja renomeada.';
GO

/* E2 - ID_DESPERDICIO -> DS_COMPARA_META VARCHAR(300) NULL
   INT -> VARCHAR(300) é conversão implícita segura: os valores viram
   texto ("12" etc.), nenhum dado se perde. */
IF COL_LENGTH('CI.KZN_PEDRAVISAOCONSOLIDADA', 'ID_DESPERDICIO') IS NOT NULL
BEGIN
    DECLARE @n SYSNAME, @s NVARCHAR(MAX);

    /* DEFAULT e índices sobre a coluna impediriam o ALTER — descobertos
       por metadados em vez de assumidos. */
    SELECT @n = dc.name FROM sys.default_constraints dc
    WHERE  dc.parent_object_id = OBJECT_ID('CI.KZN_PEDRAVISAOCONSOLIDADA')
      AND  dc.parent_column_id = COLUMNPROPERTY(OBJECT_ID('CI.KZN_PEDRAVISAOCONSOLIDADA'), 'ID_DESPERDICIO', 'ColumnId');
    IF @n IS NOT NULL
    BEGIN
        SET @s = N'ALTER TABLE CI.KZN_PEDRAVISAOCONSOLIDADA DROP CONSTRAINT ' + QUOTENAME(@n) + N';';
        EXEC sp_executesql @s;
    END

    IF EXISTS (SELECT 1 FROM sys.indexes i
               JOIN sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id
               WHERE i.object_id = OBJECT_ID('CI.KZN_PEDRAVISAOCONSOLIDADA') AND i.name IS NOT NULL
                 AND i.is_primary_key = 0 AND i.is_unique_constraint = 0
                 AND ic.column_id = COLUMNPROPERTY(OBJECT_ID('CI.KZN_PEDRAVISAOCONSOLIDADA'), 'ID_DESPERDICIO', 'ColumnId'))
    BEGIN
        RAISERROR('E2 NAO EXECUTADA: ha indice sobre ID_DESPERDICIO. Remova-o antes.', 16, 1);
        RETURN;
    END

    EXEC sp_rename 'CI.KZN_PEDRAVISAOCONSOLIDADA.ID_DESPERDICIO', 'DS_COMPARA_META', 'COLUMN';
    EXEC sp_executesql N'ALTER TABLE CI.KZN_PEDRAVISAOCONSOLIDADA ALTER COLUMN DS_COMPARA_META VARCHAR(300) NULL;';
    PRINT 'E2 ok - DS_COMPARA_META VARCHAR(300) NULL.';
END
ELSE PRINT 'E2 pulada - ja renomeada.';
GO

/* E3 - reescreve os triggers da tabela com os nomes novos.
   A definição vem do próprio banco, então nada precisa ser colado aqui e
   o resultado acompanha a versão que estiver instalada. */
DECLARE @t SYSNAME, @d NVARCHAR(MAX);
DECLARE c CURSOR LOCAL FAST_FORWARD FOR
    SELECT t.name, m.definition
    FROM   sys.triggers t JOIN sys.sql_modules m ON m.object_id = t.object_id
    WHERE  t.parent_id = OBJECT_ID('CI.KZN_PEDRAVISAOCONSOLIDADA')
      AND (m.definition LIKE '%DS_RESULTADO_ESPERADO%' OR m.definition LIKE '%ID_DESPERDICIO%');

OPEN c;
FETCH NEXT FROM c INTO @t, @d;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @d = REPLACE(REPLACE(@d, 'DS_RESULTADO_ESPERADO', 'DS_RESULTADO_ALCANCADO'), 'ID_DESPERDICIO', 'DS_COMPARA_META');
    /* Garante CREATE OR ALTER: a definição gravada pode ser um CREATE puro. */
    IF @d NOT LIKE '%CREATE OR ALTER%'
        SET @d = STUFF(@d, CHARINDEX('CREATE', @d), 6, 'CREATE OR ALTER');
    EXEC sp_executesql @d;
    PRINT '  E3 ok - trigger ' + @t + ' reescrito.';
    FETCH NEXT FROM c INTO @t, @d;
END
CLOSE c; DEALLOCATE c;
GO

/* E4 - conferência */
SELECT COLUNA = c.name,
       TIPO   = ty.name + CASE WHEN ty.name = 'varchar' THEN '(' + CAST(c.max_length AS VARCHAR(10)) + ')' ELSE '' END,
       NULO   = CASE WHEN c.is_nullable = 1 THEN 'SIM' ELSE 'NAO' END,
       POSICAO = c.column_id
FROM   sys.columns c JOIN sys.types ty ON ty.user_type_id = c.user_type_id
WHERE  c.object_id = OBJECT_ID('CI.KZN_PEDRAVISAOCONSOLIDADA')
  AND  c.name IN ('DS_RESULTADO_ALCANCADO', 'DS_COMPARA_META');

SELECT TRIGGER_COM_NOME_ANTIGO = t.name
FROM   sys.triggers t JOIN sys.sql_modules m ON m.object_id = t.object_id
WHERE  t.parent_id = OBJECT_ID('CI.KZN_PEDRAVISAOCONSOLIDADA')
  AND (m.definition LIKE '%DS_RESULTADO_ESPERADO%' OR m.definition LIKE '%ID_DESPERDICIO%');
GO
