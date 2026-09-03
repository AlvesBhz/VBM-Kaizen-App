/**
 * VBM Kaizen — servidor Node/Express.
 *
 * Serve os HTML/CSS/JS estáticos do app (index, admin, aprovacao, etc.)
 * e expõe uma API REST para a tabela `kzn_aprovador`, usada hoje pela
 * aba "Aprovadores" de admin.html. Também expõe uma leitura (só GET)
 * de `kzn_categoria` + contagem em `kzn_pendenciaconsolidada`, usada
 * pelo card em destaque da aba "Categorias" (ver js/categorias.js).
 *
 * MODELO DE CONEXÃO (igual ao app.py de teste / app.yaml fornecidos):
 *   - Conexão DIRETA ao Azure SQL Database, sem passar pelo Databricks
 *     SQL Warehouse (diferente do padrão OAuth usado em outros apps
 *     deste workspace, como o "teste-conexao").
 *   - Credenciais fixas via variáveis de ambiente, injetadas pelo
 *     app.yaml (usuário/senha devem vir de um Secret Scope do
 *     Databricks — nunca em texto puro no app.yaml de produção).
 *   - Usamos o pacote `mssql` (equivalente Node do `pymssql` usado no
 *     protótipo Python): driver 100% JS (Tedious por baixo), instala
 *     só com "npm install", sem precisar de driver de sistema
 *     operacional — importante porque Databricks Apps não permite
 *     apt-get/sudo.
 */

const path = require("path");
const express = require("express");
const compression = require("compression");
const sql = require("mssql");
const multer = require("multer");
const { enviarArquivoParaVolume, baixarArquivoDoVolume } = require("./databricks-fs");

const app = express();

// gzip em tudo que é texto (HTML/CSS/JS/JSON/SVG). Já estava no
// package.json mas nunca tinha sido ligado — o app servia os ~110 KB de
// admin.html e os ~65 KB de vbm-app.css crus. Com gzip esses caem para
// ~20 KB e ~12 KB (>80% menos). Só afeta o transporte: o conteúdo que
// chega ao navegador é byte a byte o mesmo.
app.use(compression());

app.use(express.json());

// ------------------------------------------------------------------
// Configuração (env vars injetadas pelo app.yaml)
// ------------------------------------------------------------------
const DB_SERVER = process.env.AZURE_SQL_SERVER || "";
const DB_NAME = process.env.AZURE_SQL_DATABASE || "";
const DB_USER = process.env.AZURE_SQL_USER || "";
const DB_PASSWORD = process.env.AZURE_SQL_PASSWORD || "";
const DB_PORT = parseInt(process.env.AZURE_SQL_PORT || "1433", 10);

// Identificadores (schema/tabela) só podem conter letras, números e
// underscore — nunca interpolados sem essa validação, mesmo vindo de
// env var de confiança (defesa em profundidade).
const IDENTIFIER_RE = /^[A-Za-z0-9_]+$/;

function safeIdentifier(value, fallback) {
  const v = value || fallback;
  if (!IDENTIFIER_RE.test(v)) {
    throw new Error(`Identificador inválido: "${v}"`);
  }
  return v;
}

const DB_SCHEMA = safeIdentifier(process.env.AZURE_SQL_SCHEMA, "dbo");
const DB_TABLE = safeIdentifier(process.env.AZURE_SQL_TABLE, "kzn_aprovador");
const FULL_TABLE_NAME = `[${DB_SCHEMA}].[${DB_TABLE}]`;

// Mesmo schema dos aprovadores; tabela própria, também sobrescrevível
// por env var caso o nome real divirja do padrão.
const DB_CATEGORIA_TABLE = safeIdentifier(process.env.AZURE_SQL_CATEGORIA_TABLE, "kzn_categoria");
const FULL_CATEGORIA_TABLE = `[${DB_SCHEMA}].[${DB_CATEGORIA_TABLE}]`;

const DB_PENDENCIA_TABLE = safeIdentifier(process.env.AZURE_SQL_PENDENCIA_TABLE, "kzn_pendenciaconsolidada");
const FULL_PENDENCIA_TABLE = `[${DB_SCHEMA}].[${DB_PENDENCIA_TABLE}]`;

// Cadastro de pessoas (nome/matrícula/e-mail dos aprovadores) — pelo
// DER é aqui que esses dados moram, não em kzn_aprovador.
const DB_MDM_TABLE = safeIdentifier(process.env.AZURE_SQL_MDM_TABLE, "kzn_mdm_hierarquia");
const FULL_MDM_TABLE = `[${DB_SCHEMA}].[${DB_MDM_TABLE}]`;

// Quem pode ABRIR o admin. Mesmo desenho de kzn_aprovador no DER
// (ID_ADMIN, ID_USUARIO, SG_ATIVO, DT_ATUALIZACAO) — o vínculo é por
// ID_USUARIO do MDM, e SG_ATIVO='S' é o que vale.
const DB_ADMIN_TABLE = safeIdentifier(process.env.AZURE_SQL_ADMIN_TABLE, "kzn_admin");
const FULL_ADMIN_TABLE = `[${DB_SCHEMA}].[${DB_ADMIN_TABLE}]`;

// ------------------------------------------------------------------
// Tela "Novo Kaizen" (kaizen-novo.html) — ver
// Usuário - Novo Kaizen - Aprovação.txt
// ------------------------------------------------------------------
// Tabela principal: 1 linha por Kaizen enviado. NM_KAIZEN é VARCHAR(30)
// no DER (mesmo limite curto das outras tabelas de cadastro) — o
// helper da Etapa 1 dizia "até 100 caracteres"; ajustado no HTML para
// bater com o banco de verdade (ver kaizen-novo.html).
const DB_PVC_TABLE = safeIdentifier(process.env.AZURE_SQL_PVC_TABLE, "kzn_pedravisaoconsolidada");
const FULL_PVC_TABLE = `[${DB_SCHEMA}].[${DB_PVC_TABLE}]`;

// Junção Kaizen <-> MDM (equipe): mesmo desenho para membro interno
// (Vale) e externo (terceiro) — os dois são apenas um ID_USUARIO do
// MDM; o que diferencia um terceiro é o ID_TIPO_USUARIO=2 na própria
// linha do MDM (ver ID_TIPO_USUARIO_TERCEIRO, já usado pela aba
// Usuários), não uma coluna separada aqui.
const DB_MEMBROS_TABLE = safeIdentifier(process.env.AZURE_SQL_MEMBROS_TABLE, "kzn_membros_equipe");
const FULL_MEMBROS_TABLE = `[${DB_SCHEMA}].[${DB_MEMBROS_TABLE}]`;

// kzn_moeda NÃO é bilíngue (sem ID_IDIOMA no DER) — por isso não passa
// por registrarCadastroBilingue() como as outras 6 tabelas de cadastro;
// ver GET /moedas abaixo, bem mais simples.
const DB_MOEDA_TABLE = safeIdentifier(process.env.AZURE_SQL_MOEDA_TABLE, "kzn_moeda");
const FULL_MOEDA_TABLE = `[${DB_SCHEMA}].[${DB_MOEDA_TABLE}]`;

// Reduções de desperdício: seleção MÚLTIPLA na tela, mas
// kzn_pedravisaoconsolidada só tem uma FK ID_DESPERDICIO (sem tabela de
// junção no DER original) — nova tabela pedida ao usuário, mesmo
// padrão de kzn_resultado_kaizen. PVC.ID_DESPERDICIO fica sempre NULL
// agora; a lista de verdade mora só aqui.
const DB_KZ_DESPERDICIO_TABLE = safeIdentifier(process.env.AZURE_SQL_KZ_DESPERDICIO_TABLE, "kzn_kaizen_desperdicio");
const FULL_KZ_DESPERDICIO_TABLE = `[${DB_SCHEMA}].[${DB_KZ_DESPERDICIO_TABLE}]`;

// "Outros resultados": grava em kzn_resultados (item bilíngue novo,
// texto duplicado nos 2 idiomas — não há como auto-traduzir a
// descrição livre) + a junção kzn_resultado_kaizen, que já existe no
// DER original.
const DB_RESULTADOS_TABLE = safeIdentifier(process.env.AZURE_SQL_RESULTADOS_TABLE, "kzn_resultados");
const FULL_RESULTADOS_TABLE = `[${DB_SCHEMA}].[${DB_RESULTADOS_TABLE}]`;
const DB_RESULTADO_KAIZEN_TABLE = safeIdentifier(process.env.AZURE_SQL_RESULTADO_KAIZEN_TABLE, "kzn_resultado_kaizen");
const FULL_RESULTADO_KAIZEN_TABLE = `[${DB_SCHEMA}].[${DB_RESULTADO_KAIZEN_TABLE}]`;

// Nomes de tabela usados só em JOINs de leitura (Biblioteca) — mesmas
// env vars/padrões já usados nos cadastros bilíngues acima (registrarCadastroBilingue).
const FULL_REPLICACAO_TABLE = tabelaCadastro("AZURE_SQL_REPLICACAO_TABLE", "kzn_replicacao");
const FULL_DESPERDICIO_TABLE = tabelaCadastro("AZURE_SQL_DESPERDICIO_TABLE", "kzn_desperdicio");
const FULL_MOTIVO_TABLE = tabelaCadastro("AZURE_SQL_MOTIVO_REPROVACAO_TABLE", "kzn_motivo_reprovacao");

// kzn_categoria guarda 1 LINHA POR IDIOMA para a mesma categoria (mesmo
// ID_CATEGORIA, ID_IDIOMA diferente) — confirmado no DER
// (database/DER_VBM_Kaizen_CI.html) e pelo time: ID_IDIOMA=1 é Português,
// ID_IDIOMA=2 é Inglês (kzn_idioma).
const ID_IDIOMA_PT = 1;
const ID_IDIOMA_EN = 2;

// Traduz o idioma da tela (?idioma=pt-BR|en, o mesmo valor guardado em
// localStorage 'vdt-lang') para o ID_IDIOMA do banco. Qualquer valor
// desconhecido/ausente cai em português — nunca deixa a lista vazia
// por causa de um parâmetro estranho.
function idIdiomaDaRequisicao(req) {
  const bruto = String(req.query.idioma || "").trim().toLowerCase();
  if (bruto === "en" || bruto.startsWith("en-") || bruto === String(ID_IDIOMA_EN)) {
    return ID_IDIOMA_EN;
  }
  return ID_IDIOMA_PT;
}

// Helpers globais de parsing de querystring/body — usados pela
// Biblioteca (GET /kaizens) e por qualquer rota futura.
function intOuNuloGlobal(valor) {
  if (valor === "" || valor == null) return null;
  const n = parseInt(valor, 10);
  return Number.isInteger(n) ? n : null;
}
function textoOuNuloGlobal(valor) {
  if (valor == null) return null;
  const limpo = String(valor).trim();
  return limpo === "" ? null : limpo;
}

function checkConfig() {
  const missing = [
    ["AZURE_SQL_SERVER", DB_SERVER],
    ["AZURE_SQL_DATABASE", DB_NAME],
    ["AZURE_SQL_USER", DB_USER],
    ["AZURE_SQL_PASSWORD", DB_PASSWORD],
  ]
    .filter(([, val]) => !val)
    .map(([name]) => name);

  if (missing.length) {
    throw new Error("Faltam variáveis de configuração: " + missing.join(", "));
  }
}

// ------------------------------------------------------------------
// Conexão (pool reaproveitado — evita reabrir handshake TLS/login a
// cada requisição; mesmo raciocínio do app.py, que usa
// @st.cache_resource para cachear a conexão)
// ------------------------------------------------------------------
let poolPromise = null;

function createPool() {
  checkConfig();
  const config = {
    server: DB_SERVER,
    port: DB_PORT,
    database: DB_NAME,
    user: DB_USER,
    password: DB_PASSWORD,
    options: {
      encrypt: true, // obrigatório para Azure SQL
      trustServerCertificate: false,
    },
    pool: { max: 5, min: 0, idleTimeoutMillis: 30000 },
  };
  return new sql.ConnectionPool(config).connect();
}

async function getPool() {
  if (!poolPromise) poolPromise = createPool();
  try {
    return await poolPromise;
  } catch (err) {
    poolPromise = null; // não cacheia promise quebrada
    throw err;
  }
}

/** Executa um request parametrizado; `params` é um array de
 * [nome, tipoSql, valor], nunca concatenado na string SQL. */
async function runQuery(query, params = []) {
  const pool = await getPool();
  const request = pool.request();
  params.forEach(([name, type, value]) => request.input(name, type, value));
  return request.query(query);
}

// ------------------------------------------------------------------
// Estáticos
// ------------------------------------------------------------------
// ANTES: "no-store" em TUDO. Isso proíbe o navegador até de guardar
// uma cópia, então cada ida e volta entre index/admin/biblioteca/etc.
// rebaixava de novo os mesmos ~160 KB de CSS, ~154 KB de fontes e os
// fundos de 0,6–1,3 MB — era o principal motivo da navegação lenta
// entre as páginas.
//
// AGORA, por tipo de arquivo, sem perder atualização em deploy:
//
//   • arquivos com hash no nome (<hash>_nome.ext, ex.: as fontes em
//     assets/fonts, o favicon em assets/icons, as fotos em
//     assets/images e o Font Awesome em css/vendor) — o hash faz parte
//     do nome, então conteúdo novo = nome novo. Podem ir de cache
//     "para sempre" (immutable): zero requisição em navegações
//     seguintes. A regra olha só o nome do arquivo, não a pasta, para
//     continuar valendo depois da reorganização de diretórios.
//   • todo o resto (HTML, css/vbm-app.css, js/*.js, SVGs de fundo) —
//     "no-cache" + ETag: o navegador SEMPRE revalida (deploy continua
//     aparecendo na hora, igual a antes), mas quando nada mudou o
//     servidor responde 304 sem corpo. Um fundo de 1,3 MB vira uma
//     resposta de algumas centenas de bytes.
const UM_ANO_EM_SEGUNDOS = 60 * 60 * 24 * 365;
const ARQUIVO_COM_HASH_NO_NOME = /(?:^|[\\/])[0-9a-f]{8,}_[^\\/]+$/i;

// ------------------------------------------------------------------
// Controle de acesso (kzn_admin / kzn_aprovador)
// ------------------------------------------------------------------
// Duas páginas são restritas e o critério é o CADASTRO no banco, pelo
// ID_USUARIO do MDM:
//
//   admin.html     -> kzn_admin      (SG_ATIVO='S')
//   aprovacao.html -> kzn_aprovador  (SG_ATIVO='S')
//
// A identidade vem do MESMO lugar que já grava o ID_USUARIO nos
// cadastros: o cabeçalho X-Forwarded-Email do proxy do Databricks Apps
// (ver idUsuarioLogado()/buscarMdmPorEmail() abaixo). Não é forjável
// por quem acessa a URL publicada, ao contrário de qualquer coisa que
// o navegador mande — por isso a decisão é SEMPRE do servidor, e o
// front-end só esconde os links (reforço visual, nunca a trava).
//
// DENY BY DEFAULT: sem cabeçalho, e-mail sem correspondência no MDM,
// tabela inacessível ou erro de consulta => acesso NEGADO. Nenhum
// desses cenários "abre" a página.
const PAGINAS_RESTRITAS = {
  "/admin.html": "admin",
  "/aprovacao.html": "aprovador",
};

// Perfil do usuário da requisição, em UMA consulta (MDM + os dois
// vínculos de papel). Memorizado no próprio req: o gate da API e o
// GET /api/me da mesma requisição reusam o resultado em vez de
// consultar de novo.
async function perfilDeAcesso(req) {
  if (req._perfilAcesso) return req._perfilAcesso;

  const negar = (motivo) => {
    if (motivo) console.warn(`[acesso] negado: ${motivo}`);
    req._perfilAcesso = { idUsuario: null, admin: false, aprovador: false };
    return req._perfilAcesso;
  };

  const email = req.get("X-Forwarded-Email");
  if (!email) return negar("requisição sem X-Forwarded-Email (fora do Databricks Apps?)");

  try {
    const result = await runQuery(
      `SELECT TOP (1) m.ID_USUARIO,
              CASE WHEN EXISTS (SELECT 1 FROM ${FULL_ADMIN_TABLE} ad
                                 WHERE ad.ID_USUARIO = m.ID_USUARIO AND ad.SG_ATIVO = 'S')
                   THEN 1 ELSE 0 END AS EH_ADMIN,
              CASE WHEN EXISTS (SELECT 1 FROM ${FULL_TABLE_NAME} ap
                                 WHERE ap.ID_USUARIO = m.ID_USUARIO AND ap.SG_ATIVO = 'S')
                   THEN 1 ELSE 0 END AS EH_APROVADOR
       FROM ${FULL_MDM_TABLE} m
       WHERE LOWER(m.CD_EMAIL) = LOWER(@email)`,
      [["email", sql.NVarChar(255), email]]
    );
    const linha = result.recordset[0];
    if (!linha) return negar(`e-mail "${email}" sem correspondência em ${FULL_MDM_TABLE}.CD_EMAIL`);

    req._perfilAcesso = {
      idUsuario: linha.ID_USUARIO || null,
      admin: linha.EH_ADMIN === 1,
      aprovador: linha.EH_APROVADOR === 1,
    };
    return req._perfilAcesso;
  } catch (err) {
    // Falha de consulta NUNCA libera: erro é tratado como sem permissão.
    return negar(`falha ao verificar permissões de "${email}": ${err.message}`);
  }
}

