/* =====================================================================
   Carga do historico nas tabelas KZN_HIST_* — 16 Kaizens (7281 a 7296)
   Fonte: c6b43f9f-Extracao_Kaizen_2026_FINAL_IMPORTE.xlsx, apenas as guias
   KZN_HIST_*. Valores literais: sem dependencia de arquivo externo.

   Volume: 16 Kaizens, 29 membros, 15 resultados, 16 hierarquias,
   25 desperdicios. Auxiliares filtradas pela lista exata de Kaizens da
   guia principal, nao pela faixa (os IDs nao sao contiguos).

   ---------------------------------------------------------------------
   1) '#N/A' NAS COLUNAS DE ID (erro de VLOOKUP na planilha)

   ID_USUARIO_CADASTRO, ID_USUARIO_LIDER, ID_APROVADOR e
   ID_USUARIO_ATUALIZACAO podem trazer '#N/A'. Entram no staging como
   texto e sao convertidos por TRY_CONVERT: '#N/A' vira NULL.

   Em ID_APROVADOR (coluna NULL-avel) isso e aceitavel. Nas outras tres,
   que sao NOT NULL, o NULL derrubaria a carga: a E1b detecta e ABORTA
   listando as linhas. Para carregar o resto sem corrigir a origem,
   troque @PULAR_INVALIDAS para 1 — as linhas problematicas (e suas
   auxiliares) ficam de fora e sao listadas.

   Nesta faixa: nenhum '#N/A' — a E1b nao deve disparar.

   2) TRUNCAMENTO

   A E0.1 compara o tamanho DECLARADO de cada coluna com o exigido pelo
   dado desta faixa e ABORTA listando as que nao comportam — o INSERT so
   avisa com Msg 8152 se ANSI_WARNINGS estiver ligado; desligado, corta
   em silencio.

   2b) COLUNA NOT NULL QUE ESTA CARGA NAO PREENCHE

   criar_tabelas_hist.sql copia tipo e nulidade da tabela de producao, mas
   nao copia constraint DEFAULT. A E0.2 lista qualquer coluna NOT NULL sem
   DEFAULT fora do INSERT e aborta antes de gravar nada — caso tipico:
   SG_GM e ID_TIPO_KAIZEN, resolvidos por alinhar_hist_com_pvc_campos_gm.sql.

   3) ID_REPLICACAO vem como texto e e resolvido por lookup em
   CI.KZN_REPLICACAO; o que nao casar entra NULL e e listado na E7.

   Colunas de texto sao emitidas SEMPRE como literal string: num VALUES
   multi-linha o int tem precedencia sobre o nvarchar, e uma coluna com
   valores mistos faria o SQL Server tentar converter o texto para int.

   ---------------------------------------------------------------------
   A coluna de data da principal e resolvida em tempo de execucao:
   DT_CRIACAO se o renomear_dt_atualizacao_hist.sql ja rodou, senao
   DT_ATUALIZACAO.

   Idempotente (aborta se ja houver Kaizen na faixa). Transacionado.
   So escreve em CI.KZN_HIST_*. Schema: 'ci'.
   ===================================================================== */

SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @PULAR_INVALIDAS BIT = 0;   -- 1 = exclui linhas sem ID obrigatorio em vez de abortar
DECLARE @dtCol SYSNAME, @sql NVARCHAR(MAX), @qt INT;

/* =====================================================================
   E0 - PRE-CHECAGENS
   ===================================================================== */
DECLARE @tabs TABLE (TABELA SYSNAME PRIMARY KEY);
INSERT INTO @tabs (TABELA) VALUES
    (N'KZN_HIST_PEDRAVISAOCONSOLIDADA'), (N'KZN_HIST_MEMBROS_EQUIPE'),
    (N'KZN_HIST_RESULTADO_KAIZEN'),      (N'KZN_HIST_KAIZEN_HIERARQUIA'),
    (N'KZN_HIST_KAIZEN_DESPERDICIO');

IF EXISTS (SELECT 1 FROM @tabs WHERE OBJECT_ID('CI.' + TABELA, 'U') IS NULL)
BEGIN
    SELECT TABELA_AUSENTE = TABELA FROM @tabs WHERE OBJECT_ID('CI.' + TABELA, 'U') IS NULL;
    RAISERROR('Abortado: falta ao menos uma tabela CI.KZN_HIST_* (lista acima). Rode criar_tabelas_hist.sql antes.', 16, 1);
    RETURN;
END

IF EXISTS (SELECT 1 FROM CI.KZN_HIST_PEDRAVISAOCONSOLIDADA WHERE ID_KAIZEN BETWEEN 7281 AND 7296)
BEGIN
    RAISERROR('Abortado: ja existem Kaizens na faixa 7281-7296. Use apagar_dados_hist.sql antes de recarregar.', 16, 1);
    RETURN;
END

/* ---------------------------------------------------------------------
   E0.1 - TRUNCAMENTO: tamanho declarado x tamanho exigido por esta carga
   --------------------------------------------------------------------- */
DECLARE @req TABLE (TABELA SYSNAME, COLUNA SYSNAME, TAM_NECESSARIO INT);
INSERT INTO @req (TABELA, COLUNA, TAM_NECESSARIO) VALUES
    (N'KZN_HIST_PEDRAVISAOCONSOLIDADA', N'NM_KAIZEN', 51),
    (N'KZN_HIST_PEDRAVISAOCONSOLIDADA', N'DS_PROBLEMA', 378),
    (N'KZN_HIST_PEDRAVISAOCONSOLIDADA', N'DS_OBJETIVO', 429),
    (N'KZN_HIST_PEDRAVISAOCONSOLIDADA', N'URL_IMG_ANTES', 33),
    (N'KZN_HIST_PEDRAVISAOCONSOLIDADA', N'DS_ESTADO_ANTES', 527),
    (N'KZN_HIST_PEDRAVISAOCONSOLIDADA', N'URL_IMG_DEPOIS', 34),
    (N'KZN_HIST_PEDRAVISAOCONSOLIDADA', N'DS_ESTADO_DEPOIS', 705),
    (N'KZN_HIST_PEDRAVISAOCONSOLIDADA', N'DS_COMPARA_META', 473),
    (N'KZN_HIST_PEDRAVISAOCONSOLIDADA', N'DS_LICOES_APRENDIDAS', 347),
    (N'KZN_HIST_PEDRAVISAOCONSOLIDADA', N'DS_RESULTADO_ALCANCADO', 395),
    (N'KZN_HIST_KAIZEN_HIERARQUIA', N'NM_HIERARQUIA_N1', 35),
    (N'KZN_HIST_KAIZEN_HIERARQUIA', N'NM_HIERARQUIA_N2', 38),
    (N'KZN_HIST_KAIZEN_HIERARQUIA', N'NM_HIERARQUIA_N3', 56),
    (N'KZN_HIST_KAIZEN_HIERARQUIA', N'NM_HIERARQUIA_N4', 63),
    (N'KZN_HIST_KAIZEN_HIERARQUIA', N'NM_HIERARQUIA_N5', 70),
    (N'KZN_HIST_KAIZEN_HIERARQUIA', N'NM_HIERARQUIA_N6', 55),
    (N'KZN_HIST_KAIZEN_HIERARQUIA', N'NM_HIERARQUIA_N7', 60),
    (N'KZN_HIST_KAIZEN_HIERARQUIA', N'NM_HIERARQUIA_N8', 61);

/* max_length vem em BYTES: NVARCHAR gasta 2 por caractere, VARCHAR 1. */
IF EXISTS (SELECT 1 FROM @req r
           JOIN sys.columns c ON c.object_id = OBJECT_ID('CI.' + r.TABELA)
                             AND c.name COLLATE DATABASE_DEFAULT = r.COLUNA COLLATE DATABASE_DEFAULT
           JOIN sys.types ty ON ty.user_type_id = c.user_type_id
           WHERE c.max_length <> -1
             AND c.max_length / CASE WHEN ty.name IN ('nvarchar','nchar') THEN 2 ELSE 1 END < r.TAM_NECESSARIO)
BEGIN
    SELECT  TABELA = r.TABELA, COLUNA = c.name,
            TAM_DECLARADO  = c.max_length / CASE WHEN ty.name IN ('nvarchar','nchar') THEN 2 ELSE 1 END,
            TAM_NECESSARIO = r.TAM_NECESSARIO
    FROM    @req r
    JOIN    sys.columns c ON c.object_id = OBJECT_ID('CI.' + r.TABELA)
                         AND c.name COLLATE DATABASE_DEFAULT = r.COLUNA COLLATE DATABASE_DEFAULT
    JOIN    sys.types ty ON ty.user_type_id = c.user_type_id
    WHERE   c.max_length <> -1
      AND   c.max_length / CASE WHEN ty.name IN ('nvarchar','nchar') THEN 2 ELSE 1 END < r.TAM_NECESSARIO
    ORDER BY r.TABELA, c.name;
    RAISERROR('Abortado: ha coluna menor que o dado desta carga (lista acima). Amplie-a ou recrie as HIST com @TAM_TEXTO = -1 (MAX).', 16, 1);
    RETURN;
