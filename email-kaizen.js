/**
 * VBM Kaizen — e-mails automáticos das decisões de aprovação.
 *
 * Usado por server.js (registrarDecisao) DEPOIS que a decisão já está
 * gravada: aprovar, reprovar e solicitar alteração avisam o autor da
 * iniciativa por e-mail.
 *
 * ENVIO
 *   Microsoft Graph, app-only (client credentials), sem dependência
 *   nova — o fetch é o nativo do Node. Mesmo desenho de token do
 *   databricks-fs.js: troca client_id + client_secret por um access
 *   token e guarda em memória até pouco antes de expirar.
 *
 *     POST https://graph.microsoft.com/v1.0/users/{remetente}/sendMail
 *
 *   Variáveis (app.yaml):
 *     AZURE_TENANT_ID          tenant do Entra ID
 *     AZURE_CLIENT_ID          app registration com Mail.Send
 *     AZURE_CLIENT_SECRET      segredo desse app registration
 *     KAIZEN_EMAIL_REMETENTE   caixa remetente (padrão abaixo)
 *     KAIZEN_APP_URL           endereço do app (padrão abaixo)
 *
 *   PERMISSÃO NECESSÁRIA: permissão de APLICATIVO Mail.Send, com
 *   consentimento do administrador, e — porque Mail.Send de aplicativo
 *   dá acesso a todas as caixas do tenant — uma Application Access
 *   Policy restringindo esse app à caixa PCI.Base.Metals@Vale.com. Sem
 *   isso o Graph responde 403 mesmo com o token válido.
 *
 *   Sem as três variáveis o módulo NÃO quebra a decisão: registra um
 *   aviso no log e devolve { enviado: false, motivo: "..." }. Gravar a
 *   decisão é o que não pode falhar; o aviso é consequência dela.
 *
 * IDIOMA
 *   Não existe idioma cadastrado por pessoa: kzn_mdm_hierarquia não tem
 *   coluna de idioma e kzn_pedravisaoconsolidada também não. Por isso
 *   cada e-mail sai BILÍNGUE — o corpo em português e, abaixo, o mesmo
 *   conteúdo em inglês —, o que não depende do idioma da tela de quem
 *   decidiu nem de mudança de banco. O nome do status vem de
 *   kzn_status nos dois idiomas (ID_IDIOMA 1 e 2), não de texto fixo.
 */

const GRAPH = "https://graph.microsoft.com";
const TENANT_ID = process.env.AZURE_TENANT_ID || "";
const CLIENT_ID = process.env.AZURE_CLIENT_ID || "";
const CLIENT_SECRET = process.env.AZURE_CLIENT_SECRET || "";
const REMETENTE = process.env.KAIZEN_EMAIL_REMETENTE || "PCI.Base.Metals@Vale.com";
const APP_URL = (process.env.KAIZEN_APP_URL ||
  "https://kaizen-7405608945147182.2.azure.databricksapps.com").replace(/\/+$/, "");

const URL_APROVACAO = `${APP_URL}/aprovacao.html`;
const URL_BIBLIOTECA = `${APP_URL}/biblioteca.html`;

let tokenCache = null;

async function tokenDoGraph() {
  if (tokenCache && tokenCache.expiraEm > Date.now() + 60_000) return tokenCache.token;

  const corpo = new URLSearchParams({
    grant_type: "client_credentials",
    client_id: CLIENT_ID,
    client_secret: CLIENT_SECRET,
    scope: `${GRAPH}/.default`,
  });
  const resp = await fetch(`https://login.microsoftonline.com/${TENANT_ID}/oauth2/v2.0/token`, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: corpo.toString(),
  });
  if (!resp.ok) {
    const texto = await resp.text().catch(() => "");
    throw new Error(`Falha ao obter token do Graph (HTTP ${resp.status}): ${texto}`);
  }
  const dados = await resp.json();
  tokenCache = {
    token: dados.access_token,
    expiraEm: Date.now() + (dados.expires_in || 3600) * 1000,
  };
  return tokenCache.token;
}

// ------------------------------------------------------------------
// Templates — centralizados aqui de propósito: mudar o texto de um
// aviso não deveria exigir mexer no fluxo de aprovação.
// ------------------------------------------------------------------

