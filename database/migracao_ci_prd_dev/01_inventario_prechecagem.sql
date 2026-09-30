/* =====================================================================
   01 - INVENTÁRIO E PRÉ-CHECAGEM  (conectado ao BDIBPBMSA_DEV)
   ---------------------------------------------------------------------
   Só lê. Captura o catálogo do schema CI na PRD e no DEV, confere a
   lista de tabelas contempladas, bloqueios e dependências fora do CI, e
   calcula a ordem de carga pelas FKs. O 02 recusa rodar se houver FALHA.
   ===================================================================== */

SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @ini INT = ISNULL((SELECT MAX(ID) FROM MIG.EVIDENCIA), 0);
DECLARE @recriar BIT = (SELECT RECRIAR FROM MIG.PARAMETRO);
DECLARE @d NVARCHAR(MAX), @n INT;

EXEC MIG.SP_SNAPSHOT 'PRD';
EXEC MIG.SP_SNAPSHOT 'DEV';

/* ── Banco ─────────────────────────────────────────────────────────── */
DECLARE @r VARCHAR(10);
SELECT @d = N'PRD: ' + p.COLLATION_ + N' / compat ' + CAST(p.COMPAT AS NVARCHAR(10))
          + N' | DEV: ' + d.COLLATION_ + N' / compat ' + CAST(d.COMPAT AS NVARCHAR(10))
          + CASE WHEN p.COLLATION_ = d.COLLATION_ AND p.COMPAT = d.COMPAT THEN N''
                 ELSE N' — colunas recebem a collation explícita da PRD; variáveis e #temp dos módulos usam a do DEV.' END,
       @r = CASE WHEN p.COLLATION_ = d.COLLATION_ AND p.COMPAT = d.COMPAT THEN 'OK' ELSE 'AVISO' END
FROM MIG.CAT_BANCO p CROSS JOIN MIG.CAT_BANCO d WHERE p.ORIGEM = 'PRD' AND d.ORIGEM = 'DEV';
EXEC MIG.SP_EVIDENCIA '01', N'Collation e nível de compatibilidade', @r, @d;

/* ── Tabelas contempladas x existentes na PRD ─────────────────────── */
DECLARE @lista TABLE (TABELA SYSNAME PRIMARY KEY);
INSERT @lista VALUES
    (N'KZN_HIST_APROVADOR'), (N'KZN_ADMIN'), (N'KZN_ANALISE_DUPLICIDADE'), (N'KZN_APROVADOR'), (N'KZN_CATEGORIA'),
    (N'KZN_DESPERDICIO'), (N'KZN_HIST_KAIZEN_DESPERDICIO'), (N'KZN_HIST_KAIZEN_HIERARQUIA'), (N'KZN_HIST_MDM_VBM_TERC'),
    (N'KZN_HIST_MEMBROS_EQUIPE'), (N'KZN_HIST_PEDRAVISAOCONSOLIDADA'), (N'KZN_HIST_RESULTADO_KAIZEN'), (N'KZN_IDIOMA'),
    (N'KZN_KAIZEN_DESPERDICIO'), (N'KZN_KAIZEN_HIERARQUIA'), (N'KZN_LOG_PEDRAVISAOCONSOLIDADA'),
    (N'KZN_LOG_PEDRAVISAOCONSOLIDADA_DETALHE'), (N'KZN_MDM_HIERARQUIA'), (N'KZN_MDM_TEMP'), (N'KZN_MDM_TERCEIROS_TEMP'),
    (N'KZN_MEMBROS_EQUIPE'), (N'KZN_MOEDA'), (N'KZN_PEDRAVISAOCONSOLIDADA'), (N'KZN_REPLICACAO'), (N'KZN_RESULTADO_KAIZEN'),
    (N'KZN_RESULTADOS'), (N'KZN_STATUS'), (N'KZN_TB_NOTIFICACAO_TESTE'), (N'KZN_TIPO_KAIZEN'), (N'KZN_TIPO_RESULTADO'),
    (N'KZN_TIPO_USUARIO');

INSERT MIG.EVIDENCIA (ETAPA, ITEM, RESULTADO, DETALHE)
SELECT '01', N'Tabela contemplada ausente na PRD: ' + l.TABELA, 'AVISO', N'Listada na tarefa, não existe no schema CI da PRD.'
FROM @lista l WHERE NOT EXISTS (SELECT 1 FROM MIG.CAT_TABELA t WHERE t.ORIGEM = 'PRD' AND t.TABELA = l.TABELA);

