/* =====================================================================
   VBM Kaizen — diagnóstico da FK de ci.kzn_kaizen_hierarquia
   =====================================================================

   Por que este script existe
   --------------------------
   Um MERGE que lê o ID_KAIZEN de DENTRO de ci.kzn_pedravisaoconsolidada
   foi recusado por uma FK que referencia justamente
   ci.kzn_pedravisaoconsolidada(ID_KAIZEN):

     Msg 547 ... conflicted with the FOREIGN KEY constraint
     "FK_KZN_KAIZEN_HIERARQUIA_KAIZEN". The conflict occurred in
     database "BDIBPBMSA_PRD", table "CI.KZN_PEDRAVISAOCONSOLIDADA",
     column 'ID_KAIZEN'.

   Um valor tirado da própria tabela referenciada não pode "não existir"
   nela. Logo, a coluna que a constraint está conferindo NÃO é a que o
   nome dela sugere — a suspeita é que ela cobre ID_USUARIO_LIDER (ou
   outra coluna) contra PEDRAVISAOCONSOLIDADA.ID_KAIZEN. Um líder
   181222 não é um Kaizen 181222, e a recusa aparece exatamente assim.

   O passo 1 confirma ou descarta isso. Não altera nada.
   ===================================================================== */

SET NOCOUNT ON;

/* ---------------------------------------------------------------------
   PASSO 1 — O que cada FK da tabela realmente confere.
   Leia a linha do FK_KZN_KAIZEN_HIERARQUIA_KAIZEN: COLUNA é o que ele
   valida, REFERENCIA/COLUNA_REFERENCIADA é contra o quê.

   Esperado e correto:
     ID_KAIZEN        -> ci.kzn_pedravisaoconsolidada . ID_KAIZEN
     ID_USUARIO_LIDER -> ci.kzn_mdm_hierarquia        . ID_USUARIO
   --------------------------------------------------------------------- */
SELECT  fk.name                                                             AS CONSTRAINT_NAME,
        OBJECT_SCHEMA_NAME(fk.parent_object_id) + '.'
          + OBJECT_NAME(fk.parent_object_id)                                AS TABELA,
        cp.name                                                             AS COLUNA,
        OBJECT_SCHEMA_NAME(fk.referenced_object_id) + '.'
          + OBJECT_NAME(fk.referenced_object_id)                            AS REFERENCIA,
        cr.name                                                             AS COLUNA_REFERENCIADA,
        fk.is_disabled                                                      AS DESABILITADA,
        fk.is_not_trusted                                                   AS NAO_CONFIAVEL
  FROM sys.foreign_keys fk
  JOIN sys.foreign_key_columns fkc ON fkc.constraint_object_id = fk.object_id
  JOIN sys.columns cp ON cp.object_id = fkc.parent_object_id
                     AND cp.column_id = fkc.parent_column_id
  JOIN sys.columns cr ON cr.object_id = fkc.referenced_object_id
                     AND cr.column_id = fkc.referenced_column_id
 WHERE fk.parent_object_id = OBJECT_ID('ci.kzn_kaizen_hierarquia')
 ORDER BY fk.name, fkc.constraint_column_id;

/* ---------------------------------------------------------------------
   PASSO 2 — Confirmação pelos dados.
   Se a suspeita estiver certa, PRECISA_EXISTIR_COMO_KAIZEN traz os
   ID_USUARIO_LIDER que a FK está exigindo encontrar em ID_KAIZEN — e
   que obviamente não estão lá.
   --------------------------------------------------------------------- */
SELECT DISTINCT p.ID_USUARIO_LIDER AS PRECISA_EXISTIR_COMO_KAIZEN
  FROM ci.kzn_pedravisaoconsolidada p
 WHERE NOT EXISTS (SELECT 1 FROM ci.kzn_pedravisaoconsolidada k
                    WHERE k.ID_KAIZEN = p.ID_USUARIO_LIDER);

/* =====================================================================
   PASSO 3 — CORREÇÃO. Só execute depois de o passo 1 confirmar que a
   constraint está apontando para a coluna errada.

   Não roda sozinho: descomente o bloco abaixo. É DDL em produção —
   confira o resultado do passo 1 antes.

   O WITH CHECK revalida as linhas existentes; se a tabela estiver
   vazia, não há nada a revalidar.
   ===================================================================== */

/*
ALTER TABLE ci.kzn_kaizen_hierarquia
  DROP CONSTRAINT FK_KZN_KAIZEN_HIERARQUIA_KAIZEN;

ALTER TABLE ci.kzn_kaizen_hierarquia WITH CHECK
  ADD CONSTRAINT FK_KZN_KAIZEN_HIERARQUIA_KAIZEN
      FOREIGN KEY (ID_KAIZEN)
      REFERENCES ci.kzn_pedravisaoconsolidada (ID_KAIZEN);
*/

/* Se o passo 1 mostrar que a FK de ID_USUARIO_LIDER também aponta para
   o lugar errado, ela deveria ser:

ALTER TABLE ci.kzn_kaizen_hierarquia
  DROP CONSTRAINT <nome que apareceu no passo 1>;

ALTER TABLE ci.kzn_kaizen_hierarquia WITH CHECK
  ADD CONSTRAINT FK_KZN_KAIZEN_HIERARQUIA_USUARIO
      FOREIGN KEY (ID_USUARIO_LIDER)
      REFERENCES ci.kzn_mdm_hierarquia (ID_USUARIO);
*/

/* Depois de corrigir, rode preencher_kaizen_hierarquia.sql e confira:
     SELECT * FROM ci.kzn_kaizen_hierarquia;                            */
