/**
 * VBM Kaizen — aba "Usuários" (admin.html). SOMENTE LEITURA.
 *
 * Fonte: kzn_mdm_hierarquia (GET /api/usuarios), que pelo DER tem só
 * ID_USUARIO, CD_MATRICULA, NM_USUARIO, DS_EMAIL, NM_HIERARQUIA_N1..N8
 * e DT_ATUALIZACAO — e é sincronizada do MDM corporativo.
 *
 * Por isso esta aba NÃO tem criar/editar/ativar como as demais: o
 * modelo atual não tem coluna de status (SG_ATIVO), papel, empresa nem
 * unidade para gravar. As colunas Site, Empresa e Status ficam vazias
 * ("—") em vez de exibir valor inventado; Função é derivada de
 * kzn_aprovador (único vínculo de papel existente hoje).
 *
 * Assim que o modelo ganhar essas colunas (ou uma tabela de vínculo
 * usuário↔papel/unidade/status), esta aba passa a usar a mesma fábrica
 * das outras — ver js/cadastro-bilingue.js.
 */
(function () {
  var tbody = document.getElementById("usuariosTableBody");
  if (!tbody) return; // esta página não tem a aba Usuários

  var COLUNAS = 7;

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

  // "Aprovador"/"Operador" é rótulo de tela (kzn_aprovador não é
  // bilíngue — não tem ID_IDIOMA), então NÃO vem do banco: o servidor
  // manda só o booleano EH_APROVADOR e a tradução é local. O
  // data-i18n faz o badge já existente acompanhar trocas de idioma
  // seguintes sem precisar re-render (ver translatePanel no <script>
  // de idioma de admin.html, que reaplica em todo elemento marcado).
  function papelBadge(ehAprovador) {
    var chave = ehAprovador ? "role.aprovador" : "role.operador";
    var idiomaAtual = (window.VBMIdioma && window.VBMIdioma.atual()) || "pt-BR";
    var emIngles = String(idiomaAtual).toLowerCase().indexOf("en") === 0;
    var texto = ehAprovador
      ? (emIngles ? "Approver" : "Aprovador")
      : (emIngles ? "Operator" : "Operador");
    return '<span class="admin-item-badge role-badge" data-i18n="' + chave + '">' + escapeHtml(texto) + "</span>";
  }

  function render(usuarios) {
    if (!usuarios.length) {
      tbody.innerHTML = linhaAviso("Nenhum usuário encontrado no MDM.", false);
      return;
    }
    tbody.innerHTML = usuarios.map(function (u) {
      var vazio = '<td style="color:var(--vbm-mid);">—</td>';
      return "<tr>" +
        '<td><div style="display:flex;align-items:center;gap:.5rem;">' +
          '<div class="admin-avatar" style="width:28px;height:28px;font-size:.65rem;background:linear-gradient(135deg,#3cb5e5,#1a8bbf);">' + escapeHtml(initials(u.NM_USUARIO)) + "</div>" +
          "<span>" + escapeHtml(u.NM_USUARIO || "—") + "</span></div></td>" +
        '<td style="font-size:.78rem;">' + escapeHtml(u.DS_EMAIL || "—") + "</td>" +
        vazio + /* Site: sem coluna no modelo atual */
        "<td>" + papelBadge(u.EH_APROVADOR) + "</td>" +
        vazio + /* Empresa: sem coluna no modelo atual */
        vazio + /* Status: sem SG_ATIVO no modelo atual */
        '<td style="font-size:.72rem;color:var(--vbm-mid);">' + escapeHtml(u.CD_MATRICULA || "—") + "</td>" +
      "</tr>";
    }).join("");
  }

  var jaCarregou = false;

  function carregar() {
    jaCarregou = true;
    tbody.innerHTML = linhaAviso("Carregando usuários…", false);
    fetch("/api/usuarios")
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

  // Carrega sob demanda: esta aba nasce escondida, mas antes já
  // consultava o MDM no load da página. Agora só na primeira vez que
  // for realmente aberta.
  //
  // A coluna "Função" (Aprovador/Operador) é derivada de kzn_aprovador,
  // ou seja, de OUTRA aba: cadastrar ou desativar um aprovador deixa
  // esta lista desatualizada. VBMDados marca isso e a recarga acontece
  // na próxima abertura desta aba — não a cada troca de aba, e nunca
  // com a aba fechada (ver js/vbm-app.js).
  var painel = tbody.closest(".admin-panel");

  function abaAberta() {
    return !painel || painel.classList.contains("active");
  }

  var revalidar = window.VBMDados
    ? window.VBMDados.aoMudar(["aprovadores"], carregar, abaAberta)
    : null;

  function aoAbrirAba() {
    if (!jaCarregou) {
      carregar();
      return;
    }
    if (revalidar) revalidar(); // no-op se nenhum aprovador mudou
  }

  if (abaAberta() || typeof MutationObserver === "undefined") {
    aoAbrirAba();
  } else {
    new MutationObserver(function () {
      if (painel.classList.contains("active")) aoAbrirAba();
    }).observe(painel, { attributes: true, attributeFilter: ["class"] });
  }
})();
