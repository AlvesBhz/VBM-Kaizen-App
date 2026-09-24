/* =====================================================================
   CI.KZN_PEDRAVISAOCONSOLIDADA — campos novos
   ---------------------------------------------------------------------
     SG_GM           VARCHAR(1)   NOT NULL  DEFAULT ('N')
     URL_GM          VARCHAR(300)     NULL
     ID_TIPO_KAIZEN  INT          NOT NULL  DEFAULT (0)

   Os DEFAULT são necessários, não decorativos: as duas colunas NOT NULL
   entram numa tabela que pode ter linhas, e um ADD NOT NULL sem DEFAULT
   falharia. 'N' e 0 são valores neutros para viabilizar o ALTER — AJUSTE
   se o time tiver padrão definido.

   ID_TIPO_KAIZEN NÃO recebe FK: CI.KZN_TIPO_KAIZEN tem PK composta
   (ID_TIPO_KAIZEN, ID_IDIOMA) e o SQL Server não aceita FK para parte de
   chave composta — mesma regra já aplicada a ID_CATEGORIA, ID_REPLICACAO
   e ID_STATUS.

   PRÉ-REQUISITO: criar_kzn_tipo_kaizen.sql (a E4 avisa se faltar).
   Idempotente. Schema: 'ci'.
   ===================================================================== */

SET NOCOUNT ON;
SET XACT_ABORT ON;

/* =====================================================================
   E1 - COLUNAS
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

/* =====================================================================
   E2 - ÍNDICE
   ===================================================================== */
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE object_id = OBJECT_ID('CI.KZN_PEDRAVISAOCONSOLIDADA')
                 AND name = 'IX_KZN_PVC_TIPO_KAIZEN')
    CREATE NONCLUSTERED INDEX IX_KZN_PVC_TIPO_KAIZEN
        ON CI.KZN_PEDRAVISAOCONSOLIDADA (ID_TIPO_KAIZEN);
GO

PRINT 'E1/E2 ok - colunas e indice.';
GO

/* =====================================================================
   E3 - Auditoria das colunas novas no TR_KZN_PVC_UPD
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
    ) x;';

    IF @d NOT LIKE '%' + CHAR(13) + CHAR(10) + '    ) x;%'
        RAISERROR('E3 NAO aplicada: nao encontrei o fechamento ") x;" no corpo do trigger. Acrescente os blocos a mao.', 16, 1);
    ELSE
    BEGIN
        SET @d = REPLACE(@d, CHAR(13) + CHAR(10) + '    ) x;', @novo);
        SET @d = STUFF(@d, CHARINDEX('CREATE', @d), 6, 'CREATE OR ALTER');
        SET @d = REPLACE(@d, 'CREATE OR ALTER OR ALTER', 'CREATE OR ALTER');
        EXEC sp_executesql @d;
        PRINT 'E3 ok - 3 campos novos incluidos na auditoria.';
    END
END
GO

/* =====================================================================
   E4 - CONFERÊNCIA
   ===================================================================== */
IF OBJECT_ID('CI.KZN_TIPO_KAIZEN','U') IS NULL
    PRINT 'AVISO: CI.KZN_TIPO_KAIZEN nao existe. ID_TIPO_KAIZEN fica sem dominio ate rodar criar_kzn_tipo_kaizen.sql.';

SELECT COLUNA = c.name,
       TIPO = ty.name + CASE WHEN ty.name = 'varchar' THEN '(' + CAST(c.max_length AS VARCHAR(10)) + ')' ELSE '' END,
       NULO = CASE WHEN c.is_nullable = 1 THEN 'SIM' ELSE 'NAO' END,
       DEFAULT_ = dc.definition,
       POSICAO = c.column_id
FROM        sys.columns c
JOIN        sys.types ty ON ty.user_type_id = c.user_type_id
LEFT JOIN   sys.default_constraints dc ON dc.parent_object_id = c.object_id AND dc.parent_column_id = c.column_id
WHERE       c.object_id = OBJECT_ID('CI.KZN_PEDRAVISAOCONSOLIDADA')
  AND       c.name IN ('SG_GM','URL_GM','ID_TIPO_KAIZEN')
ORDER BY    c.column_id;
GO
