/* =====================================================================
   1) CI.KZN_TIPO_KAIZEN (mestre de referência)
   2) Novos campos em CI.KZN_PEDRAVISAOCONSOLIDADA
   Idempotente. Schema: 'ci'.
   ===================================================================== */

SET NOCOUNT ON;
SET XACT_ABORT ON;

/* =====================================================================
   E1 - CI.KZN_TIPO_KAIZEN
   Mesmo molde de KZN_STATUS/KZN_CATEGORIA/KZN_REPLICACAO: 1 linha por
   idioma, PK composta, UNIQUE de nome por idioma, índice por idioma com
   INCLUDE do nome, SG_ATIVO com DEFAULT, DT_ATUALIZACAO com DEFAULT.
   ===================================================================== */
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

    PRINT 'E1 ok - CI.KZN_TIPO_KAIZEN criada.';
END
ELSE PRINT 'E1 pulada - CI.KZN_TIPO_KAIZEN ja existe.';
GO

-- FK_KZN_TIPO_KAIZEN_USUARIO fora do CREATE TABLE, pelo mesmo motivo das
-- irmãs: CI.KZN_MDM_HIERARQUIA não tem UNIQUE/PK cobrindo ID_USUARIO
-- sozinho, e inline o CREATE TABLE inteiro falharia.
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

/* =====================================================================
   E2 - Novos campos em CI.KZN_PEDRAVISAOCONSOLIDADA

   SG_GM e ID_TIPO_KAIZEN são NOT NULL, mas a tabela já tem linhas: um
   ADD NOT NULL sem DEFAULT falharia. Entram com DEFAULT, que preenche as
   linhas existentes e serve de valor-padrão em inserts que omitam a
   coluna. SG_GM = 'N' e ID_TIPO_KAIZEN = 0 são os únicos valores
   neutros possíveis sem inventar regra de negócio — AJUSTE-OS se houver
   um padrão definido pelo time.

   ID_TIPO_KAIZEN NÃO recebe FK de banco: KZN_TIPO_KAIZEN tem PK composta
   (ID_TIPO_KAIZEN, ID_IDIOMA) e o SQL Server não aceita FK para parte de
   chave composta — mesma regra já aplicada a ID_CATEGORIA, ID_REPLICACAO
   e ID_STATUS.
   ===================================================================== */
IF COL_LENGTH('CI.KZN_PEDRAVISAOCONSOLIDADA', 'SG_GM') IS NULL
    ALTER TABLE CI.KZN_PEDRAVISAOCONSOLIDADA ADD SG_GM VARCHAR(1) NOT NULL
        CONSTRAINT DF_KZN_PVC_SG_GM DEFAULT ('N');
GO

IF COL_LENGTH('CI.KZN_PEDRAVISAOCONSOLIDADA', 'URL_GM') IS NULL
    ALTER TABLE CI.KZN_PEDRAVISAOCONSOLIDADA ADD URL_GM VARCHAR(300) NULL;
GO

IF COL_LENGTH('CI.KZN_PEDRAVISAOCONSOLIDADA', 'ID_TIPO_KAIZEN') IS NULL
    ALTER TABLE CI.KZN_PEDRAVISAOCONSOLIDADA ADD ID_TIPO_KAIZEN INT NOT NULL
        CONSTRAINT DF_KZN_PVC_ID_TIPO_KAIZEN DEFAULT (0);
GO

IF COL_LENGTH('CI.KZN_PEDRAVISAOCONSOLIDADA', 'PCT_DUPLICIDADE') IS NULL
    ALTER TABLE CI.KZN_PEDRAVISAOCONSOLIDADA ADD PCT_DUPLICIDADE FLOAT NULL;
GO

IF COL_LENGTH('CI.KZN_PEDRAVISAOCONSOLIDADA', 'ID_DUPLICIDADE') IS NULL
    ALTER TABLE CI.KZN_PEDRAVISAOCONSOLIDADA ADD ID_DUPLICIDADE INT NULL;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE object_id = OBJECT_ID('CI.KZN_PEDRAVISAOCONSOLIDADA')
                 AND name = 'IX_KZN_PVC_TIPO_KAIZEN')
    CREATE NONCLUSTERED INDEX IX_KZN_PVC_TIPO_KAIZEN
        ON CI.KZN_PEDRAVISAOCONSOLIDADA (ID_TIPO_KAIZEN);
GO

/* =====================================================================
   E3 - Auditoria das 5 colunas novas no trigger de UPDATE
   O diff campo a campo da seção 19 é uma lista explícita: sem estes
   blocos, alterações nos campos novos não apareceriam no log.
   ===================================================================== */
DECLARE @d NVARCHAR(MAX), @novo NVARCHAR(MAX);

SELECT @d = m.definition
FROM   sys.sql_modules m JOIN sys.triggers t ON t.object_id = m.object_id
WHERE  t.parent_id = OBJECT_ID('CI.KZN_PEDRAVISAOCONSOLIDADA') AND t.name = 'TR_KZN_PVC_UPD';

IF @d IS NULL
    RAISERROR('E3 pulada: TR_KZN_PVC_UPD nao encontrado.', 10, 1);
ELSE IF @d LIKE '%''SG_GM''%'
    PRINT 'E3 pulada - campos novos ja auditados.';
