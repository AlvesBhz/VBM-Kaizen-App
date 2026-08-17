/**
 * VBM Kaizen — aba "Aprovadores" (admin.html).
 *
 * kzn_aprovador é uma tabela de PAPEL: pelo DER guarda só ID_USUARIO
 * (FK do MDM), SG_ATIVO e DT_ATUALIZACAO. Nome, cargo, matrícula e
 * e-mail vêm de kzn_mdm_hierarquia por join, feito no servidor.
 *
 * Editar aqui é APONTAR o registro para outra pessoa (trocar o
 * ID_USUARIO): é o único campo editável da tabela, já que o SG_ATIVO é
 * o próprio botão de ativar/desativar. Os dados pessoais mudam no MDM,
 * nunca por esta tela.
 *
 *   GET  /api/aprovadores            lista (join com o MDM)
 *   GET  /api/aprovadores/mdm/:id    confere de quem é um ID_USUARIO
 *   POST /api/aprovadores            adiciona (só ID_USUARIO)
 *   PUT  /api/aprovadores/:id        troca o ID_USUARIO do registro
 *   PUT  /api/aprovadores/:id/status ativa/desativa (SG_ATIVO)
 *
 * Depende de funções globais de vbm-app.js: closeModal / showToast.
 */
(function () {
  var listEl = document.getElementById("aprovadoresList");
  if (!listEl) return; // esta página não tem a aba Aprovadores

  var stateEl = document.getElementById("aprovadoresState");
  var countEl = document.getElementById("aprovadoresCount");
  var addIdInput = document.getElementById("addAprovadorIdUsuario");
  var addMatriculaInput = document.getElementById("addAprovadorMatricula");
  var addNomeInput = document.getElementById("addAprovadorNome");
  var btnSaveAdd = document.getElementById("btnSaveAddAprovador");
  var addTrigger = document.querySelector('[data-modal-open="modalAddAprovador"]');

  var editIdInput = document.getElementById("editAprovadorIdUsuario");
  var editMatriculaInput = document.getElementById("editAprovadorMatricula");
  var editNomeInput = document.getElementById("editAprovadorNome");
  var btnSaveEdit = document.getElementById("btnSaveEditAprovador");
  var idEmEdicao = null;

  function escapeHtml(str) {
    var div = document.createElement("div");
    div.textContent = str == null ? "" : String(str);
    return div.innerHTML;
  }

  function initials(name) {
    var parts = String(name || "").trim().split(/\s+/).filter(Boolean);
    if (!parts.length) return "?";
    return (parts[0][0] + (parts[1] ? parts[1][0] : "")).toUpperCase();
  }

  function setState(msg, isError) {
    if (!stateEl) return;
    if (msg) {
      stateEl.style.display = "";
      stateEl.style.color = isError ? "#c0392b" : "var(--vbm-mid)";
      stateEl.textContent = msg;
      listEl.style.display = "none";
    } else {
      stateEl.style.display = "none";
      listEl.style.display = "";
    }
  }

  function renderItem(row) {
    var nome = row.NM_USUARIO || "(usuário fora do MDM)";
    var item = document.createElement("div");
    item.className = "admin-item" + (row.ATIVO ? "" : " admin-item-inactive");
    item.dataset.id = row.ID_USUARIO;
    item.innerHTML =
      '<div class="admin-avatar" style="background:linear-gradient(135deg,#3cb5e5,#1a8bbf);">' + escapeHtml(initials(row.NM_USUARIO)) + "</div>" +
      '<div class="admin-item-body">' +
        '<div class="admin-item-name">' + escapeHtml(nome) + "</div>" +
        '<div class="admin-item-sub">' + escapeHtml(row.DS_EMAIL || "—") + "</div>" +
        '<div class="admin-item-sub">Cargo ' + escapeHtml(row.NM_POSICAO || "—") + " · ID " + escapeHtml(row.ID_USUARIO) + "</div>" +
      "</div>" +
      '<div class="admin-item-actions">' +
        '<button type="button" class="btn-icon btn-icon-blue btn-icon-sm" data-action="editar" title="Editar" data-i18n-title="common.editar"><i class="fa-solid fa-pen"></i></button>' +
        '<button type="button" class="btn-icon ' + (row.ATIVO ? "btn-icon-red" : "btn-icon-blue") + ' btn-icon-sm" data-action="status" title="' + (row.ATIVO ? "Desativar" : "Reativar") + '"><i class="fa-solid ' + (row.ATIVO ? "fa-ban" : "fa-rotate-right") + '"></i></button>' +
      "</div>";

    item.querySelector('[data-action="editar"]').addEventListener("click", function () {
      abrirEdicao(row);
    });
    item.querySelector('[data-action="status"]').addEventListener("click", function () {
      alternarStatus(row, item);
    });
    return item;
  }

  function renderList(rows) {
    listEl.innerHTML = "";
    if (countEl) countEl.textContent = rows.length + " " + (rows.length === 1 ? "aprovador" : "aprovadores");

    if (!rows.length) {
      setState("Nenhum aprovador cadastrado ainda.", false);
      return;
    }
    setState(null);
    rows.forEach(function (row) { listEl.appendChild(renderItem(row)); });
  }

  function loadAprovadores() {
    setState("Carregando aprovadores...", false);
    return fetch("/api/aprovadores")
      .then(function (res) {
        if (!res.ok) return res.json().then(function (e) { throw new Error(e.error || res.statusText); });
        return res.json();
      })
      .then(renderList)
      .catch(function (err) {
        console.error("[aprovadores] erro ao carregar:", err);
        setState("Erro ao carregar aprovadores: " + err.message, true);
      });
  }

  // ── Adicionar ──
  // Nome/matrícula não são digitados: pertencem ao MDM. Ao informar o
  // ID_USUARIO, buscamos lá para o usuário confirmar de quem é aquele
  // ID antes de salvar; o POST envia só o ID.
  function limparFormulario() {
    if (addIdInput) addIdInput.value = "";
    if (addMatriculaInput) addMatriculaInput.value = "";
    if (addNomeInput) addNomeInput.value = "";
  }

  // Mesma consulta nos dois formulários (adicionar e editar): só mudam
  // os campos de destino, passados por parâmetro.
  function consultarMdm(idInput, matriculaInput, nomeInput, avisarNaoEncontrado) {
    var id = idInput ? idInput.value.trim() : "";
    var limpar = function () {
      if (matriculaInput) matriculaInput.value = "";
      if (nomeInput) nomeInput.value = "";
    };
    if (!id) return limpar();

    return fetch("/api/aprovadores/mdm/" + encodeURIComponent(id))
      .then(function (res) {
        return res.json().then(function (data) {
          if (!res.ok) throw new Error(data.error || res.statusText);
          return data;
        });
      })
      .then(function (u) {
        if (matriculaInput) matriculaInput.value = u.CD_MATRICULA || "";
        if (nomeInput) nomeInput.value = u.NM_USUARIO || "";
      })
      .catch(function (err) {
        limpar();
        if (avisarNaoEncontrado !== false && window.showToast) {
          showToast("warning", "Usuário não encontrado", err.message);
        }
      });
  }

  // Avisa as outras abas que kzn_aprovador mudou: a coluna "Função" da
  // aba Usuários é derivada daqui (ver window.VBMDados em vbm-app.js).
  function avisarMudanca() {
    if (window.VBMDados) window.VBMDados.mudou("aprovadores");
  }

  function saveAdd() {
    var id = addIdInput ? addIdInput.value.trim() : "";
    if (!id) {
      if (window.showToast) showToast("warning", "Campo obrigatório", "Informe o ID_USUARIO do aprovador.");
      return;
    }
    if (btnSaveAdd) btnSaveAdd.disabled = true;
    fetch("/api/aprovadores", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ ID_USUARIO: id }),
    })
      .then(function (res) {
        return res.json().then(function (data) {
          if (!res.ok) throw new Error(data.error || res.statusText);
          return data;
        });
      })
      .then(function () {
        limparFormulario();
        if (window.closeModal) closeModal("modalAddAprovador");
        if (window.showToast) showToast("success", "Aprovador adicionado", "Aprovador cadastrado com sucesso!");
        loadAprovadores();
        avisarMudanca();
      })
      .catch(function (err) {
        if (window.showToast) showToast("error", "Erro ao inserir", err.message);
      })
      .finally(function () {
        if (btnSaveAdd) btnSaveAdd.disabled = false;
      });
  }

  // ── Editar ──
  // Único campo editável: o ID_USUARIO (ver cabeçalho). Abre o modal já
  // preenchido com o ID atual e os dados do MDM correspondentes, no
  // mesmo formato do formulário de adicionar.
  function abrirEdicao(row) {
    idEmEdicao = row.ID_USUARIO;
    if (editIdInput) editIdInput.value = row.ID_USUARIO;
    if (editMatriculaInput) editMatriculaInput.value = row.CD_MATRICULA || "";
    if (editNomeInput) editNomeInput.value = row.NM_USUARIO || "";
    if (window.openModal) openModal("modalEditAprovador");
  }

  function saveEdit() {
    var id = editIdInput ? editIdInput.value.trim() : "";
    if (!id) {
      if (window.showToast) showToast("warning", "Campo obrigatório", "Informe o ID_USUARIO do aprovador.");
      return;
    }
    if (btnSaveEdit) btnSaveEdit.disabled = true;
    fetch("/api/aprovadores/" + encodeURIComponent(idEmEdicao), {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ ID_USUARIO: id }),
    })
      .then(function (res) {
        return res.json().then(function (data) {
          if (!res.ok) throw new Error(data.error || res.statusText);
          return data;
        });
      })
      .then(function () {
        if (window.closeModal) closeModal("modalEditAprovador");
        if (window.showToast) showToast("success", "Salvo", "Aprovador atualizado com sucesso!");
        loadAprovadores();
        avisarMudanca();
      })
      .catch(function (err) {
        console.error("[aprovadores] falha ao salvar:", err);
        if (window.showToast) showToast("error", "Erro ao salvar", err.message);
      })
      .finally(function () {
        if (btnSaveEdit) btnSaveEdit.disabled = false;
      });
  }

  // ── Ativar/Desativar — grava SG_ATIVO no banco, nunca só visual ──
  async function alternarStatus(row, item) {
    var ativar = !row.ATIVO;
    var nome = row.NM_USUARIO || "ID " + row.ID_USUARIO;
    var confirmado = await confirmarAcao({
      variant: ativar ? "ativar" : "desativar",
      titulo: ativar ? ('Reativar "' + nome + '" como aprovador?') : ('Desativar "' + nome + '"?'),
      mensagem: ativar ? "" : "Deixará de aparecer como aprovador ativo, mas não será excluído.",
    });
    if (!confirmado) return;

    fetch("/api/aprovadores/" + encodeURIComponent(row.ID_USUARIO) + "/status", {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ ativo: ativar }),
    })
      .then(function (res) {
        return res.json().then(function (data) {
          if (!res.ok) throw new Error(data.error || res.statusText);
          return data;
        });
      })
      .then(function () {
        row.ATIVO = ativar;
        item.replaceWith(renderItem(row));
        avisarMudanca();
        if (window.showToast) {
          showToast("success", ativar ? "Reativado" : "Desativado",
            '"' + nome + '" ' + (ativar ? "reativado" : "desativado") + " com sucesso.");
        }
      })
      .catch(function (err) {
        console.error("[aprovadores] erro ao atualizar status:", err);
        if (window.showToast) showToast("error", "Erro", "Não foi possível atualizar o status. " + err.message);
      });
  }

  if (btnSaveAdd) btnSaveAdd.addEventListener("click", saveAdd);
  if (btnSaveEdit) btnSaveEdit.addEventListener("click", saveEdit);
  if (addTrigger) addTrigger.addEventListener("click", limparFormulario);
  if (addIdInput) {
    addIdInput.addEventListener("change", function () {
      consultarMdm(addIdInput, addMatriculaInput, addNomeInput);
    });
  }
  if (editIdInput) {
    editIdInput.addEventListener("change", function () {
      consultarMdm(editIdInput, editMatriculaInput, editNomeInput);
    });
  }

  // CONSULTA DUPLICADA (corrigida): este arquivo é carregado no fim do
  // <body>, então document.readyState já era "interactive" quando ele
  // rodava — o if disparava loadAprovadores() na hora E o listener de
  // DOMContentLoaded disparava de novo em seguida. Eram 2x GET
  // /api/aprovadores (2 consultas ao Azure SQL, com JOIN no MDM) em todo
  // carregamento do admin. Agora roda uma vez só, nos dois cenários.
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", loadAprovadores, { once: true });
  } else {
    loadAprovadores();
  }
})();
