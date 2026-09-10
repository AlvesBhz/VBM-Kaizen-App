/**
 * VBM Kaizen — e-mails automáticos das decisões de aprovação.
 *
 * Usado por server.js (registrarDecisao) DEPOIS que a decisão já está
 * gravada: aprovar, reprovar e solicitar alteração avisam o autor da
 * iniciativa por e-mail.
 *
 * O QUE ESTE MÓDULO FAZ (e o que não faz)
 *   Aqui ficam só os TEMPLATES e a montagem da mensagem com os dados
 *   reais lidos do banco. O envio em si acontece no navegador
 *   (js/envio-email.js), com o token DELEGADO do aprovador logado —
 *   é o perfil dele que autentica no Microsoft Graph, não uma
 *   identidade de aplicação. Por isso não há client secret aqui.
 *
 *   Montar no servidor e enviar no navegador mantém o conteúdo fora do
 *   alcance da tela: o corpo do e-mail é gerado a partir da linha do
 *   banco, não do que foi digitado.
 *
 * CAIXA REMETENTE
 *   PCI.Base.Metals@Vale.com (KAIZEN_EMAIL_REMETENTE sobrescreve). Quem
 *   decide precisa ter "Enviar Como" (ou "Enviar em Nome De") nessa
 *   caixa compartilhada, e o app registration do MSAL precisa do escopo
 *   delegado Mail.Send.Shared — ver js/msal-config.js.
 *
 * IDIOMA
 *   Não existe idioma cadastrado por pessoa: kzn_mdm_hierarquia não tem
 *   coluna de idioma e kzn_pedravisaoconsolidada também não. Por isso
 *   cada e-mail sai BILÍNGUE — o corpo em português e, abaixo, o mesmo
 *   conteúdo em inglês —, o que não depende do idioma da tela de quem
 *   decidiu nem de mudança de banco. O nome do status vem de
 *   kzn_status nos dois idiomas (ID_IDIOMA 1 e 2), não de texto fixo.
 */

const REMETENTE = process.env.KAIZEN_EMAIL_REMETENTE || "PCI.Base.Metals@Vale.com";
const APP_URL = (process.env.KAIZEN_APP_URL ||
  "https://kaizen-7405608945147182.2.azure.databricksapps.com").replace(/\/+$/, "");

const URL_APROVACAO = `${APP_URL}/aprovacao.html`;
const URL_BIBLIOTECA = `${APP_URL}/biblioteca.html`;

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

  // Único fluxo com o link da Biblioteca: é lá que o autor corrige o
  // Kaizen e o reenvia. Os outros dois não pedem ação de edição.
  alteracao: {
    pt: (d) => ({
      assunto: "[Kaizen] Ajustes solicitados em sua iniciativa",
      linhas: [
        `Olá, ${d.nomeAutor}.`,
        "Seu Kaizen foi analisado e necessita de ajustes antes de uma nova avaliação.",
        { campos: [["codigo", d.codigo], ["titulo", d.titulo], ["site", d.site],
                   ["aprovador", d.nomeAprovador], ["data", d.dataPt]] },
        "Comentários do aprovador:",
        { destaque: d.motivo },
        "Para realizar as correções, acesse a Biblioteca Kaizen:",
        { link: URL_BIBLIOTECA },
        "Após atualizar as informações necessárias, envie novamente para aprovação.",
      ],
    }),
    en: (d) => ({
      assunto: "[Kaizen] Changes requested in your initiative",
      linhas: [
        `Hello, ${d.nomeAutor}.`,
        "Your Kaizen has been reviewed and needs changes before a new evaluation.",
        { campos: [["codigo", d.codigo], ["titulo", d.titulo], ["site", d.site],
                   ["aprovador", d.nomeAprovador], ["data", d.dataEn]] },
        "Approver comments:",
        { destaque: d.motivo },
        "To make the corrections, access the Kaizen Library:",
        { link: URL_BIBLIOTECA },
        "After updating the required information, submit it for approval again.",
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
// Montagem do aviso
// ------------------------------------------------------------------

/**
 * Monta o aviso da decisão para o autor da iniciativa.
 *
 * @param {string} momento   "aprovado" | "reprovado" | "alteracao"
 * @param {object} dados     dados REAIS do Kaizen, lidos do banco:
 *   idKaizen, idStatus, codigo, titulo, site, nomeAutor, emailAutor,
 *   nomeAprovador, statusPt, statusEn, dataDecisao, motivo
 * @returns {{chave, de, para, assunto, html}|{erro}} o objeto que a tela
 *   entrega ao Graph; `erro` quando não há a quem enviar.
 */
function montarAvisoDecisao(momento, dados) {
  if (!dados.emailAutor) {
    return { erro: "autor sem e-mail cadastrado no MDM" };
  }
  const { assunto, html } = montarMensagem(momento, {
    ...dados,
    dataPt: formatarData(dados.dataDecisao, "pt"),
    dataEn: formatarData(dados.dataDecisao, "en"),
  });
  return {
    // Identifica a decisão: a tela usa para não enviar duas vezes o
    // mesmo aviso e o servidor usa no log.
    chave: `${dados.idKaizen}:${dados.idStatus}:${momento}`,
    de: REMETENTE,
    para: dados.emailAutor,
    assunto,
    html,
  };
}

module.exports = { montarAvisoDecisao, TEMPLATES, montarMensagem, formatarData, REMETENTE };
