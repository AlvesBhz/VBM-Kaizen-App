/**
 * VBM Kaizen — aba "Categorias" (admin.html).
 * Só a configuração; a lógica (listar/criar/editar/ativar) está em
 * assets/cadastro-bilingue.js (window.criarCadastroBilingue).
 */
(function () {
  if (!window.criarCadastroBilingue) {
    // Sem isso, uma falha em carregar assets/cadastro-bilingue.js (deploy
    // incompleto, cache, etc.) deixava a lista travada pra sempre no
    // "Carregando…" estático do HTML, sem NENHUM sinal de erro — quem via
    // a tela não tinha como saber que algo tinha quebrado.
    console.error("[categorias] assets/cadastro-bilingue.js não carregou — window.criarCadastroBilingue está indefinido.");
    var list = document.getElementById("categoriasList");
    if (list) {
      list.innerHTML =
        '<div class="admin-list-status is-error">' +
        '<i class="fa-solid fa-triangle-exclamation"></i> ' +
        "<span>Falha ao carregar o motor de cadastros (assets/cadastro-bilingue.js). " +
        "Atualize a página (Ctrl+Shift+R); se persistir, o arquivo pode não ter sido publicado no último deploy.</span>" +
        "</div>";
    }
    return;
  }

  criarCadastroBilingue({
    rota: "categorias", listaId: "categoriasList",
    modalAddId: "modalAddCategoria", modalEditId: "modalEditCategoria",
    prefixoAdd: "catAdd", prefixoEdit: "catEdit",
    btnSalvarAddId: "btnSaveAddCategoria", btnSalvarEditId: "btnSaveEditCategoria",
    classeIcone: "green", iconePadrao: "fa-solid fa-tag",
    palavraBadge: "kaizens", palavraBadgeSingular: "kaizen",
    // Exceção ao DER (NM 20 / DS 40): estas colunas já foram ampliadas
    // no banco especificamente para Categoria (30/100).
    maxNome: 30, maxDescricao: 100,
    rotuloSingular: "Categoria",
    textoCarregando: "Carregando categorias…", textoVazio: "Nenhuma categoria cadastrada.",
    textoErro: "Não foi possível carregar as categorias no momento. Tente novamente em instantes.",
  });
})();
