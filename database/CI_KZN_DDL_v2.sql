/* ==============================================================================
   Projeto : Kaizen Management (KZN)
   Schema  : CI
   SGBD    : SQL Server 2016+
   Arquivo : CI_KZN_DDL_v2.sql
   Descr.  : Adequação do schema original: URL_ICONE em IDIOMA/CATEGORIA/
             REPLICACAO/DESPERDICIO/RESULTADOS, nova tabela mestre de usuários
             (KZN_MDM_HIERARQUIA, fonte RH/MDM), KZN_APROVADOR redesenhada como
             papel (aponta pra MDM em vez de duplicar matrícula/nome), tabela
             principal KZN_PEDRAVISAOCONSOLIDADA + log de auditoria
             (KZN_LOG_PEDRAVISAOCONSOLIDADA) e tabelas auxiliares
             (KZN_MEMBROS_EQUIPE, KZN_RESULTADO_KAIZEN, KZN_KAIZEN_HIERARQUIA).
   Obs.    : Script idempotente — pode ser executado mais de uma vez.

   ASSUNÇÕES QUE PRECISAM DE REVISÃO DO TIME DE NEGÓCIO (marcadas também
   inline com "-- ASSUNÇÃO:"):
     - SG_STATUS: domínio provisório ('ABERTO','EM_APROVACAO','APROVADO',
       'REPROVADO','CONCLUIDO'). Ajustar o CK_KZN_PVC_STATUS se a lista real
       for diferente.
     - Nullability de ID_REPLICACAO, ID_APROVADOR, ID_DESPERDICIO, ID_MOEDA,
       ID_MOTIVO, DT_CONCLUSAO em KZN_PEDRAVISAOCONSOLIDADA: NULL (só fazem
       sentido em fases posteriores do fluxo do Kaizen). ID_USUARIO_LIDER
       ficou NOT NULL — se puder ficar em branco na criação, trocar pra NULL.
     - VL_RESULTADO_FINANCEIRO: DECIMAL(18,2).
     - Tamanhos de campo, 2ª rodada (pedido do time — padronização geral):
       todo campo VARCHAR(20) (na prática, os NM_* e também CD_MATRICULA e
       SG_STATUS) passou para VARCHAR(30); todo campo VARCHAR(40) (os DS_*
       e também DS_EMAIL) passou para VARCHAR(100); todo campo VARCHAR(150)
       (os URL_*) passou para VARCHAR(200). NM_HIERARQUIA_* (VARCHAR(50)) e
       campos VARCHAR de outros tamanhos (SG_IDIOMA, SG_MOEDA, SG_ATIVO,
       TP_OPERACAO) ficaram fora da regra por não se encaixarem em nenhum
       dos três tamanhos-origem. Ainda ficou apertado pra texto livre de
       formulário (DS_PROBLEMA, DS_OBJETIVO, DS_ESTADO_ANTES/DEPOIS,
       DS_LICOES_APRENDIDAS, DS_RESULTADO_ESPERADO — antes VARCHAR(MAX)) —
       confirmar se 100 é suficiente antes de produção. Seção 20 (ALTER
       COLUMN) amplia essas colunas em bancos onde as tabelas já existirem
       com os tamanhos antigos, sem perda de dado (mesma nullability,
       apenas mais espaço) — necessário porque os CREATE TABLE abaixo só
       rodam quando a tabela ainda não existe (IF OBJECT_ID ... IS NULL).
     - KZN_MDM_HIERARQUIA não tem seed nem trigger de escrita pela aplicação
       assumida como fonte única — presumido que é alimentada por integração
       externa (job/ETL do RH/MDM), não pela tela do KZN. Se a aplicação
       também gravar nela diretamente, avisar para revisar.
     - Log de auditoria (KZN_LOG_PEDRAVISAOCONSOLIDADA) é por evento
       (quem/quando/criado ou atualizado), sem diff campo a campo.
     - ID_USUARIO_ATUALIZACAO deve ser enviado pela aplicação em todo UPDATE
       de KZN_PEDRAVISAOCONSOLIDADA — a trigger não tem como descobrir quem
       está agindo sozinha (conexão via conta de serviço).
     - IDENTITY removido de TODAS as PKs (pedido do time, nesta rodada): as
       12 chaves primárias que eram INT IDENTITY(1,1) viraram INT simples —
       a aplicação passa a ser responsável por gerar/enviar o valor em todo
       INSERT (nenhuma delas tem DEFAULT). Sem IDENTITY, o SQL Server também
       não garante mais unicidade/sequência sozinho: colisão de PK vira erro
       de constraint na hora do INSERT, mas cabe à aplicação evitar reuso de
       ID. O seed de KZN_IDIOMA/KZN_MOEDA foi ajustado pra atribuir o ID
       explicitamente (1 a 5 em cada), já que não há mais geração automática.
     - Chave composta por idioma (pedido do time, nesta rodada): KZN_CATEGORIA,
       KZN_REPLICACAO, KZN_DESPERDICIO, KZN_TIPO_RESULTADO, KZN_RESULTADOS e
       KZN_MOTIVO_REPROVACAO passaram a ter PK composta (ID_X, ID_IDIOMA), já
       que o mesmo cadastro existe em mais de um idioma (uma linha por idioma).
       Consequência: o SQL Server não permite FK apontando para parte de uma
       chave composta, então as colunas ID_CATEGORIA, ID_REPLICACAO,
       ID_DESPERDICIO e ID_MOTIVO em KZN_PEDRAVISAOCONSOLIDADA, e ID_RESULTADO
       em KZN_RESULTADO_KAIZEN, deixaram de ter FK de banco (continuam INT,
       apenas sem constraint) — decisão confirmada com o time: "sem FK de
       banco pra essas colunas", integridade fica sob responsabilidade da
       aplicação. Já FK_KZN_RESULTADOS_TIPO virou FK composta de verdade
       (ID_TIPO_RESULTADO, ID_IDIOMA), pois KZN_RESULTADOS já carrega seu
       próprio ID_IDIOMA. As triggers AFTER UPDATE dessas 6 tabelas também
       foram ajustadas para casar inserted x tabela por (ID_X, ID_IDIOMA) —
       antes casavam só por ID_X, o que agora atualizaria todas as linhas do
       mesmo ID em qualquer idioma.
     - Tabelas CI.KZN_ADMIN e CI.KZN_APROVADOR (reestruturadas): papel igual
       ao de subconjunto de KZN_MDM_HIERARQUIA. Ambas agora possuem PK própria
       (ID_ADMIN e ID_APROVADOR respectivamente) como primeira coluna, ID_USUARIO
       como FK pra MDM posicionado logo antes de DT_ATUALIZACAO.
     - Campo ID_USUARIO (novo, nesta rodada) adicionado antes de
       DT_ATUALIZACAO em KZN_IDIOMA, KZN_CATEGORIA, KZN_REPLICACAO,
       KZN_DESPERDICIO, KZN_MOEDA, KZN_TIPO_RESULTADO, KZN_MOTIVO_REPROVACAO
       e KZN_RESULTADOS — FK opcional (NULL) pra
       CI.KZN_MDM_HIERARQUIA (ID_USUARIO), representando o usuário
       responsável/administrador do cadastro. ASSUNÇÃO: ficou NULL (não
       bloqueia INSERT/seed já existente, ex. o seed de KZN_IDIOMA) —
       trocar pra NOT NULL se a aplicação sempre tiver esse valor.
       KZN_APROVADOR e KZN_ADMIN recebem ID_USUARIO como FK (não como
       segunda coluna com mesmo nome) — nenhuma duplicação de coluna.
     - Reordenação de KZN_PEDRAVISAOCONSOLIDADA (pedido do time, nesta rodada):
       DT_CRIACAO passou a ficar imediatamente antes de DT_CONCLUSAO. SQL
       Server não tem comando de ALTER pra reordenar coluna fisicamente — a
       única forma de mudar a ordem sem perder dado é recriar a tabela e
       migrar as linhas; a seção 17.3 faz isso de forma idempotente (só roda
       se a tabela já existir com a ordem antiga; bancos novos já nascem
       certos pelo CREATE TABLE da seção 13).
     - KZN_MDM_HIERARQUIA (pedido do time, nesta rodada): DS_EMAIL renomeado
       pra CD_EMAIL; novos campos de perfil (NM_SITUACAO, SG_ATIVO, NM_POSICAO,
       NM_PAIS, SG_ESTADO, NM_CIDADE, NM_SITE) inseridos logo após CD_EMAIL;
       PK trocada de simples (ID_USUARIO) pra composta (ID_USUARIO,
       CD_MATRICULA). Mesmo problema de reordenação física do item acima —
       a seção 17.2 recria a tabela de forma idempotente pra bancos já
       existentes. ASSUNÇÃO CRÍTICA: praticamente todo o schema tem FK pra
       KZN_MDM_HIERARQUIA (ID_USUARIO) (~15 tabelas), e o SQL Server não
       permite FK apontando pra parte de uma PK composta sem uma UNIQUE
       constraint dedicada — por isso foi adicionado
       UQ_KZN_MDM_HIERARQUIA_USUARIO (UNIQUE em ID_USUARIO); sem essa
       constraint extra, a criação de todas as FKs existentes falharia.
       Nullability/tamanho dos 7 campos novos: SG_ATIVO NOT NULL DEFAULT
       ('S') (segue o padrão de SG_ATIVO usado no resto do schema); os
       outros 6 ficaram NULL (perfil pode vir incompleto da integração
       RH/MDM) e VARCHAR(30), exceto SG_ESTADO em VARCHAR(5) (sigla/UF) —
       confirmar com o time se algum precisa ser NOT NULL ou de outro
       tamanho.
     - KZN_APROVADOR / KZN_ADMIN — chave composta (pedido do time, nesta
       rodada, confirmado via clarificação): KZN_APROVADOR passou a ter PK
       composta (ID_APROVADOR, ID_USUARIO) e KZN_ADMIN passou a ter PK
       composta (ID_ADMIN, ID_USUARIO) — cada tabela usa seu próprio campo
       identificador, não ID_ADMIN nas duas (o texto original do pedido
       repetia "ID_USUARIO, ID_ADMIN" nas duas atividades, o que só faz
       sentido pra KZN_ADMIN; tratado como erro de cópia). Como
       FK_KZN_PVC_APROVADOR (em KZN_PEDRAVISAOCONSOLIDADA) referencia só
       ID_APROVADOR, foi adicionado UQ_KZN_APROVADOR_ID (UNIQUE em
       ID_APROVADOR) pra manter essa FK válida. Nenhuma FK externa aponta
       hoje pra KZN_ADMIN, então nenhuma UNIQUE extra foi necessária lá.
       Ordem final das colunas (pedido do time, ajuste seguinte): ID_APROVADOR/
       ID_ADMIN (PK) → ID_USUARIO (chave secundária/FK, logo após a PK) →
       SG_ATIVO → DT_ATUALIZACAO. Seção 17.4 aplica a migração completa
       (chave composta + reordenação física) em bancos já existentes —
       reordenar coluna exige recriar a tabela (mesma técnica das seções
       17.2/17.3), já que o SQL Server não tem ALTER TABLE pra isso.
     - Nova tabela CI.KZN_TIPO_USUARIO (pedido do time, nesta rodada):
       cadastro simples de tipos/perfis de usuário do KZN — ID_TIPO_USUARIO
       (PK, sem IDENTITY, seguindo o mesmo padrão adotado pra todas as
       demais PKs do schema nesta rodada), NM_USUARIO (mantido com esse
       nome exato, conforme especificado no pedido, mesmo divergindo do
       padrão NM_<ENTIDADE> usado nas demais tabelas de domínio como
       NM_CATEGORIA/NM_REPLICACAO), ID_USUARIO (FK opcional pra MDM, mesmo
       padrão das outras tabelas de cadastro) e DT_ATUALIZACAO. Sem
       ID_IDIOMA (não foi pedido suporte multi-idioma aqui) e sem SG_ATIVO
       (não estava na lista de campos pedida). Adicionado UQ_KZN_TIPO_USUARIO_NM
       (nome único) e documentação via sp_addextendedproperty (seção 17.1).
     - KZN_MDM_HIERARQUIA — SG_ESTADO renomeado pra NM_ESTADO (pedido do
       time, nesta rodada); tipo ajustado de VARCHAR(5) pra VARCHAR(30) pra
       seguir o padrão dos demais campos NM_* do schema (a mudança de
       prefixo SG_→NM_ sugere nome por extenso, não mais sigla/UF —
       ASSUNÇÃO: confirmar com o time se o formato do dado realmente muda,
       ou se é só rename mantendo sigla curta). Campo ID_TIPO_USUARIO
       inserido logo após CD_MATRICULA, FK pra CI.KZN_TIPO_USUARIO
       (ID_TIPO_USUARIO), NULL (ASSUNÇÃO: opcional, mesmo padrão de
       ID_USUARIO nas tabelas de cadastro). Isso cria uma referência
       circular entre KZN_MDM_HIERARQUIA e KZN_TIPO_USUARIO (cada uma tem
       FK pra outra) — nenhuma das duas pode declarar a FK cruzada no
       próprio CREATE TABLE, então FK_KZN_MDM_TIPO_USUARIO é adicionada à
       parte na seção 17.2b, depois que as duas tabelas já existem.
     - Correção de idempotência na seção 17.2 (constatada nesta rodada, não
       pedida, mas necessária pro script continuar re-executável como já
       era o requisito original): a versão anterior da migração referenciava
       DS_EMAIL de forma estática dentro de um IF — em T-SQL, batch avulso
       (fora de stored procedure) não tem resolução de nomes adiada, então
       uma coluna que deixasse de existir (após a 1ª execução bem-sucedida,
       quando ela já vira CD_EMAIL) quebraria a COMPILAÇÃO do batch inteiro
       numa 2ª execução, mesmo com o IF de guarda impedindo a execução em
       runtime. A seção 17.2 agora monta o INSERT de migração via
       sp_executesql (SQL dinâmico), resolvendo os nomes de origem em
       runtime — mesmo tratamento dado agora a SG_ESTADO/NM_ESTADO.
     - VERSÃO-BASE FIXADA PELO TIME (pedido explícito nesta rodada): a partir
       daqui o script passou a usar como baseline uma versão anterior deste
       arquivo (anexada pelo time como "capítulo fixado"), sobre a qual foi
       aplicada apenas UMA alteração: NM_HIERARQUIA_N1..N8 (8 campos) em
       CI.KZN_MDM_HIERARQUIA e CI.KZN_KAIZEN_HIERARQUIA passaram de
       VARCHAR(50) para VARCHAR(80) — tanto nos CREATE TABLE (seções 2 e 17)
       quanto na tabela reconstruída pela migração de KZN_MDM_HIERARQUIA
       (seção 17.2) e num novo bloco de ALTER COLUMN idempotente pra
       KZN_KAIZEN_HIERARQUIA (seção 21, que ainda não existia nesta versão-
       base). ASSUNÇÃO/ALERTA: por ser uma versão anterior, este baseline NÃO
       inclui três ajustes feitos em rodadas mais recentes deste projeto, que
       ficam de fora até serem pedidos de novo: (1) PK composta de 3 colunas
       (ID_USUARIO, CD_MATRICULA, ID_TIPO_USUARIO) em KZN_MDM_HIERARQUIA —
       aqui a PK permanece composta só por (ID_USUARIO, CD_MATRICULA), com
       ID_TIPO_USUARIO como coluna comum (NULL), fora da chave; (2) a busca
       dinâmica de FKs (sys.foreign_keys) nas migrações das seções 17.2/17.3/
       17.4 — aqui essas seções ainda usam listas fixas de nomes de FK
       (IF OBJECT_ID('CI.FK_xxx','F')...), o que pode voltar a falhar com
       "Could not drop object ... referenced by a FOREIGN KEY constraint" se
       alguma FK existir no banco com nome diferente do previsto; (3) a
       descoberta dinâmica de FKs+tabelas na Seção 1 (DROP) — aqui a Seção 1
       voltou a usar uma lista fixa e ordenada de DROP TABLE IF EXISTS, que
       NÃO inclui CI.KZN_TIPO_USUARIO, reproduzindo o problema já relatado de
       tabelas (KZN_TIPO_USUARIO, KZN_MDM_HIERARQUIA, KZN_HIERARQUIA) não
       serem removidas ao reexecutar o script do zero.
     - KZN_APROVADOR / KZN_ADMIN — nova coluna CD_MATRICULA + troca de PK
       (pedido do time, nesta rodada): adicionada CD_MATRICULA (2ª coluna,
       logo após ID_APROVADOR/ID_ADMIN); ID_USUARIO reposicionado pra
       penúltima coluna (antes de DT_ATUALIZACAO); a PK composta trocou de
       (ID_APROVADOR/ID_ADMIN, ID_USUARIO) — item de uma rodada anterior, ver
       ASSUNÇÃO acima — pra (ID_APROVADOR/ID_ADMIN, CD_MATRICULA); ID_USUARIO
       deixou de ser chave e passou a ser só FK pra CI.KZN_MDM_HIERARQUIA
       (auditoria de quem cadastrou o Aprovador/Admin). UQ_KZN_APROVADOR_ID
       (UNIQUE em ID_APROVADOR) e FK_KZN_PVC_APROVADOR não mudam. Seção 17.4
       migra bancos já existentes recriando as tabelas (mesma técnica de
       reordenação física das demais seções 17.x), preenchendo CD_MATRICULA
       a partir de CI.KZN_MDM_HIERARQUIA (join pelo ID_USUARIO já existente
       em cada linha) e abortando com RAISERROR antes de qualquer alteração
       se algum registro não tiver correspondência. ASSUNÇÃO: CD_MATRICULA
       ficou INT (pedido explícito e repetido do time), embora
       CI.KZN_MDM_HIERARQUIA.CD_MATRICULA seja VARCHAR(30) — os dois campos
       não têm FK entre si (só ID_USUARIO tem FK, por pedido) nem checagem
       de tipo pelo banco; se a matrícula puder ter caracteres não numéricos,
       avisar para reavaliar o tipo. Nenhuma rotina/tela de front-end foi
       ajustada nesta entrega: este repositório não contém código de
       aplicação que consuma o schema CI/KZN_* (é um projeto de front-end
       não relacionado), então o item "ajustar rotinas/telas dependentes" do
       pedido não se aplica aqui — sinalizar se houver outro repositório com
       esse código.
     - KZN_MDM_HIERARQUIA — PK composta de 3 colunas (pedido do time, nesta
       rodada): a PK passou de (ID_USUARIO, CD_MATRICULA) pra (ID_USUARIO,
       CD_MATRICULA, ID_TIPO_USUARIO). Como toda coluna de PK é
       obrigatoriamente NOT NULL no SQL Server, ID_TIPO_USUARIO deixou de
       ser opcional (era NULL desde que foi criado). A migração (seção
       17.2) agora começa com uma checagem de pré-voo que aborta o script
       (RAISERROR + RETURN, sem alterar nada) se a coluna ainda não existir
       ou se houver qualquer registro com ID_TIPO_USUARIO nulo — não há
       valor-padrão de negócio razoável pra preencher automaticamente; o
       time precisa garantir que todo usuário já tenha um tipo definido
       antes de reexecutar. ASSUNÇÃO/ALERTA sobre a própria PK: como
       ID_USUARIO e CD_MATRICULA já têm UNIQUE dedicada cada um
       (UQ_KZN_MDM_HIERARQUIA_USUARIO e UQ_KZN_MDM_HIERARQUIA_MATR, mantidas
       pelas ~15 FKs do resto do schema), qualquer linha da tabela já é
       identificada de forma única só por ID_USUARIO (ou só por
       CD_MATRICULA) — a PK de 3 colunas não habilita múltiplas linhas por
       usuário nem por matrícula; ID_TIPO_USUARIO entra na chave "de
       carona", sem mudar a cardinalidade real da tabela. Se a intenção for
       permitir mais de um ID_TIPO_USUARIO por usuário (histórico de
       tipos, por período), as duas UNIQUE atuais precisam ser revistas —
       do jeito que está hoje, elas continuam restringindo a 1 linha por
       usuário/matrícula independente da PK.
   ============================================================================== */

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

