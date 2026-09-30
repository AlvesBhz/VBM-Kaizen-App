/* =====================================================================
   GERAR SCRIPT DE ESTRUTURA DO SCHEMA CI
   (executar conectado ao BDIBPBMSA_PRD — só lê, não cria nada)
   ---------------------------------------------------------------------
   Lê o catálogo REAL do schema CI e escreve, na aba MENSAGENS do SSMS,
   um script único que cria no BDIBPBMSA_DEV todas as tabelas e ligações:
   schema, sequences, tabelas (colunas, tipos, collation, identity,
   colunas calculadas, defaults, PK e UNIQUE com as mesmas opções),
   índices, CHECKs, FKs (no mesmo estado de confiança da PRD), views,
   funções, procedures, triggers (estado e ordem), sinônimos e
   propriedades estendidas. Não copia dados.

   USO
     1. Execute este arquivo na PRD.
     2. Aba Mensagens: Ctrl+A, Ctrl+C, cole num arquivo novo.
     3. Execute esse arquivo conectado ao BDIBPBMSA_DEV.

   Tabelas em @EXCLUIR (logo abaixo) ficam de fora.

   O script gerado é idempotente (só cria o que não existir, nunca
   apaga) e termina com uma conferência: esperado x criado por tipo.
   Mesmas consultas de catálogo da migração (00_preparar.sql), já
   testadas com a collation do catálogo do Azure SQL.
   ===================================================================== */

SET NOCOUNT ON;
SET ANSI_WARNINGS OFF;

/* Tabelas do CI que ficam de fora do script (com seus índices, CHECKs,
   FKs, triggers e propriedades estendidas). */
DECLARE @EXCLUIR TABLE (TABELA SYSNAME PRIMARY KEY);
INSERT @EXCLUIR (TABELA) VALUES (N'KZN_MDM_TEMP'), (N'KZN_MDM_TERCEIROS_TEMP'), (N'KZN_TB_NOTIFICACAO_TESTE');   -- nenhum aviso de agregação pode sair na aba Mensagens junto com o script

DECLARE @q NVARCHAR(MAX);
DECLARE @TABELA TABLE (TABELA SYSNAME, NAO_SUPORTADO NVARCHAR(4000), ESCALONAMENTO NVARCHAR(60), COMPRESSAO_HEAP NVARCHAR(60), LINHAS_CATALOGO BIGINT);
DECLARE @COLUNA TABLE (TABELA SYSNAME, ORDEM INT, COLUNA SYSNAME, TIPO NVARCHAR(300), COLLATION_ NVARCHAR(128), NULO BIT,
    IDENTIDADE BIT, SEMENTE NVARCHAR(40), INCREMENTO NVARCHAR(40), IDENT_NFR BIT, ULTIMO_IDENTITY NVARCHAR(40), CALCULADA BIT,
    DEF_CALCULADA NVARCHAR(MAX), PERSISTIDA BIT, NM_DEFAULT SYSNAME NULL, DEF_DEFAULT NVARCHAR(MAX), ROWGUIDCOL_ BIT, ESPARSA BIT,
    MASCARA NVARCHAR(4000), ROWVERSION_ BIT);
DECLARE @CHAVE TABLE (TABELA SYSNAME, NOME SYSNAME, TIPO CHAR(2), AGRUPAMENTO NVARCHAR(60), COLUNAS NVARCHAR(4000), OPCOES NVARCHAR(4000));
DECLARE @INDICE TABLE (OBJETO SYSNAME, OBJETO_TIPO CHAR(2), NOME SYSNAME, TIPO NVARCHAR(60), UNICO BIT, COLUNAS NVARCHAR(4000),
    INCLUIDAS NVARCHAR(4000), FILTRO NVARCHAR(MAX), OPCOES NVARCHAR(4000), DESABILITADO BIT);
DECLARE @CHECK TABLE (TABELA SYSNAME, NOME SYSNAME, DEFINICAO NVARCHAR(MAX), DESABILITADA BIT, NAO_CONFIAVEL BIT, NAO_REPLICACAO BIT);
DECLARE @FK TABLE (TABELA SYSNAME, NOME SYSNAME, COLUNAS NVARCHAR(4000), REF_ESQUEMA SYSNAME, REF_TABELA SYSNAME, REF_COLUNAS NVARCHAR(4000),
    ACAO_DELETE NVARCHAR(60), ACAO_UPDATE NVARCHAR(60), DESABILITADA BIT, NAO_CONFIAVEL BIT, NAO_REPLICACAO BIT);
DECLARE @MODULO TABLE (NOME SYSNAME, TIPO CHAR(2), TABELA_PAI SYSNAME NULL, DEFINICAO NVARCHAR(MAX), ANSI_NULLS_ BIT, QUOTED_ID BIT,
    SCHEMABINDING_ BIT, DESABILITADO BIT, INSTEAD_OF BIT, ORDEM_TRIGGER NVARCHAR(400), CRIADO DATETIME2(3));
DECLARE @SEQUENCIA TABLE (NOME SYSNAME, TIPO NVARCHAR(128), INICIO NVARCHAR(40), INCREMENTO NVARCHAR(40), MINIMO NVARCHAR(40),
    MAXIMO NVARCHAR(40), CICLO BIT, CACHE_ NVARCHAR(40), PROXIMO NVARCHAR(40));
DECLARE @SINONIMO TABLE (NOME SYSNAME, BASE NVARCHAR(1035));
DECLARE @EXTPROP TABLE (OBJETO SYSNAME, OBJETO_TIPO CHAR(2), PAI SYSNAME NULL, NIVEL2_TIPO NVARCHAR(20), NIVEL2 SYSNAME NULL, NOME SYSNAME, VALOR NVARCHAR(4000));
DECLARE @DEPEXT TABLE (TIPO NVARCHAR(40), OBJETO_FORA NVARCHAR(600), OBJETO_CI NVARCHAR(600), DETALHE NVARCHAR(600));

