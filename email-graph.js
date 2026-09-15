/**
 * VBM Kaizen — envio de e-mail pelo SERVIDOR via Microsoft Graph, com a
 * identidade de um SERVICE PRINCIPAL (fluxo client_credentials).
 *
 * POR QUE ESTE MÓDULO EXISTE, tendo email-smtp.js
 *   O caminho SMTP depende de "SMTP AUTH" (submissão autenticada por
 *   usuário e senha) estar habilitado no Exchange Online. A Microsoft
 *   aposentou a autenticação básica para esse canal; em boa parte dos
 *   locatários ele simplesmente não aceita mais senha, e nenhum ajuste
 *   do lado da aplicação muda isso. Confirme com o time de Exchange
 *   antes de contar com o SMTP.
 *
 *   Este módulo é o caminho suportado hoje: o app pede um token com a
 *   PRÓPRIA identidade (sem usuário logado, sem MSAL, sem navegador) e
 *   chama /users/<caixa>/sendMail. É o que faz o comunicado sair no
 *   cadastro de um Kaizen mesmo que ninguém esteja com a tela aberta.
 *
 * INTERFACE IDÊNTICA À DO email-smtp.js
 *   estaConfigurado(), remetente(), enviarEmail(), LIMITES. O server.js
 *   escolhe um dos dois e não precisa saber qual está em uso — ver
 *   transporteDeEmail() lá.
 *
 * CONFIGURAÇÃO (app.yaml — o segredo sempre por Secret Scope)
 *   GRAPH_TENANT_ID       diretório (tenant) do Entra
 *   GRAPH_CLIENT_ID       Application (client) ID do service principal
 *   GRAPH_CLIENT_SECRET   segredo do service principal
 *   GRAPH_REMETENTE       caixa de onde o e-mail sai, ex.:
 *                         PCI.Base.Metals@Vale.com
 *
 * O QUE PRECISA SER LIBERADO NO ENTRA (não dá para fazer por código)
 *   1. Permissão de APLICAÇÃO (não delegada) Mail.Send do Microsoft
 *      Graph, no app registration do service principal, COM consentimento
 *      do administrador.
 *   2. Mail.Send de aplicação vale, por padrão, para TODAS as caixas do
 *      locatário. Peça ao time de Exchange uma ApplicationAccessPolicy
 *      restringindo este service principal à caixa do programa — sem
 *      isso, a segurança da informação costuma (com razão) recusar.
 *
 * O SEGREDO
 *   Nunca sai deste processo: não é exportado, não entra em resposta de
 *   API e não aparece em log. O token que ele gera também não — fica em
 *   memória, com prazo, e é renovado sozinho.
 */

const TENANT = String(process.env.GRAPH_TENANT_ID || "").trim();
const CLIENT_ID = String(process.env.GRAPH_CLIENT_ID || "").trim();
const CLIENT_SECRET = String(process.env.GRAPH_CLIENT_SECRET || "");
const CAIXA = String(process.env.GRAPH_REMETENTE || process.env.KAIZEN_EMAIL_REMETENTE || "").trim();
const NOME_EXIBIDO = String(process.env.GRAPH_REMETENTE_NOME || "Programa Kaizen").trim();

// Endereços da Microsoft. São variáveis SÓ para o teste automatizado
// conseguir apontar para um Graph falso — em produção não declare
// nenhuma das duas e os padrões abaixo valem.
const AUTORIDADE = String(process.env.GRAPH_AUTH_URL || "https://login.microsoftonline.com").replace(/\/+$/, "");
const GRAPH = String(process.env.GRAPH_API_URL || "https://graph.microsoft.com/v1.0").replace(/\/+$/, "");

// sendMail simples aceita um corpo de requisição de poucos MB (anexo vai
// em base64 dentro do JSON, o que já infla ~33%). Acima disso o caminho
// correto seria a sessão de upload em rascunho, que é bem mais código
// para um caso que este sistema não tem: os comunicados automáticos não
// levam anexo nenhum. Então o limite aqui é menor que o do SMTP, e
// explícito.
const LIMITES = {
  maxAnexos: 5,
  anexoBytes: 3 * 1024 * 1024,
  totalBytes: 3 * 1024 * 1024,
  maxDestinatarios: 50,
  assuntoChars: 200,
  corpoChars: 20000,
};

