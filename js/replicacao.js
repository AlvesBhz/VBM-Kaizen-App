/**
 * VBM Kaizen — aba "Pot. Replicação" (admin.html).
 * Só a configuração; a lógica (listar/criar/editar/ativar) está em
 * js/cadastro-bilingue.js (window.criarCadastroBilingue).
 */
(function () {
  if (!window.criarCadastroBilingue) return;

  criarCadastroBilingue({
    rota: "replicacoes", listaId: "replicacoesList",
    modalAddId: "modalAddReplicacao", modalEditId: "modalEditReplicacao",
    prefixoAdd: "replAdd", prefixoEdit: "replEdit",
    btnSalvarAddId: "btnSaveAddReplicacao", btnSalvarEditId: "btnSaveEditReplicacao",
    classeIcone: "blue", iconePadrao: "fa-solid fa-globe",
    palavraBadge: null, palavraBadgeSingular: null,
    // Limites do DER (kzn_replicacao): NM_REPLICACAO 20 / DS_REPLICACAO 40.
    maxNome: 20, maxDescricao: 40,
    rotuloSingular: "Potencial de replicação",
    textoCarregando: "Carregando potenciais de replicação…", textoVazio: "Nenhum potencial de replicação cadastrado.",
    textoErro: "Não foi possível carregar os potenciais de replicação no momento. Tente novamente em instantes.",
  });
})();
