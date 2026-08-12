/**
 * VBM Kaizen — aba "Aprovadores" (admin.html)
 *
 * Conecta o painel à tabela `kzn_aprovador` via API própria do
 * server.js (GET/POST/PUT/DELETE /api/aprovadores). Só roda nesta
 * página: todo o código é guardado por `if (!listEl) return;`.
 *
 * Depende de funções globais já definidas em vbm-app.js:
 * openModal / closeModal / showToast.
 */
(function () {
  var listEl = document.getElementById("aprovadoresList");
  if (!listEl) return; // esta página não tem a aba Aprovadores

  var stateEl = document.getElementById("aprovadoresState");
  var countEl = document.getElementById("aprovadoresCount");
  var connStatusEl = document.getElementById("aprovadoresConnStatus");
  var reloadBtn = document.getElementById("btnReloadAprovadores");

  var addIdInput = document.getElementById("addAprovadorIdUsuario");
  var addMatriculaInput = document.getElementById("addAprovadorMatricula");
  var addNomeInput = document.getElementById("addAprovadorNome");
  var btnSaveAdd = document.getElementById("btnSaveAddAprovador");

  var editIdInput = document.getElementById("editAprovadorIdUsuario");
  var editMatriculaInput = document.getElementById("editAprovadorMatricula");
  var editNomeInput = document.getElementById("editAprovadorNome");
  var btnSaveEdit = document.getElementById("btnSaveEditAprovador");

  function escapeHtml(str) {
    return String(str == null ? "" : str).replace(/[&<>"']/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c];
    });
  }

  function initials(name) {
    var parts = String(name || "").trim().split(/\s+/).filter(Boolean);
    if (!parts.length) return "?";
    return (parts[0][0] + (parts[1] ? parts[1][0] : "")).toUpperCase();
  }

  function formatDate(value) {
    if (!value) return "—";
    var d = new Date(value);
    if (isNaN(d.getTime())) return String(value);
    return d.toLocaleString("pt-BR");
  }

  function setState(msg, isError) {
    if (!stateEl) return;
    if (msg) {
      stateEl.style.display = "";
      stateEl.style.color = isError ? "var(--vbm-red, #dc2626)" : "var(--vbm-mid)";
      stateEl.textContent = msg;
      listEl.style.display = "none";
    } else {
      stateEl.style.display = "none";
      listEl.style.display = "";
    }
  }

  function renderList(rows) {
    listEl.innerHTML = "";
    if (countEl) countEl.textContent = rows.length + " " + (rows.length === 1 ? "aprovador" : "aprovadores");

    if (!rows.length) {
      setState("Nenhum aprovador cadastrado ainda.", false);
      return;
    }
    setState(null);

    rows.forEach(function (row) {
      var item = document.createElement("div");
      item.className = "admin-item";
      item.innerHTML =
        '<div class="admin-avatar" style="background:linear-gradient(135deg,#3cb5e5,#1a8bbf);">' + escapeHtml(initials(row.NM_USER)) + "</div>" +
        '<div class="admin-item-body">' +
          '<div class="admin-item-name">' + escapeHtml(row.NM_USER) + "</div>" +
          '<div class="admin-item-sub">Matrícula ' + escapeHtml(row.CD_MATRICULA) + " · ID " + escapeHtml(row.ID_USUARIO) + "</div>" +
          '<div class="admin-item-sub">Atualizado em ' + escapeHtml(formatDate(row.DT_ATUALIZACAO)) + "</div>" +
        "</div>" +
        '<div class="admin-item-actions">' +
          '<button class="btn-icon btn-icon-blue btn-icon-sm" title="Editar" data-action="edit"><i class="fa-solid fa-pen"></i></button>' +
          '<button class="btn-icon btn-icon-red btn-icon-sm" title="Excluir" data-action="delete"><i class="fa-solid fa-trash"></i></button>' +
        "</div>";

      item.querySelector('[data-action="edit"]').addEventListener("click", function () {
        openEditModal(row);
      });
      item.querySelector('[data-action="delete"]').addEventListener("click", function () {
        deleteAprovador(row);
      });

      listEl.appendChild(item);
    });
  }

  function loadAprovadores() {
    setState("Carregando aprovadores...", false);
    if (connStatusEl) connStatusEl.textContent = "";
    return fetch("/api/aprovadores")
      .then(function (res) {
        if (!res.ok) return res.json().then(function (e) { throw new Error(e.error || res.statusText); });
        return res.json();
      })
      .then(function (rows) {
        renderList(rows);
        if (connStatusEl) connStatusEl.textContent = "Conectado ✓";
      })
      .catch(function (err) {
        console.error("[aprovadores] erro ao carregar:", err);
        setState("Erro ao carregar aprovadores: " + err.message, true);
        if (connStatusEl) connStatusEl.textContent = "Falha na conexão";
        showToast("error", "Erro", "Não foi possível carregar os aprovadores. " + err.message);
      });
  }

  function openEditModal(row) {
    editIdInput.value = row.ID_USUARIO;
    editMatriculaInput.value = row.CD_MATRICULA || "";
    editNomeInput.value = row.NM_USER || "";
    openModal("modalEditAprovador");
  }

  function saveAdd() {
    var payload = {
      ID_USUARIO: addIdInput.value,
      CD_MATRICULA: addMatriculaInput.value,
      NM_USER: addNomeInput.value,
    };
    if (!payload.ID_USUARIO || !payload.CD_MATRICULA || !payload.NM_USER.trim()) {
      showToast("warning", "Campos obrigatórios", "Preencha ID_USUARIO, CD_MATRICULA e o nome antes de salvar.");
      return;
    }
    btnSaveAdd.disabled = true;
    fetch("/api/aprovadores", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    })
      .then(function (res) {
        return res.json().then(function (data) {
          if (!res.ok) throw new Error(data.error || res.statusText);
          return data;
        });
      })
      .then(function () {
        closeModal("modalAddAprovador");
        addIdInput.value = "";
        addMatriculaInput.value = "";
        addNomeInput.value = "";
        showToast("success", "Aprovador adicionado", "Aprovador cadastrado com sucesso!");
        loadAprovadores();
      })
      .catch(function (err) {
        showToast("error", "Erro ao inserir", err.message);
      })
      .finally(function () {
        btnSaveAdd.disabled = false;
      });
  }

  function saveEdit() {
    var id = editIdInput.value;
    var payload = {
      CD_MATRICULA: editMatriculaInput.value,
      NM_USER: editNomeInput.value,
    };
    btnSaveEdit.disabled = true;
    fetch("/api/aprovadores/" + encodeURIComponent(id), {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    })
      .then(function (res) {
        return res.json().then(function (data) {
          if (!res.ok) throw new Error(data.error || res.statusText);
          return data;
        });
      })
      .then(function () {
        closeModal("modalEditAprovador");
        showToast("success", "Salvo", "Aprovador atualizado com sucesso!");
        loadAprovadores();
      })
      .catch(function (err) {
        showToast("error", "Erro ao atualizar", err.message);
      })
      .finally(function () {
        btnSaveEdit.disabled = false;
      });
  }

  function deleteAprovador(row) {
    if (!window.confirm('Excluir o aprovador "' + row.NM_USER + '" (ID ' + row.ID_USUARIO + ')? Esta ação não pode ser desfeita.')) {
      return;
    }
    fetch("/api/aprovadores/" + encodeURIComponent(row.ID_USUARIO), { method: "DELETE" })
      .then(function (res) {
        return res.json().then(function (data) {
          if (!res.ok) throw new Error(data.error || res.statusText);
          return data;
        });
      })
      .then(function () {
        showToast("success", "Excluído", "Aprovador removido com sucesso.");
        loadAprovadores();
      })
      .catch(function (err) {
        showToast("error", "Erro ao excluir", err.message);
      });
  }

  if (btnSaveAdd) btnSaveAdd.addEventListener("click", saveAdd);
  if (btnSaveEdit) btnSaveEdit.addEventListener("click", saveEdit);
  if (reloadBtn) reloadBtn.addEventListener("click", loadAprovadores);

  document.addEventListener("DOMContentLoaded", loadAprovadores);
  if (document.readyState === "complete" || document.readyState === "interactive") {
    loadAprovadores();
  }
})();
