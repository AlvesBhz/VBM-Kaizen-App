/**
 * VBM Kaizen — aba "E-mail" do admin.html.
 *
 * O QUE ESTE ARQUIVO **NÃO** TEM, e é o ponto principal:
 *   servidor SMTP, porta, usuário, senha, token ou chave. Não há campo
 *   de credencial no formulário, nada é guardado em localStorage,
 *   sessionStorage ou cookie, e nenhuma resposta da API traz segredo
 *   algum. Quem autentica no serviço de e-mail é o servidor
 *   (email-smtp.js), com variáveis de ambiente que não saem do processo
 *   Node. Abrir o DevTools aqui não revela nada além do que a pessoa
 *   digitou.
 *
 *   Pelo mesmo motivo o REMETENTE não é um campo: ele é decidido no
 *   servidor. O endereço mostrado no cabeçalho vem de
 *   GET /api/email/config e serve só para a pessoa saber por qual caixa
 *   a mensagem vai sair — mandar outro valor daqui não muda nada, porque
 *   a rota ignora qualquer "de" no corpo da requisição.
 *
 * Anexos vão como multipart/form-data. Não use JSON com base64: inchar
 * o arquivo em 33% para caber numa string é o caminho mais curto para
 * estourar o limite de corpo da requisição com um anexo que caberia.
 */
