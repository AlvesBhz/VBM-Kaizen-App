/* =====================================================================
   Carga do histórico 2026 — Kaizens 7281 a 7296
   ---------------------------------------------------------------------
   Popula as 5 tabelas KZN_HIST_* a partir da planilha
   Extracao_Kaizen_2026_FINAL.xlsx. Os valores estão literais aqui: o
   script não depende de arquivo externo, linked server nem de acesso ao
   Excel na hora de rodar.

   Volume: 16 Kaizens, 30 membros, 16 resultados, 16 hierarquias,
   25 desperdícios.

   ---------------------------------------------------------------------
   DUAS COLUNAS DA PLANILHA NÃO SÃO NUMÉRICAS — resolvidas por lookup

   A planilha traz TEXTO onde o banco espera INT:

     ID_REPLICACAO   -> 'Others/Outros', 'Underground/Subterrâneo',
                        'Projects/Projetos'
     ID_DESPERDICIO  -> vem NULO; o nome está em NM_DESPERDICIO
                        ('Defects/Defeitos', 'Motion/Movimento', ...)

   O script carrega esses valores como texto em tabelas temporárias e os
   converte consultando CI.KZN_REPLICACAO e CI.KZN_DESPERDICIO pelo nome.
   O texto vem no formato 'Inglês/Português', então a comparação testa a
   string inteira E cada metade separadamente, sem acento e sem
   diferenciar maiúsculas (COLLATE Latin1_General_CI_AI).

   O que não casar entra como NULL e é LISTADO na conferência final — em
   vez de derrubar a carga inteira. Confira essa lista: se vier grande, o
   provável é que os nomes nas tabelas de domínio estejam diferentes.

   ---------------------------------------------------------------------
   ATENÇÃO — ID_CATEGORIA vem VAZIA nas 16 linhas

   Na tabela original ID_CATEGORIA é INT NOT NULL. Se você criou as HIST
   com @RELAXAR_NOT_NULL = 0 (o padrão), a coluna herdou o NOT NULL e
   esta carga FALHA com "Cannot insert the value NULL".

   A E0 detecta isso ANTES de inserir qualquer linha e aborta avisando.
   Saídas: recriar a HIST com @RELAXAR_NOT_NULL = 1, ou rodar
     ALTER TABLE CI.KZN_HIST_PEDRAVISAOCONSOLIDADA ALTER COLUMN ID_CATEGORIA INT NULL;

   ---------------------------------------------------------------------
   SEGURANÇA
     - Tudo em UMA transação: erro em qualquer etapa desfaz TUDO.
     - IDEMPOTENTE: se já houver Kaizen na faixa 7281-7296 nas tabelas
       HIST, o script aborta em vez de duplicar.
     - Só escreve em CI.KZN_HIST_*. Nenhuma tabela de produção é tocada.

   Schema: 'ci'.
   ===================================================================== */

SET NOCOUNT ON;
SET XACT_ABORT ON;

/* =====================================================================
   E0 - PRÉ-CHECAGENS
   ===================================================================== */
IF OBJECT_ID('CI.KZN_HIST_PEDRAVISAOCONSOLIDADA','U') IS NULL
BEGIN
    RAISERROR('Abortado: as tabelas CI.KZN_HIST_* não existem. Rode criar_tabelas_hist.sql antes.', 16, 1);
    RETURN;
END

IF EXISTS (SELECT 1 FROM CI.KZN_HIST_PEDRAVISAOCONSOLIDADA WHERE ID_KAIZEN BETWEEN 7281 AND 7296)
BEGIN
    RAISERROR('Abortado: já existem Kaizens na faixa 7281-7296 em CI.KZN_HIST_PEDRAVISAOCONSOLIDADA. Apague-os antes de recarregar (evita duplicar).', 16, 1);
    RETURN;
END

/* ID_CATEGORIA vem vazia na planilha: se a coluna for NOT NULL, para aqui. */
IF EXISTS (SELECT 1 FROM sys.columns
           WHERE object_id = OBJECT_ID('CI.KZN_HIST_PEDRAVISAOCONSOLIDADA')
             AND name = 'ID_CATEGORIA' AND is_nullable = 0)
BEGIN
    RAISERROR('Abortado: ID_CATEGORIA é NOT NULL em CI.KZN_HIST_PEDRAVISAOCONSOLIDADA, mas as 16 linhas da planilha vêm sem categoria. Rode: ALTER TABLE CI.KZN_HIST_PEDRAVISAOCONSOLIDADA ALTER COLUMN ID_CATEGORIA INT NULL;', 16, 1);
    RETURN;
END

/* Sem GO entre a E0 e a carga, DE PROPÓSITO: RAISERROR + RETURN encerram
   apenas o BATCH em que aparecem. Se houvesse um GO aqui, um aborto
   acima não impediria a carga de rodar logo abaixo. Mantendo tudo no
   mesmo batch, o RETURN realmente barra tudo.
   Tabela temporária criada e usada no mesmo batch é permitida: #tabelas
   têm resolução de nome adiada, ao contrário de tabelas normais. */

BEGIN TRANSACTION;
BEGIN TRY

/* =====================================================================
   E1 - STAGING da tabela principal (ID_REPLICACAO ainda como texto)
   ===================================================================== */
CREATE TABLE #PVC (
    ID_KAIZEN INT, ID_USUARIO_CADASTRO INT, ID_USUARIO_LIDER INT, NM_KAIZEN NVARCHAR(400),
    ID_CATEGORIA INT, TX_REPLICACAO NVARCHAR(200), DS_PROBLEMA NVARCHAR(MAX), DS_OBJETIVO NVARCHAR(MAX),
    ID_APROVADOR INT, URL_IMG_ANTES NVARCHAR(400), DS_ESTADO_ANTES NVARCHAR(MAX), URL_IMG_DEPOIS NVARCHAR(400),
    DS_ESTADO_DEPOIS NVARCHAR(MAX), URL_REFERENCIA NVARCHAR(400), DS_COMPARA_META NVARCHAR(MAX),
    DS_LICOES_APRENDIDAS NVARCHAR(MAX), VL_RESULTADO_FINANCEIRO DECIMAL(18,2), ID_MOEDA INT,
    DS_RESULTADO_ALCANCADO NVARCHAR(MAX), DT_CONCLUSAO DATE, DT_ATUALIZACAO DATETIME2(3),
    ID_USUARIO_ATUALIZACAO INT, DS_MOTIVO NVARCHAR(MAX), ID_STATUS INT);