END

SET @dtCol = CASE WHEN COL_LENGTH('CI.KZN_HIST_PEDRAVISAOCONSOLIDADA','DT_CRIACAO') IS NOT NULL
                  THEN 'DT_CRIACAO' ELSE 'DT_ATUALIZACAO' END;
PRINT 'E0 - coluna de data da principal: ' + @dtCol;

IF EXISTS (SELECT 1 FROM sys.columns
           WHERE object_id = OBJECT_ID('CI.KZN_HIST_PEDRAVISAOCONSOLIDADA')
             AND name = 'ID_CATEGORIA' AND is_nullable = 0)
BEGIN
    RAISERROR('Abortado: ID_CATEGORIA e NOT NULL mas vem vazia em 16 das 16 linhas. Rode relaxar_not_null_hist.sql antes.', 16, 1);
    RETURN;
END

/* ---------------------------------------------------------------------
   E0.2 - NOT NULL sem DEFAULT que esta carga NAO preenche
   --------------------------------------------------------------------- */
DECLARE @carregadas TABLE (TABELA SYSNAME, COLUNA SYSNAME);
INSERT INTO @carregadas (TABELA, COLUNA)
SELECT N'KZN_HIST_PEDRAVISAOCONSOLIDADA', v FROM (VALUES
    (N'ID_KAIZEN'),
    (N'ID_USUARIO_CADASTRO'),
    (N'ID_USUARIO_LIDER'),
    (N'NM_KAIZEN'),
    (N'ID_CATEGORIA'),
    (N'ID_REPLICACAO'),
    (N'DS_PROBLEMA'),
    (N'DS_OBJETIVO'),
    (N'ID_APROVADOR'),
    (N'URL_IMG_ANTES'),
    (N'DS_ESTADO_ANTES'),
    (N'URL_IMG_DEPOIS'),
    (N'DS_ESTADO_DEPOIS'),
    (N'URL_REFERENCIA'),
    (N'DS_COMPARA_META'),
    (N'DS_LICOES_APRENDIDAS'),
    (N'VL_RESULTADO_FINANCEIRO'),
    (N'ID_MOEDA'),
    (N'DS_RESULTADO_ALCANCADO'),
    (N'DT_CONCLUSAO'),
    (N'ID_USUARIO_ATUALIZACAO'),
    (N'DS_MOTIVO'),
    (N'ID_STATUS')) x(v)
UNION ALL SELECT N'KZN_HIST_PEDRAVISAOCONSOLIDADA', @dtCol
UNION ALL SELECT N'KZN_HIST_MEMBROS_EQUIPE', v FROM (VALUES
    (N'ID_KAIZEN'),
    (N'ID_USUARIO'),
    (N'DT_ATUALIZACAO')) x(v)
UNION ALL SELECT N'KZN_HIST_RESULTADO_KAIZEN', v FROM (VALUES
    (N'ID_KAIZEN'),
    (N'ID_RESULTADO'),
    (N'DT_ATUALIZACAO')) x(v)
UNION ALL SELECT N'KZN_HIST_KAIZEN_HIERARQUIA', v FROM (VALUES
    (N'ID_KAIZEN'),
    (N'ID_USUARIO_LIDER'),
    (N'NM_HIERARQUIA_N1'),
    (N'NM_HIERARQUIA_N2'),
    (N'NM_HIERARQUIA_N3'),
    (N'NM_HIERARQUIA_N4'),
    (N'NM_HIERARQUIA_N5'),
    (N'NM_HIERARQUIA_N6'),
    (N'NM_HIERARQUIA_N7'),
    (N'NM_HIERARQUIA_N8'),
    (N'DT_ATUALIZACAO')) x(v)
UNION ALL SELECT N'KZN_HIST_KAIZEN_DESPERDICIO', v FROM (VALUES
    (N'ID_KAIZEN'),
    (N'ID_DESPERDICIO'),
    (N'DT_ATUALIZACAO')) x(v);

IF EXISTS (
    SELECT 1
    FROM   @tabs t
    JOIN   sys.columns c ON c.object_id = OBJECT_ID('CI.' + t.TABELA)
    WHERE  c.is_nullable = 0 AND c.is_computed = 0 AND c.default_object_id = 0
      AND  NOT EXISTS (SELECT 1 FROM @carregadas g
                       WHERE g.TABELA COLLATE DATABASE_DEFAULT = t.TABELA COLLATE DATABASE_DEFAULT
                         AND g.COLUNA COLLATE DATABASE_DEFAULT = c.name COLLATE DATABASE_DEFAULT))
BEGIN
    SELECT  TABELA = t.TABELA, COLUNA = c.name, TIPO = ty.name
    FROM    @tabs t
    JOIN    sys.columns c  ON c.object_id = OBJECT_ID('CI.' + t.TABELA)
    JOIN    sys.types   ty ON ty.user_type_id = c.user_type_id
    WHERE   c.is_nullable = 0 AND c.is_computed = 0 AND c.default_object_id = 0
      AND   NOT EXISTS (SELECT 1 FROM @carregadas g
                        WHERE g.TABELA COLLATE DATABASE_DEFAULT = t.TABELA COLLATE DATABASE_DEFAULT
                          AND g.COLUNA COLLATE DATABASE_DEFAULT = c.name COLLATE DATABASE_DEFAULT)
    ORDER BY t.TABELA, c.column_id;
    RAISERROR('Abortado: ha coluna NOT NULL sem DEFAULT que esta carga nao preenche (lista acima) — o INSERT falharia com Msg 515. Para SG_GM/ID_TIPO_KAIZEN, rode alinhar_hist_com_pvc_campos_gm.sql, que cria os DEFAULT.', 16, 1);
    RETURN;
END
PRINT 'E0 ok - larguras e colunas obrigatorias conferidas.';

/* Sem GO ate o fim da carga: RAISERROR + RETURN so encerram o batch em
   que aparecem, e um GO aqui deixaria a carga rodar apos um aborto. */

BEGIN TRANSACTION;
BEGIN TRY

/* =====================================================================
   E1 - STAGING (IDs com '#N/A' e ID_REPLICACAO entram como texto)
   ===================================================================== */
CREATE TABLE #PVC (
    ID_KAIZEN INT, TX_CADASTRO NVARCHAR(50), TX_LIDER NVARCHAR(50), NM_KAIZEN NVARCHAR(MAX),
    ID_CATEGORIA INT, TX_REPLICACAO NVARCHAR(200), DS_PROBLEMA NVARCHAR(MAX), DS_OBJETIVO NVARCHAR(MAX),
    TX_APROVADOR NVARCHAR(50), URL_IMG_ANTES NVARCHAR(MAX), DS_ESTADO_ANTES NVARCHAR(MAX), URL_IMG_DEPOIS NVARCHAR(MAX),
    DS_ESTADO_DEPOIS NVARCHAR(MAX), URL_REFERENCIA NVARCHAR(MAX), DS_COMPARA_META NVARCHAR(MAX),
    DS_LICOES_APRENDIDAS NVARCHAR(MAX), VL_RESULTADO_FINANCEIRO DECIMAL(18,2), ID_MOEDA INT,
    DS_RESULTADO_ALCANCADO NVARCHAR(MAX), DT_CONCLUSAO DATE, DT_REG DATETIME2(3),
    TX_ATUALIZACAO NVARCHAR(50), DS_MOTIVO NVARCHAR(MAX), ID_STATUS INT);
INSERT INTO #PVC VALUES (7281, N'81034776', N'81034776', N'Melhoria para instalação de FSL-2308SA-0021', NULL, N'Others/Outros', N'Problema com antigo fluxostato, para instalação do novo era necessário adequação de conexão na linha de água de selagem da BP-2308SA-32', N'Objetivo realizar adequação para instalação de fluxostato tipo IFM', N'10329', N'01 - Imagens/01 - Antes/7281.jpeg', N'Condição do fluxostato anterior, acumulou resíduo internamente vindo a danificar, necessário substituição.', N'01 - Imagens/02 - Depois/7281.jpeg', N'Melhoria consiste em instalação de instrumento mais robusto IFM, com adaptação de conexão soldada diretamente na linha de água de selagem, possibilitando utilizar redução que temos disponível no kanban.', NULL, N'SIM, problema resolvido, objetivo alcançado, Com a instalação de nossa melhoria, possibilitamos partida da BP-2308SA-32 2 em automático e não tivemos mais paradas da mesma por falha no FSL-2308SA-32', N'Adequar situações de forma segura e planejada ajuda na resolução de nossas pendências.', 0, NULL, N'arantir maior agilidade no processo de entrega dos materiais ao executante, por meio da padronização e identificação adequada das peças.', '2025-12-24T00:00:00.000', '2026-01-01T05:52:19.000', N'81034776', NULL, 1);
INSERT INTO #PVC VALUES (7282, N'81029873', N'547667', N'Suporte dos calços da empilhadeira.', NULL, N'Others/Outros', N'Os calços da empilhadeira eram armazenados de forma inadequada e promoviam um ambiente desorganizado,  sem identificação e que dificultava a localização rápida dos calços.

