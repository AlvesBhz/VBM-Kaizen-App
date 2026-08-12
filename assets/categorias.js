/**
 * VBM Kaizen — aba "Categorias" (admin.html), 1ª fase.
 *
 * Preenche só o card em destaque (o primeiro da lista) com dados reais
 * de GET /api/categorias (server.js -> kzn_categoria + contagem em
 * kzn_pendenciaconsolidada). Os demais cards continuam estáticos.
 *
 * Falha ao carregar o card: mantém o conteúdo estático já presente no
 * HTML como fallback (nada quebra visualmente) — só loga no console.
 */
(function () {
  var card = document.getElementById("categoriaCardDestaque");
  if (!card) return; // esta página não tem o card de Categorias

  var iconeEl = document.getElementById("categoriaCardIcone");
  var nomeEl = document.getElementById("categoriaCardNome");
  var descricaoEl = document.getElementById("categoriaCardDescricao");
  var badgeEl = document.getElementById("categoriaCardBadge");

  // Edição (modal modalEditCategoria, compartilhado por todos os cards
  // no HTML — só o botão Editar DESTE card, o dinâmico, é religado
  // abaixo pra buscar/gravar de verdade; os outros 6 continuam com o
  // comportamento estático de antes).
  var editBtn = card.querySelector('[data-modal-open="modalEditCategoria"]');
  var namePtEl = document.getElementById("catEditNamePt");
  var nameEnEl = document.getElementById("catEditNameEn");
  var descPtEl = document.getElementById("catEditDescPt");
  var descEnEl = document.getElementById("catEditDescEn");
  var saveBtn = document.getElementById("btnSaveEditCategoria");

  var categoriaId = null; // ID_CATEGORIA em destaque, assim que descoberto (ver garantirCategoriaId)

  function aplicarIcone(url) {
    if (!iconeEl || !url) return;
    var img = document.createElement("img");
    img.src = url;
    img.alt = "";
    img.loading = "lazy";
    iconeEl.innerHTML = "";
    iconeEl.appendChild(img);
  }

  function aplicarBadge(qtd) {
    if (!badgeEl) return;
    if (qtd == null) {
      badgeEl.textContent = "—";
      return;
    }
    badgeEl.textContent = qtd + " " + (qtd === 1 ? "kaizen" : "kaizens");
  }

  function carregarCard() {
    return fetch("/api/categorias")
      .then(function (res) {
        if (!res.ok) return res.json().then(function (e) { throw new Error(e.error || res.statusText); });
        return res.json();
      })
      .then(function (categoria) {
        if (!categoria) return null; // nenhuma categoria cadastrada ainda: mantém o card estático
        categoriaId = categoria.ID_CATEGORIA;
        if (nomeEl) nomeEl.textContent = categoria.NM_CATEGORIA || "";
        if (descricaoEl) descricaoEl.textContent = categoria.DS_CATEGORIA || "";
        aplicarIcone(categoria.URL_ICONE);
        aplicarBadge(categoria.QTD_KAIZENS);
        return categoriaId;
      });
  }

  // Garante o ID_CATEGORIA antes de editar — se o card ainda não
  // carregou (ou o load inicial falhou), busca de novo agora em vez de
  // desistir: quem clicou em Editar precisa mesmo ir ao banco, não só
  // reaproveitar um estado que pode nem ter chegado a existir ainda.
  function garantirCategoriaId() {
    if (categoriaId != null) return Promise.resolve(categoriaId);
    return carregarCard();
  }

  // Editar: garante o ID_CATEGORIA e então busca as 2 linhas (PT/EN)
  // desse registro no banco, populando o modal com dado fresco — nunca
  // com o texto estático do HTML.
  function carregarParaEdicao() {
    garantirCategoriaId()
      .then(function (id) {
        if (id == null) throw new Error("Categoria ainda não carregada.");
        return fetch("/api/categorias/" + encodeURIComponent(id)).then(function (res) {
          return res.json().then(function (data) {
            if (!res.ok) throw new Error(data.error || res.statusText);
            return data;
          });
        });
      })
      .then(function (data) {
        // Sempre atribui (mesmo vazio) — nunca deixa o texto estático
        // antigo do HTML no campo quando o idioma não existe ainda no
        // banco (ex.: categoria só tem a linha PT cadastrada). Salvar
        // com o campo em branco cria a linha que falta (ver PUT).
        if (namePtEl) namePtEl.value = (data.pt && data.pt.NM_CATEGORIA) || "";
        if (nameEnEl) nameEnEl.value = (data.en && data.en.NM_CATEGORIA) || "";
        if (descPtEl) {
          descPtEl.value = (data.pt && data.pt.DS_CATEGORIA) || "";
          if (window.updateCategoryDescCounter) updateCategoryDescCounter(descPtEl, "catEdit");
        }
        if (descEnEl) descEnEl.value = (data.en && data.en.DS_CATEGORIA) || "";
      })
      .catch(function (err) {
        console.error("[categorias] falha ao carregar categoria para edição:", err);
        if (window.showToast) showToast("error", "Erro ao carregar", "Não foi possível buscar os dados da categoria no banco. " + err.message);
      });
  }

  // Salvar: grava as 2 linhas (PT/EN) do MESMO ID_CATEGORIA (UPDATE,
  // nunca INSERT — ver server.js) e reflete o nome/descrição PT no
  // card sem precisar recarregar a página.
  function salvarEdicao() {
    if (categoriaId == null) {
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
    fetch("/api/categorias/" + encodeURIComponent(categoriaId), {
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
        if (nomeEl) nomeEl.textContent = payload.pt.NM_CATEGORIA;
        if (descricaoEl) descricaoEl.textContent = payload.pt.DS_CATEGORIA;
        if (window.closeModal) closeModal("modalEditCategoria");
        if (window.showToast) showToast("success", "Salvo", "Categoria atualizada com sucesso!");
      })
      .catch(function (err) {
        console.error("[categorias] falha ao salvar categoria:", err);
        if (window.showToast) showToast("error", "Erro ao salvar", err.message);
      })
      .finally(function () {
        if (saveBtn) saveBtn.disabled = false;
      });
  }

  carregarCard().catch(function (err) {
    console.error("[categorias] falha ao carregar o card em destaque:", err);
  });

  if (editBtn) editBtn.addEventListener("click", carregarParaEdicao);
  if (saveBtn) saveBtn.addEventListener("click", salvarEdicao);
})();
