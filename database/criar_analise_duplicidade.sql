/* =====================================================================
   Move a análise de duplicidade da PVC para tabela própria
   1) cria CI.KZN_ANALISE_DUPLICIDADE
   2) remove PCT_DUPLICIDADE e ID_DUPLICIDADE de CI.KZN_PEDRAVISAOCONSOLIDADA
   Idempotente. Schema: 'ci'.
   ===================================================================== */

SET NOCOUNT ON;
SET XACT_ABORT ON;

/* =====================================================================
   E1 - CI.KZN_ANALISE_DUPLICIDADE
   Sem PK: as colunas-chave são NULL-áveis conforme especificado, então
   não há candidata. Sem FK para a PVC: não foi pedida (ver observação na
   entrega). DT_ATUALIZACAO com DEFAULT + trigger, como nas demais.
   ===================================================================== */
IF OBJECT_ID('CI.KZN_ANALISE_DUPLICIDADE', 'U') IS NULL
BEGIN
    CREATE TABLE CI.KZN_ANALISE_DUPLICIDADE
    (
        ID_KAIZEN            INT                                 NULL,
        ID_KAIZEN_DUPLICADO  INT                                 NULL,
        PCT_DUPLICIDADE      FLOAT                               NULL,
        STATUS_ANALISE       VARCHAR(30)                         NULL,
        DT_ATUALIZACAO       DATETIME2(3)                    NOT NULL
            CONSTRAINT DF_KZN_ANALISE_DUP_DT_ATUALIZACAO DEFAULT (SYSDATETIME())
    );

    CREATE NONCLUSTERED INDEX IX_KZN_ANALISE_DUP_KAIZEN
        ON CI.KZN_ANALISE_DUPLICIDADE (ID_KAIZEN);

    PRINT 'E1 ok - CI.KZN_ANALISE_DUPLICIDADE criada.';
END
ELSE PRINT 'E1 pulada - CI.KZN_ANALISE_DUPLICIDADE ja existe.';
GO

CREATE OR ALTER TRIGGER CI.TR_KZN_ANALISE_DUP_UPD ON CI.KZN_ANALISE_DUPLICIDADE AFTER UPDATE AS
BEGIN
    SET NOCOUNT ON;
    -- Sem PK na tabela, o UPDATE de DT_ATUALIZACAO não tem como casar
    -- linha a linha: carimba todas as linhas afetadas pelo mesmo ID_KAIZEN.
    IF NOT UPDATE(DT_ATUALIZACAO)
        UPDATE T SET DT_ATUALIZACAO = SYSDATETIME()
        FROM CI.KZN_ANALISE_DUPLICIDADE T
        JOIN inserted i ON i.ID_KAIZEN = T.ID_KAIZEN;
END
GO

/* =====================================================================
   E2 - Preserva o que houver nas colunas antes de removê-las
   As duas nasceram NULL-áveis e sem carga conhecida, mas a conferência é
   barata e evita perda silenciosa.
   ===================================================================== */
IF COL_LENGTH('CI.KZN_PEDRAVISAOCONSOLIDADA', 'PCT_DUPLICIDADE') IS NOT NULL
BEGIN
    DECLARE @mig INT;
    EXEC sp_executesql N'
        INSERT INTO CI.KZN_ANALISE_DUPLICIDADE (ID_KAIZEN, ID_KAIZEN_DUPLICADO, PCT_DUPLICIDADE, DT_ATUALIZACAO)
        SELECT p.ID_KAIZEN, p.ID_DUPLICIDADE, p.PCT_DUPLICIDADE, SYSDATETIME()
        FROM   CI.KZN_PEDRAVISAOCONSOLIDADA p
        WHERE  p.PCT_DUPLICIDADE IS NOT NULL OR p.ID_DUPLICIDADE IS NOT NULL;
        SET @qt = @@ROWCOUNT;',
        N'@qt INT OUTPUT', @qt = @mig OUTPUT;
    PRINT 'E2 ok - ' + CAST(@mig AS VARCHAR(10)) + ' linha(s) migrada(s) para CI.KZN_ANALISE_DUPLICIDADE.';
END
ELSE PRINT 'E2 pulada - colunas ja removidas.';
GO

/* =====================================================================
   E3 - Retira as 2 colunas do diff do TR_KZN_PVC_UPD
   ANTES do DROP COLUMN: um trigger ativo citando coluna inexistente
   derruba o próximo UPDATE da tabela.
   ===================================================================== */
DECLARE @d NVARCHAR(MAX), @b1 NVARCHAR(MAX), @b2 NVARCHAR(MAX);

SELECT @d = m.definition
FROM   sys.sql_modules m JOIN sys.triggers t ON t.object_id = m.object_id
WHERE  t.parent_id = OBJECT_ID('CI.KZN_PEDRAVISAOCONSOLIDADA') AND t.name = 'TR_KZN_PVC_UPD';

IF @d IS NULL
    RAISERROR('E3 pulada: TR_KZN_PVC_UPD nao encontrado.', 10, 1);
ELSE IF @d NOT LIKE '%PCT_DUPLICIDADE%'
    PRINT 'E3 pulada - trigger ja nao cita as colunas.';
