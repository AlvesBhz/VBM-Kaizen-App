/* =====================================================================
   Cria CI.KZN_STATUS — cadastro de status (tabela de domínio)
   ---------------------------------------------------------------------
   Mesmo molde das demais tabelas de domínio do schema
   (KZN_CATEGORIA / KZN_REPLICACAO / KZN_MOEDA): 1 linha por idioma,
   PK composta (ID_STATUS, ID_IDIOMA), UNIQUE do nome por idioma,
   índice por idioma com INCLUDE do nome, SG_ATIVO 'S'/'N' com DEFAULT,
   ID_USUARIO opcional e DT_ATUALIZACAO com DEFAULT + trigger.

   Script IDEMPOTENTE: só cria o que ainda não existir.

   O campo do idioma ficou ID_IDIOMA (e não CD_IDIOMA, como no texto do
   pedido) porque a própria regra pedia "seguir o padrão já utilizado no
   sistema para idiomas" — ID_IDIOMA é o nome usado nas 6 tabelas de
   domínio e em KZN_IDIOMA, e é o que a FK e a PK composta exigem.

   FK_KZN_STATUS_USUARIO só é criada se CI.KZN_MDM_HIERARQUIA tiver
   UNIQUE/PK cobrindo ID_USUARIO sozinho — está confirmado que hoje NÃO
   tem (mesma razão documentada em database/criar_membros_equipe.sql).
   Sem essa checagem, o script inteiro falharia.

   Schema: 'ci' (AZURE_SQL_SCHEMA em app.yaml).
   ===================================================================== */

SET NOCOUNT ON;

IF OBJECT_ID('CI.KZN_STATUS', 'U') IS NOT NULL
BEGIN
    PRINT 'CI.KZN_STATUS ja existe - nada a fazer.';
    RETURN;
END

CREATE TABLE CI.KZN_STATUS
(
    ID_STATUS       INT                             NOT NULL,
    ID_IDIOMA       INT                             NOT NULL,
    URL_ICONE       VARCHAR(200)                        NULL,
    NM_STATUS       VARCHAR(30)                     NOT NULL,
    DS_STATUS       VARCHAR(100)                        NULL,
    SG_ATIVO        VARCHAR(1)                      NOT NULL
        CONSTRAINT DF_KZN_STATUS_SG_ATIVO DEFAULT ('S'),
    ID_USUARIO      INT                                 NULL,
    DT_ATUALIZACAO  DATETIME2(3)                    NOT NULL
        CONSTRAINT DF_KZN_STATUS_DT_ATUALIZACAO DEFAULT (SYSDATETIME()),

    CONSTRAINT PK_KZN_STATUS         PRIMARY KEY CLUSTERED (ID_STATUS, ID_IDIOMA),
    CONSTRAINT FK_KZN_STATUS_IDIOMA  FOREIGN KEY (ID_IDIOMA)
        REFERENCES CI.KZN_IDIOMA (ID_IDIOMA),
    CONSTRAINT UQ_KZN_STATUS_NM      UNIQUE (ID_IDIOMA, NM_STATUS)
);

CREATE NONCLUSTERED INDEX IX_KZN_STATUS_ID_IDIOMA
    ON CI.KZN_STATUS (ID_IDIOMA) INCLUDE (NM_STATUS);

PRINT 'CI.KZN_STATUS criada.';
GO

/* --- FK para o MDM — só se o banco suportar (ver cabeçalho) --------- */
IF OBJECT_ID('CI.KZN_STATUS', 'U') IS NOT NULL
   AND OBJECT_ID('CI.FK_KZN_STATUS_USUARIO', 'F') IS NULL
   AND EXISTS (
        SELECT 1 FROM sys.indexes ix
        WHERE ix.object_id = OBJECT_ID('CI.KZN_MDM_HIERARQUIA')
          AND (ix.is_primary_key = 1 OR ix.is_unique = 1)
          AND (SELECT COUNT(*) FROM sys.index_columns ic
               WHERE ic.object_id = ix.object_id AND ic.index_id = ix.index_id) = 1
          AND EXISTS (SELECT 1 FROM sys.index_columns ic
                      JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
                      WHERE ic.object_id = ix.object_id AND ic.index_id = ix.index_id
                        AND c.name = 'ID_USUARIO')
   )
    ALTER TABLE CI.KZN_STATUS ADD CONSTRAINT FK_KZN_STATUS_USUARIO
        FOREIGN KEY (ID_USUARIO) REFERENCES CI.KZN_MDM_HIERARQUIA (ID_USUARIO);
GO

/* --- Trigger de DT_ATUALIZACAO (padrão da secao 18 do DDL) ---------- */
CREATE OR ALTER TRIGGER CI.TR_KZN_STATUS_UPD ON CI.KZN_STATUS AFTER UPDATE AS
BEGIN
    SET NOCOUNT ON;
    IF NOT UPDATE(DT_ATUALIZACAO)
        UPDATE T SET DT_ATUALIZACAO = SYSDATETIME()
        FROM CI.KZN_STATUS T JOIN inserted i ON i.ID_STATUS = T.ID_STATUS AND i.ID_IDIOMA = T.ID_IDIOMA;
END
GO