USE [SEU_BANCO];   -- <<< AJUSTAR
GO

/* ==============================================================================
   0. SCHEMA
   ============================================================================== */
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'CI')
    EXEC('CREATE SCHEMA CI AUTHORIZATION dbo;');
GO

/* ==============================================================================
   1. DROP (ordem inversa das dependências) — descomente para recriar do zero
   ============================================================================== */
/*
DROP TABLE IF EXISTS CI.KZN_KAIZEN_HIERARQUIA;
DROP TABLE IF EXISTS CI.KZN_RESULTADO_KAIZEN;
DROP TABLE IF EXISTS CI.KZN_MEMBROS_EQUIPE;
DROP TABLE IF EXISTS CI.KZN_LOG_PEDRAVISAOCONSOLIDADA;
DROP TABLE IF EXISTS CI.KZN_PEDRAVISAOCONSOLIDADA;
DROP TABLE IF EXISTS CI.KZN_MOTIVO_REPROVACAO;
DROP TABLE IF EXISTS CI.KZN_RESULTADOS;
DROP TABLE IF EXISTS CI.KZN_TIPO_RESULTADO;
DROP TABLE IF EXISTS CI.KZN_MOEDA;
DROP TABLE IF EXISTS CI.KZN_DESPERDICIO;
DROP TABLE IF EXISTS CI.KZN_REPLICACAO;
DROP TABLE IF EXISTS CI.KZN_CATEGORIA;
DROP TABLE IF EXISTS CI.KZN_ADMIN;
DROP TABLE IF EXISTS CI.KZN_APROVADOR;
DROP TABLE IF EXISTS CI.KZN_IDIOMA;
DROP TABLE IF EXISTS CI.KZN_MDM_HIERARQUIA;
GO
*/

/* ==============================================================================
   2. TABELA: CI.KZN_MDM_HIERARQUIA  (mestre — referência RH/MDM, sem FK)
   PK composta (ID_USUARIO, CD_MATRICULA, ID_TIPO_USUARIO) — pedido do time,
   nesta rodada: ID_TIPO_USUARIO passou a integrar a chave, o que exigiu
   torná-lo NOT NULL (toda coluna de PK é obrigatoriamente NOT NULL no SQL
   Server). UQ_KZN_MDM_HIERARQUIA_USUARIO (UNIQUE em ID_USUARIO) mantida à
   parte pra sustentar as ~15 FKs do resto do schema que referenciam só
   ID_USUARIO (ver seção 17.2 pra detalhes). ID_TIPO_USUARIO é FK pra
   CI.KZN_TIPO_USUARIO, mas a constraint não é declarada aqui: as duas
   tabelas se referenciam uma à outra (referência circular — KZN_TIPO_USUARIO
   também tem FK pra esta tabela via ID_USUARIO), então nenhuma pode ter a FK
   cruzada no próprio CREATE TABLE sem que a outra já exista. A
   FK_KZN_MDM_TIPO_USUARIO é adicionada à parte na seção 17.2b, depois que
   ambas já existem.
   ============================================================================== */
IF OBJECT_ID('CI.KZN_MDM_HIERARQUIA', 'U') IS NULL
BEGIN
    CREATE TABLE CI.KZN_MDM_HIERARQUIA
    (
        ID_USUARIO          INT                             NOT NULL,
        CD_MATRICULA        VARCHAR(30)                     NOT NULL,
        ID_TIPO_USUARIO     INT                             NOT NULL,   -- ASSUNÇÃO: passou a integrar a PK composta (pedido do time, nesta rodada); FK pra CI.KZN_TIPO_USUARIO adicionada na seção 17.2b (ver comentário acima)
        NM_USUARIO          VARCHAR(30)                     NOT NULL,
        CD_EMAIL            VARCHAR(100)                    NOT NULL,
        NM_SITUACAO         VARCHAR(30)                         NULL,   -- ASSUNÇÃO: situação do colaborador (ex.: Ativo, Afastado); opcional
        SG_ATIVO            VARCHAR(1)                      NOT NULL
            CONSTRAINT DF_KZN_MDM_HIERARQUIA_SG_ATIVO DEFAULT ('S'),      -- ASSUNÇÃO: 'S'/'N', ativo por padrão
        NM_POSICAO          VARCHAR(30)                         NULL,
        NM_PAIS             VARCHAR(30)                         NULL,
        NM_ESTADO           VARCHAR(30)                         NULL,   -- renomeado de SG_ESTADO
        NM_CIDADE           VARCHAR(30)                         NULL,
        NM_SITE             VARCHAR(30)                         NULL,
        NM_HIERARQUIA_N1    VARCHAR(80)                         NULL,
        NM_HIERARQUIA_N2    VARCHAR(80)                         NULL,
        NM_HIERARQUIA_N3    VARCHAR(80)                         NULL,
        NM_HIERARQUIA_N4    VARCHAR(80)                         NULL,
        NM_HIERARQUIA_N5    VARCHAR(80)                         NULL,
        NM_HIERARQUIA_N6    VARCHAR(80)                         NULL,
        NM_HIERARQUIA_N7    VARCHAR(80)                         NULL,
        NM_HIERARQUIA_N8    VARCHAR(80)                         NULL,
        DT_ATUALIZACAO      DATETIME2(3)                    NOT NULL
            CONSTRAINT DF_KZN_MDM_HIERARQUIA_DT_ATUALIZACAO DEFAULT (SYSDATETIME()),

        CONSTRAINT PK_KZN_MDM_HIERARQUIA         PRIMARY KEY CLUSTERED (ID_USUARIO, CD_MATRICULA, ID_TIPO_USUARIO),
        CONSTRAINT UQ_KZN_MDM_HIERARQUIA_USUARIO UNIQUE (ID_USUARIO),
        CONSTRAINT UQ_KZN_MDM_HIERARQUIA_MATR    UNIQUE (CD_MATRICULA)
    );

    CREATE NONCLUSTERED INDEX IX_KZN_MDM_HIERARQUIA_EMAIL
        ON CI.KZN_MDM_HIERARQUIA (CD_EMAIL);
END
GO

/* ==============================================================================
   3. TABELA: CI.KZN_IDIOMA  (tabela mestre — referenciada pelas demais)
   ============================================================================== */
IF OBJECT_ID('CI.KZN_IDIOMA', 'U') IS NULL
BEGIN
    CREATE TABLE CI.KZN_IDIOMA
    (
        ID_IDIOMA       INT                             NOT NULL,
        URL_ICONE       VARCHAR(200)                        NULL,
        SG_IDIOMA       VARCHAR(5)                      NOT NULL,   -- ISO 639-1 + região (pt-BR)
        NM_IDIOMA       VARCHAR(30)                     NOT NULL,
        NM_PAIS         VARCHAR(30)                         NULL,
        SG_ATIVO        VARCHAR(1)                      NOT NULL
            CONSTRAINT DF_KZN_IDIOMA_SG_ATIVO DEFAULT ('S'),           -- ASSUNÇÃO: 'S'/'N', ativo por padrão
        ID_USUARIO      INT                                 NULL,   -- usuário (MDM) responsável/administrador do cadastro
        DT_ATUALIZACAO  DATETIME2(3)                    NOT NULL
            CONSTRAINT DF_KZN_IDIOMA_DT_ATUALIZACAO DEFAULT (SYSDATETIME()),

        CONSTRAINT PK_KZN_IDIOMA         PRIMARY KEY CLUSTERED (ID_IDIOMA),
        CONSTRAINT UQ_KZN_IDIOMA_SG      UNIQUE (SG_IDIOMA),
        CONSTRAINT FK_KZN_IDIOMA_USUARIO FOREIGN KEY (ID_USUARIO)
            REFERENCES CI.KZN_MDM_HIERARQUIA (ID_USUARIO)
    );
END
GO

/* ==============================================================================
   4. TABELA: CI.KZN_APROVADOR
   (papel: subconjunto de KZN_MDM_HIERARQUIA habilitado a aprovar Kaizens —
   não duplica nome, mas agora carrega a própria CD_MATRICULA; PK composta
   (ID_APROVADOR, CD_MATRICULA), com CD_MATRICULA logo após a PK e ID_USUARIO
   reposicionado pra penúltima coluna (pedido do time, nesta rodada — ver
   ASSUNÇÃO no cabeçalho do arquivo). UQ_KZN_APROVADOR_ID (UNIQUE em
   ID_APROVADOR) mantida à parte pra sustentar FK_KZN_PVC_APROVADOR, que
   referencia só ID_APROVADOR)
   ============================================================================== */
IF OBJECT_ID('CI.KZN_APROVADOR', 'U') IS NULL
BEGIN
    CREATE TABLE CI.KZN_APROVADOR
    (
        ID_APROVADOR    INT                             NOT NULL,
        CD_MATRICULA    INT                             NOT NULL,   -- ASSUNÇÃO: tipo INT conforme pedido do time; CD_MATRICULA em CI.KZN_MDM_HIERARQUIA é VARCHAR(30) — sem FK dedicada aqui (só ID_USUARIO tem FK, por pedido), então não há checagem de tipo pelo banco
        SG_ATIVO        VARCHAR(1)                      NOT NULL
            CONSTRAINT DF_KZN_APROVADOR_SG_ATIVO DEFAULT ('S'),        -- ASSUNÇÃO: 'S'/'N', ativo por padrão
        ID_USUARIO      INT                             NOT NULL,     -- FK -> MDM: usuário que cadastrou o aprovador (auditoria); penúltima coluna
        DT_ATUALIZACAO  DATETIME2(3)                    NOT NULL
            CONSTRAINT DF_KZN_APROVADOR_DT_ATUALIZACAO DEFAULT (SYSDATETIME()),

        CONSTRAINT PK_KZN_APROVADOR         PRIMARY KEY CLUSTERED (ID_APROVADOR, CD_MATRICULA),
        CONSTRAINT UQ_KZN_APROVADOR_ID      UNIQUE (ID_APROVADOR),
        CONSTRAINT FK_KZN_APROVADOR_USUARIO FOREIGN KEY (ID_USUARIO)
            REFERENCES CI.KZN_MDM_HIERARQUIA (ID_USUARIO)
    );
END
GO

/* ==============================================================================
   5. TABELA: CI.KZN_ADMIN
   (papel: subconjunto de KZN_MDM_HIERARQUIA habilitado a administrar os
   cadastros do KZN — mesmo desenho de KZN_APROVADOR, com PK composta
   (ID_ADMIN, CD_MATRICULA), CD_MATRICULA logo após a PK e ID_USUARIO
   reposicionado pra penúltima coluna. Nenhuma FK externa referencia
   KZN_ADMIN hoje, então não foi necessária uma UNIQUE adicional em ID_ADMIN)
   ============================================================================== */
IF OBJECT_ID('CI.KZN_ADMIN', 'U') IS NULL
BEGIN
    CREATE TABLE CI.KZN_ADMIN
    (
        ID_ADMIN        INT                             NOT NULL,
        CD_MATRICULA    INT                             NOT NULL,   -- ASSUNÇÃO: mesmo tipo/observação de CI.KZN_APROVADOR.CD_MATRICULA acima
        SG_ATIVO        VARCHAR(1)                      NOT NULL
            CONSTRAINT DF_KZN_ADMIN_SG_ATIVO DEFAULT ('S'),            -- ASSUNÇÃO: 'S'/'N', ativo por padrão
        ID_USUARIO      INT                             NOT NULL,     -- FK -> MDM: usuário que cadastrou o admin (auditoria); penúltima coluna
        DT_ATUALIZACAO  DATETIME2(3)                    NOT NULL
            CONSTRAINT DF_KZN_ADMIN_DT_ATUALIZACAO DEFAULT (SYSDATETIME()),

        CONSTRAINT PK_KZN_ADMIN         PRIMARY KEY CLUSTERED (ID_ADMIN, CD_MATRICULA),
        CONSTRAINT FK_KZN_ADMIN_USUARIO FOREIGN KEY (ID_USUARIO)
            REFERENCES CI.KZN_MDM_HIERARQUIA (ID_USUARIO)
    );
END
GO

/* ==============================================================================
   6. TABELA: CI.KZN_CATEGORIA
   ============================================================================== */
IF OBJECT_ID('CI.KZN_CATEGORIA', 'U') IS NULL
BEGIN
    CREATE TABLE CI.KZN_CATEGORIA
    (
        ID_CATEGORIA    INT                             NOT NULL,
        ID_IDIOMA       INT                             NOT NULL,
        URL_ICONE       VARCHAR(200)                        NULL,
        NM_CATEGORIA    VARCHAR(30)                     NOT NULL,
        DS_CATEGORIA    VARCHAR(100)                         NULL,
        SG_ATIVO        VARCHAR(1)                      NOT NULL
            CONSTRAINT DF_KZN_CATEGORIA_SG_ATIVO DEFAULT ('S'),        -- ASSUNÇÃO: 'S'/'N', ativo por padrão
        ID_USUARIO      INT                                 NULL,   -- usuário (MDM) responsável/administrador do cadastro
        DT_ATUALIZACAO  DATETIME2(3)                    NOT NULL
            CONSTRAINT DF_KZN_CATEGORIA_DT_ATUALIZACAO DEFAULT (SYSDATETIME()),

        CONSTRAINT PK_KZN_CATEGORIA          PRIMARY KEY CLUSTERED (ID_CATEGORIA, ID_IDIOMA),
        CONSTRAINT FK_KZN_CATEGORIA_IDIOMA   FOREIGN KEY (ID_IDIOMA)
            REFERENCES CI.KZN_IDIOMA (ID_IDIOMA),
        CONSTRAINT FK_KZN_CATEGORIA_USUARIO  FOREIGN KEY (ID_USUARIO)
            REFERENCES CI.KZN_MDM_HIERARQUIA (ID_USUARIO),
        CONSTRAINT UQ_KZN_CATEGORIA_NM       UNIQUE (ID_IDIOMA, NM_CATEGORIA)
    );

    CREATE NONCLUSTERED INDEX IX_KZN_CATEGORIA_ID_IDIOMA
        ON CI.KZN_CATEGORIA (ID_IDIOMA) INCLUDE (NM_CATEGORIA);
