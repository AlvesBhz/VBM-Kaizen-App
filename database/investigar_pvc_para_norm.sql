/* =====================================================================
   ETAPA 1 — Investigação de CI.KZN_PEDRAVISAOCONSOLIDADA
   ---------------------------------------------------------------------
   SOMENTE LEITURA. Nenhum INSERT/UPDATE/DELETE/DDL. Pode rodar em
   produção com segurança.

   Levanta tudo que é necessário para dimensionar e criar a tabela
   normalizada: colunas, constraints, índices, FKs nos dois sentidos,
   maior valor real por coluna de texto, dependências e tamanho de linha.

   Rode e me mande a saída das 9 partes — em especial a PARTE 6 (maior
   valor real) e a PARTE 9 (limite de 8060 bytes), que são as que
   definem o tamanho final de cada coluna.

   Schema: 'ci'.
   ===================================================================== */

SET NOCOUNT ON;

DECLARE @T SYSNAME = 'CI.KZN_PEDRAVISAOCONSOLIDADA';

IF OBJECT_ID(@T, 'U') IS NULL
BEGIN
    RAISERROR('Tabela CI.KZN_PEDRAVISAOCONSOLIDADA não encontrada neste banco/contexto.', 16, 1);
    RETURN;
END

/* ---------- PARTE 1 — Colunas ---------- */
SELECT  PARTE = '1-COLUNAS',
        POSICAO   = c.column_id,
        COLUNA    = c.name,
        TIPO      = ty.name,
        TAMANHO   = CASE
                      WHEN ty.name IN ('varchar','char','varbinary','binary')
                           THEN CASE WHEN c.max_length = -1 THEN 'MAX' ELSE CAST(c.max_length AS VARCHAR(10)) END
                      WHEN ty.name IN ('nvarchar','nchar')
                           THEN CASE WHEN c.max_length = -1 THEN 'MAX' ELSE CAST(c.max_length/2 AS VARCHAR(10)) END
                      WHEN ty.name IN ('decimal','numeric')
                           THEN CAST(c.precision AS VARCHAR(10)) + ',' + CAST(c.scale AS VARCHAR(10))
                      WHEN ty.name IN ('datetime2','time','datetimeoffset')
                           THEN CAST(c.scale AS VARCHAR(10))
                      ELSE '' END,
        BYTES_MAX = c.max_length,
        NULO      = CASE WHEN c.is_nullable = 1 THEN 'SIM' ELSE 'NAO' END,
        COLLATION = c.collation_name,
        IDENTITY_ = CASE WHEN c.is_identity = 1 THEN 'SIM' ELSE 'NAO' END,
        CALCULADA = CASE WHEN c.is_computed = 1 THEN 'SIM' ELSE 'NAO' END,
        DEFAULT_  = dc.definition,
        DEFAULT_NOME = dc.name
FROM        sys.columns c
JOIN        sys.types   ty ON ty.user_type_id = c.user_type_id
LEFT JOIN   sys.default_constraints dc ON dc.parent_object_id = c.object_id
                                      AND dc.parent_column_id = c.column_id
WHERE       c.object_id = OBJECT_ID(@T)
ORDER BY    c.column_id;

