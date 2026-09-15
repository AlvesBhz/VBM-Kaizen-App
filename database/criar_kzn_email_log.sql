/* =====================================================================
   ci.kzn_email_log — auditoria dos e-mails enviados pela aplicação
   ---------------------------------------------------------------------
   Sustenta o REQUISITO 4 do envio de e-mail: registrar QUEM enviou,
   QUANDO, PARA QUEM, com QUE ASSUNTO e com QUE RESULTADO.

   O QUE ESTA TABELA NÃO GUARDA — e não é esquecimento:

     • senha, token, chave ou qualquer credencial. Elas nem chegam à
       camada que escreve aqui: ficam em variáveis de ambiente lidas por
       email-smtp.js e não passam por nenhum parâmetro de consulta.
     • o CORPO da mensagem e os BYTES dos anexos. A auditoria pedida é
       de ENVIO, não de conteúdo; guardar o texto transformaria esta
       tabela num arquivo de correspondência, com o dever de sigilo que
       vem junto. Ficam só a contagem e o tamanho total dos anexos, que
       é o que serve para investigar abuso de cota.

   DT_ENVIO é DATETIME2 e recebe o relógio de BRASÍLIA, igual ao resto
   do sistema (ver AGORA_BRASILIA em server.js). Não é UTC.

   SG_ENVIADO segue a convenção das outras tabelas do schema ('S'/'N',
   como SG_ATIVO), em vez de BIT — assim uma consulta feita à mão lê o
   valor sem consultar legenda.

   A escrita nesta tabela NUNCA derruba um envio: server.js registra o
   log dentro de try/catch e, se falhar, o e-mail já saiu do mesmo jeito
   e a falha vai para o console. Uma auditoria indisponível é um
   problema a corrigir, não um motivo para impedir a pessoa de trabalhar.

   Schema: 'ci' (AZURE_SQL_SCHEMA em app.yaml).
   Rodar uma vez. Rodar de novo não faz nada (a checagem está abaixo).
   ===================================================================== */

SET NOCOUNT ON;

IF OBJECT_ID('ci.kzn_email_log', 'U') IS NOT NULL
BEGIN
    PRINT 'ci.kzn_email_log ja existe - nada a fazer.';
END
ELSE
BEGIN
    CREATE TABLE [ci].[kzn_email_log]
    (
        [ID_EMAIL_LOG]      INT            IDENTITY(1,1) NOT NULL,

        -- Quem enviou. Os dois juntos de propósito: o ID_USUARIO liga ao
        -- MDM, e o e-mail é o que o proxy do Databricks afirmou na hora
        -- (fica legível mesmo que a pessoa saia do MDM depois).
        [ID_USUARIO]        INT            NULL,
        [CD_EMAIL_USUARIO]  NVARCHAR(255)  NULL,

        [DT_ENVIO]          DATETIME2      NOT NULL,

        -- Listas separadas por "; ". NVARCHAR(MAX) porque um comunicado
        -- para uma equipe inteira estoura qualquer limite redondo que se
        -- escolha, e truncar auditoria é pior que guardar texto longo.
        [DS_DESTINATARIOS]  NVARCHAR(MAX)  NULL,
        [DS_COPIA]          NVARCHAR(MAX)  NULL,
        [DS_COPIA_OCULTA]   NVARCHAR(MAX)  NULL,

        [DS_ASSUNTO]        NVARCHAR(400)  NULL,

        [QT_ANEXOS]         INT            NULL,
        [NR_BYTES_ANEXOS]   BIGINT         NULL,

        -- 'S' = o serviço de e-mail aceitou a mensagem. 'N' = não saiu.
        [SG_ENVIADO]        CHAR(1)        NOT NULL,
        -- Só a razão em linguagem de usuário (a mesma que apareceu na
        -- tela). O erro cru do SMTP, que traz host e conta de serviço,
        -- fica no log do servidor e não entra aqui.
        [DS_ERRO]           NVARCHAR(500)  NULL,
        -- Message-ID devolvido pelo servidor: é por ele que o time de
        -- Exchange rastreia a mensagem se alguém disser que não recebeu.
        [DS_MESSAGE_ID]     NVARCHAR(255)  NULL,

        CONSTRAINT [PK_kzn_email_log] PRIMARY KEY CLUSTERED ([ID_EMAIL_LOG] ASC),
        CONSTRAINT [CK_kzn_email_log_enviado] CHECK ([SG_ENVIADO] IN ('S','N'))
    );

    PRINT 'ci.kzn_email_log criada.';
END
GO

/* ---------------------------------------------------------------------
   Índice das duas perguntas que essa auditoria responde na prática:
   "o que saiu neste período?" e "o que fulano enviou?".
   --------------------------------------------------------------------- */
IF OBJECT_ID('ci.kzn_email_log', 'U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes
                    WHERE name = 'IX_kzn_email_log_data'
                      AND object_id = OBJECT_ID('ci.kzn_email_log'))
BEGIN
    CREATE INDEX [IX_kzn_email_log_data]
        ON [ci].[kzn_email_log] ([DT_ENVIO] DESC)
        INCLUDE ([ID_USUARIO], [SG_ENVIADO]);
    PRINT 'IX_kzn_email_log_data criado.';
END
GO

IF OBJECT_ID('ci.kzn_email_log', 'U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes
                    WHERE name = 'IX_kzn_email_log_usuario'
                      AND object_id = OBJECT_ID('ci.kzn_email_log'))
BEGIN
    CREATE INDEX [IX_kzn_email_log_usuario]
        ON [ci].[kzn_email_log] ([ID_USUARIO], [DT_ENVIO] DESC);
    PRINT 'IX_kzn_email_log_usuario criado.';
END
GO

/* ---------------------------------------------------------------------
   FK para o MDM — DE PROPÓSITO NÃO ESTÁ AQUI, pelo mesmo motivo de
   ci.kzn_membros_equipe: a PK real de kzn_mdm_hierarquia é composta
   (ID_USUARIO, CD_MATRICULA, ID_TIPO_USUARIO), então não existe chave
   única em ID_USUARIO para uma FK apontar.

   Aqui isso é até desejável: registro de auditoria não pode deixar de
   ser gravado porque a pessoa ainda não está (ou não está mais) no MDM.
   --------------------------------------------------------------------- */

/* ---------------------------------------------------------------------
   Conferência
   --------------------------------------------------------------------- */
SELECT  COLUNA = c.name, TIPO = ty.name,
        TAMANHO = CASE WHEN ty.name LIKE 'n%char' AND c.max_length = -1 THEN 'MAX'
                       WHEN ty.name LIKE 'n%char' THEN CAST(c.max_length / 2 AS VARCHAR(10))
                       ELSE '' END,
        ACEITA_NULO = CASE WHEN c.is_nullable = 1 THEN 'sim' ELSE 'NAO' END
FROM        sys.columns c
INNER JOIN  sys.types   ty ON ty.user_type_id = c.user_type_id
WHERE       c.object_id = OBJECT_ID('ci.kzn_email_log')
ORDER BY    c.column_id;