INSERT INTO #PVC VALUES
(7281, 81034776, 81034776, N'Melhoria para instalação de FSL-2308SA-0021', NULL, N'Others/Outros', N'Problema com antigo fluxostato, para instalação do novo era necessário adequação de conexão na linha de água de selagem da BP-2308SA-32', N'Objetivo realizar adequação para instalação de fluxostato tipo IFM', 10329, N'01 - Imagens/01 - Antes/7281.png', N'Condição do fluxostato anterior, acumulou resíduo internamente vindo a danificar, necessário substituição.', N'01 - Imagens/02 - Depois/7281.png', N'Melhoria consiste em instalação de instrumento mais robusto IFM, com adaptação de conexão soldada diretamente na linha de água de selagem, possibilitando utilizar redução que temos disponível no kanban.', NULL, N'SIM, problema resolvido, objetivo alcançado, Com a instalação de nossa melhoria, possibilitamos partida da BP-2308SA-32 2 em automático e não tivemos mais paradas da mesma por falha no FSL-2308SA-32', N'Adequar situações de forma segura e planejada ajuda na resolução de nossas pendências.', 0, NULL, N'arantir maior agilidade no processo de entrega dos materiais ao executante, por meio da padronização e identificação adequada das peças.', '2025-12-24T00:00:00.000', '2026-09-18T09:53:29.960', 81034776, NULL, 3),
(7282, 81029873, 547667, N'Suporte dos calços da empilhadeira.', NULL, N'Others/Outros', N'Os calços da empilhadeira eram armazenados de forma inadequada e promoviam um ambiente desorganizado,  sem identificação e que dificultava a localização rápida dos calços.

', N'Organização e padronização no armazenamento dos calços.', 10245, N'01 - Imagens/01 - Antes/7282.png', N'Durante a análise do ambiente de trabalho, foi identificado que os calços das empilhadeiras estavam sendo armazenados de forma inadequada, sem qualquer tipo de padronização. Essa falta de estrutura impacta diretamente na eficiência das atividades, podendo gerar atrasos e riscos operacionais.
', N'01 - Imagens/02 - Depois/7282.png', N'A substituição do armazenamento improvisado por um suporte específico e padronizado para calços trouxe diversos benefícios para a operação. Com a instalação do suporte, os calços passaram a ter um local definido e sinalizado, garantindo organização e fácil acesso.
Essa padronização reduz significativamente o tempo gasto na busca pelos calços, aumentando a produtividade e assegurando maior agilidade na preparação das empilhadeiras. Outro ponto relevante é a melhoria na celeridade das atividades, reduzindo atrasos e custos indiretos. 
', NULL, N'Sim, o problema foi resolvido.Os calços das empilhadeiras foram organizados em um suporte padronizado e identificado, garantindo gestão visual e local definido para cada item. Essa ação eliminou a dificuldade de localização, reduziu o tempo de busca e tornou o processo mais ágil e seguro. Além disso, promoveu um ambiente organizado, aumentando a produtividade e reforçando as práticas de segurança.
', N'Aprendemos que a falta de identificação, padronização e organização impacta diretamente a produtividade o que gera custos de forma indireta. A aplicação de práticas simples, como gestão visual, padronização e metodologia 5S, é essencial para evitar perda de tempo e riscos. ', 0, NULL, N'Garantir acesso seguro à praça de resíduos por meio da criação de uma rota adequada na área externa da oficina.
Eliminar riscos de acidentes relacionados à circulação em áreas não preparadas.
Assegurar conformidade com normas de segurança e ergonomia.
Melhorar a mobilidade e eficiência operacional na gestão de componentes e resíduos.
Proporcionar um ambiente de trabalho seguro e organizado.

', '2025-12-31T00:00:00.000', '2026-09-18T09:53:29.960', 81029873, NULL, 1);

INSERT INTO #PVC VALUES
(7283, 81029873, 547667, N'Melhoria nos cabos negativos das máquinas de solda.', NULL, N'Others/Outros', N'Os cabos negativos de solda apresentavam desgaste acelerado e ficavam expostos durante as atividades, gerando riscos de falha operacional e insegurança no ambiente de trabalho.
', N'O objetivo principal do projeto é aumentar a durabilidade e a segurança dos cabos negativos de solda, eliminando o desgaste causado pelo aquecimento das chapas e reduzindo a necessidade de substituições frequentes. Além disso, busca garantir maior proteção contra exposição de cabos deteriorados, prevenindo riscos elétricos e assegurando um ambiente de trabalho mais seguro, com maior eficiência operacional e redução de custos.', 10245, N'01 - Imagens/01 - Antes/7283.png', N'Os cabos negativos de solda apresentavam desgaste acelerado devido ao aquecimento das chapas durante as atividades, o que resultava em substituições frequentes e aumento de custos de manutenção. Além disso, quando os cabos começavam a se deteriorar, ficavam expostos, criando riscos elétricos e comprometendo a segurança dos operadores. Essa situação também impactava a confiabilidade do processo, podendo gerar paradas não programadas e atrasos nas operações, além de contribuir para um ambiente de trabalho menos organizado.
', N'01 - Imagens/02 - Depois/7283.png', N'A implementação do plano consistiu na instalação de um dispositivo de barramento diretamente ligado às chapas onde são realizadas as soldagens. Essa solução permitiu redistribuir a corrente elétrica de forma mais eficiente, reduzindo a sobrecarga térmica nos cabos negativos. Como resultado, os cabos deixaram de sofrer desgaste acelerado, eliminando a necessidade de substituições frequentes. Entre os principais benefícios estão: redução de custos com manutenção, aumento da confiabilidade do processo de soldagem e melhoria significativa na segurança, já que os cabos não ficam mais expostos quando deterioram, prevenindo riscos elétricos e garantindo um ambiente de trabalho mais seguro e organizado.
', NULL, N'O problema foi resolvido com a implementação do barramento. Os resultados obtidos foram muito positivos: os cabos negativos deixaram de sofrer desgaste acelerado, eliminando a necessidade de substituições frequentes. Além disso, houve aumento significativo na segurança, pois os cabos não ficam mais expostos, prevenindo riscos elétricos. A confiabilidade do processo de soldagem também melhorou, evitando paradas não programadas e garantindo maior eficiência operacional.
', N'A implementação do projeto mostrou a importância de identificar a causa raiz antes de propor soluções, garantindo efetividade. Também evidenciou que melhorias simples podem gerar grandes impactos em segurança. Além disso, o planejamento adequado e o envolvimento da equipe operacional foram fundamentais para evitar retrabalho e validar a solução.', 0, NULL, NULL, '2025-12-08T00:00:00.000', '2026-09-18T09:53:29.960', 81029873, NULL, 1),
(7284, 81029873, 547667, N'Identificação das escadas.', NULL, N'Others/Outros', N'Escadas sem identificação adequada podem gerar riscos de acidentes, dificultar a orientação dos colaboradores e comprometer a conformidade com normas de segurança.
', N'Aumentar a segurança e a organização do ambiente, garantindo que todas as escadas estejam claramente sinalizadas para prevenir acidentes e facilitar a localização em situações de emergência e identificar capacidade de carga.', 10245, N'01 - Imagens/01 - Antes/7284.png', N'As escadas do ambiente operacional não possuíam identificação adequada, o que gerava riscos à segurança dos colaboradores, dificultava a orientação e aumentava a probabilidade de acidentes. Além disso, a ausência de sinalização comprometia a organização e a conformidade com normas de segurança, tornando o ambiente menos seguro e eficiente. Essa situação também impactava a agilidade em situações de emergência, podendo causar atrasos e aumentar os riscos.
', N'01 - Imagens/02 - Depois/7284.png', N'Essa solução garantiu maior visibilidade e orientação para os colaboradores, reduzindo riscos de acidentes e melhorando a conformidade com normas de segurança. Como resultado, o ambiente tornou-se mais organizado e seguro, facilitando a localização das escadas em situações de emergência e promovendo maior eficiência operacional. Entre os principais benefícios estão: prevenção de quedas, redução de riscos, identificação de capacidade de carga, aumento da segurança e melhoria na organização do espaço.
', NULL, N'Sim, o problema foi resolvido.
O problema das escadas sem identificação gerava riscos de acidentes e falta de conformidade com normas. A meta era garantir sinalização clara e padronizada para aumentar a segurança e organização. Com a implementação, todas as escadas foram identificadas, reduzindo riscos e melhorando a orientação, atingindo plenamente a meta inicial e tornando o ambiente mais seguro e eficiente.
', N'Aprendemos que a sinalização adequada é essencial para prevenir acidentes e garantir conformidade com normas. Melhorias simples, como identificação clara, têm grande impacto na segurança e organização, e o envolvimento da equipe é fundamental para eficácia da solução.', 0, NULL, N'Resultado esperado alcançado com sucesso.', '2025-12-14T00:00:00.000', '2026-09-18T09:53:29.960', 81029873, NULL, 1);

INSERT INTO #PVC VALUES
(7285, 81063774, 498537, N'PERFIL H ', NULL, N'Others/Outros', N'Durante o processo de montagem do componente Vertimill, a fixação das engrenagens no eixo era realizada por meio de cintas de corrente entrelaçadas no próprio dispositivo. Esse método tinha como finalidade garantir a estabilidade das engrenagens durante as etapas de alinhamento e posicionamento, prevenindo deslocamentos indesejados ou danos às superfícies de contato.', N'Otimizar o risco  de contato direto na peça', 10230, N'01 - Imagens/01 - Antes/7285.png', N'Durante o processo de montagem do componente Vertimill, a fixação das engrenagens no eixo era realizada por meio de cintas de corrente entrelaçadas no próprio dispositivo. Esse método tinha como finalidade garantir a estabilidade das engrenagens durante as etapas de alinhamento e posicionamento, prevenindo deslocamentos indesejados ou danos às superfícies de contato.', N'01 - Imagens/02 - Depois/7285.png', N'Dispositivo mecânico em perfil H, fabricado em aço e desenvolvido internamente na oficina, destinado à remoção do acoplamento de baixa rotação do componente Vertimill, como parte do processo de manutenção, garantir a execução da manutenção dentro do prazo, utilizando métodos seguros e eficientes, preservando a integridade da peça e a segurança da equipe.', NULL, N'Garantir a execução da manutenção dentro do prazo, utilizando métodos seguros e eficientes, preservando a integridade da peça e a segurança da equipe.', N'Planejamento de Ferramentas e Importância da Inovação Interna', 0, NULL, N'Uma boa identificação possibilita atuações mais rápidas e assertivas.', '2025-12-30T00:00:00.000', '2026-09-18T09:53:29.960', 81063774, NULL, 3),
(7286, 81025448, 81025448, N'equipment visibilty', NULL, N'Underground/Subterrâneo', N'on 760 level 3 way intersection with blindspots', N'line of sight with other equipment', 10068, N'01 - Imagens/01 - Antes/7286.png', N'intersections on 760 level were very blind. easily causing equipment collisions', N'01 - Imagens/02 - Depois/7286.png', N'with the use of convex mirrors, the intersection is a lot more visible from all 3 directions', NULL, N'much better equipment flow on levels', N'intersections with heavy equipment need visibilty', 0, NULL, N'N/A', '2025-12-30T00:00:00.000', '2026-09-18T09:53:29.960', 81025448, NULL, 3);

INSERT INTO #PVC VALUES
(7287, 81025448, 81051729, N'equipment visibilty', NULL, N'Underground/Subterrâneo', N'on 790 level 3 way intersection with blindspots', N'line of sight with other equipment', 10068, N'01 - Imagens/01 - Antes/7287.png', N'intersections on 790 level were very blind. easily causing equipment collisions', N'01 - Imagens/02 - Depois/7287.png', N'with the use of convex mirrors, the intersection is a lot more visible from all 3 directions', NULL, N'much better equipment flow on levels', N'intersections with heavy equipment need visibilty', 0, NULL, N'REPLICAMOS NOS OUTRO EQUIPAMENTOS QUE NÃO TINHAM A TAMPA, E MANTENDO A ERGONOMIA DOS MESMO.', '2025-12-31T00:00:00.000', '2026-09-18T09:53:29.960', 81025448, NULL, 3),
(7288, 81025448, 81025448, N'equipment visibilty', NULL, N'Underground/Subterrâneo', N'on 820 level 3 way intersection with blindspots', N'line of sight with other equipment', 10157, N'01 - Imagens/01 - Antes/7288.png', N'intersections on 820 level were very blind. easily causing equipment collisions', N'01 - Imagens/02 - Depois/7288.png', N'with the use of convex mirrors, the intersection is a lot more visible from all 3 directions', NULL, N'much better equipment flow on levels', N'intersections with heavy equipment need visibilty', 0, NULL, N'eficiência e praticidade.  ', '2025-12-31T00:00:00.000', '2026-09-18T09:53:29.960', 81025448, NULL, 3);

INSERT INTO #PVC VALUES
(7289, 81025448, 81025448, N'equipment visibilty', NULL, N'Underground/Subterrâneo', N'on 730 level 3 way intersection with blindspots', N'line of sight with other equipment', 10068, N'01 - Imagens/01 - Antes/7289.png', N'intersections on 730 level were very blind. easily causing equipment collisions', N'01 - Imagens/02 - Depois/7289.png', N'with the use of convex mirrors, the intersection is a lot more visible from all 3 directions', NULL, N'much better equipment flow on levels', N'intersections with heavy equipment need visibilty', 0, NULL, N'Plant hygiene will be easier to maintain', '2025-12-31T00:00:00.000', '2026-09-18T09:53:29.960', 81025448, NULL, 3),
(7290, 81029873, 547667, N'Carro para transporte de peças. ', NULL, N'Others/Outros', N'O transporte manual de peças dentro do setor é realizado de forma pouco eficiente, exigindo esforço físico elevado e aumentando o risco de acidentes e danos às peças. Essa situação impacta a produtividade e a segurança dos colaboradores. É necessário desenvolver uma solução prática que facilite o deslocamento das peças, reduzindo esforço e melhorando a ergonomia no processo.
', N'O projeto teve como objetivo melhorar ergonomia e produtividade, substituindo o carrinho inadequado que causava esforço físico e atrasos. A causa raiz foi a falta de equipamento adequado. A solução foi implementar um carrinho ergonômico e funcional, atingindo a meta de reduzir esforço, aumentar segurança e agilizar o transporte, resultando em menor tempo de execução e maior eficiência operacional.', 10245, N'01 - Imagens/01 - Antes/7290.png', N'O transporte manual de peças dentro do setor é realizado de forma pouco eficiente, exigindo esforço físico elevado e aumentando o risco de acidentes e danos às peças. Essa situação impacta a produtividade e a segurança dos colaboradores. É necessário desenvolver uma solução prática que facilite o deslocamento das peças, reduzindo esforço e melhorando a ergonomia no processo. Ao utilizar um carro que tem medidas especificas e geometrias complexas, o risco de s peça caírem ou danificarem é maior. 
', N'01 - Imagens/02 - Depois/7290.png', N'Identificou-se que o transporte manual de peças causava esforço físico excessivo e baixa eficiência devido à falta de equipamento adequado. O transporte com carrinhos inadequados também promoviam esforços excessivos. Para solucionar, foi desenvolvido e implementado um carrinho específico para movimentação interna. Com essa ação, houve redução do esforço físico, aumento da segurança, melhoria na ergonomia e maior agilidade no processo, garantindo padronização e eficiência operacional.
', NULL, N'Sim, o problema foi resolvido.
O objetivo era reduzir o esforço físico e aumentar a eficiência no transporte interno de peças, conforme declarado no problema inicial. Com a implementação do carrinho, atingimos a meta proposta: houve diminuição significativa do esforço manual, melhoria na ergonomia, aumento da segurança e maior agilidade no processo, atendendo plenamente à necessidade identificada.
', N'Aprendemos que analisar ergonomia e segurança antes de definir processos é essencial, e que soluções simples, como um carrinho, podem gerar grande impacto na eficiência. A participação da equipe na identificação do problema facilita a implementação, e testes práticos são fundamentais para validar a funcionalidade e garantir resultados efetivos.', 0, NULL, N'We reduced 30 minutes by that activity.', '2025-12-25T00:00:00.000', '2026-09-18T09:53:29.960', 81029873, NULL, 1);

INSERT INTO #PVC VALUES
(7291, 81025448, 81051729, N'equipment visibilty', NULL, N'Underground/Subterrâneo', N'on 760 ramp entrance 3 way intersection with blind spots', N'line of sight with other equipment', 10068, N'01 - Imagens/01 - Antes/7291.png', N'entrance on 760 level were very blind. easily causing equipment collisions', N'01 - Imagens/02 - Depois/7291.png', N'with the use of convex mirrors, the intersection is a lot more visible from all 3 directions', NULL, N'much better equipment flow on levels', N'intersections with heavy equipment need visibilty', 0, NULL, N'We reduced time consuming about 30 minutes by the time.', '2025-12-31T00:00:00.000', '2026-09-18T09:53:29.960', 81025448, NULL, 3),
(7292, 81025448, 81030023, N'equipment visibilty', NULL, N'Underground/Subterrâneo', N'on 820 ramp entrance 3 way intersection with blind spots', N'line of sight with other equipment', 10068, N'01 - Imagens/01 - Antes/7292.png', N'entrance on 820 level were very blind. easily causing equipment collisions', N'01 - Imagens/02 - Depois/7292.png', N'with the use of convex mirrors, the intersection is a lot more visible from all 3 directions', NULL, N'much better equipment flow on levels', N'intersections with heavy equipment need visibilty', 0, NULL, N'We reduced injury risk.', '2025-12-30T00:00:00.000', '2026-09-18T09:53:29.960', 81025448, NULL, 3);

INSERT INTO #PVC VALUES
(7293, 81063774, 498537, N'DISPOSITIVO DE MONTAGEM DA BOMBA WEIR ', NULL, N'Others/Outros', N'A montagem das buchas da bomba WEIR era realizada utilizando marretas de borracha como ferramenta auxiliar para ajuste das peças. Esse método apresentava riscos de aplicação de força excessiva, podendo ocasionar deformações nas buchas, desalinhamento dos componentes e redução da vida útil do conjunto.', N'Desenvolver e implementar um dispositivo específico para montagem das buchas da bomba WEIR vertical, garantindo aplicação de força controlada e uniforme.', 10230, N'01 - Imagens/01 - Antes/7293.png', N'A montagem das buchas da bomba WEIR era realizada utilizando marretas de borracha como ferramenta auxiliar para ajuste das peças. Esse método apresentava riscos de aplicação de força excessiva, podendo ocasionar deformações nas buchas, desalinhamento dos componentes e redução da vida útil do conjunto.', N'01 - Imagens/02 - Depois/7293.png', N'Dispositivo para montagem da bomba WEIR vertical na balsa, desenvolvido para realizar o impacto das buchas durante o processo de montagem. O objetivo é evitar esforços excessivos no prensamento, que podem causar danos às buchas durante a instalação.', NULL, N' Montagem manual com marretas → alta variabilidade, risco de danos, falta de controle de força.
Implementação de dispositivo de montagem → força aplicada de forma controlada, redução de danos, aumento da precisão e padronização do processo.', N'esforços não controlados', 0, NULL, N'Time saved when signing out monitors', '2025-12-29T00:00:00.000', '2026-09-18T09:53:29.960', 81063774, NULL, 3),
(7294, 81063774, 81063774, N'Suporte de identificação do guanital 				', NULL, N'Others/Outros', N'Guanital  na área da ferramentaria sem identificação, ocasionando desgaste de tempo significativa para os colaboradores na verificação e determinação da medida correta.', N'visão de 3 segundos ', 10226, N'01 - Imagens/01 - Antes/7294.png', N'Guanital  na área da ferramentaria sem identificação, ocasionando desgaste de tempo significativa para os colaboradores na verificação e determinação da medida correta.', N'01 - Imagens/02 - Depois/7294.png', N' Fabricado um suporte para inclusão de placas de identificação, proporcionando maior agilidade no processo de entrega do material ao executante.', NULL, N'Problema Identificado: A ausência de suporte para placas de identificação causava atrasos na entrega e dificultava a rastreabilidade do material.
Impacto: Aumentava o tempo de execução e gerava risco de erros na identificação dos materiais.
Solução Aplicada: Desenvolvimento e fabricação do suporte para placas, garantindo padronização e agilidade.', N'Senso de 3 segundos melhora o processo ', 0, NULL, N'Obtido um suporte resistente e funcional, que melhore a organização, a ergonomia e a higiene no uso do cooler e dos fardos de água mineral.', '2025-10-28T00:00:00.000', '2026-09-18T09:53:29.960', 81063774, NULL, 3);

INSERT INTO #PVC VALUES
(7295, 81063774, 544555, N'Adeguação da área externa com caminho seguro 				', NULL, N'Others/Outros', N'Área externa da oficina, destinada à gestão de componentes, sem rota segura para acesso à praça de resíduos.', N'Realizar o caminho seguro ', 10226, N'01 - Imagens/01 - Antes/7295.png', N'Área externa da oficina, destinada à gestão de componentes, sem rota segura para acesso à praça de resíduos.', N'01 - Imagens/02 - Depois/7295.png', N'Após a identificação da ausência de um caminho seguro nas áreas externas, foi aberto um chamado para a equipe industrial realizar a criação do acesso, garantindo um ambiente de trabalho seguro e conforme as normas de SSMA.', NULL, N'Antes: Ausência de rota segura → risco elevado de acidentes, não conformidade com normas, baixa ergonomia.
Depois: Criação de caminho seguro pela equipe industrial → ambiente seguro, redução de riscos, conformidade com normas e melhoria na mobilidade.', N'segurança ', 0, NULL, N'Garantir a fixação segura do tambor de graxa, reduzindo riscos de tombamento, vazamentos e acidentes, além de aumentar a segurança operacional e a organização do local de trabalho.', '2025-11-11T00:00:00.000', '2026-09-18T09:53:29.960', 81063774, NULL, 3),
(7296, 503436, 503436, N'MONITORAMENTO THE ENDURECE DYNAMOX', NULL, N'Projects/Projetos', N'ANTERIORMENTE TINHAMOS QUE REALIZAR AS COLETAS DEPEDENDO DOS OPERADORES NA FORTA 793 D E 797F. ESPERANDO 1 HORA DE AGUARDO E ATRASANDO A OPERAÇÃO.', N'COLETAR A VIBRAÇÃO DE FORMA SEGURA', 10015, N'01 - Imagens/01 - Antes/7296.png', N'AS COLETAS ERAM FEITAS PRÓXIMAS DOS EQUIPAMENTOS FUNCIONANDO EM 1400 RPM COM RISCO DE SER ATROPELADO OU BATIDA CONTRA.', N'01 - Imagens/02 - Depois/7296.png', N'AO RELIAZARMOS AS INSTALAÇÕES DOS SENSORES PORTABLES ANTES DE FUNCIONAR O CAMINHÃO BLOQUEANDO E EM SEGUIDA INSTALANDO 10 SENSORES NOS PONTOS DE MONITORAMENTO, PODE SUBIR NA CABINE E COLETAR DE FORMA SEGURA.', NULL, N'SIM MAIOR AGILIDADE E SEGURANÇA NAS COLETAS NA CABINE EVITANDO A EXPOSIÇÃO DOS COLABORADORES A LINHAS DE EXPLOSÃO DE PNEU OU ATROPLEAMENTO.', N'SEGURANÇA E MAIOR AGILIDADE', 2, 1, N'less contamination to deal with', '2025-12-31T00:00:00.000', '2026-09-18T09:53:29.960', 503436, NULL, 2);

/* =====================================================================
   E2 - Tabela principal: converte ID_REPLICACAO pelo nome e insere
   ---------------------------------------------------------------------
   OUTER APPLY (não CROSS APPLY): sem correspondência, ID_REPLICACAO
   entra NULL e a linha do Kaizen é preservada. TOP 1 por ID_IDIOMA
   porque KZN_REPLICACAO tem PK composta (ID_REPLICACAO, ID_IDIOMA) e
   traz uma linha por idioma.
   ===================================================================== */
INSERT INTO CI.KZN_HIST_PEDRAVISAOCONSOLIDADA
    (ID_KAIZEN, ID_USUARIO_CADASTRO, ID_USUARIO_LIDER, NM_KAIZEN, ID_CATEGORIA, ID_REPLICACAO,
     DS_PROBLEMA, DS_OBJETIVO, ID_APROVADOR, URL_IMG_ANTES, DS_ESTADO_ANTES, URL_IMG_DEPOIS,
     DS_ESTADO_DEPOIS, URL_REFERENCIA, DS_COMPARA_META, DS_LICOES_APRENDIDAS,
     VL_RESULTADO_FINANCEIRO, ID_MOEDA, DS_RESULTADO_ALCANCADO, DT_CONCLUSAO, DT_ATUALIZACAO,
     ID_USUARIO_ATUALIZACAO, DS_MOTIVO, ID_STATUS)
SELECT  p.ID_KAIZEN, p.ID_USUARIO_CADASTRO, p.ID_USUARIO_LIDER, p.NM_KAIZEN, p.ID_CATEGORIA, r.ID_REPLICACAO,
        p.DS_PROBLEMA, p.DS_OBJETIVO, p.ID_APROVADOR, p.URL_IMG_ANTES, p.DS_ESTADO_ANTES, p.URL_IMG_DEPOIS,
        p.DS_ESTADO_DEPOIS, p.URL_REFERENCIA, p.DS_COMPARA_META, p.DS_LICOES_APRENDIDAS,
        p.VL_RESULTADO_FINANCEIRO, p.ID_MOEDA, p.DS_RESULTADO_ALCANCADO, p.DT_CONCLUSAO, p.DT_ATUALIZACAO,
        p.ID_USUARIO_ATUALIZACAO, p.DS_MOTIVO, p.ID_STATUS
FROM        #PVC p
OUTER APPLY (SELECT TOP (1) d.ID_REPLICACAO
             FROM   CI.KZN_REPLICACAO d
             WHERE  LTRIM(RTRIM(d.NM_REPLICACAO)) COLLATE Latin1_General_CI_AI
                    IN (LTRIM(RTRIM(p.TX_REPLICACAO))                                           COLLATE Latin1_General_CI_AI,
                        LTRIM(RTRIM(LEFT(p.TX_REPLICACAO, NULLIF(CHARINDEX('/', p.TX_REPLICACAO),0) - 1))) COLLATE Latin1_General_CI_AI,
                        LTRIM(RTRIM(SUBSTRING(p.TX_REPLICACAO, NULLIF(CHARINDEX('/', p.TX_REPLICACAO),0) + 1, 200))) COLLATE Latin1_General_CI_AI)
             ORDER BY d.ID_IDIOMA) r
ORDER BY p.ID_KAIZEN;

PRINT '  E2 - KZN_HIST_PEDRAVISAOCONSOLIDADA: ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' linha(s).';

/* =====================================================================
   E3 - Membros de equipe
   ===================================================================== */
INSERT INTO CI.KZN_HIST_MEMBROS_EQUIPE (ID_KAIZEN, ID_USUARIO, DT_ATUALIZACAO) VALUES
(7281, 4303, '2026-01-01T05:52:19.000'),
(7282, 10498, '2026-01-01T10:22:08.000'),
(7282, 4322, '2026-01-01T10:22:08.000'),
(7283, 10499, '2026-01-01T11:11:18.000'),
(7283, 4342, '2026-01-01T11:11:18.000'),
(7284, 10264, '2026-01-01T11:43:59.000'),
(7284, 10500, '2026-01-01T11:43:59.000'),
(7285, 4380, '2026-01-01T11:57:20.000'),
(7285, 4385, '2026-01-01T11:57:20.000'),
(7285, 4423, '2026-01-01T11:57:20.000');
INSERT INTO CI.KZN_HIST_MEMBROS_EQUIPE (ID_KAIZEN, ID_USUARIO, DT_ATUALIZACAO) VALUES
(7286, 10501, '2026-01-01T12:03:59.000'),
(7287, 10502, '2026-01-01T12:08:24.000'),
(7288, 10501, '2026-01-01T12:13:13.000'),
(7289, 10446, '2026-01-01T12:18:16.000'),
(7290, 10498, '2026-01-01T12:18:33.000'),
(7290, 4341, '2026-01-01T12:18:33.000'),
(7290, 10499, '2026-01-01T12:18:33.000'),
(7291, 10502, '2026-01-01T12:27:57.000'),
(7292, 10502, '2026-01-01T12:28:44.000'),
(7293, 4380, '2026-01-01T17:20:35.000');
INSERT INTO CI.KZN_HIST_MEMBROS_EQUIPE (ID_KAIZEN, ID_USUARIO, DT_ATUALIZACAO) VALUES
(7293, 4385, '2026-01-01T17:20:35.000'),
(7293, 4398, '2026-01-01T17:20:35.000'),
(7294, 1851, '2026-01-01T18:10:46.000'),
(7294, 4385, '2026-01-01T18:10:46.000'),
(7294, 4381, '2026-01-01T18:10:46.000'),
(7295, 1851, '2026-01-01T18:45:02.000'),
(7295, 4469, '2026-01-01T18:45:02.000'),
(7295, NULL, '2026-01-01T18:45:02.000'),
(7296, 8834, '2026-01-01T23:51:21.000'),
(7296, 1766, '2026-01-01T23:51:21.000');
PRINT '  E3 - KZN_HIST_MEMBROS_EQUIPE: 30 linha(s).';

/* =====================================================================
   E4 - Resultados
   ===================================================================== */
INSERT INTO CI.KZN_HIST_RESULTADO_KAIZEN (ID_KAIZEN, ID_RESULTADO, DT_ATUALIZACAO) VALUES
(7281, 2, '2026-01-01T05:52:19.000'),
(7282, 6, '2026-01-01T10:22:08.000'),
(7283, 1, '2026-01-01T11:11:18.000'),
(7284, 1, '2026-01-01T11:43:59.000'),
(7285, 3, '2026-01-01T11:57:20.000'),
(7286, 1, '2026-01-01T12:03:59.000'),
(7287, 1, '2026-01-01T12:08:24.000'),
(7288, 1, '2026-01-01T12:13:13.000'),
(7289, 1, '2026-01-01T12:18:16.000'),
(7290, 1, '2026-01-01T12:18:33.000');
INSERT INTO CI.KZN_HIST_RESULTADO_KAIZEN (ID_KAIZEN, ID_RESULTADO, DT_ATUALIZACAO) VALUES
(7291, 1, '2026-01-01T12:27:57.000'),
(7292, 1, '2026-01-01T12:28:44.000'),
(7293, 3, '2026-01-01T17:20:35.000'),
(7294, 3, '2026-01-01T18:10:46.000'),
(7295, 5, '2026-01-01T18:45:02.000'),
(7296, NULL, '2026-01-01T23:51:21.000');
PRINT '  E4 - KZN_HIST_RESULTADO_KAIZEN: 16 linha(s).';

/* =====================================================================
   E5 - Fotografia da hierarquia
   ===================================================================== */
INSERT INTO CI.KZN_HIST_KAIZEN_HIERARQUIA (ID_KAIZEN, ID_USUARIO_LIDER, NM_HIERARQUIA_N1, NM_HIERARQUIA_N2, NM_HIERARQUIA_N3, NM_HIERARQUIA_N4, NM_HIERARQUIA_N5, NM_HIERARQUIA_N6, NM_HIERARQUIA_N7, NM_HIERARQUIA_N8, DT_ATUALIZACAO) VALUES
(7281, 81034776, N'PRESIDENTE - GUSTAVO DUARTE PIMENTA', N'CEO, BASE METALS - SHAUN ALLEYNE USMAR', N'CHIEF OPERATING OFFICER - BM - ALFREDO PONTES DE SANTANA', N'DIRETOR DE OPERACOES - SALOBO - ANTONIO SCHETTINO GOMES PEREIRA', N'DIR USINAS SALOBO I/II/IIII - ADEILSON RODRIGUES', N'GER GERAL MANUT USINA SALOBO - ALLAN NUNES SANTOS', N'GER MANUTENC ELETRICA SALOBO - CHARLES TASSIO DE FARIA', N'SUP MANUT CORRETIVA - RODOLFO VASCONCELOS DE MENEZES', '2026-01-01T05:52:19.000');
INSERT INTO CI.KZN_HIST_KAIZEN_HIERARQUIA (ID_KAIZEN, ID_USUARIO_LIDER, NM_HIERARQUIA_N1, NM_HIERARQUIA_N2, NM_HIERARQUIA_N3, NM_HIERARQUIA_N4, NM_HIERARQUIA_N5, NM_HIERARQUIA_N6, NM_HIERARQUIA_N7, NM_HIERARQUIA_N8, DT_ATUALIZACAO) VALUES
(7282, 547667, N'PRESIDENTE - GUSTAVO DUARTE PIMENTA', N'CEO, BASE METALS - SHAUN ALLEYNE USMAR', N'CHIEF OPERATING OFFICER - BM - ALFREDO PONTES DE SANTANA', N'DIR OPER SOSSEGO BM - VINICIUS MOREIRA ASSIS', N'GER GERAL OPERACOES SOSSEGO - FRANCISCO ISAIAS LOPES DE OLIVEIRA SILVA', N'GER MANUTENC ELETRICA SOSSEGO - MONIQUE ALEIXO DE SOUZA', N'SUP GEST COMPONENTES MINERACAO - RAISSA SOARES DE ARAUJO', NULL, '2026-01-01T10:22:08.000');
INSERT INTO CI.KZN_HIST_KAIZEN_HIERARQUIA (ID_KAIZEN, ID_USUARIO_LIDER, NM_HIERARQUIA_N1, NM_HIERARQUIA_N2, NM_HIERARQUIA_N3, NM_HIERARQUIA_N4, NM_HIERARQUIA_N5, NM_HIERARQUIA_N6, NM_HIERARQUIA_N7, NM_HIERARQUIA_N8, DT_ATUALIZACAO) VALUES
(7283, 547667, N'PRESIDENTE - GUSTAVO DUARTE PIMENTA', N'CEO, BASE METALS - SHAUN ALLEYNE USMAR', N'CHIEF OPERATING OFFICER - BM - ALFREDO PONTES DE SANTANA', N'DIR OPER SOSSEGO BM - VINICIUS MOREIRA ASSIS', N'GER GERAL OPERACOES SOSSEGO - FRANCISCO ISAIAS LOPES DE OLIVEIRA SILVA', N'GER MANUTENC ELETRICA SOSSEGO - MONIQUE ALEIXO DE SOUZA', N'SUP GEST COMPONENTES MINERACAO - RAISSA SOARES DE ARAUJO', NULL, '2026-01-01T11:11:18.000');
INSERT INTO CI.KZN_HIST_KAIZEN_HIERARQUIA (ID_KAIZEN, ID_USUARIO_LIDER, NM_HIERARQUIA_N1, NM_HIERARQUIA_N2, NM_HIERARQUIA_N3, NM_HIERARQUIA_N4, NM_HIERARQUIA_N5, NM_HIERARQUIA_N6, NM_HIERARQUIA_N7, NM_HIERARQUIA_N8, DT_ATUALIZACAO) VALUES
(7284, 547667, N'PRESIDENTE - GUSTAVO DUARTE PIMENTA', N'CEO, BASE METALS - SHAUN ALLEYNE USMAR', N'CHIEF OPERATING OFFICER - BM - ALFREDO PONTES DE SANTANA', N'DIR OPER SOSSEGO BM - VINICIUS MOREIRA ASSIS', N'GER GERAL OPERACOES SOSSEGO - FRANCISCO ISAIAS LOPES DE OLIVEIRA SILVA', N'GER MANUTENC ELETRICA SOSSEGO - MONIQUE ALEIXO DE SOUZA', N'SUP GEST COMPONENTES MINERACAO - RAISSA SOARES DE ARAUJO', NULL, '2026-01-01T11:43:59.000');
INSERT INTO CI.KZN_HIST_KAIZEN_HIERARQUIA (ID_KAIZEN, ID_USUARIO_LIDER, NM_HIERARQUIA_N1, NM_HIERARQUIA_N2, NM_HIERARQUIA_N3, NM_HIERARQUIA_N4, NM_HIERARQUIA_N5, NM_HIERARQUIA_N6, NM_HIERARQUIA_N7, NM_HIERARQUIA_N8, DT_ATUALIZACAO) VALUES
(7285, 498537, N'PRESIDENTE - GUSTAVO DUARTE PIMENTA', N'CEO, BASE METALS - SHAUN ALLEYNE USMAR', N'CHIEF OPERATING OFFICER - BM - ALFREDO PONTES DE SANTANA', N'DIRETOR DE OPERACOES - SALOBO - ANTONIO SCHETTINO GOMES PEREIRA', N'DIR USINAS SALOBO I/II/IIII - ADEILSON RODRIGUES', N'GER GERAL MANUT USINA SALOBO - ALLAN NUNES SANTOS', N'GER GESTAO COMPONENT MINERACAO - WALLACE BARCELOS (INTERINO)', N'SUP GESTAO COMPONENT MINERACAO - ADRIANA ALVES PEREIRA', '2026-01-01T11:57:20.000');
INSERT INTO CI.KZN_HIST_KAIZEN_HIERARQUIA (ID_KAIZEN, ID_USUARIO_LIDER, NM_HIERARQUIA_N1, NM_HIERARQUIA_N2, NM_HIERARQUIA_N3, NM_HIERARQUIA_N4, NM_HIERARQUIA_N5, NM_HIERARQUIA_N6, NM_HIERARQUIA_N7, NM_HIERARQUIA_N8, DT_ATUALIZACAO) VALUES
(7286, 81025448, N'PRESIDENTE - GUSTAVO DUARTE PIMENTA', N'CEO, BASE METALS - SHAUN ALLEYNE USMAR', N'CHIEF OPERATING OFFICER - BM - ALFREDO PONTES DE SANTANA', N'DIR, VNL & INTERNATIONAL REFIN - ROBERTO MATOS DAMASCENO', N'DIR, VB OPERATIONS - PIETER J LOOCK', N'MANAGER, VOISEY''S BAY MINES - GLEN HOUSE', N'Supt, Mining Operations - Jonathan Stanley', N'Supv, Ug Mine Ops - Vbme - Bill May', '2026-01-01T12:03:59.000');
INSERT INTO CI.KZN_HIST_KAIZEN_HIERARQUIA (ID_KAIZEN, ID_USUARIO_LIDER, NM_HIERARQUIA_N1, NM_HIERARQUIA_N2, NM_HIERARQUIA_N3, NM_HIERARQUIA_N4, NM_HIERARQUIA_N5, NM_HIERARQUIA_N6, NM_HIERARQUIA_N7, NM_HIERARQUIA_N8, DT_ATUALIZACAO) VALUES
(7287, 81051729, N'PRESIDENTE - GUSTAVO DUARTE PIMENTA', N'CEO, BASE METALS - SHAUN ALLEYNE USMAR', N'CHIEF OPERATING OFFICER - BM - ALFREDO PONTES DE SANTANA', N'DIR, VNL & INTERNATIONAL REFIN - ROBERTO MATOS DAMASCENO', N'DIR, VB OPERATIONS - PIETER J LOOCK', N'MANAGER, VOISEY''S BAY MINES - GLEN HOUSE', N'Supt, Mining Operations - Jonathan Stanley', N'Supv, Ug Mine Ops - Vbme - Bill May', '2026-01-01T12:08:24.000');
INSERT INTO CI.KZN_HIST_KAIZEN_HIERARQUIA (ID_KAIZEN, ID_USUARIO_LIDER, NM_HIERARQUIA_N1, NM_HIERARQUIA_N2, NM_HIERARQUIA_N3, NM_HIERARQUIA_N4, NM_HIERARQUIA_N5, NM_HIERARQUIA_N6, NM_HIERARQUIA_N7, NM_HIERARQUIA_N8, DT_ATUALIZACAO) VALUES
(7288, 81025448, N'PRESIDENTE - GUSTAVO DUARTE PIMENTA', N'CEO, BASE METALS - SHAUN ALLEYNE USMAR', N'CHIEF OPERATING OFFICER - BM - ALFREDO PONTES DE SANTANA', N'DIR, VNL & INTERNATIONAL REFIN - ROBERTO MATOS DAMASCENO', N'DIR, VB OPERATIONS - PIETER J LOOCK', N'MANAGER, VOISEY''S BAY MINES - GLEN HOUSE', N'Supt, Mining Operations - Jonathan Stanley', N'Supv, Ug Mine Ops - Vbme - Bill May', '2026-01-01T12:13:13.000');
INSERT INTO CI.KZN_HIST_KAIZEN_HIERARQUIA (ID_KAIZEN, ID_USUARIO_LIDER, NM_HIERARQUIA_N1, NM_HIERARQUIA_N2, NM_HIERARQUIA_N3, NM_HIERARQUIA_N4, NM_HIERARQUIA_N5, NM_HIERARQUIA_N6, NM_HIERARQUIA_N7, NM_HIERARQUIA_N8, DT_ATUALIZACAO) VALUES
(7289, 81025448, N'PRESIDENTE - GUSTAVO DUARTE PIMENTA', N'CEO, BASE METALS - SHAUN ALLEYNE USMAR', N'CHIEF OPERATING OFFICER - BM - ALFREDO PONTES DE SANTANA', N'DIR, VNL & INTERNATIONAL REFIN - ROBERTO MATOS DAMASCENO', N'DIR, VB OPERATIONS - PIETER J LOOCK', N'MANAGER, VOISEY''S BAY MINES - GLEN HOUSE', N'Supt, Mining Operations - Jonathan Stanley', N'Supv, Ug Mine Ops - Vbme - Bill May', '2026-01-01T12:18:16.000');
INSERT INTO CI.KZN_HIST_KAIZEN_HIERARQUIA (ID_KAIZEN, ID_USUARIO_LIDER, NM_HIERARQUIA_N1, NM_HIERARQUIA_N2, NM_HIERARQUIA_N3, NM_HIERARQUIA_N4, NM_HIERARQUIA_N5, NM_HIERARQUIA_N6, NM_HIERARQUIA_N7, NM_HIERARQUIA_N8, DT_ATUALIZACAO) VALUES
(7290, 547667, N'PRESIDENTE - GUSTAVO DUARTE PIMENTA', N'CEO, BASE METALS - SHAUN ALLEYNE USMAR', N'CHIEF OPERATING OFFICER - BM - ALFREDO PONTES DE SANTANA', N'DIR OPER SOSSEGO BM - VINICIUS MOREIRA ASSIS', N'GER GERAL OPERACOES SOSSEGO - FRANCISCO ISAIAS LOPES DE OLIVEIRA SILVA', N'GER MANUTENC ELETRICA SOSSEGO - MONIQUE ALEIXO DE SOUZA', N'SUP GEST COMPONENTES MINERACAO - RAISSA SOARES DE ARAUJO', NULL, '2026-01-01T12:18:33.000');
INSERT INTO CI.KZN_HIST_KAIZEN_HIERARQUIA (ID_KAIZEN, ID_USUARIO_LIDER, NM_HIERARQUIA_N1, NM_HIERARQUIA_N2, NM_HIERARQUIA_N3, NM_HIERARQUIA_N4, NM_HIERARQUIA_N5, NM_HIERARQUIA_N6, NM_HIERARQUIA_N7, NM_HIERARQUIA_N8, DT_ATUALIZACAO) VALUES
(7291, 81051729, N'PRESIDENTE - GUSTAVO DUARTE PIMENTA', N'CEO, BASE METALS - SHAUN ALLEYNE USMAR', N'CHIEF OPERATING OFFICER - BM - ALFREDO PONTES DE SANTANA', N'DIR, VNL & INTERNATIONAL REFIN - ROBERTO MATOS DAMASCENO', N'DIR, VB OPERATIONS - PIETER J LOOCK', N'MANAGER, VOISEY''S BAY MINES - GLEN HOUSE', N'Supt, Mining Operations - Jonathan Stanley', N'Supv, Ug Mine Ops - Vbme - Bill May', '2026-01-01T12:27:57.000');
INSERT INTO CI.KZN_HIST_KAIZEN_HIERARQUIA (ID_KAIZEN, ID_USUARIO_LIDER, NM_HIERARQUIA_N1, NM_HIERARQUIA_N2, NM_HIERARQUIA_N3, NM_HIERARQUIA_N4, NM_HIERARQUIA_N5, NM_HIERARQUIA_N6, NM_HIERARQUIA_N7, NM_HIERARQUIA_N8, DT_ATUALIZACAO) VALUES
(7292, 81030023, N'PRESIDENTE - GUSTAVO DUARTE PIMENTA', N'CEO, BASE METALS - SHAUN ALLEYNE USMAR', N'CHIEF OPERATING OFFICER - BM - ALFREDO PONTES DE SANTANA', N'DIR, VNL & INTERNATIONAL REFIN - ROBERTO MATOS DAMASCENO', N'DIR, VB OPERATIONS - PIETER J LOOCK', N'MANAGER, VOISEY''S BAY MINES - GLEN HOUSE', N'Supt, Mining Operations - Jonathan Stanley', N'Supv, Ug Mine Ops - Vbme - Bill May', '2026-01-01T12:28:44.000');
INSERT INTO CI.KZN_HIST_KAIZEN_HIERARQUIA (ID_KAIZEN, ID_USUARIO_LIDER, NM_HIERARQUIA_N1, NM_HIERARQUIA_N2, NM_HIERARQUIA_N3, NM_HIERARQUIA_N4, NM_HIERARQUIA_N5, NM_HIERARQUIA_N6, NM_HIERARQUIA_N7, NM_HIERARQUIA_N8, DT_ATUALIZACAO) VALUES
(7293, 498537, N'PRESIDENTE - GUSTAVO DUARTE PIMENTA', N'CEO, BASE METALS - SHAUN ALLEYNE USMAR', N'CHIEF OPERATING OFFICER - BM - ALFREDO PONTES DE SANTANA', N'DIRETOR DE OPERACOES - SALOBO - ANTONIO SCHETTINO GOMES PEREIRA', N'DIR USINAS SALOBO I/II/IIII - ADEILSON RODRIGUES', N'GER GERAL MANUT USINA SALOBO - ALLAN NUNES SANTOS', N'GER GESTAO COMPONENT MINERACAO - WALLACE BARCELOS (INTERINO)', N'SUP GESTAO COMPONENT MINERACAO - ADRIANA ALVES PEREIRA', '2026-01-01T17:20:35.000');
INSERT INTO CI.KZN_HIST_KAIZEN_HIERARQUIA (ID_KAIZEN, ID_USUARIO_LIDER, NM_HIERARQUIA_N1, NM_HIERARQUIA_N2, NM_HIERARQUIA_N3, NM_HIERARQUIA_N4, NM_HIERARQUIA_N5, NM_HIERARQUIA_N6, NM_HIERARQUIA_N7, NM_HIERARQUIA_N8, DT_ATUALIZACAO) VALUES
(7294, 81063774, N'PRESIDENTE - GUSTAVO DUARTE PIMENTA', N'CEO, BASE METALS - SHAUN ALLEYNE USMAR', N'CHIEF OPERATING OFFICER - BM - ALFREDO PONTES DE SANTANA', N'DIRETOR DE OPERACOES - SALOBO - ANTONIO SCHETTINO GOMES PEREIRA', N'DIR USINAS SALOBO I/II/IIII - ADEILSON RODRIGUES', N'GER GERAL MANUT USINA SALOBO - ALLAN NUNES SANTOS', N'GER GESTAO COMPONENT MINERACAO - WALLACE BARCELOS (INTERINO)', N'SUP GESTAO COMPONENT MINERACAO - ADRIANA ALVES PEREIRA', '2026-01-01T18:10:46.000');
INSERT INTO CI.KZN_HIST_KAIZEN_HIERARQUIA (ID_KAIZEN, ID_USUARIO_LIDER, NM_HIERARQUIA_N1, NM_HIERARQUIA_N2, NM_HIERARQUIA_N3, NM_HIERARQUIA_N4, NM_HIERARQUIA_N5, NM_HIERARQUIA_N6, NM_HIERARQUIA_N7, NM_HIERARQUIA_N8, DT_ATUALIZACAO) VALUES
(7295, 544555, N'PRESIDENTE - GUSTAVO DUARTE PIMENTA', N'CEO, BASE METALS - SHAUN ALLEYNE USMAR', N'CHIEF OPERATING OFFICER - BM - ALFREDO PONTES DE SANTANA', N'DIRETOR DE OPERACOES - SALOBO - ANTONIO SCHETTINO GOMES PEREIRA', N'DIR USINAS SALOBO I/II/IIII - ADEILSON RODRIGUES', N'GER GERAL MANUT USINA SALOBO - ALLAN NUNES SANTOS', N'GER GESTAO COMPONENT MINERACAO - WALLACE BARCELOS (INTERINO)', N'SUP GESTAO COMPONENT MINERACAO - ADRIANA ALVES PEREIRA', '2026-01-01T18:45:02.000');
INSERT INTO CI.KZN_HIST_KAIZEN_HIERARQUIA (ID_KAIZEN, ID_USUARIO_LIDER, NM_HIERARQUIA_N1, NM_HIERARQUIA_N2, NM_HIERARQUIA_N3, NM_HIERARQUIA_N4, NM_HIERARQUIA_N5, NM_HIERARQUIA_N6, NM_HIERARQUIA_N7, NM_HIERARQUIA_N8, DT_ATUALIZACAO) VALUES
(7296, 503436, N'PRESIDENTE - GUSTAVO DUARTE PIMENTA', N'CEO, BASE METALS - SHAUN ALLEYNE USMAR', N'CHIEF OPERATING OFFICER - BM - ALFREDO PONTES DE SANTANA', N'DIRETOR DE OPERACOES - SALOBO - ANTONIO SCHETTINO GOMES PEREIRA', N'DIR MINING SALOBO - BRUNO DE ALVARENGA SOARES', N'MANUTENÇÃO MINA - BRUNO DE ALVARENGA SOARES', N'GER INSP CONFIAB E ENG ATL SUL - GEOVANE ROSSO FELIPE', N'SUP PROC MANUT EQ MOVEIS PERF. - EWERTON FERNANDES NASCIMENTO', '2026-01-01T23:51:21.000');
PRINT '  E5 - KZN_HIST_KAIZEN_HIERARQUIA: 16 linha(s).';

/* =====================================================================
   E6 - Desperdícios: converte NM_DESPERDICIO pelo nome
   ---------------------------------------------------------------------
   Na planilha ID_DESPERDICIO vem vazio e só NM_DESPERDICIO está
   preenchido, então o ID é resolvido pelo nome, mesma lógica da E2.
   ===================================================================== */
CREATE TABLE #DESP (ID_KAIZEN INT, TX_DESPERDICIO NVARCHAR(200), DT_ATUALIZACAO DATETIME2(3));

INSERT INTO #DESP VALUES
(7281, N'Defects/Defeitos', '2026-01-01T05:52:19.000'),
(7282, N'Motion/Movimento', '2026-01-01T10:22:08.000'),
(7282, N'Inventory/Inventário', '2026-01-01T10:22:08.000'),
(7282, N'Waiting/Em espera', '2026-01-01T10:22:08.000'),
(7283, N'Inventory/Inventário', '2026-01-01T11:11:18.000'),
(7283, N'Defects/Defeitos', '2026-01-01T11:11:18.000'),
(7284, N'Motion/Movimento', '2026-01-01T11:43:59.000'),
(7284, N'Defects/Defeitos', '2026-01-01T11:43:59.000'),
(7284, N'Waiting/Em espera', '2026-01-01T11:43:59.000'),
(7285, N'Overprocessing/Processamento excessivo', '2026-01-01T11:57:20.000');
INSERT INTO #DESP VALUES
(7286, N'Defects/Defeitos', '2026-01-01T12:03:59.000'),
(7287, N'Defects/Defeitos', '2026-01-01T12:08:24.000'),
(7288, N'Defects/Defeitos', '2026-01-01T12:13:13.000'),
(7289, N'Defects/Defeitos', '2026-01-01T12:18:16.000'),
(7290, N'Ergonomics', '2026-01-01T12:18:33.000'),
(7290, N'Overburden/Sobrecarga', '2026-01-01T12:18:33.000'),
(7290, N'Motion/Movimento', '2026-01-01T12:18:33.000'),
(7290, N'Defects/Defeitos', '2026-01-01T12:18:33.000'),
(7291, N'Defects/Defeitos', '2026-01-01T12:27:57.000'),
(7292, N'Defects/Defeitos', '2026-01-01T12:28:44.000');
INSERT INTO #DESP VALUES
(7293, N'Motion/Movimento', '2026-01-01T17:20:35.000'),
(7294, N'Motion/Movimento', '2026-01-01T18:10:46.000'),
(7294, N'Waiting/Em espera', '2026-01-01T18:10:46.000'),
(7295, N'Transportation/Transporte', '2026-01-01T18:45:02.000'),
(7296, N'Waiting/Em espera', '2026-01-01T23:51:21.000');

INSERT INTO CI.KZN_HIST_KAIZEN_DESPERDICIO (ID_KAIZEN, ID_DESPERDICIO, DT_ATUALIZACAO)
SELECT  d.ID_KAIZEN, w.ID_DESPERDICIO, d.DT_ATUALIZACAO
FROM        #DESP d
OUTER APPLY (SELECT TOP (1) x.ID_DESPERDICIO
             FROM   CI.KZN_DESPERDICIO x
             WHERE  LTRIM(RTRIM(x.NM_DESPERDICIO)) COLLATE Latin1_General_CI_AI
                    IN (LTRIM(RTRIM(d.TX_DESPERDICIO))                                            COLLATE Latin1_General_CI_AI,
                        LTRIM(RTRIM(LEFT(d.TX_DESPERDICIO, NULLIF(CHARINDEX('/', d.TX_DESPERDICIO),0) - 1))) COLLATE Latin1_General_CI_AI,
                        LTRIM(RTRIM(SUBSTRING(d.TX_DESPERDICIO, NULLIF(CHARINDEX('/', d.TX_DESPERDICIO),0) + 1, 200))) COLLATE Latin1_General_CI_AI)
             ORDER BY x.ID_IDIOMA) w
ORDER BY d.ID_KAIZEN;

PRINT '  E6 - KZN_HIST_KAIZEN_DESPERDICIO: ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' linha(s).';

/* =====================================================================
   E7 - O que NÃO casou nos lookups (antes do commit, para você decidir)
   ===================================================================== */
SELECT  PROBLEMA = 'REPLICACAO sem correspondencia em CI.KZN_REPLICACAO',
        p.ID_KAIZEN, TEXTO_DA_PLANILHA = p.TX_REPLICACAO
FROM    #PVC p
JOIN    CI.KZN_HIST_PEDRAVISAOCONSOLIDADA h ON h.ID_KAIZEN = p.ID_KAIZEN
WHERE   h.ID_REPLICACAO IS NULL AND p.TX_REPLICACAO IS NOT NULL
UNION ALL
SELECT  DISTINCT 'DESPERDICIO sem correspondencia em CI.KZN_DESPERDICIO',
        d.ID_KAIZEN, d.TX_DESPERDICIO
FROM    #DESP d
WHERE   NOT EXISTS (SELECT 1 FROM CI.KZN_DESPERDICIO x
                    WHERE LTRIM(RTRIM(x.NM_DESPERDICIO)) COLLATE Latin1_General_CI_AI
                          IN (LTRIM(RTRIM(d.TX_DESPERDICIO))                                            COLLATE Latin1_General_CI_AI,
                              LTRIM(RTRIM(LEFT(d.TX_DESPERDICIO, NULLIF(CHARINDEX('/', d.TX_DESPERDICIO),0) - 1))) COLLATE Latin1_General_CI_AI,
                              LTRIM(RTRIM(SUBSTRING(d.TX_DESPERDICIO, NULLIF(CHARINDEX('/', d.TX_DESPERDICIO),0) + 1, 200))) COLLATE Latin1_General_CI_AI));

DROP TABLE #PVC;
DROP TABLE #DESP;

COMMIT TRANSACTION;
PRINT 'Carga concluida: Kaizens 7281-7296 e auxiliares gravados nas tabelas HIST.';

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

SELECT ID_KAIZEN, NM_KAIZEN, ID_REPLICACAO, ID_STATUS, DT_CONCLUSAO,
       TAM_MAIOR_TEXTO = (SELECT MAX(v) FROM (VALUES (LEN(DS_PROBLEMA)),(LEN(DS_OBJETIVO)),(LEN(DS_ESTADO_ANTES)),
                          (LEN(DS_ESTADO_DEPOIS)),(LEN(DS_COMPARA_META)),(LEN(DS_LICOES_APRENDIDAS)),
                          (LEN(DS_RESULTADO_ALCANCADO))) t(v))
FROM   CI.KZN_HIST_PEDRAVISAOCONSOLIDADA
WHERE  ID_KAIZEN BETWEEN 7281 AND 7296
ORDER BY ID_KAIZEN;
GO
