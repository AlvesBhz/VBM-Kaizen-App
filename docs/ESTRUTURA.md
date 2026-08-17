# Estrutura do projeto — VBM Kaizen

Organização física dos arquivos. A arquitetura funcional não mudou:
continua sendo um app Node/Express servindo HTML estático + uma API REST
que fala direto com o Azure SQL.

```
/
├── *.html                  telas (index, admin, kaizen-novo, biblioteca, aprovacao)
├── server.js               Express: estáticos + API REST + pool do Azure SQL
├── app.yaml                config do Databricks App (env vars)
├── package.json
│
├── css/
│   ├── vbm-app.css         Design System (tokens --vbm-*, componentes)
│   └── vendor/             CSS de terceiros (Font Awesome)
│
├── js/
│   ├── vbm-app.js          comportamento compartilhado (modais, abas, toasts)
│   ├── aprovadores.js      aba Aprovadores
│   ├── usuarios.js         aba Usuários (somente leitura)
│   ├── cadastro-bilingue.js  motor dos cadastros PT/EN
│   ├── categorias.js       aba Categorias (autossuficiente, ver nota)
│   ├── replicacao.js       aba Pot. Replicação    ─┐
│   ├── desperdicios.js     aba Red. Desperdícios   ├─ usam cadastro-bilingue.js
│   └── resultados.js       aba Resultados         ─┘
│
├── assets/
│   ├── images/             fundos, logos e fotos (svg, webp)
│   ├── icons/              favicon
│   └── fonts/              webfonts (Font Awesome solid)
│
├── database/
│   ├── DER_VBM_Kaizen_CI.html   modelo de dados (tabelas, colunas, limites)
│   └── CI_KZN_DDL_v2.sql        script DDL idempotente (schema CI/KZN_*)
│
├── docs/
│   └── ESTRUTURA.md        este arquivo
│
└── lixo/                   arquivos sem uso, guardados (não excluídos)
```

## Convenções

**Nomes com hash** (`e5e202e3c8995079_all.min.css`, `1f0189e087fcefbf_…woff2`):
o hash faz parte do nome, então conteúdo novo gera nome novo. O
`server.js` detecta esse padrão e serve esses arquivos com
`Cache-Control: immutable` (1 ano) — zero requisição em navegações
seguintes. **Não renomeie esses arquivos**: perderiam o cache agressivo.

**Todo o resto** (HTML, `css/vbm-app.css`, `js/*.js`, fundos) é servido
com `no-cache` + ETag: revalida sempre — deploy aparece na hora — mas
responde `304` sem corpo quando nada mudou.

**API** (`/api/*`): sempre `no-store`. Dado nunca vem de cache.

## Notas

- `js/categorias.js` é **autossuficiente de propósito** — não depende de
  `cadastro-bilingue.js`. Um deploy em que esse arquivo compartilhado não
  chegou ao ambiente derrubou a aba inteira; a duplicação é intencional
  para que Categorias não dependa de um segundo arquivo estático.
- As abas do admin carregam **sob demanda**: só a visível consulta o
  banco no load; as demais na primeira vez que são abertas.
- `database/DER_VBM_Kaizen_CI.html` e `database/CI_KZN_DDL_v2.sql` não
  são carregados em runtime — são a referência de schema (nomes de
  tabelas/colunas e tamanhos de campo) usada ao escrever as queries do
  `server.js`. ATENÇÃO: o DDL já modela `kzn_aprovador`/`kzn_admin` com
  PK composta (ID_APROVADOR/ID_ADMIN + CD_MATRICULA), mas o `server.js` e
  o `js/aprovadores.js` atuais ainda tratam `kzn_aprovador` como se a
  única chave fosse ID_USUARIO (sem ID_APROVADOR, sem CD_MATRICULA
  gravada) — o DDL está à frente do código da aplicação nesse ponto;
  ajustar API + tela é trabalho pendente, não incluído nesta atualização.