END
GO

/* ==============================================================================
   7. TABELA: CI.KZN_REPLICACAO
   ============================================================================== */
IF OBJECT_ID('CI.KZN_REPLICACAO', 'U') IS NULL
BEGIN
    CREATE TABLE CI.KZN_REPLICACAO
    (
        ID_REPLICACAO   INT                             NOT NULL,
        ID_IDIOMA       INT                             NOT NULL,
        URL_ICONE       VARCHAR(200)                        NULL,
        NM_REPLICACAO   VARCHAR(30)                     NOT NULL,
        DS_REPLICACAO   VARCHAR(100)                         NULL,
        SG_ATIVO        VARCHAR(1)                      NOT NULL
            CONSTRAINT DF_KZN_REPLICACAO_SG_ATIVO DEFAULT ('S'),       -- ASSUNÇÃO: 'S'/'N', ativo por padrão
        ID_USUARIO      INT                                 NULL,   -- usuário (MDM) responsável/administrador do cadastro
        DT_ATUALIZACAO  DATETIME2(3)                    NOT NULL
            CONSTRAINT DF_KZN_REPLICACAO_DT_ATUALIZACAO DEFAULT (SYSDATETIME()),

        CONSTRAINT PK_KZN_REPLICACAO         PRIMARY KEY CLUSTERED (ID_REPLICACAO, ID_IDIOMA),
        CONSTRAINT FK_KZN_REPLICACAO_IDIOMA  FOREIGN KEY (ID_IDIOMA)
            REFERENCES CI.KZN_IDIOMA (ID_IDIOMA),
        CONSTRAINT FK_KZN_REPLICACAO_USUARIO FOREIGN KEY (ID_USUARIO)
            REFERENCES CI.KZN_MDM_HIERARQUIA (ID_USUARIO),
        CONSTRAINT UQ_KZN_REPLICACAO_NM      UNIQUE (ID_IDIOMA, NM_REPLICACAO)
    );

    CREATE NONCLUSTERED INDEX IX_KZN_REPLICACAO_ID_IDIOMA
        ON CI.KZN_REPLICACAO (ID_IDIOMA) INCLUDE (NM_REPLICACAO);
END
GO

/* ==============================================================================
   8. TABELA: CI.KZN_DESPERDICIO
   ============================================================================== */
IF OBJECT_ID('CI.KZN_DESPERDICIO', 'U') IS NULL
BEGIN
    CREATE TABLE CI.KZN_DESPERDICIO
    (
        ID_DESPERDICIO  INT                             NOT NULL,
        ID_IDIOMA       INT                             NOT NULL,
        URL_ICONE       VARCHAR(200)                        NULL,
        NM_DESPERDICIO  VARCHAR(30)                     NOT NULL,
        DS_DESPERDICIO  VARCHAR(100)                         NULL,
        SG_ATIVO        VARCHAR(1)                      NOT NULL
            CONSTRAINT DF_KZN_DESPERDICIO_SG_ATIVO DEFAULT ('S'),      -- ASSUNÇÃO: 'S'/'N', ativo por padrão
        ID_USUARIO      INT                                 NULL,   -- usuário (MDM) responsável/administrador do cadastro
        DT_ATUALIZACAO  DATETIME2(3)                    NOT NULL
            CONSTRAINT DF_KZN_DESPERDICIO_DT_ATUALIZACAO DEFAULT (SYSDATETIME()),

        CONSTRAINT PK_KZN_DESPERDICIO            PRIMARY KEY CLUSTERED (ID_DESPERDICIO, ID_IDIOMA),
        CONSTRAINT FK_KZN_DESPERDICIO_IDIOMA     FOREIGN KEY (ID_IDIOMA)
            REFERENCES CI.KZN_IDIOMA (ID_IDIOMA),
        CONSTRAINT FK_KZN_DESPERDICIO_USUARIO    FOREIGN KEY (ID_USUARIO)
            REFERENCES CI.KZN_MDM_HIERARQUIA (ID_USUARIO),
        CONSTRAINT UQ_KZN_DESPERDICIO_NM         UNIQUE (ID_IDIOMA, NM_DESPERDICIO)
    );

    CREATE NONCLUSTERED INDEX IX_KZN_DESPERDICIO_ID_IDIOMA
        ON CI.KZN_DESPERDICIO (ID_IDIOMA) INCLUDE (NM_DESPERDICIO);
END
GO

/* ==============================================================================
   9. TABELA: CI.KZN_MOEDA
   ============================================================================== */
IF OBJECT_ID('CI.KZN_MOEDA', 'U') IS NULL
BEGIN
    CREATE TABLE CI.KZN_MOEDA
    (
        ID_MOEDA        INT                             NOT NULL,
        NM_MOEDA        VARCHAR(30)                     NOT NULL,
        SG_MOEDA        CHAR(3)                         NOT NULL,   -- ISO 4217
        NM_PAIS         VARCHAR(30)                         NULL,
        SG_ATIVO        VARCHAR(1)                      NOT NULL
            CONSTRAINT DF_KZN_MOEDA_SG_ATIVO DEFAULT ('S'),            -- ASSUNÇÃO: 'S'/'N', ativo por padrão
        ID_USUARIO      INT                                 NULL,   -- usuário (MDM) responsável/administrador do cadastro
        DT_ATUALIZACAO  DATETIME2(3)                    NOT NULL
            CONSTRAINT DF_KZN_MOEDA_DT_ATUALIZACAO DEFAULT (SYSDATETIME()),

        CONSTRAINT PK_KZN_MOEDA      PRIMARY KEY CLUSTERED (ID_MOEDA),
        CONSTRAINT UQ_KZN_MOEDA_SG   UNIQUE (SG_MOEDA),
        CONSTRAINT FK_KZN_MOEDA_USUARIO FOREIGN KEY (ID_USUARIO)
            REFERENCES CI.KZN_MDM_HIERARQUIA (ID_USUARIO)
    );
END
GO

/* ==============================================================================
   10. TABELA: CI.KZN_TIPO_RESULTADO
   ============================================================================== */
IF OBJECT_ID('CI.KZN_TIPO_RESULTADO', 'U') IS NULL
BEGIN
    CREATE TABLE CI.KZN_TIPO_RESULTADO
    (
        ID_TIPO_RESULTADO  INT                             NOT NULL,
        ID_IDIOMA          INT                             NOT NULL,
        NM_TIPO_RESULTADO  VARCHAR(30)                     NOT NULL,
        SG_ATIVO           VARCHAR(1)                      NOT NULL
            CONSTRAINT DF_KZN_TIPO_RESULTADO_SG_ATIVO DEFAULT ('S'),      -- ASSUNÇÃO: 'S'/'N', ativo por padrão
        ID_USUARIO         INT                                 NULL,   -- usuário (MDM) responsável/administrador do cadastro
        DT_ATUALIZACAO     DATETIME2(3)                    NOT NULL
            CONSTRAINT DF_KZN_TIPO_RESULTADO_DT_ATUALIZACAO DEFAULT (SYSDATETIME()),

        CONSTRAINT PK_KZN_TIPO_RESULTADO          PRIMARY KEY CLUSTERED (ID_TIPO_RESULTADO, ID_IDIOMA),
        CONSTRAINT FK_KZN_TIPO_RESULTADO_IDIOMA   FOREIGN KEY (ID_IDIOMA)
            REFERENCES CI.KZN_IDIOMA (ID_IDIOMA),
        CONSTRAINT FK_KZN_TIPO_RESULTADO_USUARIO  FOREIGN KEY (ID_USUARIO)
            REFERENCES CI.KZN_MDM_HIERARQUIA (ID_USUARIO),
        CONSTRAINT UQ_KZN_TIPO_RESULTADO_NM       UNIQUE (ID_IDIOMA, NM_TIPO_RESULTADO)
    );
END
GO

/* ==============================================================================
   11. TABELA: CI.KZN_RESULTADOS
   ============================================================================== */
IF OBJECT_ID('CI.KZN_RESULTADOS', 'U') IS NULL
BEGIN
    CREATE TABLE CI.KZN_RESULTADOS
    (
        ID_RESULTADO       INT                             NOT NULL,
        ID_IDIOMA          INT                             NOT NULL,
        URL_ICONE          VARCHAR(200)                        NULL,
        ID_TIPO_RESULTADO  INT                             NOT NULL,
        NM_RESULTADO       VARCHAR(30)                     NOT NULL,
        DS_RESULTADO       VARCHAR(100)                         NULL,
        SG_ATIVO           VARCHAR(1)                      NOT NULL
            CONSTRAINT DF_KZN_RESULTADOS_SG_ATIVO DEFAULT ('S'),       -- ASSUNÇÃO: 'S'/'N', ativo por padrão
        ID_USUARIO         INT                                 NULL,   -- usuário (MDM) responsável/administrador do cadastro
        DT_ATUALIZACAO     DATETIME2(3)                    NOT NULL
            CONSTRAINT DF_KZN_RESULTADOS_DT_ATUALIZACAO DEFAULT (SYSDATETIME()),

        CONSTRAINT PK_KZN_RESULTADOS          PRIMARY KEY CLUSTERED (ID_RESULTADO, ID_IDIOMA),
        CONSTRAINT FK_KZN_RESULTADOS_IDIOMA   FOREIGN KEY (ID_IDIOMA)
            REFERENCES CI.KZN_IDIOMA (ID_IDIOMA),
        CONSTRAINT FK_KZN_RESULTADOS_TIPO     FOREIGN KEY (ID_TIPO_RESULTADO, ID_IDIOMA)
            REFERENCES CI.KZN_TIPO_RESULTADO (ID_TIPO_RESULTADO, ID_IDIOMA),
        CONSTRAINT FK_KZN_RESULTADOS_USUARIO  FOREIGN KEY (ID_USUARIO)
            REFERENCES CI.KZN_MDM_HIERARQUIA (ID_USUARIO),
        CONSTRAINT UQ_KZN_RESULTADOS_NM       UNIQUE (ID_IDIOMA, NM_RESULTADO)
    );

    CREATE NONCLUSTERED INDEX IX_KZN_RESULTADOS_ID_IDIOMA
        ON CI.KZN_RESULTADOS (ID_IDIOMA) INCLUDE (NM_RESULTADO);
END
GO

/* ==============================================================================
   12. TABELA: CI.KZN_MOTIVO_REPROVACAO
   ============================================================================== */
IF OBJECT_ID('CI.KZN_MOTIVO_REPROVACAO', 'U') IS NULL
BEGIN
    CREATE TABLE CI.KZN_MOTIVO_REPROVACAO
    (
        ID_MOTIVO       INT                             NOT NULL,
        ID_IDIOMA       INT                             NOT NULL,
        NM_MOTIVO       VARCHAR(30)                     NOT NULL,
        DS_MOTIVO       VARCHAR(100)                         NULL,
        SG_ATIVO        VARCHAR(1)                      NOT NULL
            CONSTRAINT DF_KZN_MOTIVO_REPROVACAO_SG_ATIVO DEFAULT ('S'), -- ASSUNÇÃO: 'S'/'N', ativo por padrão
        ID_USUARIO      INT                                 NULL,   -- usuário (MDM) responsável/administrador do cadastro
        DT_ATUALIZACAO  DATETIME2(3)                    NOT NULL
            CONSTRAINT DF_KZN_MOTIVO_REPROVACAO_DT_ATUALIZACAO DEFAULT (SYSDATETIME()),

        CONSTRAINT PK_KZN_MOTIVO_REPROVACAO          PRIMARY KEY CLUSTERED (ID_MOTIVO, ID_IDIOMA),
        CONSTRAINT FK_KZN_MOTIVO_REPROVACAO_IDIOMA   FOREIGN KEY (ID_IDIOMA)
            REFERENCES CI.KZN_IDIOMA (ID_IDIOMA),
        CONSTRAINT FK_KZN_MOTIVO_REPROVACAO_USUARIO  FOREIGN KEY (ID_USUARIO)
            REFERENCES CI.KZN_MDM_HIERARQUIA (ID_USUARIO),
        CONSTRAINT UQ_KZN_MOTIVO_REPROVACAO_NM       UNIQUE (ID_IDIOMA, NM_MOTIVO)
    );
END
GO

/* ==============================================================================
   13. TABELA: CI.KZN_PEDRAVISAOCONSOLIDADA  (tabela principal / transacional)
   ============================================================================== */
IF OBJECT_ID('CI.KZN_PEDRAVISAOCONSOLIDADA', 'U') IS NULL
BEGIN
    CREATE TABLE CI.KZN_PEDRAVISAOCONSOLIDADA
    (
        ID_KAIZEN                  INT                             NOT NULL,
        ID_USUARIO_CADASTRO        INT                             NOT NULL,   -- FK -> MDM: quem registrou
        ID_USUARIO_LIDER           INT                             NOT NULL,   -- FK -> MDM: líder do Kaizen  -- ASSUNÇÃO: NOT NULL
        NM_KAIZEN                  VARCHAR(30)                     NOT NULL,
        ID_CATEGORIA               INT                             NOT NULL,
        ID_REPLICACAO              INT                                 NULL,   -- ASSUNÇÃO: opcional
        DS_PROBLEMA                VARCHAR(100)                        NULL,
        DS_OBJETIVO                VARCHAR(100)                        NULL,
        SG_STATUS                  VARCHAR(30)                     NOT NULL
            CONSTRAINT DF_KZN_PVC_STATUS DEFAULT ('ABERTO'),               -- ASSUNÇÃO: domínio provisório, ver CK abaixo
        ID_APROVADOR               INT                                 NULL,   -- só preenchido quando alguém aprova/reprova
        URL_IMG_ANTES               VARCHAR(200)                       NULL,
        DS_ESTADO_ANTES            VARCHAR(100)                        NULL,
        URL_IMG_DEPOIS              VARCHAR(200)                       NULL,
        DS_ESTADO_DEPOIS           VARCHAR(100)                        NULL,
        URL_REFERENCIA             VARCHAR(200)                       NULL,
        ID_DESPERDICIO             INT                                 NULL,
        DS_LICOES_APRENDIDAS       VARCHAR(100)                        NULL,
        VL_RESULTADO_FINANCEIRO    DECIMAL(18,2)                      NULL,
        ID_MOEDA                   INT                                 NULL,
        DS_RESULTADO_ESPERADO      VARCHAR(100)                        NULL,
        DT_CRIACAO                 DATETIME2(3)                    NOT NULL
            CONSTRAINT DF_KZN_PVC_DT_CRIACAO DEFAULT (SYSDATETIME()),
        DT_CONCLUSAO               DATE                                NULL,
        ID_MOTIVO                  INT                                 NULL,   -- só preenchido quando SG_STATUS = REPROVADO
        DT_ATUALIZACAO             DATETIME2(3)                    NOT NULL
            CONSTRAINT DF_KZN_PVC_DT_ATUALIZACAO DEFAULT (SYSDATETIME()),
        ID_USUARIO_ATUALIZACAO     INT                             NOT NULL,   -- app envia a cada INSERT/UPDATE (quem está agindo)

        CONSTRAINT PK_KZN_PVC                      PRIMARY KEY CLUSTERED (ID_KAIZEN),
        CONSTRAINT FK_KZN_PVC_USUARIO_CADASTRO     FOREIGN KEY (ID_USUARIO_CADASTRO)
            REFERENCES CI.KZN_MDM_HIERARQUIA (ID_USUARIO),
        CONSTRAINT FK_KZN_PVC_USUARIO_LIDER        FOREIGN KEY (ID_USUARIO_LIDER)
            REFERENCES CI.KZN_MDM_HIERARQUIA (ID_USUARIO),
        CONSTRAINT FK_KZN_PVC_USUARIO_ATUALIZACAO  FOREIGN KEY (ID_USUARIO_ATUALIZACAO)
            REFERENCES CI.KZN_MDM_HIERARQUIA (ID_USUARIO),
        -- ID_CATEGORIA, ID_REPLICACAO, ID_DESPERDICIO e ID_MOTIVO NÃO têm FK de banco:
        -- as tabelas de destino agora têm PK composta (ID_X, ID_IDIOMA) e o SQL Server não
        -- permite FK apontando para parte de uma chave composta; a integridade referencial
        -- dessas colunas fica sob responsabilidade da aplicação (decisão confirmada com o time)
        CONSTRAINT FK_KZN_PVC_APROVADOR            FOREIGN KEY (ID_APROVADOR)
            REFERENCES CI.KZN_APROVADOR (ID_APROVADOR),
        CONSTRAINT FK_KZN_PVC_MOEDA                FOREIGN KEY (ID_MOEDA)
            REFERENCES CI.KZN_MOEDA (ID_MOEDA),
        CONSTRAINT CK_KZN_PVC_STATUS               CHECK (SG_STATUS IN
            ('ABERTO','EM_APROVACAO','APROVADO','REPROVADO','CONCLUIDO'))   -- ASSUNÇÃO: ajustar domínio real
    );

    CREATE NONCLUSTERED INDEX IX_KZN_PVC_STATUS        ON CI.KZN_PEDRAVISAOCONSOLIDADA (SG_STATUS);
    CREATE NONCLUSTERED INDEX IX_KZN_PVC_CATEGORIA     ON CI.KZN_PEDRAVISAOCONSOLIDADA (ID_CATEGORIA);
    CREATE NONCLUSTERED INDEX IX_KZN_PVC_USUARIO_LIDER ON CI.KZN_PEDRAVISAOCONSOLIDADA (ID_USUARIO_LIDER);