/* ── Catálogo (mesmas consultas do 00_preparar.sql) ─────────────────── */
    SET @q = N'SELECT TABELA = t.name COLLATE DATABASE_DEFAULT,
        NAO_SUPORTADO = NULLIF(CONCAT_WS(N'', '',
            CASE WHEN t.is_memory_optimized = 1 THEN N''memory-optimized'' END,
            CASE WHEN t.temporal_type <> 0 THEN N''temporal'' END,
            CASE WHEN t.is_node = 1 OR t.is_edge = 1 THEN N''graph'' END,
            CASE WHEN t.ledger_type <> 0 THEN N''ledger'' END,
            CASE WHEN t.is_external = 1 THEN N''external table'' END,
            CASE WHEN EXISTS (SELECT 1 FROM sys.indexes i JOIN sys.data_spaces ds ON ds.data_space_id = i.data_space_id
                              WHERE i.object_id = t.object_id AND ds.type = ''PS'') THEN N''particionada'' END,
            CASE WHEN EXISTS (SELECT 1 FROM sys.indexes i WHERE i.object_id = t.object_id AND i.type IN (3,4,5,6,7))
                 THEN N''indice xml/espacial/columnstore/hash'' END,
            CASE WHEN EXISTS (SELECT 1 FROM sys.columns c JOIN sys.types ty ON ty.user_type_id = c.user_type_id
                              WHERE c.object_id = t.object_id
                                AND (ty.is_user_defined = 1 OR c.is_filestream = 1 OR c.is_column_set = 1
                                     OR c.generated_always_type <> 0 OR c.encryption_type IS NOT NULL
                                     OR ty.name IN (''xml'',''geography'',''geometry'',''hierarchyid'',''sql_variant'',''text'',''ntext'',''image'')))
                 THEN N''tipo/atributo de coluna nao suportado'' END), N''''),
        ESCALONAMENTO = t.lock_escalation_desc COLLATE DATABASE_DEFAULT,
        COMPRESSAO_HEAP = (SELECT p.data_compression_desc COLLATE DATABASE_DEFAULT FROM sys.partitions p
                           WHERE p.object_id = t.object_id AND p.index_id = 0 AND p.partition_number = 1),
        LINHAS_CATALOGO = (SELECT SUM(p.rows) FROM sys.partitions p WHERE p.object_id = t.object_id AND p.index_id IN (0,1))
      FROM sys.tables t WHERE t.schema_id = SCHEMA_ID(N''CI'')';
    INSERT @TABELA (TABELA, NAO_SUPORTADO, ESCALONAMENTO, COMPRESSAO_HEAP, LINHAS_CATALOGO) EXEC sp_executesql @q;

    SET @q = N'SELECT TABELA = t.name COLLATE DATABASE_DEFAULT,
        ORDEM = ROW_NUMBER() OVER (PARTITION BY t.object_id ORDER BY c.column_id),
        COLUNA = c.name COLLATE DATABASE_DEFAULT,
        TIPO = CASE
            WHEN ty.name IN (''varchar'',''char'',''varbinary'',''binary'')
                 THEN ty.name COLLATE DATABASE_DEFAULT + N''('' + CASE WHEN c.max_length = -1 THEN N''max'' ELSE CAST(c.max_length AS NVARCHAR(10)) END + N'')''
            WHEN ty.name IN (''nvarchar'',''nchar'')
                 THEN ty.name COLLATE DATABASE_DEFAULT + N''('' + CASE WHEN c.max_length = -1 THEN N''max'' ELSE CAST(c.max_length / 2 AS NVARCHAR(10)) END + N'')''
            WHEN ty.name IN (''decimal'',''numeric'')
                 THEN ty.name COLLATE DATABASE_DEFAULT + N''('' + CAST(c.precision AS NVARCHAR(3)) + N'','' + CAST(c.scale AS NVARCHAR(3)) + N'')''
            WHEN ty.name IN (''datetime2'',''time'',''datetimeoffset'')
                 THEN ty.name COLLATE DATABASE_DEFAULT + N''('' + CAST(c.scale AS NVARCHAR(3)) + N'')''
            WHEN ty.name = ''float'' THEN N''float('' + CAST(c.precision AS NVARCHAR(3)) + N'')''
            ELSE ty.name COLLATE DATABASE_DEFAULT END,
        COLLATION_ = c.collation_name COLLATE DATABASE_DEFAULT,
        NULO = c.is_nullable, IDENTIDADE = c.is_identity,
        SEMENTE = CAST(ic.seed_value AS NVARCHAR(40)), INCREMENTO = CAST(ic.increment_value AS NVARCHAR(40)),
        IDENT_NFR = ic.is_not_for_replication, ULTIMO_IDENTITY = CAST(ic.last_value AS NVARCHAR(40)),
        CALCULADA = c.is_computed, DEF_CALCULADA = cc.definition COLLATE DATABASE_DEFAULT, PERSISTIDA = ISNULL(cc.is_persisted, 0),
        NM_DEFAULT = dc.name COLLATE DATABASE_DEFAULT, DEF_DEFAULT = dc.definition COLLATE DATABASE_DEFAULT,
        ROWGUIDCOL_ = c.is_rowguidcol, ESPARSA = c.is_sparse, MASCARA = mc.masking_function COLLATE DATABASE_DEFAULT,
        ROWVERSION_ = CASE WHEN ty.name = ''timestamp'' THEN 1 ELSE 0 END
      FROM sys.tables t
      JOIN sys.columns c ON c.object_id = t.object_id
      JOIN sys.types ty ON ty.user_type_id = c.user_type_id
      LEFT JOIN sys.identity_columns ic ON ic.object_id = c.object_id AND ic.column_id = c.column_id
      LEFT JOIN sys.computed_columns cc ON cc.object_id = c.object_id AND cc.column_id = c.column_id
      LEFT JOIN sys.default_constraints dc ON dc.object_id = c.default_object_id
      LEFT JOIN sys.masked_columns mc ON mc.object_id = c.object_id AND mc.column_id = c.column_id
      WHERE t.schema_id = SCHEMA_ID(N''CI'')';
    INSERT @COLUNA (TABELA, ORDEM, COLUNA, TIPO, COLLATION_, NULO, IDENTIDADE, SEMENTE, INCREMENTO, IDENT_NFR,
        ULTIMO_IDENTITY, CALCULADA, DEF_CALCULADA, PERSISTIDA, NM_DEFAULT, DEF_DEFAULT, ROWGUIDCOL_, ESPARSA, MASCARA,
        ROWVERSION_) EXEC sp_executesql @q;

    /* Opções de índice numa forma única — usada no DDL e na comparação. */
    DECLARE @opcoes NVARCHAR(MAX) = N'CONCAT_WS(N'', '',
            N''PAD_INDEX = '' + CASE WHEN i.is_padded = 1 THEN N''ON'' ELSE N''OFF'' END,
            CASE WHEN i.fill_factor > 0 THEN N''FILLFACTOR = '' + CAST(i.fill_factor AS NVARCHAR(3)) END,
            N''IGNORE_DUP_KEY = '' + CASE WHEN i.ignore_dup_key = 1 THEN N''ON'' ELSE N''OFF'' END,
            N''STATISTICS_NORECOMPUTE = '' + CASE WHEN st.no_recompute = 1 THEN N''ON'' ELSE N''OFF'' END,
            N''ALLOW_ROW_LOCKS = '' + CASE WHEN i.allow_row_locks = 1 THEN N''ON'' ELSE N''OFF'' END,
            N''ALLOW_PAGE_LOCKS = '' + CASE WHEN i.allow_page_locks = 1 THEN N''ON'' ELSE N''OFF'' END,
            N''OPTIMIZE_FOR_SEQUENTIAL_KEY = '' + CASE WHEN i.optimize_for_sequential_key = 1 THEN N''ON'' ELSE N''OFF'' END,
            N''DATA_COMPRESSION = '' + p.data_compression_desc COLLATE DATABASE_DEFAULT)';
    DECLARE @colunasIndice NVARCHAR(MAX) = N'(SELECT STRING_AGG(QUOTENAME(c.name COLLATE DATABASE_DEFAULT)
                + CASE WHEN ic.is_descending_key = 1 THEN N'' DESC'' ELSE N'' ASC'' END, N'', '') WITHIN GROUP (ORDER BY ic.key_ordinal)
             FROM sys.index_columns ic JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
             WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.key_ordinal > 0)';

    SET @q = N'SELECT TABELA = t.name COLLATE DATABASE_DEFAULT, NOME = kc.name COLLATE DATABASE_DEFAULT,
        TIPO = kc.type COLLATE DATABASE_DEFAULT, AGRUPAMENTO = i.type_desc COLLATE DATABASE_DEFAULT,
        COLUNAS = ' + @colunasIndice + N', OPCOES = ' + @opcoes + N'
      FROM sys.key_constraints kc
      JOIN sys.tables t ON t.object_id = kc.parent_object_id
      JOIN sys.indexes i ON i.object_id = kc.parent_object_id AND i.index_id = kc.unique_index_id
      OUTER APPLY (SELECT s.no_recompute FROM sys.stats s WHERE s.object_id = i.object_id AND s.stats_id = i.index_id) st
      OUTER APPLY (SELECT TOP (1) pp.data_compression_desc FROM sys.partitions pp
                   WHERE pp.object_id = i.object_id AND pp.index_id = i.index_id ORDER BY pp.partition_number) p
      WHERE t.schema_id = SCHEMA_ID(N''CI'')';
    INSERT @CHAVE (TABELA, NOME, TIPO, AGRUPAMENTO, COLUNAS, OPCOES) EXEC sp_executesql @q;

    SET @q = N'SELECT OBJETO = o.name COLLATE DATABASE_DEFAULT, OBJETO_TIPO = o.type COLLATE DATABASE_DEFAULT,
        NOME = i.name COLLATE DATABASE_DEFAULT, TIPO = i.type_desc COLLATE DATABASE_DEFAULT, UNICO = i.is_unique,
        COLUNAS = ' + @colunasIndice + N',
        INCLUIDAS = (SELECT STRING_AGG(QUOTENAME(c.name COLLATE DATABASE_DEFAULT), N'', '') WITHIN GROUP (ORDER BY ic.index_column_id)
                     FROM sys.index_columns ic JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
                     WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.is_included_column = 1),
        FILTRO = i.filter_definition COLLATE DATABASE_DEFAULT, OPCOES = ' + @opcoes + N', DESABILITADO = i.is_disabled
      FROM sys.indexes i
      JOIN sys.objects o ON o.object_id = i.object_id
      OUTER APPLY (SELECT s.no_recompute FROM sys.stats s WHERE s.object_id = i.object_id AND s.stats_id = i.index_id) st
      OUTER APPLY (SELECT TOP (1) pp.data_compression_desc FROM sys.partitions pp
                   WHERE pp.object_id = i.object_id AND pp.index_id = i.index_id ORDER BY pp.partition_number) p
      WHERE o.schema_id = SCHEMA_ID(N''CI'') AND o.type IN (''U'',''V'') AND i.type IN (1,2)
        AND i.is_primary_key = 0 AND i.is_unique_constraint = 0 AND i.is_hypothetical = 0';
    INSERT @INDICE (OBJETO, OBJETO_TIPO, NOME, TIPO, UNICO, COLUNAS, INCLUIDAS, FILTRO, OPCOES, DESABILITADO) EXEC sp_executesql @q;

    SET @q = N'SELECT TABELA = t.name COLLATE DATABASE_DEFAULT, NOME = cc.name COLLATE DATABASE_DEFAULT,
        DEFINICAO = cc.definition COLLATE DATABASE_DEFAULT, DESABILITADA = cc.is_disabled, NAO_CONFIAVEL = cc.is_not_trusted,
        NAO_REPLICACAO = cc.is_not_for_replication
      FROM sys.check_constraints cc JOIN sys.tables t ON t.object_id = cc.parent_object_id
      WHERE t.schema_id = SCHEMA_ID(N''CI'')';
    INSERT @CHECK (TABELA, NOME, DEFINICAO, DESABILITADA, NAO_CONFIAVEL, NAO_REPLICACAO) EXEC sp_executesql @q;

    SET @q = N'SELECT TABELA = t.name COLLATE DATABASE_DEFAULT, NOME = fk.name COLLATE DATABASE_DEFAULT,
        COLUNAS = (SELECT STRING_AGG(QUOTENAME(c.name COLLATE DATABASE_DEFAULT), N'', '') WITHIN GROUP (ORDER BY fc.constraint_column_id)
                   FROM sys.foreign_key_columns fc JOIN sys.columns c ON c.object_id = fc.parent_object_id AND c.column_id = fc.parent_column_id
                   WHERE fc.constraint_object_id = fk.object_id),
        REF_ESQUEMA = SCHEMA_NAME(rt.schema_id) COLLATE DATABASE_DEFAULT, REF_TABELA = rt.name COLLATE DATABASE_DEFAULT,
        REF_COLUNAS = (SELECT STRING_AGG(QUOTENAME(c.name COLLATE DATABASE_DEFAULT), N'', '') WITHIN GROUP (ORDER BY fc.constraint_column_id)
                   FROM sys.foreign_key_columns fc JOIN sys.columns c ON c.object_id = fc.referenced_object_id AND c.column_id = fc.referenced_column_id
                   WHERE fc.constraint_object_id = fk.object_id),
        ACAO_DELETE = REPLACE(fk.delete_referential_action_desc COLLATE DATABASE_DEFAULT, N''_'', N'' ''),
        ACAO_UPDATE = REPLACE(fk.update_referential_action_desc COLLATE DATABASE_DEFAULT, N''_'', N'' ''),
        DESABILITADA = fk.is_disabled, NAO_CONFIAVEL = fk.is_not_trusted, NAO_REPLICACAO = fk.is_not_for_replication
      FROM sys.foreign_keys fk
      JOIN sys.tables t ON t.object_id = fk.parent_object_id
      JOIN sys.tables rt ON rt.object_id = fk.referenced_object_id
      WHERE t.schema_id = SCHEMA_ID(N''CI'')';
    INSERT @FK (TABELA, NOME, COLUNAS, REF_ESQUEMA, REF_TABELA, REF_COLUNAS, ACAO_DELETE, ACAO_UPDATE,
        DESABILITADA, NAO_CONFIAVEL, NAO_REPLICACAO) EXEC sp_executesql @q;

    SET @q = N'SELECT NOME = o.name COLLATE DATABASE_DEFAULT, TIPO = o.type COLLATE DATABASE_DEFAULT,
        TABELA_PAI = OBJECT_NAME(o.parent_object_id) COLLATE DATABASE_DEFAULT,
        DEFINICAO = m.definition COLLATE DATABASE_DEFAULT, ANSI_NULLS_ = m.uses_ansi_nulls, QUOTED_ID = m.uses_quoted_identifier,
        SCHEMABINDING_ = m.is_schema_bound, DESABILITADO = tr.is_disabled, INSTEAD_OF = tr.is_instead_of_trigger,
        ORDEM_TRIGGER = (SELECT STRING_AGG(te.type_desc COLLATE DATABASE_DEFAULT
                                + CASE WHEN te.is_first = 1 THEN N'':First'' ELSE N'':Last'' END, N'', '')
                         FROM sys.trigger_events te WHERE te.object_id = o.object_id AND (te.is_first = 1 OR te.is_last = 1)),
        CRIADO = o.create_date
      FROM sys.objects o
      LEFT JOIN sys.sql_modules m ON m.object_id = o.object_id
      LEFT JOIN sys.triggers tr ON tr.object_id = o.object_id
      WHERE o.schema_id = SCHEMA_ID(N''CI'') AND o.type IN (''V'',''P'',''FN'',''IF'',''TF'',''TR'',''R'',''D'',''PC'',''FS'',''FT'',''TA'')
        AND NOT (o.type = ''D'' AND o.parent_object_id <> 0)';
    INSERT @MODULO (NOME, TIPO, TABELA_PAI, DEFINICAO, ANSI_NULLS_, QUOTED_ID, SCHEMABINDING_, DESABILITADO,
        INSTEAD_OF, ORDEM_TRIGGER, CRIADO) EXEC sp_executesql @q;

    SET @q = N'SELECT NOME = s.name COLLATE DATABASE_DEFAULT,
        TIPO = CASE WHEN TYPE_NAME(s.user_type_id) IN (''decimal'',''numeric'')
                    THEN TYPE_NAME(s.user_type_id) COLLATE DATABASE_DEFAULT + N''('' + CAST(s.precision AS NVARCHAR(3)) + N'',0)''
                    ELSE TYPE_NAME(s.user_type_id) COLLATE DATABASE_DEFAULT END,
        INICIO = CAST(s.start_value AS NVARCHAR(40)), INCREMENTO = CAST(s.increment AS NVARCHAR(40)),
        MINIMO = CAST(s.minimum_value AS NVARCHAR(40)), MAXIMO = CAST(s.maximum_value AS NVARCHAR(40)), CICLO = s.is_cycling,
        CACHE_ = CASE WHEN s.is_cached = 0 THEN N''NO CACHE'' ELSE ISNULL(CAST(s.cache_size AS NVARCHAR(40)), N''DEFAULT'') END,
        PROXIMO = CAST(CASE WHEN s.last_used_value IS NULL THEN CAST(s.current_value AS DECIMAL(38,0))
                            ELSE CAST(s.last_used_value AS DECIMAL(38,0)) + CAST(s.increment AS DECIMAL(38,0)) END AS NVARCHAR(40))
      FROM sys.sequences s WHERE s.schema_id = SCHEMA_ID(N''CI'')';
    INSERT @SEQUENCIA (NOME, TIPO, INICIO, INCREMENTO, MINIMO, MAXIMO, CICLO, CACHE_, PROXIMO) EXEC sp_executesql @q;

    SET @q = N'SELECT NOME = sn.name COLLATE DATABASE_DEFAULT, BASE = sn.base_object_name COLLATE DATABASE_DEFAULT
      FROM sys.synonyms sn WHERE sn.schema_id = SCHEMA_ID(N''CI'')';
    INSERT @SINONIMO (NOME, BASE) EXEC sp_executesql @q;

    /* Propriedades estendidas: objetos (classe 1, com coluna quando houver)
       e índices (classe 7). Constraint/trigger ficam no nível 2 do pai. */
    SET @q = N'SELECT OBJETO = COALESCE(pai.name, o.name) COLLATE DATABASE_DEFAULT,
        OBJETO_TIPO = COALESCE(pai.type, o.type) COLLATE DATABASE_DEFAULT,
        PAI = pai.name COLLATE DATABASE_DEFAULT,
        NIVEL2_TIPO = CASE WHEN ep.class = 7 THEN N''INDEX''
                           WHEN ep.minor_id > 0 THEN N''COLUMN''
                           WHEN pai.object_id IS NOT NULL AND o.type = ''TR'' THEN N''TRIGGER''
                           WHEN pai.object_id IS NOT NULL THEN N''CONSTRAINT'' END,
        NIVEL2 = CASE WHEN ep.class = 7 THEN ix.name
                      WHEN ep.minor_id > 0 THEN COL_NAME(ep.major_id, ep.minor_id)
                      WHEN pai.object_id IS NOT NULL THEN o.name END COLLATE DATABASE_DEFAULT,
        NOME = ep.name COLLATE DATABASE_DEFAULT, VALOR = CAST(ep.value AS NVARCHAR(4000))
      FROM sys.extended_properties ep
      JOIN sys.objects o ON o.object_id = ep.major_id
      LEFT JOIN sys.objects pai ON pai.object_id = o.parent_object_id AND o.parent_object_id <> 0
      LEFT JOIN sys.indexes ix ON ep.class = 7 AND ix.object_id = ep.major_id AND ix.index_id = ep.minor_id
      WHERE ep.class IN (1, 7) AND o.schema_id = SCHEMA_ID(N''CI'')';
    INSERT @EXTPROP (OBJETO, OBJETO_TIPO, PAI, NIVEL2_TIPO, NIVEL2, NOME, VALOR) EXEC sp_executesql @q;

    /* Dependências que cruzam a fronteira do schema CI. */
    SET @q = N'SELECT TIPO = N''FK de fora -> CI'',
            OBJETO_FORA = SCHEMA_NAME(t.schema_id) COLLATE DATABASE_DEFAULT + N''.'' + t.name COLLATE DATABASE_DEFAULT,
            OBJETO_CI = rt.name COLLATE DATABASE_DEFAULT, DETALHE = fk.name COLLATE DATABASE_DEFAULT
        FROM sys.foreign_keys fk JOIN sys.tables t ON t.object_id = fk.parent_object_id JOIN sys.tables rt ON rt.object_id = fk.referenced_object_id
        WHERE rt.schema_id = SCHEMA_ID(N''CI'') AND t.schema_id <> SCHEMA_ID(N''CI'')
      UNION ALL
      SELECT N''FK de CI -> fora'', SCHEMA_NAME(rt.schema_id) COLLATE DATABASE_DEFAULT + N''.'' + rt.name COLLATE DATABASE_DEFAULT,
             t.name COLLATE DATABASE_DEFAULT, fk.name COLLATE DATABASE_DEFAULT
        FROM sys.foreign_keys fk JOIN sys.tables t ON t.object_id = fk.parent_object_id JOIN sys.tables rt ON rt.object_id = fk.referenced_object_id
        WHERE t.schema_id = SCHEMA_ID(N''CI'') AND rt.schema_id <> SCHEMA_ID(N''CI'')
      UNION ALL
      SELECT DISTINCT CASE WHEN m.is_schema_bound = 1 THEN N''Modulo de fora -> CI (SCHEMABINDING)'' ELSE N''Modulo de fora -> CI'' END,
             SCHEMA_NAME(o.schema_id) COLLATE DATABASE_DEFAULT + N''.'' + o.name COLLATE DATABASE_DEFAULT,
             d.referenced_entity_name COLLATE DATABASE_DEFAULT, o.type_desc COLLATE DATABASE_DEFAULT
        FROM sys.sql_expression_dependencies d JOIN sys.objects o ON o.object_id = d.referencing_id
        LEFT JOIN sys.sql_modules m ON m.object_id = o.object_id
        WHERE d.referenced_schema_name = N''CI'' AND d.referenced_database_name IS NULL AND o.schema_id <> SCHEMA_ID(N''CI'')
      UNION ALL
      SELECT DISTINCT N''Modulo de CI -> fora'',
             ISNULL(d.referenced_database_name COLLATE DATABASE_DEFAULT + N''.'', N'''') + ISNULL(d.referenced_schema_name COLLATE DATABASE_DEFAULT, N''?'') + N''.'' + d.referenced_entity_name COLLATE DATABASE_DEFAULT,
             o.name COLLATE DATABASE_DEFAULT, o.type_desc COLLATE DATABASE_DEFAULT
        FROM sys.sql_expression_dependencies d JOIN sys.objects o ON o.object_id = d.referencing_id
        WHERE o.schema_id = SCHEMA_ID(N''CI'')
          AND (d.referenced_database_name IS NOT NULL OR (d.referenced_schema_name IS NOT NULL AND d.referenced_schema_name <> N''CI''))
          AND d.referenced_class = 1';
    INSERT @DEPEXT (TIPO, OBJETO_FORA, OBJETO_CI, DETALHE) EXEC sp_executesql @q;


/* ── Exclusões ─────────────────────────────────────────────────────── */
-- FK de tabela mantida para tabela excluída não pode ser criada: vira aviso no topo
INSERT @DEPEXT (TIPO, OBJETO_FORA, OBJETO_CI, DETALHE)
SELECT N'FK para tabela excluida', N'CI.' + REF_TABELA, TABELA, NOME FROM @FK
WHERE REF_TABELA IN (SELECT TABELA FROM @EXCLUIR) AND TABELA NOT IN (SELECT TABELA FROM @EXCLUIR);
DELETE @TABELA  WHERE TABELA IN (SELECT TABELA FROM @EXCLUIR);
DELETE @COLUNA  WHERE TABELA IN (SELECT TABELA FROM @EXCLUIR);
DELETE @CHAVE   WHERE TABELA IN (SELECT TABELA FROM @EXCLUIR);
DELETE @CHECK   WHERE TABELA IN (SELECT TABELA FROM @EXCLUIR);
DELETE @FK      WHERE TABELA IN (SELECT TABELA FROM @EXCLUIR) OR REF_TABELA IN (SELECT TABELA FROM @EXCLUIR);
DELETE @INDICE  WHERE OBJETO IN (SELECT TABELA FROM @EXCLUIR);
DELETE @MODULO  WHERE TIPO = 'TR' AND TABELA_PAI IN (SELECT TABELA FROM @EXCLUIR);
DELETE @EXTPROP WHERE OBJETO IN (SELECT TABELA FROM @EXCLUIR);

/* ── Travas ────────────────────────────────────────────────────────── */
IF NOT EXISTS (SELECT 1 FROM @TABELA)
BEGIN
    RAISERROR('Abortado: não há tabelas no schema CI deste banco (%s).', 16, 1, @@SERVERNAME);
    RETURN;
END
IF EXISTS (SELECT 1 FROM @TABELA WHERE NAO_SUPORTADO IS NOT NULL)
   OR EXISTS (SELECT 1 FROM @MODULO WHERE TIPO IN ('R','D','PC','FS','FT','TA') OR DEFINICAO IS NULL)
BEGIN
    SELECT OBJETO = N'CI.' + TABELA, MOTIVO = NAO_SUPORTADO FROM @TABELA WHERE NAO_SUPORTADO IS NOT NULL
    UNION ALL SELECT N'CI.' + NOME, N'módulo CLR, regra/default legado ou WITH ENCRYPTION' FROM @MODULO
    WHERE TIPO IN ('R','D','PC','FS','FT','TA') OR DEFINICAO IS NULL;
    RAISERROR('Abortado: há recurso que este gerador não reproduz fielmente (lista acima).', 16, 1);
    RETURN;
END

/* ── Montagem do script ────────────────────────────────────────────── */
DECLARE @nl NCHAR(2) = NCHAR(13) + NCHAR(10);
DECLARE @go NVARCHAR(10) = NCHAR(13) + NCHAR(10) + N'GO' + NCHAR(13) + NCHAR(10);
DECLARE @sep NVARCHAR(10) = N',' + NCHAR(13) + NCHAR(10) + N'    ';   -- STRING_AGG só aceita variável como separador
DECLARE @s NVARCHAR(MAX), @parte NVARCHAR(MAX);
-- literal N'...' seguro para embutir texto no script gerado
DECLARE @origem SYSNAME = DB_NAME();

SET @s = N'/* =====================================================================' + @nl
       + N'   ESTRUTURA DO SCHEMA CI — gerada de ' + @origem + N' em '
       + CONVERT(NVARCHAR(19), SYSDATETIME(), 120) + @nl
       + N'   Executar conectado ao BDIBPBMSA_DEV. Idempotente: só cria o que não existir.' + @nl
       + N'   Não apaga nada e não copia dados. Termina com a conferência esperado x criado.' + @nl
       + N'   ===================================================================== */' + @nl
       + N'SET NOCOUNT ON;' + @nl + N'SET ANSI_NULLS ON;' + @nl + N'SET QUOTED_IDENTIFIER ON;' + @nl
       + N'IF DB_NAME() = N''' + REPLACE(@origem, N'''', N'''''') + N''''
       + N' BEGIN RAISERROR(''Abortado: este script é para o DEV, não para a origem.'', 16, 1); SET NOEXEC ON; END' + @go
       + N'IF SCHEMA_ID(N''CI'') IS NULL EXEC (N''CREATE SCHEMA CI AUTHORIZATION dbo;'');' + @go;

/* Sequences (antes das tabelas: DEFAULT pode usar NEXT VALUE FOR) */
SELECT @parte = STRING_AGG(CONVERT(NVARCHAR(MAX),
        N'IF OBJECT_ID(N''CI.' + REPLACE(QUOTENAME(NOME), N'''', N'''''') + N''', N''SO'') IS NULL' + @nl
      + N'    CREATE SEQUENCE CI.' + QUOTENAME(NOME) + N' AS ' + TIPO + N' START WITH ' + INICIO + N' INCREMENT BY ' + INCREMENTO
      + N' MINVALUE ' + MINIMO + N' MAXVALUE ' + MAXIMO + CASE WHEN CICLO = 1 THEN N' CYCLE' ELSE N' NO CYCLE' END
      + CASE WHEN CACHE_ = N'NO CACHE' THEN N' NO CACHE' WHEN CACHE_ = N'DEFAULT' THEN N' CACHE' ELSE N' CACHE ' + CACHE_ END + N';'),
        @go) WITHIN GROUP (ORDER BY NOME)
FROM @SEQUENCIA;
SET @s += ISNULL(N'/* ── Sequences ── */' + @nl + @parte + @go, N'');

/* Tabelas, com PK e UNIQUE */
SET @s += N'/* ── Tabelas ── */' + @nl;
DECLARE @tab SYSNAME, @ddl NVARCHAR(MAX);
DECLARE t CURSOR LOCAL FAST_FORWARD FOR SELECT TABELA FROM @TABELA ORDER BY TABELA;
OPEN t;
FETCH NEXT FROM t INTO @tab;
WHILE @@FETCH_STATUS = 0
BEGIN
    SELECT @ddl = N'IF OBJECT_ID(N''CI.' + REPLACE(QUOTENAME(@tab), N'''', N'''''') + N''', N''U'') IS NULL' + @nl
        + N'BEGIN' + @nl + N'CREATE TABLE CI.' + QUOTENAME(@tab) + N' (' + @nl + N'    '
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
            END), @sep) WITHIN GROUP (ORDER BY c.ORDEM)
    FROM @COLUNA c WHERE c.TABELA = @tab;

    SELECT @ddl += ISNULL(N',' + @nl + N'    ' + STRING_AGG(CONVERT(NVARCHAR(MAX),
            N'CONSTRAINT ' + QUOTENAME(k.NOME) + CASE k.TIPO WHEN 'PK' THEN N' PRIMARY KEY ' ELSE N' UNIQUE ' END
            + k.AGRUPAMENTO + N' (' + k.COLUNAS + N') WITH (' + k.OPCOES + N')'), @sep)
            WITHIN GROUP (ORDER BY CASE k.TIPO WHEN 'PK' THEN 0 ELSE 1 END, k.NOME), N'')
    FROM @CHAVE k WHERE k.TABELA = @tab;

    SELECT @ddl += @nl + N')'
        + CASE WHEN tb.COMPRESSAO_HEAP IS NOT NULL AND tb.COMPRESSAO_HEAP <> N'NONE'
               THEN N' WITH (DATA_COMPRESSION = ' + tb.COMPRESSAO_HEAP + N')' ELSE N'' END + N';'
        + CASE WHEN tb.ESCALONAMENTO <> N'TABLE'
               THEN @nl + N'ALTER TABLE CI.' + QUOTENAME(@tab) + N' SET (LOCK_ESCALATION = ' + tb.ESCALONAMENTO + N');' ELSE N'' END
        + @nl + N'END'
    FROM @TABELA tb WHERE tb.TABELA = @tab;

    SET @s += @ddl + @go;
    FETCH NEXT FROM t INTO @tab;
