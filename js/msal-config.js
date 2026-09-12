/**
 * VBM Kaizen — configuração única do login Microsoft (MSAL / Entra ID).
 *
 * Antes esses dois valores viviam soltos dentro do <script> do
 * index.html. Agora que a tela de Aprovação também precisa de um token
 * do usuário (para enviar o aviso da decisão pelo Microsoft Graph com o
 * perfil de quem aprovou), preenchê-los em dois lugares seria pedir
 * para as duas telas divergirem. Este arquivo é o único lugar a editar.
 *
 * PENDENTE DE CONFIGURAÇÃO — preencha abaixo com os dados do app
 * registrado em Entra ID > App registrations:
 *   • clientId  = "Application (client) ID"
 *   • authority = "https://login.microsoftonline.com/<TENANT_ID>"
 *
 * No mesmo app registration:
 *   • Authentication > Redirect URI do tipo SPA com a URL das páginas
 *     que usam login (index.html e aprovacao.html).
 *   • API permissions (Microsoft Graph, DELEGADAS):
 *       User.Read          — perfil de quem está logado
 *       Mail.Send.Shared    — enviar pela caixa compartilhada
 *
 * A permissão é DELEGADA de propósito: quem autentica é o próprio
 * aprovador, não uma identidade de aplicação. Por isso não há client
 * secret em lugar nenhum do projeto — e por isso a conta de quem decide
 * precisa ter "Enviar Como" (ou "Enviar em Nome De") na caixa
 * PCI.Base.Metals@Vale.com; sem isso o Graph recusa o envio.
 *
 * Enquanto os placeholders estiverem aqui, nada quebra: o login não é
 * tentado e o aviso da decisão apenas não é enviado (a decisão em si é
 * gravada normalmente).
 */
(function () {
  'use strict';

  var CONFIG = {
    clientId: 'SEU_CLIENT_ID_AQUI',
    authority: 'https://login.microsoftonline.com/SEU_TENANT_ID_AQUI'
  };

  var MSAL_CDN = 'https://alcdn.msauth.net/browser/2.38.3/js/msal-browser.min.js';
  var instancia = null;
  var carregando = null;

  /* Endereço de retorno do login. Precisa ser a URL da PÁGINA, sem a
     query nem o fragmento: o Entra ID compara o redirect_uri com a
     lista registrada por IGUALDADE EXATA, e window.location.href numa
     tela como kaizen-novo.html?id=123 pediria o retorno para
     ".../kaizen-novo.html?id=123" — que ninguém consegue registrar,
     porque muda a cada Kaizen. O login falharia com AADSTS50011 logo na
     edição, justamente onde o comunicado é enviado.
     Assim, bastam TRÊS endereços registrados: index.html,
     aprovacao.html e kaizen-novo.html. */
  function enderecoDeRetorno() {
    return window.location.origin + window.location.pathname;
  }

  function estaConfigurado() {
    return CONFIG.clientId !== 'SEU_CLIENT_ID_AQUI'
      && CONFIG.authority.indexOf('SEU_TENANT_ID_AQUI') === -1;
  }

  // A msal-browser.min.js (~200 KB, CDN externo) só é baixada quando o
  // login está de fato configurado — e uma vez só por página, mesmo que
  // duas partes do código peçam ao mesmo tempo.
  function carregarMsal() {
    if (typeof msal !== 'undefined') return Promise.resolve();
    if (carregando) return carregando;
    carregando = new Promise(function (resolve, reject) {
      var s = document.createElement('script');
      s.src = MSAL_CDN;
      s.onload = function () { resolve(); };
      s.onerror = function () { reject(new Error('Falha ao carregar a MSAL.')); };
      document.head.appendChild(s);
    });
    return carregando;
  }

  /** Instância única por página: duas PublicClientApplication com o
   *  mesmo clientId brigariam pelo cache de token do navegador. */
  function obterInstancia() {
    if (instancia) return Promise.resolve(instancia);
    if (!estaConfigurado()) return Promise.reject(new Error('MSAL não configurado.'));
    return carregarMsal().then(function () {
      var app = new msal.PublicClientApplication({
        auth: {
          clientId: CONFIG.clientId,
          authority: CONFIG.authority,
          redirectUri: enderecoDeRetorno()
        },
        cache: { cacheLocation: 'sessionStorage' }
      });
      return Promise.resolve(app.initialize()).then(function () {
        instancia = app;
        return app;
      });
    });
  }

  window.VBMMsal = {
    config: CONFIG,
    enderecoDeRetorno: enderecoDeRetorno,
    estaConfigurado: estaConfigurado,
    carregarMsal: carregarMsal,
    obterInstancia: obterInstancia
  };
})();
