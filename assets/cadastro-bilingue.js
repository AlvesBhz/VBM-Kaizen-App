/**
 * VBM Kaizen — motor compartilhado dos cadastros bilíngues do admin.html.
 *
 * Categorias, Pot. Replicação, Red. Desperdícios e Resultados têm o
 * MESMO desenho no banco (ver DER: PK + ID_IDIOMA + NM/DS/URL_ICONE/
 * SG_ATIVO, 1 linha por idioma) e a mesma tela (lista de .admin-item +
 * modais Add/Edit bilíngues). Este arquivo define o motor único
 * (window.criarCadastroBilingue) usado pelos 4 arquivos de aba —
 * assets/categorias.js, assets/replicacao.js, assets/desperdicios.js
 * e assets/resultados.js — cada um só passando a configuração da sua
 * própria aba (rota, ids dos elementos, textos, limites de campo).
 * Precisa ser carregado ANTES desses 4 arquivos.
 *
 * Rotas REST que cada aba usa (registradas em server.js por
 * registrarCadastroBilingue(), o espelho desta fábrica no servidor):
 *
 *   GET    /api/<rota>            lista (com SG_ATIVO real)
 *   GET    /api/<rota>/:id        as 2 linhas (PT/EN) para editar
 *   POST   /api/<rota>            criar
 *   PUT    /api/<rota>/:id        editar (PT + EN)
 *   PUT    /api/<rota>/:id/status ativar/desativar (SG_ATIVO)
 *
 * Nada é estático: a lista inteira vem do banco a cada carregamento,
 * inclusive o estado ativo/inativo. Falha ao carregar mostra erro com
 * "tentar novamente" (não há fallback local — a lista É o banco).
 */
