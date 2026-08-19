/**
 * VBM Kaizen — aba "Usuários" (admin.html).
 *
 * Cadastro dos usuários TERCEIROS do MDM: kzn_mdm_hierarquia com
 * ID_TIPO_USUARIO = 2. Esse recorte é do SERVIDOR (ver as rotas
 * /api/usuarios em server.js), não um filtro da tela — busca, empresa
 * e unidade só estreitam o resultado, nunca ampliam, e o tipo nunca
 * viaja no corpo da requisição.
 *
 * Colunas da grade, todas do MDM:
 *   Usuário  NM_USUARIO      Site     NM_SITE
 *   E-mail   CD_EMAIL        Função   NM_POSICAO
 *   Empresa  NM_EMPRESA      Status   SG_ATIVO
 *
 * A CHAVE É COMPOSTA — (ID_USUARIO, CD_MATRICULA, ID_TIPO_USUARIO).
 * Por isso toda ação de linha manda ID e matrícula: só o ID poderia
 * casar com mais de um registro. E por isso os dois campos abrem
 * travados na edição: trocá-los seria criar outro registro.
 *
 *   GET    /api/usuarios?q=&empresa=&unidade=   lista (só terceiros)
 *   GET    /api/usuarios/empresas               filtro Empresa
 *   GET    /api/usuarios/unidades               filtro Unidade
 *   GET    /api/usuarios/:id?matricula=         um registro (edição)
 *   POST   /api/usuarios                        inserir
 *   PUT    /api/usuarios/:id                    editar
 *   PUT    /api/usuarios/:id/status             ativar/desativar
 *
 * Depende de funções globais de vbm-app.js: openModal / closeModal /
 * showToast / confirmarAcao.
 */
