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

// kzn_categoria guarda 1 LINHA POR IDIOMA para a mesma categoria (mesmo
// ID_CATEGORIA, ID_IDIOMA diferente) — confirmado no DER
// (assets/DER_VBM_Kaizen_CI.html) e pelo time: ID_IDIOMA=1 é Português,
// ID_IDIOMA=2 é Inglês (kzn_idioma).
const ID_IDIOMA_PT = 1;
const ID_IDIOMA_EN = 2;

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
// API — kzn_categoria
// ------------------------------------------------------------------
// Limites de campo (mesmos para INSERT e UPDATE — ver
// validarCategoriaCampos abaixo, usada pelos dois).
const CATEGORIA_NOME_MAX = 30;
const CATEGORIA_DESCRICAO_MAX = 100;

// Validação única, compartilhada pelo POST (criar) e PUT (editar) —
// garante que os dois processos apliquem exatamente a mesma regra.
function validarCategoriaCampos(nomePt, descPt, nomeEn, descEn) {
  if (!nomePt || !descPt || !nomeEn || !descEn) {
    return "Nome e descrição são obrigatórios nos dois idiomas.";
  }
  if (nomePt.length > CATEGORIA_NOME_MAX || nomeEn.length > CATEGORIA_NOME_MAX) {
    return `O nome da categoria deve ter no máximo ${CATEGORIA_NOME_MAX} caracteres (em cada idioma).`;
  }
  if (descPt.length > CATEGORIA_DESCRICAO_MAX || descEn.length > CATEGORIA_DESCRICAO_MAX) {
    return `A descrição da categoria deve ter no máximo ${CATEGORIA_DESCRICAO_MAX} caracteres (em cada idioma).`;
  }
  return null;
}

// Upsert de 1 linha (1 idioma) de kzn_categoria — MERGE: atualiza se a
// linha (ID_CATEGORIA + ID_IDIOMA) já existe, cria se não existe.
// Usada tanto pelo POST (criar — as 2 linhas caem sempre no ramo
// INSERT, já que o ID_CATEGORIA é sempre novo) quanto pelo PUT (editar
// — cai em UPDATE pra quem já existe, INSERT só pro idioma que
// faltava). Mesma função, mesma regra, nos dois processos.
// WHEN NOT MATCHED: URL_ICONE herda o valor da linha do OUTRO idioma
// que já existir (mesma categoria, mesmo ícone nos dois idiomas — fica
// NULL na criação, quando nenhuma linha existe ainda); SG_ATIVO 'S'
// (ativo), mesmo padrão das categorias já cadastradas.
function upsertCategoriaIdioma(id, idIdioma, nome, descricao) {
  return runQuery(
    `MERGE INTO ${FULL_CATEGORIA_TABLE} AS target
     USING (SELECT @id AS ID_CATEGORIA, @idIdioma AS ID_IDIOMA) AS src
       ON target.ID_CATEGORIA = src.ID_CATEGORIA AND target.ID_IDIOMA = src.ID_IDIOMA
     WHEN MATCHED THEN
       UPDATE SET NM_CATEGORIA = @nome, DS_CATEGORIA = @descricao, DT_ATUALIZACAO = GETDATE()
     WHEN NOT MATCHED THEN
       INSERT (ID_CATEGORIA, ID_IDIOMA, URL_ICONE, NM_CATEGORIA, DS_CATEGORIA, SG_ATIVO, DT_ATUALIZACAO)
       VALUES (
         @id, @idIdioma,
         (SELECT TOP (1) URL_ICONE FROM ${FULL_CATEGORIA_TABLE} WHERE ID_CATEGORIA = @id),
         @nome, @descricao, 'S', GETDATE()
       );`,
    [
      ["nome", sql.NVarChar(CATEGORIA_NOME_MAX), nome],
      ["descricao", sql.NVarChar(CATEGORIA_DESCRICAO_MAX), descricao],
      ["id", sql.Int, id],
      ["idIdioma", sql.Int, idIdioma],
    ]
  );
}