END
GO

/* ==============================================================================
   14. TABELA: CI.KZN_LOG_PEDRAVISAOCONSOLIDADA
   (histórico de auditoria: 1 linha por criação/atualização da tabela principal)
   ============================================================================== */
IF OBJECT_ID('CI.KZN_LOG_PEDRAVISAOCONSOLIDADA', 'U') IS NULL
BEGIN
    CREATE TABLE CI.KZN_LOG_PEDRAVISAOCONSOLIDADA
    (
        ID_LOG                INT                             NOT NULL,
        ID_KAIZEN             INT                             NOT NULL,
        TP_OPERACAO           CHAR(1)                         NOT NULL,   -- 'C' Criado / 'A' Atualizado
        DT_OPERACAO           DATETIME2(3)                    NOT NULL
            CONSTRAINT DF_KZN_LOG_PVC_DT_OPERACAO DEFAULT (SYSDATETIME()),
        ID_USUARIO_OPERACAO   INT                             NOT NULL,

        CONSTRAINT PK_KZN_LOG_PVC           PRIMARY KEY CLUSTERED (ID_LOG),
        CONSTRAINT FK_KZN_LOG_PVC_KAIZEN    FOREIGN KEY (ID_KAIZEN)
            REFERENCES CI.KZN_PEDRAVISAOCONSOLIDADA (ID_KAIZEN),
        CONSTRAINT FK_KZN_LOG_PVC_USUARIO   FOREIGN KEY (ID_USUARIO_OPERACAO)
            REFERENCES CI.KZN_MDM_HIERARQUIA (ID_USUARIO),
        CONSTRAINT CK_KZN_LOG_PVC_TIPO      CHECK (TP_OPERACAO IN ('C','A'))
    );

    CREATE NONCLUSTERED INDEX IX_KZN_LOG_PVC_KAIZEN
        ON CI.KZN_LOG_PEDRAVISAOCONSOLIDADA (ID_KAIZEN, DT_OPERACAO DESC);
END
GO

/* ==============================================================================
   AUXILIARES | TABELAS DE SUPORTE À PRINCIPAL
   ============================================================================== */

/* ------------------------------------------------------------------------------
   15. TABELA: CI.KZN_MEMBROS_EQUIPE
   (usuários que participaram do Kaizen — conceito distinto de KZN_APROVADOR;
   referencia a MDM diretamente, qualquer colaborador pode ser membro)
   ------------------------------------------------------------------------------ */
IF OBJECT_ID('CI.KZN_MEMBROS_EQUIPE', 'U') IS NULL
BEGIN
    CREATE TABLE CI.KZN_MEMBROS_EQUIPE
    (
        ID_KAIZEN       INT                             NOT NULL,
        ID_USUARIO      INT                             NOT NULL,
        DT_ATUALIZACAO  DATETIME2(3)                    NOT NULL
            CONSTRAINT DF_KZN_MEMBROS_EQUIPE_DT_ATUALIZACAO DEFAULT (SYSDATETIME()),

        CONSTRAINT PK_KZN_MEMBROS_EQUIPE           PRIMARY KEY CLUSTERED (ID_KAIZEN, ID_USUARIO),
        CONSTRAINT FK_KZN_MEMBROS_EQUIPE_KAIZEN    FOREIGN KEY (ID_KAIZEN)
            REFERENCES CI.KZN_PEDRAVISAOCONSOLIDADA (ID_KAIZEN),
        CONSTRAINT FK_KZN_MEMBROS_EQUIPE_USUARIO   FOREIGN KEY (ID_USUARIO)
            REFERENCES CI.KZN_MDM_HIERARQUIA (ID_USUARIO)
    );
END
GO

/* ------------------------------------------------------------------------------
   16. TABELA: CI.KZN_RESULTADO_KAIZEN
   (junção N:N Kaizen x Resultado padronizado — um Kaizen pode ter vários
   resultados de KZN_RESULTADOS; URL_ICONE aqui é override por ocorrência)
   ------------------------------------------------------------------------------ */
IF OBJECT_ID('CI.KZN_RESULTADO_KAIZEN', 'U') IS NULL
BEGIN
    CREATE TABLE CI.KZN_RESULTADO_KAIZEN
    (
        ID_KAIZEN       INT                             NOT NULL,
        ID_RESULTADO    INT                             NOT NULL,
        URL_ICONE       VARCHAR(200)                        NULL,
        DT_ATUALIZACAO  DATETIME2(3)                    NOT NULL
            CONSTRAINT DF_KZN_RESULTADO_KAIZEN_DT_ATUALIZACAO DEFAULT (SYSDATETIME()),

        CONSTRAINT PK_KZN_RESULTADO_KAIZEN          PRIMARY KEY CLUSTERED (ID_KAIZEN, ID_RESULTADO),
        CONSTRAINT FK_KZN_RESULTADO_KAIZEN_KAIZEN   FOREIGN KEY (ID_KAIZEN)
            REFERENCES CI.KZN_PEDRAVISAOCONSOLIDADA (ID_KAIZEN)
        -- ID_RESULTADO NÃO tem FK de banco: KZN_RESULTADOS agora tem PK composta
        -- (ID_RESULTADO, ID_IDIOMA); integridade fica sob responsabilidade da aplicação
    );
END
GO

/* ------------------------------------------------------------------------------
   17. TABELA: CI.KZN_KAIZEN_HIERARQUIA
   (fotografia da hierarquia organizacional do usuário no momento do registro
   do Kaizen — texto solto de propósito, não FK pra MDM, pra não mudar
   retroativamente se o org chart mudar depois)
   ------------------------------------------------------------------------------ */
IF OBJECT_ID('CI.KZN_KAIZEN_HIERARQUIA', 'U') IS NULL
BEGIN
    CREATE TABLE CI.KZN_KAIZEN_HIERARQUIA
    (
        ID_KAIZEN_HIERARQUIA   INT                             NOT NULL,
        ID_KAIZEN              INT                             NOT NULL,
        NM_HIERARQUIA_N1       VARCHAR(80)                         NULL,
        NM_HIERARQUIA_N2       VARCHAR(80)                         NULL,
        NM_HIERARQUIA_N3       VARCHAR(80)                         NULL,
        NM_HIERARQUIA_N4       VARCHAR(80)                         NULL,
        NM_HIERARQUIA_N5       VARCHAR(80)                         NULL,
        NM_HIERARQUIA_N6       VARCHAR(80)                         NULL,
        NM_HIERARQUIA_N7       VARCHAR(80)                         NULL,
        NM_HIERARQUIA_N8       VARCHAR(80)                         NULL,
        DT_ATUALIZACAO         DATETIME2(3)                    NOT NULL
            CONSTRAINT DF_KZN_KAIZEN_HIERARQUIA_DT_ATUALIZACAO DEFAULT (SYSDATETIME()),

        CONSTRAINT PK_KZN_KAIZEN_HIERARQUIA        PRIMARY KEY CLUSTERED (ID_KAIZEN_HIERARQUIA),
        CONSTRAINT FK_KZN_KAIZEN_HIERARQUIA_KAIZEN FOREIGN KEY (ID_KAIZEN)
            REFERENCES CI.KZN_PEDRAVISAOCONSOLIDADA (ID_KAIZEN)
    );

    CREATE NONCLUSTERED INDEX IX_KZN_KAIZEN_HIERARQUIA_KAIZEN
        ON CI.KZN_KAIZEN_HIERARQUIA (ID_KAIZEN);
END
GO

/* ------------------------------------------------------------------------------
   17.1 TABELA: CI.KZN_TIPO_USUARIO
   (cadastro simples de tipos/perfis de usuário do KZN; sem ID_IDIOMA — não
   foi pedido suporte multi-idioma aqui, diferente das demais tabelas de
   domínio; sem SG_ATIVO — não estava na lista de campos pedida)
   ------------------------------------------------------------------------------ */
IF OBJECT_ID('CI.KZN_TIPO_USUARIO', 'U') IS NULL
BEGIN
    CREATE TABLE CI.KZN_TIPO_USUARIO
    (
        ID_TIPO_USUARIO INT                             NOT NULL,
        NM_USUARIO      VARCHAR(30)                     NOT NULL,
        ID_USUARIO      INT                                 NULL,   -- usuário (MDM) responsável/administrador do cadastro
        DT_ATUALIZACAO  DATETIME2(3)                    NOT NULL
            CONSTRAINT DF_KZN_TIPO_USUARIO_DT_ATUALIZACAO DEFAULT (SYSDATETIME()),

        CONSTRAINT PK_KZN_TIPO_USUARIO         PRIMARY KEY CLUSTERED (ID_TIPO_USUARIO),
        CONSTRAINT FK_KZN_TIPO_USUARIO_USUARIO FOREIGN KEY (ID_USUARIO)
            REFERENCES CI.KZN_MDM_HIERARQUIA (ID_USUARIO),
        CONSTRAINT UQ_KZN_TIPO_USUARIO_NM      UNIQUE (NM_USUARIO)
    );
END
GO

-- documentação da estrutura via extended properties (idempotente)
IF NOT EXISTS (SELECT 1 FROM sys.extended_properties
               WHERE major_id = OBJECT_ID('CI.KZN_TIPO_USUARIO') AND minor_id = 0 AND name = 'MS_Description')
    EXEC sys.sp_addextendedproperty @name = N'MS_Description',
        @value = N'Cadastro de tipos/perfis de usuário do Kaizen.',
        @level0type = N'SCHEMA', @level0name = 'CI', @level1type = N'TABLE', @level1name = 'KZN_TIPO_USUARIO';

IF NOT EXISTS (SELECT 1 FROM sys.extended_properties
               WHERE major_id = OBJECT_ID('CI.KZN_TIPO_USUARIO')
                 AND minor_id = (SELECT column_id FROM sys.columns WHERE object_id = OBJECT_ID('CI.KZN_TIPO_USUARIO') AND name = 'ID_TIPO_USUARIO')
                 AND name = 'MS_Description')
    EXEC sys.sp_addextendedproperty @name = N'MS_Description',
        @value = N'Identificador do tipo de usuário (PK).',
        @level0type = N'SCHEMA', @level0name = 'CI', @level1type = N'TABLE', @level1name = 'KZN_TIPO_USUARIO',
        @level2type = N'COLUMN', @level2name = 'ID_TIPO_USUARIO';

IF NOT EXISTS (SELECT 1 FROM sys.extended_properties
               WHERE major_id = OBJECT_ID('CI.KZN_TIPO_USUARIO')
                 AND minor_id = (SELECT column_id FROM sys.columns WHERE object_id = OBJECT_ID('CI.KZN_TIPO_USUARIO') AND name = 'NM_USUARIO')
                 AND name = 'MS_Description')
    EXEC sys.sp_addextendedproperty @name = N'MS_Description',
        @value = N'Nome do tipo de usuário.',
        @level0type = N'SCHEMA', @level0name = 'CI', @level1type = N'TABLE', @level1name = 'KZN_TIPO_USUARIO',
        @level2type = N'COLUMN', @level2name = 'NM_USUARIO';

IF NOT EXISTS (SELECT 1 FROM sys.extended_properties
               WHERE major_id = OBJECT_ID('CI.KZN_TIPO_USUARIO')
                 AND minor_id = (SELECT column_id FROM sys.columns WHERE object_id = OBJECT_ID('CI.KZN_TIPO_USUARIO') AND name = 'ID_USUARIO')
                 AND name = 'MS_Description')
    EXEC sys.sp_addextendedproperty @name = N'MS_Description',
        @value = N'Usuário (MDM) responsável/administrador do cadastro.',
        @level0type = N'SCHEMA', @level0name = 'CI', @level1type = N'TABLE', @level1name = 'KZN_TIPO_USUARIO',
        @level2type = N'COLUMN', @level2name = 'ID_USUARIO';

IF NOT EXISTS (SELECT 1 FROM sys.extended_properties
               WHERE major_id = OBJECT_ID('CI.KZN_TIPO_USUARIO')
                 AND minor_id = (SELECT column_id FROM sys.columns WHERE object_id = OBJECT_ID('CI.KZN_TIPO_USUARIO') AND name = 'DT_ATUALIZACAO')
                 AND name = 'MS_Description')
    EXEC sys.sp_addextendedproperty @name = N'MS_Description',
        @value = N'Data da última atualização do registro.',
        @level0type = N'SCHEMA', @level0name = 'CI', @level1type = N'TABLE', @level1name = 'KZN_TIPO_USUARIO',
        @level2type = N'COLUMN', @level2name = 'DT_ATUALIZACAO';
GO

/* ------------------------------------------------------------------------------
   17.2 MIGRAÇÃO — CI.KZN_MDM_HIERARQUIA (idempotente)
   ATENÇÃO: recomenda-se backup antes de rodar em base com dado real — esta
   seção recria a tabela mais referenciada do schema (~15 FKs).

   Reconstrói a tabela pro formato final vigente, partindo de QUALQUER versão
   anterior já em produção: renomeia DS_EMAIL/SG_ESTADO se ainda estiverem
   com o nome antigo, insere os campos de perfil (se ainda não existirem) e
   ID_TIPO_USUARIO logo após CD_MATRICULA, e garante a PK composta
   (ID_USUARIO, CD_MATRICULA, ID_TIPO_USUARIO) — 3 colunas, pedido do time
   nesta rodada (antes era só ID_USUARIO + CD_MATRICULA). SQL Server não
   reordena coluna via ALTER TABLE — a única forma segura de mudar a ordem
   física sem perder dado é recriar a tabela e migrar os dados. Como quase
   todo o schema tem FK pra CI.KZN_MDM_HIERARQUIA (ID_USUARIO), e uma FK não
   pode referenciar parte de uma PK composta sem uma UNIQUE dedicada, a nova
   PK vem acompanhada de UQ_KZN_MDM_HIERARQUIA_USUARIO — sem isso, todas
   essas FKs deixariam de poder ser recriadas.

   ID_TIPO_USUARIO agora faz parte da PK, então precisa ser NOT NULL — mas
   não há valor-padrão razoável pra inventar pra quem ainda não tem tipo de
   usuário definido. Por isso, ANTES de tocar em qualquer dado, o passo (0)
   abaixo verifica se a coluna existe e se está 100% preenchida; se não
   estiver, a migração inteira é abortada (RAISERROR + RETURN) sem alterar
   nada, com instrução pro time popular ID_TIPO_USUARIO antes de reexecutar.

   O passo de cópia de dados usa sp_executesql (SQL dinâmico) porque os
   nomes/colunas de origem variam conforme o estado atual da tabela
   (CD_EMAIL pode ainda não existir em bases muito antigas; SG_ESTADO pode
   já ter sido renomeado pra NM_ESTADO em bases que rodaram uma versão
   anterior desta mesma migração; ID_TIPO_USUARIO pode não existir ainda —
   ver passo 0). Uma referência ESTÁTICA a uma coluna que não existe MAIS
   (ou ainda não existe) falha a compilação do BATCH inteiro mesmo dentro de
   um IF que nunca chega a executar — T-SQL só faz resolução de nomes
   adiada dentro de stored procedure/function/trigger, não em batch avulso
   como este script; por isso o SQL dinâmico é necessário aqui (as demais
   seções de migração deste script não precisam disso porque seus nomes de
   coluna de origem não mudam entre versões, só a ordem física).

   Só executa se a tabela já existir E (a PK ainda não tiver as 3 colunas
   OU faltar a coluna ID_TIPO_USUARIO) — senão, já está no formato final
   (bancos novos já nascem certos pelo CREATE TABLE da seção 2).
   ------------------------------------------------------------------------------ */
