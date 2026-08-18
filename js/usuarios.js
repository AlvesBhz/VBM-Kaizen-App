/**
 * VBM Kaizen — aba "Usuários" (admin.html). SOMENTE LEITURA.
 *
 * Lista os usuários TERCEIROS do MDM: kzn_mdm_hierarquia com
 * ID_TIPO_USUARIO = 2. Esse recorte é do SERVIDOR (ver GET
 * /api/usuarios em server.js), não um filtro da tela — busca, empresa
 * e unidade só estreitam o resultado, nunca ampliam.
 *
 * Colunas, todas do MDM:
 *   Usuário  NM_USUARIO      Site     NM_SITE
 *   E-mail   CD_EMAIL        Função   NM_POSICAO
 *   Empresa  NM_EMPRESA      Status   SG_ATIVO
 *
 * A aba não tem criar/editar/ativar como as demais: os dados vêm do
 * MDM corporativo e mudam lá, não por esta tela.
 *
 *   GET /api/usuarios?q=&empresa=  lista (recorte fixo de terceiros)
 *   GET /api/usuarios/empresas     opções do filtro Empresa
 */
(function () {
  var tbody = document.getElementById("usuariosTableBody");
  if (!tbody) return; // esta página não tem a aba Usuários

  var COLUNAS = 6;
  var BUSCA_MIN = 2; // mesmo mínimo do servidor
  var buscaEl = document.getElementById("usuariosBusca");
  var empresaEl = document.getElementById("usuariosEmpresa");

  function escapeHtml(str) {
    var div = document.createElement("div");
    div.textContent = str == null ? "" : String(str);
    return div.innerHTML;
  }

  function initials(nome) {
    var p = String(nome || "").trim().split(/\s+/).filter(Boolean);
    if (!p.length) return "?";
    return (p[0][0] + (p[1] ? p[1][0] : "")).toUpperCase();
  }

  function linhaAviso(texto, erro) {
    return '<tr><td colspan="' + COLUNAS + '" style="padding:1.25rem;font-size:.8rem;color:' +
      (erro ? "#c0392b" : "var(--vbm-mid)") + ';">' + escapeHtml(texto) + "</td></tr>";
  }

  function emIngles() {
    var idioma = (window.VBMIdioma && window.VBMIdioma.atual()) || "pt-BR";
    return String(idioma).toLowerCase().indexOf("en") === 0;
  }

  // "Ativo"/"Inativo" é rótulo de tela: SG_ATIVO não é bilíngue no
  // banco, então a tradução é local. O data-i18n faz o badge acompanhar
  // trocas de idioma seguintes sem re-render (ver translatePanel no
  // <script> de idioma de admin.html).
  function statusBadge(ativo) {
    var chave = ativo ? "status.ativo" : "status.inativo";
    var texto = ativo
      ? (emIngles() ? "Active" : "Ativo")
      : (emIngles() ? "Inactive" : "Inativo");
    return '<span class="admin-item-badge" data-i18n="' + chave + '">' + escapeHtml(texto) + "</span>";
  }

  function celula(valor) {
    return valor
      ? "<td>" + escapeHtml(valor) + "</td>"
      : '<td style="color:var(--vbm-mid);">—</td>';
  }

  function render(usuarios) {
    if (!usuarios.length) {
      tbody.innerHTML = linhaAviso("Nenhum usuário encontrado.", false);
      return;
    }
    tbody.innerHTML = usuarios.map(function (u) {
      return "<tr>" +
        '<td><div style="display:flex;align-items:center;gap:.5rem;">' +
          '<div class="admin-avatar" style="width:28px;height:28px;font-size:.65rem;background:linear-gradient(135deg,#3cb5e5,#1a8bbf);">' + escapeHtml(initials(u.NM_USUARIO)) + "</div>" +
          "<span>" + escapeHtml(u.NM_USUARIO || "—") + "</span></div></td>" +
        '<td style="font-size:.78rem;">' + escapeHtml(u.CD_EMAIL || "—") + "</td>" +
        celula(u.NM_SITE) +
        celula(u.NM_POSICAO) +
        celula(u.NM_EMPRESA) +
        "<td>" + statusBadge(u.ATIVO) + "</td>" +
      "</tr>";
    }).join("");
  }

  var jaCarregou = false;

  // Busca com menos de 2 caracteres não vai para o servidor: a lista
  // fica como está (sem filtro de texto), que é o gatilho mínimo pedido.
  function parametros() {
    var termo = buscaEl ? buscaEl.value.trim() : "";
    var partes = [];
    if (termo.length >= BUSCA_MIN) partes.push("q=" + encodeURIComponent(termo));
    if (empresaEl && empresaEl.value) partes.push("empresa=" + encodeURIComponent(empresaEl.value));
    return partes.length ? "?" + partes.join("&") : "";
  }

  function carregar() {
    jaCarregou = true;
    tbody.innerHTML = linhaAviso("Carregando usuários…", false);
    fetch("/api/usuarios" + parametros())
      .then(function (res) {
        if (!res.ok) return res.json().then(function (e) { throw new Error(e.error || res.statusText); });
        return res.json();
      })
      .then(render)
      .catch(function (err) {
        console.error("[usuarios] falha ao carregar:", err);
        tbody.innerHTML = linhaAviso("Erro ao carregar usuários: " + err.message, true);
      });
  }

  // Opções do filtro Empresa (NM_EMPRESA distintos dos terceiros).
  // Falha aqui não derruba a lista: o combo fica só com "Todas as
  // empresas" e a tabela continua funcionando.
  function carregarEmpresas() {
    if (!empresaEl) return;
    fetch("/api/usuarios/empresas")
      .then(function (res) { return res.ok ? res.json() : []; })
      .then(function (empresas) {
        var selecionada = empresaEl.value;
        var primeira = empresaEl.querySelector("option"); // "Todas as empresas"
        empresaEl.innerHTML = "";
        if (primeira) empresaEl.appendChild(primeira);
        empresas.forEach(function (nome) {
          var op = document.createElement("option");
          op.value = nome;
          op.textContent = nome;
          empresaEl.appendChild(op);
        });
        empresaEl.value = selecionada || "";
      })
      .catch(function (err) {
        console.error("[usuarios] falha ao carregar empresas:", err);
      });
  }

  // Debounce: uma consulta depois que a digitação para, não uma por tecla.
  var timerBusca = null;
  if (buscaEl) {
    buscaEl.addEventListener("input", function () {
      clearTimeout(timerBusca);
      timerBusca = setTimeout(carregar, 300);
    });
  }
  if (empresaEl) empresaEl.addEventListener("change", carregar);

  // Carrega sob demanda: esta aba nasce escondida, mas antes já
  // consultava o MDM no load da página. Agora só na primeira vez que
  // for realmente aberta.
  var painel = tbody.closest(".admin-panel");

  function abaAberta() {
    return !painel || painel.classList.contains("active");
  }

  function aoAbrirAba() {
    if (jaCarregou) return;
    carregarEmpresas();
    carregar();
  }

  if (abaAberta() || typeof MutationObserver === "undefined") {
    aoAbrirAba();
  } else {
    new MutationObserver(function () {
      if (painel.classList.contains("active")) aoAbrirAba();
    }).observe(painel, { attributes: true, attributeFilter: ["class"] });
  }
})();