', N'Organização e padronização no armazenamento dos calços.', N'10245', N'01 - Imagens/01 - Antes/7282.jpeg', N'Durante a análise do ambiente de trabalho, foi identificado que os calços das empilhadeiras estavam sendo armazenados de forma inadequada, sem qualquer tipo de padronização. Essa falta de estrutura impacta diretamente na eficiência das atividades, podendo gerar atrasos e riscos operacionais.
', N'01 - Imagens/02 - Depois/7282.jpeg', N'A substituição do armazenamento improvisado por um suporte específico e padronizado para calços trouxe diversos benefícios para a operação. Com a instalação do suporte, os calços passaram a ter um local definido e sinalizado, garantindo organização e fácil acesso.
Essa padronização reduz significativamente o tempo gasto na busca pelos calços, aumentando a produtividade e assegurando maior agilidade na preparação das empilhadeiras. Outro ponto relevante é a melhoria na celeridade das atividades, reduzindo atrasos e custos indiretos. 
', NULL, N'Sim, o problema foi resolvido.Os calços das empilhadeiras foram organizados em um suporte padronizado e identificado, garantindo gestão visual e local definido para cada item. Essa ação eliminou a dificuldade de localização, reduziu o tempo de busca e tornou o processo mais ágil e seguro. Além disso, promoveu um ambiente organizado, aumentando a produtividade e reforçando as práticas de segurança.
', N'Aprendemos que a falta de identificação, padronização e organização impacta diretamente a produtividade o que gera custos de forma indireta. A aplicação de práticas simples, como gestão visual, padronização e metodologia 5S, é essencial para evitar perda de tempo e riscos. ', 0, NULL, N'Garantir acesso seguro à praça de resíduos por meio da criação de uma rota adequada na área externa da oficina.
Eliminar riscos de acidentes relacionados à circulação em áreas não preparadas.
Assegurar conformidade com normas de segurança e ergonomia.
Melhorar a mobilidade e eficiência operacional na gestão de componentes e resíduos.
Proporcionar um ambiente de trabalho seguro e organizado.

