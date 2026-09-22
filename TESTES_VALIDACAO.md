# Testes de Validação — Quartely Dashboard (Comparações e Cores)

## Fase 1: Validação das Comparações de Horizontes

### Teste 1.1: Q4 não compara com H1
**Cenário**: Selecionar dados que incluem Q4 e H1 do mesmo ano
**Esperado**: Nenhuma linha vermelha (connector) ou percentual entre Q4 e H1
**Verificação**: 
- Abrir dashboard Quartely
- Selecionar período que inclua Q4 e H1 (ex: Horizonte = todos, Ano = 2025)
- Verificar visualmente que não há conector vermelho entre Q4 2025 e H1 2025
- Verificar console para mensagens de validação

### Teste 1.2: H2 não compara com Ano
**Cenário**: Selecionar dados que incluem H2 e Ano
**Esperado**: Nenhum conector entre H2 2025 e 25A/25F
**Verificação**:
- Selecionar dados com H2 2025 e 25A/25F visível no gráfico
- Confirmar que não há percentual conectando H2 para o Ano

### Teste 1.3: Q3 compara com Q2 (válido)
**Cenário**: Q2 e Q3 do mesmo ano
**Esperado**: Conector vermelho/verde entre Q3 e Q2 com percentual
**Verificação**:
- Selecionar dados com Q2 e Q3 2025
- Confirmar que há conector mostrando variação de Q3 vs Q2
- Verificar que o percentual é calculado corretamente

### Teste 1.4: H2 compara com H1 (válido)
**Cenário**: H1 e H2 do mesmo ano
**Esperado**: Conector mostrando variação H2 vs H1
**Verificação**:
- Selecionar dados com H1 2025 e H2 2025
- Confirmar conector entre H2 e H1
- Percentual deve ser calculado

### Teste 1.5: Ano 2026 compara com Ano 2025 (válido)
**Cenário**: Anos diferentes
**Esperado**: Conector entre 25A/25F e 26A/26F
**Verificação**:
- Selecionar Ano = 2025 e 2026
- Confirmar conector entre os dois anos

### Teste 1.6: Múltiplos anos com trimestres
**Cenário**: Trimestres de 2025 e 2026
**Esperado**: 
- Q1-Q4 2025 comparados apenas entre si
- Q1-Q4 2026 comparados apenas entre si
- Nenhum conector entre Q4 2025 e Q1 2026
**Verificação**:
- Selecionar Horizonte incluindo trimestres de 2025 e 2026
- Observar que cada ano mantém suas próprias comparações

## Fase 2: Validação do Configurador de Cores

### Teste 2.1: Painel de cores é exibido
**Esperado**: Painel com 4 color swatches (Actual, Plan, Default, Background) + botão Restaurar
**Verificação**:
- Abrir página Quartely
- Confirmar que painel "Actual | Plan | Default | Background | Restaurar" aparece acima do gráfico
- Cada color swatch deve exibir a cor atual

### Teste 2.2: Clicar em swatch abre color picker
**Cenário**: Clicar no quadrado de cor de Actual
**Esperado**: Input <color> se abre para seleção
**Verificação**:
- Clicar no swatch "Actual"
- Confirmar que se abre o seletor nativo de cores do navegador

### Teste 2.3: Mudar cor atualiza barra imediatamente
**Cenário**: Selecionar nova cor para Actual
**Esperado**: Todas as barras Actual mudam para a nova cor instantaneamente
**Verificação**:
- Clicar em swatch Actual
- Selecionar cor diferente (ex: vermelho)
- Confirmar que barras Actual ficam vermelhas
- Confirmar que nenhuma consulta ao banco é feita

### Teste 2.4: Cada série tem cor independente
**Cenário**: Mudar Actual, depois Plan
**Esperado**: Cada série mantém sua cor única
**Verificação**:
- Alterar Actual para azul claro
- Alterar Plan para roxo
- Alterar Default para cinza
- Confirmar que cada série mantém sua cor

### Teste 2.5: Mudança de fundo não afeta legibilidade
**Cenário**: Selecionar fundo branco, depois cinza, depois preto
**Esperado**: Título, valores e rótulos permanecem legíveis
**Verificação**:
- Mudar Background para preto
- Confirmar que textos em cores escuras (ink-strong) ainda são legíveis
- Considerar constraste de cores