ELSE
BEGIN
    SET @b1 = N'
        UNION ALL
        SELECT lm.ID_LOG, ''PCT_DUPLICIDADE'', CONVERT(VARCHAR(300), d.PCT_DUPLICIDADE), CONVERT(VARCHAR(300), i.PCT_DUPLICIDADE)
        FROM inserted i JOIN deleted d ON d.ID_KAIZEN = i.ID_KAIZEN JOIN @logMap lm ON lm.ID_KAIZEN = i.ID_KAIZEN
        WHERE NOT (d.PCT_DUPLICIDADE = i.PCT_DUPLICIDADE OR (d.PCT_DUPLICIDADE IS NULL AND i.PCT_DUPLICIDADE IS NULL))';
    SET @b2 = N'
        UNION ALL
        SELECT lm.ID_LOG, ''ID_DUPLICIDADE'', CONVERT(VARCHAR(300), d.ID_DUPLICIDADE), CONVERT(VARCHAR(300), i.ID_DUPLICIDADE)
        FROM inserted i JOIN deleted d ON d.ID_KAIZEN = i.ID_KAIZEN JOIN @logMap lm ON lm.ID_KAIZEN = i.ID_KAIZEN
        WHERE NOT (d.ID_DUPLICIDADE = i.ID_DUPLICIDADE OR (d.ID_DUPLICIDADE IS NULL AND i.ID_DUPLICIDADE IS NULL))';

    IF CHARINDEX(@b1, @d) = 0 OR CHARINDEX(@b2, @d) = 0
        RAISERROR('E3 NAO aplicada: os blocos de PCT_DUPLICIDADE/ID_DUPLICIDADE nao batem com o corpo do trigger. Remova-os a mao ANTES da E4.', 16, 1);
    ELSE
    BEGIN
        SET @d = REPLACE(REPLACE(@d, @b1, N''), @b2, N'');
        SET @d = STUFF(@d, CHARINDEX('CREATE', @d), 6, 'CREATE OR ALTER');
        SET @d = REPLACE(@d, 'CREATE OR ALTER OR ALTER', 'CREATE OR ALTER');
        EXEC sp_executesql @d;
        PRINT 'E3 ok - trigger sem referencia as colunas removidas.';
    END
END
GO

/* =====================================================================
   E4 - DROP das colunas
   Reconfere o trigger por conta própria: RAISERROR + RETURN encerram
   apenas o batch em que aparecem.
   ===================================================================== */
IF EXISTS (SELECT 1 FROM sys.sql_modules m JOIN sys.triggers t ON t.object_id = m.object_id
           WHERE t.parent_id = OBJECT_ID('CI.KZN_PEDRAVISAOCONSOLIDADA')
             AND m.definition LIKE '%PCT_DUPLICIDADE%')
BEGIN
    RAISERROR('E4 NAO EXECUTADA: ainda ha trigger citando PCT_DUPLICIDADE. As colunas foram PRESERVADAS - resolva a E3 primeiro.', 16, 1);
    RETURN;
END

IF COL_LENGTH('CI.KZN_PEDRAVISAOCONSOLIDADA', 'PCT_DUPLICIDADE') IS NOT NULL
    EXEC sp_executesql N'ALTER TABLE CI.KZN_PEDRAVISAOCONSOLIDADA DROP COLUMN PCT_DUPLICIDADE;';

IF COL_LENGTH('CI.KZN_PEDRAVISAOCONSOLIDADA', 'ID_DUPLICIDADE') IS NOT NULL
    EXEC sp_executesql N'ALTER TABLE CI.KZN_PEDRAVISAOCONSOLIDADA DROP COLUMN ID_DUPLICIDADE;';

PRINT 'E4 ok - PCT_DUPLICIDADE e ID_DUPLICIDADE removidas da PVC.';
GO

/* =====================================================================
   E5 - CONFERÊNCIA
   ===================================================================== */
SELECT COLUNAS_PVC_RESTANTES = COUNT(*),
       AINDA_TEM_DUPLICIDADE = CASE WHEN SUM(CASE WHEN name IN ('PCT_DUPLICIDADE','ID_DUPLICIDADE') THEN 1 ELSE 0 END) > 0 THEN 'SIM' ELSE 'NAO' END
FROM   sys.columns WHERE object_id = OBJECT_ID('CI.KZN_PEDRAVISAOCONSOLIDADA');

SELECT COLUNA = c.name,
       TIPO = ty.name + CASE WHEN ty.name = 'varchar' THEN '(' + CAST(c.max_length AS VARCHAR(10)) + ')'
                             WHEN ty.name = 'datetime2' THEN '(' + CAST(c.scale AS VARCHAR(10)) + ')' ELSE '' END,
       NULO = CASE WHEN c.is_nullable = 1 THEN 'SIM' ELSE 'NAO' END
FROM   sys.columns c JOIN sys.types ty ON ty.user_type_id = c.user_type_id
WHERE  c.object_id = OBJECT_ID('CI.KZN_ANALISE_DUPLICIDADE')
ORDER BY c.column_id;

SELECT LINHAS_MIGRADAS = COUNT(*) FROM CI.KZN_ANALISE_DUPLICIDADE;
GO
