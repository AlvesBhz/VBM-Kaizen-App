/**
 * VBM Kaizen — aba "Categorias" (admin.html).
 *
 * Lista TODAS as categorias reais de GET /api/categorias (server.js ->
 * kzn_categoria + contagem em kzn_pendenciaconsolidada). Nenhum item
 * estático: a lista inteira vem do banco a cada carregamento da tela,
 * inclusive o status ativo/inativo (SG_ATIVO).
 *
 * Cada card tem 2 ações:
 *   - Editar: modal bilíngue PT/EN (GET/PUT /api/categorias/:id).
 *   - Ativar/Desativar: grava SG_ATIVO no banco
 *     (PUT /api/categorias/:id/status) — nunca só visual.
 *
 * Falha ao carregar a lista: mostra erro com botão de tentar de novo
 * (não há mais fallback estático — a lista É o banco).
 */
(function () {
  var list = document.getElementById("categoriasList");
  if (!list) return; // esta página não tem a aba Categorias

  var loadingText = list.dataset.loadingText || "Carregando…";
  var errorText = list.dataset.errorText || "Não foi possível carregar os dados.";

  var namePtEl = document.getElementById("catEditNamePt");
  var nameEnEl = document.getElementById("catEditNameEn");
  var descPtEl = document.getElementById("catEditDescPt");
  var descEnEl = document.getElementById("catEditDescEn");
  var saveBtn = document.getElementById("btnSaveEditCategoria");
  var diagEl = document.getElementById("catEditDiagnostico");

  var categoriaEmEdicaoId = null; // ID_CATEGORIA aberto no modal de edição no momento

  function escapeHtml(str) {
    var div = document.createElement("div");
    div.textContent = str == null ? "" : String(str);
    return div.innerHTML;
  }

  function badgeTexto(qtd) {
    if (qtd == null) return "—";
    return qtd + " " + (qtd === 1 ? "kaizen" : "kaizens");
  }

  function renderItem(cat) {
    var item = document.createElement("div");
    item.className = "admin-item" + (cat.ATIVO ? "" : " admin-item-inactive");
    item.dataset.id = cat.ID_CATEGORIA;
    item.innerHTML =
      '<div class="admin-item-icon green">' +
        (cat.URL_ICONE ? '<img src="' + escapeHtml(cat.URL_ICONE) + '" alt="" loading="lazy">' : '<i class="fa-solid fa-tag"></i>') +
      "</div>" +
      '<div class="admin-item-body">' +
        '<div class="admin-item-name">' + escapeHtml(cat.NM_CATEGORIA) + "</div>" +
        '<div class="admin-item-sub">' + escapeHtml(cat.DS_CATEGORIA) + "</div>" +
      "</div>" +
      '<span class="admin-item-badge">' + badgeTexto(cat.QTD_KAIZENS) + "</span>" +
      '<div class="admin-item-actions">' +
        '<button type="button" class="btn-icon btn-icon-blue btn-icon-sm" data-action="editar" title="Editar"><i class="fa-solid fa-pen"></i></button>' +
        '<button type="button" class="btn-icon ' + (cat.ATIVO ? "btn-icon-red" : "btn-icon-blue") + ' btn-icon-sm" data-action="status" title="' + (cat.ATIVO ? "Desativar" : "Reativar") + '"><i class="fa-solid ' + (cat.ATIVO ? "fa-ban" : "fa-rotate-right") + '"></i></button>' +
      "</div>";

    item.querySelector('[data-action="editar"]').addEventListener("click", function () {
      abrirEdicao(cat);
    });
    item.querySelector('[data-action="status"]').addEventListener("click", function () {
      alternarStatus(cat, item);
    });
    return item;
  }

  function renderLista(categorias) {
    list.innerHTML = "";
    if (!categorias.length) {
      var empty = document.createElement("div");
      empty.className = "admin-list-status";
      empty.textContent = "Nenhuma categoria cadastrada.";
      list.appendChild(empty);
      return;
    }
    categorias.forEach(function (cat) { list.appendChild(renderItem(cat)); });
  }

  function renderCarregando() {
    list.innerHTML = "";
    var el = document.createElement("div");
    el.className = "admin-list-status";
    el.textContent = loadingText;
    list.appendChild(el);
  }

  function renderErro() {
    list.innerHTML = "";
    var err = document.createElement("div");
    err.className = "admin-list-status is-error";
    err.innerHTML = '<i class="fa-solid fa-triangle-exclamation"></i> <span></span>';
    err.querySelector("span").textContent = errorText;
    var retry = document.createElement("button");
    retry.className = "btn btn-outline btn-sm";
    retry.type = "button";
    retry.textContent = "Tentar novamente";
    retry.addEventListener("click", carregarLista);
    err.appendChild(retry);
    list.appendChild(err);
  }

  // Chamado no carregamento da tela E depois de qualquer edição/status
  // — sempre busca do zero, nunca reaproveita estado velho, então o
  // ativo/inativo mostrado é sempre o que está no banco agora.
  function carregarLista() {
    renderCarregando();
    fetch("/api/categorias")
      .then(function (res) {
        if (!res.ok) return res.json().then(function (e) { throw new Error(e.error || res.statusText); });
        return res.json();
      })
      .then(renderLista)
      .catch(function (err) {
        console.error("[categorias] falha ao carregar lista:", err);
        renderErro();
      });
  }

  // ── Editar (modal bilíngue PT/EN) ──
  function abrirEdicao(cat) {
    categoriaEmEdicaoId = cat.ID_CATEGORIA;
    if (window.openModal) openModal("modalEditCategoria");

    fetch("/api/categorias/" + encodeURIComponent(cat.ID_CATEGORIA))
      .then(function (res) {
        return res.json().then(function (data) {
          if (!res.ok) throw new Error(data.error || res.statusText);
          return data;
        });
      })
      .then(function (data) {
        // Sempre atribui (mesmo vazio) — nunca deixa texto de uma
        // edição anterior no campo quando o idioma não existe ainda.
        if (namePtEl) namePtEl.value = (data.pt && data.pt.NM_CATEGORIA) || "";
        if (nameEnEl) nameEnEl.value = (data.en && data.en.NM_CATEGORIA) || "";
        if (descPtEl) {
          descPtEl.value = (data.pt && data.pt.DS_CATEGORIA) || "";
          if (window.updateCategoryDescCounter) updateCategoryDescCounter(descPtEl, "catEdit");
        }
        if (descEnEl) descEnEl.value = (data.en && data.en.DS_CATEGORIA) || "";

        if (diagEl) {
          if (data.pt && data.en) {
            diagEl.style.display = "none";
          } else {
            diagEl.style.display = "";
            diagEl.textContent =
              "ID_CATEGORIA = " + data.ID_CATEGORIA + " — no banco: " +
              "PT " + (data.pt ? "encontrado" : "NÃO encontrado") + ", " +
              "EN " + (data.en ? "encontrado" : "NÃO encontrado") +
              ". Salvar cria a linha que faltar com este mesmo ID_CATEGORIA.";
          }
        }
      })
      .catch(function (err) {
        console.error("[categorias] falha ao carregar categoria para edição:", err);
        if (window.showToast) showToast("error", "Erro ao carregar", "Não foi possível buscar os dados da categoria no banco. " + err.message);
      });
  }

  function salvarEdicao() {
    if (categoriaEmEdicaoId == null) {
      if (window.showToast) showToast("error", "Erro", "Categoria não identificada — feche e abra o formulário de novo.");
      return;
    }
    var payload = {
      pt: { NM_CATEGORIA: namePtEl ? namePtEl.value.trim() : "", DS_CATEGORIA: descPtEl ? descPtEl.value.trim() : "" },
      en: { NM_CATEGORIA: nameEnEl ? nameEnEl.value.trim() : "", DS_CATEGORIA: descEnEl ? descEnEl.value.trim() : "" },
    };
    if (!payload.pt.NM_CATEGORIA || !payload.pt.DS_CATEGORIA || !payload.en.NM_CATEGORIA || !payload.en.DS_CATEGORIA) {
      if (window.showToast) showToast("warning", "Campos obrigatórios", "Preencha nome e descrição nos dois idiomas antes de salvar.");
      return;
    }

    if (saveBtn) saveBtn.disabled = true;
    fetch("/api/categorias/" + encodeURIComponent(categoriaEmEdicaoId), {
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
        if (diagEl) diagEl.style.display = "none";
        if (window.closeModal) closeModal("modalEditCategoria");
        if (window.showToast) showToast("success", "Salvo", "Categoria atualizada com sucesso!");
        carregarLista(); // recarrega do banco pra refletir o nome/descrição novos no card
      })
      .catch(function (err) {
        console.error("[categorias] falha ao salvar categoria:", err);
        if (window.showToast) showToast("error", "Erro ao salvar", err.message);
      })
      .finally(function () {
        if (saveBtn) saveBtn.disabled = false;
      });
  }

  // ── Ativar/Desativar — grava SG_ATIVO no banco, nunca só visual ──
  function alternarStatus(cat, item) {
    var ativar = !cat.ATIVO;
    var msg = ativar
      ? 'Reativar "' + cat.NM_CATEGORIA + '"?'
      : 'Desativar "' + cat.NM_CATEGORIA + '"? Ela deixará de aparecer como opção ativa, mas não será excluída.';
    if (!window.confirm(msg)) return;

    fetch("/api/categorias/" + encodeURIComponent(cat.ID_CATEGORIA) + "/status", {
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
        cat.ATIVO = ativar;
        item.replaceWith(renderItem(cat));
        if (window.showToast) {
          showToast(
            "success",
            ativar ? "Reativada" : "Desativada",
            'Categoria "' + cat.NM_CATEGORIA + '" ' + (ativar ? "reativada" : "desativada") + " com sucesso."
          );
        }
      })
      .catch(function (err) {
        console.error("[categorias] falha ao atualizar status:", err);
        if (window.showToast) showToast("error", "Erro", "Não foi possível atualizar o status. " + err.message);
      });
  }

  if (saveBtn) saveBtn.addEventListener("click", salvarEdicao);

  carregarLista();
})();