function estaConfigurado() {
  return Boolean(TENANT && CLIENT_ID && CLIENT_SECRET && CAIXA);
}

function remetente() {
  return { endereco: CAIXA, nome: NOME_EXIBIDO };
}

class ErroDeEnvio extends Error {
  constructor(codigo, publico, status, original) {
    super(publico);
    this.name = "ErroDeEnvio";
    this.codigo = codigo;
    this.publico = publico;
    this.status = status || 502;
    this.original = original || null;
  }
}

// ------------------------------------------------------------------
// Token
// ------------------------------------------------------------------

let tokenEmCache = null;
let tokenExpiraEm = 0;

/** Token de aplicação, renovado sozinho.
 *
 *  Guardado em memória com 60 s de folga antes do vencimento: pedir um
 *  token novo a cada e-mail seria uma ida a mais à rede por mensagem e
 *  conta para o limite de autenticações do Entra. */
async function obterToken() {
  const agora = Date.now();
  if (tokenEmCache && agora < tokenExpiraEm) return tokenEmCache;

  const corpo = new URLSearchParams({
    client_id: CLIENT_ID,
    client_secret: CLIENT_SECRET,
    scope: "https://graph.microsoft.com/.default",
    grant_type: "client_credentials",
  });

  let resp;
  try {
    resp = await fetch(`${AUTORIDADE}/${encodeURIComponent(TENANT)}/oauth2/v2.0/token`, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: corpo,
    });
  } catch (err) {
    throw new ErroDeEnvio("conexao", "O serviço de e-mail não respondeu. Tente novamente em alguns minutos.", 504, err);
  }

  const dados = await resp.json().catch(() => ({}));
  if (!resp.ok || !dados.access_token) {
    // O corpo do erro do Entra traz o código AADSTS, que diz exatamente
    // o que está errado (segredo vencido, ID errado, consentimento
    // faltando). Vai para o LOG, não para a tela.
    console.error(
      `[email-graph] falha ao obter token (HTTP ${resp.status}): ` +
      `${dados.error || ""} ${String(dados.error_description || "").split("\n")[0]}`
    );
    throw new ErroDeEnvio(
      "autenticacao",
      "Não foi possível autenticar no serviço de e-mail. A área de TI precisa revisar a credencial do aplicativo.",
      502
    );
  }

  tokenEmCache = dados.access_token;
  tokenExpiraEm = agora + Math.max(0, (Number(dados.expires_in) || 3600) - 60) * 1000;
  return tokenEmCache;
}

// ------------------------------------------------------------------
// Envio
// ------------------------------------------------------------------

function semQuebraDeLinha(texto) {
  return String(texto == null ? "" : texto).replace(/[\r\n]+/g, " ").trim();
}

function paraGraph(lista) {
  return (lista || []).map((e) => ({ emailAddress: { address: e } }));
}

/** Traduz a resposta do Graph para uma frase que pode ir à tela.
 *
 *  O Graph responde com um código nominal ("ErrorAccessDenied",
 *  "ErrorInvalidRecipients"), e é por ele que decidimos — nunca pela
 *  mensagem em inglês, que muda sem aviso. O texto original fica no log. */
