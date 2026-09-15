/**
 * VBM Kaizen — envio de e-mail pelo SERVIDOR, com credencial que nunca
 * sai do processo Node.
 *
 * POR QUE ESTE MÓDULO EXISTE
 *   O outro caminho de e-mail do projeto (email-kaizen.js + a tela
 *   js/envio-email.js) monta a mensagem aqui e ENTREGA NO NAVEGADOR, que
 *   chama o Microsoft Graph com o token delegado de quem está logado.
 *   Aquele desenho não tem credencial nenhuma — mas depende de liberação
 *   no Entra/Exchange e só serve para os comunicados automáticos.
 *
 *   Este módulo é o outro caminho: a mensagem é digitada por uma pessoa e
 *   sai por uma CONTA DE SERVIÇO SMTP. Usuário e senha dessa conta ficam
 *   só aqui dentro, em variáveis de ambiente. Nada deste arquivo é
 *   servido ao navegador, nada daqui vai para uma resposta de API, e o
 *   módulo não exporta os valores lidos do ambiente — só respostas
 *   derivadas deles (ver `remetente()`, que devolve o endereço de origem,
 *   nunca a senha).
 *
 * CONFIGURAÇÃO (app.yaml — sempre por Secret Scope, nunca em texto puro)
 *   SMTP_HOST       ex.: smtp.office365.com
 *   SMTP_PORT       587 (STARTTLS, padrão) ou 465 (TLS direto)
 *   SMTP_USER       conta de serviço que autentica
 *   SMTP_PASSWORD   senha/app password da conta de serviço
 *   SMTP_FROM       endereço que aparece no "De:". Padrão: SMTP_USER.
 *                   Enviar com um "De:" diferente da conta autenticada
 *                   exige "Enviar Como" no Exchange — sem isso o próprio
 *                   servidor recusa (é o que impede forjar remetente).
 *   SMTP_FROM_NOME  nome exibido. Padrão: "Programa Kaizen".
 *
 * TLS — sem opção de desligar, de propósito
 *   Na 587 vai `requireTLS`: se o servidor não oferecer STARTTLS a
 *   conexão é abortada, em vez de mandar a senha em claro. Na 465 o TLS
 *   é a própria conexão. Em nenhum dos dois há caminho para
 *   `rejectUnauthorized: false` — uma opção dessas transformaria
 *   qualquer intermediário na rede em dono da credencial, e é justamente
 *   o que o REQUISITO 1 proíbe. Certificado inválido é problema a
 *   resolver no servidor de e-mail, não a ignorar aqui.
 *
 * O QUE NUNCA APARECE PARA QUEM CHAMA
 *   `traduzirErro()` devolve frase pronta para a tela a partir do CÓDIGO
 *   do erro. A mensagem original do nodemailer — que costuma trazer host,
 *   porta, usuário e às vezes o diálogo SMTP inteiro — fica no
 *   console.error do servidor. É o REQUISITO 5: "não exibir detalhes
 *   internos da infraestrutura".
 */

const nodemailer = require("nodemailer");

const HOST = String(process.env.SMTP_HOST || "").trim();
const PORTA = Number(process.env.SMTP_PORT || 587);
const USUARIO = String(process.env.SMTP_USER || "").trim();
const SENHA = String(process.env.SMTP_PASSWORD || "");
const DE_ENDERECO = String(process.env.SMTP_FROM || USUARIO).trim();
const DE_NOME = String(process.env.SMTP_FROM_NOME || "Programa Kaizen").trim();

// Limites do que o servidor aceita receber. Ficam aqui, e não na rota,
// porque a tela também precisa deles (o formulário avisa antes de subir
// 20MB para ouvir "não") — a rota os expõe como NÚMEROS, que não são
// segredo, ao contrário de tudo o mais deste arquivo.
const LIMITES = {
  maxAnexos: 5,
  anexoBytes: 5 * 1024 * 1024, //  5MB por arquivo
  totalBytes: 15 * 1024 * 1024, // 15MB somando tudo
  maxDestinatarios: 50, // para + cc + cco
  assuntoChars: 200,
  corpoChars: 20000,
};

