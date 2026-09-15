/* =====================================================================
   Quem ficaria SEM e-mail nos comunicados do Kaizen
   ---------------------------------------------------------------------
   Só LEITURA. Nada é alterado.

   Um comunicado sem nenhum destinatário simplesmente não é enviado. Este
   script mostra, antes de o problema aparecer como "o e-mail não
   chegou", quais Kaizens estão nessa situação e por quê.

   A REGRA DE BUSCA DO E-MAIL, por papel:

     Dono do Kaizen  ci.kzn_mdm_hierarquia.CD_EMAIL
                     por ID_USUARIO = ISNULL(ID_USUARIO_CADASTRO,
                                             ID_USUARIO_LIDER)
     Equipe          ci.kzn_mdm_hierarquia.CD_EMAIL
                     por ID_USUARIO = kzn_membros_equipe.ID_USUARIO
     Aprovador       ci.kzn_aprovador.CD_MATRICULA, que na prática
                     guarda uma de três coisas — e por isso a busca tenta
                     as três, nesta ordem:
                       1. a matrícula, casando com MDM.CD_MATRICULA;
                       2. um ID_USUARIO, casando com MDM.ID_USUARIO. É o
                          caso do banco atual: ID_APROVADOR = 1 tem
                          CD_MATRICULA = 181222, que é um ID_USUARIO;
                       3. nada — e aí vale kzn_aprovador.ID_USUARIO, que
                          só nas linhas ANTIGAS é o próprio aprovador.

   Repare na diferença entre os ramos 2 e 3. No 2, o VALOR guardado em
   CD_MATRICULA é um ID_USUARIO e aponta para o próprio aprovador. No 3,
   quem aponta é a coluna ID_USUARIO da linha — e ela só vale quando a
   matrícula está vazia, porque nas linhas NOVAS ci.kzn_aprovador.ID_USUARIO
   é quem CONCEDEU o direito de aprovar, não quem aprova. Usar essa coluna
   como atalho geral mandaria o "aprove este Kaizen" para a pessoa errada.

   Valor preenchido que não é nem matrícula nem ID_USUARIO do MDM é erro
   de dado, e a ETAPA 3 aponta quais são.

   TOP (1) com ORDER BY em toda busca ao MDM: a PK de lá é
   (ID_USUARIO, CD_MATRICULA, ID_TIPO_USUARIO) e a mesma pessoa aparece
   em mais de uma linha.

   Schema: 'ci' (AZURE_SQL_SCHEMA em app.yaml).
   ===================================================================== */

SET NOCOUNT ON;

/* =====================================================================
   ETAPA 1 — Um Kaizen específico, de ponta a ponta.
   Troque o número e rode: mostra os três papéis e o e-mail de cada um.
   ===================================================================== */
DECLARE @ID_KAIZEN INT = 501;   /* <<< troque aqui */

SELECT  PAPEL              = 'Dono do Kaizen',
        ID_USUARIO         = ISNULL(p.ID_USUARIO_CADASTRO, p.ID_USUARIO_LIDER),
        CD_MATRICULA       = autor.CD_MATRICULA,
        NOME               = autor.NM_USUARIO,
        CD_EMAIL           = autor.CD_EMAIL,
        SITUACAO           = CASE WHEN autor.CD_EMAIL IS NULL
                                  THEN 'SEM E-MAIL: confira o ID_USUARIO no MDM'
                                  ELSE 'ok' END
FROM        ci.kzn_pedravisaoconsolidada p
OUTER APPLY (SELECT TOP (1) x.NM_USUARIO, x.CD_EMAIL, x.CD_MATRICULA
               FROM ci.kzn_mdm_hierarquia x
              WHERE x.ID_USUARIO = ISNULL(p.ID_USUARIO_CADASTRO, p.ID_USUARIO_LIDER)
              ORDER BY x.ID_TIPO_USUARIO) autor
WHERE       p.ID_KAIZEN = @ID_KAIZEN

UNION ALL

SELECT  'Aprovador',
        aprov.ID_USUARIO,
        a.CD_MATRICULA,
        aprov.NM_USUARIO,
        aprov.CD_EMAIL,
        CASE WHEN aprov.CD_EMAIL IS NOT NULL THEN 'ok'
             WHEN a.ID_APROVADOR IS NULL     THEN 'SEM APROVADOR: o Kaizen nao aponta para kzn_aprovador'
             WHEN a.CD_MATRICULA IS NULL
               OR LTRIM(RTRIM(CAST(a.CD_MATRICULA AS VARCHAR(30)))) = ''
                                             THEN 'SEM E-MAIL: a linha do aprovador esta sem CD_MATRICULA'
             ELSE 'SEM E-MAIL: o valor da CD_MATRICULA nao e matricula nem ID_USUARIO do MDM'
        END