### Teste 2.6: Cores persistem ao filtrar
**Cenário**: Mudar cores, depois alterar filtro (ex: Product, Year)
**Esperado**: Cores se mantêm após o novo cálculo do gráfico
**Verificação**:
- Alterar Actual para roxo
- Mudar filtro de Product
- Confirmar que barras continuam roxas

### Teste 2.7: Cores persistem entre sessões
**Cenário**: Mudar cores, fechar e reabrir página
**Esperado**: Cores customizadas são recuperadas
**Verificação**:
- Alterar Actual para verde
- Fechar aba e reabrir quartely.html
- Confirmar que Actual permanece verde
- Verificar localStorage no DevTools: `vdt-chart-colors`

### Teste 2.8: Botão "Restaurar Padrão" funciona
**Cenário**: Customizar cores, clicar em "Restaurar Padrão"
**Esperado**: Todas as cores retornam aos valores originais
**Verificação**:
- Mudar todas as 4 cores
- Clicar em "Restaurar Padrão"
- Confirmar que cores voltam ao padrão
- Verificar localStorage — deve refletir padrão

## Fase 3: Validação de Acessibilidade

### Teste 3.1: Color picker é acessível por teclado
**Esperado**: Navegar com Tab até os swatches
**Verificação**:
- Pressionar Tab até alcançar um swatch
- Pressionar Enter/Espaço para abrir color picker

### Teste 3.2: Contraste adequado
**Esperado**: Textos permanecem legíveis em qualquer fundo selecionado
**Verificação**:
- Testar com ferramenta de contraste (ex: DevTools Lighthouse)
- Confirmar WCAG AA (4.5:1 para texto)

### Teste 3.3: Painel responsivo em mobile
**Esperado**: Painel de cores se adapta a telas pequenas
**Verificação**:
- Abrir em device 375px (mobile)
- Confirmar que color items não transbordam
- Confirmar que botão Restaurar é acessível

## Fase 4: Validação da Integridade

### Teste 4.1: Nenhuma funcionalidade existente foi afetada
**Verificação**:
- Filtros independentes funcionam (Ano, Site, Visão, Horizonte, Product)
- Gráfico renderiza corretamente
- Rótulos de eixo estão precisos
- Valores são formatados corretamente
- Cross-filtering (AND/OR) continua funcionando
- Ordem do gráfico (Trimestre → Semestre → Ano) é mantida

### Teste 4.2: Sem erros de console
**Verificação**:
- Abrir DevTools Console
- Confirmar que não há erros (vermelho)
- Avisos sobre deprecated APIs são aceitáveis

### Teste 4.3: Performance não degradou
**Verificação**:
- Medir tempo de renderização antes e depois
- Confirmar que mudança de cores é instantânea (~0ms)
- Confirmar que filtros continuam rápidos

## Relatório de Testes

| Teste | Status | Observações |
|-------|--------|------------|
| 1.1 - Q4 vs H1 | ⏳ | Aguardando teste |
| 1.2 - H2 vs Ano | ⏳ | Aguardando teste |
| 1.3 - Q3 vs Q2 | ⏳ | Aguardando teste |
| 1.4 - H2 vs H1 | ⏳ | Aguardando teste |
| 1.5 - Ano vs Ano | ⏳ | Aguardando teste |
| 1.6 - Multi-ano | ⏳ | Aguardando teste |
| 2.1 - Painel exibido | ⏳ | Aguardando teste |
| 2.2 - Color picker | ⏳ | Aguardando teste |
| 2.3 - Atualização imediata | ⏳ | Aguardando teste |
| 2.4 - Cores independentes | ⏳ | Aguardando teste |
| 2.5 - Legibilidade | ⏳ | Aguardando teste |
| 2.6 - Persistência (filtros) | ⏳ | Aguardando teste |
| 2.7 - Persistência (sessão) | ⏳ | Aguardando teste |
| 2.8 - Restaurar padrão | ⏳ | Aguardando teste |
| 3.1 - Teclado | ⏳ | Aguardando teste |
| 3.2 - Contraste | ⏳ | Aguardando teste |
| 3.3 - Mobile | ⏳ | Aguardando teste |
| 4.1 - Integridade | ⏳ | Aguardando teste |
| 4.2 - Console | ⏳ | Aguardando teste |
| 4.3 - Performance | ⏳ | Aguardando teste |

---

**Instruções de Teste**:
1. Fazer deploy das mudanças (commit abfda25)
2. Abrir https://[databricks-host]/Quartely/quartely.html
3. Executar testes da Fase 1 até Fase 4
4. Registrar resultados neste documento
5. Abrir issue caso algum teste falhe