function traduzirErro(status, corpo) {
  const erro = (corpo && corpo.error) || {};
  const codigo = String(erro.code || "");
  const detalhe = String(erro.message || "").slice(0, 300);
  console.error(`[email-graph] sendMail recusado (HTTP ${status}): ${codigo} — ${detalhe}`);

  if (status === 401) {
    return new ErroDeEnvio("autenticacao",
      "Não foi possível autenticar no serviço de e-mail. A área de TI precisa revisar a credencial do aplicativo.", 502);
  }
  if (status === 403 || /AccessDenied|Authorization/i.test(codigo)) {
    // A causa quase sempre é uma destas duas, e as duas são liberação no
    // Entra/Exchange — por isso a frase manda a pessoa para TI em vez de
    // sugerir que ela errou algo.
    return new ErroDeEnvio("autorizacao",
      "O aplicativo não tem permissão para enviar por esta caixa. A área de TI precisa liberar o envio.", 502);
  }
  if (status === 404 || /MailboxNotEnabled|ResourceNotFound/i.test(codigo)) {
    return new ErroDeEnvio("remetente",
      "A caixa de envio configurada não foi encontrada. Procure a área de TI.", 502);
  }
  if (/InvalidRecipients|ErrorInvalidUser/i.test(codigo)) {
    return new ErroDeEnvio("destinatario",
      "Um ou mais destinatários foram recusados pelo serviço de e-mail. Confira os endereços informados.", 400);
  }
  if (status === 429 || /QuotaExceeded|SubmissionQuota|TooManyRequests/i.test(codigo)) {
    return new ErroDeEnvio("limite",
      "O limite de envios da conta foi atingido. Aguarde alguns minutos e tente novamente.", 429);
  }
  if (status === 413 || /RequestBodyTooLarge|MessageSizeExceeded/i.test(codigo)) {
    return new ErroDeEnvio("anexo",
      "A mensagem ficou grande demais com os anexos. Reduza os arquivos e tente novamente.", 400);
  }
  return new ErroDeEnvio("falha", "Não foi possível enviar o e-mail.", 502);
}

/**
 * Mesma assinatura de email-smtp.enviarEmail.
 *
 * `de` também NÃO é parâmetro aqui: a caixa é a configurada no ambiente.
 * O Graph, aliás, recusaria de qualquer jeito uma caixa para a qual o
 * service principal não tenha permissão — mas a trava não deve depender
 * disso.
 */
async function enviarEmail(msg) {
  if (!estaConfigurado()) {
    throw new ErroDeEnvio("indisponivel",
      "O envio de e-mail não está configurado nesta aplicação. Procure a área de TI.", 503);
  }

  const anexos = (msg.anexos || []).map((a) => ({
    "@odata.type": "#microsoft.graph.fileAttachment",
    name: semQuebraDeLinha(a.nomeArquivo).split(/[\\/]/).pop() || "anexo",
    contentType: a.tipo || "application/octet-stream",
    contentBytes: Buffer.from(a.conteudo).toString("base64"),
  }));

  const mensagem = {
    subject: semQuebraDeLinha(msg.assunto),
    body: { contentType: "HTML", content: msg.html || msg.texto || "" },
    toRecipients: paraGraph(msg.para),
  };
  if (msg.cc && msg.cc.length) mensagem.ccRecipients = paraGraph(msg.cc);
  if (msg.cco && msg.cco.length) mensagem.bccRecipients = paraGraph(msg.cco);
  if (msg.responderPara) mensagem.replyTo = paraGraph([msg.responderPara]);
  if (anexos.length) mensagem.attachments = anexos;

  const token = await obterToken();

  let resp;
  try {
    resp = await fetch(`${GRAPH}/users/${encodeURIComponent(CAIXA)}/sendMail`, {
      method: "POST",
      headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
      body: JSON.stringify({ message: mensagem, saveToSentItems: true }),
    });
  } catch (err) {
    console.error("[email-graph] falha de rede no sendMail:", err && err.message);
    throw new ErroDeEnvio("conexao", "O serviço de e-mail não respondeu. Tente novamente em alguns minutos.", 504, err);
  }

  if (resp.status === 401) {
    // Token pode ter sido revogado antes de vencer. Descarta o cache
    // para a próxima tentativa não repetir o token morto.
    tokenEmCache = null;
    tokenExpiraEm = 0;
  }
  if (!resp.ok) {
    const corpo = await resp.json().catch(() => ({}));
    throw traduzirErro(resp.status, corpo);
  }

  // sendMail devolve 202 sem corpo: não há Message-ID para guardar.
  return {
    messageId: "",
    aceitos: [].concat(msg.para || [], msg.cc || [], msg.cco || []),
    recusados: [],
  };
}

module.exports = { estaConfigurado, remetente, enviarEmail, LIMITES, ErroDeEnvio };