/** Está tudo configurado para enviar? A rota usa isto para responder
 *  "recurso indisponível" em vez de estourar na primeira conexão. */
function estaConfigurado() {
  return Boolean(HOST && USUARIO && SENHA && DE_ENDERECO);
}

/** Endereço e nome que vão no "De:". Público de propósito: a tela mostra
 *  "Enviando como ..." para ninguém digitar achando que sai pela própria
 *  caixa. Note que não há função equivalente para a senha. */
function remetente() {
  return { endereco: DE_ENDERECO, nome: DE_NOME };
}

// ------------------------------------------------------------------
// Transporte
// ------------------------------------------------------------------

let transporte = null;

/** Um transporte só, criado na primeira necessidade e reusado.
 *
 *  `pool: true` mantém a conexão autenticada aberta entre envios: sem
 *  isso, cada e-mail refaz handshake TLS + AUTH, o que é lento e, no
 *  Office 365, conta para o limite de autenticações por minuto. */
function obterTransporte() {
  if (transporte) return transporte;
  const seguro = PORTA === 465; // 465 = TLS desde o primeiro byte
  transporte = nodemailer.createTransport({
    host: HOST,
    port: PORTA,
    secure: seguro,
    // Na 587 o TLS é negociado por STARTTLS. `requireTLS` torna a
    // negociação OBRIGATÓRIA — ver a nota "TLS" no topo.
    requireTLS: !seguro,
    auth: { user: USUARIO, pass: SENHA },
    tls: { minVersion: "TLSv1.2" },
    pool: true,
    maxConnections: 2,
    // Um servidor que não responde não pode segurar a requisição da
    // pessoa até o timeout do navegador.
    connectionTimeout: 10000,
    greetingTimeout: 10000,
    socketTimeout: 30000,
    // logger/debug ficam desligados: o log de depuração do nodemailer
    // imprime o diálogo SMTP, AUTH incluído.
    logger: false,
    debug: false,
  });
  return transporte;
}

// ------------------------------------------------------------------
// Erros
// ------------------------------------------------------------------

/** Erro já pronto para virar resposta HTTP: `codigo` para a tela
 *  diferenciar os casos, `status` para a rota, `publico` para exibir. */
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

/** Converte a falha do nodemailer em uma frase que pode aparecer na tela.
 *
 *  Os códigos vêm do próprio nodemailer (EAUTH, ECONNECTION, ...) e o
 *  `responseCode` é o número SMTP devolvido pelo servidor. Quando nada
 *  casa, cai numa frase genérica — nunca em `err.message`, que carrega
 *  host, porta e usuário. */
function traduzirErro(err) {
  const codigo = String(err && err.code ? err.code : "");
  const smtp = Number(err && err.responseCode) || 0;

  if (codigo === "EAUTH" || smtp === 535 || smtp === 534) {
    return new ErroDeEnvio(
      "autenticacao",
      "Não foi possível autenticar no serviço de e-mail. A área de TI precisa revisar a conta de envio.",
      502,
      err
    );
  }
  if (codigo === "ECONNECTION" || codigo === "ESOCKET" || codigo === "ETIMEDOUT" || codigo === "EDNS") {
    return new ErroDeEnvio(
      "conexao",
      "O serviço de e-mail não respondeu. Tente novamente em alguns minutos.",
      504,
      err
    );
  }
  // 550/553 em EENVELOPE = endereço recusado pelo servidor. É erro de
  // quem digitou, então volta como 400: refazer o envio com o mesmo
  // endereço não vai adiantar.
  if (codigo === "EENVELOPE" || smtp === 550 || smtp === 553) {
    return new ErroDeEnvio(
      "destinatario",
      "Um ou mais destinatários foram recusados pelo serviço de e-mail. Confira os endereços informados.",
      400,
      err
    );
  }
  if (smtp === 452 || smtp === 552 || /quota|rate limit|too many/i.test(String(err && err.response))) {
    return new ErroDeEnvio(
      "limite",
      "O limite de envios da conta foi atingido. Aguarde alguns minutos e tente novamente.",
      429,
      err
    );
  }
  if (codigo === "EMESSAGE" || smtp === 554) {
    return new ErroDeEnvio(
      "mensagem",
      "O serviço de e-mail recusou a mensagem. Revise o assunto, o texto e os anexos.",
      400,
      err
    );
  }
  return new ErroDeEnvio("falha", "Não foi possível enviar o e-mail.", 502, err);
}