INSERT MIG.EVIDENCIA (ETAPA, ITEM, RESULTADO, DETALHE)
SELECT '01', N'Tabela da PRD não listada: ' + t.TABELA, 'AVISO', N'Dependência adicional: será migrada com o schema.'
FROM MIG.CAT_TABELA t WHERE t.ORIGEM = 'PRD' AND NOT EXISTS (SELECT 1 FROM @lista l WHERE l.TABELA = t.TABELA);

SELECT @n = COUNT(*) FROM MIG.CAT_TABELA WHERE ORIGEM = 'PRD';
SELECT @d = CAST(@n AS NVARCHAR(10)) + N' tabela(s) no CI da PRD; '
          + CAST((SELECT COUNT(*) FROM @lista l WHERE EXISTS (SELECT 1 FROM MIG.CAT_TABELA t WHERE t.ORIGEM = 'PRD' AND t.TABELA = l.TABELA)) AS NVARCHAR(10))
          + N' de ' + CAST((SELECT COUNT(*) FROM @lista) AS NVARCHAR(10)) + N' contempladas encontradas. Outros objetos: '
          + (SELECT STRING_AGG(x, N', ') FROM (
                SELECT CAST(COUNT(*) AS NVARCHAR(10)) + N' módulo(s)' AS x FROM MIG.CAT_MODULO WHERE ORIGEM = 'PRD'
                UNION ALL SELECT CAST(COUNT(*) AS NVARCHAR(10)) + N' sequence(s)' FROM MIG.CAT_SEQUENCIA WHERE ORIGEM = 'PRD'
                UNION ALL SELECT CAST(COUNT(*) AS NVARCHAR(10)) + N' sinônimo(s)' FROM MIG.CAT_SINONIMO WHERE ORIGEM = 'PRD'
                UNION ALL SELECT CAST(COUNT(*) AS NVARCHAR(10)) + N' FK(s)' FROM MIG.CAT_FK WHERE ORIGEM = 'PRD'
                UNION ALL SELECT CAST(COUNT(*) AS NVARCHAR(10)) + N' índice(s)' FROM MIG.CAT_INDICE WHERE ORIGEM = 'PRD') s);
EXEC MIG.SP_EVIDENCIA '01', N'Inventário do schema CI na PRD', 'OK', @d;

/* ── Recursos que o gerador não reproduz fielmente ────────────────── */
INSERT MIG.EVIDENCIA (ETAPA, ITEM, RESULTADO, DETALHE)
SELECT '01', N'Recurso não suportado: CI.' + TABELA, 'FALHA', NAO_SUPORTADO
FROM MIG.CAT_TABELA WHERE ORIGEM = 'PRD' AND NAO_SUPORTADO IS NOT NULL;

INSERT MIG.EVIDENCIA (ETAPA, ITEM, RESULTADO, DETALHE)
SELECT '01', N'Módulo não reproduzível: CI.' + NOME, 'FALHA',
       CASE WHEN TIPO IN ('R','D') THEN N'regra/default legado (CREATE RULE/DEFAULT)'
            WHEN TIPO IN ('PC','FS','FT','TA') THEN N'objeto CLR'
            ELSE N'definição indisponível (WITH ENCRYPTION)' END
FROM MIG.CAT_MODULO WHERE ORIGEM = 'PRD' AND (TIPO IN ('R','D','PC','FS','FT','TA') OR DEFINICAO IS NULL);