// Página de bloqueio: autossuficiente de propósito (só a folha de
// estilo pública do app), para não carregar nenhum script, dado ou
// componente da página restrita — o usuário sem permissão não recebe
// nada além desta mensagem.
function paginaAcessoNegado(papel) {
  const tabela = papel === "admin" ? "KZN_ADMIN" : "KZN_APROVADOR";
  return `<!DOCTYPE html>
<html lang="pt-BR"><head><meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Acesso não autorizado — VBM Kaizen</title>
<link rel="stylesheet" href="css/vbm-app.css">
<style>
  .acesso-negado { min-height:100vh; display:flex; align-items:center; justify-content:center; padding:1.5rem; }
  .acesso-negado .caixa { max-width:460px; text-align:center; background:var(--vbm-white);
    border:1px solid var(--vbm-border); border-radius:12px; padding:2.5rem 2rem; }
  .acesso-negado .marca { width:52px; height:52px; margin:0 auto 1.25rem; border-radius:50%;
    background:var(--vbm-blue-pale); color:var(--vbm-blue-dark); font-size:1.5rem; font-weight:700;
    display:flex; align-items:center; justify-content:center; }
  .acesso-negado h1 { font-size:1.15rem; color:var(--vbm-dark); margin:0 0 .5rem; }
  .acesso-negado p { font-size:.85rem; color:var(--vbm-mid); margin:0 0 .35rem; line-height:1.5; }
  .acesso-negado a { display:inline-block; margin-top:1.5rem; }
</style></head>
<body><div class="acesso-negado"><div class="caixa">
  <div class="marca" aria-hidden="true">!</div>
  <h1>Acesso não autorizado</h1>
  <p>Seu usuário não está cadastrado em <strong>${tabela}</strong>. Procure um administrador do VBM Kaizen para solicitar acesso.</p>
  <p><em>You are not authorized to view this page.</em></p>
  <a class="btn btn-primary" href="index.html">Voltar ao início</a>
</div></div></body></html>`;
}

// Gate das PÁGINAS — antes do express.static, senão o HTML restrito
// seria entregue pelo servidor de estáticos sem passar por aqui.
app.use(async (req, res, next) => {
  const papel = PAGINAS_RESTRITAS[req.path.toLowerCase()];
  if (!papel) return next();

  const perfil = await perfilDeAcesso(req);
  if (perfil[papel]) return next();

  console.warn(`[acesso] ${req.path} bloqueado (papel exigido: ${papel})`);
  res.status(403).set("Cache-Control", "no-store").type("html").send(paginaAcessoNegado(papel));
});

app.use(
  express.static(__dirname, {
    etag: true,
    index: false,
    lastModified: true,
    setHeaders: (res, filePath) => {
      if (ARQUIVO_COM_HASH_NO_NOME.test(filePath)) {
        res.set("Cache-Control", `public, max-age=${UM_ANO_EM_SEGUNDOS}, immutable`);
      } else {
        res.set("Cache-Control", "no-cache");
      }
    },
  })
);

// ------------------------------------------------------------------
// API — kzn_aprovador
// ------------------------------------------------------------------
const apiRouter = express.Router();

// Rotas abertas a qualquer usuário autenticado pelo proxy. Só GET /me,
// que devolve exclusivamente a identidade de QUEM chamou (e é o que
// permite ao front-end esconder os links das páginas restritas).
const ROTAS_API_PUBLICAS = new Set(["/me"]);

// Gate da API — o reforço server-side do bloqueio das páginas. Todo o
// resto da API existe para servir o admin.html, então exige kzn_admin:
// esconder o botão no front não basta, a chamada direta ao endpoint
// (curl, DevTools, URL colada) tem que ser recusada aqui. Lista de
// EXCEÇÕES, não de rotas protegidas — rota nova nasce fechada.
apiRouter.use(async (req, res, next) => {
  res.set("Cache-Control", "no-store");
  if (ROTAS_API_PUBLICAS.has(req.path.toLowerCase())) return next();

  const perfil = await perfilDeAcesso(req);
  if (perfil.admin) return next();

  console.warn(`[acesso] API ${req.method} ${req.path} bloqueada (exige kzn_admin)`);
  res.status(403).json({ error: "Acesso não autorizado." });
});

// Busca ID_USUARIO + CD_MATRICULA + NM_USUARIO no MDM (kzn_mdm_hierarquia)
// por e-mail — mesma tabela já usada nas abas Aprovadores/Usuários, aqui
// só com outra chave de busca (e-mail em vez de ID_USUARIO). Devolve
// null em qualquer falha: os 3 campos são "extras" (cabeçalho e/ou
// auditoria de cadastro) — uma falha aqui nunca pode derrubar a
// identidade do usuário nem impedir um salvamento.
//
// Reaproveitada por GET /api/me (matrícula no cabeçalho) e por
// idUsuarioLogado() (usuário responsável ao criar/editar categoria) —
// mesma consulta, dois consumidores, sem duplicar SQL.
async function buscarMdmPorEmail(email) {
  if (!email) return null;
  try {
    const result = await runQuery(
      `SELECT TOP (1) ID_USUARIO, CD_MATRICULA, NM_USUARIO, NM_POSICAO FROM ${FULL_MDM_TABLE} WHERE LOWER(CD_EMAIL) = LOWER(@email)`,
      [["email", sql.NVarChar(255), email]]
    );
    return result.recordset[0] || null;
  } catch (err) {
    console.warn("[mdm] falha ao consultar usuário por e-mail:", err.message);
    return null;
  }
}

// ID_USUARIO (kzn_mdm_hierarquia) do usuário logado, a partir do e-mail
// que o proxy do Databricks Apps já autenticou e repassa em
// X-Forwarded-Email (mesma identidade usada em GET /api/me e no
// cabeçalho — ver js/usuario-graph.js). Não depende do Microsoft Graph:
// o servidor nunca tem o token do Graph (ele mora só no navegador), e
// confiar num e-mail vindo do CLIENTE para gravar "quem criou/editou"
// permitiria forjar o campo pela própria requisição — o cabeçalho do
// proxy é reescrito a cada chamada e não é forjável por quem acessa a
// URL publicada, então é a fonte confiável para um campo de auditoria.
//
// null em qualquer cenário sem quebrar quem chamou: sem cabeçalho
// (fora do Databricks Apps), e-mail sem correspondência no MDM, ou
// falha na consulta. Loga o MOTIVO de cada null (visível nos logs do
// Databricks App) — sem isso, "gravou NULL" e "gravou o ID certo" são
// indistinguíveis de fora, e não dá pra saber se falta cabeçalho ou se
// o e-mail do proxy não bate com CD_EMAIL no MDM.
async function idUsuarioLogado(req) {
  const email = req.get("X-Forwarded-Email");
  if (!email) {
    console.warn("[usuario-logado] sem X-Forwarded-Email nesta requisição — fora do Databricks Apps?");
    return null;
  }
  const mdm = await buscarMdmPorEmail(email);
  if (!mdm) {
    console.warn(`[usuario-logado] e-mail "${email}" (do proxy) sem correspondência em ${FULL_MDM_TABLE}.CD_EMAIL`);
    return null;
  }
  console.log(`[usuario-logado] "${email}" -> ID_USUARIO ${mdm.ID_USUARIO}`);
  return mdm.ID_USUARIO || null;
}

// Identidade do usuário logado, na visão do Databricks Apps + MDM.
//
// O app roda ATRÁS do proxy do Databricks Apps, que já autenticou a
// pessoa (Entra ID) antes de a requisição chegar aqui e repassa a
// identidade em cabeçalhos X-Forwarded-*. Isso dá nome/e-mail reais sem
// nenhuma configuração extra e sem segundo login. A matrícula (que não
// vem do proxy nem do Graph) é buscada no MDM pelo e-mail.
//
// NÃO substitui o Microsoft Graph: aqui não há foto, cargo, empresa nem
// gestor — esses campos só vêm do Graph (ver js/usuario-graph.js). Este
// endpoint é o piso de identidade + a matrícula, usados no cabeçalho
// mesmo antes de o MSAL estar configurado.
//
// ?email=<e-mail> permite consultar a matrícula pelo e-mail do GRAPH,
// para quando o MSAL já resolveu a conta mas o proxy do Databricks não
// mandou X-Forwarded-Email (ex.: acesso fora do Databricks Apps).
//
// Segurança: os X-Forwarded-* são reescritos pelo proxy do Databricks a
// cada requisição, então não são forjáveis por quem acessa o app pela
// URL publicada. O access token repassado NÃO é devolvido ao navegador
// — só informamos se ele existe, para diagnóstico.
apiRouter.get("/me", async (req, res) => {
  const h = (nome) => req.get(nome) || null;

  const email = h("X-Forwarded-Email");
  const usuario = h("X-Forwarded-Preferred-Username") || h("X-Forwarded-User");
  const emailParaMdm = (typeof req.query.email === "string" && req.query.email.trim()) || email;

  // O proxy não manda nome de exibição; derivamos algo apresentável do
  // e-mail ("maria.souza@vale.com" -> "Maria Souza") só como último
  // fallback — o MDM (nome real) e o Graph (displayName) têm prioridade.
  const base = (email || usuario || "").split("@")[0];
  const nomeDerivado = base
    ? base
        .split(/[._-]+/)
        .filter(Boolean)
        .map((p) => p.charAt(0).toUpperCase() + p.slice(1))
        .join(" ")
    : null;

  const mdm = await buscarMdmPorEmail(emailParaMdm);

  // Papéis SEMPRE pelo cabeçalho do proxy — nunca por ?email=, que o
  // navegador escolhe. Senão bastaria pedir /api/me?email=<um admin>
  // para o front-end reexibir os links restritos. (Reexibir o link não
  // abriria nada: o gate acima recusa a página de qualquer jeito. Ainda
  // assim, a resposta não pode afirmar um papel que o chamador não tem.)
  const perfil = await perfilDeAcesso(req);

  res.json({
    autenticado: !!(email || usuario),
    nome: (mdm && mdm.NM_USUARIO) || nomeDerivado,
    email: email,
    // Papéis do usuário logado — o front-end usa só para esconder os
    // links de navegação das páginas restritas (ver window.VBMAcesso em
    // js/vbm-app.js). O bloqueio real é o gate de páginas/API.
    admin: perfil.admin,
    aprovador: perfil.aprovador,
    usuario: usuario,
    idUsuario: h("X-Forwarded-User"),
    matricula: (mdm && mdm.CD_MATRICULA) || null,
    // Cargo do MDM (NM_POSICAO) — é o que o cabeçalho mostra na 2ª
    // linha, no lugar da matrícula. Vem do mesmo SELECT, sem consulta
    // extra. O Graph tem um jobTitle próprio, mas a fonte aqui é o
    // banco, como o resto da tela.
    cargo: (mdm && mdm.NM_POSICAO) || null,
    // Diagnóstico: mostra QUAIS cabeçalhos o Databricks está mandando,
    // sem expor o valor do token.
    _diagnostico: {
      temAccessToken: !!req.get("X-Forwarded-Access-Token"),
      cabecalhosRecebidos: Object.keys(req.headers)
        .filter((k) => k.toLowerCase().startsWith("x-forwarded"))
        .sort(),
    },
  });
});

// Conectividade (equivalente ao botão "Testar conexão" do app.py)
apiRouter.get("/test", async (req, res) => {
  try {
    await runQuery("SELECT 1 AS ok");
    res.json({ ok: true });
  } catch (err) {
    res.status(500).json({ ok: false, error: err.message });
  }
});

// Listar
// kzn_aprovador é uma tabela de PAPEL, não de cadastro: pelo DER ela
// tem apenas ID_USUARIO (PK e FK para kzn_mdm_hierarquia), SG_ATIVO e
// DT_ATUALIZACAO. Nome, matrícula e e-mail NÃO moram aqui — vêm do
// MDM por join. (A versão anterior consultava NM_USER/CD_MATRICULA
// direto nesta tabela, o que produzia o erro "Invalid column name
// 'NM_USER'" visto na tela.)
// Consequência de negócio: não existe "editar aprovador" — os dados
// pessoais são do MDM e o único campo próprio é SG_ATIVO. Por isso a
// aba tem listar, adicionar e ativar/desativar, sem edição.
apiRouter.get("/aprovadores", async (req, res) => {
  try {
    const limite = Math.min(parseInt(req.query.limit, 10) || 500, 5000);
    // LEFT JOIN de propósito: um aprovador cujo usuário saiu do MDM
    // continua listado (com os campos vazios) em vez de sumir da tela
    // sem explicação.
    // CD_EMAIL é o nome real da coluna no MDM (o DER antigo mostrava
    // DS_EMAIL — divergência só descoberta em produção, via "Invalid
    // column name"). Alias AS DS_EMAIL preserva o contrato do JSON
    // abaixo e o que o front-end já espera, sem tocar em mais nada.
    const result = await runQuery(
      `SELECT TOP (@limite)
              a.ID_USUARIO, a.SG_ATIVO, a.DT_ATUALIZACAO,
              m.CD_MATRICULA, m.NM_USUARIO, m.CD_EMAIL AS DS_EMAIL,
              m.NM_POSICAO, m.NM_ESTADO, m.NM_CIDADE
       FROM ${FULL_TABLE_NAME} a
       LEFT JOIN ${FULL_MDM_TABLE} m ON m.ID_USUARIO = a.ID_USUARIO
       ORDER BY m.NM_USUARIO, a.ID_USUARIO`,
      [["limite", sql.Int, limite]]
    );
    res.json(
      result.recordset.map((r) => ({
        ID_USUARIO: r.ID_USUARIO,
        CD_MATRICULA: r.CD_MATRICULA,
        NM_USUARIO: r.NM_USUARIO,
        DS_EMAIL: r.DS_EMAIL,
        // Cargo/estado/cidade vêm do MESMO join que já traz
        // nome/matrícula/e-mail, sem consulta extra. O cargo aparece no
        // card; os três juntos abrem o modal de edição já preenchido,
        // sem precisar consultar o MDM de novo.
        NM_POSICAO: r.NM_POSICAO,
        NM_ESTADO: r.NM_ESTADO,
        NM_CIDADE: r.NM_CIDADE,
        ATIVO: r.SG_ATIVO === "S",
        DT_ATUALIZACAO: r.DT_ATUALIZACAO,
      }))
    );
  } catch (err) {
    console.error("[aprovadores] erro ao listar:", err.message);
    res.status(500).json({ error: "Erro ao consultar aprovadores: " + err.message });
  }
});

// Busca de pessoas no MDM: ?q=<termo>, agora sempre em NM_USUARIO,
// CD_EMAIL e CD_MATRICULA ao mesmo tempo (nome, e-mail OU matrícula
// batendo já entra no resultado) — antes só buscava 1 coluna por vez
// via ?campo=nome|email, o que deixava a busca "errada" quando a
// pessoa digitava e-mail ou matrícula num campo pensado pra nome (ex.:
// Líder do Projeto). ?campo= é aceito mas ignorado (compatibilidade).
//
// TOP (10) e mínimo de 2 caracteres seguram o custo: sem isso, um
// LIKE '%%' varreria o MDM inteiro a cada tecla digitada.
const MDM_BUSCA_MIN = 2;

// Tipo de usuário "terceiro" no MDM (kzn_tipo_usuario). A aba Usuários
// lista SÓ esses — constante do servidor, nunca parâmetro da URL, para
// que o filtro não possa ser removido pelo cliente.
const ID_TIPO_USUARIO_TERCEIRO = 2;