FROM        ci.kzn_pedravisaoconsolidada p
LEFT JOIN   ci.kzn_aprovador a ON a.ID_APROVADOR = p.ID_APROVADOR
OUTER APPLY (SELECT TOP (1) x.ID_USUARIO, x.NM_USUARIO, x.CD_EMAIL
               FROM ci.kzn_mdm_hierarquia x
              WHERE (TRY_CAST(x.CD_MATRICULA AS BIGINT) = TRY_CAST(a.CD_MATRICULA AS BIGINT)
                     OR CAST(x.CD_MATRICULA AS VARCHAR(30)) = CAST(a.CD_MATRICULA AS VARCHAR(30))
                     OR x.ID_USUARIO = TRY_CAST(a.CD_MATRICULA AS BIGINT)
                     OR (x.ID_USUARIO = a.ID_USUARIO
                         AND (a.CD_MATRICULA IS NULL
                              OR LTRIM(RTRIM(CAST(a.CD_MATRICULA AS VARCHAR(30)))) = '')))
              ORDER BY CASE WHEN (TRY_CAST(x.CD_MATRICULA AS BIGINT) = TRY_CAST(a.CD_MATRICULA AS BIGINT)
                                  OR CAST(x.CD_MATRICULA AS VARCHAR(30)) = CAST(a.CD_MATRICULA AS VARCHAR(30)))
                            THEN 0
                            WHEN x.ID_USUARIO = TRY_CAST(a.CD_MATRICULA AS BIGINT) THEN 1
                            ELSE 2 END, x.ID_TIPO_USUARIO) aprov
WHERE       p.ID_KAIZEN = @ID_KAIZEN

UNION ALL

SELECT  'Equipe',
        me.ID_USUARIO,
        m.CD_MATRICULA,
        m.NM_USUARIO,
        m.CD_EMAIL,
        CASE WHEN m.CD_EMAIL IS NULL THEN 'SEM E-MAIL: confira o ID_USUARIO no MDM' ELSE 'ok' END
FROM        ci.kzn_membros_equipe me
OUTER APPLY (SELECT TOP (1) x.NM_USUARIO, x.CD_EMAIL, x.CD_MATRICULA
               FROM ci.kzn_mdm_hierarquia x
              WHERE x.ID_USUARIO = me.ID_USUARIO
              ORDER BY x.ID_TIPO_USUARIO) m
WHERE       me.ID_KAIZEN = @ID_KAIZEN;


/* =====================================================================
   ETAPA 2 — Todos os Kaizens cujo comunicado de APROVAÇÃO não sairia.
   É o e-mail "Iniciativa aguardando sua aprovação": ele vai para UMA
   pessoa só, então sem o e-mail dela não há a quem enviar.
   ===================================================================== */
SELECT      p.ID_KAIZEN,
            p.NM_KAIZEN,
            p.ID_APROVADOR,
            CD_MATRICULA_NA_KZN_APROVADOR = a.CD_MATRICULA,
            ID_USUARIO_CONCEDENTE         = a.ID_USUARIO,
            MOTIVO = CASE WHEN a.ID_APROVADOR IS NULL THEN 'o Kaizen nao aponta para kzn_aprovador'
                          WHEN a.CD_MATRICULA IS NULL
                            OR LTRIM(RTRIM(CAST(a.CD_MATRICULA AS VARCHAR(30)))) = ''
                               THEN 'linha do aprovador sem CD_MATRICULA'
                          ELSE 'o valor da CD_MATRICULA nao e matricula nem ID_USUARIO do MDM' END
FROM        ci.kzn_pedravisaoconsolidada p
LEFT JOIN   ci.kzn_aprovador a ON a.ID_APROVADOR = p.ID_APROVADOR
OUTER APPLY (SELECT TOP (1) x.CD_EMAIL
               FROM ci.kzn_mdm_hierarquia x
              WHERE (TRY_CAST(x.CD_MATRICULA AS BIGINT) = TRY_CAST(a.CD_MATRICULA AS BIGINT)
                     OR CAST(x.CD_MATRICULA AS VARCHAR(30)) = CAST(a.CD_MATRICULA AS VARCHAR(30))
                     OR x.ID_USUARIO = TRY_CAST(a.CD_MATRICULA AS BIGINT)
                     OR (x.ID_USUARIO = a.ID_USUARIO
                         AND (a.CD_MATRICULA IS NULL
                              OR LTRIM(RTRIM(CAST(a.CD_MATRICULA AS VARCHAR(30)))) = '')))
              ORDER BY CASE WHEN (TRY_CAST(x.CD_MATRICULA AS BIGINT) = TRY_CAST(a.CD_MATRICULA AS BIGINT)
                                  OR CAST(x.CD_MATRICULA AS VARCHAR(30)) = CAST(a.CD_MATRICULA AS VARCHAR(30)))
                            THEN 0
                            WHEN x.ID_USUARIO = TRY_CAST(a.CD_MATRICULA AS BIGINT) THEN 1
                            ELSE 2 END, x.ID_TIPO_USUARIO) aprov