', '2025-12-31T00:00:00.000', '2026-01-01T10:22:08.000', N'81029873', NULL, 1);
INSERT INTO #PVC VALUES (7283, N'81029873', N'547667', N'Melhoria nos cabos negativos das máquinas de solda.', NULL, N'Others/Outros', N'Os cabos negativos de solda apresentavam desgaste acelerado e ficavam expostos durante as atividades, gerando riscos de falha operacional e insegurança no ambiente de trabalho.
', N'O objetivo principal do projeto é aumentar a durabilidade e a segurança dos cabos negativos de solda, eliminando o desgaste causado pelo aquecimento das chapas e reduzindo a necessidade de substituições frequentes. Além disso, busca garantir maior proteção contra exposição de cabos deteriorados, prevenindo riscos elétricos e assegurando um ambiente de trabalho mais seguro, com maior eficiência operacional e redução de custos.', N'10245', N'01 - Imagens/01 - Antes/7283.jpeg', N'Os cabos negativos de solda apresentavam desgaste acelerado devido ao aquecimento das chapas durante as atividades, o que resultava em substituições frequentes e aumento de custos de manutenção. Além disso, quando os cabos começavam a se deteriorar, ficavam expostos, criando riscos elétricos e comprometendo a segurança dos operadores. Essa situação também impactava a confiabilidade do processo, podendo gerar paradas não programadas e atrasos nas operações, além de contribuir para um ambiente de trabalho menos organizado.
', N'01 - Imagens/02 - Depois/7283.jpeg', N'A implementação do plano consistiu na instalação de um dispositivo de barramento diretamente ligado às chapas onde são realizadas as soldagens. Essa solução permitiu redistribuir a corrente elétrica de forma mais eficiente, reduzindo a sobrecarga térmica nos cabos negativos. Como resultado, os cabos deixaram de sofrer desgaste acelerado, eliminando a necessidade de substituições frequentes. Entre os principais benefícios estão: redução de custos com manutenção, aumento da confiabilidade do processo de soldagem e melhoria significativa na segurança, já que os cabos não ficam mais expostos quando deterioram, prevenindo riscos elétricos e garantindo um ambiente de trabalho mais seguro e organizado.
', NULL, N'O problema foi resolvido com a implementação do barramento. Os resultados obtidos foram muito positivos: os cabos negativos deixaram de sofrer desgaste acelerado, eliminando a necessidade de substituições frequentes. Além disso, houve aumento significativo na segurança, pois os cabos não ficam mais expostos, prevenindo riscos elétricos. A confiabilidade do processo de soldagem também melhorou, evitando paradas não programadas e garantindo maior eficiência operacional.
', N'A implementação do projeto mostrou a importância de identificar a causa raiz antes de propor soluções, garantindo efetividade. Também evidenciou que melhorias simples podem gerar grandes impactos em segurança. Além disso, o planejamento adequado e o envolvimento da equipe operacional foram fundamentais para evitar retrabalho e validar a solução.', 0, NULL, NULL, '2025-12-08T00:00:00.000', '2026-01-01T11:11:18.000', N'81029873', NULL, 1);
INSERT INTO #PVC VALUES (7284, N'81029873', N'547667', N'Identificação das escadas.', NULL, N'Others/Outros', N'Escadas sem identificação adequada podem gerar riscos de acidentes, dificultar a orientação dos colaboradores e comprometer a conformidade com normas de segurança.
', N'Aumentar a segurança e a organização do ambiente, garantindo que todas as escadas estejam claramente sinalizadas para prevenir acidentes e facilitar a localização em situações de emergência e identificar capacidade de carga.', N'10245', N'01 - Imagens/01 - Antes/7284.jpeg', N'As escadas do ambiente operacional não possuíam identificação adequada, o que gerava riscos à segurança dos colaboradores, dificultava a orientação e aumentava a probabilidade de acidentes. Além disso, a ausência de sinalização comprometia a organização e a conformidade com normas de segurança, tornando o ambiente menos seguro e eficiente. Essa situação também impactava a agilidade em situações de emergência, podendo causar atrasos e aumentar os riscos.
', N'01 - Imagens/02 - Depois/7284.jpeg', N'Essa solução garantiu maior visibilidade e orientação para os colaboradores, reduzindo riscos de acidentes e melhorando a conformidade com normas de segurança. Como resultado, o ambiente tornou-se mais organizado e seguro, facilitando a localização das escadas em situações de emergência e promovendo maior eficiência operacional. Entre os principais benefícios estão: prevenção de quedas, redução de riscos, identificação de capacidade de carga, aumento da segurança e melhoria na organização do espaço.
', NULL, N'Sim, o problema foi resolvido.
O problema das escadas sem identificação gerava riscos de acidentes e falta de conformidade com normas. A meta era garantir sinalização clara e padronizada para aumentar a segurança e organização. Com a implementação, todas as escadas foram identificadas, reduzindo riscos e melhorando a orientação, atingindo plenamente a meta inicial e tornando o ambiente mais seguro e eficiente.
', N'Aprendemos que a sinalização adequada é essencial para prevenir acidentes e garantir conformidade com normas. Melhorias simples, como identificação clara, têm grande impacto na segurança e organização, e o envolvimento da equipe é fundamental para eficácia da solução.', 0, NULL, N'Resultado esperado alcançado com sucesso.', '2025-12-14T00:00:00.000', '2026-01-01T11:43:59.000', N'81029873', NULL, 1);
INSERT INTO #PVC VALUES (7285, N'81063774', N'498537', N'PERFIL H ', NULL, N'Others/Outros', N'Durante o processo de montagem do componente Vertimill, a fixação das engrenagens no eixo era realizada por meio de cintas de corrente entrelaçadas no próprio dispositivo. Esse método tinha como finalidade garantir a estabilidade das engrenagens durante as etapas de alinhamento e posicionamento, prevenindo deslocamentos indesejados ou danos às superfícies de contato.', N'Otimizar o risco  de contato direto na peça', N'10230', N'01 - Imagens/01 - Antes/7285.jpeg', N'Durante o processo de montagem do componente Vertimill, a fixação das engrenagens no eixo era realizada por meio de cintas de corrente entrelaçadas no próprio dispositivo. Esse método tinha como finalidade garantir a estabilidade das engrenagens durante as etapas de alinhamento e posicionamento, prevenindo deslocamentos indesejados ou danos às superfícies de contato.', N'01 - Imagens/02 - Depois/7285.jpeg', N'Dispositivo mecânico em perfil H, fabricado em aço e desenvolvido internamente na oficina, destinado à remoção do acoplamento de baixa rotação do componente Vertimill, como parte do processo de manutenção, garantir a execução da manutenção dentro do prazo, utilizando métodos seguros e eficientes, preservando a integridade da peça e a segurança da equipe.', NULL, N'Garantir a execução da manutenção dentro do prazo, utilizando métodos seguros e eficientes, preservando a integridade da peça e a segurança da equipe.', N'Planejamento de Ferramentas e Importância da Inovação Interna', 0, NULL, N'Uma boa identificação possibilita atuações mais rápidas e assertivas.', '2025-12-30T00:00:00.000', '2026-01-01T11:57:20.000', N'81063774', NULL, 1);
INSERT INTO #PVC VALUES (7286, N'81025448', N'81025448', N'equipment visibilty', NULL, N'Underground/Subterrâneo', N'on 760 level 3 way intersection with blindspots', N'line of sight with other equipment', N'10068', N'01 - Imagens/01 - Antes/7286.jpeg', N'intersections on 760 level were very blind. easily causing equipment collisions', N'01 - Imagens/02 - Depois/7286.jpeg', N'with the use of convex mirrors, the intersection is a lot more visible from all 3 directions', NULL, N'much better equipment flow on levels', N'intersections with heavy equipment need visibilty', 0, NULL, N'N/A', '2025-12-30T00:00:00.000', '2026-01-01T12:03:59.000', N'81025448', NULL, 1);
INSERT INTO #PVC VALUES (7287, N'81025448', N'81051729', N'equipment visibilty', NULL, N'Underground/Subterrâneo', N'on 790 level 3 way intersection with blindspots', N'line of sight with other equipment', N'10068', N'01 - Imagens/01 - Antes/7287.jpeg', N'intersections on 790 level were very blind. easily causing equipment collisions', N'01 - Imagens/02 - Depois/7287.jpeg', N'with the use of convex mirrors, the intersection is a lot more visible from all 3 directions', NULL, N'much better equipment flow on levels', N'intersections with heavy equipment need visibilty', 0, NULL, N'REPLICAMOS NOS OUTRO EQUIPAMENTOS QUE NÃO TINHAM A TAMPA, E MANTENDO A ERGONOMIA DOS MESMO.', '2025-12-31T00:00:00.000', '2026-01-01T12:08:24.000', N'81025448', NULL, 1);
INSERT INTO #PVC VALUES (7288, N'81025448', N'81025448', N'equipment visibilty', NULL, N'Underground/Subterrâneo', N'on 820 level 3 way intersection with blindspots', N'line of sight with other equipment', N'10157', N'01 - Imagens/01 - Antes/7288.jpeg', N'intersections on 820 level were very blind. easily causing equipment collisions', N'01 - Imagens/02 - Depois/7288.jpeg', N'with the use of convex mirrors, the intersection is a lot more visible from all 3 directions', NULL, N'much better equipment flow on levels', N'intersections with heavy equipment need visibilty', 0, NULL, N'eficiência e praticidade.  ', '2025-12-31T00:00:00.000', '2026-01-01T12:13:13.000', N'81025448', NULL, 1);
INSERT INTO #PVC VALUES (7289, N'81025448', N'81025448', N'equipment visibilty', NULL, N'Underground/Subterrâneo', N'on 730 level 3 way intersection with blindspots', N'line of sight with other equipment', N'10068', N'01 - Imagens/01 - Antes/7289.jpeg', N'intersections on 730 level were very blind. easily causing equipment collisions', N'01 - Imagens/02 - Depois/7289.jpeg', N'with the use of convex mirrors, the intersection is a lot more visible from all 3 directions', NULL, N'much better equipment flow on levels', N'intersections with heavy equipment need visibilty', 0, NULL, N'Plant hygiene will be easier to maintain', '2025-12-31T00:00:00.000', '2026-01-01T12:18:16.000', N'81025448', NULL, 1);
INSERT INTO #PVC VALUES (7290, N'81029873', N'547667', N'Carro para transporte de peças. ', NULL, N'Others/Outros', N'O transporte manual de peças dentro do setor é realizado de forma pouco eficiente, exigindo esforço físico elevado e aumentando o risco de acidentes e danos às peças. Essa situação impacta a produtividade e a segurança dos colaboradores. É necessário desenvolver uma solução prática que facilite o deslocamento das peças, reduzindo esforço e melhorando a ergonomia no processo.
', N'O projeto teve como objetivo melhorar ergonomia e produtividade, substituindo o carrinho inadequado que causava esforço físico e atrasos. A causa raiz foi a falta de equipamento adequado. A solução foi implementar um carrinho ergonômico e funcional, atingindo a meta de reduzir esforço, aumentar segurança e agilizar o transporte, resultando em menor tempo de execução e maior eficiência operacional.', N'10245', N'01 - Imagens/01 - Antes/7290.jpeg', N'O transporte manual de peças dentro do setor é realizado de forma pouco eficiente, exigindo esforço físico elevado e aumentando o risco de acidentes e danos às peças. Essa situação impacta a produtividade e a segurança dos colaboradores. É necessário desenvolver uma solução prática que facilite o deslocamento das peças, reduzindo esforço e melhorando a ergonomia no processo. Ao utilizar um carro que tem medidas especificas e geometrias complexas, o risco de s peça caírem ou danificarem é maior. 
', N'01 - Imagens/02 - Depois/7290.jpeg', N'Identificou-se que o transporte manual de peças causava esforço físico excessivo e baixa eficiência devido à falta de equipamento adequado. O transporte com carrinhos inadequados também promoviam esforços excessivos. Para solucionar, foi desenvolvido e implementado um carrinho específico para movimentação interna. Com essa ação, houve redução do esforço físico, aumento da segurança, melhoria na ergonomia e maior agilidade no processo, garantindo padronização e eficiência operacional.
', NULL, N'Sim, o problema foi resolvido.
O objetivo era reduzir o esforço físico e aumentar a eficiência no transporte interno de peças, conforme declarado no problema inicial. Com a implementação do carrinho, atingimos a meta proposta: houve diminuição significativa do esforço manual, melhoria na ergonomia, aumento da segurança e maior agilidade no processo, atendendo plenamente à necessidade identificada.
', N'Aprendemos que analisar ergonomia e segurança antes de definir processos é essencial, e que soluções simples, como um carrinho, podem gerar grande impacto na eficiência. A participação da equipe na identificação do problema facilita a implementação, e testes práticos são fundamentais para validar a funcionalidade e garantir resultados efetivos.', 0, NULL, N'We reduced 30 minutes by that activity.', '2025-12-25T00:00:00.000', '2026-01-01T12:18:33.000', N'81029873', NULL, 1);
INSERT INTO #PVC VALUES (7291, N'81025448', N'81051729', N'equipment visibilty', NULL, N'Underground/Subterrâneo', N'on 760 ramp entrance 3 way intersection with blind spots', N'line of sight with other equipment', N'10068', N'01 - Imagens/01 - Antes/7291.jpeg', N'entrance on 760 level were very blind. easily causing equipment collisions', N'01 - Imagens/02 - Depois/7291.jpeg', N'with the use of convex mirrors, the intersection is a lot more visible from all 3 directions', NULL, N'much better equipment flow on levels', N'intersections with heavy equipment need visibilty', 0, NULL, N'We reduced time consuming about 30 minutes by the time.', '2025-12-31T00:00:00.000', '2026-01-01T12:27:57.000', N'81025448', NULL, 1);
INSERT INTO #PVC VALUES (7292, N'81025448', N'81030023', N'equipment visibilty', NULL, N'Underground/Subterrâneo', N'on 820 ramp entrance 3 way intersection with blind spots', N'line of sight with other equipment', N'10068', N'01 - Imagens/01 - Antes/7292.jpeg', N'entrance on 820 level were very blind. easily causing equipment collisions', N'01 - Imagens/02 - Depois/7292.jpeg', N'with the use of convex mirrors, the intersection is a lot more visible from all 3 directions', NULL, N'much better equipment flow on levels', N'intersections with heavy equipment need visibilty', 0, NULL, N'We reduced injury risk.', '2025-12-30T00:00:00.000', '2026-01-01T12:28:44.000', N'81025448', NULL, 1);
INSERT INTO #PVC VALUES (7293, N'81063774', N'498537', N'DISPOSITIVO DE MONTAGEM DA BOMBA WEIR ', NULL, N'Others/Outros', N'A montagem das buchas da bomba WEIR era realizada utilizando marretas de borracha como ferramenta auxiliar para ajuste das peças. Esse método apresentava riscos de aplicação de força excessiva, podendo ocasionar deformações nas buchas, desalinhamento dos componentes e redução da vida útil do conjunto.', N'Desenvolver e implementar um dispositivo específico para montagem das buchas da bomba WEIR vertical, garantindo aplicação de força controlada e uniforme.', N'10230', N'01 - Imagens/01 - Antes/7293.jpeg', N'A montagem das buchas da bomba WEIR era realizada utilizando marretas de borracha como ferramenta auxiliar para ajuste das peças. Esse método apresentava riscos de aplicação de força excessiva, podendo ocasionar deformações nas buchas, desalinhamento dos componentes e redução da vida útil do conjunto.', N'01 - Imagens/02 - Depois/7293.jpeg', N'Dispositivo para montagem da bomba WEIR vertical na balsa, desenvolvido para realizar o impacto das buchas durante o processo de montagem. O objetivo é evitar esforços excessivos no prensamento, que podem causar danos às buchas durante a instalação.', NULL, N' Montagem manual com marretas → alta variabilidade, risco de danos, falta de controle de força.
Implementação de dispositivo de montagem → força aplicada de forma controlada, redução de danos, aumento da precisão e padronização do processo.', N'esforços não controlados', 0, NULL, N'Time saved when signing out monitors', '2025-12-29T00:00:00.000', '2026-01-01T17:20:35.000', N'81063774', NULL, 1);
INSERT INTO #PVC VALUES (7294, N'81063774', N'81063774', N'Suporte de identificação do guanital 				', NULL, N'Others/Outros', N'Guanital  na área da ferramentaria sem identificação, ocasionando desgaste de tempo significativa para os colaboradores na verificação e determinação da medida correta.', N'visão de 3 segundos ', N'10226', N'01 - Imagens/01 - Antes/7294.jpeg', N'Guanital  na área da ferramentaria sem identificação, ocasionando desgaste de tempo significativa para os colaboradores na verificação e determinação da medida correta.', N'01 - Imagens/02 - Depois/7294.jpeg', N' Fabricado um suporte para inclusão de placas de identificação, proporcionando maior agilidade no processo de entrega do material ao executante.', NULL, N'Problema Identificado: A ausência de suporte para placas de identificação causava atrasos na entrega e dificultava a rastreabilidade do material.
Impacto: Aumentava o tempo de execução e gerava risco de erros na identificação dos materiais.
Solução Aplicada: Desenvolvimento e fabricação do suporte para placas, garantindo padronização e agilidade.', N'Senso de 3 segundos melhora o processo ', 0, NULL, N'Obtido um suporte resistente e funcional, que melhore a organização, a ergonomia e a higiene no uso do cooler e dos fardos de água mineral.', '2025-10-28T00:00:00.000', '2026-01-01T18:10:46.000', N'81063774', NULL, 1);
INSERT INTO #PVC VALUES (7295, N'81063774', N'544555', N'Adeguação da área externa com caminho seguro 				', NULL, N'Others/Outros', N'Área externa da oficina, destinada à gestão de componentes, sem rota segura para acesso à praça de resíduos.', N'Realizar o caminho seguro ', N'10226', N'01 - Imagens/01 - Antes/7295.jpeg', N'Área externa da oficina, destinada à gestão de componentes, sem rota segura para acesso à praça de resíduos.', N'01 - Imagens/02 - Depois/7295.jpeg', N'Após a identificação da ausência de um caminho seguro nas áreas externas, foi aberto um chamado para a equipe industrial realizar a criação do acesso, garantindo um ambiente de trabalho seguro e conforme as normas de SSMA.', NULL, N'Antes: Ausência de rota segura → risco elevado de acidentes, não conformidade com normas, baixa ergonomia.
Depois: Criação de caminho seguro pela equipe industrial → ambiente seguro, redução de riscos, conformidade com normas e melhoria na mobilidade.', N'segurança ', 0, NULL, N'Garantir a fixação segura do tambor de graxa, reduzindo riscos de tombamento, vazamentos e acidentes, além de aumentar a segurança operacional e a organização do local de trabalho.', '2025-11-11T00:00:00.000', '2026-01-01T18:45:02.000', N'81063774', NULL, 1);
INSERT INTO #PVC VALUES (7296, N'503436', N'503436', N'MONITORAMENTO THE ENDURECE DYNAMOX', NULL, N'Projects/Projetos', N'ANTERIORMENTE TINHAMOS QUE REALIZAR AS COLETAS DEPEDENDO DOS OPERADORES NA FORTA 793 D E 797F. ESPERANDO 1 HORA DE AGUARDO E ATRASANDO A OPERAÇÃO.', N'COLETAR A VIBRAÇÃO DE FORMA SEGURA', N'10015', N'01 - Imagens/01 - Antes/7296.jpeg', N'AS COLETAS ERAM FEITAS PRÓXIMAS DOS EQUIPAMENTOS FUNCIONANDO EM 1400 RPM COM RISCO DE SER ATROPELADO OU BATIDA CONTRA.', N'01 - Imagens/02 - Depois/7296.jpeg', N'AO RELIAZARMOS AS INSTALAÇÕES DOS SENSORES PORTABLES ANTES DE FUNCIONAR O CAMINHÃO BLOQUEANDO E EM SEGUIDA INSTALANDO 10 SENSORES NOS PONTOS DE MONITORAMENTO, PODE SUBIR NA CABINE E COLETAR DE FORMA SEGURA.', NULL, N'SIM MAIOR AGILIDADE E SEGURANÇA NAS COLETAS NA CABINE EVITANDO A EXPOSIÇÃO DOS COLABORADORES A LINHAS DE EXPLOSÃO DE PNEU OU ATROPLEAMENTO.', N'SEGURANÇA E MAIOR AGILIDADE', 2, 1, N'less contamination to deal with', '2025-12-31T00:00:00.000', '2026-01-01T23:51:21.000', N'503436', NULL, 2);

