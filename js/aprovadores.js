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
  var btnSaveAdd = document.getElementById("btnSaveAddAprovador");
  var addTrigger = document.querySelector('[data-modal-open="modalAddAprovador"]');

  // Busca de pessoa no MDM (modal "Novo Aprovador"): o ID_USUARIO não é
  // mais digitado — vem de quem o usuário escolher na lista. Os campos
  // abaixo só EXIBEM os dados do MDM (readonly no HTML).
  var addBuscaInput = document.getElementById("addAprovadorBusca");
  var addSugestoesEl = document.getElementById("addAprovadorSugestoes");
  var addCampos = {
    NM_USUARIO: document.getElementById("addAprovadorNome"),
    CD_MATRICULA: document.getElementById("addAprovadorMatricula"),
    CD_EMAIL: document.getElementById("addAprovadorEmail"),
    NM_POSICAO: document.getElementById("addAprovadorCargo"),
    NM_ESTADO: document.getElementById("addAprovadorEstado"),
    NM_CIDADE: document.getElementById("addAprovadorCidade"),
  };
  // Vínculo interno com o registro escolhido: é o que vai no POST.
  var idSelecionado = null;

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
  // Escolhe-se a PESSOA, não o ID: o rádio define o critério (nome ou
  // e-mail), a busca sugere até 10 registros do MDM e a seleção
  // preenche os campos de leitura. O POST continua enviando só o
  // ID_USUARIO, agora guardado em idSelecionado.
  function criterioAdd() {
    var marcado = document.querySelector('input[name="addAprovadorCriterio"]:checked');
    return marcado && marcado.value === "email" ? "email" : "nome";
  }

  // Salvar só habilita com alguém realmente escolhido na lista —
  // digitar um nome parecido não basta.
  function definirSelecionado(u) {
    idSelecionado = u ? u.ID_USUARIO : null;
    Object.keys(addCampos).forEach(function (col) {
      if (addCampos[col]) addCampos[col].value = (u && u[col]) || "";
    });
    if (btnSaveAdd) btnSaveAdd.disabled = !idSelecionado;
  }

  function fecharSugestoes() {
    if (!addSugestoesEl) return;
    addSugestoesEl.innerHTML = "";
    addSugestoesEl.hidden = true;
  }

  function mostrarSugestoes(lista) {
    if (!addSugestoesEl) return;
    if (!lista.length) {
      addSugestoesEl.innerHTML =
        '<div class="form-suggest-vazio" data-i18n="adm.noResults">Nenhum usuário encontrado.</div>';
      addSugestoesEl.hidden = false;
      return;
    }
    addSugestoesEl.innerHTML = lista
      .map(function (u, i) {
        return '<div class="form-suggest-item" data-indice="' + i + '">' +
          "<strong>" + escapeHtml(u.NM_USUARIO || "—") + "</strong>" +
          "<span>" + escapeHtml(u.CD_EMAIL || "—") + "</span>" +
        "</div>";
      })
      .join("");
    addSugestoesEl.hidden = false;

    Array.prototype.forEach.call(addSugestoesEl.querySelectorAll(".form-suggest-item"), function (el) {
      el.addEventListener("click", function () {
        var u = lista[parseInt(el.dataset.indice, 10)];
        if (!u) return;
        if (addBuscaInput) {
          addBuscaInput.value = (criterioAdd() === "email" ? u.CD_EMAIL : u.NM_USUARIO) || "";
        }
        definirSelecionado(u);
        fecharSugestoes();
      });
    });
  }

  function buscarNoMdm() {
    var termo = addBuscaInput ? addBuscaInput.value.trim() : "";
    // Editar o texto invalida a escolha anterior: senão daria para
    // selecionar uma pessoa, trocar o texto e salvar outra coisa.
    definirSelecionado(null);
    if (termo.length < 2) return fecharSugestoes();

    fetch("/api/aprovadores/mdm?campo=" + encodeURIComponent(criterioAdd()) + "&q=" + encodeURIComponent(termo))
      .then(function (res) {
        return res.json().then(function (data) {
          if (!res.ok) throw new Error(data.error || res.statusText);
          return data;
        });
      })
      .then(mostrarSugestoes)
      .catch(function (err) {
        console.error("[aprovadores] falha ao buscar no MDM:", err);
        fecharSugestoes();
      });
  }

  // Debounce: uma consulta depois que a digitação para, não uma por
  // tecla.
  var timerBusca = null;
  function agendarBusca() {
    clearTimeout(timerBusca);
    timerBusca = setTimeout(buscarNoMdm, 300);
  }

  function limparFormulario() {
    if (addBuscaInput) addBuscaInput.value = "";
    definirSelecionado(null);
    fecharSugestoes();
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
    if (!idSelecionado) {
      if (window.showToast) showToast("warning", "Campo obrigatório", "Busque e selecione o usuário na lista.");
      return;
    }
    if (btnSaveAdd) btnSaveAdd.disabled = true;
    fetch("/api/aprovadores", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ ID_USUARIO: idSelecionado }),
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
        // Reabilita só se ainda houver alguém selecionado: depois de um
        // salvamento bem-sucedido o formulário é limpo e o botão tem de
        // continuar desabilitado.
        if (btnSaveAdd) btnSaveAdd.disabled = !idSelecionado;
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
  // Estado inicial: sem ninguém escolhido, Salvar nasce desabilitado.
  definirSelecionado(null);
  if (addBuscaInput) {
    addBuscaInput.addEventListener("input", agendarBusca);
    // Reabre a lista ao voltar ao campo sem ter escolhido ninguém.
    addBuscaInput.addEventListener("focus", function () {
      if (!idSelecionado && addBuscaInput.value.trim().length >= 2) buscarNoMdm();
    });
  }
  // Trocar o critério recomeça a busca: o termo digitado quase nunca
  // serve para os dois campos.
  Array.prototype.forEach.call(
    document.querySelectorAll('input[name="addAprovadorCriterio"]'),
    function (radio) {
      radio.addEventListener("change", function () {
        limparFormulario();
        if (addBuscaInput) addBuscaInput.focus();
      });
    }
  );
  // Clique fora fecha a lista sem alterar o que já estava escolhido.
  document.addEventListener("click", function (ev) {
    if (!addSugestoesEl || addSugestoesEl.hidden) return;
    if (ev.target === addBuscaInput || addSugestoesEl.contains(ev.target)) return;
    fecharSugestoes();
  });
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
