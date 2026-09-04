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
 * Os dois modais (adicionar e editar) são IGUAIS: escolhe-se a PESSOA
 * numa busca ao MDM e grava-se o ID_USUARIO correspondente — ver
 * criarBuscaMdm(), instanciada uma vez para cada modal.
 *
 *   GET  /api/aprovadores            lista (join com o MDM)
 *   GET  /api/aprovadores/mdm        busca por nome ou e-mail (top 10)
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
  var addTrigger = document.querySelector('[data-modal-open="modalAddAprovador"]');
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
        '<div class="admin-item-sub">' + escapeHtml(row.NM_POSICAO || "—") + "</div>" +
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

  // ── Busca de pessoa no MDM ──
  // Componente único usado pelos DOIS modais (adicionar e editar): o
  // dado escolhido é o mesmo (ID_USUARIO) e a tela é a mesma, então
  // duplicar a lógica só criaria duas versões para divergirem depois.
  // cfg.prefixo casa com os ids do HTML (addAprovador* / editAprovador*).
  function criarBuscaMdm(cfg) {
    var el = function (sufixo) { return document.getElementById(cfg.prefixo + sufixo); };
    var buscaInput = el("Busca");
    var sugestoesEl = el("Sugestoes");
    var btnSalvar = document.getElementById(cfg.btnSalvar);
    var campos = {
      NM_USUARIO: el("Nome"),
      CD_MATRICULA: el("Matricula"),
      CD_EMAIL: el("Email"),
      NM_POSICAO: el("Cargo"),
      NM_ESTADO: el("Estado"),
      NM_CIDADE: el("Cidade"),
    };
    // Vínculo interno com o registro escolhido: é o que vai no salvamento.
    var idSelecionado = null;
    var timerBusca = null;

    function criterio() {
      var marcado = document.querySelector('input[name="' + cfg.prefixo + 'Criterio"]:checked');
      return marcado && marcado.value === "email" ? "email" : "nome";
    }

    // O rótulo do campo de busca acompanha o critério escolhido: "Nome"
    // ou "E-mail" no lugar do genérico "Usuário".
    //
    // O texto vem do rótulo do PRÓPRIO rádio, que o i18n da tela já
    // traduziu — assim não há dicionário duplicado aqui e o rótulo sai
    // certo em qualquer idioma. A chave data-i18n também é trocada, para
    // que uma troca de idioma feita depois retraduza o rótulo sozinha
    // (translatePanel, em admin.html, varre todo [data-i18n]).
    var grupoBusca = buscaInput ? buscaInput.closest(".form-suggest-wrap") : null;
    var rotuloBusca = grupoBusca ? grupoBusca.querySelector(".form-label") : null;

    function ajustarRotuloBusca() {
      if (!rotuloBusca) return;
      var porEmail = criterio() === "email";
      var chave = porEmail ? "adm.byEmail" : "adm.byName";
      var fonte = document.querySelector('.form-radios [data-i18n="' + chave + '"]');
      rotuloBusca.setAttribute("data-i18n", chave);
      rotuloBusca.textContent = fonte ? fonte.textContent.trim() : (porEmail ? "E-mail" : "Nome");
    }

    // Salvar só habilita com alguém realmente escolhido na lista —
    // digitar um nome parecido não basta.
    function definirSelecionado(u) {
      idSelecionado = u ? u.ID_USUARIO : null;
      Object.keys(campos).forEach(function (col) {
        if (campos[col]) campos[col].value = (u && u[col]) || "";
      });
      if (btnSalvar) btnSalvar.disabled = !idSelecionado;
    }

    function fecharSugestoes() {
      if (!sugestoesEl) return;
      sugestoesEl.innerHTML = "";
      sugestoesEl.hidden = true;
    }

    function avisoSugestoes(texto, chaveI18n) {
      if (!sugestoesEl) return;
      sugestoesEl.innerHTML = '<div class="form-suggest-vazio"' +
        (chaveI18n ? ' data-i18n="' + chaveI18n + '"' : "") + ">" + escapeHtml(texto) + "</div>";
      sugestoesEl.hidden = false;
    }

    function mostrarSugestoes(lista) {
      if (!sugestoesEl) return;
      if (!lista.length) return avisoSugestoes("Nenhum usuário encontrado.", "adm.noResults");

      sugestoesEl.innerHTML = lista
        .map(function (u, i) {
          return '<div class="form-suggest-item" data-indice="' + i + '">' +
            "<strong>" + escapeHtml(u.NM_USUARIO || "—") + "</strong>" +
            "<span>" + escapeHtml(u.CD_EMAIL || "—") + "</span>" +
          "</div>";
        })
        .join("");
      sugestoesEl.hidden = false;

      Array.prototype.forEach.call(sugestoesEl.querySelectorAll(".form-suggest-item"), function (item) {
        item.addEventListener("click", function () {
          var u = lista[parseInt(item.dataset.indice, 10)];
          if (!u) return;
          if (buscaInput) buscaInput.value = (criterio() === "email" ? u.CD_EMAIL : u.NM_USUARIO) || "";
          definirSelecionado(u);
          fecharSugestoes();
        });
      });
    }

    function buscar() {
      var termo = buscaInput ? buscaInput.value.trim() : "";
      // Editar o texto invalida a escolha anterior: senão daria para
      // selecionar uma pessoa, trocar o texto e salvar outra coisa.
      definirSelecionado(null);
      if (termo.length < 2) return fecharSugestoes();

      fetch("/api/aprovadores/mdm?campo=" + encodeURIComponent(criterio()) + "&q=" + encodeURIComponent(termo))
        .then(function (res) {
          // Lê como texto antes de interpretar: quando a rota não existe
          // no servidor publicado, a resposta é o HTML de 404 e um
          // res.json() direto estouraria com "Unexpected token <" —
          // mensagem que não ajuda a descobrir que faltou subir o
          // server.js.
          return res.text().then(function (txt) {
            var dados = null;
            try { dados = JSON.parse(txt); } catch (e) { /* resposta não-JSON */ }
            if (!res.ok) {
              throw new Error((dados && dados.error) || "HTTP " + res.status + " em /api/aprovadores/mdm");
            }
            if (!Array.isArray(dados)) {
              throw new Error("Resposta inesperada de /api/aprovadores/mdm (HTTP " + res.status + ")");
            }
            return dados;
          });
        })
        .then(mostrarSugestoes)
        .catch(function (err) {
          // Falha NUNCA fica muda: fechar a lista em silêncio faz a busca
          // parecer "não achou nada" quando a consulta na verdade quebrou.
          console.error("[aprovadores] falha ao buscar no MDM:", err);
          avisoSugestoes("Erro ao buscar no MDM: " + err.message);
        });
    }

    // Debounce: uma consulta depois que a digitação para, não uma por tecla.
    function agendar() {
      clearTimeout(timerBusca);
      timerBusca = setTimeout(buscar, 300);
    }

    function limpar() {
      if (buscaInput) buscaInput.value = "";
      definirSelecionado(null);
      fecharSugestoes();
    }

    if (buscaInput) {
      buscaInput.addEventListener("input", agendar);
      // Reabre a lista ao voltar ao campo sem ter escolhido ninguém.
      buscaInput.addEventListener("focus", function () {
        if (!idSelecionado && buscaInput.value.trim().length >= 2) buscar();
      });
    }
    // Trocar o critério recomeça a busca: o termo digitado quase nunca
    // serve para os dois campos.
    Array.prototype.forEach.call(
      document.querySelectorAll('input[name="' + cfg.prefixo + 'Criterio"]'),
      function (radio) {
        radio.addEventListener("change", function () {
          limpar();
          ajustarRotuloBusca();
          if (buscaInput) buscaInput.focus();
        });
      }
    );
    // Clique fora fecha a lista sem alterar o que já estava escolhido.
    document.addEventListener("click", function (ev) {
      if (!sugestoesEl || sugestoesEl.hidden) return;
      if (ev.target === buscaInput || sugestoesEl.contains(ev.target)) return;
      fecharSugestoes();
    });

    definirSelecionado(null); // estado inicial: Salvar desabilitado
    ajustarRotuloBusca();     // rótulo já nasce igual ao critério marcado

    return {
      /** ID_USUARIO escolhido, ou null. */
      id: function () { return idSelecionado; },
      limpar: limpar,
      /** Abre já preenchido com um registro conhecido (modo edição). */
      preencher: function (u) {
        definirSelecionado(u);
        if (buscaInput) buscaInput.value = (criterio() === "email" ? u.CD_EMAIL : u.NM_USUARIO) || "";
        fecharSugestoes();
      },
    };
  }

  var buscaAdd = criarBuscaMdm({ prefixo: "addAprovador", btnSalvar: "btnSaveAddAprovador" });
  var buscaEdit = criarBuscaMdm({ prefixo: "editAprovador", btnSalvar: "btnSaveEditAprovador" });

  // Avisa as outras abas que kzn_aprovador mudou: a coluna "Função" da
  // aba Usuários é derivada daqui (ver window.VBMDados em vbm-app.js).
  function avisarMudanca() {
    if (window.VBMDados) window.VBMDados.mudou("aprovadores");
  }

  var btnSaveAdd = document.getElementById("btnSaveAddAprovador");
  var btnSaveEdit = document.getElementById("btnSaveEditAprovador");

  function saveAdd() {
    var id = buscaAdd.id();
    if (!id) {
      if (window.showToast) showToast("warning", "Campo obrigatório", "Busque e selecione o usuário na lista.");
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
        buscaAdd.limpar();
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
        if (btnSaveAdd) btnSaveAdd.disabled = !buscaAdd.id();
      });
  }

  // ── Editar ──
  // Mesma tela do adicionar: escolhe-se a PESSOA na busca ao MDM. A
  // diferença é que o modal abre já preenchido com o aprovador atual, e
  // o salvamento é um PUT no ID original (trocar a pessoa aponta o
  // registro para outra — ver cabeçalho).
  //
  // O preenchimento reusa o que a listagem já trouxe do mesmo join com o
  // MDM: nenhuma consulta extra ao abrir o modal.
  function abrirEdicao(row) {
    idEmEdicao = row.ID_USUARIO;
    buscaEdit.preencher({
      ID_USUARIO: row.ID_USUARIO,
      NM_USUARIO: row.NM_USUARIO,
      CD_MATRICULA: row.CD_MATRICULA,
      CD_EMAIL: row.DS_EMAIL, // a listagem devolve o e-mail com esse alias
      NM_POSICAO: row.NM_POSICAO,
      NM_ESTADO: row.NM_ESTADO,
      NM_CIDADE: row.NM_CIDADE,
    });
    if (window.openModal) openModal("modalEditAprovador");
  }

  function saveEdit() {
    var id = buscaEdit.id();
    if (!id) {
      if (window.showToast) showToast("warning", "Campo obrigatório", "Busque e selecione o usuário na lista.");
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
        if (btnSaveEdit) btnSaveEdit.disabled = !buscaEdit.id();
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
  // Abrir "Novo Aprovador" sempre começa do zero; a edição é preenchida
  // por abrirEdicao(). Os listeners da busca ficam dentro de
  // criarBuscaMdm, um conjunto por modal.
  if (addTrigger) addTrigger.addEventListener("click", buscaAdd.limpar);

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