function escapar(txt) {
  return String(txt == null ? "" : txt)
    .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

/** Quebra de linha do usuário vira <br>; o resto já vai escapado. */
function paraHtml(txt) {
  return escapar(txt).replace(/\r?\n/g, "<br>");
}

/** dd/MM/aaaa HH:mm (pt) e MM/dd/aaaa HH:mm (en).
 *
 *  Componentes UTC, não locais: DATETIME2 não guarda fuso e o que está
 *  na coluna já é o relógio de Brasília (ver AGORA_BRASILIA e
 *  relogioLocal em server.js). getDate()/getHours() usariam o fuso do
 *  processo Node e deslocariam a data da decisão. */
function formatarData(valor, idioma) {
  const d = valor instanceof Date ? valor : new Date(valor);
  if (Number.isNaN(d.getTime())) return "";
  const p = (n) => String(n).padStart(2, "0");
  const dia = p(d.getUTCDate()), mes = p(d.getUTCMonth() + 1), ano = d.getUTCFullYear();
  const hora = `${p(d.getUTCHours())}:${p(d.getUTCMinutes())}`;
  return idioma === "en" ? `${mes}/${dia}/${ano} ${hora}` : `${dia}/${mes}/${ano} ${hora}`;
}

const RODAPE = {
  pt: ["Atenciosamente,", "Programa Kaizen", "Vale Base Metals"],
  en: ["Best regards,", "Kaizen Program", "Vale Base Metals"],
};

const ROTULOS = {
  pt: { codigo: "Código", titulo: "Título", site: "Site", status: "Status",
        aprovador: "Aprovador", data: "Data da decisão" },
  en: { codigo: "Code", titulo: "Title", site: "Site", status: "Status",
        aprovador: "Approver", data: "Decision date" },
};

/** Um momento do ciclo = um template por idioma. Cada função recebe os
 *  dados reais do Kaizen e devolve { assunto, linhas }, onde `linhas` é
 *  a lista de parágrafos/blocos do corpo. */
const TEMPLATES = {
  aprovado: {
    pt: (d) => ({
      assunto: "[Kaizen] Iniciativa aprovada",
      linhas: [
        `Olá, ${d.nomeAutor}.`,
        "Seu Kaizen abaixo foi aprovado com sucesso.",
        { campos: [["codigo", d.codigo], ["titulo", d.titulo], ["site", d.site],
                   ["status", d.statusPt], ["aprovador", d.nomeAprovador], ["data", d.dataPt]] },
        "Parabéns! Sua iniciativa foi aprovada e seguirá o fluxo definido pelo programa Kaizen.",
        "Acesse o sistema para mais detalhes:",
        { link: URL_APROVACAO },
      ],
    }),
    en: (d) => ({
      assunto: "[Kaizen] Initiative approved",
      linhas: [
        `Hello, ${d.nomeAutor}.`,
        "Your Kaizen below has been successfully approved.",
        { campos: [["codigo", d.codigo], ["titulo", d.titulo], ["site", d.site],
                   ["status", d.statusEn], ["aprovador", d.nomeAprovador], ["data", d.dataEn]] },
        "Congratulations! Your initiative has been approved and will follow the flow defined by the Kaizen program.",
        "Access the system for more details:",
        { link: URL_APROVACAO },
      ],
    }),
  },

  reprovado: {
    pt: (d) => ({
      assunto: "[Kaizen] Iniciativa não aprovada",
      linhas: [
        `Olá, ${d.nomeAutor}.`,
        "Após avaliação, o Kaizen abaixo não foi aprovado.",
        { campos: [["codigo", d.codigo], ["titulo", d.titulo], ["site", d.site],
                   ["aprovador", d.nomeAprovador], ["data", d.dataPt]] },
        "Motivo informado pelo aprovador:",
        { destaque: d.motivo },
        "Caso necessário, consulte seu gestor ou responsável local para orientação.",
      ],
    }),
    en: (d) => ({
      assunto: "[Kaizen] Initiative not approved",
      linhas: [
        `Hello, ${d.nomeAutor}.`,
        "After review, the Kaizen below was not approved.",
        { campos: [["codigo", d.codigo], ["titulo", d.titulo], ["site", d.site],
                   ["aprovador", d.nomeAprovador], ["data", d.dataEn]] },
        "Reason given by the approver:",
        { destaque: d.motivo },
        "If needed, contact your manager or local representative for guidance.",
      ],
    }),
  },
};

/** Monta o HTML de um idioma. Mesmo desenho para os três momentos: sem
 *  imagem, sem CSS externo e sem tabela de layout — o que sobrevive ao
 *  Outlook e ao cliente de e-mail do celular. */
function corpoDeUmIdioma(modelo, idioma) {
  const r = ROTULOS[idioma];
  const partes = modelo.linhas.map((linha) => {
    if (typeof linha === "string") {
      return `<p style="margin:0 0 12px;">${paraHtml(linha)}</p>`;
    }
    if (linha.link) {
      return `<p style="margin:0 0 12px;"><a href="${escapar(linha.link)}" ` +
             `style="color:#1a8bbf;">${escapar(linha.link)}</a></p>`;
    }
    if (linha.campos) {
      const itens = linha.campos
        .map(([chave, valor]) => `<div style="margin:0 0 4px;"><strong>${escapar(r[chave])}:</strong> ${paraHtml(valor || "—")}</div>`)
        .join("");
      return `<div style="margin:0 0 16px;">${itens}</div>`;
    }
    if (linha.destaque) {
      return `<div style="margin:0 0 16px;padding:12px 14px;background:#f5f7f9;` +
             `border-left:3px solid #1a8bbf;">${paraHtml(linha.destaque)}</div>`;
    }
    return "";
  }).join("");

  const rodape = RODAPE[idioma]
    .map((l) => `<div>${escapar(l)}</div>`).join("");

  return `${partes}<div style="margin-top:20px;color:#555;">${rodape}</div>`;
}

/** E-mail bilíngue: português em cima, inglês embaixo, separados por uma
 *  linha. Um envio só — dois e-mails para a mesma decisão seriam ruído
 *  na caixa de quem recebe. */
function montarMensagem(momento, dados) {
  const modelo = TEMPLATES[momento];
  if (!modelo) throw new Error(`Sem template de e-mail para "${momento}".`);
  const pt = modelo.pt(dados);
  const en = modelo.en(dados);

  const html =
    `<div style="font-family:Segoe UI,Arial,sans-serif;font-size:14px;color:#222;line-height:1.55;">` +
      corpoDeUmIdioma(pt, "pt") +
      `<hr style="border:none;border-top:1px solid #e0e0e0;margin:28px 0;">` +
      corpoDeUmIdioma(en, "en") +
    `</div>`;

  return { assunto: `${pt.assunto} / ${en.assunto}`, html };
}

// ------------------------------------------------------------------
// Envio
// ------------------------------------------------------------------

/** Uma decisão = um e-mail. A trava de status em server.js já recusa a
 *  segunda decisão do mesmo Kaizen; esta chave cobre o caso de a mesma
 *  decisão ser reprocessada dentro do processo (retry, clique duplo que
 *  passe pelas duas travas de tela). */
const jaEnviados = new Set();

/**
 * Envia o aviso da decisão ao autor da iniciativa.
 *
 * @param {string} momento   "aprovado" | "reprovado" | "alteracao"
 * @param {object} dados     dados REAIS do Kaizen, lidos do banco:
 *   idKaizen, idStatus, codigo, titulo, site, nomeAutor, emailAutor,
 *   nomeAprovador, statusPt, statusEn, dataDecisao, motivo
 * @returns {Promise<{enviado: boolean, motivo?: string}>} nunca lança:
 *   o e-mail é consequência da decisão, não pode derrubá-la.
 */
async function enviarEmailDecisao(momento, dados) {
  const chave = `${dados.idKaizen}:${dados.idStatus}:${momento}`;
  try {
    if (!dados.emailAutor) {
      console.warn(`[email] ${chave}: autor sem CD_EMAIL no MDM — nada enviado.`);
      return { enviado: false, motivo: "autor sem e-mail cadastrado" };
    }
    if (jaEnviados.has(chave)) {
      console.warn(`[email] ${chave}: já enviado nesta execução — ignorado.`);
      return { enviado: false, motivo: "já enviado" };
    }
    if (!TENANT_ID || !CLIENT_ID || !CLIENT_SECRET) {
      console.warn(
        `[email] ${chave}: envio não configurado — informe AZURE_TENANT_ID, ` +
        `AZURE_CLIENT_ID e AZURE_CLIENT_SECRET no app.yaml (permissão de ` +
        `aplicativo Mail.Send para ${REMETENTE}).`
      );
      return { enviado: false, motivo: "envio de e-mail não configurado" };
    }

    const { assunto, html } = montarMensagem(momento, {
      ...dados,
      dataPt: formatarData(dados.dataDecisao, "pt"),
      dataEn: formatarData(dados.dataDecisao, "en"),
    });

    const token = await tokenDoGraph();
    const resp = await fetch(`${GRAPH}/v1.0/users/${encodeURIComponent(REMETENTE)}/sendMail`, {
      method: "POST",
      headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        message: {
          subject: assunto,
          body: { contentType: "HTML", content: html },
          toRecipients: [{ emailAddress: { address: dados.emailAutor } }],
        },
        saveToSentItems: true,
      }),
    });
    if (!resp.ok) {
      const texto = await resp.text().catch(() => "");
      throw new Error(`Graph respondeu HTTP ${resp.status}: ${texto.slice(0, 300)}`);
    }

    jaEnviados.add(chave);
    console.log(`[email] ${chave}: enviado para ${dados.emailAutor} (${momento}).`);
    return { enviado: true };
  } catch (err) {
    // A decisão já está gravada: falha de e-mail vira log, nunca erro
    // de API — senão o aprovador refaria uma decisão que já valeu.
    console.error(`[email] ${chave}: falha no envio — ${err.message}`);
    return { enviado: false, motivo: err.message };
  }
}

module.exports = { enviarEmailDecisao, TEMPLATES, montarMensagem, formatarData };
