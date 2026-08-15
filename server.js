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
apiRouter.use((req, res, next) => {
  res.set("Cache-Control", "no-store");
  next();
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
      `SELECT TOP (1) ID_USUARIO, CD_MATRICULA, NM_USUARIO FROM ${FULL_MDM_TABLE} WHERE LOWER(CD_EMAIL) = LOWER(@email)`,
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

  res.json({
    autenticado: !!(email || usuario),
    nome: (mdm && mdm.NM_USUARIO) || nomeDerivado,
    email: email,
    usuario: usuario,
    idUsuario: h("X-Forwarded-User"),
    matricula: (mdm && mdm.CD_MATRICULA) || null,
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
              m.CD_MATRICULA, m.NM_USUARIO, m.CD_EMAIL AS DS_EMAIL
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
        ATIVO: r.SG_ATIVO === "S",
        DT_ATUALIZACAO: r.DT_ATUALIZACAO,
      }))
    );
  } catch (err) {
    console.error("[aprovadores] erro ao listar:", err.message);
    res.status(500).json({ error: "Erro ao consultar aprovadores: " + err.message });
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
      `SELECT TOP (1) ID_USUARIO, CD_MATRICULA, NM_USUARIO, CD_EMAIL AS DS_EMAIL
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

// Adicionar — só o ID_USUARIO é gravado; ele precisa existir no MDM
// (a FK garante isso no banco, mas checamos antes para devolver uma
// mensagem clara em vez de um erro cru de constraint).
apiRouter.post("/aprovadores", async (req, res) => {
  try {
    const idUsuario = parseInt(req.body?.ID_USUARIO, 10);
    if (!Number.isInteger(idUsuario)) {
      return res.status(400).json({ error: "ID_USUARIO é obrigatório e deve ser um número inteiro." });
    }

    const noMdm = await runQuery(
      `SELECT TOP (1) 1 AS X FROM ${FULL_MDM_TABLE} WHERE ID_USUARIO = @id`,
      [["id", sql.Int, idUsuario]]
    );
    if (!noMdm.recordset.length) {
      return res.status(400).json({ error: "Usuário não encontrado no MDM — verifique o ID_USUARIO." });
    }

    const jaExiste = await runQuery(
      `SELECT TOP (1) 1 AS X FROM ${FULL_TABLE_NAME} WHERE ID_USUARIO = @id`,
      [["id", sql.Int, idUsuario]]
    );
    if (jaExiste.recordset.length) {
      return res.status(409).json({ error: "Este usuário já está cadastrado como aprovador." });
    }

    await runQuery(
      `INSERT INTO ${FULL_TABLE_NAME} (ID_USUARIO, SG_ATIVO, DT_ATUALIZACAO)
       VALUES (@id, 'S', GETDATE())`,
      [["id", sql.Int, idUsuario]]
    );
    res.status(201).json({ ok: true, ID_USUARIO: idUsuario });
  } catch (err) {
    console.error("[aprovadores] erro ao inserir:", err.message);
    res.status(500).json({ error: "Erro ao inserir aprovador: " + err.message });
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
apiRouter.get("/usuarios", async (req, res) => {
  try {
    const limite = Math.min(parseInt(req.query.limit, 10) || 500, 5000);
    const result = await runQuery(
      `SELECT TOP (@limite)
              m.ID_USUARIO, m.CD_MATRICULA, m.NM_USUARIO, m.CD_EMAIL AS DS_EMAIL,
              CASE WHEN a.ID_USUARIO IS NULL THEN 0 ELSE 1 END AS EH_APROVADOR,
              a.SG_ATIVO AS SG_ATIVO_APROVADOR
       FROM ${FULL_MDM_TABLE} m
       LEFT JOIN ${FULL_TABLE_NAME} a ON a.ID_USUARIO = m.ID_USUARIO
       ORDER BY m.NM_USUARIO`,
      [["limite", sql.Int, limite]]
    );
    res.json(
      result.recordset.map((r) => ({
        ID_USUARIO: r.ID_USUARIO,
        CD_MATRICULA: r.CD_MATRICULA,
        NM_USUARIO: r.NM_USUARIO,
        DS_EMAIL: r.DS_EMAIL,
        // Booleano, não texto: "Aprovador"/"Operador" é rótulo de tela,
        // não dado do banco (kzn_aprovador não tem coluna de idioma).
        // Faixa fixa em PT aqui nunca acompanhava a troca de idioma —
        // quem traduz é o front-end (ver js/usuarios.js).
        EH_APROVADOR: !!r.EH_APROVADOR,
      }))
    );
  } catch (err) {
    console.error("[usuarios] erro ao listar:", err.message);
    res.status(500).json({ error: "Erro ao consultar usuários: " + err.message });
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
function mensagemErroSql(err, rotuloSing) {
  const numero = err && err.number;
  const texto = (err && err.message) || "";
  if (numero === 2627 || numero === 2601 || /violation of unique key constraint|cannot insert duplicate key/i.test(texto)) {
    return `Já existe um(a) ${rotuloSing} cadastrado(a) com esse nome neste idioma.`;
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
      const amigavel = mensagemErroSql(err, rotuloSing);
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
      const amigavel = mensagemErroSql(err, rotuloSing);
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