/* ── Leitura completa dos dados pela credencial da migração ───────── */
DECLARE @perm TABLE (UNMASK_ INT, RLS INT, MASCARADAS INT, DEPENDENCIAS INT, SHARD NVARCHAR(500));
INSERT @perm EXEC MIG.SP_EXEC_ORIGEM N'SELECT UNMASK_ = CASE WHEN ISNULL(HAS_PERMS_BY_NAME(DB_NAME(), ''DATABASE'', ''UNMASK''), 0) = 1
                         OR ISNULL(HAS_PERMS_BY_NAME(N''CI'', ''SCHEMA'', ''UNMASK''), 0) = 1 THEN 1 ELSE 0 END,
    RLS = (SELECT COUNT(*) FROM sys.security_predicates sp JOIN sys.objects o ON o.object_id = sp.target_object_id
           JOIN sys.security_policies pol ON pol.object_id = sp.object_id
           WHERE o.schema_id = SCHEMA_ID(N''CI'') AND pol.is_enabled = 1),
    MASCARADAS = (SELECT COUNT(*) FROM sys.masked_columns mc JOIN sys.objects o ON o.object_id = mc.object_id
                  WHERE o.schema_id = SCHEMA_ID(N''CI'')),
    DEPENDENCIAS = ISNULL(HAS_PERMS_BY_NAME(N''sys.sql_expression_dependencies'', ''OBJECT'', ''SELECT''), 0)';
INSERT MIG.EVIDENCIA (ETAPA, ITEM, RESULTADO, DETALHE)
SELECT '01', N'Máscara dinâmica (DDM) na PRD', CASE WHEN MASCARADAS > 0 AND UNMASK_ = 0 THEN 'FALHA' ELSE 'OK' END,
       CAST(MASCARADAS AS NVARCHAR(10)) + N' coluna(s) mascarada(s); UNMASK para a credencial: '
       + CASE WHEN UNMASK_ = 1 THEN N'sim' ELSE N'não' END
       + CASE WHEN MASCARADAS > 0 AND UNMASK_ = 0 THEN N' — sem UNMASK o dado copiado seria o mascarado.' ELSE N'' END
FROM @perm
UNION ALL
SELECT '01', N'Row-Level Security na PRD', CASE WHEN RLS > 0 THEN 'FALHA' ELSE 'OK' END,
       CAST(RLS AS NVARCHAR(10)) + N' predicado(s) ativo(s) em tabelas CI'
       + CASE WHEN RLS > 0 THEN N' — a leitura pela credencial pode vir filtrada.' ELSE N'' END
FROM @perm
UNION ALL
SELECT '01', N'Visibilidade de dependências na PRD', CASE WHEN DEPENDENCIAS = 1 THEN 'OK' ELSE 'FALHA' END,
       CASE WHEN DEPENDENCIAS = 1 THEN N'A credencial lê sys.sql_expression_dependencies.'
            ELSE N'A credencial não lê sys.sql_expression_dependencies: o mapeamento de dependências viria vazio. Rode o 00a.' END
FROM @perm;

/* ── Dependências que cruzam o schema CI ──────────────────────────── */
INSERT MIG.EVIDENCIA (ETAPA, ITEM, RESULTADO, DETALHE)
SELECT '01', N'Dependência: ' + x.TIPO + N' ' + x.OBJETO_FORA,
       CASE WHEN x.TIPO = N'FK de CI -> fora' AND OBJECT_ID(x.OBJETO_FORA, 'U') IS NULL THEN 'FALHA'
            WHEN x.TIPO = N'Modulo de CI -> fora' AND OBJECT_ID(x.OBJETO_FORA) IS NULL THEN 'AVISO'
            WHEN x.TIPO LIKE N'%de fora -> CI%' THEN 'AVISO'
            ELSE 'OK' END,
       N'CI.' + x.OBJETO_CI + N' (' + x.DETALHE + N')'
       + CASE WHEN x.TIPO = N'FK de CI -> fora' AND OBJECT_ID(x.OBJETO_FORA, 'U') IS NULL
              THEN N' — tabela referenciada não existe no DEV; a FK não pode ser criada.'
              WHEN x.TIPO = N'Modulo de CI -> fora' AND OBJECT_ID(x.OBJETO_FORA) IS NULL
              THEN N' — objeto referenciado não existe no DEV; o módulo pode falhar na criação.'
              WHEN x.TIPO LIKE N'%de fora -> CI%'
              THEN N' — objeto de OUTRO schema: mapeado, não migrado (fora do escopo CI).'
              ELSE N'' END
FROM MIG.CAT_DEPEXT x WHERE x.ORIGEM = 'PRD';