/* ---------- PARTE 2 — PK, UNIQUE e CHECK ---------- */
SELECT  PARTE = '2-PK_UNIQUE',
        CONSTRAINT_ = kc.name,
        TIPO        = CASE kc.type WHEN 'PK' THEN 'PRIMARY KEY' ELSE 'UNIQUE' END,
        CLUSTERIZADO = i.type_desc,
        COLUNAS     = STUFF((SELECT ', ' + COL_NAME(ic.object_id, ic.column_id)
                             FROM sys.index_columns ic
                             WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id
                               AND ic.is_included_column = 0
                             ORDER BY ic.key_ordinal
                             FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, '')
FROM    sys.key_constraints kc
JOIN    sys.indexes i ON i.object_id = kc.parent_object_id AND i.index_id = kc.unique_index_id
WHERE   kc.parent_object_id = OBJECT_ID(@T);

SELECT  PARTE = '2-CHECK',
        CONSTRAINT_ = cc.name,
        DEFINICAO   = cc.definition,
        CONFIAVEL   = CASE WHEN cc.is_not_trusted = 1 THEN 'NAO' ELSE 'SIM' END
FROM    sys.check_constraints cc
WHERE   cc.parent_object_id = OBJECT_ID(@T);

/* ---------- PARTE 3 — Índices (não-constraint) ---------- */
SELECT  PARTE = '3-INDICES',
        INDICE   = i.name,
        TIPO     = i.type_desc,
        UNICO    = CASE WHEN i.is_unique = 1 THEN 'SIM' ELSE 'NAO' END,
        CHAVE    = STUFF((SELECT ', ' + COL_NAME(ic.object_id, ic.column_id)
                          FROM sys.index_columns ic
                          WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id
                            AND ic.is_included_column = 0
                          ORDER BY ic.key_ordinal
                          FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, ''),
        INCLUDE_ = STUFF((SELECT ', ' + COL_NAME(ic.object_id, ic.column_id)
                          FROM sys.index_columns ic
                          WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id
                            AND ic.is_included_column = 1
                          ORDER BY ic.index_column_id
                          FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, ''),
        FILTRO   = i.filter_definition
FROM    sys.indexes i
WHERE   i.object_id = OBJECT_ID(@T)
  AND   i.type IN (1,2) AND i.is_primary_key = 0 AND i.is_unique_constraint = 0;

/* ---------- PARTE 4 — FKs de SAÍDA (PVC referencia outras) ---------- */
SELECT  PARTE = '4-FK_SAIDA',
        FK           = fk.name,
        COLUNAS_PVC  = STUFF((SELECT ', ' + COL_NAME(c.parent_object_id, c.parent_column_id)
                              FROM sys.foreign_key_columns c
                              WHERE c.constraint_object_id = fk.object_id
                              ORDER BY c.constraint_column_id
                              FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, ''),
        TABELA_PAI   = OBJECT_SCHEMA_NAME(fk.referenced_object_id) + '.' + OBJECT_NAME(fk.referenced_object_id),
        COLUNAS_PAI  = STUFF((SELECT ', ' + COL_NAME(c.referenced_object_id, c.referenced_column_id)
                              FROM sys.foreign_key_columns c
                              WHERE c.constraint_object_id = fk.object_id
                              ORDER BY c.constraint_column_id
                              FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, ''),
        ON_DELETE    = fk.delete_referential_action_desc,
        ON_UPDATE    = fk.update_referential_action_desc,
        CONFIAVEL    = CASE WHEN fk.is_not_trusted = 1 THEN 'NAO' ELSE 'SIM' END
FROM    sys.foreign_keys fk
WHERE   fk.parent_object_id = OBJECT_ID(@T);

/* ---------- PARTE 5 — FKs de ENTRADA (outras referenciam PVC) ---------- */
SELECT  PARTE = '5-FK_ENTRADA',
        FK            = fk.name,
        TABELA_FILHA  = OBJECT_SCHEMA_NAME(fk.parent_object_id) + '.' + OBJECT_NAME(fk.parent_object_id),
        COLUNAS_FILHA = STUFF((SELECT ', ' + COL_NAME(c.parent_object_id, c.parent_column_id)
                               FROM sys.foreign_key_columns c
                               WHERE c.constraint_object_id = fk.object_id
                               ORDER BY c.constraint_column_id
                               FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, ''),
        COLUNAS_PVC   = STUFF((SELECT ', ' + COL_NAME(c.referenced_object_id, c.referenced_column_id)
                               FROM sys.foreign_key_columns c
                               WHERE c.constraint_object_id = fk.object_id
                               ORDER BY c.constraint_column_id
                               FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, ''),
        ON_DELETE     = fk.delete_referential_action_desc,
        LINHAS_FILHA  = (SELECT SUM(p.rows) FROM sys.partitions p
                         WHERE p.object_id = fk.parent_object_id AND p.index_id IN (0,1))
FROM    sys.foreign_keys fk
WHERE   fk.referenced_object_id = OBJECT_ID(@T)
  AND   fk.parent_object_id <> OBJECT_ID(@T);

/* ---------- PARTE 6 — MAIOR VALOR REAL por coluna de texto ----------
   É esta parte que decide o tamanho final de cada coluna. Montada
   dinamicamente: funciona qualquer que seja o conjunto de colunas
   presente hoje (as renomeações recentes não quebram a consulta).
   LEN() = caracteres (o que VARCHAR(n) limita); DATALENGTH = bytes. */
DECLARE @s NVARCHAR(MAX) = N'';

SELECT @s = @s + CASE WHEN @s = N'' THEN N'' ELSE N' UNION ALL ' END
     + N'SELECT POSICAO=' + CAST(c.column_id AS NVARCHAR(10))
     + N', COLUNA=''' + c.name + N''''
     + N', TAM_DECLARADO=' + CASE WHEN c.max_length = -1 THEN N'-1'
                                  WHEN ty.name IN ('nvarchar','nchar') THEN CAST(c.max_length/2 AS NVARCHAR(10))
                                  ELSE CAST(c.max_length AS NVARCHAR(10)) END
     + N', LINHAS_PREENCHIDAS=COUNT(' + QUOTENAME(c.name) + N')'
     + N', MAIOR_LEN=ISNULL(MAX(LEN(' + QUOTENAME(c.name) + N')),0)'
     + N', MAIOR_BYTES=ISNULL(MAX(DATALENGTH(' + QUOTENAME(c.name) + N')),0)'
     + N' FROM ' + @T
FROM        sys.columns c
JOIN        sys.types   ty ON ty.user_type_id = c.user_type_id
WHERE       c.object_id = OBJECT_ID(@T)
  AND       ty.name IN ('varchar','nvarchar','char','nchar')
  AND       c.is_computed = 0
ORDER BY    c.column_id;

IF @s = N''
    PRINT 'PARTE 6: nenhuma coluna de texto encontrada.';
ELSE
BEGIN
    SET @s = N'SELECT PARTE=''6-MAIOR_VALOR_REAL'', * FROM (' + @s + N') x ORDER BY POSICAO;';
    EXEC sp_executesql @s;
END

/* ---------- PARTE 7 — Dependências (triggers, views, procs, funções) ---------- */
SELECT  PARTE = '7-TRIGGERS',
        TRIGGER_  = t.name,
        DESABILITADO = CASE WHEN t.is_disabled = 1 THEN 'SIM' ELSE 'NAO' END,
        TAMANHO_DEF  = LEN(m.definition),
        CITA_TEXTO   = CASE WHEN m.definition LIKE '%VARCHAR(300)%' THEN 'SIM (CONVERT fixo!)' ELSE 'nao' END
FROM        sys.triggers t
LEFT JOIN   sys.sql_modules m ON m.object_id = t.object_id
WHERE       t.parent_id = OBJECT_ID(@T);

SELECT  PARTE = '7-OUTROS_OBJETOS',
        OBJETO = OBJECT_SCHEMA_NAME(d.referencing_id) + '.' + OBJECT_NAME(d.referencing_id),
        TIPO   = o.type_desc
FROM        sys.sql_expression_dependencies d
JOIN        sys.objects o ON o.object_id = d.referencing_id
WHERE       d.referenced_id = OBJECT_ID(@T)
  AND       o.type_desc NOT LIKE '%TRIGGER%'
GROUP BY    d.referencing_id, o.type_desc;

/* ---------- PARTE 8 — Volume e espaço ocupado ---------- */
SELECT  PARTE = '8-VOLUME',
        LINHAS = SUM(CASE WHEN p.index_id IN (0,1) THEN p.rows ELSE 0 END),
        ESPACO_TOTAL_KB = SUM(a.total_pages) * 8,
        ESPACO_DADOS_KB = SUM(a.used_pages)  * 8
FROM        sys.partitions p
JOIN        sys.allocation_units a ON a.container_id = p.partition_id
WHERE       p.object_id = OBJECT_ID(@T);

/* ---------- PARTE 9 — Tamanho de linha vs. limite de 8060 bytes ----------
   Decisivo para o dimensionamento: se a soma dos tamanhos DECLARADOS
   passar de 8060, o CREATE TABLE ainda funciona, mas o SQL Server emite
   o aviso 1701 e as linhas que de fato estourarem passam a usar páginas
   de ROW_OVERFLOW (custo de I/O extra). Ver a análise que mandei junto. */
SELECT  PARTE = '9-TAMANHO_LINHA',
        SOMA_BYTES_DECLARADOS = SUM(CASE WHEN c.max_length = -1 THEN 0 ELSE c.max_length END),
        COLUNAS_MAX           = SUM(CASE WHEN c.max_length = -1 THEN 1 ELSE 0 END),
        LIMITE_IN_ROW         = 8060,
        SITUACAO              = CASE WHEN SUM(CASE WHEN c.max_length = -1 THEN 0 ELSE c.max_length END) > 8060
                                     THEN 'ACIMA do limite in-row (aviso 1701 na criação)'
                                     ELSE 'dentro do limite' END
FROM    sys.columns c
WHERE   c.object_id = OBJECT_ID(@T);
GO