(function () {
  var tbody = document.getElementById("usuariosTableBody");
  if (!tbody) return; // esta página não tem a aba Usuários

  var COLUNAS = 7;
  var BUSCA_MIN = 2; // mesmo mínimo do servidor
  var buscaEl = document.getElementById("usuariosBusca");
  var empresaEl = document.getElementById("usuariosEmpresa");
  var unidadeEl = document.getElementById("usuariosUnidade");

  // Mesma lista do servidor (COLUNAS_MDM_TEXTO em server.js), na mesma
  // ordem. É o contrato dos dois modais: cada campo do HTML se declara
  // com data-campo="<COLUNA>".
  var CAMPOS_TEXTO = [
    "NM_USUARIO", "CD_EMAIL", "NM_POSICAO", "NM_EMPRESA",
    "NM_PAIS", "NM_ESTADO", "NM_CIDADE", "NM_SITE",
    "NM_HIERARQUIA_N1", "NM_HIERARQUIA_N2", "NM_HIERARQUIA_N3", "NM_HIERARQUIA_N4",
    "NM_HIERARQUIA_N5", "NM_HIERARQUIA_N6", "NM_HIERARQUIA_N7", "NM_HIERARQUIA_N8",
  ];

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

  // Mesmo par de botões das outras abas: lápis para editar, banir/
  // recuperar para alternar o status.
  function acoes(ativo) {
    return '<td><div class="row-actions" style="display:inline-flex;gap:.35rem;">' +
      '<button type="button" class="btn-icon btn-icon-blue btn-icon-sm" data-action="editar" title="Editar" data-i18n-title="common.editar"><i class="fa-solid fa-pen"></i></button>' +
      '<button type="button" class="btn-icon ' + (ativo ? "btn-icon-red" : "btn-icon-blue") +
        ' btn-icon-sm" data-action="status" title="' + (ativo ? "Desativar" : "Reativar") + '">' +
        '<i class="fa-solid ' + (ativo ? "fa-ban" : "fa-rotate-right") + '"></i></button>' +
      "</div></td>";
  }

  function linhaHtml(u) {
    return '<tr class="' + (u.ATIVO ? "" : "admin-item-inactive") + '">' +
      '<td><div style="display:flex;align-items:center;gap:.5rem;">' +
        '<div class="admin-avatar" style="width:28px;height:28px;font-size:.65rem;background:linear-gradient(135deg,#3cb5e5,#1a8bbf);">' + escapeHtml(initials(u.NM_USUARIO)) + "</div>" +
        "<span>" + escapeHtml(u.NM_USUARIO || "—") + "</span></div></td>" +
      '<td style="font-size:.78rem;">' + escapeHtml(u.CD_EMAIL || "—") + "</td>" +
      celula(u.NM_SITE) +
      celula(u.NM_POSICAO) +
      celula(u.NM_EMPRESA) +
      "<td>" + statusBadge(u.ATIVO) + "</td>" +
      acoes(u.ATIVO) +
    "</tr>";
  }

  // A linha guarda a chave inteira; os handlers leem daqui, nunca de
  // uma posição de array que a próxima busca invalidaria.
  function render(usuarios) {
    if (!usuarios.length) {
      tbody.innerHTML = linhaAviso("Nenhum usuário encontrado.", false);
      return;
    }
    tbody.innerHTML = usuarios.map(linhaHtml).join("");
    Array.prototype.forEach.call(tbody.querySelectorAll("tr"), function (tr, i) {
      var u = usuarios[i];
      tr.dataset.id = u.ID_USUARIO;
      tr.dataset.matricula = u.CD_MATRICULA == null ? "" : u.CD_MATRICULA;
      tr.querySelector('[data-action="editar"]').addEventListener("click", function () {
        abrirEdicao(u);
      });
      tr.querySelector('[data-action="status"]').addEventListener("click", function () {
        alternarStatus(u);
      });
    });
  }

  var jaCarregou = false;

  // Busca com menos de 2 caracteres não vai para o servidor: a lista
  // fica como está (sem filtro de texto), que é o gatilho mínimo pedido.
  function parametros() {
    var termo = buscaEl ? buscaEl.value.trim() : "";
    var partes = [];
    if (termo.length >= BUSCA_MIN) partes.push("q=" + encodeURIComponent(termo));
    if (empresaEl && empresaEl.value) partes.push("empresa=" + encodeURIComponent(empresaEl.value));
    if (unidadeEl && unidadeEl.value) partes.push("unidade=" + encodeURIComponent(unidadeEl.value));
    return partes.length ? "?" + partes.join("&") : "";
  }

  function comoJson(res) {
    return res.text().then(function (texto) {
      var dados = null;
      try { dados = texto ? JSON.parse(texto) : null; } catch (e) { /* resposta não-JSON */ }
      if (!res.ok) throw new Error((dados && dados.error) || ("HTTP " + res.status));
      return dados;
    });
  }

  function carregar() {
    jaCarregou = true;
    tbody.innerHTML = linhaAviso("Carregando usuários…", false);
    return fetch("/api/usuarios" + parametros())
      .then(comoJson)
      .then(render)
      .catch(function (err) {
        console.error("[usuarios] falha ao carregar:", err);
        tbody.innerHTML = linhaAviso("Erro ao carregar usuários: " + err.message, true);
      });
  }

  // Opções dos filtros Empresa (NM_EMPRESA) e Unidade (NM_SITE), ambos
  // com os valores distintos dos terceiros. A 1ª opção ("Todas as ...")
  // é a do HTML e fica preservada.
  //
  // Sem nenhum valor no banco (coluna vazia no MDM) o combo é
  // desabilitado: um filtro que só tem "Todas as ..." não filtra nada, e
  // deixá-lo clicável faz parecer que a tela perdeu as opções.
  //
  // Falha aqui não derruba a lista: o combo fica só com a opção "Todas"
  // e a tabela continua funcionando.
  function carregarOpcoes(select, rota, rotulo) {
    if (!select) return;
    fetch("/api/usuarios/" + rota)
      .then(function (res) { return res.ok ? res.json() : []; })
      .then(function (valores) {
        var selecionado = select.value;
        var primeira = select.querySelector("option");
        select.innerHTML = "";
        if (primeira) select.appendChild(primeira);
        valores.forEach(function (nome) {
          var op = document.createElement("option");
          op.value = nome;
          op.textContent = nome;
          select.appendChild(op);
        });
        select.value = selecionado || "";
        select.disabled = valores.length === 0;
      })
      .catch(function (err) {
        console.error("[usuarios] falha ao carregar " + rotulo + ":", err);
        select.disabled = true;
      });
  }

  function recarregarFiltros() {
    carregarOpcoes(empresaEl, "empresas", "empresas");
    carregarOpcoes(unidadeEl, "unidades", "unidades");
  }

  // ── Formulário (mesmos campos nos dois modais) ──
  //
  // Cada campo se identifica por data-campo="<COLUNA>", então ler e
  // escrever o formulário é percorrer as colunas — sem uma lista de
  // ids paralela para sair de sincronia.
  function campo(modalId, coluna) {
    return document.querySelector("#" + modalId + ' [data-campo="' + coluna + '"]');
  }

  function limparFormulario(modalId) {
    ["ID_USUARIO", "CD_MATRICULA"].concat(CAMPOS_TEXTO).forEach(function (c) {
      var el = campo(modalId, c);
      if (el) el.value = "";
    });
    var st = campo(modalId, "SG_ATIVO");
    if (st) st.value = "S";
  }

  function preencherFormulario(modalId, dados) {
    ["ID_USUARIO", "CD_MATRICULA"].concat(CAMPOS_TEXTO).forEach(function (c) {
      var el = campo(modalId, c);
      if (el) el.value = dados[c] == null ? "" : dados[c];
    });
    var st = campo(modalId, "SG_ATIVO");
    if (st) st.value = dados.ATIVO === false ? "N" : "S";
  }

  function lerFormulario(modalId) {
    var corpo = {};
    CAMPOS_TEXTO.forEach(function (c) {
      var el = campo(modalId, c);
      corpo[c] = el ? el.value : "";
    });
    var id = campo(modalId, "ID_USUARIO");
    var mat = campo(modalId, "CD_MATRICULA");
    var st = campo(modalId, "SG_ATIVO");
    corpo.ID_USUARIO = id ? id.value.trim() : "";
    corpo.CD_MATRICULA = mat ? mat.value.trim() : "";
    corpo.ATIVO = !st || st.value === "S";
    return corpo;
  }

  // Validação mínima, igual à do servidor: sem chave não há registro, e
  // sem nome a linha não diz nada na grade.
  function faltando(corpo, exigirChave) {
    if (exigirChave && !/^\d+$/.test(corpo.ID_USUARIO)) return "Informe o ID do usuário (MDM), só números.";
    if (exigirChave && !corpo.CD_MATRICULA) return "Informe a matrícula.";
    if (!String(corpo.NM_USUARIO || "").trim()) return "Informe o nome completo.";
    return null;
  }

  function enviar(url, metodo, corpo) {
    return fetch(url, {
      method: metodo,
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(corpo),
    }).then(comoJson);
  }

  // ── Inserir ──
  var btnAdd = document.getElementById("btnSaveAddUser");
  var gatilhoAdd = document.querySelector('[data-modal-open="modalAddUser"]');
  if (gatilhoAdd) gatilhoAdd.addEventListener("click", function () { limparFormulario("modalAddUser"); });

  function salvarNovo() {
    var corpo = lerFormulario("modalAddUser");
    var erro = faltando(corpo, true);
    if (erro) {
      if (window.showToast) showToast("warning", "Campo obrigatório", erro);
      return;
    }
    if (btnAdd) btnAdd.disabled = true;
    enviar("/api/usuarios", "POST", corpo)
      .then(function () {
        if (window.closeModal) closeModal("modalAddUser");
        if (window.showToast) showToast("success", "Usuário criado", "Usuário cadastrado com sucesso!");
        limparFormulario("modalAddUser");
        carregar();
        // Empresa e unidade novas passam a existir nos combos.
        recarregarFiltros();
      })
      .catch(function (err) {
        console.error("[usuarios] falha ao inserir:", err);
        if (window.showToast) showToast("error", "Erro ao salvar", err.message);
      })
      .finally(function () { if (btnAdd) btnAdd.disabled = false; });
  }

  // ── Editar ──
  //
  // A grade não carrega país, cidade nem os 8 níveis de hierarquia (são
  // 11 colunas que ninguém vê na tabela), então o modal busca o
  // registro completo ao abrir. A chave vai na URL + query.
  var btnEdit = document.getElementById("btnSaveEditUser");
  var chaveEmEdicao = null;

  function urlDoRegistro(id, matricula) {
    return "/api/usuarios/" + encodeURIComponent(id) +
      "?matricula=" + encodeURIComponent(matricula);
  }

  function abrirEdicao(u) {
    chaveEmEdicao = { id: u.ID_USUARIO, matricula: u.CD_MATRICULA };
    limparFormulario("modalEditUser");
    // Mostra de imediato o que a grade já tem; o resto chega da busca.
    preencherFormulario("modalEditUser", u);
    if (window.openModal) openModal("modalEditUser");

    fetch(urlDoRegistro(u.ID_USUARIO, u.CD_MATRICULA))
      .then(comoJson)
      .then(function (dados) {
        if (!chaveEmEdicao || chaveEmEdicao.id !== u.ID_USUARIO) return; // trocou de registro
        preencherFormulario("modalEditUser", dados);
      })
      .catch(function (err) {
        console.error("[usuarios] falha ao carregar registro:", err);
        if (window.showToast) showToast("error", "Erro ao abrir", err.message);
      });
  }

  function salvarEdicao() {
    if (!chaveEmEdicao) return;
    var corpo = lerFormulario("modalEditUser");
    var erro = faltando(corpo, false);
    if (erro) {
      if (window.showToast) showToast("warning", "Campo obrigatório", erro);
      return;
    }
    // A chave vem do registro aberto, não dos campos travados: o que
    // identifica a linha é o que foi clicado.
    corpo.CD_MATRICULA = chaveEmEdicao.matricula;
    if (btnEdit) btnEdit.disabled = true;
    enviar("/api/usuarios/" + encodeURIComponent(chaveEmEdicao.id), "PUT", corpo)
      .then(function () {
        if (window.closeModal) closeModal("modalEditUser");
        if (window.showToast) showToast("success", "Salvo", "Usuário atualizado com sucesso!");
        carregar();
        recarregarFiltros();
      })
      .catch(function (err) {
        console.error("[usuarios] falha ao salvar:", err);
        if (window.showToast) showToast("error", "Erro ao salvar", err.message);
      })
      .finally(function () { if (btnEdit) btnEdit.disabled = false; });
  }

  // ── Ativar/Desativar — grava SG_ATIVO no banco, nunca só visual ──
  function alternarStatus(u) {
    var ativar = !u.ATIVO;
    var nome = u.NM_USUARIO || "ID " + u.ID_USUARIO;
    Promise.resolve(
      window.confirmarAcao
        ? confirmarAcao({
            variant: ativar ? "ativar" : "desativar",
            titulo: ativar ? ('Reativar "' + nome + '"?') : ('Desativar "' + nome + '"?'),
            mensagem: ativar ? "" : "Deixará de aparecer como usuário ativo, mas não será excluído.",
          })
        : true
    ).then(function (confirmado) {
      if (!confirmado) return;
      return enviar(
        "/api/usuarios/" + encodeURIComponent(u.ID_USUARIO) + "/status",
        "PUT",
        { ativo: ativar, CD_MATRICULA: u.CD_MATRICULA }
      ).then(function () {
        u.ATIVO = ativar;
        carregar();
        if (window.showToast) {
          showToast("success", ativar ? "Reativado" : "Desativado",
            '"' + nome + '" ' + (ativar ? "reativado" : "desativado") + " com sucesso.");
        }
      });
    }).catch(function (err) {
      console.error("[usuarios] erro ao atualizar status:", err);
      if (window.showToast) showToast("error", "Erro", "Não foi possível atualizar o status. " + err.message);
    });
  }

  if (btnAdd) btnAdd.addEventListener("click", salvarNovo);
  if (btnEdit) btnEdit.addEventListener("click", salvarEdicao);

  // Debounce: uma consulta depois que a digitação para, não uma por tecla.
  var timerBusca = null;
  if (buscaEl) {
    buscaEl.addEventListener("input", function () {
      clearTimeout(timerBusca);
      timerBusca = setTimeout(carregar, 300);
    });
  }
  if (empresaEl) empresaEl.addEventListener("change", carregar);
  if (unidadeEl) unidadeEl.addEventListener("change", carregar);

  // Carrega sob demanda: esta aba nasce escondida, mas antes já
  // consultava o MDM no load da página. Agora só na primeira vez que
  // for realmente aberta.
  var painel = tbody.closest(".admin-panel");

  function abaAberta() {
    return !painel || painel.classList.contains("active");
  }

  function aoAbrirAba() {
    if (jaCarregou) return;
    recarregarFiltros();
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