window.criarCadastroBilingue = function (cfg) {
  function escapeHtml(str) {
    var div = document.createElement("div");
    div.textContent = str == null ? "" : String(str);
    return div.innerHTML;
  }

  var list = document.getElementById(cfg.listaId);
  if (!list) return; // esta página não tem esta aba

  var el = function (id) { return document.getElementById(id); };
  var addNamePt = el(cfg.prefixoAdd + "NamePt");
  var addNameEn = el(cfg.prefixoAdd + "NameEn");
  var addDescPt = el(cfg.prefixoAdd + "DescPt");
  var addDescEn = el(cfg.prefixoAdd + "DescEn");
  var addSaveBtn = el(cfg.btnSalvarAddId);
  var addTrigger = document.querySelector('[data-modal-open="' + cfg.modalAddId + '"]');

  var editNamePt = el(cfg.prefixoEdit + "NamePt");
  var editNameEn = el(cfg.prefixoEdit + "NameEn");
  var editDescPt = el(cfg.prefixoEdit + "DescPt");
  var editDescEn = el(cfg.prefixoEdit + "DescEn");
  var editSaveBtn = el(cfg.btnSalvarEditId);

  var idEmEdicao = null;

  // Mesmos limites do server.js (que os tira do DER). A checagem no
  // cliente é só uma resposta mais rápida — o servidor valida de
  // novo antes de gravar, sempre.
  function validar(nomePt, descPt, nomeEn, descEn) {
    if (!nomePt || !descPt || !nomeEn || !descEn) {
      return "Preencha nome e descrição nos dois idiomas antes de salvar.";
    }
    if (nomePt.length > cfg.maxNome || nomeEn.length > cfg.maxNome) {
      return "O nome deve ter no máximo " + cfg.maxNome + " caracteres (em cada idioma).";
    }
    if (descPt.length > cfg.maxDescricao || descEn.length > cfg.maxDescricao) {
      return "A descrição deve ter no máximo " + cfg.maxDescricao + " caracteres (em cada idioma).";
    }
    return null;
  }

  function montarPayload(nomePtEl, descPtEl, nomeEnEl, descEnEl) {
    return {
      pt: { NM: nomePtEl ? nomePtEl.value.trim() : "", DS: descPtEl ? descPtEl.value.trim() : "" },
      en: { NM: nomeEnEl ? nomeEnEl.value.trim() : "", DS: descEnEl ? descEnEl.value.trim() : "" },
    };
  }

  function statusEl(texto, erro) {
    var div = document.createElement("div");
    div.className = "admin-list-status" + (erro ? " is-error" : "");
    div.textContent = texto;
    return div;
  }

  function badgeHtml(qtd) {
    if (!cfg.palavraBadge) return "";
    var texto = qtd == null ? "—" : qtd + " " + (qtd === 1 ? cfg.palavraBadgeSingular : cfg.palavraBadge);
    return '<span class="admin-item-badge">' + escapeHtml(texto) + "</span>";
  }

  function renderItem(reg) {
    var item = document.createElement("div");
    item.className = "admin-item" + (reg.ATIVO ? "" : " admin-item-inactive");
    item.dataset.id = reg.ID;
    item.innerHTML =
      '<div class="admin-item-icon ' + cfg.classeIcone + '">' +
        (reg.URL_ICONE
          ? '<img src="' + escapeHtml(reg.URL_ICONE) + '" alt="" loading="lazy">'
          : '<i class="' + cfg.iconePadrao + '"></i>') +
      "</div>" +
      '<div class="admin-item-body">' +
        '<div class="admin-item-name">' + escapeHtml(reg.NM) + "</div>" +
        '<div class="admin-item-sub">' + escapeHtml(reg.DS) + "</div>" +
      "</div>" +
      badgeHtml(reg.QTD) +
      '<div class="admin-item-actions">' +
        '<button type="button" class="btn-icon btn-icon-blue btn-icon-sm" data-action="editar" title="Editar" data-i18n-title="common.editar"><i class="fa-solid fa-pen"></i></button>' +
        '<button type="button" class="btn-icon ' + (reg.ATIVO ? "btn-icon-red" : "btn-icon-blue") + ' btn-icon-sm" data-action="status" title="' + (reg.ATIVO ? "Desativar" : "Reativar") + '"><i class="fa-solid ' + (reg.ATIVO ? "fa-ban" : "fa-rotate-right") + '"></i></button>' +
      "</div>";

    item.querySelector('[data-action="editar"]').addEventListener("click", function () { abrirEdicao(reg); });
    item.querySelector('[data-action="status"]').addEventListener("click", function () { alternarStatus(reg, item); });
    return item;
  }

  // Recarrega sempre do banco — nunca reaproveita estado anterior,
  // então o ativo/inativo exibido é o SG_ATIVO atual.
  function carregarLista() {
    list.innerHTML = "";
    list.appendChild(statusEl(cfg.textoCarregando, false));

    fetch("/api/" + cfg.rota)
      .then(function (res) {
        if (!res.ok) return res.json().then(function (e) { throw new Error(e.error || res.statusText); });
        return res.json();
      })
      .then(function (registros) {
        list.innerHTML = "";
        if (!registros.length) {
          list.appendChild(statusEl(cfg.textoVazio, false));
          return;
        }
        registros.forEach(function (reg) { list.appendChild(renderItem(reg)); });
      })
      .catch(function (err) {
        console.error("[" + cfg.rota + "] falha ao carregar lista:", err);
        list.innerHTML = "";
        var box = statusEl("", true);
        box.innerHTML = '<i class="fa-solid fa-triangle-exclamation"></i> <span></span>';
        box.querySelector("span").textContent = cfg.textoErro;
        var retry = document.createElement("button");
        retry.className = "btn btn-outline btn-sm";
        retry.type = "button";
        retry.textContent = "Tentar novamente";
        retry.addEventListener("click", carregarLista);
        box.appendChild(retry);
        list.appendChild(box);
      });
  }

  // ── Editar ──
  function abrirEdicao(reg) {
    idEmEdicao = reg.ID;
    if (window.openModal) openModal(cfg.modalEditId);

    fetch("/api/" + cfg.rota + "/" + encodeURIComponent(reg.ID))
      .then(function (res) {
        return res.json().then(function (data) {
          if (!res.ok) throw new Error(data.error || res.statusText);
          return data;
        });
      })
      .then(function (data) {
        // Sempre atribui, mesmo vazio — nunca deixa no campo o texto
        // de uma edição anterior quando o idioma ainda não existe.
        if (editNamePt) editNamePt.value = (data.pt && data.pt.NM) || "";
        if (editNameEn) editNameEn.value = (data.en && data.en.NM) || "";
        if (editDescPt) {
          editDescPt.value = (data.pt && data.pt.DS) || "";
          if (window.updateCategoryDescCounter) updateCategoryDescCounter(editDescPt, cfg.prefixoEdit, cfg.maxDescricao);
        }
        if (editDescEn) editDescEn.value = (data.en && data.en.DS) || "";
      })
      .catch(function (err) {
        console.error("[" + cfg.rota + "] falha ao carregar para edição:", err);
        if (window.showToast) showToast("error", "Erro ao carregar", "Não foi possível buscar os dados no banco. " + err.message);
      });
  }

  function salvarEdicao() {
    if (idEmEdicao == null) {
      if (window.showToast) showToast("error", "Erro", "Registro não identificado — feche e abra o formulário de novo.");
      return;
    }
    var payload = montarPayload(editNamePt, editDescPt, editNameEn, editDescEn);
    var erro = validar(payload.pt.NM, payload.pt.DS, payload.en.NM, payload.en.DS);
    if (erro) {
      if (window.showToast) showToast("warning", "Campo inválido", erro);
      return;
    }

    if (editSaveBtn) editSaveBtn.disabled = true;
    fetch("/api/" + cfg.rota + "/" + encodeURIComponent(idEmEdicao), {
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
        if (window.closeModal) closeModal(cfg.modalEditId);
        if (window.showToast) showToast("success", "Salvo", cfg.rotuloSingular + " atualizado com sucesso!");
        carregarLista();
      })
      .catch(function (err) {
        console.error("[" + cfg.rota + "] falha ao salvar:", err);
        if (window.showToast) showToast("error", "Erro ao salvar", err.message);
      })
      .finally(function () {
        if (editSaveBtn) editSaveBtn.disabled = false;
      });
  }

  // ── Criar ──
  function limparFormularioCriacao() {
    if (addNamePt) addNamePt.value = "";
    if (addNameEn) addNameEn.value = "";
    if (addDescPt) {
      addDescPt.value = "";
      if (window.updateCategoryDescCounter) updateCategoryDescCounter(addDescPt, cfg.prefixoAdd, cfg.maxDescricao);
    }
    if (addDescEn) addDescEn.value = "";
  }

  function salvarCriacao() {
    var payload = montarPayload(addNamePt, addDescPt, addNameEn, addDescEn);
    var erro = validar(payload.pt.NM, payload.pt.DS, payload.en.NM, payload.en.DS);
    if (erro) {
      if (window.showToast) showToast("warning", "Campo inválido", erro);
      return;
    }

    if (addSaveBtn) addSaveBtn.disabled = true;
    fetch("/api/" + cfg.rota, {
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
        limparFormularioCriacao();
        if (window.closeModal) closeModal(cfg.modalAddId);
        if (window.showToast) showToast("success", "Criado", cfg.rotuloSingular + " adicionado com sucesso!");
        carregarLista();
      })
      .catch(function (err) {
        console.error("[" + cfg.rota + "] falha ao criar:", err);
        if (window.showToast) showToast("error", "Erro ao criar", err.message);
      })
      .finally(function () {
        if (addSaveBtn) addSaveBtn.disabled = false;
      });
  }

  // ── Ativar/Desativar — grava SG_ATIVO no banco, nunca só visual ──
  function alternarStatus(reg, item) {
    var ativar = !reg.ATIVO;
    var msg = ativar
      ? 'Reativar "' + reg.NM + '"?'
      : 'Desativar "' + reg.NM + '"? Deixará de aparecer como opção ativa, mas não será excluído.';
    if (!window.confirm(msg)) return;

    fetch("/api/" + cfg.rota + "/" + encodeURIComponent(reg.ID) + "/status", {
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
        reg.ATIVO = ativar;
        item.replaceWith(renderItem(reg));
        if (window.showToast) {
          showToast("success", ativar ? "Reativado" : "Desativado",
            '"' + reg.NM + '" ' + (ativar ? "reativado" : "desativado") + " com sucesso.");
        }
      })
      .catch(function (err) {
        console.error("[" + cfg.rota + "] falha ao atualizar status:", err);
        if (window.showToast) showToast("error", "Erro", "Não foi possível atualizar o status. " + err.message);
      });
  }

  if (editSaveBtn) editSaveBtn.addEventListener("click", salvarEdicao);
  if (addSaveBtn) addSaveBtn.addEventListener("click", salvarCriacao);
  // Limpa o formulário ao abrir — nunca deixa sobrar texto de uma
  // tentativa anterior (evita reenviar sem querer).
  if (addTrigger) addTrigger.addEventListener("click", limparFormularioCriacao);

  carregarLista();
};