/* ── Estado do DEV ─────────────────────────────────────────────────── */
SELECT @d = STRING_AGG(o, N', ')
FROM (SELECT N'tabela ' + TABELA AS o FROM MIG.CAT_TABELA WHERE ORIGEM = 'DEV'
      UNION ALL SELECT N'módulo ' + NOME FROM MIG.CAT_MODULO WHERE ORIGEM = 'DEV' AND TIPO <> 'TR'
      UNION ALL SELECT N'sequence ' + NOME FROM MIG.CAT_SEQUENCIA WHERE ORIGEM = 'DEV'
      UNION ALL SELECT N'sinônimo ' + NOME FROM MIG.CAT_SINONIMO WHERE ORIGEM = 'DEV') x;
IF @d IS NULL
    EXEC MIG.SP_EVIDENCIA '01', N'Schema CI no DEV', 'OK', N'Vazio — pronto para receber a estrutura.';
ELSE IF @recriar = 1
    EXEC MIG.SP_EVIDENCIA '01', N'Schema CI no DEV', 'AVISO', N'@RECRIAR = 1: serão APAGADOS no 02: ';
ELSE
    EXEC MIG.SP_EVIDENCIA '01', N'Schema CI no DEV', 'FALHA', N'Já existem objetos (troque @RECRIAR para 1 no 00 para recriar): ';
UPDATE MIG.EVIDENCIA SET DETALHE = DETALHE + ISNULL(@d, N'') WHERE ID = (SELECT MAX(ID) FROM MIG.EVIDENCIA) AND @d IS NOT NULL;

INSERT MIG.EVIDENCIA (ETAPA, ITEM, RESULTADO, DETALHE)
SELECT '01', N'DEV: ' + x.TIPO + N' ' + x.OBJETO_FORA, 'FALHA',
       N'Impede apagar CI.' + x.OBJETO_CI + N' no DEV sem alterar outro schema. Remova/ajuste esse objeto antes.'
FROM MIG.CAT_DEPEXT x
WHERE x.ORIGEM = 'DEV' AND @d IS NOT NULL
  AND (x.TIPO = N'FK de fora -> CI' OR x.TIPO = N'Modulo de fora -> CI (SCHEMABINDING)');

/* ── Permissões (não migradas: principais diferem entre ambientes) ── */
SELECT @n = COUNT(*), @d = STRING_AGG(ESTADO + N' ' + PERMISSAO + N' ON ' + OBJETO + N' TO ' + PRINCIPAL, N'; ')
FROM MIG.CAT_PERMISSAO WHERE ORIGEM = 'PRD';
EXEC MIG.SP_EVIDENCIA '01', N'Permissões em CI na PRD (mapeadas, não migradas)', 'OK', @d;
UPDATE MIG.EVIDENCIA SET RESULTADO = CASE WHEN @n > 0 THEN 'AVISO' ELSE 'OK' END,
       DETALHE = CASE WHEN @n > 0 THEN CAST(@n AS NVARCHAR(10)) + N': ' + DETALHE ELSE N'Nenhuma permissão explícita.' END
WHERE ID = (SELECT MAX(ID) FROM MIG.EVIDENCIA);

/* ── Ordem de carga pelas FKs entre tabelas CI ────────────────────────
   Nível 0: não depende de outra tabela CI. Nível n: todas as tabelas de
   que depende já têm nível. Sobra = ciclo (ex.: MDM <-> TIPO_USUARIO):
   recebe o próximo nível. As FKs só são criadas DEPOIS da carga (04),
   então o ciclo não bloqueia, e a criação WITH CHECK prova a integridade. */
IF OBJECT_ID('MIG.ORDEM_CARGA') IS NULL
    CREATE TABLE MIG.ORDEM_CARGA (TABELA SYSNAME PRIMARY KEY, NIVEL INT NOT NULL, ORDEM INT NULL, EM_CICLO BIT NOT NULL);
DELETE MIG.ORDEM_CARGA;

DECLARE @dep TABLE (TABELA SYSNAME, DEPENDE SYSNAME);
INSERT @dep SELECT DISTINCT TABELA, REF_TABELA FROM MIG.CAT_FK
WHERE ORIGEM = 'PRD' AND REF_ESQUEMA = N'CI' AND REF_TABELA <> TABELA;

DECLARE @nivel INT = 0, @novos INT = 1;
WHILE EXISTS (SELECT 1 FROM MIG.CAT_TABELA t WHERE t.ORIGEM = 'PRD'
              AND NOT EXISTS (SELECT 1 FROM MIG.ORDEM_CARGA o WHERE o.TABELA = t.TABELA))