// Lista TODAS as categorias (linha PT de cada uma — ID_IDIOMA fixo,
// ver nota de ID_IDIOMA_PT/EN acima) pra aba "Categorias" de
// admin.html, sem nenhum item estático misturado (ver
// assets/categorias.js). Contagem de Kaizens vem de
// kzn_pendenciaconsolidada, casada por NM_CATEGORIA, numa ÚNICA
// consulta agrupada (não uma por categoria) — se essa tabela/coluna
// não existir de verdade, a contagem falha sozinha sem derrubar a
// lista (mesmo espírito defensivo do restante do arquivo): todo mundo
// fica com QTD_KAIZENS null, só loga o motivo.
apiRouter.get("/categorias", async (req, res) => {
  try {
    const result = await runQuery(
      `SELECT ID_CATEGORIA, NM_CATEGORIA, DS_CATEGORIA, URL_ICONE, SG_ATIVO
       FROM ${FULL_CATEGORIA_TABLE}
       WHERE ID_IDIOMA = @idIdioma
       ORDER BY NM_CATEGORIA`,
      [["idIdioma", sql.Int, ID_IDIOMA_PT]]
    );

    let contagemPorNome = {};
    try {
      const contagem = await runQuery(
        `SELECT NM_CATEGORIA, COUNT(*) AS QTD FROM ${FULL_PENDENCIA_TABLE} GROUP BY NM_CATEGORIA`
      );
      contagem.recordset.forEach((r) => { contagemPorNome[r.NM_CATEGORIA] = r.QTD; });
    } catch (err) {
      console.warn(`[categorias] contagem de kaizens indisponível (${FULL_PENDENCIA_TABLE}): ${err.message}`);
    }

    res.json(
      result.recordset.map((c) => ({
        ID_CATEGORIA: c.ID_CATEGORIA,
        NM_CATEGORIA: c.NM_CATEGORIA,
        DS_CATEGORIA: c.DS_CATEGORIA,
        URL_ICONE: c.URL_ICONE,
        ATIVO: c.SG_ATIVO === "S",
        QTD_KAIZENS: contagemPorNome[c.NM_CATEGORIA] != null ? contagemPorNome[c.NM_CATEGORIA] : null,
      }))
    );
  } catch (err) {
    console.error("[categorias] erro ao consultar:", err.message);
    res.status(500).json({ error: "Erro ao consultar categorias: " + err.message });
  }
});

// Buscar 1 categoria por ID — as duas linhas (PT e EN) do mesmo
// ID_CATEGORIA, usadas para popular o modal de edição bilíngue.
apiRouter.get("/categorias/:id", async (req, res) => {
  try {
    const id = parseInt(req.params.id, 10);
    if (!Number.isInteger(id)) {
      return res.status(400).json({ error: "ID_CATEGORIA inválido." });
    }

    const result = await runQuery(
      `SELECT ID_IDIOMA, NM_CATEGORIA, DS_CATEGORIA
       FROM ${FULL_CATEGORIA_TABLE}
       WHERE ID_CATEGORIA = @id`,
      [["id", sql.Int, id]]
    );

    const pt = result.recordset.find((r) => r.ID_IDIOMA === ID_IDIOMA_PT);
    const en = result.recordset.find((r) => r.ID_IDIOMA === ID_IDIOMA_EN);
    if (!pt && !en) {
      return res.status(404).json({ error: "Categoria não encontrada." });
    }

    res.json({
      ID_CATEGORIA: id,
      pt: pt ? { NM_CATEGORIA: pt.NM_CATEGORIA, DS_CATEGORIA: pt.DS_CATEGORIA } : null,
      en: en ? { NM_CATEGORIA: en.NM_CATEGORIA, DS_CATEGORIA: en.DS_CATEGORIA } : null,
    });
  } catch (err) {
    console.error("[categorias] erro ao consultar por ID:", err.message);
    res.status(500).json({ error: "Erro ao consultar categoria: " + err.message });
  }
});

// Atualizar (por ID_CATEGORIA) — grava as duas linhas (PT e EN).
// NA PRÁTICA A CATEGORIA PODE TER SÓ A LINHA PT CADASTRADA (a EN nunca
// foi criada ainda) — por isso cada idioma faz um upsert (MERGE: edita
// se a linha já existe, cria se não existe) em vez de um UPDATE puro,
// senão digitar a tradução em inglês pela 1ª vez silenciosamente não
// gravava nada (0 linhas afetadas, sem erro). O ID_CATEGORIA do ambos
// os idiomas é sempre o mesmo, tanto no upsert quanto no ícone herdado
// (abaixo) — nunca gera um ID novo/solto.
// Ainda assim, só mexe em categoria que já existe: se NENHUMA linha
// (nem PT nem EN) tiver esse ID_CATEGORIA, devolve 404 sem gravar nada
// — não dá pra criar uma categoria do zero por aqui, só completar o
// idioma que falta numa já existente.
apiRouter.put("/categorias/:id", async (req, res) => {
  try {
    const id = parseInt(req.params.id, 10);
    if (!Number.isInteger(id)) {
      return res.status(400).json({ error: "ID_CATEGORIA inválido." });
    }

    const pt = req.body?.pt || {};
    const en = req.body?.en || {};
    const nomePt = (pt.NM_CATEGORIA || "").trim();
    const descPt = (pt.DS_CATEGORIA || "").trim();
    const nomeEn = (en.NM_CATEGORIA || "").trim();
    const descEn = (en.DS_CATEGORIA || "").trim();

    const erroValidacao = validarCategoriaCampos(nomePt, descPt, nomeEn, descEn);
    if (erroValidacao) {
      return res.status(400).json({ error: erroValidacao });
    }

    const existe = await runQuery(
      `SELECT TOP (1) 1 AS X FROM ${FULL_CATEGORIA_TABLE} WHERE ID_CATEGORIA = @id`,
      [["id", sql.Int, id]]
    );
    if (!existe.recordset.length) {
      return res.status(404).json({ error: "Categoria não encontrada." });
    }

    await Promise.all([
      upsertCategoriaIdioma(id, ID_IDIOMA_PT, nomePt, descPt),
      upsertCategoriaIdioma(id, ID_IDIOMA_EN, nomeEn, descEn),
    ]);

    res.json({ ok: true });
  } catch (err) {
    console.error("[categorias] erro ao atualizar:", err.message);
    res.status(500).json({ error: "Erro ao atualizar categoria: " + err.message });
  }
});

