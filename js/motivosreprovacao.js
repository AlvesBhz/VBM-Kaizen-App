/**
 * VBM Kaizen — aba "Mot. Reprovação" (admin.html).
 * Só a configuração; a lógica (listar/criar/editar/ativar) está em
 * js/cadastro-bilingue.js (window.criarCadastroBilingue).
 *
 * Tabela (DER): kzn_motivo_reprovacao — ID_MOTIVO, ID_IDIOMA,
 * NM_MOTIVO VARCHAR(30), DS_MOTIVO VARCHAR(100), DT_ATUALIZACAO. Tem
 * descrição (como Categorias/Replicação/Desperdícios/Resultados), mas
 * sem URL_ICONE — o motor compartilhado usa sempre o ícone padrão
 * (não há campo de ícone no modal desta aba).
 */
(function () {
  if (!window.criarCadastroBilingue) return;

  criarCadastroBilingue({
    rota: "motivosreprovacao", listaId: "motivosReprovacaoList",
    modalAddId: "modalAddMotivoReprovacao", modalEditId: "modalEditMotivoReprovacao",
    prefixoAdd: "motRepAdd", prefixoEdit: "motRepEdit",
    btnSalvarAddId: "btnSaveAddMotivoReprovacao", btnSalvarEditId: "btnSaveEditMotivoReprovacao",
    classeIcone: "purple", iconePadrao: "fa-solid fa-circle-xmark",
    palavraBadge: null, palavraBadgeSingular: null,
    // Limites do DER (kzn_motivo_reprovacao): NM_MOTIVO VARCHAR(30) /
    // DS_MOTIVO VARCHAR(100) — mesmo tamanho das outras tabelas
    // bilíngues (server.js espelha isso em CADASTRO_LIMITES_DER).
    maxNome: 30, maxDescricao: 100,
    rotuloSingular: "Motivo de reprovação",
    textoCarregando: "Carregando motivos de reprovação…", textoVazio: "Nenhum motivo de reprovação cadastrado.",
    textoErro: "Não foi possível carregar os motivos de reprovação no momento. Tente novamente em instantes.",
  });
})();