(function () {
  var form = document.getElementById("emailForm");
  if (!form) return;

  var campoPara = document.getElementById("emailPara");
  var campoCc = document.getElementById("emailCc");
  var campoCco = document.getElementById("emailCco");
  var campoAssunto = document.getElementById("emailAssunto");
  var campoMensagem = document.getElementById("emailMensagem");
  var campoAnexos = document.getElementById("emailAnexos");
  var infoAnexos = document.getElementById("emailAnexosInfo");
  var btnEnviar = document.getElementById("emailEnviar");
  var btnLimpar = document.getElementById("emailLimpar");
  var status = document.getElementById("emailStatus");
  var rotuloRemetente = document.getElementById("emailRemetente");
  var avisoIndisponivel = document.getElementById("emailIndisponivel");

  // Espelho dos limites do servidor. Chegam por /api/email/config para
  // NÃO existirem em dois lugares: mudar o limite no app.yaml/servidor
  // muda a validação daqui sozinho. Os valores abaixo são só o que vale
  // enquanto a configuração não chega.
  var limites = {
    maxAnexos: 5, anexoBytes: 5 * 1024 * 1024, totalBytes: 15 * 1024 * 1024,
    maxDestinatarios: 50, assuntoChars: 200, corpoChars: 20000,
  };

  // O MESMO padrão do servidor (EMAIL_VALIDO em server.js). Aqui ele
  // serve para avisar antes de subir 10MB de anexo e ouvir "endereço
  // inválido"; a validação que VALE é sempre a do servidor, porque esta
  // roda no navegador de quem chama e pode ser contornada.
  var EMAIL_VALIDO = /^[^\s@<>",;:\\]+@[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$/;

  var enviando = false;

  function avisar(tipo, titulo, texto) {
    if (typeof showToast === "function") showToast(tipo, titulo, texto, tipo === "success" ? 4000 : 9000);
    else alert(texto);
  }

  function mostrarStatus(texto) {
    if (!status) return;
    if (!texto) { status.hidden = true; status.textContent = ""; return; }
    status.textContent = texto;
    status.hidden = false;
  }

  function mb(bytes) {
    return Math.round((bytes / (1024 * 1024)) * 10) / 10;
  }

  function listaDe(valor) {
    return String(valor || "").split(/[;,\r\n]+/).map(function (e) { return e.trim(); })
      .filter(function (e) { return e; });
  }

  /** Primeiro endereço inválido dos três campos, ou null. */
  function enderecoInvalido() {
    var todos = listaDe(campoPara.value).concat(listaDe(campoCc.value), listaDe(campoCco.value));
    for (var i = 0; i < todos.length; i++) {
      if (!EMAIL_VALIDO.test(todos[i])) return todos[i];
    }
    return null;
  }

  function marcarErro(campo) {
    campo.classList.add("form-control-error");
    if (campo.focus) campo.focus();
  }

  function limparMarcas() {
    [campoPara, campoCc, campoCco, campoAssunto, campoMensagem].forEach(function (c) {
      c.classList.remove("form-control-error");
    });
  }

  /** Valida o que dá para validar aqui. Devolve true quando pode enviar. */
  function validar() {
    limparMarcas();

    if (!listaDe(campoPara.value).length) {
      marcarErro(campoPara);
      avisar("warning", "Destinatário", "Informe pelo menos um destinatário.");
      return false;
    }
    var ruim = enderecoInvalido();
    if (ruim) {
      marcarErro(campoPara);
      avisar("warning", "E-mail inválido", 'O endereço "' + ruim + '" não é válido.');
      return false;
    }
    var total = listaDe(campoPara.value).length + listaDe(campoCc.value).length + listaDe(campoCco.value).length;
    if (total > limites.maxDestinatarios) {
      marcarErro(campoPara);
      avisar("warning", "Destinatários demais",
        "No máximo " + limites.maxDestinatarios + " destinatários por e-mail (somando Para, CC e CCO).");
      return false;
    }
    if (!campoAssunto.value.trim()) {
      marcarErro(campoAssunto);
      avisar("warning", "Assunto", "O assunto é obrigatório.");
      return false;
    }
    if (!campoMensagem.value.trim()) {
      marcarErro(campoMensagem);
      avisar("warning", "Mensagem", "Escreva a mensagem do e-mail.");
      return false;
    }
    if (campoMensagem.value.length > limites.corpoChars) {
      marcarErro(campoMensagem);
      avisar("warning", "Mensagem longa",
        "A mensagem deve ter no máximo " + limites.corpoChars + " caracteres.");
      return false;
    }

    var arquivos = campoAnexos.files || [];
    if (arquivos.length > limites.maxAnexos) {
      avisar("warning", "Anexos", "No máximo " + limites.maxAnexos + " anexos por e-mail.");
      return false;
    }
    var soma = 0;
    for (var i = 0; i < arquivos.length; i++) {
      soma += arquivos[i].size;
      if (arquivos[i].size > limites.anexoBytes) {
        avisar("warning", "Anexo grande demais",
          '"' + arquivos[i].name + '" tem ' + mb(arquivos[i].size) + "MB. O limite por arquivo é " +
          mb(limites.anexoBytes) + "MB.");
        return false;
      }
    }
    if (soma > limites.totalBytes) {
      avisar("warning", "Anexos grandes demais",
        "Os anexos somam " + mb(soma) + "MB e o limite é " + mb(limites.totalBytes) + "MB.");
      return false;
    }
    return true;
  }

  function resumirAnexos() {
    if (!infoAnexos) return;
    var arquivos = campoAnexos.files || [];
    if (!arquivos.length) {
      infoAnexos.textContent = "Até " + limites.maxAnexos + " arquivos, " +
        mb(limites.anexoBytes) + "MB cada, " + mb(limites.totalBytes) + "MB no total.";
      return;
    }
    var soma = 0;
    for (var i = 0; i < arquivos.length; i++) soma += arquivos[i].size;
    infoAnexos.textContent = arquivos.length + " arquivo(s) · " + mb(soma) + "MB";
  }

  function travar(travado) {
    enviando = travado;
    btnEnviar.disabled = travado;
    btnLimpar.disabled = travado;
    [campoPara, campoCc, campoCco, campoAssunto, campoMensagem, campoAnexos].forEach(function (c) {
      c.disabled = travado;
    });
  }

  function limparFormulario() {
    form.reset();
    limparMarcas();
    resumirAnexos();
  }

  campoAnexos.addEventListener("change", resumirAnexos);
  btnLimpar.addEventListener("click", function () { if (!enviando) limparFormulario(); });

  form.addEventListener("submit", function (evento) {
    evento.preventDefault();
    // REQUISITO 7 — "bloquear envios simultâneos". A trava daqui evita o
    // duplo clique; o servidor tem a própria, porque esta some com um F5.
    if (enviando) return;
    if (!validar()) return;

    var dados = new FormData();
    dados.append("para", campoPara.value);
    dados.append("cc", campoCc.value);
    dados.append("cco", campoCco.value);
    dados.append("assunto", campoAssunto.value);
    dados.append("mensagem", campoMensagem.value);
    var arquivos = campoAnexos.files || [];
    for (var i = 0; i < arquivos.length; i++) dados.append("anexos", arquivos[i]);

    travar(true);
    mostrarStatus("Enviando e-mail...");

    fetch("/api/email", { method: "POST", body: dados, cache: "no-store" })
      .then(function (resposta) {
        return resposta.json()
          .catch(function () { return {}; })
          .then(function (corpo) { return { ok: resposta.ok, corpo: corpo }; });
      })
      .then(function (r) {
        if (!r.ok) {
          // A frase vem pronta do servidor e já foi filtrada lá: não
          // traz host, porta nem conta de serviço.
          avisar("error", "E-mail não enviado",
            (r.corpo && r.corpo.error) || "Não foi possível enviar o e-mail.");
          return;
        }
        avisar("success", "E-mail enviado", (r.corpo && r.corpo.mensagem) || "Mensagem enviada com sucesso.");
        limparFormulario();
      })
      .catch(function () {
        // Aqui a requisição nem chegou (rede, proxy, app reiniciando).
        avisar("error", "E-mail não enviado",
          "Não foi possível falar com o servidor. Verifique a conexão e tente novamente.");
      })
      .then(function () {
        travar(false);
        mostrarStatus("");
      });
  });

  // Configuração: limites reais e endereço do remetente. Falhar aqui não
  // pode esconder o formulário — os limites padrão acima seguram a
  // validação e o servidor valida de novo de qualquer jeito.
  fetch("/api/email/config", { cache: "no-store" })
    .then(function (r) { return r.ok ? r.json() : null; })
    .then(function (cfg) {
      if (!cfg) return;
      if (cfg.limites) limites = cfg.limites;
      resumirAnexos();
      if (!cfg.disponivel) {
        if (avisoIndisponivel) avisoIndisponivel.hidden = false;
        form.hidden = true;
        return;
      }
      if (rotuloRemetente && cfg.remetente) {
        rotuloRemetente.textContent = "Enviando como " + cfg.remetente.endereco;
      }
    })
    .catch(function () { /* silêncio: o formulário continua utilizável */ });

  resumirAnexos();
})();