/* =====================================================================
   E1b - TRAVA: ID obrigatorio que nao converte
   ===================================================================== */
IF EXISTS (SELECT 1 FROM #PVC
           WHERE TRY_CONVERT(INT, TX_CADASTRO) IS NULL
              OR TRY_CONVERT(INT, TX_LIDER) IS NULL
              OR TRY_CONVERT(INT, TX_ATUALIZACAO) IS NULL)
BEGIN
    SELECT  PROBLEMA = 'ID obrigatorio nao numerico',
            ID_KAIZEN, CADASTRO = TX_CADASTRO, LIDER = TX_LIDER, ATUALIZACAO = TX_ATUALIZACAO
    FROM    #PVC
    WHERE   TRY_CONVERT(INT, TX_CADASTRO) IS NULL
       OR   TRY_CONVERT(INT, TX_LIDER) IS NULL
       OR   TRY_CONVERT(INT, TX_ATUALIZACAO) IS NULL
    ORDER BY ID_KAIZEN;

    IF @PULAR_INVALIDAS = 0
        RAISERROR('Abortado: ha Kaizen(s) com ID obrigatorio nao numerico (lista acima). Corrija a origem, ou troque @PULAR_INVALIDAS para 1 para carregar o restante.', 16, 1);
    ELSE
    BEGIN
        DELETE FROM #PVC
        WHERE TRY_CONVERT(INT, TX_CADASTRO) IS NULL
           OR TRY_CONVERT(INT, TX_LIDER) IS NULL
           OR TRY_CONVERT(INT, TX_ATUALIZACAO) IS NULL;
        PRINT '  E1b - ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' Kaizen(s) excluido(s) da carga.';
    END
END

/* =====================================================================
   E2 - Tabela principal
   ===================================================================== */
SET @sql = N'
INSERT INTO CI.KZN_HIST_PEDRAVISAOCONSOLIDADA
    (ID_KAIZEN, ID_USUARIO_CADASTRO, ID_USUARIO_LIDER, NM_KAIZEN, ID_CATEGORIA, ID_REPLICACAO,
     DS_PROBLEMA, DS_OBJETIVO, ID_APROVADOR, URL_IMG_ANTES, DS_ESTADO_ANTES, URL_IMG_DEPOIS,
     DS_ESTADO_DEPOIS, URL_REFERENCIA, DS_COMPARA_META, DS_LICOES_APRENDIDAS,
     VL_RESULTADO_FINANCEIRO, ID_MOEDA, DS_RESULTADO_ALCANCADO, DT_CONCLUSAO, ' + QUOTENAME(@dtCol) + N',
     ID_USUARIO_ATUALIZACAO, DS_MOTIVO, ID_STATUS)