IF OBJECT_ID('CI.KZN_MDM_HIERARQUIA', 'U') IS NOT NULL
   AND (
        (SELECT COUNT(*) FROM sys.index_columns ic
         JOIN sys.indexes ix ON ix.object_id = ic.object_id AND ix.index_id = ic.index_id
         WHERE ix.object_id = OBJECT_ID('CI.KZN_MDM_HIERARQUIA') AND ix.is_primary_key = 1) < 3
        OR NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('CI.KZN_MDM_HIERARQUIA') AND name = 'ID_TIPO_USUARIO')
   )
BEGIN
    PRINT 'Migrando CI.KZN_MDM_HIERARQUIA pro formato final...';

    -- 0) pré-voo: ID_TIPO_USUARIO vai virar NOT NULL (parte da PK) — aborta
    -- sem alterar nada se a coluna não existir ainda ou se houver linha sem
    -- valor preenchido (não há valor-padrão de negócio pra inventar aqui).
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('CI.KZN_MDM_HIERARQUIA') AND name = 'ID_TIPO_USUARIO')
    BEGIN
        RAISERROR('Migração de CI.KZN_MDM_HIERARQUIA abortada: a nova PK composta exige ID_TIPO_USUARIO (NOT NULL), mas a coluna ainda não existe nesta base. Rode uma versão anterior deste script pra criar a coluna, preencha ID_TIPO_USUARIO pra todos os usuários e só então reexecute esta migração.', 16, 1);
        RETURN;
    END
    DECLARE @qtdTipoUsuarioNulo INT;
    EXEC sp_executesql N'SELECT @qtd = COUNT(*) FROM CI.KZN_MDM_HIERARQUIA WHERE ID_TIPO_USUARIO IS NULL', N'@qtd INT OUTPUT', @qtd = @qtdTipoUsuarioNulo OUTPUT;
    IF @qtdTipoUsuarioNulo > 0
    BEGIN
        RAISERROR('Migração de CI.KZN_MDM_HIERARQUIA abortada: há %d registro(s) com ID_TIPO_USUARIO nulo. A nova PK composta exige o campo preenchido (NOT NULL) pra todo usuário — popule ID_TIPO_USUARIO antes de reexecutar.', 16, 1, @qtdTipoUsuarioNulo);
        RETURN;
    END

    -- 1) remove todas as FKs de outras tabelas que apontam pra ID_USUARIO (recriadas ao final);
    -- também remove a FK diferida (seção 17.2b) se já tiver sido criada numa rodada anterior
    IF OBJECT_ID('CI.FK_KZN_IDIOMA_USUARIO', 'F') IS NOT NULL
        ALTER TABLE CI.KZN_IDIOMA DROP CONSTRAINT FK_KZN_IDIOMA_USUARIO;
    IF OBJECT_ID('CI.FK_KZN_APROVADOR_USUARIO', 'F') IS NOT NULL
        ALTER TABLE CI.KZN_APROVADOR DROP CONSTRAINT FK_KZN_APROVADOR_USUARIO;
    IF OBJECT_ID('CI.FK_KZN_ADMIN_USUARIO', 'F') IS NOT NULL
        ALTER TABLE CI.KZN_ADMIN DROP CONSTRAINT FK_KZN_ADMIN_USUARIO;
    IF OBJECT_ID('CI.FK_KZN_CATEGORIA_USUARIO', 'F') IS NOT NULL
        ALTER TABLE CI.KZN_CATEGORIA DROP CONSTRAINT FK_KZN_CATEGORIA_USUARIO;
    IF OBJECT_ID('CI.FK_KZN_REPLICACAO_USUARIO', 'F') IS NOT NULL
        ALTER TABLE CI.KZN_REPLICACAO DROP CONSTRAINT FK_KZN_REPLICACAO_USUARIO;
    IF OBJECT_ID('CI.FK_KZN_DESPERDICIO_USUARIO', 'F') IS NOT NULL
        ALTER TABLE CI.KZN_DESPERDICIO DROP CONSTRAINT FK_KZN_DESPERDICIO_USUARIO;
    IF OBJECT_ID('CI.FK_KZN_MOEDA_USUARIO', 'F') IS NOT NULL
        ALTER TABLE CI.KZN_MOEDA DROP CONSTRAINT FK_KZN_MOEDA_USUARIO;
    IF OBJECT_ID('CI.FK_KZN_TIPO_RESULTADO_USUARIO', 'F') IS NOT NULL
        ALTER TABLE CI.KZN_TIPO_RESULTADO DROP CONSTRAINT FK_KZN_TIPO_RESULTADO_USUARIO;
    IF OBJECT_ID('CI.FK_KZN_RESULTADOS_USUARIO', 'F') IS NOT NULL
        ALTER TABLE CI.KZN_RESULTADOS DROP CONSTRAINT FK_KZN_RESULTADOS_USUARIO;
    IF OBJECT_ID('CI.FK_KZN_MOTIVO_REPROVACAO_USUARIO', 'F') IS NOT NULL
        ALTER TABLE CI.KZN_MOTIVO_REPROVACAO DROP CONSTRAINT FK_KZN_MOTIVO_REPROVACAO_USUARIO;
    IF OBJECT_ID('CI.FK_KZN_PVC_USUARIO_CADASTRO', 'F') IS NOT NULL
        ALTER TABLE CI.KZN_PEDRAVISAOCONSOLIDADA DROP CONSTRAINT FK_KZN_PVC_USUARIO_CADASTRO;
    IF OBJECT_ID('CI.FK_KZN_PVC_USUARIO_LIDER', 'F') IS NOT NULL
        ALTER TABLE CI.KZN_PEDRAVISAOCONSOLIDADA DROP CONSTRAINT FK_KZN_PVC_USUARIO_LIDER;
    IF OBJECT_ID('CI.FK_KZN_PVC_USUARIO_ATUALIZACAO', 'F') IS NOT NULL
        ALTER TABLE CI.KZN_PEDRAVISAOCONSOLIDADA DROP CONSTRAINT FK_KZN_PVC_USUARIO_ATUALIZACAO;
    IF OBJECT_ID('CI.FK_KZN_LOG_PVC_USUARIO', 'F') IS NOT NULL
        ALTER TABLE CI.KZN_LOG_PEDRAVISAOCONSOLIDADA DROP CONSTRAINT FK_KZN_LOG_PVC_USUARIO;
    IF OBJECT_ID('CI.FK_KZN_MEMBROS_EQUIPE_USUARIO', 'F') IS NOT NULL
        ALTER TABLE CI.KZN_MEMBROS_EQUIPE DROP CONSTRAINT FK_KZN_MEMBROS_EQUIPE_USUARIO;
    IF OBJECT_ID('CI.FK_KZN_TIPO_USUARIO_USUARIO', 'F') IS NOT NULL
        ALTER TABLE CI.KZN_TIPO_USUARIO DROP CONSTRAINT FK_KZN_TIPO_USUARIO_USUARIO;
    IF OBJECT_ID('CI.FK_KZN_MDM_TIPO_USUARIO', 'F') IS NOT NULL
        ALTER TABLE CI.KZN_MDM_HIERARQUIA DROP CONSTRAINT FK_KZN_MDM_TIPO_USUARIO;

    -- 2) cria a tabela nova já com a ordem/estrutura final
    CREATE TABLE CI.KZN_MDM_HIERARQUIA_NEW
    (
        ID_USUARIO          INT                             NOT NULL,
        CD_MATRICULA        VARCHAR(30)                     NOT NULL,
        ID_TIPO_USUARIO     INT                             NOT NULL,
        NM_USUARIO          VARCHAR(30)                     NOT NULL,
        CD_EMAIL            VARCHAR(100)                    NOT NULL,
        NM_SITUACAO         VARCHAR(30)                         NULL,
        SG_ATIVO            VARCHAR(1)                      NOT NULL
            CONSTRAINT DF_KZN_MDM_HIERARQUIA_SG_ATIVO_NEW DEFAULT ('S'),
        NM_POSICAO          VARCHAR(30)                         NULL,
        NM_PAIS             VARCHAR(30)                         NULL,
        NM_ESTADO           VARCHAR(30)                         NULL,
        NM_CIDADE           VARCHAR(30)                         NULL,
        NM_SITE             VARCHAR(30)                         NULL,
        NM_HIERARQUIA_N1    VARCHAR(80)                         NULL,
        NM_HIERARQUIA_N2    VARCHAR(80)                         NULL,
        NM_HIERARQUIA_N3    VARCHAR(80)                         NULL,
        NM_HIERARQUIA_N4    VARCHAR(80)                         NULL,
        NM_HIERARQUIA_N5    VARCHAR(80)                         NULL,
        NM_HIERARQUIA_N6    VARCHAR(80)                         NULL,
        NM_HIERARQUIA_N7    VARCHAR(80)                         NULL,
        NM_HIERARQUIA_N8    VARCHAR(80)                         NULL,
        DT_ATUALIZACAO      DATETIME2(3)                    NOT NULL
            CONSTRAINT DF_KZN_MDM_HIERARQUIA_DT_ATUALIZACAO_NEW DEFAULT (SYSDATETIME())
    );

    -- 3) copia os dados via SQL dinâmico (nomes de origem variam conforme a
    -- versão anterior da tabela — ver explicação no cabeçalho da seção).
    -- ID_TIPO_USUARIO já foi validado 100% preenchido no passo 0 — copiado
    -- normalmente, igual às demais colunas com dado prévio.
    DECLARE @emailSrc   sysname       = CASE WHEN EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('CI.KZN_MDM_HIERARQUIA') AND name = 'CD_EMAIL') THEN 'CD_EMAIL' ELSE 'DS_EMAIL' END;
    DECLARE @hasProfile BIT           = CASE WHEN EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('CI.KZN_MDM_HIERARQUIA') AND name = 'NM_SITUACAO') THEN 1 ELSE 0 END;
    DECLARE @estadoSrc  sysname       = CASE
        WHEN EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('CI.KZN_MDM_HIERARQUIA') AND name = 'SG_ESTADO') THEN 'SG_ESTADO'
        WHEN EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('CI.KZN_MDM_HIERARQUIA') AND name = 'NM_ESTADO') THEN 'NM_ESTADO'
        ELSE NULL END;
    DECLARE @estadoExpr nvarchar(50)  = CASE WHEN @estadoSrc IS NULL THEN N'NULL' ELSE QUOTENAME(@estadoSrc) END;
    DECLARE @sql nvarchar(max) = N'
        INSERT INTO CI.KZN_MDM_HIERARQUIA_NEW
        (ID_USUARIO, CD_MATRICULA, ID_TIPO_USUARIO, NM_USUARIO, CD_EMAIL, '
            + CASE WHEN @hasProfile = 1 THEN N'NM_SITUACAO, SG_ATIVO, NM_POSICAO, NM_PAIS, NM_ESTADO, NM_CIDADE, NM_SITE, ' ELSE N'SG_ATIVO, ' END
            + N'NM_HIERARQUIA_N1, NM_HIERARQUIA_N2, NM_HIERARQUIA_N3, NM_HIERARQUIA_N4, NM_HIERARQUIA_N5, NM_HIERARQUIA_N6, NM_HIERARQUIA_N7, NM_HIERARQUIA_N8, DT_ATUALIZACAO)
        SELECT ID_USUARIO, CD_MATRICULA, ID_TIPO_USUARIO, NM_USUARIO, ' + QUOTENAME(@emailSrc) + N', '
            + CASE WHEN @hasProfile = 1 THEN N'NM_SITUACAO, SG_ATIVO, NM_POSICAO, NM_PAIS, ' + @estadoExpr + N', NM_CIDADE, NM_SITE, ' ELSE N'''S'', ' END
            + N'NM_HIERARQUIA_N1, NM_HIERARQUIA_N2, NM_HIERARQUIA_N3, NM_HIERARQUIA_N4, NM_HIERARQUIA_N5, NM_HIERARQUIA_N6, NM_HIERARQUIA_N7, NM_HIERARQUIA_N8, DT_ATUALIZACAO
        FROM CI.KZN_MDM_HIERARQUIA;';
    EXEC sp_executesql @sql;

    -- 4) remove a tabela antiga (leva junto PK/UNIQUE/índice/trigger dela) e promove a nova
    DROP TABLE CI.KZN_MDM_HIERARQUIA;
    EXEC sp_rename 'CI.KZN_MDM_HIERARQUIA_NEW', 'KZN_MDM_HIERARQUIA';
    EXEC sp_rename 'CI.DF_KZN_MDM_HIERARQUIA_SG_ATIVO_NEW', 'DF_KZN_MDM_HIERARQUIA_SG_ATIVO', 'OBJECT';
    EXEC sp_rename 'CI.DF_KZN_MDM_HIERARQUIA_DT_ATUALIZACAO_NEW', 'DF_KZN_MDM_HIERARQUIA_DT_ATUALIZACAO', 'OBJECT';

    -- 5) recria PK composta, UNIQUEs e índice
    ALTER TABLE CI.KZN_MDM_HIERARQUIA ADD CONSTRAINT PK_KZN_MDM_HIERARQUIA PRIMARY KEY CLUSTERED (ID_USUARIO, CD_MATRICULA, ID_TIPO_USUARIO);
    ALTER TABLE CI.KZN_MDM_HIERARQUIA ADD CONSTRAINT UQ_KZN_MDM_HIERARQUIA_USUARIO UNIQUE (ID_USUARIO);
    ALTER TABLE CI.KZN_MDM_HIERARQUIA ADD CONSTRAINT UQ_KZN_MDM_HIERARQUIA_MATR UNIQUE (CD_MATRICULA);

    CREATE NONCLUSTERED INDEX IX_KZN_MDM_HIERARQUIA_EMAIL ON CI.KZN_MDM_HIERARQUIA (CD_EMAIL);

    -- 6) recria as FKs removidas no passo 1 (agora válidas contra UQ_KZN_MDM_HIERARQUIA_USUARIO);
    -- FK_KZN_MDM_TIPO_USUARIO NÃO é recriada aqui — só depois que
    -- CI.KZN_TIPO_USUARIO também estiver garantidamente no formato final
    -- (seção 17.2b, que roda logo em seguida)
    IF OBJECT_ID('CI.KZN_IDIOMA', 'U') IS NOT NULL
        ALTER TABLE CI.KZN_IDIOMA ADD CONSTRAINT FK_KZN_IDIOMA_USUARIO FOREIGN KEY (ID_USUARIO) REFERENCES CI.KZN_MDM_HIERARQUIA (ID_USUARIO);
    IF OBJECT_ID('CI.KZN_APROVADOR', 'U') IS NOT NULL
        ALTER TABLE CI.KZN_APROVADOR ADD CONSTRAINT FK_KZN_APROVADOR_USUARIO FOREIGN KEY (ID_USUARIO) REFERENCES CI.KZN_MDM_HIERARQUIA (ID_USUARIO);
    IF OBJECT_ID('CI.KZN_ADMIN', 'U') IS NOT NULL
        ALTER TABLE CI.KZN_ADMIN ADD CONSTRAINT FK_KZN_ADMIN_USUARIO FOREIGN KEY (ID_USUARIO) REFERENCES CI.KZN_MDM_HIERARQUIA (ID_USUARIO);
    IF OBJECT_ID('CI.KZN_CATEGORIA', 'U') IS NOT NULL
        ALTER TABLE CI.KZN_CATEGORIA ADD CONSTRAINT FK_KZN_CATEGORIA_USUARIO FOREIGN KEY (ID_USUARIO) REFERENCES CI.KZN_MDM_HIERARQUIA (ID_USUARIO);
    IF OBJECT_ID('CI.KZN_REPLICACAO', 'U') IS NOT NULL
        ALTER TABLE CI.KZN_REPLICACAO ADD CONSTRAINT FK_KZN_REPLICACAO_USUARIO FOREIGN KEY (ID_USUARIO) REFERENCES CI.KZN_MDM_HIERARQUIA (ID_USUARIO);
    IF OBJECT_ID('CI.KZN_DESPERDICIO', 'U') IS NOT NULL
        ALTER TABLE CI.KZN_DESPERDICIO ADD CONSTRAINT FK_KZN_DESPERDICIO_USUARIO FOREIGN KEY (ID_USUARIO) REFERENCES CI.KZN_MDM_HIERARQUIA (ID_USUARIO);
    IF OBJECT_ID('CI.KZN_MOEDA', 'U') IS NOT NULL
        ALTER TABLE CI.KZN_MOEDA ADD CONSTRAINT FK_KZN_MOEDA_USUARIO FOREIGN KEY (ID_USUARIO) REFERENCES CI.KZN_MDM_HIERARQUIA (ID_USUARIO);
    IF OBJECT_ID('CI.KZN_TIPO_RESULTADO', 'U') IS NOT NULL
        ALTER TABLE CI.KZN_TIPO_RESULTADO ADD CONSTRAINT FK_KZN_TIPO_RESULTADO_USUARIO FOREIGN KEY (ID_USUARIO) REFERENCES CI.KZN_MDM_HIERARQUIA (ID_USUARIO);
    IF OBJECT_ID('CI.KZN_RESULTADOS', 'U') IS NOT NULL
        ALTER TABLE CI.KZN_RESULTADOS ADD CONSTRAINT FK_KZN_RESULTADOS_USUARIO FOREIGN KEY (ID_USUARIO) REFERENCES CI.KZN_MDM_HIERARQUIA (ID_USUARIO);
    IF OBJECT_ID('CI.KZN_MOTIVO_REPROVACAO', 'U') IS NOT NULL
        ALTER TABLE CI.KZN_MOTIVO_REPROVACAO ADD CONSTRAINT FK_KZN_MOTIVO_REPROVACAO_USUARIO FOREIGN KEY (ID_USUARIO) REFERENCES CI.KZN_MDM_HIERARQUIA (ID_USUARIO);
    IF OBJECT_ID('CI.KZN_PEDRAVISAOCONSOLIDADA', 'U') IS NOT NULL
    BEGIN
        ALTER TABLE CI.KZN_PEDRAVISAOCONSOLIDADA ADD CONSTRAINT FK_KZN_PVC_USUARIO_CADASTRO FOREIGN KEY (ID_USUARIO_CADASTRO) REFERENCES CI.KZN_MDM_HIERARQUIA (ID_USUARIO);
        ALTER TABLE CI.KZN_PEDRAVISAOCONSOLIDADA ADD CONSTRAINT FK_KZN_PVC_USUARIO_LIDER FOREIGN KEY (ID_USUARIO_LIDER) REFERENCES CI.KZN_MDM_HIERARQUIA (ID_USUARIO);
        ALTER TABLE CI.KZN_PEDRAVISAOCONSOLIDADA ADD CONSTRAINT FK_KZN_PVC_USUARIO_ATUALIZACAO FOREIGN KEY (ID_USUARIO_ATUALIZACAO) REFERENCES CI.KZN_MDM_HIERARQUIA (ID_USUARIO);
    END
    IF OBJECT_ID('CI.KZN_LOG_PEDRAVISAOCONSOLIDADA', 'U') IS NOT NULL
        ALTER TABLE CI.KZN_LOG_PEDRAVISAOCONSOLIDADA ADD CONSTRAINT FK_KZN_LOG_PVC_USUARIO FOREIGN KEY (ID_USUARIO_OPERACAO) REFERENCES CI.KZN_MDM_HIERARQUIA (ID_USUARIO);
    IF OBJECT_ID('CI.KZN_MEMBROS_EQUIPE', 'U') IS NOT NULL
        ALTER TABLE CI.KZN_MEMBROS_EQUIPE ADD CONSTRAINT FK_KZN_MEMBROS_EQUIPE_USUARIO FOREIGN KEY (ID_USUARIO) REFERENCES CI.KZN_MDM_HIERARQUIA (ID_USUARIO);
    IF OBJECT_ID('CI.KZN_TIPO_USUARIO', 'U') IS NOT NULL
        ALTER TABLE CI.KZN_TIPO_USUARIO ADD CONSTRAINT FK_KZN_TIPO_USUARIO_USUARIO FOREIGN KEY (ID_USUARIO) REFERENCES CI.KZN_MDM_HIERARQUIA (ID_USUARIO);

    PRINT 'Migração de CI.KZN_MDM_HIERARQUIA concluída.';
END
GO

/* ------------------------------------------------------------------------------
   17.2b FK DIFERIDA — CI.KZN_MDM_HIERARQUIA.ID_TIPO_USUARIO → CI.KZN_TIPO_USUARIO
   Referência circular entre as duas tabelas (KZN_TIPO_USUARIO também tem FK
   pra KZN_MDM_HIERARQUIA via ID_USUARIO): nenhuma das duas pode ter sua FK
   cruzada declarada no próprio CREATE TABLE, porque a tabela referenciada
   ainda não existiria nesse ponto do script. Por isso essa FK é adicionada
   à parte, depois que as duas tabelas já existem no formato final (idempotente:
   só adiciona se ainda não existir).
   ------------------------------------------------------------------------------ */
IF OBJECT_ID('CI.KZN_MDM_HIERARQUIA', 'U') IS NOT NULL
   AND OBJECT_ID('CI.KZN_TIPO_USUARIO', 'U') IS NOT NULL
   AND OBJECT_ID('CI.FK_KZN_MDM_TIPO_USUARIO', 'F') IS NULL
    ALTER TABLE CI.KZN_MDM_HIERARQUIA ADD CONSTRAINT FK_KZN_MDM_TIPO_USUARIO
        FOREIGN KEY (ID_TIPO_USUARIO) REFERENCES CI.KZN_TIPO_USUARIO (ID_TIPO_USUARIO);
GO

/* ------------------------------------------------------------------------------
   17.3 MIGRAÇÃO — CI.KZN_PEDRAVISAOCONSOLIDADA (idempotente)
   Reorganiza a ordem física das colunas pra DT_CRIACAO ficar imediatamente
   antes de DT_CONCLUSAO. SQL Server não reordena coluna via ALTER TABLE — a
   forma segura de mudar a ordem física sem perder dado é recriar a tabela e
   migrar os dados. Só executa se a tabela já existir E a ordem atual ainda
   não estiver correta (senão, já nasceu certa pelo CREATE TABLE da seção 13,
   ou já rodou nesta base antes).
   ------------------------------------------------------------------------------ */
IF OBJECT_ID('CI.KZN_PEDRAVISAOCONSOLIDADA', 'U') IS NOT NULL
   AND EXISTS (
        SELECT 1
        FROM sys.columns c1
        JOIN sys.columns c2 ON c1.object_id = c2.object_id
        WHERE c1.object_id = OBJECT_ID('CI.KZN_PEDRAVISAOCONSOLIDADA')
          AND c1.name = 'DT_CRIACAO' AND c2.name = 'DT_CONCLUSAO'
          AND c1.column_id <> c2.column_id - 1
   )
BEGIN
    PRINT 'Migrando CI.KZN_PEDRAVISAOCONSOLIDADA (DT_CRIACAO antes de DT_CONCLUSAO)...';

    -- 1) remove FKs de tabelas filhas que apontam pra ID_KAIZEN (recriadas ao final)
    IF OBJECT_ID('CI.FK_KZN_LOG_PVC_KAIZEN', 'F') IS NOT NULL
        ALTER TABLE CI.KZN_LOG_PEDRAVISAOCONSOLIDADA DROP CONSTRAINT FK_KZN_LOG_PVC_KAIZEN;
    IF OBJECT_ID('CI.FK_KZN_MEMBROS_EQUIPE_KAIZEN', 'F') IS NOT NULL
        ALTER TABLE CI.KZN_MEMBROS_EQUIPE DROP CONSTRAINT FK_KZN_MEMBROS_EQUIPE_KAIZEN;
    IF OBJECT_ID('CI.FK_KZN_RESULTADO_KAIZEN_KAIZEN', 'F') IS NOT NULL
        ALTER TABLE CI.KZN_RESULTADO_KAIZEN DROP CONSTRAINT FK_KZN_RESULTADO_KAIZEN_KAIZEN;
    IF OBJECT_ID('CI.FK_KZN_KAIZEN_HIERARQUIA_KAIZEN', 'F') IS NOT NULL
        ALTER TABLE CI.KZN_KAIZEN_HIERARQUIA DROP CONSTRAINT FK_KZN_KAIZEN_HIERARQUIA_KAIZEN;

    -- 2) cria a tabela nova já na ordem final
    CREATE TABLE CI.KZN_PEDRAVISAOCONSOLIDADA_NEW
    (
        ID_KAIZEN                  INT                             NOT NULL,
        ID_USUARIO_CADASTRO        INT                             NOT NULL,
        ID_USUARIO_LIDER           INT                             NOT NULL,
        NM_KAIZEN                  VARCHAR(30)                     NOT NULL,
        ID_CATEGORIA               INT                             NOT NULL,
        ID_REPLICACAO              INT                                 NULL,
        DS_PROBLEMA                VARCHAR(100)                        NULL,
        DS_OBJETIVO                VARCHAR(100)                        NULL,
        SG_STATUS                  VARCHAR(30)                     NOT NULL
            CONSTRAINT DF_KZN_PVC_STATUS_NEW DEFAULT ('ABERTO'),
        ID_APROVADOR               INT                                 NULL,
        URL_IMG_ANTES               VARCHAR(200)                       NULL,
        DS_ESTADO_ANTES            VARCHAR(100)                        NULL,
        URL_IMG_DEPOIS              VARCHAR(200)                       NULL,
        DS_ESTADO_DEPOIS           VARCHAR(100)                        NULL,
        URL_REFERENCIA             VARCHAR(200)                       NULL,
        ID_DESPERDICIO             INT                                 NULL,
        DS_LICOES_APRENDIDAS       VARCHAR(100)                        NULL,
        VL_RESULTADO_FINANCEIRO    DECIMAL(18,2)                      NULL,
        ID_MOEDA                   INT                                 NULL,
        DS_RESULTADO_ESPERADO      VARCHAR(100)                        NULL,
        DT_CRIACAO                 DATETIME2(3)                    NOT NULL
            CONSTRAINT DF_KZN_PVC_DT_CRIACAO_NEW DEFAULT (SYSDATETIME()),
        DT_CONCLUSAO               DATE                                NULL,
        ID_MOTIVO                  INT                                 NULL,
        DT_ATUALIZACAO             DATETIME2(3)                    NOT NULL
            CONSTRAINT DF_KZN_PVC_DT_ATUALIZACAO_NEW DEFAULT (SYSDATETIME()),
        ID_USUARIO_ATUALIZACAO     INT                             NOT NULL
    );

    -- 3) copia os dados na ordem/colunas novas
    INSERT INTO CI.KZN_PEDRAVISAOCONSOLIDADA_NEW
    (ID_KAIZEN, ID_USUARIO_CADASTRO, ID_USUARIO_LIDER, NM_KAIZEN, ID_CATEGORIA, ID_REPLICACAO,
     DS_PROBLEMA, DS_OBJETIVO, SG_STATUS, ID_APROVADOR, URL_IMG_ANTES, DS_ESTADO_ANTES,
     URL_IMG_DEPOIS, DS_ESTADO_DEPOIS, URL_REFERENCIA, ID_DESPERDICIO, DS_LICOES_APRENDIDAS,
     VL_RESULTADO_FINANCEIRO, ID_MOEDA, DS_RESULTADO_ESPERADO, DT_CRIACAO, DT_CONCLUSAO,
     ID_MOTIVO, DT_ATUALIZACAO, ID_USUARIO_ATUALIZACAO)
    SELECT ID_KAIZEN, ID_USUARIO_CADASTRO, ID_USUARIO_LIDER, NM_KAIZEN, ID_CATEGORIA, ID_REPLICACAO,
           DS_PROBLEMA, DS_OBJETIVO, SG_STATUS, ID_APROVADOR, URL_IMG_ANTES, DS_ESTADO_ANTES,
           URL_IMG_DEPOIS, DS_ESTADO_DEPOIS, URL_REFERENCIA, ID_DESPERDICIO, DS_LICOES_APRENDIDAS,
           VL_RESULTADO_FINANCEIRO, ID_MOEDA, DS_RESULTADO_ESPERADO, DT_CRIACAO, DT_CONCLUSAO,
           ID_MOTIVO, DT_ATUALIZACAO, ID_USUARIO_ATUALIZACAO
    FROM CI.KZN_PEDRAVISAOCONSOLIDADA;

    -- 4) remove a antiga e promove a nova
    DROP TABLE CI.KZN_PEDRAVISAOCONSOLIDADA;
    EXEC sp_rename 'CI.KZN_PEDRAVISAOCONSOLIDADA_NEW', 'KZN_PEDRAVISAOCONSOLIDADA';
    EXEC sp_rename 'CI.DF_KZN_PVC_STATUS_NEW', 'DF_KZN_PVC_STATUS', 'OBJECT';
    EXEC sp_rename 'CI.DF_KZN_PVC_DT_CRIACAO_NEW', 'DF_KZN_PVC_DT_CRIACAO', 'OBJECT';
    EXEC sp_rename 'CI.DF_KZN_PVC_DT_ATUALIZACAO_NEW', 'DF_KZN_PVC_DT_ATUALIZACAO', 'OBJECT';

    -- 5) recria PK, FKs próprias, CHECK e índices
    ALTER TABLE CI.KZN_PEDRAVISAOCONSOLIDADA ADD CONSTRAINT PK_KZN_PVC PRIMARY KEY CLUSTERED (ID_KAIZEN);
    ALTER TABLE CI.KZN_PEDRAVISAOCONSOLIDADA ADD CONSTRAINT FK_KZN_PVC_USUARIO_CADASTRO FOREIGN KEY (ID_USUARIO_CADASTRO) REFERENCES CI.KZN_MDM_HIERARQUIA (ID_USUARIO);
    ALTER TABLE CI.KZN_PEDRAVISAOCONSOLIDADA ADD CONSTRAINT FK_KZN_PVC_USUARIO_LIDER FOREIGN KEY (ID_USUARIO_LIDER) REFERENCES CI.KZN_MDM_HIERARQUIA (ID_USUARIO);
    ALTER TABLE CI.KZN_PEDRAVISAOCONSOLIDADA ADD CONSTRAINT FK_KZN_PVC_USUARIO_ATUALIZACAO FOREIGN KEY (ID_USUARIO_ATUALIZACAO) REFERENCES CI.KZN_MDM_HIERARQUIA (ID_USUARIO);
    ALTER TABLE CI.KZN_PEDRAVISAOCONSOLIDADA ADD CONSTRAINT FK_KZN_PVC_APROVADOR FOREIGN KEY (ID_APROVADOR) REFERENCES CI.KZN_APROVADOR (ID_APROVADOR);
    ALTER TABLE CI.KZN_PEDRAVISAOCONSOLIDADA ADD CONSTRAINT FK_KZN_PVC_MOEDA FOREIGN KEY (ID_MOEDA) REFERENCES CI.KZN_MOEDA (ID_MOEDA);
    ALTER TABLE CI.KZN_PEDRAVISAOCONSOLIDADA ADD CONSTRAINT CK_KZN_PVC_STATUS CHECK (SG_STATUS IN ('ABERTO','EM_APROVACAO','APROVADO','REPROVADO','CONCLUIDO'));

    CREATE NONCLUSTERED INDEX IX_KZN_PVC_STATUS        ON CI.KZN_PEDRAVISAOCONSOLIDADA (SG_STATUS);
    CREATE NONCLUSTERED INDEX IX_KZN_PVC_CATEGORIA     ON CI.KZN_PEDRAVISAOCONSOLIDADA (ID_CATEGORIA);
    CREATE NONCLUSTERED INDEX IX_KZN_PVC_USUARIO_LIDER ON CI.KZN_PEDRAVISAOCONSOLIDADA (ID_USUARIO_LIDER);

    -- 6) recria as FKs das tabelas filhas removidas no passo 1
    ALTER TABLE CI.KZN_LOG_PEDRAVISAOCONSOLIDADA ADD CONSTRAINT FK_KZN_LOG_PVC_KAIZEN FOREIGN KEY (ID_KAIZEN) REFERENCES CI.KZN_PEDRAVISAOCONSOLIDADA (ID_KAIZEN);
    ALTER TABLE CI.KZN_MEMBROS_EQUIPE ADD CONSTRAINT FK_KZN_MEMBROS_EQUIPE_KAIZEN FOREIGN KEY (ID_KAIZEN) REFERENCES CI.KZN_PEDRAVISAOCONSOLIDADA (ID_KAIZEN);
    ALTER TABLE CI.KZN_RESULTADO_KAIZEN ADD CONSTRAINT FK_KZN_RESULTADO_KAIZEN_KAIZEN FOREIGN KEY (ID_KAIZEN) REFERENCES CI.KZN_PEDRAVISAOCONSOLIDADA (ID_KAIZEN);
    ALTER TABLE CI.KZN_KAIZEN_HIERARQUIA ADD CONSTRAINT FK_KZN_KAIZEN_HIERARQUIA_KAIZEN FOREIGN KEY (ID_KAIZEN) REFERENCES CI.KZN_PEDRAVISAOCONSOLIDADA (ID_KAIZEN);

    PRINT 'Migração de CI.KZN_PEDRAVISAOCONSOLIDADA concluída.';
END
GO

/* ------------------------------------------------------------------------------
   17.4 MIGRAÇÃO — CI.KZN_APROVADOR / CI.KZN_ADMIN (idempotente)
   Reconstrói cada tabela pra (pedido do time, nesta rodada): criar
   CD_MATRICULA como 2ª coluna (logo após ID_APROVADOR / ID_ADMIN),
   reposicionar ID_USUARIO pra penúltima coluna (antes de DT_ATUALIZACAO) e
   trocar a PK composta de (ID_APROVADOR/ID_ADMIN, ID_USUARIO) pra
   (ID_APROVADOR/ID_ADMIN, CD_MATRICULA) — ID_USUARIO deixa de ser chave e
   passa a ser só FK (auditoria de quem cadastrou). SQL Server não reordena
   coluna via ALTER TABLE — a forma segura de mudar a ordem física sem
   perder dado é recriar a tabela e migrar os dados (mesma técnica das
   seções 17.2/17.3). CD_MATRICULA é preenchida a partir de
   CI.KZN_MDM_HIERARQUIA, casando pelo ID_USUARIO já existente em cada linha
   (UQ_KZN_MDM_HIERARQUIA_USUARIO garante 1 CD_MATRICULA por ID_USUARIO) —
   ASSUNÇÃO: CD_MATRICULA aqui é INT (pedido explícito do time), enquanto em
   KZN_MDM_HIERARQUIA é VARCHAR(30); o TRY_CAST abaixo cobre a migração, mas
   se algum ambiente tiver matrícula não-numérica a conversão falha e a
   checagem de pré-voo abaixo aborta o script antes de alterar qualquer
   dado. Como FK_KZN_PVC_APROVADOR (em KZN_PEDRAVISAOCONSOLIDADA) referencia
   só ID_APROVADOR, o rebuild de KZN_APROVADOR também derruba e recria essa
   FK; UQ_KZN_APROVADOR_ID (UNIQUE em ID_APROVADOR) é o que permite essa FK
   continuar válida mesmo com a PK composta. Nenhuma FK externa referencia
   KZN_ADMIN hoje. Só executa por tabela se a coluna CD_MATRICULA ainda não
   existir — cobre quem nunca migrou; bancos novos já nascem certos pelo
   CREATE TABLE das seções 4/5, e quem já rodou esta migração uma vez não
   dispara de novo.
   ------------------------------------------------------------------------------ */
IF OBJECT_ID('CI.KZN_APROVADOR', 'U') IS NOT NULL
   AND NOT EXISTS (
        SELECT 1 FROM sys.columns
        WHERE object_id = OBJECT_ID('CI.KZN_APROVADOR') AND name = 'CD_MATRICULA'
   )
BEGIN
    PRINT 'Migrando CI.KZN_APROVADOR (CD_MATRICULA + PK composta + reordenação)...';

    IF EXISTS (
        SELECT 1
        FROM CI.KZN_APROVADOR a
        LEFT JOIN CI.KZN_MDM_HIERARQUIA m ON m.ID_USUARIO = a.ID_USUARIO
        WHERE m.ID_USUARIO IS NULL OR TRY_CAST(m.CD_MATRICULA AS INT) IS NULL
    )
    BEGIN
        RAISERROR('Migração de CI.KZN_APROVADOR abortada: há registro(s) cujo ID_USUARIO não tem CD_MATRICULA numérica correspondente em CI.KZN_MDM_HIERARQUIA. Corrija os dados de origem (ou o script, se a matrícula não for sempre numérica) antes de reexecutar.', 16, 1);
        RETURN;
    END

    IF OBJECT_ID('CI.FK_KZN_PVC_APROVADOR', 'F') IS NOT NULL
        ALTER TABLE CI.KZN_PEDRAVISAOCONSOLIDADA DROP CONSTRAINT FK_KZN_PVC_APROVADOR;

    CREATE TABLE CI.KZN_APROVADOR_NEW
    (
        ID_APROVADOR    INT                             NOT NULL,
        CD_MATRICULA    INT                             NOT NULL,
        SG_ATIVO        VARCHAR(1)                      NOT NULL
            CONSTRAINT DF_KZN_APROVADOR_SG_ATIVO_NEW DEFAULT ('S'),
        ID_USUARIO      INT                             NOT NULL,
        DT_ATUALIZACAO  DATETIME2(3)                    NOT NULL
            CONSTRAINT DF_KZN_APROVADOR_DT_ATUALIZACAO_NEW DEFAULT (SYSDATETIME())
    );

    INSERT INTO CI.KZN_APROVADOR_NEW (ID_APROVADOR, CD_MATRICULA, SG_ATIVO, ID_USUARIO, DT_ATUALIZACAO)
    SELECT a.ID_APROVADOR, TRY_CAST(m.CD_MATRICULA AS INT), a.SG_ATIVO, a.ID_USUARIO, a.DT_ATUALIZACAO
    FROM CI.KZN_APROVADOR a
    JOIN CI.KZN_MDM_HIERARQUIA m ON m.ID_USUARIO = a.ID_USUARIO;

    DROP TABLE CI.KZN_APROVADOR;
    EXEC sp_rename 'CI.KZN_APROVADOR_NEW', 'KZN_APROVADOR';
    EXEC sp_rename 'CI.DF_KZN_APROVADOR_SG_ATIVO_NEW', 'DF_KZN_APROVADOR_SG_ATIVO', 'OBJECT';
    EXEC sp_rename 'CI.DF_KZN_APROVADOR_DT_ATUALIZACAO_NEW', 'DF_KZN_APROVADOR_DT_ATUALIZACAO', 'OBJECT';

    ALTER TABLE CI.KZN_APROVADOR ADD CONSTRAINT PK_KZN_APROVADOR PRIMARY KEY CLUSTERED (ID_APROVADOR, CD_MATRICULA);
    ALTER TABLE CI.KZN_APROVADOR ADD CONSTRAINT UQ_KZN_APROVADOR_ID UNIQUE (ID_APROVADOR);
    ALTER TABLE CI.KZN_APROVADOR ADD CONSTRAINT FK_KZN_APROVADOR_USUARIO FOREIGN KEY (ID_USUARIO) REFERENCES CI.KZN_MDM_HIERARQUIA (ID_USUARIO);

    IF OBJECT_ID('CI.KZN_PEDRAVISAOCONSOLIDADA', 'U') IS NOT NULL
        ALTER TABLE CI.KZN_PEDRAVISAOCONSOLIDADA ADD CONSTRAINT FK_KZN_PVC_APROVADOR FOREIGN KEY (ID_APROVADOR) REFERENCES CI.KZN_APROVADOR (ID_APROVADOR);

    PRINT 'Migração de CI.KZN_APROVADOR concluída.';
END
GO

IF OBJECT_ID('CI.KZN_ADMIN', 'U') IS NOT NULL
   AND NOT EXISTS (
        SELECT 1 FROM sys.columns
        WHERE object_id = OBJECT_ID('CI.KZN_ADMIN') AND name = 'CD_MATRICULA'
   )
BEGIN
    PRINT 'Migrando CI.KZN_ADMIN (CD_MATRICULA + PK composta + reordenação)...';

    IF EXISTS (
        SELECT 1
        FROM CI.KZN_ADMIN d
        LEFT JOIN CI.KZN_MDM_HIERARQUIA m ON m.ID_USUARIO = d.ID_USUARIO
        WHERE m.ID_USUARIO IS NULL OR TRY_CAST(m.CD_MATRICULA AS INT) IS NULL
    )
    BEGIN
        RAISERROR('Migração de CI.KZN_ADMIN abortada: há registro(s) cujo ID_USUARIO não tem CD_MATRICULA numérica correspondente em CI.KZN_MDM_HIERARQUIA. Corrija os dados de origem (ou o script, se a matrícula não for sempre numérica) antes de reexecutar.', 16, 1);
        RETURN;
    END

    CREATE TABLE CI.KZN_ADMIN_NEW
    (
        ID_ADMIN        INT                             NOT NULL,
        CD_MATRICULA    INT                             NOT NULL,
        SG_ATIVO        VARCHAR(1)                      NOT NULL
            CONSTRAINT DF_KZN_ADMIN_SG_ATIVO_NEW DEFAULT ('S'),
        ID_USUARIO      INT                             NOT NULL,
        DT_ATUALIZACAO  DATETIME2(3)                    NOT NULL
            CONSTRAINT DF_KZN_ADMIN_DT_ATUALIZACAO_NEW DEFAULT (SYSDATETIME())
    );

    INSERT INTO CI.KZN_ADMIN_NEW (ID_ADMIN, CD_MATRICULA, SG_ATIVO, ID_USUARIO, DT_ATUALIZACAO)
    SELECT d.ID_ADMIN, TRY_CAST(m.CD_MATRICULA AS INT), d.SG_ATIVO, d.ID_USUARIO, d.DT_ATUALIZACAO
    FROM CI.KZN_ADMIN d
    JOIN CI.KZN_MDM_HIERARQUIA m ON m.ID_USUARIO = d.ID_USUARIO;

    DROP TABLE CI.KZN_ADMIN;
    EXEC sp_rename 'CI.KZN_ADMIN_NEW', 'KZN_ADMIN';
    EXEC sp_rename 'CI.DF_KZN_ADMIN_SG_ATIVO_NEW', 'DF_KZN_ADMIN_SG_ATIVO', 'OBJECT';
    EXEC sp_rename 'CI.DF_KZN_ADMIN_DT_ATUALIZACAO_NEW', 'DF_KZN_ADMIN_DT_ATUALIZACAO', 'OBJECT';

    ALTER TABLE CI.KZN_ADMIN ADD CONSTRAINT PK_KZN_ADMIN PRIMARY KEY CLUSTERED (ID_ADMIN, CD_MATRICULA);
    ALTER TABLE CI.KZN_ADMIN ADD CONSTRAINT FK_KZN_ADMIN_USUARIO FOREIGN KEY (ID_USUARIO) REFERENCES CI.KZN_MDM_HIERARQUIA (ID_USUARIO);

    PRINT 'Migração de CI.KZN_ADMIN concluída.';
END
GO

/* ==============================================================================
   18. TRIGGERS — atualização automática de DT_ATUALIZACAO no UPDATE
   (tabelas mestre / auxiliares com PK simples ou composta)
   ============================================================================== */
CREATE OR ALTER TRIGGER CI.TR_KZN_MDM_HIERARQUIA_UPD ON CI.KZN_MDM_HIERARQUIA AFTER UPDATE AS
BEGIN
    SET NOCOUNT ON;
    IF NOT UPDATE(DT_ATUALIZACAO)
        UPDATE T SET DT_ATUALIZACAO = SYSDATETIME()
        FROM CI.KZN_MDM_HIERARQUIA T JOIN inserted i ON i.ID_USUARIO = T.ID_USUARIO;
END
GO

CREATE OR ALTER TRIGGER CI.TR_KZN_IDIOMA_UPD ON CI.KZN_IDIOMA AFTER UPDATE AS
BEGIN
    SET NOCOUNT ON;
    IF NOT UPDATE(DT_ATUALIZACAO)
        UPDATE T SET DT_ATUALIZACAO = SYSDATETIME()
        FROM CI.KZN_IDIOMA T JOIN inserted i ON i.ID_IDIOMA = T.ID_IDIOMA;
END
GO

CREATE OR ALTER TRIGGER CI.TR_KZN_APROVADOR_UPD ON CI.KZN_APROVADOR AFTER UPDATE AS
BEGIN
    SET NOCOUNT ON;
    IF NOT UPDATE(DT_ATUALIZACAO)
        UPDATE T SET DT_ATUALIZACAO = SYSDATETIME()
        FROM CI.KZN_APROVADOR T JOIN inserted i ON i.ID_APROVADOR = T.ID_APROVADOR AND i.CD_MATRICULA = T.CD_MATRICULA;
END
GO

CREATE OR ALTER TRIGGER CI.TR_KZN_ADMIN_UPD ON CI.KZN_ADMIN AFTER UPDATE AS
BEGIN
    SET NOCOUNT ON;
    IF NOT UPDATE(DT_ATUALIZACAO)
        UPDATE T SET DT_ATUALIZACAO = SYSDATETIME()
        FROM CI.KZN_ADMIN T JOIN inserted i ON i.ID_ADMIN = T.ID_ADMIN AND i.CD_MATRICULA = T.CD_MATRICULA;
END
GO

CREATE OR ALTER TRIGGER CI.TR_KZN_TIPO_USUARIO_UPD ON CI.KZN_TIPO_USUARIO AFTER UPDATE AS
BEGIN
    SET NOCOUNT ON;
    IF NOT UPDATE(DT_ATUALIZACAO)
        UPDATE T SET DT_ATUALIZACAO = SYSDATETIME()
        FROM CI.KZN_TIPO_USUARIO T JOIN inserted i ON i.ID_TIPO_USUARIO = T.ID_TIPO_USUARIO;
END
GO

CREATE OR ALTER TRIGGER CI.TR_KZN_CATEGORIA_UPD ON CI.KZN_CATEGORIA AFTER UPDATE AS
BEGIN
    SET NOCOUNT ON;
    IF NOT UPDATE(DT_ATUALIZACAO)
        UPDATE T SET DT_ATUALIZACAO = SYSDATETIME()
        FROM CI.KZN_CATEGORIA T JOIN inserted i ON i.ID_CATEGORIA = T.ID_CATEGORIA AND i.ID_IDIOMA = T.ID_IDIOMA;
END
GO

CREATE OR ALTER TRIGGER CI.TR_KZN_REPLICACAO_UPD ON CI.KZN_REPLICACAO AFTER UPDATE AS
BEGIN
    SET NOCOUNT ON;
    IF NOT UPDATE(DT_ATUALIZACAO)
        UPDATE T SET DT_ATUALIZACAO = SYSDATETIME()
        FROM CI.KZN_REPLICACAO T JOIN inserted i ON i.ID_REPLICACAO = T.ID_REPLICACAO AND i.ID_IDIOMA = T.ID_IDIOMA;
END
GO

CREATE OR ALTER TRIGGER CI.TR_KZN_DESPERDICIO_UPD ON CI.KZN_DESPERDICIO AFTER UPDATE AS
BEGIN
    SET NOCOUNT ON;
    IF NOT UPDATE(DT_ATUALIZACAO)
        UPDATE T SET DT_ATUALIZACAO = SYSDATETIME()
        FROM CI.KZN_DESPERDICIO T JOIN inserted i ON i.ID_DESPERDICIO = T.ID_DESPERDICIO AND i.ID_IDIOMA = T.ID_IDIOMA;
END
GO

CREATE OR ALTER TRIGGER CI.TR_KZN_MOEDA_UPD ON CI.KZN_MOEDA AFTER UPDATE AS
BEGIN
    SET NOCOUNT ON;
    IF NOT UPDATE(DT_ATUALIZACAO)
        UPDATE T SET DT_ATUALIZACAO = SYSDATETIME()
        FROM CI.KZN_MOEDA T JOIN inserted i ON i.ID_MOEDA = T.ID_MOEDA;
END
GO

CREATE OR ALTER TRIGGER CI.TR_KZN_TIPO_RESULTADO_UPD ON CI.KZN_TIPO_RESULTADO AFTER UPDATE AS
BEGIN
    SET NOCOUNT ON;
    IF NOT UPDATE(DT_ATUALIZACAO)
        UPDATE T SET DT_ATUALIZACAO = SYSDATETIME()
        FROM CI.KZN_TIPO_RESULTADO T JOIN inserted i ON i.ID_TIPO_RESULTADO = T.ID_TIPO_RESULTADO AND i.ID_IDIOMA = T.ID_IDIOMA;
END
GO

CREATE OR ALTER TRIGGER CI.TR_KZN_RESULTADOS_UPD ON CI.KZN_RESULTADOS AFTER UPDATE AS
BEGIN
    SET NOCOUNT ON;
    IF NOT UPDATE(DT_ATUALIZACAO)
        UPDATE T SET DT_ATUALIZACAO = SYSDATETIME()
        FROM CI.KZN_RESULTADOS T JOIN inserted i ON i.ID_RESULTADO = T.ID_RESULTADO AND i.ID_IDIOMA = T.ID_IDIOMA;
END
GO

CREATE OR ALTER TRIGGER CI.TR_KZN_MOTIVO_REPROVACAO_UPD ON CI.KZN_MOTIVO_REPROVACAO AFTER UPDATE AS
BEGIN
    SET NOCOUNT ON;
    IF NOT UPDATE(DT_ATUALIZACAO)
        UPDATE T SET DT_ATUALIZACAO = SYSDATETIME()
        FROM CI.KZN_MOTIVO_REPROVACAO T JOIN inserted i ON i.ID_MOTIVO = T.ID_MOTIVO AND i.ID_IDIOMA = T.ID_IDIOMA;
END
GO

CREATE OR ALTER TRIGGER CI.TR_KZN_MEMBROS_EQUIPE_UPD ON CI.KZN_MEMBROS_EQUIPE AFTER UPDATE AS
BEGIN
    SET NOCOUNT ON;
    IF NOT UPDATE(DT_ATUALIZACAO)
        UPDATE T SET DT_ATUALIZACAO = SYSDATETIME()
        FROM CI.KZN_MEMBROS_EQUIPE T
        JOIN inserted i ON i.ID_KAIZEN = T.ID_KAIZEN AND i.ID_USUARIO = T.ID_USUARIO;
END
GO

CREATE OR ALTER TRIGGER CI.TR_KZN_RESULTADO_KAIZEN_UPD ON CI.KZN_RESULTADO_KAIZEN AFTER UPDATE AS
BEGIN
    SET NOCOUNT ON;
    IF NOT UPDATE(DT_ATUALIZACAO)
        UPDATE T SET DT_ATUALIZACAO = SYSDATETIME()
        FROM CI.KZN_RESULTADO_KAIZEN T
        JOIN inserted i ON i.ID_KAIZEN = T.ID_KAIZEN AND i.ID_RESULTADO = T.ID_RESULTADO;
END
GO

CREATE OR ALTER TRIGGER CI.TR_KZN_KAIZEN_HIERARQUIA_UPD ON CI.KZN_KAIZEN_HIERARQUIA AFTER UPDATE AS
BEGIN
    SET NOCOUNT ON;
    IF NOT UPDATE(DT_ATUALIZACAO)
        UPDATE T SET DT_ATUALIZACAO = SYSDATETIME()
        FROM CI.KZN_KAIZEN_HIERARQUIA T JOIN inserted i ON i.ID_KAIZEN_HIERARQUIA = T.ID_KAIZEN_HIERARQUIA;
END
GO

/* ==============================================================================
   19. TRIGGERS ESPECIAIS — CI.KZN_PEDRAVISAOCONSOLIDADA
   (DT_ATUALIZACAO automática + gravação no log de auditoria)
   ============================================================================== */
CREATE OR ALTER TRIGGER CI.TR_KZN_PVC_INS ON CI.KZN_PEDRAVISAOCONSOLIDADA AFTER INSERT AS
BEGIN
    SET NOCOUNT ON;
    INSERT INTO CI.KZN_LOG_PEDRAVISAOCONSOLIDADA (ID_KAIZEN, TP_OPERACAO, DT_OPERACAO, ID_USUARIO_OPERACAO)
    SELECT ID_KAIZEN, 'C', DT_CRIACAO, ID_USUARIO_CADASTRO
    FROM inserted;
END
GO

CREATE OR ALTER TRIGGER CI.TR_KZN_PVC_UPD ON CI.KZN_PEDRAVISAOCONSOLIDADA AFTER UPDATE AS
BEGIN
    SET NOCOUNT ON;

    IF NOT UPDATE(DT_ATUALIZACAO)
        UPDATE T SET DT_ATUALIZACAO = SYSDATETIME()
        FROM CI.KZN_PEDRAVISAOCONSOLIDADA T JOIN inserted i ON i.ID_KAIZEN = T.ID_KAIZEN;

    -- Relê DT_ATUALIZACAO já corrigida acima, pra não gravar um SYSDATETIME()
    -- ligeiramente diferente do que efetivamente ficou salvo na linha.
    INSERT INTO CI.KZN_LOG_PEDRAVISAOCONSOLIDADA (ID_KAIZEN, TP_OPERACAO, DT_OPERACAO, ID_USUARIO_OPERACAO)
    SELECT i.ID_KAIZEN, 'A', T.DT_ATUALIZACAO, i.ID_USUARIO_ATUALIZACAO
    FROM inserted i
    JOIN CI.KZN_PEDRAVISAOCONSOLIDADA T ON T.ID_KAIZEN = i.ID_KAIZEN;
END
GO

/* ==============================================================================
   20. CARGA INICIAL (seed) — idiomas e moedas
   (KZN_MDM_HIERARQUIA não é semeada aqui: presumida alimentada por
   integração externa RH/MDM, não pelo script. Demais tabelas mestre
   dependem de dado de negócio real — sem seed fictício.)
   ============================================================================== */
-- ID_IDIOMA/ID_MOEDA agora são INT preenchidos pela aplicação (sem
-- IDENTITY) — o seed abaixo passa a atribuir o ID explicitamente também.
MERGE CI.KZN_IDIOMA AS T
USING (VALUES
    (1, 'pt-BR', 'Português (Brasil)', 'Brasil'),
    (2, 'en-US', 'English (US)',       'Estados Unidos'),
    (3, 'en-CA', 'English (Canada)',   'Canadá'),
    (4, 'es-ES', 'Español',            'Espanha'),
    (5, 'id-ID', 'Bahasa Indonesia',   'Indonésia')
) AS S (ID_IDIOMA, SG_IDIOMA, NM_IDIOMA, NM_PAIS)
    ON T.SG_IDIOMA = S.SG_IDIOMA
WHEN NOT MATCHED BY TARGET THEN
    INSERT (ID_IDIOMA, SG_IDIOMA, NM_IDIOMA, NM_PAIS) VALUES (S.ID_IDIOMA, S.SG_IDIOMA, S.NM_IDIOMA, S.NM_PAIS);
GO

MERGE CI.KZN_MOEDA AS T
USING (VALUES
    (1, 'Real',              'BRL', 'Brasil'),
    (2, 'Dólar Americano',   'USD', 'Estados Unidos'),
    (3, 'Dólar Canadense',   'CAD', 'Canadá'),
    (4, 'Libra Esterlina',   'GBP', 'Reino Unido'),
    (5, 'Rupia Indonésia',   'IDR', 'Indonésia')
) AS S (ID_MOEDA, NM_MOEDA, SG_MOEDA, NM_PAIS)
    ON T.SG_MOEDA = S.SG_MOEDA
WHEN NOT MATCHED BY TARGET THEN
    INSERT (ID_MOEDA, NM_MOEDA, SG_MOEDA, NM_PAIS) VALUES (S.ID_MOEDA, S.NM_MOEDA, S.SG_MOEDA, S.NM_PAIS);
GO

/* ==============================================================================
   21. AJUSTE DE TAMANHO DE CAMPOS (padronização VARCHAR) — idempotente
   Os CREATE TABLE acima só rodam quando a tabela ainda não existe (IF
   OBJECT_ID ... IS NULL); em bancos onde as tabelas já tiverem sido
   criadas com os tamanhos antigos (VARCHAR(20)/(40)/(150)), esta seção
   amplia as colunas pros tamanhos novos (VARCHAR(30)/(100)/(200)).
   Ampliar VARCHAR não trunca nem perde dado existente — é seguro rodar
   mesmo com linhas já gravadas; nullability e demais atributos da coluna
   são preservados (mesma regra do CREATE TABLE correspondente).
   ============================================================================== */
IF OBJECT_ID('CI.KZN_MDM_HIERARQUIA', 'U') IS NOT NULL
BEGIN
    ALTER TABLE CI.KZN_MDM_HIERARQUIA ALTER COLUMN CD_MATRICULA VARCHAR(30)  NOT NULL;
    ALTER TABLE CI.KZN_MDM_HIERARQUIA ALTER COLUMN NM_USUARIO   VARCHAR(30)  NOT NULL;
    ALTER TABLE CI.KZN_MDM_HIERARQUIA ALTER COLUMN CD_EMAIL     VARCHAR(100) NOT NULL;
END
GO

IF OBJECT_ID('CI.KZN_IDIOMA', 'U') IS NOT NULL
BEGIN
    ALTER TABLE CI.KZN_IDIOMA ALTER COLUMN URL_ICONE VARCHAR(200)     NULL;
    ALTER TABLE CI.KZN_IDIOMA ALTER COLUMN NM_IDIOMA VARCHAR(30)  NOT NULL;
    ALTER TABLE CI.KZN_IDIOMA ALTER COLUMN NM_PAIS   VARCHAR(30)      NULL;
END
GO

IF OBJECT_ID('CI.KZN_CATEGORIA', 'U') IS NOT NULL
BEGIN
    ALTER TABLE CI.KZN_CATEGORIA ALTER COLUMN URL_ICONE    VARCHAR(200)     NULL;
    ALTER TABLE CI.KZN_CATEGORIA ALTER COLUMN NM_CATEGORIA VARCHAR(30)  NOT NULL;
    ALTER TABLE CI.KZN_CATEGORIA ALTER COLUMN DS_CATEGORIA VARCHAR(100)     NULL;
END
GO

IF OBJECT_ID('CI.KZN_REPLICACAO', 'U') IS NOT NULL
BEGIN
    ALTER TABLE CI.KZN_REPLICACAO ALTER COLUMN URL_ICONE     VARCHAR(200)     NULL;
    ALTER TABLE CI.KZN_REPLICACAO ALTER COLUMN NM_REPLICACAO VARCHAR(30)  NOT NULL;
    ALTER TABLE CI.KZN_REPLICACAO ALTER COLUMN DS_REPLICACAO VARCHAR(100)     NULL;
END
GO

IF OBJECT_ID('CI.KZN_DESPERDICIO', 'U') IS NOT NULL
BEGIN
    ALTER TABLE CI.KZN_DESPERDICIO ALTER COLUMN URL_ICONE      VARCHAR(200)     NULL;
    ALTER TABLE CI.KZN_DESPERDICIO ALTER COLUMN NM_DESPERDICIO VARCHAR(30)  NOT NULL;
    ALTER TABLE CI.KZN_DESPERDICIO ALTER COLUMN DS_DESPERDICIO VARCHAR(100)     NULL;
END
GO

IF OBJECT_ID('CI.KZN_MOEDA', 'U') IS NOT NULL
BEGIN
    ALTER TABLE CI.KZN_MOEDA ALTER COLUMN NM_MOEDA VARCHAR(30) NOT NULL;
    ALTER TABLE CI.KZN_MOEDA ALTER COLUMN NM_PAIS  VARCHAR(30)     NULL;
END
GO

IF OBJECT_ID('CI.KZN_TIPO_RESULTADO', 'U') IS NOT NULL
BEGIN
    ALTER TABLE CI.KZN_TIPO_RESULTADO ALTER COLUMN NM_TIPO_RESULTADO VARCHAR(30) NOT NULL;
END
GO

IF OBJECT_ID('CI.KZN_RESULTADOS', 'U') IS NOT NULL
BEGIN
    ALTER TABLE CI.KZN_RESULTADOS ALTER COLUMN URL_ICONE    VARCHAR(200)     NULL;
    ALTER TABLE CI.KZN_RESULTADOS ALTER COLUMN NM_RESULTADO VARCHAR(30)  NOT NULL;
    ALTER TABLE CI.KZN_RESULTADOS ALTER COLUMN DS_RESULTADO VARCHAR(100)     NULL;
END
GO

IF OBJECT_ID('CI.KZN_MOTIVO_REPROVACAO', 'U') IS NOT NULL
BEGIN
    ALTER TABLE CI.KZN_MOTIVO_REPROVACAO ALTER COLUMN NM_MOTIVO VARCHAR(30)  NOT NULL;
    ALTER TABLE CI.KZN_MOTIVO_REPROVACAO ALTER COLUMN DS_MOTIVO VARCHAR(100)     NULL;
END
GO

IF OBJECT_ID('CI.KZN_PEDRAVISAOCONSOLIDADA', 'U') IS NOT NULL
BEGIN
    ALTER TABLE CI.KZN_PEDRAVISAOCONSOLIDADA ALTER COLUMN NM_KAIZEN               VARCHAR(30)  NOT NULL;
    ALTER TABLE CI.KZN_PEDRAVISAOCONSOLIDADA ALTER COLUMN DS_PROBLEMA             VARCHAR(100)     NULL;
    ALTER TABLE CI.KZN_PEDRAVISAOCONSOLIDADA ALTER COLUMN DS_OBJETIVO             VARCHAR(100)     NULL;
    ALTER TABLE CI.KZN_PEDRAVISAOCONSOLIDADA ALTER COLUMN SG_STATUS               VARCHAR(30)  NOT NULL;
    ALTER TABLE CI.KZN_PEDRAVISAOCONSOLIDADA ALTER COLUMN URL_IMG_ANTES           VARCHAR(200)     NULL;
    ALTER TABLE CI.KZN_PEDRAVISAOCONSOLIDADA ALTER COLUMN DS_ESTADO_ANTES         VARCHAR(100)     NULL;
    ALTER TABLE CI.KZN_PEDRAVISAOCONSOLIDADA ALTER COLUMN URL_IMG_DEPOIS          VARCHAR(200)     NULL;
    ALTER TABLE CI.KZN_PEDRAVISAOCONSOLIDADA ALTER COLUMN DS_ESTADO_DEPOIS        VARCHAR(100)     NULL;
    ALTER TABLE CI.KZN_PEDRAVISAOCONSOLIDADA ALTER COLUMN URL_REFERENCIA          VARCHAR(200)     NULL;
    ALTER TABLE CI.KZN_PEDRAVISAOCONSOLIDADA ALTER COLUMN DS_LICOES_APRENDIDAS    VARCHAR(100)     NULL;
    ALTER TABLE CI.KZN_PEDRAVISAOCONSOLIDADA ALTER COLUMN DS_RESULTADO_ESPERADO   VARCHAR(100)     NULL;
END
GO

IF OBJECT_ID('CI.KZN_RESULTADO_KAIZEN', 'U') IS NOT NULL
BEGIN
    ALTER TABLE CI.KZN_RESULTADO_KAIZEN ALTER COLUMN URL_ICONE VARCHAR(200) NULL;
END
GO

-- NM_HIERARQUIA_N1..N8 de KZN_KAIZEN_HIERARQUIA: VARCHAR(50) -> VARCHAR(80) (pedido do
-- time, nesta rodada). KZN_MDM_HIERARQUIA não precisa de ALTER equivalente aqui — a
-- migração da seção 17.2 já recria a tabela inteira no tamanho novo.
IF OBJECT_ID('CI.KZN_KAIZEN_HIERARQUIA', 'U') IS NOT NULL
BEGIN
    ALTER TABLE CI.KZN_KAIZEN_HIERARQUIA ALTER COLUMN NM_HIERARQUIA_N1 VARCHAR(80) NULL;
    ALTER TABLE CI.KZN_KAIZEN_HIERARQUIA ALTER COLUMN NM_HIERARQUIA_N2 VARCHAR(80) NULL;
    ALTER TABLE CI.KZN_KAIZEN_HIERARQUIA ALTER COLUMN NM_HIERARQUIA_N3 VARCHAR(80) NULL;
    ALTER TABLE CI.KZN_KAIZEN_HIERARQUIA ALTER COLUMN NM_HIERARQUIA_N4 VARCHAR(80) NULL;
    ALTER TABLE CI.KZN_KAIZEN_HIERARQUIA ALTER COLUMN NM_HIERARQUIA_N5 VARCHAR(80) NULL;
    ALTER TABLE CI.KZN_KAIZEN_HIERARQUIA ALTER COLUMN NM_HIERARQUIA_N6 VARCHAR(80) NULL;
    ALTER TABLE CI.KZN_KAIZEN_HIERARQUIA ALTER COLUMN NM_HIERARQUIA_N7 VARCHAR(80) NULL;
    ALTER TABLE CI.KZN_KAIZEN_HIERARQUIA ALTER COLUMN NM_HIERARQUIA_N8 VARCHAR(80) NULL;
END
GO

/* ==============================================================================
   22. VALIDAÇÃO
   ============================================================================== */
SELECT  s.name AS SCHEMA_NAME,
        t.name AS TABLE_NAME,
        p.rows AS QT_LINHAS
FROM    sys.tables t
JOIN    sys.schemas s   ON s.schema_id = t.schema_id
JOIN    sys.partitions p ON p.object_id = t.object_id AND p.index_id IN (0,1)
WHERE   s.name = 'CI' AND t.name LIKE 'KZN[_]%'
ORDER BY t.name;
GO
