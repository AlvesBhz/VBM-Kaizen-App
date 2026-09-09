/* =====================================================================
   Amarrações de CI.KZN_PEDRAVISAOCONSOLIDADA — validação de cadastro
   ---------------------------------------------------------------------
   Script SÓ DE LEITURA (nenhum INSERT/UPDATE/DELETE) pra validar, no
   período de testes, um Kaizen cadastrado: quando foi criado/alterado,
   por quem, o que mudou em cada alteração, e quantas linhas ele tem em
   cada tabela dependente.

   Preencha @ID_KAIZEN pra validar 1 registro específico, ou deixe NULL
   pra ver todos.

   Em 4 partes, cada uma no seu próprio bloco (GO): se alguma tabela
   ainda não existir neste banco, só a PARTE que depende dela falha — as
   demais continuam rodando. Rode a PARTE 1 primeiro se aparecer erro de
   "Invalid object name": ela mostra, sem depender de nomes fixos, quais
   tabelas realmente têm FK pra CI.KZN_PEDRAVISAOCONSOLIDADA hoje neste
   banco — se faltar alguma das usadas nas partes 3/4
   (KZN_LOG_PEDRAVISAOCONSOLIDADA[_DETALHE], KZN_MEMBROS_EQUIPE,
   KZN_RESULTADO_KAIZEN, KZN_KAIZEN_HIERARQUIA, KZN_KAIZEN_DESPERDICIO),
   é sinal de que esta lista precisa ser atualizada (já aconteceu com
   KZN_MEMBROS_EQUIPE e KZN_KAIZEN_DESPERDICIO nesta mesma aplicação).

   Schema: 'ci' (AZURE_SQL_SCHEMA em app.yaml).
   ===================================================================== */

SET NOCOUNT ON;

-- ATENÇÃO: variável LOCAL não atravessa "GO" — como cada PARTE roda no
-- seu próprio bloco (de propósito, ver acima), @ID_KAIZEN é redeclarada
-- em toda PARTE que a usa. Ajuste o valor nas 3 (PARTES 2, 3 e 4).

/* =====================================================================
   PARTE 1 — Mapa de dependências (dinâmico, via metadados)
   ---------------------------------------------------------------------
   Lista TODAS as tabelas que hoje têm FK apontando pra
   CI.KZN_PEDRAVISAOCONSOLIDADA (ID_KAIZEN) — descoberta pelo próprio
   banco, não uma lista fixa mantida à mão, então continua correta
   mesmo se o schema mudar (nova tabela dependente, FK removida, etc.).
   ===================================================================== */
SELECT
    TABELA_DEPENDENTE = OBJECT_SCHEMA_NAME(fk.parent_object_id) + '.' + OBJECT_NAME(fk.parent_object_id),
    COLUNA_FK         = COL_NAME(fkc.parent_object_id, fkc.parent_column_id),
    NOME_CONSTRAINT   = fk.name,
    ON_DELETE         = fk.delete_referential_action_desc
FROM        sys.foreign_keys fk
JOIN        sys.foreign_key_columns fkc ON fkc.constraint_object_id = fk.object_id
WHERE       fk.referenced_object_id = OBJECT_ID('CI.KZN_PEDRAVISAOCONSOLIDADA')
ORDER BY    TABELA_DEPENDENTE;
GO

/* =====================================================================
   PARTE 2 — O(s) registro(s) principal(is): quando e por quem
   ---------------------------------------------------------------------
   DT_ATUALIZACAO/ATUALIZADO_POR vêm das próprias colunas de
   CI.KZN_PEDRAVISAOCONSOLIDADA (o que está gravado AGORA na linha).
   DT_CRIACAO não é mais coluna: vem da linha 'C' do log — pra ver o
   HISTÓRICO completo de alterações, use a Parte 3.
   ===================================================================== */
DECLARE @ID_KAIZEN INT = NULL;   -- <<< AJUSTAR (opcional): um ID_KAIZEN específico, ou NULL para todos

SELECT
    p.ID_KAIZEN,
    p.NM_KAIZEN,
    p.ID_STATUS,
    STATUS_NOME       = st.NM_STATUS,
    DT_CRIACAO        = lc.DT_OPERACAO,
    CRIADO_POR        = mc.NM_USUARIO,
    MATRICULA_CRIADOR = mc.CD_MATRICULA,
    p.DT_ATUALIZACAO,
    ATUALIZADO_POR    = ma.NM_USUARIO,
    MATRICULA_ATUALIZADOR = ma.CD_MATRICULA
FROM        CI.KZN_PEDRAVISAOCONSOLIDADA p
LEFT JOIN   CI.KZN_MDM_HIERARQUIA mc ON mc.ID_USUARIO = p.ID_USUARIO_CADASTRO
LEFT JOIN   CI.KZN_MDM_HIERARQUIA ma ON ma.ID_USUARIO = p.ID_USUARIO_ATUALIZACAO
/* DT_CRIACAO deixou de ser coluna da tabela: a data de criacao agora vem
   da linha 'C' do log de auditoria. */