SELECT  p.ID_KAIZEN, TRY_CONVERT(INT, p.TX_CADASTRO), TRY_CONVERT(INT, p.TX_LIDER), p.NM_KAIZEN, p.ID_CATEGORIA, r.ID_REPLICACAO,
        p.DS_PROBLEMA, p.DS_OBJETIVO, TRY_CONVERT(INT, p.TX_APROVADOR), p.URL_IMG_ANTES, p.DS_ESTADO_ANTES, p.URL_IMG_DEPOIS,
        p.DS_ESTADO_DEPOIS, p.URL_REFERENCIA, p.DS_COMPARA_META, p.DS_LICOES_APRENDIDAS,
        p.VL_RESULTADO_FINANCEIRO, p.ID_MOEDA, p.DS_RESULTADO_ALCANCADO, p.DT_CONCLUSAO, p.DT_REG,
        TRY_CONVERT(INT, p.TX_ATUALIZACAO), p.DS_MOTIVO, p.ID_STATUS
FROM        #PVC p
OUTER APPLY (SELECT TOP (1) d.ID_REPLICACAO
             FROM   CI.KZN_REPLICACAO d
             WHERE  LTRIM(RTRIM(d.NM_REPLICACAO)) COLLATE Latin1_General_CI_AI
                    IN (LTRIM(RTRIM(p.TX_REPLICACAO))                                                COLLATE Latin1_General_CI_AI,
                        LTRIM(RTRIM(LEFT(p.TX_REPLICACAO, NULLIF(CHARINDEX(''/'', p.TX_REPLICACAO),0) - 1)))      COLLATE Latin1_General_CI_AI,
                        LTRIM(RTRIM(SUBSTRING(p.TX_REPLICACAO, NULLIF(CHARINDEX(''/'', p.TX_REPLICACAO),0) + 1, 200))) COLLATE Latin1_General_CI_AI)
             ORDER BY d.ID_IDIOMA) r
ORDER BY p.ID_KAIZEN;
SET @c = @@ROWCOUNT;';
/* @c por OUTPUT, medido DENTRO do batch dinamico: ler @@ROWCOUNT aqui
   fora, depois do EXEC, e fragil. */
EXEC sp_executesql @sql, N'@c INT OUTPUT', @c = @qt OUTPUT;
PRINT '  E2 - KZN_HIST_PEDRAVISAOCONSOLIDADA: ' + CAST(@qt AS VARCHAR(10)) + ' linha(s).';

/* =====================================================================
   E3 - Membros de equipe
   ===================================================================== */