END
CLOSE t; DEALLOCATE t;

/* Índices: de tabela antes de view; clustered antes de nonclustered */
SELECT @parte = STRING_AGG(CONVERT(NVARCHAR(MAX),
        N'IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N''CI.' + REPLACE(QUOTENAME(OBJETO), N'''', N'''''')
      + N''') AND name = N''' + REPLACE(NOME, N'''', N'''''') + N''')' + @nl + N'BEGIN' + @nl
      + N'    CREATE ' + CASE WHEN UNICO = 1 THEN N'UNIQUE ' ELSE N'' END + TIPO + N' INDEX ' + QUOTENAME(NOME)
      + N' ON CI.' + QUOTENAME(OBJETO) + N' (' + COLUNAS + N')'
      + ISNULL(N' INCLUDE (' + INCLUIDAS + N')', N'') + ISNULL(N' WHERE ' + FILTRO, N'') + N' WITH (' + OPCOES + N');'
      + CASE WHEN DESABILITADO = 1 THEN @nl + N'    ALTER INDEX ' + QUOTENAME(NOME) + N' ON CI.' + QUOTENAME(OBJETO) + N' DISABLE;' ELSE N'' END
      + @nl + N'END'), @go)
      WITHIN GROUP (ORDER BY CASE OBJETO_TIPO WHEN 'U' THEN 0 ELSE 1 END, CASE TIPO WHEN 'CLUSTERED' THEN 0 ELSE 1 END, OBJETO, NOME)
