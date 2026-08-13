/**
 * VBM Kaizen — aba "Categorias" (admin.html).
 * Só a configuração; a lógica (listar/criar/editar/ativar) está em
 * assets/cadastro-bilingue.js (window.criarCadastroBilingue).
 */
(function () {
  if (!window.criarCadastroBilingue) return;

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