ELSE
BEGIN
    SET @novo = N'
        UNION ALL
        SELECT lm.ID_LOG, ''SG_GM'', CONVERT(VARCHAR(300), d.SG_GM), CONVERT(VARCHAR(300), i.SG_GM)
        FROM inserted i JOIN deleted d ON d.ID_KAIZEN = i.ID_KAIZEN JOIN @logMap lm ON lm.ID_KAIZEN = i.ID_KAIZEN
        WHERE NOT (d.SG_GM = i.SG_GM OR (d.SG_GM IS NULL AND i.SG_GM IS NULL))
        UNION ALL
        SELECT lm.ID_LOG, ''URL_GM'', CONVERT(VARCHAR(300), d.URL_GM), CONVERT(VARCHAR(300), i.URL_GM)
        FROM inserted i JOIN deleted d ON d.ID_KAIZEN = i.ID_KAIZEN JOIN @logMap lm ON lm.ID_KAIZEN = i.ID_KAIZEN
        WHERE NOT (d.URL_GM = i.URL_GM OR (d.URL_GM IS NULL AND i.URL_GM IS NULL))
        UNION ALL
        SELECT lm.ID_LOG, ''ID_TIPO_KAIZEN'', CONVERT(VARCHAR(300), d.ID_TIPO_KAIZEN), CONVERT(VARCHAR(300), i.ID_TIPO_KAIZEN)
        FROM inserted i JOIN deleted d ON d.ID_KAIZEN = i.ID_KAIZEN JOIN @logMap lm ON lm.ID_KAIZEN = i.ID_KAIZEN
        WHERE NOT (d.ID_TIPO_KAIZEN = i.ID_TIPO_KAIZEN OR (d.ID_TIPO_KAIZEN IS NULL AND i.ID_TIPO_KAIZEN IS NULL))
        UNION ALL
        SELECT lm.ID_LOG, ''PCT_DUPLICIDADE'', CONVERT(VARCHAR(300), d.PCT_DUPLICIDADE), CONVERT(VARCHAR(300), i.PCT_DUPLICIDADE)
        FROM inserted i JOIN deleted d ON d.ID_KAIZEN = i.ID_KAIZEN JOIN @logMap lm ON lm.ID_KAIZEN = i.ID_KAIZEN
        WHERE NOT (d.PCT_DUPLICIDADE = i.PCT_DUPLICIDADE OR (d.PCT_DUPLICIDADE IS NULL AND i.PCT_DUPLICIDADE IS NULL))
        UNION ALL
        SELECT lm.ID_LOG, ''ID_DUPLICIDADE'', CONVERT(VARCHAR(300), d.ID_DUPLICIDADE), CONVERT(VARCHAR(300), i.ID_DUPLICIDADE)
        FROM inserted i JOIN deleted d ON d.ID_KAIZEN = i.ID_KAIZEN JOIN @logMap lm ON lm.ID_KAIZEN = i.ID_KAIZEN
        WHERE NOT (d.ID_DUPLICIDADE = i.ID_DUPLICIDADE OR (d.ID_DUPLICIDADE IS NULL AND i.ID_DUPLICIDADE IS NULL))
    ) x;';

    /* Ancora no fechamento do último UNION ALL da subconsulta. */
    IF @d NOT LIKE '%' + CHAR(13) + CHAR(10) + '    ) x;%'
        RAISERROR('E3 NAO aplicada: nao encontrei o fechamento ") x;" no corpo do trigger. Acrescente os blocos a mao.', 16, 1);
    ELSE
    BEGIN
        SET @d = REPLACE(@d, CHAR(13) + CHAR(10) + '    ) x;', @novo);
        SET @d = STUFF(@d, CHARINDEX('CREATE', @d), 6, 'CREATE OR ALTER');
        SET @d = REPLACE(@d, 'CREATE OR ALTER OR ALTER', 'CREATE OR ALTER');
        EXEC sp_executesql @d;
        PRINT 'E3 ok - 5 campos novos incluidos na auditoria.';
    END
END
GO

/* =====================================================================
   E4 - CONFERÊNCIA
   ===================================================================== */
SELECT COLUNA = c.name,
       TIPO = ty.name + CASE WHEN ty.name = 'varchar' THEN '(' + CAST(c.max_length AS VARCHAR(10)) + ')' ELSE '' END,
       NULO = CASE WHEN c.is_nullable = 1 THEN 'SIM' ELSE 'NAO' END,
       DEFAULT_ = dc.definition
FROM        sys.columns c
JOIN        sys.types ty ON ty.user_type_id = c.user_type_id
LEFT JOIN   sys.default_constraints dc ON dc.parent_object_id = c.object_id AND dc.parent_column_id = c.column_id
WHERE       c.object_id = OBJECT_ID('CI.KZN_PEDRAVISAOCONSOLIDADA')
  AND       c.name IN ('SG_GM','URL_GM','ID_TIPO_KAIZEN','PCT_DUPLICIDADE','ID_DUPLICIDADE')
ORDER BY    c.column_id;

SELECT OBJETO = 'CI.KZN_TIPO_KAIZEN',
       COLUNAS  = (SELECT COUNT(*) FROM sys.columns        WHERE object_id = OBJECT_ID('CI.KZN_TIPO_KAIZEN')),
       FKS      = (SELECT COUNT(*) FROM sys.foreign_keys   WHERE parent_object_id = OBJECT_ID('CI.KZN_TIPO_KAIZEN')),
       INDICES  = (SELECT COUNT(*) FROM sys.indexes        WHERE object_id = OBJECT_ID('CI.KZN_TIPO_KAIZEN') AND type IN (1,2)),
       TRIGGERS = (SELECT COUNT(*) FROM sys.triggers       WHERE parent_id = OBJECT_ID('CI.KZN_TIPO_KAIZEN'));
GO