FROM @INDICE WHERE OBJETO_TIPO = 'U';
SET @s += ISNULL(N'/* ── Índices ── */' + @nl + @parte + @go, N'');

/* Views, funções e procedures — na ordem de criação da PRD (quem é
   referenciado nasceu antes). As opções ANSI_NULLS/QUOTED_IDENTIFIER
   com que cada um foi criado ficam gravadas nele: vão num lote antes. */
SELECT @parte = STRING_AGG(CONVERT(NVARCHAR(MAX),
        N'SET ANSI_NULLS ' + CASE WHEN ANSI_NULLS_ = 1 THEN N'ON' ELSE N'OFF' END + N';' + @nl
      + N'SET QUOTED_IDENTIFIER ' + CASE WHEN QUOTED_ID = 1 THEN N'ON' ELSE N'OFF' END + N';' + @go
      + N'IF OBJECT_ID(N''CI.' + REPLACE(QUOTENAME(NOME), N'''', N'''''') + N''') IS NULL EXEC (N'''
      + REPLACE(DEFINICAO, N'''', N'''''') + N''');'), @go) WITHIN GROUP (ORDER BY CRIADO, NOME)
FROM @MODULO WHERE TIPO IN ('V','P','FN','IF','TF');
SET @s += ISNULL(N'/* ── Views, funções e procedures ── */' + @nl + @parte + @go
               + N'SET ANSI_NULLS ON;' + @nl + N'SET QUOTED_IDENTIFIER ON;' + @go, N'');

/* Índices de views indexadas (depois das views) */
SELECT @parte = STRING_AGG(CONVERT(NVARCHAR(MAX),
        N'IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N''CI.' + REPLACE(QUOTENAME(OBJETO), N'''', N'''''')
      + N''') AND name = N''' + REPLACE(NOME, N'''', N'''''') + N''')' + @nl
      + N'    CREATE ' + CASE WHEN UNICO = 1 THEN N'UNIQUE ' ELSE N'' END + TIPO + N' INDEX ' + QUOTENAME(NOME)
      + N' ON CI.' + QUOTENAME(OBJETO) + N' (' + COLUNAS + N')'
      + ISNULL(N' INCLUDE (' + INCLUIDAS + N')', N'') + ISNULL(N' WHERE ' + FILTRO, N'') + N' WITH (' + OPCOES + N');'), @go)
      WITHIN GROUP (ORDER BY CASE TIPO WHEN 'CLUSTERED' THEN 0 ELSE 1 END, OBJETO, NOME)
FROM @INDICE WHERE OBJETO_TIPO = 'V';
SET @s += ISNULL(N'/* ── Índices de views ── */' + @nl + @parte + @go, N'');

/* CHECKs e FKs, no mesmo estado de confiança/habilitação da PRD */
SELECT @parte = STRING_AGG(x, @go) WITHIN GROUP (ORDER BY o, t, n)
FROM (
    SELECT o = 0, t = TABELA, n = NOME, x = CONVERT(NVARCHAR(MAX),
           N'IF OBJECT_ID(N''CI.' + REPLACE(QUOTENAME(NOME), N'''', N'''''') + N''', N''C'') IS NULL' + @nl + N'BEGIN' + @nl
         + N'    ALTER TABLE CI.' + QUOTENAME(TABELA) + CASE WHEN NAO_CONFIAVEL = 1 THEN N' WITH NOCHECK' ELSE N' WITH CHECK' END
         + N' ADD CONSTRAINT ' + QUOTENAME(NOME) + N' CHECK' + CASE WHEN NAO_REPLICACAO = 1 THEN N' NOT FOR REPLICATION' ELSE N'' END
         + N' ' + DEFINICAO + N';'
         + CASE WHEN DESABILITADA = 1 THEN @nl + N'    ALTER TABLE CI.' + QUOTENAME(TABELA) + N' NOCHECK CONSTRAINT ' + QUOTENAME(NOME) + N';' ELSE N'' END
         + @nl + N'END')
    FROM @CHECK
    UNION ALL
    SELECT 1, TABELA, NOME, CONVERT(NVARCHAR(MAX),
           N'IF OBJECT_ID(N''CI.' + REPLACE(QUOTENAME(NOME), N'''', N'''''') + N''', N''F'') IS NULL' + @nl + N'BEGIN' + @nl
         + N'    ALTER TABLE CI.' + QUOTENAME(TABELA) + CASE WHEN NAO_CONFIAVEL = 1 THEN N' WITH NOCHECK' ELSE N' WITH CHECK' END
         + N' ADD CONSTRAINT ' + QUOTENAME(NOME) + N' FOREIGN KEY (' + COLUNAS + N') REFERENCES '
         + QUOTENAME(REF_ESQUEMA) + N'.' + QUOTENAME(REF_TABELA) + N' (' + REF_COLUNAS + N') ON DELETE ' + ACAO_DELETE
         + N' ON UPDATE ' + ACAO_UPDATE + CASE WHEN NAO_REPLICACAO = 1 THEN N' NOT FOR REPLICATION' ELSE N'' END + N';'
         + CASE WHEN DESABILITADA = 1 THEN @nl + N'    ALTER TABLE CI.' + QUOTENAME(TABELA) + N' NOCHECK CONSTRAINT ' + QUOTENAME(NOME) + N';' ELSE N'' END
         + @nl + N'END')
    FROM @FK) q;
SET @s += ISNULL(N'/* ── CHECKs e chaves estrangeiras ── */' + @nl + @parte + @go, N'');

/* Triggers (estado e ordem de disparo) */
SELECT @parte = STRING_AGG(CONVERT(NVARCHAR(MAX),
        N'SET ANSI_NULLS ' + CASE WHEN ANSI_NULLS_ = 1 THEN N'ON' ELSE N'OFF' END + N';' + @nl
      + N'SET QUOTED_IDENTIFIER ' + CASE WHEN QUOTED_ID = 1 THEN N'ON' ELSE N'OFF' END + N';' + @go
      + N'IF OBJECT_ID(N''CI.' + REPLACE(QUOTENAME(NOME), N'''', N'''''') + N''', N''TR'') IS NULL' + @nl + N'BEGIN' + @nl
      + N'    EXEC (N''' + REPLACE(DEFINICAO, N'''', N'''''') + N''');'
      + CASE WHEN DESABILITADO = 1
             THEN @nl + N'    DISABLE TRIGGER CI.' + QUOTENAME(NOME) + N' ON CI.' + QUOTENAME(TABELA_PAI) + N';' ELSE N'' END
      + ISNULL(@nl + REPLACE(o.ORDEM_SQL, NCHAR(1), N'CI.' + REPLACE(QUOTENAME(NOME), N'''', N'''''')), N'')
      + @nl + N'END'), @go) WITHIN GROUP (ORDER BY TABELA_PAI, NOME)
FROM @MODULO m
OUTER APPLY (SELECT ORDEM_SQL = STRING_AGG(CONVERT(NVARCHAR(MAX),
                N'    EXEC sp_settriggerorder @triggername = N''' + NCHAR(1)   -- nome entra depois: STRING_AGG não aceita m.NOME junto
              + N''', @order = N''' + PARSENAME(REPLACE(LTRIM(value), N':', N'.'), 1)
              + N''', @stmttype = N''' + PARSENAME(REPLACE(LTRIM(value), N':', N'.'), 2) + N''';'), @nl)
             FROM STRING_SPLIT(m.ORDEM_TRIGGER, N',')) o
WHERE m.TIPO = 'TR';
SET @s += ISNULL(N'/* ── Triggers ── */' + @nl + @parte + @go
               + N'SET ANSI_NULLS ON;' + @nl + N'SET QUOTED_IDENTIFIER ON;' + @go, N'');

/* Sinônimos */
SELECT @parte = STRING_AGG(CONVERT(NVARCHAR(MAX),
        N'IF OBJECT_ID(N''CI.' + REPLACE(QUOTENAME(NOME), N'''', N'''''') + N''', N''SN'') IS NULL CREATE SYNONYM CI.'
      + QUOTENAME(NOME) + N' FOR ' + BASE + N';'), @go) WITHIN GROUP (ORDER BY NOME)
FROM @SINONIMO;
SET @s += ISNULL(N'/* ── Sinônimos ── */' + @nl + @parte + @go, N'');

/* Propriedades estendidas */
SELECT @parte = STRING_AGG(CONVERT(NVARCHAR(MAX),
        N'IF NOT EXISTS (SELECT 1 FROM sys.fn_listextendedproperty(N''' + REPLACE(NOME, N'''', N'''''') + N''', N''SCHEMA'', N''CI'', N'''
      + x.N1T + N''', N''' + REPLACE(OBJETO, N'''', N'''''') + N''', '
      + ISNULL(N'N''' + NIVEL2_TIPO + N'''', N'NULL') + N', ' + ISNULL(N'N''' + REPLACE(NIVEL2, N'''', N'''''') + N'''', N'NULL') + N'))' + @nl
      + N'    EXEC sp_addextendedproperty @name = N''' + REPLACE(NOME, N'''', N'''''') + N''', @value = N'''
      + REPLACE(VALOR, N'''', N'''''') + N''', @level0type = N''SCHEMA'', @level0name = N''CI'', @level1type = N''' + x.N1T
      + N''', @level1name = N''' + REPLACE(OBJETO, N'''', N'''''') + N''''
      + ISNULL(N', @level2type = N''' + NIVEL2_TIPO + N''', @level2name = N''' + REPLACE(NIVEL2, N'''', N'''''') + N'''', N'') + N';'),
        @go) WITHIN GROUP (ORDER BY OBJETO, NIVEL2, NOME)
FROM @EXTPROP
CROSS APPLY (SELECT N1T = CASE OBJETO_TIPO WHEN 'U' THEN N'TABLE' WHEN 'V' THEN N'VIEW' WHEN 'P' THEN N'PROCEDURE'
                                           WHEN 'SO' THEN N'SEQUENCE' WHEN 'SN' THEN N'SYNONYM' ELSE N'FUNCTION' END) x;
SET @s += ISNULL(N'/* ── Propriedades estendidas ── */' + @nl + @parte + @go, N'');

/* Conferência: esperado (PRD) x criado (DEV) */
SET @s += N'/* ── Conferência: esperado x criado ── */' + @nl
    + N'SELECT OBJETO = e.OBJETO, ESPERADO = e.QTD, CRIADO = c.QTD, RESULTADO = CASE WHEN e.QTD = c.QTD THEN ''OK'' ELSE ''DIVERGE'' END' + @nl
    + N'FROM (VALUES' + @nl
    + N'    (N''Tabelas'', ' + CAST((SELECT COUNT(*) FROM @TABELA) AS NVARCHAR(10)) + N'),' + @nl
    + N'    (N''Colunas'', ' + CAST((SELECT COUNT(*) FROM @COLUNA) AS NVARCHAR(10)) + N'),' + @nl
    + N'    (N''PK e UNIQUE'', ' + CAST((SELECT COUNT(*) FROM @CHAVE) AS NVARCHAR(10)) + N'),' + @nl
    + N'    (N''Defaults'', ' + CAST((SELECT COUNT(*) FROM @COLUNA WHERE NM_DEFAULT IS NOT NULL) AS NVARCHAR(10)) + N'),' + @nl
    + N'    (N''Colunas identity'', ' + CAST((SELECT COUNT(*) FROM @COLUNA WHERE IDENTIDADE = 1) AS NVARCHAR(10)) + N'),' + @nl
    + N'    (N''Índices'', ' + CAST((SELECT COUNT(*) FROM @INDICE) AS NVARCHAR(10)) + N'),' + @nl
    + N'    (N''CHECKs'', ' + CAST((SELECT COUNT(*) FROM @CHECK) AS NVARCHAR(10)) + N'),' + @nl
    + N'    (N''Chaves estrangeiras'', ' + CAST((SELECT COUNT(*) FROM @FK) AS NVARCHAR(10)) + N'),' + @nl
    + N'    (N''FKs confiáveis'', ' + CAST((SELECT COUNT(*) FROM @FK WHERE NAO_CONFIAVEL = 0) AS NVARCHAR(10)) + N'),' + @nl
    + N'    (N''Views, funções e procedures'', ' + CAST((SELECT COUNT(*) FROM @MODULO WHERE TIPO IN ('V','P','FN','IF','TF')) AS NVARCHAR(10)) + N'),' + @nl
    + N'    (N''Triggers'', ' + CAST((SELECT COUNT(*) FROM @MODULO WHERE TIPO = 'TR') AS NVARCHAR(10)) + N'),' + @nl
    + N'    (N''Sequences'', ' + CAST((SELECT COUNT(*) FROM @SEQUENCIA) AS NVARCHAR(10)) + N'),' + @nl
    + N'    (N''Sinônimos'', ' + CAST((SELECT COUNT(*) FROM @SINONIMO) AS NVARCHAR(10)) + N'),' + @nl
    + N'    (N''Propriedades estendidas'', ' + CAST((SELECT COUNT(*) FROM @EXTPROP) AS NVARCHAR(10)) + N')' + @nl
    + N') e (OBJETO, QTD)' + @nl
    + N'JOIN (' + @nl
    + N'    SELECT N''Tabelas'', COUNT(*) FROM sys.tables WHERE schema_id = SCHEMA_ID(N''CI'')' + @nl
    + N'    UNION ALL SELECT N''Colunas'', COUNT(*) FROM sys.columns c JOIN sys.tables t ON t.object_id = c.object_id WHERE t.schema_id = SCHEMA_ID(N''CI'')' + @nl
    + N'    UNION ALL SELECT N''PK e UNIQUE'', COUNT(*) FROM sys.key_constraints k JOIN sys.tables t ON t.object_id = k.parent_object_id WHERE t.schema_id = SCHEMA_ID(N''CI'')' + @nl
    + N'    UNION ALL SELECT N''Defaults'', COUNT(*) FROM sys.default_constraints d JOIN sys.tables t ON t.object_id = d.parent_object_id WHERE t.schema_id = SCHEMA_ID(N''CI'')' + @nl
    + N'    UNION ALL SELECT N''Colunas identity'', COUNT(*) FROM sys.identity_columns i JOIN sys.tables t ON t.object_id = i.object_id WHERE t.schema_id = SCHEMA_ID(N''CI'')' + @nl
    + N'    UNION ALL SELECT N''Índices'', COUNT(*) FROM sys.indexes i JOIN sys.objects o ON o.object_id = i.object_id WHERE o.schema_id = SCHEMA_ID(N''CI'') AND o.type IN (''U'',''V'') AND i.type IN (1,2) AND i.is_primary_key = 0 AND i.is_unique_constraint = 0 AND i.is_hypothetical = 0' + @nl
    + N'    UNION ALL SELECT N''CHECKs'', COUNT(*) FROM sys.check_constraints c JOIN sys.tables t ON t.object_id = c.parent_object_id WHERE t.schema_id = SCHEMA_ID(N''CI'')' + @nl
    + N'    UNION ALL SELECT N''Chaves estrangeiras'', COUNT(*) FROM sys.foreign_keys f JOIN sys.tables t ON t.object_id = f.parent_object_id WHERE t.schema_id = SCHEMA_ID(N''CI'')' + @nl
    + N'    UNION ALL SELECT N''FKs confiáveis'', COUNT(*) FROM sys.foreign_keys f JOIN sys.tables t ON t.object_id = f.parent_object_id WHERE t.schema_id = SCHEMA_ID(N''CI'') AND f.is_not_trusted = 0' + @nl
    + N'    UNION ALL SELECT N''Views, funções e procedures'', COUNT(*) FROM sys.objects WHERE schema_id = SCHEMA_ID(N''CI'') AND type IN (''V'',''P'',''FN'',''IF'',''TF'')' + @nl
    + N'    UNION ALL SELECT N''Triggers'', COUNT(*) FROM sys.objects WHERE schema_id = SCHEMA_ID(N''CI'') AND type = ''TR''' + @nl
    + N'    UNION ALL SELECT N''Sequences'', COUNT(*) FROM sys.sequences WHERE schema_id = SCHEMA_ID(N''CI'')' + @nl
    + N'    UNION ALL SELECT N''Sinônimos'', COUNT(*) FROM sys.synonyms WHERE schema_id = SCHEMA_ID(N''CI'')' + @nl
    + N'    UNION ALL SELECT N''Propriedades estendidas'', COUNT(*) FROM sys.extended_properties ep JOIN sys.objects o ON o.object_id = ep.major_id WHERE ep.class IN (1, 7) AND o.schema_id = SCHEMA_ID(N''CI'')' + @nl
    + N') c (OBJETO, QTD) ON c.OBJETO = e.OBJETO;' + @go
    + N'SET NOEXEC OFF;' + @go;

/* Dependências fora do CI: avisadas no topo do script gerado */
DECLARE @avisos NVARCHAR(MAX) = (SELECT STRING_AGG(CONVERT(NVARCHAR(MAX), N'   - ' + TIPO + N': ' + OBJETO_FORA + N' / CI.' + OBJETO_CI + N' (' + DETALHE + N')'), @nl) FROM @DEPEXT);
IF @avisos IS NOT NULL
    SET @s = STUFF(@s, CHARINDEX(N'   =====================================================================', @s, 10), 0,
                   N'   Dependências fora do schema CI (não criadas por este script):' + @nl + REPLACE(@avisos, N'*/', N'* /') + @nl);

/* ── Saída: aba Mensagens, em blocos de até 4000 caracteres ─────────────
   PRINT corta em 4000 e sempre acrescenta quebra de linha: cada bloco
   termina numa quebra de linha original, então o texto sai idêntico. */
DECLARE @pos INT = 1, @tam INT = DATALENGTH(@s) / 2, @corte INT, @trecho NVARCHAR(MAX), @longas INT = 0;
WHILE @pos <= @tam
BEGIN
    SET @trecho = SUBSTRING(@s, @pos, 4000);
    IF @pos + 4000 > @tam
        SET @corte = DATALENGTH(@trecho) / 2;
    ELSE
    BEGIN
        SET @corte = 4000 - CHARINDEX(NCHAR(10), REVERSE(@trecho)) + 1;   -- até o último LF do bloco
        IF @corte > 4000 BEGIN SET @corte = 4000; SET @longas += 1; END    -- linha com mais de 4000 caracteres
    END
    SET @trecho = SUBSTRING(@s, @pos, @corte);
    -- a quebra final do bloco vira a do próprio PRINT
    IF RIGHT(@trecho, 1) = NCHAR(10) SET @trecho = LEFT(@trecho, DATALENGTH(@trecho) / 2 - 1);
    IF RIGHT(@trecho, 1) = NCHAR(13) SET @trecho = LEFT(@trecho, DATALENGTH(@trecho) / 2 - 1);
    PRINT @trecho;
    SET @pos += @corte;
END

SELECT GERADO_DE = @origem, TABELAS = (SELECT COUNT(*) FROM @TABELA), FKS = (SELECT COUNT(*) FROM @FK),
       TAMANHO_CARACTERES = @tam,
       ATENCAO = CASE WHEN @longas > 0 THEN N'Há linha com mais de 4000 caracteres: foi quebrada na saída — revise o script gerado.'
                      ELSE N'Script completo na aba Mensagens.' END;
GO
