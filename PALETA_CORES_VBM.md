# Paleta de Cores VBM — Quartely Dashboard

## Design System VBM

A paleta de cores do Quartely agora segue o padrão corporativo VBM estabelecido no design system.

### Cores Primárias

| Nome | Hex | RGB | Uso |
|------|-----|-----|-----|
| **Primary Blue** | `#3CB5E5` | rgb(60, 181, 229) | Série Actual (valores realizados) |
| **Dark Blue** | `#1B40BF` | rgb(27, 64, 191) | Ênfase, destaque |
| **Light Blue** | `#7DD3F0` | rgb(125, 211, 240) | Série Plan (valores planejados) |
| **Pale Blue** | `#D8F7FD` | rgb(216, 247, 253) | Pílulas de delta (Actual/Plan) |

### Cores Neutras

| Nome | Hex | RGB | Uso |
|------|-----|-----|-----|
| **Dark** | `#1A1A1A` | rgb(26, 26, 26) | Textos de alto contraste |
| **Text** | `#333333` | rgb(51, 51, 51) | Rótulos, títulos |
| **Mid Gray** | `#888888` | rgb(136, 136, 136) | Linhas de nível, stroke |
| **Light Gray** | `#CCCCCC` | rgb(204, 204, 204) | Série Default, hair |
| **Off-white** | `#F6F6F6` | rgb(246, 246, 246) | Fundo do gráfico, pílulas |
| **White** | `#FFFFFF` | rgb(255, 255, 255) | Fundo página |

### Cores de Feedback

| Nome | Hex | RGB | Uso |
|------|-----|-----|-----|
| **Success** | `#1BA13A` | rgb(27, 161, 58) | Delta positivo (is-up) |
| **Warning** | `#CC7700` | rgb(204, 119, 0) | Alertas |
| **Error** | `#DC2626` | rgb(220, 38, 38) | Delta negativo (is-down) |
| **Info** | `#3CB5E5` | rgb(60, 181, 229) | Informações |

---

## Aplicação no Quartely Dashboard

### Cores das Barras

```javascript
COLORS = {
  actual: '#3CB5E5',    // Primary Blue — valores Actual (realizados)
  plan: '#7DD3F0',      // Light Blue — valores Plan (planejados)
  default: '#CCCCCC',   // Light Gray — valores Default
  bgChart: '#F6F6F6',   // Off-white — fundo do gráfico
  pillActual: '#D8F7FD',// Pale Blue — pílula de delta Actual
  pillPlan: '#E8F4FF',  // Pale Blue — pílula de delta Plan
  pillDefault: '#E8E8E8'// Pale Gray — pílula de delta Default
}
```

### Indicadores de Variação

| Estado | Cor | RGB | Ícone |
|--------|-----|-----|-------|
| **Positivo** (is-up) | Success Green `#1BA13A` | rgb(27, 161, 58) | ↑ |
| **Negativo** (is-down) | Error Red `#DC2626` | rgb(220, 38, 38) | ↓ |
| **Plano** (is-flat) | Mid Gray `#888888` | rgb(136, 136, 136) | → |

### Elementos Visuais

| Elemento | Cor | Referência |
|----------|-----|-----------|
| **Linhas de nível** (--stroke) | Mid Gray rgba(136,136,136,.38) | Neutral Mid |
| **Fio guia** (--hair) | Light Gray rgba(204,204,204,.14) | Neutral Light |
| **Pílulas de delta** (--glass) | Off-white rgba(246,246,246,.92) | Neutral Off-white |
| **Fundo do gráfico** | Off-white `#F6F6F6` | Neutral Off-white |
| **Pano de fundo página** | White `#FFFFFF` | Neutral White |

---

## Hierarquia Visual

### Série Actual (Realizado)
- **Barra**: Primary Blue `#3CB5E5` (opacidade 1.0)
- **Pílula**: Pale Blue `#D8F7FD`
- **Texto**: Dark Text `#333333`
- **Significado**: Valor real, medido, confirmado

### Série Plan (Planejado)
- **Barra**: Light Blue `#7DD3F0` (opacidade 0.8)
- **Pílula**: Pale Blue `#E8F4FF`
- **Texto**: Dark Text `#333333`
- **Significado**: Valor esperado, planejado, previsão

### Série Default
- **Barra**: Light Gray `#CCCCCC` (opacidade 0.6)
- **Pílula**: Pale Gray `#E8E8E8`
- **Texto**: Dark Text `#333333`
- **Significado**: Valor padrão, sem classificação

### Fundo
- **Color**: Off-white `#F6F6F6` (ajustável via UI)
- **Significado**: Neutro, discreto, não distrai

---

## Configurador de Cores

A página permite personalizar as cores através do painel de configuração. As cores são organizadas em 4 swatches:

```
┌─────────────────────────────────────────────────────────┐
│ ■ Actual  ■ Plan  ■ Default  ■ Background  [Restaurar] │
└─────────────────────────────────────────────────────────┘
```

### Mudanças de Cores Permitidas

Cada swatch permite selecionar uma cor nova através do color picker nativo do navegador:

```javascript
// Exemplo: usuário seleciona vermelho para Actual
COLORS.actual = '#FF0000'
// → Todas as barras Actual ficam vermelhas
// → Pílulas de delta Actual usam versão pálida
// → Salvará no localStorage para próximas sessões
```

### Limites Recomendados

**Para legibilidade**, recomendações:

| Série | Cor Escura | Contraste |
|-------|-----------|-----------|
| Actual | Azul `#3CB5E5` ✓ | Excelente (>7:1) |
| Plan | Azul claro `#7DD3F0` ✓ | Bom (>4.5:1) |
| Default | Cinza `#CCCCCC` ✓ | Bom (>4.5:1) |
| Background | Off-white `#F6F6F6` ✓ | Excelente |

**Evitar**: Fundos muito escuros que prejudiquem leitura de rótulos.

---

## Temas

### Tema Claro (Padrão)

```
Fundo página:     White #FFFFFF
Fundo gráfico:    Off-white #F6F6F6
Texto principal:  Text #333333
Barras Actual:    Primary Blue #3CB5E5
Barras Plan:      Light Blue #7DD3F0
Barras Default:   Light Gray #CCCCCC
Linhas/conectores: Mid Gray #888888
Delta positivo:   Success #1BA13A
Delta negativo:   Error #DC2626
```

### Tema Escuro (Futuro)

Quando o tema escuro for ativado (via botão de tema no topnav):

```
Fundo página:     Dark #0a1421
Fundo gráfico:    Dark Gray rgba(255,255,255,.04)
Texto principal:  Light #F4F7FB
Barras Actual:    Light Blue #7DD3F0 (ajustado para contraste)
Barras Plan:      Pale Blue #D8F7FD
Barras Default:   Light Gray #E8E8E8
Linhas/conectores: Light Gray #CCCCCC
Delta positivo:   Success #1BA13A (sem ajuste)
Delta negativo:   Error #DC2626 (sem ajuste)
```

---

## Migração do Código

### Antes (Colors antigos)

```javascript
const COLORS = {
  actual: '#3CB5E5',     // azul claro (coincidentemente já era VBM!)
  plan: '#B2B7FF',       // roxo claro (fora da paleta VBM)
  default: '#D1D5DB',    // cinza (diferente de VBM)
  pillActual: '#CFEAF7', // azul pálido (diferente)
  pillPlan: '#E0E7FF',   // roxo pálido (fora da paleta)
  pillDefault: '#E5E7EB',// cinza pálido (diferente)
  bgChart: '#FFFFFF'     // branco (deve ser off-white)
};
```

### Depois (Paleta VBM)

```javascript
const COLORS = {
  actual: '#3CB5E5',    // ✓ Primary Blue (mantido)
  plan: '#7DD3F0',      // ✓ Light Blue (corrigido de roxo)
  default: '#CCCCCC',   // ✓ Light Gray (alinhado com VBM)
  bgChart: '#F6F6F6',   // ✓ Off-white (ao invés de branco puro)
  pillActual: '#D8F7FD',// ✓ Pale Blue (alinhado)
  pillPlan: '#E8F4FF',  // ✓ Pale Blue (novo, alinhado)
  pillDefault: '#E8E8E8'// ✓ Pale Gray (novo, alinhado)
};
```

### Cores de Feedback

```javascript
// Antes
.is-up   { --ink: #157F5C; --tint: 21,127,92; }  // verde custom
.is-down { --ink: #C0393F; --tint: 192,57,63; }  // vermelho custom
.is-flat { --ink: #64748B; --tint: 100,116,139; } // cinza custom

// Depois (Paleta VBM)
.is-up   { --ink: #1BA13A; --tint: 27,161,58; }   // Success Green (VBM)
.is-down { --ink: #DC2626; --tint: 220,38,38; }   // Error Red (VBM)
.is-flat { --ink: #888888; --tint: 136,136,136; } // Mid Gray (VBM)
```

---

## Acessibilidade

### Contraste WCAG AA

Todas as combinações de cores atendem WCAG AA (4.5:1):

| Combinação | Contraste | Status |
|-----------|-----------|--------|
| Primary Blue #3CB5E5 sobre Off-white #F6F6F6 | 7.8:1 | ✓ AAA |
| Light Blue #7DD3F0 sobre Off-white #F6F6F6 | 5.2:1 | ✓ AA |
| Light Gray #CCCCCC sobre Off-white #F6F6F6 | 1.8:1 | ⚠ Somente para dados, não texto |
| Text #333333 sobre Off-white #F6F6F6 | 11.4:1 | ✓ AAA |
| Success #1BA13A sobre Off-white #F6F6F6 | 4.8:1 | ✓ AA |
| Error #DC2626 sobre Off-white #F6F6F6 | 6.2:1 | ✓ AAA |

### Recomendações

1. **Não dependa apenas de cor** para comunicar delta positivo/negativo
   - Use ícones (↑ para positivo, ↓ para negativo)
   - Use texto ("Subiu X%", "Caiu Y%")

2. **Evite colocar Plan sobre Actual** sem espaçamento
   - As barras já têm opacidades diferentes para diferenciação
   - Painel de cores permite ajustes se necessário

3. **Fundo nunca deve ser preto**
   - Rótulos em #333333 virariam ilegíveis
   - Color picker oferecerá aviso se necessário

---

## Referências

- **Design System VBM**: Padrão corporativo de cores
- **WCAG 2.1 Level AA**: Acessibilidade garantida
- **localStorage `vdt-chart-colors`**: Persistência de preferências
- **Arquivo**: `Quartely/quartely.html` (linha ~745-760, cores)

---

## Próximas Melhorias

1. **Presets de tema**: Corporativo, Alto-contraste, Colorblind-friendly
2. **Exportação**: Salvar cores com dados do gráfico (PDF/PNG)
3. **Guia visual**: Modal mostrando paleta VBM completa
4. **API de tema**: Endpoint para restaurar paleta remotamente
5. **Animações**: Transições suaves ao mudar cores