// ------------------------------------------------------------------
// Envio
// ------------------------------------------------------------------

/** Cabeçalho de e-mail é delimitado por CRLF: um \r ou \n dentro do
 *  assunto ou de um nome de arquivo permitiria ENXERTAR cabeçalhos
 *  (um Bcc a mais, outro Content-Type). O nodemailer codifica o assunto,
 *  mas a limpeza é feita aqui do mesmo jeito — a defesa não deve depender
 *  do comportamento interno de uma dependência. */
function semQuebraDeLinha(texto) {
  return String(texto == null ? "" : texto).replace(/[\r\n]+/g, " ").trim();
}

/**
 * Envia a mensagem.
 *
 * Repare no que NÃO é parâmetro: `de`. O remetente é sempre o configurado
 * no ambiente. Se viesse do chamador, bastaria adulterar o corpo da
 * requisição para mandar e-mail em nome de outra pessoa com a credencial
 * da empresa — o "parameter tampering" do REQUISITO 6.
 *
 * @param {object} msg
 * @param {string[]} msg.para        destinatários (já validados pela rota)
 * @param {string[]} [msg.cc]
 * @param {string[]} [msg.cco]
 * @param {string}   msg.assunto
 * @param {string}   [msg.html]
 * @param {string}   [msg.texto]
 * @param {Array}    [msg.anexos]    [{ nomeArquivo, conteudo: Buffer, tipo }]
 * @param {string}   [msg.responderPara]  e-mail de quem escreveu, para o
 *   Reply-To: a resposta vai para a pessoa, e o "De:" continua sendo o da
 *   conta de serviço. É o jeito de atribuir a mensagem sem forjar origem.
 * @returns {Promise<{messageId: string, aceitos: string[], recusados: string[]}>}
 * @throws {ErroDeEnvio}
 */
async function enviarEmail(msg) {
  if (!estaConfigurado()) {
    throw new ErroDeEnvio(
      "indisponivel",
      "O envio de e-mail não está configurado nesta aplicação. Procure a área de TI.",
      503
    );
  }

  const anexos = (msg.anexos || []).map((a) => ({
    // basename à mão: um nome como "../../x" viraria caminho no cliente
    // de quem recebe.
    filename: semQuebraDeLinha(a.nomeArquivo).split(/[\\/]/).pop() || "anexo",
    content: a.conteudo,
    contentType: a.tipo || "application/octet-stream",
  }));

  const envelope = {
    from: { name: DE_NOME, address: DE_ENDERECO },
    to: msg.para,
    cc: msg.cc && msg.cc.length ? msg.cc : undefined,
    bcc: msg.cco && msg.cco.length ? msg.cco : undefined,
    replyTo: msg.responderPara || undefined,
    subject: semQuebraDeLinha(msg.assunto),
    text: msg.texto || undefined,
    html: msg.html || undefined,
    attachments: anexos.length ? anexos : undefined,
  };

  try {
    const info = await obterTransporte().sendMail(envelope);
    return {
      messageId: info.messageId || "",
      aceitos: info.accepted || [],
      recusados: info.rejected || [],
    };
  } catch (err) {
    // O erro CRU só existe aqui e no log do servidor.
    console.error("[email-smtp] falha no envio:", err && err.message);
    throw traduzirErro(err);
  }
}

module.exports = { estaConfigurado, remetente, enviarEmail, LIMITES, ErroDeEnvio };