BEGIN
    INSERT MIG.ORDEM_CARGA (TABELA, NIVEL, EM_CICLO)
    SELECT t.TABELA, @nivel, 0 FROM MIG.CAT_TABELA t
    WHERE t.ORIGEM = 'PRD' AND NOT EXISTS (SELECT 1 FROM MIG.ORDEM_CARGA o WHERE o.TABELA = t.TABELA)
      AND NOT EXISTS (SELECT 1 FROM @dep d WHERE d.TABELA = t.TABELA
                      AND NOT EXISTS (SELECT 1 FROM MIG.ORDEM_CARGA o WHERE o.TABELA = d.DEPENDE));
    SET @novos = @@ROWCOUNT;
    IF @novos = 0
    BEGIN
        /* Travou: há ciclo. Fecho transitivo das dependências entre as
           tabelas que sobraram; está em ciclo quem alcança a si mesma.
           Só essas entram neste nível — as que apenas DEPENDEM do ciclo
           continuam esperando a vez delas. */
        DECLARE @alc TABLE (DE SYSNAME, PARA SYSNAME, PRIMARY KEY (DE, PARA));
        DELETE @alc;
        INSERT @alc SELECT DISTINCT d.TABELA, d.DEPENDE FROM @dep d
        WHERE NOT EXISTS (SELECT 1 FROM MIG.ORDEM_CARGA o WHERE o.TABELA = d.TABELA)
          AND NOT EXISTS (SELECT 1 FROM MIG.ORDEM_CARGA o WHERE o.TABELA = d.DEPENDE);
        WHILE @@ROWCOUNT > 0
            INSERT @alc SELECT DISTINCT a.DE, b.PARA FROM @alc a JOIN @alc b ON b.DE = a.PARA
            WHERE NOT EXISTS (SELECT 1 FROM @alc x WHERE x.DE = a.DE AND x.PARA = b.PARA);
        INSERT MIG.ORDEM_CARGA (TABELA, NIVEL, EM_CICLO)
        SELECT DISTINCT a.DE, @nivel, 1 FROM @alc a WHERE a.DE = a.PARA;
    END
    SET @nivel += 1;
END
UPDATE o SET ORDEM = x.RN FROM MIG.ORDEM_CARGA o
JOIN (SELECT TABELA, RN = ROW_NUMBER() OVER (ORDER BY NIVEL, TABELA) FROM MIG.ORDEM_CARGA) x ON x.TABELA = o.TABELA;

SELECT @d = STRING_AGG(TABELA, N', ') WITHIN GROUP (ORDER BY TABELA) FROM MIG.ORDEM_CARGA WHERE EM_CICLO = 1;
EXEC MIG.SP_EVIDENCIA '01', N'Ordem de carga pelas FKs', 'OK', N'Calculada em MIG.ORDEM_CARGA.';
IF @d IS NOT NULL
    UPDATE MIG.EVIDENCIA SET RESULTADO = 'AVISO',
        DETALHE = N'Ciclo de FKs entre: ' + @d + N'. Carga sem FKs ativas e FKs criadas WITH CHECK depois (04).'
    WHERE ID = (SELECT MAX(ID) FROM MIG.EVIDENCIA);

/* ── Resultado ─────────────────────────────────────────────────────── */
SELECT ETAPA, RESULTADO, ITEM, DETALHE FROM MIG.EVIDENCIA WHERE ID > @ini
ORDER BY CASE RESULTADO WHEN 'FALHA' THEN 0 WHEN 'AVISO' THEN 1 ELSE 2 END, ID;

SELECT o.ORDEM, o.NIVEL, o.TABELA, EM_CICLO = CASE WHEN o.EM_CICLO = 1 THEN 'SIM' ELSE '' END,
       LINHAS_PRD_CATALOGO = t.LINHAS_CATALOGO
FROM MIG.ORDEM_CARGA o JOIN MIG.CAT_TABELA t ON t.ORIGEM = 'PRD' AND t.TABELA = o.TABELA
ORDER BY o.ORDEM;

SELECT PRECHECAGEM = CASE WHEN EXISTS (SELECT 1 FROM MIG.EVIDENCIA WHERE ID > @ini AND RESULTADO = 'FALHA')
                          THEN 'REPROVADA — corrija as FALHAS antes do 02' ELSE 'APROVADA' END;
GO
