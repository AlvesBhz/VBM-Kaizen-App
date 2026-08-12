/**
 * VBM Kaizen — servidor Node/Express.
 *
 * Serve os HTML/CSS/JS estáticos do app (index, admin, aprovacao, etc.)
 * e expõe uma API REST para a tabela `kzn_aprovador`, usada hoje pela
 * aba "Aprovadores" de admin.html. Também expõe uma leitura (só GET)
 * de `kzn_categoria` + contagem em `kzn_pendenciaconsolidada`, usada
 * pelo card em destaque da aba "Categorias" (ver assets/categorias.js).
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
const sql = require("mssql");

const app = express();
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
// Sem maxAge/index automático — mesmo raciocínio de outros apps deste
// workspace: evita que o navegador/proxy prenda HTML/JS/CSS numa
// versão antiga entre deploys. etag:true ainda permite 304 quando
// nada mudou.
app.use(
  express.static(__dirname, {
    etag: true,
    index: false,
    setHeaders: (res) => res.set("Cache-Control", "no-store"),
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
apiRouter.get("/aprovadores", async (req, res) => {
  try {
    const limite = Math.min(parseInt(req.query.limit, 10) || 500, 5000);
    const result = await runQuery(
      `SELECT TOP (@limite) ID_USUARIO, CD_MATRICULA, NM_USER, DT_ATUALIZACAO
       FROM ${FULL_TABLE_NAME}
       ORDER BY DT_ATUALIZACAO DESC`,
      [["limite", sql.Int, limite]]
    );
    res.json(result.recordset);
  } catch (err) {
    console.error("[aprovadores] erro ao listar:", err.message);
    res.status(500).json({ error: "Erro ao consultar aprovadores: " + err.message });
  }
});

// Inserir
apiRouter.post("/aprovadores", async (req, res) => {
  try {
    const { ID_USUARIO, CD_MATRICULA, NM_USER } = req.body || {};

    const idUsuario = parseInt(ID_USUARIO, 10);
    const cdMatricula = (CD_MATRICULA || "").trim();
    const nmUser = (NM_USER || "").trim();

    if (!Number.isInteger(idUsuario)) {
      return res.status(400).json({ error: "ID_USUARIO é obrigatório e deve ser um número inteiro." });
    }
    if (!cdMatricula) {
      return res.status(400).json({ error: "CD_MATRICULA é obrigatório." });
    }
    if (!nmUser) {
      return res.status(400).json({ error: "NM_USER é obrigatório." });
    }

    await runQuery(
      `INSERT INTO ${FULL_TABLE_NAME} (ID_USUARIO, CD_MATRICULA, NM_USER, DT_ATUALIZACAO)
       VALUES (@idUsuario, @cdMatricula, @nmUser, GETDATE())`,
      [
        ["idUsuario", sql.Int, idUsuario],
        ["cdMatricula", sql.NVarChar(50), cdMatricula],
        ["nmUser", sql.NVarChar(200), nmUser],
      ]
    );
    res.status(201).json({ ok: true });
  } catch (err) {
    console.error("[aprovadores] erro ao inserir:", err.message);
    res.status(500).json({ error: "Erro ao inserir aprovador: " + err.message });
  }
});

// Atualizar (por ID_USUARIO)
apiRouter.put("/aprovadores/:id", async (req, res) => {
  try {
    const idUsuario = parseInt(req.params.id, 10);
    if (!Number.isInteger(idUsuario)) {
      return res.status(400).json({ error: "ID_USUARIO inválido." });
    }

    const cdMatricula = (req.body?.CD_MATRICULA || "").trim();
    const nmUser = (req.body?.NM_USER || "").trim();

    const sets = [];
    const params = [["idUsuario", sql.Int, idUsuario]];
    if (cdMatricula) {
      sets.push("CD_MATRICULA = @cdMatricula");
      params.push(["cdMatricula", sql.NVarChar(50), cdMatricula]);
    }
    if (nmUser) {
      sets.push("NM_USER = @nmUser");
      params.push(["nmUser", sql.NVarChar(200), nmUser]);
    }
    sets.push("DT_ATUALIZACAO = GETDATE()");

    if (!sets.length) {
      return res.status(400).json({ error: "Nenhum campo para atualizar foi enviado." });
    }

    const result = await runQuery(
      `UPDATE ${FULL_TABLE_NAME} SET ${sets.join(", ")} WHERE ID_USUARIO = @idUsuario`,
      params
    );
    if (!result.rowsAffected[0]) {
      return res.status(404).json({ error: "Aprovador não encontrado." });
    }
    res.json({ ok: true });
  } catch (err) {
    console.error("[aprovadores] erro ao atualizar:", err.message);
    res.status(500).json({ error: "Erro ao atualizar aprovador: " + err.message });
  }
});

// Deletar (por ID_USUARIO)
apiRouter.delete("/aprovadores/:id", async (req, res) => {
  try {
    const idUsuario = parseInt(req.params.id, 10);
    if (!Number.isInteger(idUsuario)) {
      return res.status(400).json({ error: "ID_USUARIO inválido." });
    }
    const result = await runQuery(
      `DELETE FROM ${FULL_TABLE_NAME} WHERE ID_USUARIO = @idUsuario`,
      [["idUsuario", sql.Int, idUsuario]]
    );
    if (!result.rowsAffected[0]) {
      return res.status(404).json({ error: "Aprovador não encontrado." });
    }
    res.json({ ok: true });
  } catch (err) {
    console.error("[aprovadores] erro ao deletar:", err.message);
    res.status(500).json({ error: "Erro ao deletar aprovador: " + err.message });
  }
});

// ------------------------------------------------------------------
// API — kzn_categoria (1ª fase: só leitura, 1 categoria)
// ------------------------------------------------------------------
// O card em destaque da aba "Categorias" mostra hoje só a 1ª categoria
// retornada — os demais itens da lista continuam estáticos por
// enquanto (ver assets/categorias.js). A contagem de Kaizens vem de
// kzn_pendenciaconsolidada, casada por NM_CATEGORIA; se essa coluna
// não existir na tabela real, a consulta de contagem falha sozinha
// sem derrubar a categoria em si (mesmo espírito defensivo do
// restante do arquivo) — devolve QTD_KAIZENS: null e só loga o motivo.
apiRouter.get("/categorias", async (req, res) => {
  try {
    const result = await runQuery(
      `SELECT TOP (1) NM_CATEGORIA, DS_CATEGORIA, URL_ICONE
       FROM ${FULL_CATEGORIA_TABLE}
       ORDER BY NM_CATEGORIA`
    );
    const categoria = result.recordset[0] || null;
    if (!categoria) return res.json(null);

    let qtdKaizens = null;
    try {
      const contagem = await runQuery(
        `SELECT COUNT(*) AS QTD FROM ${FULL_PENDENCIA_TABLE} WHERE NM_CATEGORIA = @nmCategoria`,
        [["nmCategoria", sql.NVarChar(200), categoria.NM_CATEGORIA]]
      );
      qtdKaizens = contagem.recordset[0].QTD;
    } catch (err) {
      console.warn(`[categorias] contagem de kaizens indisponível (${FULL_PENDENCIA_TABLE}): ${err.message}`);
    }

    res.json({ ...categoria, QTD_KAIZENS: qtdKaizens });
  } catch (err) {
    console.error("[categorias] erro ao consultar:", err.message);
    res.status(500).json({ error: "Erro ao consultar categorias: " + err.message });
  }
});

app.use("/api", apiRouter);

// ------------------------------------------------------------------
// Fallback de rota principal
// ------------------------------------------------------------------
app.get("/", (req, res) => {
  res.set("Cache-Control", "no-store");
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