// Criar (POST) — MESMA validação e MESMA função de upsert do PUT
// acima (upsertCategoriaIdioma): a única diferença é que aqui o
// ID_CATEGORIA é sempre novo (próximo disponível), então as 2 chamadas
// caem sempre no ramo INSERT do MERGE. Sem transação explícita: numa
// falha a meio caminho (ex.: EN falha depois do PT já ter gravado), a
// categoria fica só com a linha PT — mesma situação já tratada pelo
// PUT (upsert completa o idioma que faltar depois, numa edição normal).
apiRouter.post("/categorias", async (req, res) => {
  try {
    const pt = req.body?.pt || {};
    const en = req.body?.en || {};
    const nomePt = (pt.NM_CATEGORIA || "").trim();
    const descPt = (pt.DS_CATEGORIA || "").trim();
    const nomeEn = (en.NM_CATEGORIA || "").trim();
    const descEn = (en.DS_CATEGORIA || "").trim();

    const erroValidacao = validarCategoriaCampos(nomePt, descPt, nomeEn, descEn);
    if (erroValidacao) {
      return res.status(400).json({ error: erroValidacao });
    }

    const proximoId = await runQuery(
      `SELECT ISNULL(MAX(ID_CATEGORIA), 0) + 1 AS PROXIMO_ID FROM ${FULL_CATEGORIA_TABLE}`
    );
    const id = proximoId.recordset[0].PROXIMO_ID;

    await Promise.all([
      upsertCategoriaIdioma(id, ID_IDIOMA_PT, nomePt, descPt),
      upsertCategoriaIdioma(id, ID_IDIOMA_EN, nomeEn, descEn),
    ]);

    res.status(201).json({ ok: true, ID_CATEGORIA: id });
  } catch (err) {
    console.error("[categorias] erro ao criar:", err.message);
    res.status(500).json({ error: "Erro ao criar categoria: " + err.message });
  }
});

// Ativar/desativar (por ID_CATEGORIA) — grava SG_ATIVO ('S'/'N') nas
// linhas de TODOS os idiomas desse ID_CATEGORIA de uma vez (o status
// é da categoria, não de uma tradução específica), sem filtrar por
// ID_IDIOMA.
apiRouter.put("/categorias/:id/status", async (req, res) => {
  try {
    const id = parseInt(req.params.id, 10);
    if (!Number.isInteger(id)) {
      return res.status(400).json({ error: "ID_CATEGORIA inválido." });
    }
    if (typeof req.body?.ativo !== "boolean") {
      return res.status(400).json({ error: "Campo 'ativo' (true/false) é obrigatório." });
    }
    const sgAtivo = req.body.ativo ? "S" : "N";

    const result = await runQuery(
      `UPDATE ${FULL_CATEGORIA_TABLE}
       SET SG_ATIVO = @sgAtivo, DT_ATUALIZACAO = GETDATE()
       WHERE ID_CATEGORIA = @id`,
      [
        ["sgAtivo", sql.Char(1), sgAtivo],
        ["id", sql.Int, id],
      ]
    );
    if (!result.rowsAffected[0]) {
      return res.status(404).json({ error: "Categoria não encontrada." });
    }

    res.json({ ok: true, ativo: req.body.ativo });
  } catch (err) {
    console.error("[categorias] erro ao atualizar status:", err.message);
    res.status(500).json({ error: "Erro ao atualizar status da categoria: " + err.message });
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
