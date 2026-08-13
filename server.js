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
    const result = await runQuery(
      `SELECT TOP (@limite)
              a.ID_USUARIO, a.SG_ATIVO, a.DT_ATUALIZACAO,
              m.CD_MATRICULA, m.NM_USUARIO, m.DS_EMAIL
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
      `SELECT TOP (1) ID_USUARIO, CD_MATRICULA, NM_USUARIO, DS_EMAIL
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
// SOMENTE LEITURA, de propósito. Pelo DER esta tabela tem apenas
// ID_USUARIO, CD_MATRICULA, NM_USUARIO, DS_EMAIL, NM_HIERARQUIA_N1..N8
// e DT_ATUALIZACAO: não existe coluna de status (SG_ATIVO), papel,
// empresa nem unidade — e o próprio modal da tela diz que os dados são
// sincronizados do MDM corporativo. Por isso não há POST/PUT aqui:
// criar/editar/inativar usuário exigiria colunas (ou uma tabela de
// vínculo) que o modelo atual não tem.
// O papel exibido é DERIVADO: quem está em kzn_aprovador aparece como
// "Aprovador"; os demais, como "Operador". É a única fonte de papel
// disponível hoje no modelo.
apiRouter.get("/usuarios", async (req, res) => {
  try {
    const limite = Math.min(parseInt(req.query.limit, 10) || 500, 5000);
    const result = await runQuery(
      `SELECT TOP (@limite)
              m.ID_USUARIO, m.CD_MATRICULA, m.NM_USUARIO, m.DS_EMAIL,
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
 *   colDescricao  — coluna de descrição (ex.: "DS_CATEGORIA")
 *   maxNome       — limite de caracteres do nome (do DER)
 *   maxDescricao  — limite de caracteres da descrição (do DER)
 *   rotuloSing    — rótulo em mensagens de erro (ex.: "categoria")
 *   colunasExtras — colunas adicionais a preservar no INSERT do MERGE,
 *                   herdadas da linha do outro idioma (ex.: a FK
 *                   ID_TIPO_RESULTADO de kzn_resultados). Opcional.
 *   contagem      — { tabela, coluna } para o badge "N kaizens".
 *                   Opcional: sem isso, QTD_KAIZENS vem null.
 */
function registrarCadastroBilingue(cfg) {
  const { rota, tabela, pk, colNome, colDescricao, maxNome, maxDescricao, rotuloSing } = cfg;
  const extras = cfg.colunasExtras || [];
  const log = `[${rota}]`;

  // Validação única, compartilhada por POST (criar) e PUT (editar) —
  // garante que os dois processos apliquem exatamente a mesma regra.
  function validarCampos(nomePt, descPt, nomeEn, descEn) {
    if (!nomePt || !descPt || !nomeEn || !descEn) {
      return "Nome e descrição são obrigatórios nos dois idiomas.";
    }
    if (nomePt.length > maxNome || nomeEn.length > maxNome) {
      return `O nome deve ter no máximo ${maxNome} caracteres (em cada idioma).`;
    }
    if (descPt.length > maxDescricao || descEn.length > maxDescricao) {
      return `A descrição deve ter no máximo ${maxDescricao} caracteres (em cada idioma).`;
    }
    return null;
  }

  function lerCorpo(req) {
    const pt = req.body?.pt || {};
    const en = req.body?.en || {};
    return {
      nomePt: (pt.NM || "").trim(),
      descPt: (pt.DS || "").trim(),
      nomeEn: (en.NM || "").trim(),
      descEn: (en.DS || "").trim(),
    };
  }

  // Upsert de 1 linha (1 idioma) — MERGE: atualiza se a linha
  // (pk + ID_IDIOMA) já existe, cria se não existe. Usada tanto pelo
  // POST (id novo → sempre INSERT) quanto pelo PUT (UPDATE pra quem já
  // existe, INSERT só pro idioma que faltava). Mesma função, mesma
  // regra, nos dois processos.
  // WHEN NOT MATCHED: URL_ICONE (e demais colunasExtras) herdam o valor
  // da linha do OUTRO idioma que já existir — mesmo registro, mesmo
  // ícone/FK nos dois idiomas; ficam NULL na criação, quando nenhuma
  // linha existe ainda.
  const colsHerdadas = ["URL_ICONE"].concat(extras);
  const selectHerdado = (col) => `(SELECT TOP (1) ${col} FROM ${tabela} WHERE ${pk} = @id)`;

  function upsertIdioma(id, idIdioma, nome, descricao) {
    return runQuery(
      `MERGE INTO ${tabela} AS target
       USING (SELECT @id AS ${pk}, @idIdioma AS ID_IDIOMA) AS src
         ON target.${pk} = src.${pk} AND target.ID_IDIOMA = src.ID_IDIOMA
       WHEN MATCHED THEN
         UPDATE SET ${colNome} = @nome, ${colDescricao} = @descricao, DT_ATUALIZACAO = GETDATE()
       WHEN NOT MATCHED THEN
         INSERT (${pk}, ID_IDIOMA, ${colsHerdadas.join(", ")}, ${colNome}, ${colDescricao}, SG_ATIVO, DT_ATUALIZACAO)
         VALUES (@id, @idIdioma, ${colsHerdadas.map(selectHerdado).join(", ")}, @nome, @descricao, 'S', GETDATE());`,
      [
        ["nome", sql.NVarChar(maxNome), nome],
        ["descricao", sql.NVarChar(maxDescricao), descricao],
        ["id", sql.Int, id],
        ["idIdioma", sql.Int, idIdioma],
      ]
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
      const result = await runQuery(
        `SELECT base.${pk} AS ID,
                COALESCE(tr.${colNome}, base.${colNome}) AS NM,
                COALESCE(tr.${colDescricao}, base.${colDescricao}) AS DS,
                base.${colNome} AS NM_PT,
                base.URL_ICONE, base.SG_ATIVO,
                CASE WHEN @idIdioma <> @idIdiomaBase AND tr.ID_IDIOMA IS NULL
                     THEN 1 ELSE 0 END AS SEM_TRADUCAO
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
          DS: r.DS,
          URL_ICONE: r.URL_ICONE,
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

      const result = await runQuery(
        `SELECT ID_IDIOMA, ${colNome} AS NM, ${colDescricao} AS DS FROM ${tabela} WHERE ${pk} = @id`,
        [["id", sql.Int, id]]
      );

      const pt = result.recordset.find((r) => r.ID_IDIOMA === ID_IDIOMA_PT);
      const en = result.recordset.find((r) => r.ID_IDIOMA === ID_IDIOMA_EN);
      if (!pt && !en) return res.status(404).json({ error: `Registro de ${rotuloSing} não encontrado.` });

      res.json({
        ID: id,
        pt: pt ? { NM: pt.NM, DS: pt.DS } : null,
        en: en ? { NM: en.NM, DS: en.DS } : null,
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

      const { nomePt, descPt, nomeEn, descEn } = lerCorpo(req);
      const erro = validarCampos(nomePt, descPt, nomeEn, descEn);
      if (erro) return res.status(400).json({ error: erro });

      const existe = await runQuery(
        `SELECT TOP (1) 1 AS X FROM ${tabela} WHERE ${pk} = @id`,
        [["id", sql.Int, id]]
      );
      if (!existe.recordset.length) {
        return res.status(404).json({ error: `Registro de ${rotuloSing} não encontrado.` });
      }

      await Promise.all([
        upsertIdioma(id, ID_IDIOMA_PT, nomePt, descPt),
        upsertIdioma(id, ID_IDIOMA_EN, nomeEn, descEn),
      ]);
      res.json({ ok: true });
    } catch (err) {
      console.error(`${log} erro ao atualizar:`, err.message);
      res.status(500).json({ error: `Erro ao atualizar ${rotuloSing}: ` + err.message });
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
      const { nomePt, descPt, nomeEn, descEn } = lerCorpo(req);
      const erro = validarCampos(nomePt, descPt, nomeEn, descEn);
      if (erro) return res.status(400).json({ error: erro });

      const proximo = await runQuery(`SELECT ISNULL(MAX(${pk}), 0) + 1 AS PROXIMO FROM ${tabela}`);
      const id = proximo.recordset[0].PROXIMO;

      await Promise.all([
        upsertIdioma(id, ID_IDIOMA_PT, nomePt, descPt),
        upsertIdioma(id, ID_IDIOMA_EN, nomeEn, descEn),
      ]);
      res.status(201).json({ ok: true, ID: id });
    } catch (err) {
      console.error(`${log} erro ao criar:`, err.message);
      res.status(500).json({ error: `Erro ao criar ${rotuloSing}: ` + err.message });
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
  // FK própria desta tabela (as outras 3 não têm): preservada junto do
  // ícone ao criar a linha do 2º idioma. Numa criação do zero fica
  // NULL — a tela não coleta esse campo hoje.
  colunasExtras: ["ID_TIPO_RESULTADO"],
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
