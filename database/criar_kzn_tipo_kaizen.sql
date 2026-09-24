/* =====================================================================
   CI.KZN_TIPO_KAIZEN — mestre de referência
   ---------------------------------------------------------------------
   Mesmo molde de KZN_STATUS/KZN_CATEGORIA/KZN_REPLICACAO/KZN_MOEDA:
   1 linha por idioma, PK composta, UNIQUE de nome por idioma, índice por
   idioma com INCLUDE do nome, SG_ATIVO e DT_ATUALIZACAO com DEFAULT,
   trigger de DT_ATUALIZACAO.

   Idempotente. Schema: 'ci'.
   ===================================================================== */

SET NOCOUNT ON;
SET XACT_ABORT ON;

IF OBJECT_ID('CI.KZN_TIPO_KAIZEN', 'U') IS NULL
BEGIN
    CREATE TABLE CI.KZN_TIPO_KAIZEN
    (
        ID_TIPO_KAIZEN  INT                             NOT NULL,
        ID_IDIOMA       INT                             NOT NULL,
        NM_TIPO_KAIZEN  VARCHAR(30)                     NOT NULL,
        DS_TIPO_KAIZEN  VARCHAR(100)                        NULL,
        SG_ATIVO        VARCHAR(1)                      NOT NULL
            CONSTRAINT DF_KZN_TIPO_KAIZEN_SG_ATIVO DEFAULT ('S'),
        ID_USUARIO      INT                                 NULL,
        DT_ATUALIZACAO  DATETIME2(3)                    NOT NULL
            CONSTRAINT DF_KZN_TIPO_KAIZEN_DT_ATUALIZACAO DEFAULT (SYSDATETIME()),

        CONSTRAINT PK_KZN_TIPO_KAIZEN        PRIMARY KEY CLUSTERED (ID_TIPO_KAIZEN, ID_IDIOMA),
        CONSTRAINT FK_KZN_TIPO_KAIZEN_IDIOMA FOREIGN KEY (ID_IDIOMA)
            REFERENCES CI.KZN_IDIOMA (ID_IDIOMA),
        CONSTRAINT UQ_KZN_TIPO_KAIZEN_NM     UNIQUE (ID_IDIOMA, NM_TIPO_KAIZEN)
    );

    CREATE NONCLUSTERED INDEX IX_KZN_TIPO_KAIZEN_ID_IDIOMA
        ON CI.KZN_TIPO_KAIZEN (ID_IDIOMA) INCLUDE (NM_TIPO_KAIZEN);

    PRINT 'CI.KZN_TIPO_KAIZEN criada.';
END
ELSE PRINT 'CI.KZN_TIPO_KAIZEN ja existe.';
GO

-- FK de ID_USUARIO fora do CREATE TABLE, pelo mesmo motivo das irmãs:
-- CI.KZN_MDM_HIERARQUIA não tem UNIQUE/PK cobrindo ID_USUARIO sozinho e,
-- inline, o CREATE TABLE inteiro falharia. Só é criada onde o banco
-- realmente suporta.
IF OBJECT_ID('CI.KZN_TIPO_KAIZEN', 'U') IS NOT NULL
   AND OBJECT_ID('CI.FK_KZN_TIPO_KAIZEN_USUARIO', 'F') IS NULL
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
    ALTER TABLE CI.KZN_TIPO_KAIZEN ADD CONSTRAINT FK_KZN_TIPO_KAIZEN_USUARIO
        FOREIGN KEY (ID_USUARIO) REFERENCES CI.KZN_MDM_HIERARQUIA (ID_USUARIO);
GO

CREATE OR ALTER TRIGGER CI.TR_KZN_TIPO_KAIZEN_UPD ON CI.KZN_TIPO_KAIZEN AFTER UPDATE AS
BEGIN
    SET NOCOUNT ON;
    IF NOT UPDATE(DT_ATUALIZACAO)
        UPDATE T SET DT_ATUALIZACAO = SYSDATETIME()
        FROM CI.KZN_TIPO_KAIZEN T JOIN inserted i
          ON i.ID_TIPO_KAIZEN = T.ID_TIPO_KAIZEN AND i.ID_IDIOMA = T.ID_IDIOMA;
END
GO

/* Conferência */
SELECT COLUNA = c.name,
       TIPO = ty.name + CASE WHEN ty.name = 'varchar' THEN '(' + CAST(c.max_length AS VARCHAR(10)) + ')'
                             WHEN ty.name = 'datetime2' THEN '(' + CAST(c.scale AS VARCHAR(10)) + ')' ELSE '' END,
       NULO = CASE WHEN c.is_nullable = 1 THEN 'SIM' ELSE 'NAO' END
FROM   sys.columns c JOIN sys.types ty ON ty.user_type_id = c.user_type_id
WHERE  c.object_id = OBJECT_ID('CI.KZN_TIPO_KAIZEN')
ORDER BY c.column_id;

SELECT CONSTRAINT_ = name, TIPO = type_desc
FROM   sys.objects WHERE parent_object_id = OBJECT_ID('CI.KZN_TIPO_KAIZEN')
ORDER BY type_desc, name;
GO
