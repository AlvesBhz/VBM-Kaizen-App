/**
 * VBM Kaizen — aba "Resultados" (admin.html).
 * Só a configuração; a lógica (listar/criar/editar/ativar) está em
 * assets/cadastro-bilingue.js (window.criarCadastroBilingue).
 */
(function () {
  if (!window.criarCadastroBilingue) return;

  criarCadastroBilingue({
    rota: "resultados", listaId: "resultadosList",
    modalAddId: "modalAddResultado", modalEditId: "modalEditResultado",
    prefixoAdd: "resAdd", prefixoEdit: "resEdit",
    btnSalvarAddId: "btnSaveAddResultado", btnSalvarEditId: "btnSaveEditResultado",
    classeIcone: "yellow", iconePadrao: "fa-solid fa-trophy",
    palavraBadge: null, palavraBadgeSingular: null,
    // Limites do DER (kzn_resultados): NM_RESULTADO 20 / DS_RESULTADO 40.
    maxNome: 20, maxDescricao: 40,
    rotuloSingular: "Tipo de resultado",
    textoCarregando: "Carregando tipos de resultado…", textoVazio: "Nenhum tipo de resultado cadastrado.",
    textoErro: "Não foi possível carregar os tipos de resultado no momento. Tente novamente em instantes.",
  });
})();