WHERE       aprov.CD_EMAIL IS NULL
ORDER BY    p.ID_KAIZEN DESC;


/* =====================================================================
   ETAPA 3 — Linhas de kzn_aprovador que não acham a pessoa no MDM.
   É a causa-raiz da ETAPA 2, e a lista que precisa ser corrigida.
   Para a correção da matrícula existe database/corrigir_matricula_aprovador.sql
   — LEIA os avisos de lá antes de rodar.
   ===================================================================== */
SELECT      a.ID_APROVADOR,
            a.CD_MATRICULA,
            ID_USUARIO_CONCEDENTE = a.ID_USUARIO,
            a.SG_ATIVO,
            NOME_DO_CONCEDENTE = conc.NM_USUARIO,
            DIAGNOSTICO = CASE WHEN a.CD_MATRICULA IS NULL
                                 OR LTRIM(RTRIM(CAST(a.CD_MATRICULA AS VARCHAR(30)))) = ''
                               THEN 'sem CD_MATRICULA — a aplicacao usa o ID_USUARIO como aprovador (linha antiga)'
                               ELSE 'valor preenchido que nao e matricula nem ID_USUARIO do MDM — ERRO DE DADO, corrigir' END
FROM        ci.kzn_aprovador a
OUTER APPLY (SELECT TOP (1) x.CD_EMAIL
               FROM ci.kzn_mdm_hierarquia x
              WHERE (TRY_CAST(x.CD_MATRICULA AS BIGINT) = TRY_CAST(a.CD_MATRICULA AS BIGINT)
                     OR CAST(x.CD_MATRICULA AS VARCHAR(30)) = CAST(a.CD_MATRICULA AS VARCHAR(30))
                     OR x.ID_USUARIO = TRY_CAST(a.CD_MATRICULA AS BIGINT)
                     OR (x.ID_USUARIO = a.ID_USUARIO
                         AND (a.CD_MATRICULA IS NULL
                              OR LTRIM(RTRIM(CAST(a.CD_MATRICULA AS VARCHAR(30)))) = '')))
              ORDER BY CASE WHEN (TRY_CAST(x.CD_MATRICULA AS BIGINT) = TRY_CAST(a.CD_MATRICULA AS BIGINT)
                                  OR CAST(x.CD_MATRICULA AS VARCHAR(30)) = CAST(a.CD_MATRICULA AS VARCHAR(30)))
                            THEN 0
                            WHEN x.ID_USUARIO = TRY_CAST(a.CD_MATRICULA AS BIGINT) THEN 1
                            ELSE 2 END, x.ID_TIPO_USUARIO) pessoa
OUTER APPLY (SELECT TOP (1) y.NM_USUARIO FROM ci.kzn_mdm_hierarquia y
              WHERE y.ID_USUARIO = a.ID_USUARIO ORDER BY y.ID_TIPO_USUARIO) conc
WHERE       pessoa.CD_EMAIL IS NULL
ORDER BY    a.ID_APROVADOR;


/* =====================================================================
   ETAPA 4 — Pessoas do MDM sem CD_EMAIL que participam de algum Kaizen.
   Aqui não há o que a aplicação possa fazer: o e-mail precisa entrar no
   cadastro de origem do MDM.
   ===================================================================== */
SELECT DISTINCT
            m.ID_USUARIO, m.CD_MATRICULA, m.NM_USUARIO,
            PAPEL = 'dono ou membro de equipe'
FROM        ci.kzn_mdm_hierarquia m
WHERE       (m.CD_EMAIL IS NULL OR LTRIM(RTRIM(m.CD_EMAIL)) = '')
  AND       (EXISTS (SELECT 1 FROM ci.kzn_pedravisaoconsolidada p
                      WHERE ISNULL(p.ID_USUARIO_CADASTRO, p.ID_USUARIO_LIDER) = m.ID_USUARIO)
             OR EXISTS (SELECT 1 FROM ci.kzn_membros_equipe me
                         WHERE me.ID_USUARIO = m.ID_USUARIO))
ORDER BY    m.NM_USUARIO;
