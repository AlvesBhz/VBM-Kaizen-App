/**
 * VBM Kaizen — envio dos comunicados do Kaizen pelo Microsoft Graph.
 *
 * Cobre o cadastro (equipe + aprovador) e as três decisões.
 *
 * Quem envia é o NAVEGADOR, com o token delegado de quem está logado:
 * é o perfil dele que autentica, e a mensagem sai pela caixa
 * compartilhada PCI.Base.Metals@Vale.com (ele precisa ter "Enviar Como"
 * nessa caixa). Não há client secret nem identidade de aplicação em
 * nenhum ponto — ver js/msal-config.js.
 *
 * O CONTEÚDO NÃO É MONTADO AQUI. O servidor devolve os comunicados
 * prontos (destinatários, assunto e corpo) na resposta, gerados a
 * partir da linha já gravada no banco (email-kaizen.js). Esta camada só
 * entrega ao Graph e informa o resultado de volta, para o log ficar no
 * servidor como o dos demais fluxos.
 *
 * ESTE CAMINHO VIROU O PLANO B. Havendo SMTP configurado (ver
 * email-smtp.js), quem entrega é o SERVIDOR, e os comunicados chegam
 * aqui marcados com `enviadoPeloServidor` — este arquivo os ignora.
 * O caminho do Graph continua inteiro para dois casos: instalação sem
 * SMTP configurado, e comunicado que o servidor tentou e não conseguiu
 * entregar (aí vem `motivoServidor` e o corpo junto).
 */