LEFT JOIN   CI.KZN_LOG_PEDRAVISAOCONSOLIDADA lc
       ON   lc.ID_KAIZEN = p.ID_KAIZEN AND lc.TP_OPERACAO = 'C'
/* KZN_STATUS tem PK composta (ID_STATUS, ID_IDIOMA) - TOP 1 pelo idioma
   para nao multiplicar a linha do Kaizen por idioma. */
OUTER APPLY (SELECT TOP (1) s.NM_STATUS FROM CI.KZN_STATUS s
             WHERE s.ID_STATUS = p.ID_STATUS ORDER BY s.ID_IDIOMA) st
WHERE       (@ID_KAIZEN IS NULL OR p.ID_KAIZEN = @ID_KAIZEN)
ORDER BY    p.ID_KAIZEN;
GO

/* =====================================================================
   PARTE 3 — Histórico completo de alterações (quem, quando, o quê)
   ---------------------------------------------------------------------
   1 linha por campo alterado em cada operação (LEFT JOIN: a criação
   aparece com NM_CAMPO/VL_ANTERIOR/VL_NOVO em branco — ela não tem
   diff, só cabeçalho, ver seção 19 do DDL de referência).
   ===================================================================== */
DECLARE @ID_KAIZEN INT = NULL;   -- <<< AJUSTAR (opcional): um ID_KAIZEN específico, ou NULL para todos

SELECT
    l.ID_KAIZEN,
    l.ID_LOG,
    OPERACAO       = CASE l.TP_OPERACAO WHEN 'C' THEN 'Criação' WHEN 'A' THEN 'Atualização' ELSE l.TP_OPERACAO END,
    l.DT_OPERACAO,
    REALIZADO_POR  = mu.NM_USUARIO,
    MATRICULA      = mu.CD_MATRICULA,
    d.NM_CAMPO,
    d.VL_ANTERIOR,
    d.VL_NOVO
FROM        CI.KZN_LOG_PEDRAVISAOCONSOLIDADA l
LEFT JOIN   CI.KZN_MDM_HIERARQUIA mu ON mu.ID_USUARIO = l.ID_USUARIO_OPERACAO
LEFT JOIN   CI.KZN_LOG_PEDRAVISAOCONSOLIDADA_DETALHE d ON d.ID_LOG = l.ID_LOG
WHERE       (@ID_KAIZEN IS NULL OR l.ID_KAIZEN = @ID_KAIZEN)
ORDER BY    l.ID_KAIZEN, l.DT_OPERACAO, d.NM_CAMPO;
GO

/* =====================================================================
   PARTE 4 — Quantidade de linhas em cada tabela dependente
   ---------------------------------------------------------------------
   Visão rápida de "o que esse Kaizen carrega": quantos membros de
   equipe, resultados, fotografias de hierarquia, desperdícios e
   entradas de log ele tem. Útil pra decidir se vale a pena excluir
   (ver excluir_kaizen_e_dependencias.sql) ou só investigar mais.
   ===================================================================== */
DECLARE @ID_KAIZEN INT = NULL;   -- <<< AJUSTAR (opcional): um ID_KAIZEN específico, ou NULL para todos

SELECT
    p.ID_KAIZEN,
    p.NM_KAIZEN,
    QT_MEMBROS_EQUIPE  = (SELECT COUNT(*) FROM CI.KZN_MEMBROS_EQUIPE      me WHERE me.ID_KAIZEN = p.ID_KAIZEN),
    QT_RESULTADOS      = (SELECT COUNT(*) FROM CI.KZN_RESULTADO_KAIZEN    rk WHERE rk.ID_KAIZEN = p.ID_KAIZEN),
    QT_HIERARQUIA      = (SELECT COUNT(*) FROM CI.KZN_KAIZEN_HIERARQUIA   kh WHERE kh.ID_KAIZEN = p.ID_KAIZEN),
    QT_DESPERDICIOS    = (SELECT COUNT(*) FROM CI.KZN_KAIZEN_DESPERDICIO  kd WHERE kd.ID_KAIZEN = p.ID_KAIZEN),
    QT_LOGS            = (SELECT COUNT(*) FROM CI.KZN_LOG_PEDRAVISAOCONSOLIDADA l WHERE l.ID_KAIZEN = p.ID_KAIZEN),
    QT_LOGS_DETALHE    = (SELECT COUNT(*) FROM CI.KZN_LOG_PEDRAVISAOCONSOLIDADA_DETALHE d
                          JOIN CI.KZN_LOG_PEDRAVISAOCONSOLIDADA l2 ON l2.ID_LOG = d.ID_LOG
                          WHERE l2.ID_KAIZEN = p.ID_KAIZEN)
FROM        CI.KZN_PEDRAVISAOCONSOLIDADA p
WHERE       (@ID_KAIZEN IS NULL OR p.ID_KAIZEN = @ID_KAIZEN)
ORDER BY    p.ID_KAIZEN;
GO