// Monta o termo de um LIKE "contém", escapando os curingas do SQL Server
// (%, _ e [) para que o texto digitado seja buscado literalmente.
function termoContem(texto) {
  return "%" + String(texto).replace(/[[%_]/g, (c) => "[" + c + "]") + "%";
}
const MDM_BUSCA_TOP = 10;

apiRouter.get("/aprovadores/mdm", async (req, res) => {
  try {
    const termo = String(req.query.q || "").trim();
    if (termo.length < MDM_BUSCA_MIN) return res.json([]);

    const coluna = String(req.query.campo || "").toLowerCase() === "email" ? "CD_EMAIL" : "NM_USUARIO";
    const termoLike = termoContem(termo);

    // ?tipo=1 (empregado próprio) ou ?tipo=2 (terceiro) — usado pelos
    // dois campos de equipe do Novo Kaizen, que buscam populações
    // diferentes. Só esses dois valores são aceitos; qualquer outra
    // coisa é ignorada e a busca segue sem recorte, que é o
    // comportamento de quem já usava esta rota (aba Aprovadores).
    const tipoPedido = parseInt(req.query.tipo, 10);
    const tipo = tipoPedido === 1 || tipoPedido === 2 ? tipoPedido : null;

    const params = [["termo", sql.NVarChar(255), termoLike]];
    let filtroTipo = "";
    if (tipo !== null) {
      filtroTipo = "AND ID_TIPO_USUARIO = @tipo";
      params.push(["tipo", sql.Int, tipo]);
    }

    const result = await runQuery(
      `SELECT TOP (${MDM_BUSCA_TOP})
              ID_USUARIO, NM_USUARIO, CD_MATRICULA, CD_EMAIL, NM_POSICAO, NM_ESTADO, NM_CIDADE
       FROM ${FULL_MDM_TABLE}
       -- O bloco de OR fica entre parênteses: sem eles o AND do tipo se
       -- ligaria só à última alternativa e vazaria gente de outro tipo.
       WHERE (NM_USUARIO LIKE @termo
          OR CD_EMAIL LIKE @termo
          OR CD_MATRICULA LIKE @termo
          -- nome.sobrenome@vale.com -> "nome sobrenome": cobre quando
          -- NM_USUARIO está vazio/errado mas o e-mail bate com o nome
          -- digitado (mesmo raciocínio do nomeDoEmail() no front-end).
          OR REPLACE(LEFT(CD_EMAIL, CASE WHEN CHARINDEX('@', CD_EMAIL) > 0 THEN CHARINDEX('@', CD_EMAIL) - 1 ELSE LEN(CD_EMAIL) END), '.', ' ') LIKE @termo)
       ${filtroTipo}
       ORDER BY NM_USUARIO`,
      params
    );
    res.json(result.recordset);
  } catch (err) {
    console.error("[aprovadores] erro ao buscar no MDM:", err.message);
    res.status(500).json({ error: "Erro ao buscar no MDM: " + err.message });
  }
});

// Consulta um usuário no MDM pelo ID — usada pelo formulário de
// "Novo Aprovador" para mostrar de quem é aquele ID antes de salvar
// (nome/matrícula/e-mail não são digitados: pertencem ao MDM).
apiRouter.get("/aprovadores/mdm/:id", async (req, res) => {
  try {
    const id = parseInt(req.params.id, 10);
    if (!Number.isInteger(id)) return res.status(400).json({ error: "ID_USUARIO inválido." });

    const result = await runQuery(
      `SELECT TOP (1) ID_USUARIO, CD_MATRICULA, NM_USUARIO, CD_EMAIL AS DS_EMAIL, NM_POSICAO
       FROM ${FULL_MDM_TABLE} WHERE ID_USUARIO = @id`,
      [["id", sql.Int, id]]
    );
    if (!result.recordset.length) {
      return res.status(404).json({ error: "Usuário não encontrado no MDM." });
    }
    res.json(result.recordset[0]);
  } catch (err) {
    console.error("[aprovadores] erro ao consultar MDM:", err.message);
    res.status(500).json({ error: "Erro ao consultar o MDM: " + err.message });
  }
});

// CD_MATRICULA da pessoa, buscada no MDM pelo ID_USUARIO. Pelo DER,
// kzn_aprovador tem PK (ID_APROVADOR, CD_MATRICULA) e ID_USUARIO como
// FK — ou seja, a matrícula é NOT NULL e precisa ser gravada junto.
//
// Vem sempre do MDM, nunca do corpo da requisição: quem chama escolhe a
// pessoa (ID_USUARIO) e a matrícula é um dado derivado dela; aceitar do
// cliente permitiria gravar um par ID/matrícula que não existe no MDM.
//
// Devolve null quando o ID_USUARIO não existe lá — o que também serve
// de validação, poupando uma consulta só para conferir a existência.
async function matriculaDoMdm(idUsuario) {
  const r = await runQuery(
    `SELECT TOP (1) CD_MATRICULA FROM ${FULL_MDM_TABLE} WHERE ID_USUARIO = @id`,
    [["id", sql.Int, idUsuario]]
  );
  const linha = r.recordset[0];
  return linha && linha.CD_MATRICULA != null ? linha.CD_MATRICULA : null;
}

// ID_APROVADOR (PK própria de kzn_aprovador) a partir do ID_USUARIO
// escolhido na tela de Novo Kaizen — ver POST /kaizens abaixo. O
// front-end só conhece/mostra ID_USUARIO (é o que GET /aprovadores
// devolve); a FK de kzn_pedravisaoconsolidada é para ID_APROVADOR, não
// para ID_USUARIO, então resolvemos aqui, sempre no servidor, e de
// quebra confirmamos que o aprovador escolhido está ATIVO.
async function idAprovadorPorUsuario(idUsuario) {
  const r = await runQuery(
    `SELECT TOP (1) ID_APROVADOR FROM ${FULL_TABLE_NAME} WHERE ID_USUARIO = @id AND SG_ATIVO = 'S'`,
    [["id", sql.Int, idUsuario]]
  );
  return r.recordset.length ? r.recordset[0].ID_APROVADOR : null;
}

// Adicionar — grava o vínculo (ID_USUARIO + CD_MATRICULA, ambos do
// MDM); o usuário precisa existir lá (a FK garante isso no banco, mas
// checamos antes para devolver uma mensagem clara em vez de um erro cru
// de constraint).
apiRouter.post("/aprovadores", async (req, res) => {
  try {
    const idUsuario = parseInt(req.body?.ID_USUARIO, 10);
    if (!Number.isInteger(idUsuario)) {
      return res.status(400).json({ error: "ID_USUARIO é obrigatório e deve ser um número inteiro." });
    }

    const matricula = await matriculaDoMdm(idUsuario);
    if (matricula == null) {
      return res.status(400).json({ error: "Usuário não encontrado no MDM — verifique o ID_USUARIO." });
    }

    const jaExiste = await runQuery(
      `SELECT TOP (1) 1 AS X FROM ${FULL_TABLE_NAME} WHERE ID_USUARIO = @id`,
      [["id", sql.Int, idUsuario]]
    );
    if (jaExiste.recordset.length) {
      return res.status(409).json({ error: "Este usuário já está cadastrado como aprovador." });
    }

    // ID_APROVADOR é NOT NULL e NÃO é identity: o banco não gera valor
    // sozinho, então o INSERT precisa trazer o próximo — mesma regra das
    // tabelas de cadastro (ver ISNULL(MAX(pk),0)+1 em
    // registrarCadastroBilingue). Sem isso o insert falha com "Cannot
    // insert the value NULL into column 'ID_APROVADOR'".
    const proximo = await runQuery(
      `SELECT ISNULL(MAX(ID_APROVADOR), 0) + 1 AS PROXIMO FROM ${FULL_TABLE_NAME}`
    );
    const idAprovador = proximo.recordset[0].PROXIMO;

    await runQuery(
      `INSERT INTO ${FULL_TABLE_NAME} (ID_APROVADOR, CD_MATRICULA, ID_USUARIO, SG_ATIVO, DT_ATUALIZACAO)
       VALUES (@idAprovador, @matricula, @id, 'S', GETDATE())`,
      [
        ["idAprovador", sql.Int, idAprovador],
        ["matricula", sql.NVarChar(30), matricula],
        ["id", sql.Int, idUsuario],
      ]
    );
    res.status(201).json({ ok: true, ID_APROVADOR: idAprovador, ID_USUARIO: idUsuario });
  } catch (err) {
    console.error("[aprovadores] erro ao inserir:", err.message);
    res.status(500).json({ error: "Erro ao inserir aprovador: " + err.message });
  }
});

// Editar — kzn_aprovador só tem ID_USUARIO e SG_ATIVO (ver DER), e
// SG_ATIVO é o ativar/desativar logo abaixo. Então "editar" aqui é
// APONTAR o registro para outra pessoa: troca o ID_USUARIO, mantendo o
// mesmo vínculo (e o SG_ATIVO atual). Nome, cargo, matrícula e e-mail
// continuam vindo do MDM — nada disso é editável por aqui.
//
// Mesmas validações do POST, pela mesma razão: ID inteiro, usuário
// existente no MDM e sem duplicar um aprovador já cadastrado.
apiRouter.put("/aprovadores/:id", async (req, res) => {
  try {
    const idAtual = parseInt(req.params.id, 10);
    const idNovo = parseInt(req.body?.ID_USUARIO, 10);
    if (!Number.isInteger(idAtual)) return res.status(400).json({ error: "ID_USUARIO inválido." });
    if (!Number.isInteger(idNovo)) {
      return res.status(400).json({ error: "ID_USUARIO é obrigatório e deve ser um número inteiro." });
    }

    const matricula = await matriculaDoMdm(idNovo);
    if (matricula == null) {
      return res.status(400).json({ error: "Usuário não encontrado no MDM — verifique o ID_USUARIO." });
    }

    if (idNovo !== idAtual) {
      const jaExiste = await runQuery(
        `SELECT TOP (1) 1 AS X FROM ${FULL_TABLE_NAME} WHERE ID_USUARIO = @id`,
        [["id", sql.Int, idNovo]]
      );
      if (jaExiste.recordset.length) {
        return res.status(409).json({ error: "Este usuário já está cadastrado como aprovador." });
      }
    }

    // CD_MATRICULA acompanha o ID_USUARIO: as duas colunas descrevem a
    // MESMA pessoa, então apontar o registro para outra sem atualizar a
    // matrícula deixaria a linha com um par que não existe no MDM.
    const alterado = await runQuery(
      `UPDATE ${FULL_TABLE_NAME}
          SET ID_USUARIO = @idNovo, CD_MATRICULA = @matricula, DT_ATUALIZACAO = GETDATE()
        WHERE ID_USUARIO = @idAtual`,
      [
        ["idNovo", sql.Int, idNovo],
        ["matricula", sql.NVarChar(30), matricula],
        ["idAtual", sql.Int, idAtual],
      ]
    );
    if (!alterado.rowsAffected[0]) {
      return res.status(404).json({ error: "Aprovador não encontrado." });
    }
    res.json({ ok: true, ID_USUARIO: idNovo });
  } catch (err) {
    console.error("[aprovadores] erro ao editar:", err.message);
    res.status(500).json({ error: "Erro ao editar aprovador: " + err.message });
  }
});

// Ativar/desativar — mesmo contrato das abas de cadastro.
apiRouter.put("/aprovadores/:id/status", async (req, res) => {
  try {
    const id = parseInt(req.params.id, 10);
    if (!Number.isInteger(id)) return res.status(400).json({ error: "ID_USUARIO inválido." });
    if (typeof req.body?.ativo !== "boolean") {
      return res.status(400).json({ error: "Campo 'ativo' (true/false) é obrigatório." });
    }

    const result = await runQuery(
      `UPDATE ${FULL_TABLE_NAME} SET SG_ATIVO = @sgAtivo, DT_ATUALIZACAO = GETDATE()
       WHERE ID_USUARIO = @id`,
      [
        ["sgAtivo", sql.Char(1), req.body.ativo ? "S" : "N"],
        ["id", sql.Int, id],
      ]
    );
    if (!result.rowsAffected[0]) return res.status(404).json({ error: "Aprovador não encontrado." });
    res.json({ ok: true, ativo: req.body.ativo });
  } catch (err) {
    console.error("[aprovadores] erro ao atualizar status:", err.message);
    res.status(500).json({ error: "Erro ao atualizar status do aprovador: " + err.message });
  }
});

// ------------------------------------------------------------------
// API — kzn_mdm_hierarquia (aba "Usuários")
// ------------------------------------------------------------------
// SOMENTE LEITURA, de propósito — e o próprio modal da tela diz que os
// dados são sincronizados do MDM corporativo. Por isso não há POST/PUT
// aqui: criar/editar/inativar usuário exigiria colunas (ou uma tabela
// de vínculo) que esta rota não usa hoje.
// O papel exibido é DERIVADO: quem está em kzn_aprovador aparece como
// "Aprovador"; os demais, como "Operador". É a única fonte de papel
// disponível hoje no modelo.
// CD_EMAIL é o nome real da coluna de e-mail no MDM (não DS_EMAIL —
// ver nota em buscarMdmPorEmail acima); alias AS DS_EMAIL preserva o
// contrato do JSON abaixo.
// Empresas distintas dos terceiros — alimenta o filtro "Empresa" da
// aba Usuários. Mesmo recorte fixo da listagem (ID_TIPO_USUARIO = 2),
// para o combo não oferecer empresa que a lista nunca mostraria.
//
// Registrada ANTES de /usuarios para não ser capturada por uma futura
// rota com parâmetro.
// Valores distintos de uma coluna do MDM, para alimentar os filtros da
// aba Usuários. A coluna vem SEMPRE de uma constante do código (ver as
// duas rotas abaixo), nunca da URL — não há como pedir outra coluna.
//
// Mesmo recorte fixo da listagem (ID_TIPO_USUARIO = 2): o combo não
// oferece opção que a lista nunca mostraria.
async function opcoesDistintasDoMdm(coluna) {
  const result = await runQuery(
    `SELECT DISTINCT ${coluna} AS VALOR
     FROM ${FULL_MDM_TABLE}
     WHERE ID_TIPO_USUARIO = @tipo AND ${coluna} IS NOT NULL AND LTRIM(RTRIM(${coluna})) <> ''
     ORDER BY ${coluna}`,
    [["tipo", sql.Int, ID_TIPO_USUARIO_TERCEIRO]]
  );
  return result.recordset.map((r) => r.VALOR);
}

// Registradas ANTES de /usuarios para não serem capturadas por uma
// futura rota com parâmetro.
apiRouter.get("/usuarios/empresas", async (req, res) => {
  try {
    res.json(await opcoesDistintasDoMdm("NM_EMPRESA"));
  } catch (err) {
    console.error("[usuarios] erro ao listar empresas:", err.message);
    res.status(500).json({ error: "Erro ao consultar empresas: " + err.message });
  }
});

apiRouter.get("/usuarios/unidades", async (req, res) => {
  try {
    res.json(await opcoesDistintasDoMdm("NM_SITE"));
  } catch (err) {
    console.error("[usuarios] erro ao listar unidades:", err.message);
    res.status(500).json({ error: "Erro ao consultar unidades: " + err.message });
  }
});

// Lista os usuários TERCEIROS do MDM (ID_TIPO_USUARIO = 2).
//
// O recorte por tipo é constante do servidor e entra em toda consulta,
// independentemente dos filtros da tela: busca, empresa e unidade só
// estreitam o resultado, nunca ampliam.
//
// ?q=       nome, e-mail ou matrícula (mínimo 2 caracteres; abaixo
//           disso é ignorado, como o autocomplete da tela espera)
// ?empresa= NM_EMPRESA exata, vinda do próprio combo
// ?unidade= NM_SITE exata, vinda do próprio combo
apiRouter.get("/usuarios", async (req, res) => {
  try {
    const limite = Math.min(parseInt(req.query.limit, 10) || 500, 5000);
    const termo = String(req.query.q || "").trim();
    const empresa = String(req.query.empresa || "").trim();
    const unidade = String(req.query.unidade || "").trim();

    const filtros = ["m.ID_TIPO_USUARIO = @tipo"];
    const params = [
      ["limite", sql.Int, limite],
      ["tipo", sql.Int, ID_TIPO_USUARIO_TERCEIRO],
    ];

    if (termo.length >= MDM_BUSCA_MIN) {
      filtros.push(
        "(m.NM_USUARIO LIKE @termo OR m.CD_EMAIL LIKE @termo OR m.CD_MATRICULA LIKE @termo" +
        " OR REPLACE(LEFT(m.CD_EMAIL, CASE WHEN CHARINDEX('@', m.CD_EMAIL) > 0 THEN CHARINDEX('@', m.CD_EMAIL) - 1 ELSE LEN(m.CD_EMAIL) END), '.', ' ') LIKE @termo)"
      );
      params.push(["termo", sql.NVarChar(255), termoContem(termo)]);
    }
    if (empresa) {
      filtros.push("m.NM_EMPRESA = @empresa");
      params.push(["empresa", sql.NVarChar(30), empresa]);
    }
    if (unidade) {
      filtros.push("m.NM_SITE = @unidade");
      params.push(["unidade", sql.NVarChar(30), unidade]);
    }

    // A grade mostra 6 colunas, mas a listagem traz o registro inteiro:
    // é o que o modal de edição precisa, e assim abrir a edição não faz
    // requisição nenhuma. São 11 colunas a mais num resultado que já é
    // limitado a 500 linhas.
    const colunas = COLUNAS_MDM_TEXTO.map(([c]) => "m." + c).join(", ");
    const result = await runQuery(
      `SELECT TOP (@limite)
              m.ID_USUARIO, m.CD_MATRICULA, m.SG_ATIVO, ${colunas}
       FROM ${FULL_MDM_TABLE} m
       WHERE ${filtros.join(" AND ")}
       ORDER BY m.NM_USUARIO`,
      params
    );
    res.json(
      result.recordset.map((r) => ({
        ...r,
        // Booleano, não a letra: "Ativo"/"Inativo" é rótulo de tela e
        // acompanha a troca de idioma no front-end.
        ATIVO: r.SG_ATIVO === "S",
      }))
    );
  } catch (err) {
    console.error("[usuarios] erro ao listar:", err.message);
    res.status(500).json({ error: "Erro ao consultar usuários: " + err.message });
  }
});

// ── Escrita em kzn_mdm_hierarquia (aba "Usuários") ──
//
// A CHAVE PRIMÁRIA É COMPOSTA: (ID_USUARIO, CD_MATRICULA,
// ID_TIPO_USUARIO) — ver o DER. Duas consequências que valem para as
// três rotas abaixo:
//
//   1. Toda condição de identificação usa as TRÊS colunas. Filtrar só
//      por ID_USUARIO poderia atingir mais de uma linha, já que o mesmo
//      ID pode aparecer com matrículas diferentes.
//   2. ID_USUARIO e CD_MATRICULA não são editáveis: trocá-los é criar
//      outro registro, não editar este. A tela mostra os dois campos
//      travados na edição.
//
// ID_TIPO_USUARIO é constante do servidor (2 = terceiro) e nunca vem do
// cliente: é o mesmo recorte da listagem, e é o que impede esta tela de
// alcançar empregados próprios.
const COLUNAS_MDM_TEXTO = [
  ["NM_USUARIO", 30],
  ["CD_EMAIL", 100],
  ["NM_POSICAO", 30],
  ["NM_EMPRESA", 30],
  ["NM_PAIS", 30],
  ["NM_ESTADO", 30],
  ["NM_CIDADE", 30],
  ["NM_SITE", 30],
];
for (let n = 1; n <= 8; n++) COLUNAS_MDM_TEXTO.push([`NM_HIERARQUIA_N${n}`, 80]);

// Texto vazio vira NULL: a coluna aceita nulo e "" só ocuparia espaço
// fingindo ser um valor. Corta espaços das pontas por higiene.
function textoOuNulo(valor) {
  if (valor == null) return null;
  const limpo = String(valor).trim();
  return limpo === "" ? null : limpo;
}

// Parâmetros das colunas de texto, na ordem de COLUNAS_MDM_TEXTO. O
// tamanho declarado é o do DER: passar mais que isso é erro do banco
// (traduzido por mensagemErroSql), não truncamento silencioso.
function parametrosDeTexto(corpo) {
  return COLUNAS_MDM_TEXTO.map(([coluna, tamanho]) => [
    coluna,
    sql.NVarChar(tamanho),
    textoOuNulo(corpo?.[coluna]),
  ]);
}

function chaveDoUsuario(req) {
  const idUsuario = parseInt(req.params.id, 10);
  const matricula = textoOuNulo(req.body?.CD_MATRICULA ?? req.query?.matricula);
  if (!Number.isInteger(idUsuario)) return { erro: "ID_USUARIO inválido." };
  if (!matricula) return { erro: "CD_MATRICULA é obrigatória: faz parte da chave do registro." };
  return { idUsuario, matricula };
}

const FILTRO_CHAVE_MDM =
  "ID_USUARIO = @id AND CD_MATRICULA = @matricula AND ID_TIPO_USUARIO = @tipo";

// Apoio do formulário: o próximo ID livre e os valores já cadastrados
// em cada campo de texto, para o usuário escolher em vez de digitar.
//
// Uma requisição só, com duas consultas: 14 chamadas separadas de
// DISTINCT (uma por coluna) custariam 14 idas ao banco para montar um
// modal. O UNION devolve tudo de uma vez, já sem repetições.
//
// NM_USUARIO e CD_EMAIL ficam de fora de propósito: são de cada pessoa,
// sugerir o de outra só atrapalharia.
const COLUNAS_COM_SUGESTAO = COLUNAS_MDM_TEXTO
  .map(([c]) => c)
  .filter((c) => c !== "NM_USUARIO" && c !== "CD_EMAIL");

apiRouter.get("/usuarios/formulario", async (req, res) => {
  try {
    const proximo = await runQuery(
      `SELECT ISNULL(MAX(ID_USUARIO), 0) + 1 AS PROXIMO FROM ${FULL_MDM_TABLE}`
    );

    const uniao = COLUNAS_COM_SUGESTAO.map(
      (c) => `SELECT '${c}' AS COLUNA, ${c} AS VALOR FROM ${FULL_MDM_TABLE}
              WHERE ID_TIPO_USUARIO = @tipo AND ${c} IS NOT NULL AND LTRIM(RTRIM(${c})) <> ''`
    ).join(" UNION ");

    const valores = await runQuery(`${uniao} ORDER BY COLUNA, VALOR`, [
      ["tipo", sql.Int, ID_TIPO_USUARIO_TERCEIRO],
    ]);

    const opcoes = {};
    COLUNAS_COM_SUGESTAO.forEach((c) => { opcoes[c] = []; });
    valores.recordset.forEach((r) => { opcoes[r.COLUNA].push(r.VALOR); });

    res.json({ proximoId: proximo.recordset[0].PROXIMO, opcoes });
  } catch (err) {
    console.error("[usuarios] erro ao montar formulário:", err.message);
    res.status(500).json({ error: "Erro ao consultar opções: " + err.message });
  }
});

apiRouter.post("/usuarios", async (req, res) => {
  try {
    const idUsuario = parseInt(req.body?.ID_USUARIO, 10);
    const matricula = textoOuNulo(req.body?.CD_MATRICULA);
    const nome = textoOuNulo(req.body?.NM_USUARIO);
    if (!Number.isInteger(idUsuario)) {
      return res.status(400).json({ error: "ID_USUARIO é obrigatório e deve ser um número inteiro." });
    }
    if (!matricula) return res.status(400).json({ error: "CD_MATRICULA é obrigatória." });
    if (!nome) return res.status(400).json({ error: "NM_USUARIO é obrigatório." });

    // ID novo tem de ser maior que todos os já existentes. A tela já
    // sugere o próximo (ver GET /usuarios/formulario), mas a regra vive
    // aqui: o campo é editável e a sugestão pode envelhecer entre abrir
    // o modal e salvar.
    const maior = await runQuery(
      `SELECT ISNULL(MAX(ID_USUARIO), 0) AS MAIOR FROM ${FULL_MDM_TABLE}`
    );
    const maiorAtual = maior.recordset[0].MAIOR;
    if (idUsuario <= maiorAtual) {
      return res.status(400).json({
        error: `O ID do usuário deve ser maior que ${maiorAtual}, o maior já cadastrado. Sugerido: ${maiorAtual + 1}.`,
      });
    }

    const chave = [
      ["id", sql.Int, idUsuario],
      ["matricula", sql.NVarChar(30), matricula],
      ["tipo", sql.Int, ID_TIPO_USUARIO_TERCEIRO],
    ];

    const jaExiste = await runQuery(
      `SELECT TOP (1) 1 AS X FROM ${FULL_MDM_TABLE} WHERE ${FILTRO_CHAVE_MDM}`,
      chave
    );
    if (jaExiste.recordset.length) {
      return res.status(409).json({ error: "Já existe um usuário com este ID e matrícula." });
    }

    const colunas = COLUNAS_MDM_TEXTO.map(([c]) => c);
    await runQuery(
      `INSERT INTO ${FULL_MDM_TABLE}
         (ID_USUARIO, CD_MATRICULA, ID_TIPO_USUARIO, SG_ATIVO, ${colunas.join(", ")}, DT_ATUALIZACAO)
       VALUES
         (@id, @matricula, @tipo, @sgAtivo, ${colunas.map((c) => "@" + c).join(", ")}, GETDATE())`,
      [
        ...chave,
        ["sgAtivo", sql.Char(1), req.body?.ATIVO === false ? "N" : "S"],
        ...parametrosDeTexto(req.body),
      ]
    );
    res.status(201).json({ ok: true, ID_USUARIO: idUsuario, CD_MATRICULA: matricula });
  } catch (err) {
    console.error("[usuarios] erro ao inserir:", err.message);
    res.status(500).json({ error: mensagemErroSql(err, "usuário", "tipo de usuário") });
  }
});

// Editar — muda só os campos descritivos. A chave identifica a linha e
// não é alterada (ver nota acima).
apiRouter.put("/usuarios/:id", async (req, res) => {
  try {
    const { idUsuario, matricula, erro } = chaveDoUsuario(req);
    if (erro) return res.status(400).json({ error: erro });

    const nome = textoOuNulo(req.body?.NM_USUARIO);
    if (!nome) return res.status(400).json({ error: "NM_USUARIO é obrigatório." });

    const atribuicoes = COLUNAS_MDM_TEXTO.map(([c]) => `${c} = @${c}`).join(", ");
    const alterado = await runQuery(
      `UPDATE ${FULL_MDM_TABLE}
          SET ${atribuicoes}, DT_ATUALIZACAO = GETDATE()
        WHERE ${FILTRO_CHAVE_MDM}`,
      [
        ["id", sql.Int, idUsuario],
        ["matricula", sql.NVarChar(30), matricula],
        ["tipo", sql.Int, ID_TIPO_USUARIO_TERCEIRO],
        ...parametrosDeTexto(req.body),
      ]
    );
    if (!alterado.rowsAffected[0]) return res.status(404).json({ error: "Usuário não encontrado." });
    res.json({ ok: true, ID_USUARIO: idUsuario, CD_MATRICULA: matricula });
  } catch (err) {
    console.error("[usuarios] erro ao editar:", err.message);
    res.status(500).json({ error: mensagemErroSql(err, "usuário", "tipo de usuário") });
  }
});

// Ativar/desativar — grava SG_ATIVO. Mesmo contrato das outras abas: o
// registro nunca é excluído, só deixa de contar como ativo.
apiRouter.put("/usuarios/:id/status", async (req, res) => {
  try {
    const { idUsuario, matricula, erro } = chaveDoUsuario(req);
    if (erro) return res.status(400).json({ error: erro });
    if (typeof req.body?.ativo !== "boolean") {
      return res.status(400).json({ error: "Campo 'ativo' (true/false) é obrigatório." });
    }

    const alterado = await runQuery(
      `UPDATE ${FULL_MDM_TABLE} SET SG_ATIVO = @sgAtivo, DT_ATUALIZACAO = GETDATE()
        WHERE ${FILTRO_CHAVE_MDM}`,
      [
        ["sgAtivo", sql.Char(1), req.body.ativo ? "S" : "N"],
        ["id", sql.Int, idUsuario],
        ["matricula", sql.NVarChar(30), matricula],
        ["tipo", sql.Int, ID_TIPO_USUARIO_TERCEIRO],
      ]
    );
    if (!alterado.rowsAffected[0]) return res.status(404).json({ error: "Usuário não encontrado." });
    res.json({ ok: true, ativo: req.body.ativo });
  } catch (err) {
    console.error("[usuarios] erro ao atualizar status:", err.message);
    res.status(500).json({ error: "Erro ao atualizar status do usuário: " + err.message });
  }
});

// ------------------------------------------------------------------
// API — cadastros bilíngues (kzn_categoria, kzn_replicacao,
// kzn_desperdicio, kzn_resultados)
// ------------------------------------------------------------------
// Estas 4 tabelas têm exatamente o mesmo desenho no DER
// (database/DER_VBM_Kaizen_CI.html): PK própria + ID_IDIOMA, URL_ICONE,
// NM_*, DS_*, SG_ATIVO, DT_ATUALIZACAO — 1 LINHA POR IDIOMA para o
// mesmo registro (mesmo ID, ID_IDIOMA diferente). Por isso todas
// compartilham as mesmas rotas/regras, geradas por
// registrarCadastroBilingue() abaixo: listar, buscar por id (2
// idiomas), criar, editar e ativar/desativar.
//
// TAMANHOS: vêm do DER (database/DER_VBM_Kaizen_CI.html). Antes
// deste ajuste o DER mostrava NM VARCHAR(20)/DS VARCHAR(40) e só a
// tabela de Categoria estava marcada como "exceção" (colunas já
// ampliadas para 30/100 no banco). A versão atual do DER mostra que
// as 4 tabelas (categoria, replicacao, desperdicio, resultados) têm
// exatamente as MESMAS colunas VARCHAR(30)/VARCHAR(100) — não há mais
// exceção nenhuma, as 4 sempre tiveram o mesmo tamanho.
const CADASTRO_LIMITES_DER = { nome: 30, descricao: 100 };

function tabelaCadastro(envVar, padrao) {
  return `[${DB_SCHEMA}].[${safeIdentifier(process.env[envVar], padrao)}]`;
}

/**
 * Registra as 5 rotas REST de um cadastro bilíngue.
 *
 * cfg:
 *   rota          — segmento da URL (ex.: "categorias")
 *   tabela        — nome completo já escapado ([schema].[tabela])
 *   pk            — coluna de chave primária (ex.: "ID_CATEGORIA")
 *   colNome       — coluna de nome (ex.: "NM_CATEGORIA")
 *   colDescricao  — coluna de descrição (ex.: "DS_CATEGORIA"). OPCIONAL:
 *                   omitir quando a tabela não tem coluna de descrição
 *                   (ex.: kzn_tipo_resultado, que só tem NM_*) — nesse
 *                   caso a rota nunca lê/grava DS e a validação exige
 *                   só o nome.
 *   maxNome       — limite de caracteres do nome (do DER)
 *   maxDescricao  — limite de caracteres da descrição (do DER).
 *                   Ignorado quando colDescricao não é passado.
 *   temIcone      — false quando a tabela não tem URL_ICONE (ex.:
 *                   kzn_tipo_resultado). Padrão true (as 4 tabelas
 *                   originais sempre tiveram essa coluna).
 *   rotuloSing    — rótulo em mensagens de erro (ex.: "categoria")
 *   colunasExtras — colunas adicionais a preservar no INSERT do MERGE,
 *                   herdadas da linha do outro idioma (ex.: a FK
 *                   ID_TIPO_RESULTADO de kzn_resultados). Opcional.
 *   contagem      — { tabela, coluna } para o badge "N kaizens".
 *                   Opcional: sem isso, QTD_KAIZENS vem null.
 *   capturarUsuarioResponsavel — true grava, de forma automática e
 *                   transparente (a interface nunca expõe nem permite
 *                   editar isso), o ID_USUARIO (kzn_mdm_hierarquia) de
 *                   quem gravou o registro por último — resolvido no
 *                   servidor via idUsuarioLogado(req), nunca enviado
 *                   pelo cliente. 1 coluna só (sem distinguir criação de
 *                   edição — mesmo desenho de DT_ATUALIZACAO, que já é
 *                   "a última gravação", não "a criação"). Padrão false
 *                   (as 5 tabelas originais não têm essa coluna).
 *                   Usuário não identificado (fora do Databricks Apps,
 *                   e-mail sem correspondência no MDM) grava NULL —
 *                   nunca bloqueia o salvamento.
 *   colUsuario    — nome da coluna, só usado quando
 *                   capturarUsuarioResponsavel é true. Padrão "ID_USUARIO".
 *   campoExtraEditavel — { col, campo } para 1 FK escolhida pelo usuário
 *                   num <select> do formulário (ex.: ID_TIPO_RESULTADO
 *                   em kzn_resultados, escolhido pelo nome na aba "Tipo
 *                   Resultados", gravado como ID). Diferente de
 *                   colunasExtras (que só HERDA o valor da linha do
 *                   outro idioma): aqui o valor vem do corpo da
 *                   requisição (campo `campo`, nível raiz — não dentro
 *                   de pt/en, é o mesmo nos 2 idiomas) e é gravado
 *                   direto, tanto ao criar quanto ao editar. Por padrão
 *                   aceita null (não bloqueia o salvamento sem valor
 *                   escolhido) — passe `obrigatorio: true` dentro do
 *                   objeto quando a coluna real for NOT NULL (ex.:
 *                   ID_TIPO_RESULTADO em kzn_resultados — "Cannot
 *                   insert the value NULL..." se salvar sem escolher).
 *                   `rotulo` (opcional): nome amigável usado na
 *                   mensagem de erro de "obrigatório" — sem ele, usa
 *                   o próprio nome da coluna (col).
 */

// Traduz o erro cru do SQL Server pra algo que o usuário entenda. Erros
// SEM tradução conhecida (retorno null) continuam aparecendo crus, como
// sempre — nunca escondidos. Hoje só cobre violação de UNIQUE KEY (nome
// duplicado no mesmo idioma) — o caso real observado em produção
// ("Violation of UNIQUE KEY constraint 'UQ_KZN_RESULTADOS_NM'...").
// Compartilhada por todas as 6 tabelas bilíngues: qualquer uma delas
// pode ter a mesma constraint de nome único.
function mensagemErroSql(err, rotuloSing, rotuloExtra) {
  const numero = err && err.number;
  const texto = (err && err.message) || "";
  if (numero === 2627 || numero === 2601 || /violation of unique key constraint|cannot insert duplicate key/i.test(texto)) {
    return `Já existe um(a) ${rotuloSing} cadastrado(a) com esse nome neste idioma.`;
  }
  // A FK dessas tabelas é COMPOSTA (id + ID_IDIOMA), porque a tabela
  // referenciada tem PK composta. Então a linha em INGLÊS do registro só
  // grava se o item escolhido também tiver a linha em inglês: item
  // cadastrado só em português derruba exatamente essa metade do save
  // (FK_KZN_RESULTADOS_TIPO, observado em produção).
  if (numero === 547 || /conflicted with the foreign key constraint/i.test(texto)) {
    return `O ${rotuloExtra || "item vinculado"} selecionado não está cadastrado nos dois idiomas (Português e Inglês). Cadastre a tradução dele antes de usá-lo aqui.`;
  }
  return null; // sem tradução conhecida: quem chamou usa a mensagem crua do err
}

function registrarCadastroBilingue(cfg) {
  const { rota, tabela, pk, colNome, colDescricao, maxNome, maxDescricao, rotuloSing } = cfg;
  const extras = cfg.colunasExtras || [];
  const temIcone = cfg.temIcone !== false;
  const capturarUsuario = !!cfg.capturarUsuarioResponsavel;
  const extraEditavel = cfg.campoExtraEditavel || null;
  const colUsuario = cfg.colUsuario || "ID_USUARIO";
  const log = `[${rota}]`;

  // Validação única, compartilhada por POST (criar) e PUT (editar) —
  // garante que os dois processos apliquem exatamente a mesma regra.
  function validarCampos(nomePt, descPt, nomeEn, descEn) {
    if (!nomePt || !nomeEn || (colDescricao && (!descPt || !descEn))) {
      return colDescricao
        ? "Nome e descrição são obrigatórios nos dois idiomas."
        : "Nome é obrigatório nos dois idiomas.";
    }
    if (nomePt.length > maxNome || nomeEn.length > maxNome) {
      return `O nome deve ter no máximo ${maxNome} caracteres (em cada idioma).`;
    }
    if (colDescricao && (descPt.length > maxDescricao || descEn.length > maxDescricao)) {
      return `A descrição deve ter no máximo ${maxDescricao} caracteres (em cada idioma).`;
    }
    return null;
  }

  // Mesma regra nos dois processos (criar/editar): valor não numérico
  // é erro de formato; ausente só é erro se a coluna real for NOT NULL
  // (extraEditavel.obrigatorio) — sem isso, o INSERT falha só lá no
  // banco com "Cannot insert the value NULL...", uma mensagem que não
  // diz ao usuário qual campo faltou.
  function validarExtra(extra) {
    if (!extraEditavel) return null;
    if (extra != null && Number.isNaN(extra)) return `${extraEditavel.col} inválido.`;
    if (extraEditavel.obrigatorio && extra == null) {
      return `${extraEditavel.rotulo || extraEditavel.col} é obrigatório.`;
    }
    return null;
  }

  function lerCorpo(req) {
    const pt = req.body?.pt || {};
    const en = req.body?.en || {};
    const corpo = {
      nomePt: (pt.NM || "").trim(),
      descPt: (pt.DS || "").trim(),
      nomeEn: (en.NM || "").trim(),
      descEn: (en.DS || "").trim(),
    };
    if (extraEditavel) {
      const bruto = req.body?.[extraEditavel.campo];
      corpo.extra = bruto === "" || bruto == null ? null : parseInt(bruto, 10);
    }
    return corpo;
  }

  // Upsert de 1 linha (1 idioma) — MERGE: atualiza se a linha
  // (pk + ID_IDIOMA) já existe, cria se não existe. Usada tanto pelo
  // POST (id novo → sempre INSERT) quanto pelo PUT (UPDATE pra quem já
  // existe, INSERT só pro idioma que faltava). Mesma função, mesma
  // regra, nos dois processos.
  // WHEN NOT MATCHED: URL_ICONE (e demais colunasExtras) herdam o valor
  // da linha do OUTRO idioma que já existir — mesmo registro, mesmo
  // ícone/FK nos dois idiomas; ficam NULL na criação, quando nenhuma
  // linha existe ainda. Tabela sem URL_ICONE (temIcone:false): a coluna
  // simplesmente não entra no MERGE, senão o SQL Server rejeitaria a
  // query inteira com "Invalid column name".
  const colsHerdadas = (temIcone ? ["URL_ICONE"] : []).concat(extras);
  const selectHerdado = (col) => `(SELECT TOP (1) ${col} FROM ${tabela} WHERE ${pk} = @id)`;

  function upsertIdioma(id, idIdioma, nome, descricao, idUsuario, extraValor) {
    const colsInsert = [pk, "ID_IDIOMA"].concat(colsHerdadas, [colNome], colDescricao ? [colDescricao] : [], ["SG_ATIVO", "DT_ATUALIZACAO"])
      .concat(capturarUsuario ? [colUsuario] : [])
      .concat(extraEditavel ? [extraEditavel.col] : []);
    const valsInsert = ["@id", "@idIdioma"].concat(colsHerdadas.map(selectHerdado), ["@nome"], colDescricao ? ["@descricao"] : [], ["'S'", "GETDATE()"])
      // Sempre quem está salvando agora — criar ou editar, sem distinguir
      // (mesmo desenho de DT_ATUALIZACAO, ao lado).
      .concat(capturarUsuario ? ["@idUsuario"] : [])
      // Diferente de colsHerdadas: não herda da linha do outro idioma,
      // é sempre o que veio no corpo desta requisição (mesmo valor nos
      // 2 idiomas, porque os 2 upserts do mesmo POST/PUT usam o mesmo
      // extraValor).
      .concat(extraEditavel ? ["@extra"] : []);
    const setUpdate = `${colNome} = @nome` + (colDescricao ? `, ${colDescricao} = @descricao` : "") + `, DT_ATUALIZACAO = GETDATE()`
      + (capturarUsuario ? `, ${colUsuario} = @idUsuario` : "")
      + (extraEditavel ? `, ${extraEditavel.col} = @extra` : "");

    const params = [
      ["nome", sql.NVarChar(maxNome), nome],
      ["id", sql.Int, id],
      ["idIdioma", sql.Int, idIdioma],
    ];
    if (colDescricao) params.push(["descricao", sql.NVarChar(maxDescricao), descricao]);
    // Usuário não identificado (fora do Databricks Apps, e-mail sem
    // correspondência no MDM): grava NULL, nunca bloqueia o salvamento.
    if (capturarUsuario) params.push(["idUsuario", sql.Int, idUsuario ?? null]);
    // Sem seleção no combo: grava NULL, nunca bloqueia o salvamento.
    if (extraEditavel) params.push(["extra", sql.Int, extraValor ?? null]);

    return runQuery(
      `MERGE INTO ${tabela} AS target
       USING (SELECT @id AS ${pk}, @idIdioma AS ID_IDIOMA) AS src
         ON target.${pk} = src.${pk} AND target.ID_IDIOMA = src.ID_IDIOMA
       WHEN MATCHED THEN
         UPDATE SET ${setUpdate}
       WHEN NOT MATCHED THEN
         INSERT (${colsInsert.join(", ")})
         VALUES (${valsInsert.join(", ")});`,
      params
    );
  }

  // Listar — um registro por linha, no idioma pedido em ?idioma=
  // (pt-BR/en). Antes o ID_IDIOMA era fixo em PT, então a tela em
  // inglês continuava mostrando os nomes/descrições em português.
  //
  // A linha PT é a BASE (todo registro tem a dela; a tradução pode
  // nunca ter sido cadastrada). O idioma pedido entra por LEFT JOIN e
  // o COALESCE cai para o texto PT quando falta a tradução — assim
  // trocar para inglês nunca faz um registro sumir da lista.
  //
  // NM_PT vai junto de propósito: a contagem do badge casa por NOME na
  // tabela de pendências, que guarda o nome em português. Sem essa
  // coluna, listar em inglês zeraria todos os badges.
  apiRouter.get(`/${rota}`, async (req, res) => {
    try {
      const idIdiomaPedido = idIdiomaDaRequisicao(req);
      const colsSelect = [`base.${pk} AS ID`, `COALESCE(tr.${colNome}, base.${colNome}) AS NM`];
      if (colDescricao) colsSelect.push(`COALESCE(tr.${colDescricao}, base.${colDescricao}) AS DS`);
      colsSelect.push(`base.${colNome} AS NM_PT`);
      if (temIcone) colsSelect.push(`base.URL_ICONE`);
      colsSelect.push(
        `base.SG_ATIVO`,
        `CASE WHEN @idIdioma <> @idIdiomaBase AND tr.ID_IDIOMA IS NULL THEN 1 ELSE 0 END AS SEM_TRADUCAO`
      );
      const result = await runQuery(
        `SELECT ${colsSelect.join(", ")}
         FROM ${tabela} base
         LEFT JOIN ${tabela} tr
                ON tr.${pk} = base.${pk} AND tr.ID_IDIOMA = @idIdioma
         WHERE base.ID_IDIOMA = @idIdiomaBase
         ORDER BY COALESCE(tr.${colNome}, base.${colNome})`,
        [
          ["idIdioma", sql.Int, idIdiomaPedido],
          ["idIdiomaBase", sql.Int, ID_IDIOMA_PT],
        ]
      );

      // Contagem opcional (badge "N kaizens"), numa ÚNICA consulta
      // agrupada — não uma por registro. Se a tabela/coluna não existir
      // de verdade, falha sozinha sem derrubar a lista: todo mundo fica
      // com QTD_KAIZENS null e só loga o motivo.
      let contagemPorNome = {};
      if (cfg.contagem) {
        try {
          const contagem = await runQuery(
            `SELECT ${cfg.contagem.coluna} AS CHAVE, COUNT(*) AS QTD
             FROM ${cfg.contagem.tabela} GROUP BY ${cfg.contagem.coluna}`
          );
          contagem.recordset.forEach((r) => { contagemPorNome[r.CHAVE] = r.QTD; });
        } catch (err) {
          console.warn(`${log} contagem indisponível (${cfg.contagem.tabela}): ${err.message}`);
        }
      }

      res.json(
        result.recordset.map((r) => ({
          ID: r.ID,
          NM: r.NM,
          DS: colDescricao ? r.DS : null,
          URL_ICONE: temIcone ? r.URL_ICONE : null,
          ATIVO: r.SG_ATIVO === "S",
          // casa pelo nome em PT: a tabela de pendências guarda o nome
          // em português, independentemente do idioma da tela.
          QTD: contagemPorNome[r.NM_PT] != null ? contagemPorNome[r.NM_PT] : null,
          // true = pediu um idioma diferente de PT e este registro não
          // tem aquela tradução cadastrada (o NM/DS acima vêm do PT por
          // causa do COALESCE). O front-end usa isso para sinalizar o
          // card, em vez de deixar parecer, em silêncio, que o texto em
          // português É a tradução.
          SEM_TRADUCAO: r.SEM_TRADUCAO === 1,
        }))
      );
    } catch (err) {
      console.error(`${log} erro ao consultar:`, err.message);
      res.status(500).json({ error: `Erro ao consultar ${rotuloSing}: ` + err.message });
    }
  });

  // Buscar 1 registro por ID — as duas linhas (PT e EN) do mesmo ID,
  // usadas para popular o formulário de edição bilíngue.
  apiRouter.get(`/${rota}/:id`, async (req, res) => {
    try {
      const id = parseInt(req.params.id, 10);
      if (!Number.isInteger(id)) return res.status(400).json({ error: `${pk} inválido.` });

      const colsSelectId = ["ID_IDIOMA", `${colNome} AS NM`];
      if (colDescricao) colsSelectId.push(`${colDescricao} AS DS`);
      if (extraEditavel) colsSelectId.push(`${extraEditavel.col} AS EXTRA`);
      const result = await runQuery(
        `SELECT ${colsSelectId.join(", ")} FROM ${tabela} WHERE ${pk} = @id`,
        [["id", sql.Int, id]]
      );

      const pt = result.recordset.find((r) => r.ID_IDIOMA === ID_IDIOMA_PT);
      const en = result.recordset.find((r) => r.ID_IDIOMA === ID_IDIOMA_EN);
      if (!pt && !en) return res.status(404).json({ error: `Registro de ${rotuloSing} não encontrado.` });

      res.json({
        ID: id,
        pt: pt ? { NM: pt.NM, DS: colDescricao ? pt.DS : "" } : null,
        en: en ? { NM: en.NM, DS: colDescricao ? en.DS : "" } : null,
        // Mesmo valor nos 2 idiomas (não é um dado bilíngue) — pega de
        // qualquer linha que exista.
        ...(extraEditavel ? { [extraEditavel.campo]: (pt && pt.EXTRA) ?? (en && en.EXTRA) ?? null } : {}),
      });
    } catch (err) {
      console.error(`${log} erro ao consultar por ID:`, err.message);
      res.status(500).json({ error: `Erro ao consultar ${rotuloSing}: ` + err.message });
    }
  });

  // Editar — grava as duas linhas (PT e EN) do mesmo ID. O registro
  // pode ter só a linha PT cadastrada (a EN nunca criada): por isso
  // upsert, não UPDATE puro — senão digitar a tradução pela 1ª vez não
  // gravaria nada (0 linhas afetadas, sem erro). Só mexe em registro
  // que já existe: sem NENHUMA linha com esse ID, devolve 404 —
  // criar do zero é só pelo POST.
  apiRouter.put(`/${rota}/:id`, async (req, res) => {
    try {
      const id = parseInt(req.params.id, 10);
      if (!Number.isInteger(id)) return res.status(400).json({ error: `${pk} inválido.` });

      const { nomePt, descPt, nomeEn, descEn, extra } = lerCorpo(req);
      const erro = validarCampos(nomePt, descPt, nomeEn, descEn);
      if (erro) return res.status(400).json({ error: erro });
      const erroExtra = validarExtra(extra);
      if (erroExtra) return res.status(400).json({ error: erroExtra });

      const existe = await runQuery(
        `SELECT TOP (1) 1 AS X FROM ${tabela} WHERE ${pk} = @id`,
        [["id", sql.Int, id]]
      );
      if (!existe.recordset.length) {
        return res.status(404).json({ error: `Registro de ${rotuloSing} não encontrado.` });
      }

      // Resolvido uma vez (não por idioma) e nunca a partir do corpo da
      // requisição — a interface não tem (nem pode ter) campo para isso.
      const idUsuario = capturarUsuario ? await idUsuarioLogado(req) : null;

      await Promise.all([
        upsertIdioma(id, ID_IDIOMA_PT, nomePt, descPt, idUsuario, extra),
        upsertIdioma(id, ID_IDIOMA_EN, nomeEn, descEn, idUsuario, extra),
      ]);
      res.json({ ok: true });
    } catch (err) {
      console.error(`${log} erro ao atualizar:`, err.message);
      const amigavel = mensagemErroSql(err, rotuloSing, extraEditavel && (extraEditavel.rotulo || extraEditavel.col));
      res.status(amigavel ? 409 : 500).json({ error: amigavel || `Erro ao atualizar ${rotuloSing}: ` + err.message });
    }
  });

  // Criar — MESMA validação e MESMO upsert do editar; a única
  // diferença é que o ID é novo (próximo disponível), então as 2
  // chamadas caem sempre no ramo INSERT do MERGE.
  // Sem transação explícita: numa falha a meio caminho (EN falha
  // depois do PT gravado), o registro fica só com a linha PT — mesma
  // situação que o upsert do editar já resolve numa edição seguinte.
  apiRouter.post(`/${rota}`, async (req, res) => {
    try {
      const { nomePt, descPt, nomeEn, descEn, extra } = lerCorpo(req);
      const erro = validarCampos(nomePt, descPt, nomeEn, descEn);
      if (erro) return res.status(400).json({ error: erro });
      const erroExtra = validarExtra(extra);
      if (erroExtra) return res.status(400).json({ error: erroExtra });

      const proximo = await runQuery(`SELECT ISNULL(MAX(${pk}), 0) + 1 AS PROXIMO FROM ${tabela}`);
      const id = proximo.recordset[0].PROXIMO;

      const idUsuario = capturarUsuario ? await idUsuarioLogado(req) : null;

      await Promise.all([
        upsertIdioma(id, ID_IDIOMA_PT, nomePt, descPt, idUsuario, extra),
        upsertIdioma(id, ID_IDIOMA_EN, nomeEn, descEn, idUsuario, extra),
      ]);
      res.status(201).json({ ok: true, ID: id });
    } catch (err) {
      console.error(`${log} erro ao criar:`, err.message);
      const amigavel = mensagemErroSql(err, rotuloSing, extraEditavel && (extraEditavel.rotulo || extraEditavel.col));
      res.status(amigavel ? 409 : 500).json({ error: amigavel || `Erro ao criar ${rotuloSing}: ` + err.message });
    }
  });

  // Ativar/desativar — grava SG_ATIVO ('S'/'N') nas linhas de TODOS os
  // idiomas desse ID (o status é do registro, não de uma tradução).
  apiRouter.put(`/${rota}/:id/status`, async (req, res) => {
    try {
      const id = parseInt(req.params.id, 10);
      if (!Number.isInteger(id)) return res.status(400).json({ error: `${pk} inválido.` });
      if (typeof req.body?.ativo !== "boolean") {
        return res.status(400).json({ error: "Campo 'ativo' (true/false) é obrigatório." });
      }

      const result = await runQuery(
        `UPDATE ${tabela} SET SG_ATIVO = @sgAtivo, DT_ATUALIZACAO = GETDATE() WHERE ${pk} = @id`,
        [
          ["sgAtivo", sql.Char(1), req.body.ativo ? "S" : "N"],
          ["id", sql.Int, id],
        ]
      );
      if (!result.rowsAffected[0]) {
        return res.status(404).json({ error: `Registro de ${rotuloSing} não encontrado.` });
      }
      res.json({ ok: true, ativo: req.body.ativo });
    } catch (err) {
      console.error(`${log} erro ao atualizar status:`, err.message);
      res.status(500).json({ error: `Erro ao atualizar status de ${rotuloSing}: ` + err.message });
    }
  });
}

registrarCadastroBilingue({
  rota: "categorias",
  tabela: FULL_CATEGORIA_TABLE,
  pk: "ID_CATEGORIA",
  colNome: "NM_CATEGORIA",
  colDescricao: "DS_CATEGORIA",
  // Mesmo tamanho do DER que as outras 3 tabelas bilíngues (não é
  // mais exceção — ver nota em CADASTRO_LIMITES_DER acima).
  maxNome: CADASTRO_LIMITES_DER.nome,
  maxDescricao: CADASTRO_LIMITES_DER.descricao,
  rotuloSing: "categoria",
  contagem: { tabela: FULL_PENDENCIA_TABLE, coluna: "NM_CATEGORIA" },
  // ID_USUARIO: coluna nova em kzn_categoria (a ser adicionada ao banco
  // — ainda não existe no DER atual; só ID_USUARIO + DT_ATUALIZACAO,
  // sem distinguir criação de edição). Gravada automaticamente a
  // partir do usuário logado (ver idUsuarioLogado() acima); a interface
  // não expõe nem permite editar esse campo. Só Categorias tem essa
  // auditoria por enquanto — capturarUsuarioResponsavel é opt-in por
  // tabela, então as outras 5 abas bilíngues continuam exatamente como
  // estavam.
  capturarUsuarioResponsavel: true,
});

registrarCadastroBilingue({
  rota: "replicacoes",
  tabela: tabelaCadastro("AZURE_SQL_REPLICACAO_TABLE", "kzn_replicacao"),
  pk: "ID_REPLICACAO",
  colNome: "NM_REPLICACAO",
  colDescricao: "DS_REPLICACAO",
  maxNome: CADASTRO_LIMITES_DER.nome,
  maxDescricao: CADASTRO_LIMITES_DER.descricao,
  rotuloSing: "potencial de replicação",
  // ID_USUARIO (DER atualizado): mesmo padrão de Categoria — grava
  // automaticamente quem criou/editou, via idUsuarioLogado(); interface
  // não expõe nem permite editar esse campo.
  capturarUsuarioResponsavel: true,
});

registrarCadastroBilingue({
  rota: "desperdicios",
  tabela: tabelaCadastro("AZURE_SQL_DESPERDICIO_TABLE", "kzn_desperdicio"),
  pk: "ID_DESPERDICIO",
  colNome: "NM_DESPERDICIO",
  colDescricao: "DS_DESPERDICIO",
  maxNome: CADASTRO_LIMITES_DER.nome,
  maxDescricao: CADASTRO_LIMITES_DER.descricao,
  rotuloSing: "tipo de desperdício",
  // js/desperdicios.js já usa palavraBadge:"usos" (mesmo padrão do
  // badge "kaizens" de Categoria), mas faltava esta config no servidor
  // — sem ela, QTD vinha sempre null e o badge só mostrava "—". Mesma
  // tabela/abordagem de Categoria (contagem falha em silêncio se a
  // tabela/coluna não existir, sem derrubar a lista — ver nota de
  // ressalva sobre esta tabela no relatório desta tarefa).
  contagem: { tabela: FULL_PENDENCIA_TABLE, coluna: "NM_DESPERDICIO" },
  // ID_USUARIO (DER atualizado): mesmo padrão de Categoria/Replicação —
  // grava automaticamente quem criou/editou.
  capturarUsuarioResponsavel: true,
});

registrarCadastroBilingue({
  rota: "resultados",
  tabela: tabelaCadastro("AZURE_SQL_RESULTADO_TABLE", "kzn_resultados"),
  pk: "ID_RESULTADO",
  colNome: "NM_RESULTADO",
  colDescricao: "DS_RESULTADO",
  maxNome: CADASTRO_LIMITES_DER.nome,
  maxDescricao: CADASTRO_LIMITES_DER.descricao,
  rotuloSing: "tipo de resultado",
  // ID_TIPO_RESULTADO: FK própria desta tabela, agora escolhida pelo
  // usuário num combo (por nome, kzn_tipo_resultado/aba "Tipo
  // Resultados"), gravado como ID — ver campoExtraEditavel.
  // obrigatorio:true — a coluna real é NOT NULL (confirmado em produção:
  // "Cannot insert the value NULL into column 'ID_TIPO_RESULTADO'...").
  campoExtraEditavel: { col: "ID_TIPO_RESULTADO", campo: "idTipoResultado", obrigatorio: true, rotulo: "Tipo de Resultado" },
  // ID_USUARIO: mesmo padrão das demais abas — grava automaticamente
  // quem criou/editou.
  capturarUsuarioResponsavel: true,
});

// kzn_tipo_resultado (DER atualizado): ID_TIPO_RESULTADO, ID_IDIOMA,
// NM_TIPO_RESULTADO, SG_ATIVO, ID_USUARIO, DT_ATUALIZACAO — SEM
// URL_ICONE e SEM DS_* (só nome).
registrarCadastroBilingue({
  rota: "tiporesultados",
  tabela: tabelaCadastro("AZURE_SQL_TIPO_RESULTADO_TABLE", "kzn_tipo_resultado"),
  pk: "ID_TIPO_RESULTADO",
  colNome: "NM_TIPO_RESULTADO",
  maxNome: CADASTRO_LIMITES_DER.nome,
  temIcone: false,
  rotuloSing: "tipo de resultado (classificação)",
  // ID_USUARIO: mesmo padrão de Categoria/Replicação/Desperdícios —
  // grava automaticamente quem criou/editou.
  capturarUsuarioResponsavel: true,
});

// kzn_motivo_reprovacao (DER atualizado): ID_MOTIVO, ID_IDIOMA,
// NM_MOTIVO VARCHAR(30), DS_MOTIVO VARCHAR(100), SG_ATIVO, ID_USUARIO,
// DT_ATUALIZACAO — mesmos limites de nome/descrição das outras tabelas
// bilíngues, mas SEM URL_ICONE.
registrarCadastroBilingue({
  rota: "motivosreprovacao",
  tabela: tabelaCadastro("AZURE_SQL_MOTIVO_REPROVACAO_TABLE", "kzn_motivo_reprovacao"),
  pk: "ID_MOTIVO",
  colNome: "NM_MOTIVO",
  colDescricao: "DS_MOTIVO",
  maxNome: CADASTRO_LIMITES_DER.nome,
  maxDescricao: CADASTRO_LIMITES_DER.descricao,
  temIcone: false,
  rotuloSing: "motivo de reprovação",
  // ID_USUARIO: mesmo padrão das demais abas — grava automaticamente
  // quem criou/editou.
  capturarUsuarioResponsavel: true,
});

// ------------------------------------------------------------------
// kzn_moeda — não é bilíngue (sem ID_IDIOMA), então não usa
// registrarCadastroBilingue(). Só leitura por enquanto: a tela de Novo
// Kaizen só CONSOME esta lista (combo "Moeda" da Etapa 4); cadastrar
// moeda continua sendo feito direto no banco até existir uma aba
// própria no admin.
// ------------------------------------------------------------------
apiRouter.get("/moedas", async (req, res) => {
  try {
    const result = await runQuery(
      `SELECT ID_MOEDA, NM_MOEDA, SG_MOEDA, NM_PAIS, SG_ATIVO
       FROM ${FULL_MOEDA_TABLE}
       ORDER BY NM_MOEDA`
    );
    res.json(
      result.recordset.map((r) => ({
        ID: r.ID_MOEDA,
        NM: r.NM_MOEDA,
        SG: r.SG_MOEDA,
        PAIS: r.NM_PAIS,
        ATIVO: r.SG_ATIVO === "S",
      }))
    );
  } catch (err) {
    console.error("[moedas] erro ao listar:", err.message);
    res.status(500).json({ error: "Erro ao consultar moedas: " + err.message });
  }
});

// ------------------------------------------------------------------
// Novo Kaizen (kaizen-novo.html) — imagens (Antes/Depois) + criação
// ------------------------------------------------------------------
// As imagens são gravadas em Volumes do Databricks — ver
// databricks-fs.js para a autenticação (OAuth do próprio service
// principal do Databricks App, sem token fixo em app.yaml).
//
// Caminho pedido no arquivo de especificação (Usuário - Novo Kaizen -
// Aprovação.txt):
//   Antes:  /Volumes/franquia_bmsa_insight/ci/kaizen/imgs/before/
//   Depois: /Volumes/franquia_bmsa_insight/ci/kaizen/imgs/after/
//
// O upload acontece assim que a pessoa escolhe o arquivo na Etapa 2/3
// (não espera o "Enviar para Aprovação" final) — o caminho devolvido
// fica num campo oculto (url_imagem_antes/depois) até o POST /kaizens.
// Consequência aceita: escolher uma foto e nunca terminar o formulário
// deixa um arquivo órfão no volume; tolerável para o volume de uso
// desta tela, mas fica registrado aqui caso vire problema (poda por
// idade de arquivo, por exemplo).
const IMG_MAX_BYTES = 10 * 1024 * 1024; // 10MB — mesmo limite anunciado no formulário
const IMG_MIME_AUTORIZADOS = new Set(["image/png", "image/jpeg", "image/webp"]);
const IMG_EXT_POR_MIME = { "image/png": ".png", "image/jpeg": ".jpg", "image/webp": ".webp" };

const upload = multer({
  storage: multer.memoryStorage(),
  limits: { fileSize: IMG_MAX_BYTES },
});

// multer.single() como middleware direto devolveria um erro cru (HTML,
// não JSON) quando o arquivo estoura o limite — envolvemos manualmente
// para sempre responder no mesmo formato { error } do resto da API.
function receberImagemUnica(req, res, next) {
  upload.single("imagem")(req, res, (err) => {
    if (!err) return next();
    if (err.code === "LIMIT_FILE_SIZE") {
      return res.status(400).json({ error: "Arquivo maior que 10MB." });
    }
    return res.status(400).json({ error: "Erro no upload: " + err.message });
  });
}

const VOLUME_BASE_IMGS = "/Volumes/franquia_bmsa_insight/ci/kaizen/imgs";
const PASTA_POR_TIPO_IMG = { antes: "before", depois: "after" };

// Nome gerado no servidor (nunca o nome original do arquivo): evita
// colisão entre pessoas diferentes enviando "foto.jpg" ao mesmo tempo e
// evita qualquer caractere problemático vindo do sistema de arquivos de
// quem enviou.
function nomeArquivoImagem(mimetype) {
  const ext = IMG_EXT_POR_MIME[mimetype] || ".jpg";
  return Date.now() + "_" + Math.random().toString(36).slice(2, 10) + ext;
}

// GET /kaizens/imagem?path=... — serve de volta uma imagem já salva no
// volume (a Biblioteca usa isso no <img src>, já que o caminho do
// volume não é uma URL que o navegador acessa direto). Só aceita
// caminhos dentro de VOLUME_BASE_IMGS: não é um proxy genérico do volume.
apiRouter.get("/kaizens/imagem", async (req, res) => {
  try {
    const caminho = String(req.query.path || "");
    if (!caminho.startsWith(VOLUME_BASE_IMGS + "/")) {
      return res.status(400).json({ error: "Caminho de imagem inválido." });
    }
    const { buffer, contentType } = await baixarArquivoDoVolume(caminho);
    res.setHeader("Content-Type", contentType);
    res.setHeader("Cache-Control", "private, max-age=3600");
    res.send(buffer);
  } catch (err) {
    console.error("[kaizens/imagem GET] erro:", err.message);
    res.status(404).end();
  }
});

apiRouter.post("/kaizens/imagem", receberImagemUnica, async (req, res) => {
  try {
    const tipo = String(req.query.tipo || "").toLowerCase();
    const pasta = PASTA_POR_TIPO_IMG[tipo];
    if (!pasta) return res.status(400).json({ error: "Parâmetro 'tipo' deve ser 'antes' ou 'depois'." });
    if (!req.file) return res.status(400).json({ error: "Nenhum arquivo enviado (campo 'imagem')." });
    if (!IMG_MIME_AUTORIZADOS.has(req.file.mimetype)) {
      return res.status(400).json({ error: "Formato não suportado. Envie PNG, JPG ou WEBP." });
    }

    const caminhoVolume = `${VOLUME_BASE_IMGS}/${pasta}/${nomeArquivoImagem(req.file.mimetype)}`;
    await enviarArquivoParaVolume(caminhoVolume, req.file.buffer, req.file.mimetype);

    res.json({ ok: true, url: caminhoVolume });
  } catch (err) {
    console.error("[kaizens/imagem] erro ao enviar imagem:", err.message);
    res.status(500).json({ error: "Erro ao enviar a imagem: " + err.message });
  }
});

// Convenção de SG_STATUS em kzn_pedravisaoconsolidada. Valores aceitos
// pelo CHECK CK_KZN_PVC_STATUS no banco: ABERTO, EM_APROVACAO,
// APROVADO, REPROVADO, CONCLUIDO. Ainda não existe backend para a tela
// de aprovação (ver o próprio arquivo de especificação: "isso de
// aprovar vamos ver em outra tela") — mantenha em sincronia com aquela
// tela quando ela existir.
const STATUS_AGUARDANDO_APROVACAO = "EM_APROVACAO";
const STATUS_APROVADO = "APROVADO";
const STATUS_CANCELADO = "REPROVADO";

// Limites de texto — vêm do DER (database/DER_VBM_Kaizen.html /
// e_PVC). NM_KAIZEN é VARCHAR(30): o mesmo limite curto das tabelas de
// cadastro, não os 100 caracteres que o helper da tela antiga sugeria.
const PVC_LIMITES = {
  NM_KAIZEN: 30,
  DS_PROBLEMA: 100,
  DS_OBJETIVO: 100,
  DS_ESTADO_ANTES: 100,
  DS_ESTADO_DEPOIS: 100,
  URL_REFERENCIA: 200,
  DS_LICOES_APRENDIDAS: 100,
  DS_RESULTADO_ESPERADO: 100,
  URL_IMG: 200,
};

apiRouter.post("/kaizens", async (req, res) => {
  const b = req.body || {};

  const obrigatorio = (valor, rotulo) =>
    valor == null || String(valor).trim() === "" ? `${rotulo} é obrigatório.` : null;
  const maxLen = (valor, max, rotulo) =>
    valor != null && String(valor).length > max ? `${rotulo} deve ter no máximo ${max} caracteres.` : null;
  const textoOuNuloLocal = (valor) => {
    if (valor == null) return null;
    const limpo = String(valor).trim();
    return limpo === "" ? null : limpo;
  };
  const intOuNulo = (valor) => (valor === "" || valor == null ? null : parseInt(valor, 10));

  const titulo = String(b.titulo || "").trim();
  const declaracaoProblema = String(b.declaracao_problema || "").trim();
  const metaObjetivo = String(b.meta_objetivo || "").trim();
  const descricaoAntes = String(b.descricao_antes || "").trim();
  const descricaoDepois = String(b.descricao_depois || "").trim();
  const idCategoria = intOuNulo(b.id_categoria);
  const idReplicacao = intOuNulo(b.id_replicacao);
  const idUsuarioAprovador = intOuNulo(b.id_usuario_aprovador);
  const idUsuarioLider = intOuNulo(b.id_usuario_lider); // opcional: sem escolha, usa quem está logado
  // Desperdícios: seleção múltipla agora (ver FULL_KZ_DESPERDICIO_TABLE
  // acima) — PVC.ID_DESPERDICIO fica sempre NULL, a lista de verdade
  // vai pra kzn_kaizen_desperdicio.
  const idsDesperdicio = Array.isArray(b.ids_desperdicio)
    ? [...new Set(b.ids_desperdicio.map((v) => parseInt(v, 10)).filter((n) => Number.isInteger(n)))]
    : [];
  const urlImgAntes = textoOuNuloLocal(b.url_imagem_antes);
  const urlImgDepois = textoOuNuloLocal(b.url_imagem_depois);
  const urlReferencia = textoOuNuloLocal(b.links_documentos);
  const licoesAprendidas = textoOuNuloLocal(b.licoes_aprendidas);
  const comparacaoMeta = textoOuNuloLocal(b.comparacao_meta_inicial);

  // "Tipo de Resultado Financeiro" (Saving/Cost Avoided) continua só na
  // tela — não há coluna no DER para essa classificação. Moeda e Valor
  // são gravados normalmente quando o bloco "Resultado Financeiro" está
  // ativo.
  const geraResultadoFinanceiro = b.fl_resultado_financeiro === true || b.fl_resultado_financeiro === "true";
  const idMoeda = geraResultadoFinanceiro ? intOuNulo(b.id_moeda) : null;
  const valorResultadoFinanceiro =
    geraResultadoFinanceiro && b.valor_resultado_financeiro !== "" && b.valor_resultado_financeiro != null
      ? Number(b.valor_resultado_financeiro)
      : null;

  // "Outros resultados": vira 1 item novo em kzn_resultados (nos 2
  // idiomas, mesmo texto — não há como auto-traduzir descrição livre) +
  // 1 linha em kzn_resultado_kaizen ligando ao Kaizen. Ver bloco de
  // inserção mais abaixo.
  const geraResultadoOutros = b.fl_resultado_outros === true || b.fl_resultado_outros === "true";
  const idTipoResultadoOutros = geraResultadoOutros ? intOuNulo(b.id_tipo_resultado_outros) : null;
  const descricaoResultadoOutros = geraResultadoOutros ? textoOuNuloLocal(b.descricao_resultado_outros) : null;

  // Membros da equipe (Vale + externos): ambos são só um ID_USUARIO do
  // MDM — ver nota em FULL_MEMBROS_TABLE acima. Dedupe por segurança
  // (mesma pessoa marcada duas vezes não deve virar 2 linhas na
  // junção, que tem PK composta ID_KAIZEN+ID_USUARIO).
  const membros = Array.isArray(b.membros)
    ? [...new Set(b.membros.map((v) => parseInt(v, 10)).filter((n) => Number.isInteger(n)))]
    : [];

  const erros = [
    obrigatorio(titulo, "Título do Kaizen"),
    maxLen(titulo, PVC_LIMITES.NM_KAIZEN, "Título do Kaizen"),
    obrigatorio(declaracaoProblema, "Descrição do Problema"),
    maxLen(declaracaoProblema, PVC_LIMITES.DS_PROBLEMA, "Descrição do Problema"),
    obrigatorio(metaObjetivo, "Meta / Objetivo"),
    maxLen(metaObjetivo, PVC_LIMITES.DS_OBJETIVO, "Meta / Objetivo"),
    obrigatorio(descricaoAntes, "Descrição do Antes"),
    maxLen(descricaoAntes, PVC_LIMITES.DS_ESTADO_ANTES, "Descrição do Antes"),
    obrigatorio(descricaoDepois, "Descrição do Depois"),
    maxLen(descricaoDepois, PVC_LIMITES.DS_ESTADO_DEPOIS, "Descrição do Depois"),
    Number.isInteger(idCategoria) ? null : "Categoria é obrigatória.",
    Number.isInteger(idUsuarioAprovador) ? null : "Aprovador é obrigatório.",
    maxLen(urlReferencia, PVC_LIMITES.URL_REFERENCIA, "Links / Documentos"),
    maxLen(licoesAprendidas, PVC_LIMITES.DS_LICOES_APRENDIDAS, "Lições Aprendidas"),
    maxLen(comparacaoMeta, PVC_LIMITES.DS_RESULTADO_ESPERADO, "Comparação com a meta inicial"),
    geraResultadoOutros && !Number.isInteger(idTipoResultadoOutros) ? "Tipo de Resultado (Outros) é obrigatório quando o bloco está ativo." : null,
    geraResultadoOutros && !descricaoResultadoOutros ? "Descrição dos Resultados Alcançados é obrigatória quando \"Outros\" está ativo." : null,
    maxLen(descricaoResultadoOutros, 100, "Descrição dos Resultados Alcançados"),
  ].filter(Boolean);
  if (erros.length) return res.status(400).json({ error: erros[0], erros });

  try {
    // Quem está criando, sempre pelo servidor (X-Forwarded-Email) —
    // nunca aceito do corpo da requisição (ver idUsuarioLogado acima).
    const idUsuarioCadastro = await idUsuarioLogado(req);
    const idLider = idUsuarioLider || idUsuarioCadastro;
    if (!idLider) {
      return res.status(400).json({
        error: "Não foi possível identificar o líder do projeto (nem escolhido na busca, nem o usuário logado).",
      });
    }

    const idAprovador = await idAprovadorPorUsuario(idUsuarioAprovador);
    if (idAprovador == null) {
      return res.status(400).json({ error: "O usuário escolhido como aprovador não está ativo em kzn_aprovador." });
    }

    const pool = await getPool();
    const tx = new sql.Transaction(pool);
    await tx.begin();
    try {
      // ID_KAIZEN não é identity (mesmo padrão das outras tabelas deste
      // banco — ver ISNULL(MAX(pk),0)+1 em registrarCadastroBilingue).
      // Dentro da transação para não colidir com outro POST simultâneo.
      const proximo = await new sql.Request(tx).query(
        `SELECT ISNULL(MAX(ID_KAIZEN), 0) + 1 AS PROXIMO FROM ${FULL_PVC_TABLE}`
      );
      const idKaizen = proximo.recordset[0].PROXIMO;

      const reqInsert = new sql.Request(tx);
      reqInsert.input("idKaizen", sql.Int, idKaizen);
      reqInsert.input("idUsuarioCadastro", sql.Int, idUsuarioCadastro ?? null);
      reqInsert.input("idUsuarioLider", sql.Int, idLider);
      reqInsert.input("nmKaizen", sql.NVarChar(PVC_LIMITES.NM_KAIZEN), titulo);
      reqInsert.input("idCategoria", sql.Int, idCategoria);
      reqInsert.input("idReplicacao", sql.Int, idReplicacao);
      reqInsert.input("dsProblema", sql.NVarChar(PVC_LIMITES.DS_PROBLEMA), declaracaoProblema);
      reqInsert.input("dsObjetivo", sql.NVarChar(PVC_LIMITES.DS_OBJETIVO), metaObjetivo);
      reqInsert.input("sgStatus", sql.NVarChar(30), STATUS_AGUARDANDO_APROVACAO);
      reqInsert.input("idAprovador", sql.Int, idAprovador);
      reqInsert.input("urlImgAntes", sql.NVarChar(PVC_LIMITES.URL_IMG), urlImgAntes);
      reqInsert.input("dsEstadoAntes", sql.NVarChar(PVC_LIMITES.DS_ESTADO_ANTES), descricaoAntes);
      reqInsert.input("urlImgDepois", sql.NVarChar(PVC_LIMITES.URL_IMG), urlImgDepois);
      reqInsert.input("dsEstadoDepois", sql.NVarChar(PVC_LIMITES.DS_ESTADO_DEPOIS), descricaoDepois);
      reqInsert.input("urlReferencia", sql.NVarChar(PVC_LIMITES.URL_REFERENCIA), urlReferencia);
      reqInsert.input("idDesperdicio", sql.Int, null);
      reqInsert.input("dsLicoes", sql.NVarChar(PVC_LIMITES.DS_LICOES_APRENDIDAS), licoesAprendidas);
      reqInsert.input("vlResultado", sql.Decimal(18, 2), valorResultadoFinanceiro);
      reqInsert.input("idMoeda", sql.Int, idMoeda);
      reqInsert.input("dsResultadoEsperado", sql.NVarChar(PVC_LIMITES.DS_RESULTADO_ESPERADO), comparacaoMeta);

      await reqInsert.query(`
        INSERT INTO ${FULL_PVC_TABLE}
          (ID_KAIZEN, ID_USUARIO_CADASTRO, ID_USUARIO_LIDER, NM_KAIZEN, ID_CATEGORIA, ID_REPLICACAO,
           DS_PROBLEMA, DS_OBJETIVO, SG_STATUS, ID_APROVADOR, URL_IMG_ANTES, DS_ESTADO_ANTES,
           URL_IMG_DEPOIS, DS_ESTADO_DEPOIS, URL_REFERENCIA, ID_DESPERDICIO, DS_LICOES_APRENDIDAS,
           VL_RESULTADO_FINANCEIRO, ID_MOEDA, DS_RESULTADO_ESPERADO, DT_CRIACAO, DT_ATUALIZACAO,
           ID_USUARIO_ATUALIZACAO)
        VALUES
          (@idKaizen, @idUsuarioCadastro, @idUsuarioLider, @nmKaizen, @idCategoria, @idReplicacao,
           @dsProblema, @dsObjetivo, @sgStatus, @idAprovador, @urlImgAntes, @dsEstadoAntes,
           @urlImgDepois, @dsEstadoDepois, @urlReferencia, @idDesperdicio, @dsLicoes,
           @vlResultado, @idMoeda, @dsResultadoEsperado, GETDATE(), GETDATE(),
           @idUsuarioCadastro)`);

      for (const idMembro of membros) {
        const reqM = new sql.Request(tx);
        reqM.input("idKaizen", sql.Int, idKaizen);
        reqM.input("idUsuario", sql.Int, idMembro);
        await reqM.query(
          `INSERT INTO ${FULL_MEMBROS_TABLE} (ID_KAIZEN, ID_USUARIO, DT_ATUALIZACAO)
           VALUES (@idKaizen, @idUsuario, GETDATE())`
        );
      }

      for (const idDesp of idsDesperdicio) {
        const reqD = new sql.Request(tx);
        reqD.input("idKaizen", sql.Int, idKaizen);
        reqD.input("idDesperdicio", sql.Int, idDesp);
        await reqD.query(
          `INSERT INTO ${FULL_KZ_DESPERDICIO_TABLE} (ID_KAIZEN, ID_DESPERDICIO, DT_ATUALIZACAO)
           VALUES (@idKaizen, @idDesperdicio, GETDATE())`
        );
      }

      if (geraResultadoOutros) {
        // NM_RESULTADO é VARCHAR(30): sem campo de título próprio na
        // tela, usa a própria descrição truncada como nome.
        const nmResultado = descricaoResultadoOutros.slice(0, 30);
        const proximoResultado = await new sql.Request(tx).query(
          `SELECT ISNULL(MAX(ID_RESULTADO), 0) + 1 AS PROXIMO FROM ${FULL_RESULTADOS_TABLE}`
        );
        const idResultado = proximoResultado.recordset[0].PROXIMO;

        for (const idIdioma of [1, 2]) {
          const reqR = new sql.Request(tx);
          reqR.input("idResultado", sql.Int, idResultado);
          reqR.input("idIdioma", sql.Int, idIdioma);
          reqR.input("idTipoResultado", sql.Int, idTipoResultadoOutros);
          reqR.input("nmResultado", sql.NVarChar(30), nmResultado);
          reqR.input("dsResultado", sql.NVarChar(100), descricaoResultadoOutros);
          reqR.input("idUsuario", sql.Int, idUsuarioCadastro ?? null);
          await reqR.query(`
            INSERT INTO ${FULL_RESULTADOS_TABLE}
              (ID_RESULTADO, ID_IDIOMA, ID_TIPO_RESULTADO, NM_RESULTADO, DS_RESULTADO, SG_ATIVO, ID_USUARIO, DT_ATUALIZACAO)
            VALUES
              (@idResultado, @idIdioma, @idTipoResultado, @nmResultado, @dsResultado, 'S', @idUsuario, GETDATE())`);
        }

        const reqRK = new sql.Request(tx);
        reqRK.input("idKaizen", sql.Int, idKaizen);
        reqRK.input("idResultado", sql.Int, idResultado);
        await reqRK.query(
          `INSERT INTO ${FULL_RESULTADO_KAIZEN_TABLE} (ID_KAIZEN, ID_RESULTADO, DT_ATUALIZACAO)
           VALUES (@idKaizen, @idResultado, GETDATE())`
        );
      }

      await tx.commit();
      res.status(201).json({ ok: true, ID_KAIZEN: idKaizen, SG_STATUS: STATUS_AGUARDANDO_APROVACAO });
    } catch (errTx) {
      await tx.rollback().catch(() => {});
      throw errTx;
    }
  } catch (err) {
    console.error("[kaizens] erro ao criar:", err.message);
    // A mensagem "não está cadastrado nos dois idiomas" é dos cadastros
    // bilíngues (FK composta id+idioma) — não se aplica aqui, as FKs de
    // kzn_pedravisaoconsolidada são de coluna única. Em erro de FK (547),
    // mostra o texto cru do SQL Server: ele já cita o nome da constraint,
    // então dá pra saber exatamente qual campo (categoria, aprovador,
    // moeda, líder...) tem o ID inválido.
    res.status(err.number === 547 ? 409 : 500).json({ error: "Erro ao criar o Kaizen: " + err.message });
  }
});

// ------------------------------------------------------------------
// Biblioteca (biblioteca.html) — lista/detalhe/resumo de Kaizens já
// gravados. Antes era tudo mock estático no HTML; agora lê direto de
// kzn_pedravisaoconsolidada + as tabelas relacionadas.
// ------------------------------------------------------------------

// Monta o rótulo curto de ID mostrado nos cards: "KZN26-041" (2 últimos
// dígitos do ano de criação + ID_KAIZEN com 3 dígitos). Não existe
// coluna própria pra isso no DER — é só formatação de exibição.
function rotuloIdKaizen(idKaizen, dtCriacao) {
  const ano = dtCriacao ? new Date(dtCriacao).getFullYear() : new Date().getFullYear();
  return `KZN${String(ano).slice(-2)}-${String(idKaizen).padStart(3, "0")}`;
}

// GET /kaizens — lista pra grade/tabela da Biblioteca. Filtros por
// querystring, todos opcionais: status (default APROVADO), categoria
// (ID_CATEGORIA), estado (NM_ESTADO do líder, usado como "unidade" na
// tela), ano, q (busca por título/líder/ID).
apiRouter.get("/kaizens", async (req, res) => {
  try {
    const idIdioma = idIdiomaDaRequisicao(req);
    const status = String(req.query.status || "APROVADO").toUpperCase();
    const idCategoria = intOuNuloGlobal(req.query.categoria);
    const estado = textoOuNuloGlobal(req.query.estado);
    const ano = intOuNuloGlobal(req.query.ano);
    const q = textoOuNuloGlobal(req.query.q);

    const params = [
      ["idIdioma", sql.Int, idIdioma],
      ["status", sql.NVarChar(30), status],
    ];
    const filtros = ["p.SG_STATUS = @status"];
    if (idCategoria != null) { filtros.push("p.ID_CATEGORIA = @idCategoria"); params.push(["idCategoria", sql.Int, idCategoria]); }
    if (estado) { filtros.push("lider.NM_ESTADO = @estado"); params.push(["estado", sql.NVarChar(100), estado]); }
    if (ano != null) { filtros.push("YEAR(ISNULL(p.DT_CONCLUSAO, p.DT_CRIACAO)) = @ano"); params.push(["ano", sql.Int, ano]); }
    if (q) {
      filtros.push("(p.NM_KAIZEN LIKE @q OR lider.NM_USUARIO LIKE @q OR CAST(p.ID_KAIZEN AS VARCHAR(20)) LIKE @q)");
      params.push(["q", sql.NVarChar(255), termoContem(q)]);
    }

    const result = await runQuery(
      `SELECT p.ID_KAIZEN, p.NM_KAIZEN, p.SG_STATUS, p.DT_CRIACAO, p.DT_CONCLUSAO,
              cat.NM_CATEGORIA,
              lider.NM_USUARIO AS NM_LIDER, lider.NM_ESTADO, lider.NM_CIDADE,
              p.URL_IMG_ANTES, p.URL_IMG_DEPOIS,
              (SELECT TOP (1) d.NM_DESPERDICIO
                 FROM ${FULL_KZ_DESPERDICIO_TABLE} kd
                 JOIN ${FULL_DESPERDICIO_TABLE} d ON d.ID_DESPERDICIO = kd.ID_DESPERDICIO AND d.ID_IDIOMA = @idIdioma
                WHERE kd.ID_KAIZEN = p.ID_KAIZEN) AS NM_DESPERDICIO_1
       FROM ${FULL_PVC_TABLE} p
       LEFT JOIN ${FULL_CATEGORIA_TABLE} cat ON cat.ID_CATEGORIA = p.ID_CATEGORIA AND cat.ID_IDIOMA = @idIdioma
       LEFT JOIN ${FULL_MDM_TABLE} lider ON lider.ID_USUARIO = p.ID_USUARIO_LIDER
       WHERE ${filtros.join(" AND ")}
       ORDER BY ISNULL(p.DT_CONCLUSAO, p.DT_CRIACAO) DESC`,
      params
    );

    res.json(
      result.recordset.map((r) => ({
        ID_KAIZEN: r.ID_KAIZEN,
        ROTULO: rotuloIdKaizen(r.ID_KAIZEN, r.DT_CRIACAO),
        NM_KAIZEN: r.NM_KAIZEN,
        SG_STATUS: r.SG_STATUS,
        DT_CRIACAO: r.DT_CRIACAO,
        DT_CONCLUSAO: r.DT_CONCLUSAO,
        NM_CATEGORIA: r.NM_CATEGORIA,
        NM_LIDER: r.NM_LIDER,
        NM_ESTADO: r.NM_ESTADO,
        NM_CIDADE: r.NM_CIDADE,
        URL_IMG_ANTES: r.URL_IMG_ANTES,
        URL_IMG_DEPOIS: r.URL_IMG_DEPOIS,
        TAGS: [r.NM_CATEGORIA, r.NM_DESPERDICIO_1].filter(Boolean),
      }))
    );
  } catch (err) {
    console.error("[kaizens] erro ao listar:", err.message);
    res.status(500).json({ error: "Erro ao consultar Kaizens: " + err.message });
  }
});

// GET /kaizens/resumo — contadores do painel "Resumo da Biblioteca"
// (hero da tela): total por ano de criação + total por status.
apiRouter.get("/kaizens/resumo", async (req, res) => {
  try {
    const porAno = await runQuery(
      `SELECT YEAR(DT_CRIACAO) AS ANO, COUNT(*) AS QTD FROM ${FULL_PVC_TABLE} GROUP BY YEAR(DT_CRIACAO)`
    );
    const porStatus = await runQuery(
      `SELECT SG_STATUS, COUNT(*) AS QTD FROM ${FULL_PVC_TABLE} GROUP BY SG_STATUS`
    );
    res.json({
      porAno: Object.fromEntries(porAno.recordset.map((r) => [r.ANO, r.QTD])),
      porStatus: Object.fromEntries(porStatus.recordset.map((r) => [r.SG_STATUS, r.QTD])),
    });
  } catch (err) {
    console.error("[kaizens/resumo] erro:", err.message);
    res.status(500).json({ error: "Erro ao consultar resumo: " + err.message });
  }
});

// GET /kaizens/titulo-existe?titulo= — o título já está em uso?
//
// Usado pela Etapa 1 do Novo Kaizen antes de liberar o avanço: dois
// Kaizens com o mesmo nome são indistinguíveis na Biblioteca e na fila
// de aprovação.
//
// A comparação é a mesma dos dois lados: LTRIM/RTRIM tira espaço
// sobrando e LOWER iguala maiúsculas e minúsculas — "  Setup " e
// "setup" são o mesmo título.
//
// Registrada ANTES de /kaizens/:id, senão ":id" capturaria a rota.
apiRouter.get("/kaizens/titulo-existe", async (req, res) => {
  try {
    const titulo = String(req.query.titulo || "").trim();
    if (!titulo) return res.json({ existe: false });

    const result = await runQuery(
      `SELECT TOP (1) 1 AS X FROM ${FULL_PVC_TABLE}
        WHERE LOWER(LTRIM(RTRIM(NM_KAIZEN))) = LOWER(LTRIM(RTRIM(@titulo)))`,
      [["titulo", sql.NVarChar(PVC_LIMITES.NM_KAIZEN), titulo]]
    );
    res.json({ existe: result.recordset.length > 0 });
  } catch (err) {
    console.error("[kaizens/titulo-existe] erro:", err.message);
    res.status(500).json({ error: "Erro ao verificar o título: " + err.message });
  }
});

// GET /kaizens/:id — detalhe completo pro modal (Declaração do
// Problema, Antes/Depois, Resultados, Aprendizados). :id é ID_KAIZEN.
apiRouter.get("/kaizens/:id", async (req, res) => {
  try {
    const idKaizen = parseInt(req.params.id, 10);
    if (!Number.isInteger(idKaizen)) return res.status(400).json({ error: "ID inválido." });
    const idIdioma = idIdiomaDaRequisicao(req);

    const principal = await runQuery(
      `SELECT p.*, cat.NM_CATEGORIA, repl.NM_REPLICACAO, moeda.SG_MOEDA, moeda.NM_MOEDA,
              lider.NM_USUARIO AS NM_LIDER, lider.NM_ESTADO, lider.NM_CIDADE,
              aprov.NM_USUARIO AS NM_APROVADOR
       FROM ${FULL_PVC_TABLE} p
       LEFT JOIN ${FULL_CATEGORIA_TABLE} cat ON cat.ID_CATEGORIA = p.ID_CATEGORIA AND cat.ID_IDIOMA = @idIdioma
       LEFT JOIN ${FULL_REPLICACAO_TABLE} repl ON repl.ID_REPLICACAO = p.ID_REPLICACAO AND repl.ID_IDIOMA = @idIdioma
       LEFT JOIN ${FULL_MOEDA_TABLE} moeda ON moeda.ID_MOEDA = p.ID_MOEDA
       LEFT JOIN ${FULL_MDM_TABLE} lider ON lider.ID_USUARIO = p.ID_USUARIO_LIDER
       LEFT JOIN ${FULL_TABLE_NAME} aprovFk ON aprovFk.ID_APROVADOR = p.ID_APROVADOR
       LEFT JOIN ${FULL_MDM_TABLE} aprov ON aprov.ID_USUARIO = aprovFk.ID_USUARIO
       WHERE p.ID_KAIZEN = @idKaizen`,
      [["idKaizen", sql.Int, idKaizen], ["idIdioma", sql.Int, idIdioma]]
    );
    if (!principal.recordset.length) return res.status(404).json({ error: "Kaizen não encontrado." });
    const k = principal.recordset[0];

    const [membros, desperdicios, resultados] = await Promise.all([
      runQuery(
        `SELECT m.NM_USUARIO, m.NM_POSICAO FROM ${FULL_MEMBROS_TABLE} me
         JOIN ${FULL_MDM_TABLE} m ON m.ID_USUARIO = me.ID_USUARIO
         WHERE me.ID_KAIZEN = @idKaizen`,
        [["idKaizen", sql.Int, idKaizen]]
      ),
      runQuery(
        `SELECT d.NM_DESPERDICIO FROM ${FULL_KZ_DESPERDICIO_TABLE} kd
         JOIN ${FULL_DESPERDICIO_TABLE} d ON d.ID_DESPERDICIO = kd.ID_DESPERDICIO AND d.ID_IDIOMA = @idIdioma
         WHERE kd.ID_KAIZEN = @idKaizen`,
        [["idKaizen", sql.Int, idKaizen], ["idIdioma", sql.Int, idIdioma]]
      ),
      runQuery(
        `SELECT r.NM_RESULTADO, r.DS_RESULTADO FROM ${FULL_RESULTADO_KAIZEN_TABLE} rk
         JOIN ${FULL_RESULTADOS_TABLE} r ON r.ID_RESULTADO = rk.ID_RESULTADO AND r.ID_IDIOMA = @idIdioma
         WHERE rk.ID_KAIZEN = @idKaizen`,
        [["idKaizen", sql.Int, idKaizen], ["idIdioma", sql.Int, idIdioma]]
      ),
    ]);

    res.json({
      ID_KAIZEN: k.ID_KAIZEN,
      ROTULO: rotuloIdKaizen(k.ID_KAIZEN, k.DT_CRIACAO),
      NM_KAIZEN: k.NM_KAIZEN,
      SG_STATUS: k.SG_STATUS,
      DT_CRIACAO: k.DT_CRIACAO,
      DT_CONCLUSAO: k.DT_CONCLUSAO,
      NM_CATEGORIA: k.NM_CATEGORIA,
      NM_REPLICACAO: k.NM_REPLICACAO,
      NM_LIDER: k.NM_LIDER,
      NM_ESTADO: k.NM_ESTADO,
      NM_CIDADE: k.NM_CIDADE,
      NM_APROVADOR: k.NM_APROVADOR,
      DS_PROBLEMA: k.DS_PROBLEMA,
      DS_OBJETIVO: k.DS_OBJETIVO,
      URL_IMG_ANTES: k.URL_IMG_ANTES,
      DS_ESTADO_ANTES: k.DS_ESTADO_ANTES,
      URL_IMG_DEPOIS: k.URL_IMG_DEPOIS,
      DS_ESTADO_DEPOIS: k.DS_ESTADO_DEPOIS,
      URL_REFERENCIA: k.URL_REFERENCIA,
      DS_LICOES_APRENDIDAS: k.DS_LICOES_APRENDIDAS,
      DS_RESULTADO_ESPERADO: k.DS_RESULTADO_ESPERADO,
      VL_RESULTADO_FINANCEIRO: k.VL_RESULTADO_FINANCEIRO,
      SG_MOEDA: k.SG_MOEDA,
      NM_MOEDA: k.NM_MOEDA,
      MEMBROS: membros.recordset,
      DESPERDICIOS: desperdicios.recordset.map((r) => r.NM_DESPERDICIO),
      RESULTADOS: resultados.recordset,
    });
  } catch (err) {
    console.error("[kaizens/:id] erro:", err.message);
    res.status(500).json({ error: "Erro ao consultar o Kaizen: " + err.message });
  }
});

// ------------------------------------------------------------------
// Aprovação (aprovacao.html) — fila pessoal + aprovar/reprovar. Só
// aparece pro usuário logado se ele for o ID_APROVADOR do Kaizen (via
// kzn_aprovador.ID_USUARIO), nunca por cargo/admin geral.
// ------------------------------------------------------------------

// GET /aprovacoes — fila de pendentes (SG_STATUS=EM_APROVACAO) do
// aprovador logado.
// GET /aprovacoes/contagem — só o número, pro badge laranja do menu
// (Aprovação) em todas as telas. Ver js/vbm-app.js.
apiRouter.get("/aprovacoes/contagem", async (req, res) => {
  try {
    const idUsuario = await idUsuarioLogado(req);
    if (!idUsuario) return res.json({ qtd: 0 });
    const r = await runQuery(
      `SELECT COUNT(*) AS QTD FROM ${FULL_PVC_TABLE} p
       JOIN ${FULL_TABLE_NAME} a ON a.ID_APROVADOR = p.ID_APROVADOR AND a.ID_USUARIO = @idUsuario
       WHERE p.SG_STATUS = 'EM_APROVACAO'`,
      [["idUsuario", sql.Int, idUsuario]]
    );
    res.json({ qtd: r.recordset[0].QTD });
  } catch (err) {
    console.error("[aprovacoes/contagem] erro:", err.message);
    res.json({ qtd: 0 });
  }
});

apiRouter.get("/aprovacoes", async (req, res) => {
  try {
    const idUsuario = await idUsuarioLogado(req);
    if (!idUsuario) return res.status(401).json({ error: "Não foi possível identificar o usuário logado." });
    const idIdioma = idIdiomaDaRequisicao(req);

    const result = await runQuery(
      `SELECT p.ID_KAIZEN, p.NM_KAIZEN, p.DT_CRIACAO, cat.NM_CATEGORIA,
              lider.NM_USUARIO AS NM_LIDER, lider.NM_ESTADO, lider.NM_CIDADE
       FROM ${FULL_PVC_TABLE} p
       JOIN ${FULL_TABLE_NAME} a ON a.ID_APROVADOR = p.ID_APROVADOR AND a.ID_USUARIO = @idUsuario
       LEFT JOIN ${FULL_CATEGORIA_TABLE} cat ON cat.ID_CATEGORIA = p.ID_CATEGORIA AND cat.ID_IDIOMA = @idIdioma
       LEFT JOIN ${FULL_MDM_TABLE} lider ON lider.ID_USUARIO = p.ID_USUARIO_LIDER
       WHERE p.SG_STATUS = 'EM_APROVACAO'
       ORDER BY p.DT_CRIACAO ASC`,
      [["idUsuario", sql.Int, idUsuario], ["idIdioma", sql.Int, idIdioma]]
    );
    res.json(result.recordset.map((r) => ({
      ID_KAIZEN: r.ID_KAIZEN,
      ROTULO: rotuloIdKaizen(r.ID_KAIZEN, r.DT_CRIACAO),
      NM_KAIZEN: r.NM_KAIZEN,
      DT_CRIACAO: r.DT_CRIACAO,
      NM_CATEGORIA: r.NM_CATEGORIA,
      NM_LIDER: r.NM_LIDER,
      NM_ESTADO: r.NM_ESTADO,
      NM_CIDADE: r.NM_CIDADE,
    })));
  } catch (err) {
    console.error("[aprovacoes] erro ao listar:", err.message);
    res.status(500).json({ error: "Erro ao consultar aprovações: " + err.message });
  }
});

// Confere se o usuário logado é o ID_APROVADOR deste Kaizen. Reaproveitado
// por aprovar/reprovar — nenhum dos dois aceita "eu sou admin", só o
// aprovador designado (kzn_aprovador.ID_USUARIO), como pedido.
async function souOAprovadorDoKaizen(idKaizen, idUsuario) {
  const r = await runQuery(
    `SELECT p.ID_KAIZEN FROM ${FULL_PVC_TABLE} p
     JOIN ${FULL_TABLE_NAME} a ON a.ID_APROVADOR = p.ID_APROVADOR
     WHERE p.ID_KAIZEN = @idKaizen AND a.ID_USUARIO = @idUsuario AND p.SG_STATUS = 'EM_APROVACAO'`,
    [["idKaizen", sql.Int, idKaizen], ["idUsuario", sql.Int, idUsuario]]
  );
  return r.recordset.length > 0;
}

apiRouter.post("/kaizens/:id/aprovar", async (req, res) => {
  try {
    const idKaizen = parseInt(req.params.id, 10);
    const idUsuario = await idUsuarioLogado(req);
    if (!idUsuario) return res.status(401).json({ error: "Não foi possível identificar o usuário logado." });
    if (!(await souOAprovadorDoKaizen(idKaizen, idUsuario))) {
      return res.status(403).json({ error: "Você não é o aprovador designado deste Kaizen (ou ele já foi decidido)." });
    }
    await runQuery(
      `UPDATE ${FULL_PVC_TABLE}
       SET SG_STATUS = 'APROVADO', DT_CONCLUSAO = GETDATE(), DT_ATUALIZACAO = GETDATE(), ID_USUARIO_ATUALIZACAO = @idUsuario
       WHERE ID_KAIZEN = @idKaizen`,
      [["idKaizen", sql.Int, idKaizen], ["idUsuario", sql.Int, idUsuario]]
    );
    res.json({ ok: true });
  } catch (err) {
    console.error("[aprovar] erro:", err.message);
    res.status(500).json({ error: "Erro ao aprovar: " + err.message });
  }
});

// Reprovar: a pessoa ESCREVE o motivo (texto livre) — vira 1 linha nova
// em kzn_motivo_reprovacao (nos 2 idiomas, mesmo texto — não há como
// auto-traduzir texto livre, mesmo tratamento dado a "Outros
// resultados" no Novo Kaizen) e o ID_MOTIVO gerado é gravado em
// kzn_pedravisaoconsolidada.ID_MOTIVO, como pedido.
apiRouter.post("/kaizens/:id/reprovar", async (req, res) => {
  try {
    const idKaizen = parseInt(req.params.id, 10);
    const motivo = String((req.body && req.body.motivo) || "").trim();
    if (!motivo) return res.status(400).json({ error: "Motivo da reprovação é obrigatório." });
    if (motivo.length > 100) return res.status(400).json({ error: "Motivo deve ter no máximo 100 caracteres." });
    const idUsuario = await idUsuarioLogado(req);
    if (!idUsuario) return res.status(401).json({ error: "Não foi possível identificar o usuário logado." });
    if (!(await souOAprovadorDoKaizen(idKaizen, idUsuario))) {
      return res.status(403).json({ error: "Você não é o aprovador designado deste Kaizen (ou ele já foi decidido)." });
    }

    const pool = await getPool();
    const tx = new sql.Transaction(pool);
    await tx.begin();
    try {
      const proximo = await new sql.Request(tx).query(
        `SELECT ISNULL(MAX(ID_MOTIVO), 0) + 1 AS PROXIMO FROM ${FULL_MOTIVO_TABLE}`
      );
      const idMotivo = proximo.recordset[0].PROXIMO;
      const nmMotivo = motivo.slice(0, 30);

      for (const idIdioma of [1, 2]) {
        const reqM = new sql.Request(tx);
        reqM.input("idMotivo", sql.Int, idMotivo);
        reqM.input("idIdioma", sql.Int, idIdioma);
        reqM.input("nmMotivo", sql.NVarChar(30), nmMotivo);
        reqM.input("dsMotivo", sql.NVarChar(100), motivo);
        reqM.input("idUsuario", sql.Int, idUsuario);
        await reqM.query(`
          INSERT INTO ${FULL_MOTIVO_TABLE} (ID_MOTIVO, ID_IDIOMA, NM_MOTIVO, DS_MOTIVO, SG_ATIVO, ID_USUARIO, DT_ATUALIZACAO)
          VALUES (@idMotivo, @idIdioma, @nmMotivo, @dsMotivo, 'S', @idUsuario, GETDATE())`);
      }

      const reqUp = new sql.Request(tx);
      reqUp.input("idKaizen", sql.Int, idKaizen);
      reqUp.input("idMotivo", sql.Int, idMotivo);
      reqUp.input("idUsuario", sql.Int, idUsuario);
      await reqUp.query(`
        UPDATE ${FULL_PVC_TABLE}
        SET SG_STATUS = 'REPROVADO', ID_MOTIVO = @idMotivo, DT_ATUALIZACAO = GETDATE(), ID_USUARIO_ATUALIZACAO = @idUsuario
        WHERE ID_KAIZEN = @idKaizen`);

      await tx.commit();
      res.json({ ok: true });
    } catch (errTx) {
      await tx.rollback().catch(() => {});
      throw errTx;
    }
  } catch (err) {
    console.error("[reprovar] erro:", err.message);
    res.status(500).json({ error: "Erro ao reprovar: " + err.message });
  }
});

app.use("/api", apiRouter);

// ------------------------------------------------------------------
// Fallback de rota principal
// ------------------------------------------------------------------
app.get("/", (req, res) => {
  // Mesmo critério do index.html servido pelo express.static acima:
  // revalida sempre (deploy aparece na hora), mas aproveita 304.
  res.set("Cache-Control", "no-cache");
  res.sendFile(path.join(__dirname, "index.html"));
});

const PORT = process.env.DATABRICKS_APP_PORT || process.env.PORT || 8000;
// Bind explícito em 0.0.0.0: sem isso, o Node pode escutar só em IPv6
// (::) dependendo do ambiente, e o proxy do Databricks Apps às vezes
// não consegue rotear certas conexões até lá — na prática aparece
// como falhas ALEATÓRIAS em alguns assets (CSS/JS/imagens), com o
// HTML principal carregando normalmente. 0.0.0.0 aceita conexões
// IPv4 de forma explícita e resolve isso.
app.listen(PORT, "0.0.0.0", () => {
  console.log(`[kaizen] servidor rodando em 0.0.0.0:${PORT}`);
  console.log(`[kaizen] tabela alvo: ${FULL_TABLE_NAME} @ ${DB_SERVER || "(AZURE_SQL_SERVER não configurado)"}`);
});