CREATE TABLE #MEM (ID_KAIZEN INT, ID_USUARIO INT, DT_ATUALIZACAO DATETIME2(3));
INSERT INTO #MEM VALUES
(7281, 100000, '2026-01-01T05:52:19.000'),
(7282, 100001, '2026-01-01T10:22:08.000'),
(7282, 100002, '2026-01-01T10:22:08.000'),
(7283, 100003, '2026-01-01T11:11:18.000'),
(7283, 100004, '2026-01-01T11:11:18.000'),
(7284, 100005, '2026-01-01T11:43:59.000'),
(7284, 100006, '2026-01-01T11:43:59.000'),
(7285, 100007, '2026-01-01T11:57:20.000'),
(7285, 100008, '2026-01-01T11:57:20.000'),
(7285, 100009, '2026-01-01T11:57:20.000'),
(7286, 100010, '2026-01-01T12:03:59.000'),
(7287, 100011, '2026-01-01T12:08:24.000'),
(7288, 100012, '2026-01-01T12:13:13.000'),
(7289, 100013, '2026-01-01T12:18:16.000'),
(7290, 100014, '2026-01-01T12:18:33.000'),
(7290, 100015, '2026-01-01T12:18:33.000'),
(7290, 100016, '2026-01-01T12:18:33.000'),
(7291, 100017, '2026-01-01T12:27:57.000'),
(7292, 100018, '2026-01-01T12:28:44.000'),
(7293, 100019, '2026-01-01T17:20:35.000'),
(7293, 100020, '2026-01-01T17:20:35.000'),
(7293, 100021, '2026-01-01T17:20:35.000'),
(7294, 100022, '2026-01-01T18:10:46.000'),
(7294, 100023, '2026-01-01T18:10:46.000'),
(7294, 100024, '2026-01-01T18:10:46.000'),
(7295, 100025, '2026-01-01T18:45:02.000'),
(7295, 100026, '2026-01-01T18:45:02.000'),
(7296, 100027, '2026-01-01T23:51:21.000'),
(7296, 100028, '2026-01-01T23:51:21.000');
INSERT INTO CI.KZN_HIST_MEMBROS_EQUIPE (ID_KAIZEN, ID_USUARIO, DT_ATUALIZACAO)
SELECT t.ID_KAIZEN, t.ID_USUARIO, t.DT_ATUALIZACAO FROM #MEM t
WHERE EXISTS (SELECT 1 FROM #PVC p WHERE p.ID_KAIZEN = t.ID_KAIZEN);
PRINT '  KZN_HIST_MEMBROS_EQUIPE: ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' linha(s).';
DROP TABLE #MEM;

/* =====================================================================
   E4 - Resultados
   ===================================================================== */
CREATE TABLE #RES (ID_KAIZEN INT, ID_RESULTADO INT, DT_ATUALIZACAO DATETIME2(3));
INSERT INTO #RES VALUES
(7281, 2, '2026-01-01T05:52:19.000'),
(7282, 6, '2026-01-01T10:22:08.000'),
(7283, 1, '2026-01-01T11:11:18.000'),
(7284, 1, '2026-01-01T11:43:59.000'),
(7285, 3, '2026-01-01T11:57:20.000'),
(7286, 1, '2026-01-01T12:03:59.000'),
(7287, 1, '2026-01-01T12:08:24.000'),
(7288, 1, '2026-01-01T12:13:13.000'),
(7289, 1, '2026-01-01T12:18:16.000'),
(7290, 1, '2026-01-01T12:18:33.000'),
(7291, 1, '2026-01-01T12:27:57.000'),
(7292, 1, '2026-01-01T12:28:44.000'),
(7293, 3, '2026-01-01T17:20:35.000'),
(7294, 3, '2026-01-01T18:10:46.000'),
(7295, 5, '2026-01-01T18:45:02.000');
INSERT INTO CI.KZN_HIST_RESULTADO_KAIZEN (ID_KAIZEN, ID_RESULTADO, DT_ATUALIZACAO)
SELECT t.ID_KAIZEN, t.ID_RESULTADO, t.DT_ATUALIZACAO FROM #RES t
WHERE EXISTS (SELECT 1 FROM #PVC p WHERE p.ID_KAIZEN = t.ID_KAIZEN);
PRINT '  KZN_HIST_RESULTADO_KAIZEN: ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' linha(s).';
DROP TABLE #RES;

/* =====================================================================
   E5 - Fotografia da hierarquia
   ===================================================================== */
CREATE TABLE #HIE (ID_KAIZEN INT, ID_USUARIO_LIDER INT, NM_HIERARQUIA_N1 NVARCHAR(MAX), NM_HIERARQUIA_N2 NVARCHAR(MAX), NM_HIERARQUIA_N3 NVARCHAR(MAX), NM_HIERARQUIA_N4 NVARCHAR(MAX), NM_HIERARQUIA_N5 NVARCHAR(MAX), NM_HIERARQUIA_N6 NVARCHAR(MAX), NM_HIERARQUIA_N7 NVARCHAR(MAX), NM_HIERARQUIA_N8 NVARCHAR(MAX), DT_ATUALIZACAO DATETIME2(3));
INSERT INTO #HIE VALUES
(7281, 81034776, N'PRESIDENTE - GUSTAVO DUARTE PIMENTA', N'CEO, BASE METALS - SHAUN ALLEYNE USMAR', N'CHIEF OPERATING OFFICER - BM - ALFREDO PONTES DE SANTANA', N'DIRETOR DE OPERACOES - SALOBO - ANTONIO SCHETTINO GOMES PEREIRA', N'DIR USINAS SALOBO I/II/IIII - ADEILSON RODRIGUES', N'GER GERAL MANUT USINA SALOBO - ALLAN NUNES SANTOS', N'GER MANUTENC ELETRICA SALOBO - CHARLES TASSIO DE FARIA', N'SUP MANUT CORRETIVA - RODOLFO VASCONCELOS DE MENEZES', '2026-01-01T05:52:19.000'),
(7282, 547667, N'PRESIDENTE - GUSTAVO DUARTE PIMENTA', N'CEO, BASE METALS - SHAUN ALLEYNE USMAR', N'CHIEF OPERATING OFFICER - BM - ALFREDO PONTES DE SANTANA', N'DIR OPER SOSSEGO BM - VINICIUS MOREIRA ASSIS', N'GER GERAL OPERACOES SOSSEGO - FRANCISCO ISAIAS LOPES DE OLIVEIRA SILVA', N'GER MANUTENC ELETRICA SOSSEGO - MONIQUE ALEIXO DE SOUZA', N'SUP GEST COMPONENTES MINERACAO - RAISSA SOARES DE ARAUJO', NULL, '2026-01-01T10:22:08.000'),
(7283, 547667, N'PRESIDENTE - GUSTAVO DUARTE PIMENTA', N'CEO, BASE METALS - SHAUN ALLEYNE USMAR', N'CHIEF OPERATING OFFICER - BM - ALFREDO PONTES DE SANTANA', N'DIR OPER SOSSEGO BM - VINICIUS MOREIRA ASSIS', N'GER GERAL OPERACOES SOSSEGO - FRANCISCO ISAIAS LOPES DE OLIVEIRA SILVA', N'GER MANUTENC ELETRICA SOSSEGO - MONIQUE ALEIXO DE SOUZA', N'SUP GEST COMPONENTES MINERACAO - RAISSA SOARES DE ARAUJO', NULL, '2026-01-01T11:11:18.000'),
(7284, 547667, N'PRESIDENTE - GUSTAVO DUARTE PIMENTA', N'CEO, BASE METALS - SHAUN ALLEYNE USMAR', N'CHIEF OPERATING OFFICER - BM - ALFREDO PONTES DE SANTANA', N'DIR OPER SOSSEGO BM - VINICIUS MOREIRA ASSIS', N'GER GERAL OPERACOES SOSSEGO - FRANCISCO ISAIAS LOPES DE OLIVEIRA SILVA', N'GER MANUTENC ELETRICA SOSSEGO - MONIQUE ALEIXO DE SOUZA', N'SUP GEST COMPONENTES MINERACAO - RAISSA SOARES DE ARAUJO', NULL, '2026-01-01T11:43:59.000'),
(7285, 498537, N'PRESIDENTE - GUSTAVO DUARTE PIMENTA', N'CEO, BASE METALS - SHAUN ALLEYNE USMAR', N'CHIEF OPERATING OFFICER - BM - ALFREDO PONTES DE SANTANA', N'DIRETOR DE OPERACOES - SALOBO - ANTONIO SCHETTINO GOMES PEREIRA', N'DIR USINAS SALOBO I/II/IIII - ADEILSON RODRIGUES', N'GER GERAL MANUT USINA SALOBO - ALLAN NUNES SANTOS', N'GER GESTAO COMPONENT MINERACAO - WALLACE BARCELOS (INTERINO)', N'SUP GESTAO COMPONENT MINERACAO - ADRIANA ALVES PEREIRA', '2026-01-01T11:57:20.000'),
(7286, 81025448, N'PRESIDENTE - GUSTAVO DUARTE PIMENTA', N'CEO, BASE METALS - SHAUN ALLEYNE USMAR', N'CHIEF OPERATING OFFICER - BM - ALFREDO PONTES DE SANTANA', N'DIR, VNL & INTERNATIONAL REFIN - ROBERTO MATOS DAMASCENO', N'DIR, VB OPERATIONS - PIETER J LOOCK', N'MANAGER, VOISEY''S BAY MINES - GLEN HOUSE', N'Supt, Mining Operations - Jonathan Stanley', N'Supv, Ug Mine Ops - Vbme - Bill May', '2026-01-01T12:03:59.000'),
(7287, 81051729, N'PRESIDENTE - GUSTAVO DUARTE PIMENTA', N'CEO, BASE METALS - SHAUN ALLEYNE USMAR', N'CHIEF OPERATING OFFICER - BM - ALFREDO PONTES DE SANTANA', N'DIR, VNL & INTERNATIONAL REFIN - ROBERTO MATOS DAMASCENO', N'DIR, VB OPERATIONS - PIETER J LOOCK', N'MANAGER, VOISEY''S BAY MINES - GLEN HOUSE', N'Supt, Mining Operations - Jonathan Stanley', N'Supv, Ug Mine Ops - Vbme - Bill May', '2026-01-01T12:08:24.000'),
(7288, 81025448, N'PRESIDENTE - GUSTAVO DUARTE PIMENTA', N'CEO, BASE METALS - SHAUN ALLEYNE USMAR', N'CHIEF OPERATING OFFICER - BM - ALFREDO PONTES DE SANTANA', N'DIR, VNL & INTERNATIONAL REFIN - ROBERTO MATOS DAMASCENO', N'DIR, VB OPERATIONS - PIETER J LOOCK', N'MANAGER, VOISEY''S BAY MINES - GLEN HOUSE', N'Supt, Mining Operations - Jonathan Stanley', N'Supv, Ug Mine Ops - Vbme - Bill May', '2026-01-01T12:13:13.000'),
(7289, 81025448, N'PRESIDENTE - GUSTAVO DUARTE PIMENTA', N'CEO, BASE METALS - SHAUN ALLEYNE USMAR', N'CHIEF OPERATING OFFICER - BM - ALFREDO PONTES DE SANTANA', N'DIR, VNL & INTERNATIONAL REFIN - ROBERTO MATOS DAMASCENO', N'DIR, VB OPERATIONS - PIETER J LOOCK', N'MANAGER, VOISEY''S BAY MINES - GLEN HOUSE', N'Supt, Mining Operations - Jonathan Stanley', N'Supv, Ug Mine Ops - Vbme - Bill May', '2026-01-01T12:18:16.000'),
(7290, 547667, N'PRESIDENTE - GUSTAVO DUARTE PIMENTA', N'CEO, BASE METALS - SHAUN ALLEYNE USMAR', N'CHIEF OPERATING OFFICER - BM - ALFREDO PONTES DE SANTANA', N'DIR OPER SOSSEGO BM - VINICIUS MOREIRA ASSIS', N'GER GERAL OPERACOES SOSSEGO - FRANCISCO ISAIAS LOPES DE OLIVEIRA SILVA', N'GER MANUTENC ELETRICA SOSSEGO - MONIQUE ALEIXO DE SOUZA', N'SUP GEST COMPONENTES MINERACAO - RAISSA SOARES DE ARAUJO', NULL, '2026-01-01T12:18:33.000'),
(7291, 81051729, N'PRESIDENTE - GUSTAVO DUARTE PIMENTA', N'CEO, BASE METALS - SHAUN ALLEYNE USMAR', N'CHIEF OPERATING OFFICER - BM - ALFREDO PONTES DE SANTANA', N'DIR, VNL & INTERNATIONAL REFIN - ROBERTO MATOS DAMASCENO', N'DIR, VB OPERATIONS - PIETER J LOOCK', N'MANAGER, VOISEY''S BAY MINES - GLEN HOUSE', N'Supt, Mining Operations - Jonathan Stanley', N'Supv, Ug Mine Ops - Vbme - Bill May', '2026-01-01T12:27:57.000'),
(7292, 81030023, N'PRESIDENTE - GUSTAVO DUARTE PIMENTA', N'CEO, BASE METALS - SHAUN ALLEYNE USMAR', N'CHIEF OPERATING OFFICER - BM - ALFREDO PONTES DE SANTANA', N'DIR, VNL & INTERNATIONAL REFIN - ROBERTO MATOS DAMASCENO', N'DIR, VB OPERATIONS - PIETER J LOOCK', N'MANAGER, VOISEY''S BAY MINES - GLEN HOUSE', N'Supt, Mining Operations - Jonathan Stanley', N'Supv, Ug Mine Ops - Vbme - Bill May', '2026-01-01T12:28:44.000'),
(7293, 498537, N'PRESIDENTE - GUSTAVO DUARTE PIMENTA', N'CEO, BASE METALS - SHAUN ALLEYNE USMAR', N'CHIEF OPERATING OFFICER - BM - ALFREDO PONTES DE SANTANA', N'DIRETOR DE OPERACOES - SALOBO - ANTONIO SCHETTINO GOMES PEREIRA', N'DIR USINAS SALOBO I/II/IIII - ADEILSON RODRIGUES', N'GER GERAL MANUT USINA SALOBO - ALLAN NUNES SANTOS', N'GER GESTAO COMPONENT MINERACAO - WALLACE BARCELOS (INTERINO)', N'SUP GESTAO COMPONENT MINERACAO - ADRIANA ALVES PEREIRA', '2026-01-01T17:20:35.000'),
(7294, 81063774, N'PRESIDENTE - GUSTAVO DUARTE PIMENTA', N'CEO, BASE METALS - SHAUN ALLEYNE USMAR', N'CHIEF OPERATING OFFICER - BM - ALFREDO PONTES DE SANTANA', N'DIRETOR DE OPERACOES - SALOBO - ANTONIO SCHETTINO GOMES PEREIRA', N'DIR USINAS SALOBO I/II/IIII - ADEILSON RODRIGUES', N'GER GERAL MANUT USINA SALOBO - ALLAN NUNES SANTOS', N'GER GESTAO COMPONENT MINERACAO - WALLACE BARCELOS (INTERINO)', N'SUP GESTAO COMPONENT MINERACAO - ADRIANA ALVES PEREIRA', '2026-01-01T18:10:46.000'),
(7295, 544555, N'PRESIDENTE - GUSTAVO DUARTE PIMENTA', N'CEO, BASE METALS - SHAUN ALLEYNE USMAR', N'CHIEF OPERATING OFFICER - BM - ALFREDO PONTES DE SANTANA', N'DIRETOR DE OPERACOES - SALOBO - ANTONIO SCHETTINO GOMES PEREIRA', N'DIR USINAS SALOBO I/II/IIII - ADEILSON RODRIGUES', N'GER GERAL MANUT USINA SALOBO - ALLAN NUNES SANTOS', N'GER GESTAO COMPONENT MINERACAO - WALLACE BARCELOS (INTERINO)', N'SUP GESTAO COMPONENT MINERACAO - ADRIANA ALVES PEREIRA', '2026-01-01T18:45:02.000'),
(7296, 503436, N'PRESIDENTE - GUSTAVO DUARTE PIMENTA', N'CEO, BASE METALS - SHAUN ALLEYNE USMAR', N'CHIEF OPERATING OFFICER - BM - ALFREDO PONTES DE SANTANA', N'DIRETOR DE OPERACOES - SALOBO - ANTONIO SCHETTINO GOMES PEREIRA', N'DIR MINING SALOBO - BRUNO DE ALVARENGA SOARES', N'MANUTENÇÃO MINA - BRUNO DE ALVARENGA SOARES', N'GER INSP CONFIAB E ENG ATL SUL - GEOVANE ROSSO FELIPE', N'SUP PROC MANUT EQ MOVEIS PERF. - EWERTON FERNANDES NASCIMENTO', '2026-01-01T23:51:21.000');
INSERT INTO CI.KZN_HIST_KAIZEN_HIERARQUIA (ID_KAIZEN, ID_USUARIO_LIDER, NM_HIERARQUIA_N1, NM_HIERARQUIA_N2, NM_HIERARQUIA_N3, NM_HIERARQUIA_N4, NM_HIERARQUIA_N5, NM_HIERARQUIA_N6, NM_HIERARQUIA_N7, NM_HIERARQUIA_N8, DT_ATUALIZACAO)
SELECT t.ID_KAIZEN, t.ID_USUARIO_LIDER, t.NM_HIERARQUIA_N1, t.NM_HIERARQUIA_N2, t.NM_HIERARQUIA_N3, t.NM_HIERARQUIA_N4, t.NM_HIERARQUIA_N5, t.NM_HIERARQUIA_N6, t.NM_HIERARQUIA_N7, t.NM_HIERARQUIA_N8, t.DT_ATUALIZACAO FROM #HIE t
WHERE EXISTS (SELECT 1 FROM #PVC p WHERE p.ID_KAIZEN = t.ID_KAIZEN);
PRINT '  KZN_HIST_KAIZEN_HIERARQUIA: ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' linha(s).';
DROP TABLE #HIE;

/* =====================================================================
   E6 - Desperdicios
   ===================================================================== */
CREATE TABLE #DESP (ID_KAIZEN INT, ID_DESPERDICIO INT, DT_ATUALIZACAO DATETIME2(3));
INSERT INTO #DESP VALUES
(7281, 1, '2026-01-01T05:52:19.000'),
(7282, 4, '2026-01-01T10:22:08.000'),
(7282, 3, '2026-01-01T10:22:08.000'),
(7282, 2, '2026-01-01T10:22:08.000'),
(7283, 3, '2026-01-01T11:11:18.000'),
(7283, 1, '2026-01-01T11:11:18.000'),
(7284, 4, '2026-01-01T11:43:59.000'),
(7284, 1, '2026-01-01T11:43:59.000'),
(7284, 2, '2026-01-01T11:43:59.000'),
(7285, 5, '2026-01-01T11:57:20.000'),
(7286, 1, '2026-01-01T12:03:59.000'),
(7287, 1, '2026-01-01T12:08:24.000'),
(7288, 1, '2026-01-01T12:13:13.000'),
(7289, 1, '2026-01-01T12:18:16.000'),
(7290, 9, '2026-01-01T12:18:33.000'),
(7290, 8, '2026-01-01T12:18:33.000'),
(7290, 4, '2026-01-01T12:18:33.000'),
(7290, 1, '2026-01-01T12:18:33.000'),
(7291, 1, '2026-01-01T12:27:57.000'),
(7292, 1, '2026-01-01T12:28:44.000'),
(7293, 4, '2026-01-01T17:20:35.000'),
(7294, 4, '2026-01-01T18:10:46.000'),
(7294, 2, '2026-01-01T18:10:46.000'),
(7295, 7, '2026-01-01T18:45:02.000'),
(7296, 2, '2026-01-01T23:51:21.000');
INSERT INTO CI.KZN_HIST_KAIZEN_DESPERDICIO (ID_KAIZEN, ID_DESPERDICIO, DT_ATUALIZACAO)
SELECT t.ID_KAIZEN, t.ID_DESPERDICIO, t.DT_ATUALIZACAO FROM #DESP t
WHERE EXISTS (SELECT 1 FROM #PVC p WHERE p.ID_KAIZEN = t.ID_KAIZEN);
PRINT '  KZN_HIST_KAIZEN_DESPERDICIO: ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' linha(s).';
DROP TABLE #DESP;

/* =====================================================================
   E7 - Pendencias (antes do COMMIT)
   ===================================================================== */
SELECT  PROBLEMA = 'REPLICACAO sem correspondencia em CI.KZN_REPLICACAO',
        TEXTO_DA_PLANILHA = p.TX_REPLICACAO, QT_KAIZENS = COUNT(*)
FROM    #PVC p
JOIN    CI.KZN_HIST_PEDRAVISAOCONSOLIDADA h ON h.ID_KAIZEN = p.ID_KAIZEN
WHERE   h.ID_REPLICACAO IS NULL AND p.TX_REPLICACAO IS NOT NULL
GROUP BY p.TX_REPLICACAO;

SELECT  PROBLEMA = 'ID_APROVADOR nao numerico -> gravado NULL',
        QT_KAIZENS = COUNT(*)
FROM    #PVC WHERE TX_APROVADOR IS NOT NULL AND TRY_CONVERT(INT, TX_APROVADOR) IS NULL;

DROP TABLE #PVC;

COMMIT TRANSACTION;
PRINT 'Carga concluida.';

END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    PRINT 'ERRO - nada foi gravado (rollback aplicado): ' + ERROR_MESSAGE();
    THROW;
END CATCH
GO

/* =====================================================================
   E8 - CONFERENCIA
   ===================================================================== */
SELECT TABELA='KZN_HIST_PEDRAVISAOCONSOLIDADA', LINHAS=COUNT(*) FROM CI.KZN_HIST_PEDRAVISAOCONSOLIDADA WHERE ID_KAIZEN BETWEEN 7281 AND 7296
UNION ALL SELECT 'KZN_HIST_MEMBROS_EQUIPE',     COUNT(*) FROM CI.KZN_HIST_MEMBROS_EQUIPE      WHERE ID_KAIZEN BETWEEN 7281 AND 7296
UNION ALL SELECT 'KZN_HIST_RESULTADO_KAIZEN',   COUNT(*) FROM CI.KZN_HIST_RESULTADO_KAIZEN    WHERE ID_KAIZEN BETWEEN 7281 AND 7296
UNION ALL SELECT 'KZN_HIST_KAIZEN_HIERARQUIA',  COUNT(*) FROM CI.KZN_HIST_KAIZEN_HIERARQUIA   WHERE ID_KAIZEN BETWEEN 7281 AND 7296
UNION ALL SELECT 'KZN_HIST_KAIZEN_DESPERDICIO', COUNT(*) FROM CI.KZN_HIST_KAIZEN_DESPERDICIO  WHERE ID_KAIZEN BETWEEN 7281 AND 7296;
GO