(function () {
  'use strict';

  var GRAPH = 'https://graph.microsoft.com/v1.0';

  /* Escopos por DESTINO, e não um só para os dois casos.
       /me/sendMail            -> Mail.Send        (enviar como eu)
       /users/<caixa>/sendMail -> Mail.Send.Shared (enviar por outra caixa)
     Antes ia sempre Mail.Send.Shared. No envio pela própria caixa isso
     pede uma permissão maior do que a necessária — e se o locatário não
     tiver consentido justamente essa, o token não sai e o e-mail morre
     ali. Por isso há também a segunda tentativa com o outro escopo. */
  var ESCOPO_PROPRIA_CAIXA = ['Mail.Send'];
  var ESCOPO_CAIXA_COMPARTILHADA = ['Mail.Send.Shared'];
  var enviados = {};   // chave da decisão -> true; evita disparo repetido

  function escoposDe(aviso) {
    return aviso && aviso.de ? ESCOPO_CAIXA_COMPARTILHADA : ESCOPO_PROPRIA_CAIXA;
  }
  function escoposAlternativos(escopos) {
    return escopos === ESCOPO_PROPRIA_CAIXA ? ESCOPO_CAIXA_COMPARTILHADA : ESCOPO_PROPRIA_CAIXA;
  }

  function destinatarios(para) {
    return Array.isArray(para) ? para : [para];
  }

  function avisarServidor(idKaizen, chave, ok, motivo, para) {
    // Falha aqui não afeta nada na tela: é só o registro do envio.
    fetch('/api/kaizens/' + encodeURIComponent(idKaizen) + '/aviso', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        chave: chave, enviado: !!ok, motivo: motivo || null,
        // Vão junto para GET /api/email/status conseguir mostrar o que
        // aconteceu no navegador — quem opera o sistema não tem acesso
        // ao log do app, e sem isso o envio pela tela é uma caixa-preta.
        para: Array.isArray(para) ? para : (para ? [para] : []),
        origem: 'tela (Graph do usuário logado)'
      })
    }).catch(function () { /* silencioso de propósito */ });
  }

  /** Token do Graph para o usuário logado, SEM popup.
   *
   *  Silencioso de propósito: o envio acontece DEPOIS de salvar o
   *  Kaizen, ou seja, depois de um await — e aí o navegador já não
   *  considera a ação como vinda do clique, então um popup aberto aqui é
   *  bloqueado. Foi por isso que o consentimento nunca era concluído.
   *  Quem abre popup é o botão da faixa de autorização (autorizarAgora),
   *  que é clique de verdade. */
  function obterTokenSilencioso(app, escopos) {
    var conta = app.getActiveAccount() || app.getAllAccounts()[0];
    if (!conta) return Promise.reject(new Error('sem sessão Microsoft nesta página'));
    return app.acquireTokenSilent({ scopes: escopos, account: conta })
      .catch(function () {
        // Consentimento pode existir para o outro escopo.
        return app.acquireTokenSilent({ scopes: escoposAlternativos(escopos), account: conta });
      })
      .then(function (r) { return r.accessToken; });
  }

  // ------------------------------------------------------------------
  // Autorização, uma vez por sessão
  // ------------------------------------------------------------------

  var faixa = null;

  /** Faixa discreta no rodapé pedindo a autorização. Montada em
   *  JavaScript de propósito: assim vale nas duas telas que enviam
   *  e-mail sem precisar mexer no HTML de nenhuma delas. */
  function mostrarFaixaAutorizacao(motivo) {
    if (faixa) return;
    faixa = document.createElement('div');
    faixa.id = 'faixaAutorizacaoEmail';
    faixa.style.cssText =
      'position:fixed;left:50%;transform:translateX(-50%);bottom:calc(16px + env(safe-area-inset-bottom,0px));' +
      'z-index:9998;max-width:min(560px,calc(100vw - 32px));background:#fff;color:#222;' +
      'border:1px solid #e0e0e0;border-left:4px solid #c2770e;border-radius:10px;' +
      'box-shadow:0 10px 30px rgba(0,0,0,.14);padding:.85rem 1rem;display:flex;gap:.75rem;' +
      'align-items:center;flex-wrap:wrap;font-size:.82rem;line-height:1.45;';
    var texto = document.createElement('div');
    texto.style.cssText = 'flex:1 1 260px;min-width:0;';
    texto.innerHTML =
      '<strong>Autorize o envio de e-mails</strong><br>' +
      'Os comunicados do Kaizen saem pela sua caixa. É uma vez por sessão.';
    var botao = document.createElement('button');
    botao.type = 'button';
    botao.textContent = 'Autorizar';
    botao.className = 'btn btn-primary btn-sm';
    botao.style.cssText = 'flex:0 0 auto;';
    var fechar = document.createElement('button');
    fechar.type = 'button';
    fechar.setAttribute('aria-label', 'Fechar');
    fechar.textContent = '✕';
    fechar.style.cssText = 'flex:0 0 auto;background:none;border:none;color:#888;cursor:pointer;font-size:1rem;';
    fechar.addEventListener('click', esconderFaixa);
    botao.addEventListener('click', function () {
      botao.disabled = true;
      botao.textContent = 'Autorizando...';
      autorizarAgora()
        .then(function () {
          esconderFaixa();
          if (typeof showToast === 'function') {
            showToast('success', 'Autorizado', 'Os comunicados do Kaizen já podem ser enviados.');
          }
        })
        .catch(function (err) {
          botao.disabled = false;
          botao.textContent = 'Autorizar';
          if (typeof showToast === 'function') {
            showToast('error', 'Não foi possível autorizar',
              'Verifique se o navegador bloqueou a janela do Microsoft. Motivo: ' + err.message, 12000);
          }
        });
    });
    faixa.appendChild(texto);
    faixa.appendChild(botao);
    faixa.appendChild(fechar);
    document.body.appendChild(faixa);
    console.info('[VBMEmail] autorizacao pendente:', motivo || '(sem detalhe)');
  }

  function esconderFaixa() {
    if (faixa && faixa.parentNode) faixa.parentNode.removeChild(faixa);
    faixa = null;
  }

  /** Popup de login/consentimento. Só é chamada a partir de um CLIQUE. */
  function autorizarAgora() {
    return window.VBMMsal.obterInstancia().then(function (app) {
      var conta = app.getActiveAccount() || app.getAllAccounts()[0];
      var pedir = function (escopos) {
        return conta
          ? app.acquireTokenPopup({ scopes: escopos, account: conta })
          : app.loginPopup({ scopes: escopos });
      };
      return pedir(ESCOPO_PROPRIA_CAIXA)
        .catch(function () { return pedir(ESCOPO_CAIXA_COMPARTILHADA); })
        .then(function (r) {
          if (r && r.account) app.setActiveAccount(r.account);
          return r;
        });
    });
  }

  /** Na carga da página: tenta obter o token em silêncio. Conseguindo,
   *  ninguém vê nada. Falhando, mostra a faixa — que é o único jeito de
   *  o consentimento acontecer dentro de um clique de verdade.
   *
   *  Rodar aqui, e não na hora de enviar, é o ponto todo: na hora de
   *  enviar já é tarde, o popup seria bloqueado e o comunicado se
   *  perderia depois de o Kaizen já estar salvo. */
  function prepararAutorizacao() {
    if (!window.VBMMsal || !window.VBMMsal.estaConfigurado()) return;
    window.VBMMsal.obterInstancia()
      .then(function (app) { return obterTokenSilencioso(app, ESCOPO_PROPRIA_CAIXA); })
      .then(function () { console.info('[VBMEmail] autorizacao de e-mail ja concedida nesta sessao.'); })
      .catch(function (err) { mostrarFaixaAutorizacao(err && err.message); });
  }

  /**
   * @param {object} aviso  { chave, de, para, assunto, html } vindo da
   *                        resposta da decisão. `erro` no lugar disso
   *                        significa que não há a quem enviar.
   * @param {number} idKaizen
   */
  function enviar(aviso, idKaizen) {
    if (!aviso || aviso.erro) {
      if (aviso && aviso.erro) avisarServidor(idKaizen, null, false, aviso.erro, []);
      return Promise.resolve({ enviado: false, motivo: (aviso && aviso.erro) || 'sem aviso' });
    }
    // O SERVIDOR já entregou este comunicado por SMTP. Nada a fazer
    // aqui: repetir o envio seria um segundo e-mail idêntico na caixa de
    // quem recebe. Quando isso acontece o servidor tira o `html` da
    // resposta, então nem haveria corpo para mandar.
    if (aviso.enviadoPeloServidor) {
      return Promise.resolve({ enviado: true, motivo: 'enviado pelo servidor' });
    }
    // O servidor TENTOU e não conseguiu; o corpo continua aqui, então
    // ainda vale tentar pelo Graph. Se este caminho também falhar, o
    // motivo que aparece na tela é o do Graph — o do servidor já está no
    // log e na auditoria.
    if (aviso.motivoServidor) {
      console.warn('[VBMEmail] o servidor nao conseguiu enviar "' + aviso.chave +
                   '" (' + aviso.motivoServidor + '); tentando pelo navegador.');
    }
    if (enviados[aviso.chave]) {
      return Promise.resolve({ enviado: false, motivo: 'já enviado' });
    }
    if (!window.VBMMsal || !window.VBMMsal.estaConfigurado()) {
      avisarServidor(idKaizen, aviso.chave, false, 'MSAL não configurado (js/msal-config.js)', aviso.para);
      return Promise.resolve({ enviado: false, motivo: 'MSAL não configurado' });
    }

    // Marca antes de enviar: um segundo clique enquanto o primeiro está
    // em voo não pode virar um segundo e-mail.
    enviados[aviso.chave] = true;

    return window.VBMMsal.obterInstancia()
      .then(function (app) { return obterTokenSilencioso(app, escoposDe(aviso)); })
      .catch(function (err) {
        // Sem token não há o que tentar, e o popup aqui seria bloqueado.
        // Mostra a faixa para a pessoa autorizar e reenviar — e solta a
        // chave, senão o comunicado ficaria travado como "já enviado".
        delete enviados[aviso.chave];
        mostrarFaixaAutorizacao(err && err.message);
        throw new Error('envio não autorizado nesta sessão: ' + (err && err.message));
      })
      .then(function (token) {
        // Com "de" preenchido, a mensagem sai pela caixa COMPARTILHADA —
        // e quem envia precisa ter "Enviar Como" nela. Sem "de", sai
        // pela caixa da PRÓPRIA pessoa logada (/me), que não depende de
        // liberação nenhuma no Exchange. Quem decide é o servidor, pela
        // variável KAIZEN_EMAIL_DO_USUARIO — ver email-kaizen.js.
        var destino = aviso.de
          ? '/users/' + encodeURIComponent(aviso.de) + '/sendMail'
          : '/me/sendMail';
        return fetch(GRAPH + destino, {
          method: 'POST',
          headers: { Authorization: 'Bearer ' + token, 'Content-Type': 'application/json' },
          body: JSON.stringify({
            message: {
              subject: aviso.assunto,
              body: { contentType: 'HTML', content: aviso.html },
              // `para` é lista: o dono do Kaizen e os participantes da
              // equipe recebem o MESMO comunicado, num envio só.
              toRecipients: destinatarios(aviso.para).map(function (e) {
                return { emailAddress: { address: e } };
              })
            },
            saveToSentItems: true
          })
        });
      })
      .then(function (r) {
        if (!r.ok) {
          return r.text().catch(function () { return ''; }).then(function (t) {
            throw new Error('Graph HTTP ' + r.status + ': ' + String(t).slice(0, 200));
          });
        }
        avisarServidor(idKaizen, aviso.chave, true, null, aviso.para);
        return { enviado: true };
      })
      .catch(function (err) {
        // Solta a chave: a decisão já valeu, e o aviso pode ser
        // reenviado numa próxima tentativa em vez de ficar travado.
        delete enviados[aviso.chave];
        avisarServidor(idKaizen, aviso.chave, false, err.message, aviso.para);
        return { enviado: false, motivo: err.message };
      });
  }

  /** Envia a lista de comunicados que veio na resposta (cadastro manda
   *  dois: equipe e aprovador; decisão manda um). Em sequência, não em
   *  paralelo: o token é o mesmo e o primeiro envio já o deixa em cache. */
  function enviarTodos(avisos, idKaizen) {
    var lista = Array.isArray(avisos) ? avisos : (avisos ? [avisos] : []);
    return lista.reduce(function (fila, aviso) {
      return fila.then(function (acc) {
        return enviar(aviso, idKaizen).then(function (r) { return acc.concat([r]); });
      });
    }, Promise.resolve([]));
  }

  /** Mostra na TELA o motivo de um comunicado não ter saído.
   *
   *  Até aqui a falha ia só para o log do servidor (POST .../aviso) e
   *  quem estava usando o sistema não via nada: o Kaizen era gravado, a
   *  tela trocava e o e-mail simplesmente não chegava. Sem esse aviso,
   *  descobrir a causa exigia acesso ao log do app — que quem usa o
   *  sistema não tem.
   *
   *  Não é erro de gravação, e por isso é um toast de ATENÇÃO: o Kaizen
   *  (ou a decisão) já está salvo. O texto traz o motivo cru vindo do
   *  Graph ou da MSAL, porque é ele que diz o que fazer — falta de
   *  consentimento, falta de "Enviar Como", CDN bloqueado. */
  function avisarNaTela(resultados) {
    if (typeof showToast !== 'function') return resultados;
    var falhas = (resultados || []).filter(function (r) {
      return r && r.enviado === false && r.motivo
        && r.motivo !== 'já enviado' && r.motivo !== 'sem aviso';
    });
    if (!falhas.length) return resultados;
    var motivo = falhas[0].motivo;
    var titulo = (window.__i18n && window.__i18n['email.failTitle']) || 'E-mail não enviado';
    var texto = (window.__i18n && window.__i18n['email.failMsg'])
      || 'O registro foi salvo normalmente, mas o comunicado não saiu.';
    showToast('warning', titulo, texto + ' Motivo: ' + motivo, 12000);
    return resultados;
  }

  // Pede a autorização ANTES de precisar dela. Ver prepararAutorizacao.
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', prepararAutorizacao);
  } else {
    prepararAutorizacao();
  }

  window.VBMEmail = { enviar: enviar, autorizarAgora: autorizarAgora,
    enviarTodos: function (avisos, idKaizen) {
    // Rastro no console do navegador (F12). O log do servidor já
    // registra cada envio, mas quem usa o sistema não tem acesso a ele —
    // e é sempre a primeira pergunta quando "o e-mail não chegou":
    // quantos comunicados vieram e o que aconteceu com cada um.
    var lista = Array.isArray(avisos) ? avisos : (avisos ? [avisos] : []);
    console.info('[VBMEmail] comunicados recebidos do servidor:', lista.length, lista);
    if (!lista.length) {
      console.warn('[VBMEmail] o servidor não devolveu comunicado nenhum — nada a enviar.');
    }
    return enviarTodos(avisos, idKaizen).then(function (resultados) {
      console.info('[VBMEmail] resultado do envio:', resultados);
      return avisarNaTela(resultados);
    });
  } };
})();
