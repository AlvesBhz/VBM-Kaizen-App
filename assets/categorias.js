/**
 * VBM Kaizen — aba "Categorias" (admin.html), 1ª fase.
 *
 * Preenche só o card em destaque (o primeiro da lista) com dados reais
 * de GET /api/categorias (server.js -> kzn_categoria + contagem em
 * kzn_pendenciaconsolidada). Os demais cards continuam estáticos.
 *
 * Falha ao carregar: mantém o conteúdo estático já presente no HTML
 * como fallback (nada quebra visualmente) — só loga no console.
 */
(function () {
  var card = document.getElementById("categoriaCardDestaque");
  if (!card) return; // esta página não tem o card de Categorias

  var iconeEl = document.getElementById("categoriaCardIcone");
  var nomeEl = document.getElementById("categoriaCardNome");
  var descricaoEl = document.getElementById("categoriaCardDescricao");
  var badgeEl = document.getElementById("categoriaCardBadge");

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

  fetch("/api/categorias")
    .then(function (res) {
      if (!res.ok) return res.json().then(function (e) { throw new Error(e.error || res.statusText); });
      return res.json();
    })
    .then(function (categoria) {
      if (!categoria) return; // nenhuma categoria cadastrada ainda: mantém o card estático
      if (nomeEl) nomeEl.textContent = categoria.NM_CATEGORIA || "";
      if (descricaoEl) descricaoEl.textContent = categoria.DS_CATEGORIA || "";
      aplicarIcone(categoria.URL_ICONE);
      aplicarBadge(categoria.QTD_KAIZENS);
    })
    .catch(function (err) {
      console.error("[categorias] falha ao carregar o card em destaque:", err);
    });
})();
