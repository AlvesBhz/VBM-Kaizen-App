/* =====================================================================
   CI.KZN_HIST_PEDRAVISAOCONSOLIDADA — espelha as alterações da PVC
   ---------------------------------------------------------------------
   Efeito líquido das duas últimas rodadas na tabela de produção:

     +  SG_GM           VARCHAR(1)   NOT NULL  DEFAULT ('N')
     +  URL_GM          VARCHAR(300)     NULL
     +  ID_TIPO_KAIZEN  INT          NOT NULL  DEFAULT (0)

   PCT_DUPLICIDADE e ID_DUPLICIDADE foram criadas e depois removidas da
   PVC (foram para CI.KZN_ANALISE_DUPLICIDADE), então NÃO entram aqui. A
   E2 as remove caso tenham sido adicionadas por outro caminho.

   Os DEFAULT são necessários, não decorativos: as duas colunas NOT NULL
   entram numa tabela que pode ter linhas, e um ADD NOT NULL sem DEFAULT
   falharia. Também garantem que o carga_hist_2026_7281_7296.sql continue
   funcionando — ele não lista essas colunas no INSERT, e sem DEFAULT o
   NOT NULL derrubaria a carga.

   Valores ('N' e 0) são os mesmos aplicados na PVC: neutros, escolhidos
   para viabilizar o ALTER, não regra de negócio.

   Idempotente. Só toca CI.KZN_HIST_PEDRAVISAOCONSOLIDADA.
   Schema: 'ci'.
   ===================================================================== */

SET NOCOUNT ON;
SET XACT_ABORT ON;

IF OBJECT_ID('CI.KZN_HIST_PEDRAVISAOCONSOLIDADA', 'U') IS NULL
BEGIN
    RAISERROR('Abortado: CI.KZN_HIST_PEDRAVISAOCONSOLIDADA não existe.', 16, 1);
    RETURN;
END
GO

/* =====================================================================
   E1 - COLUNAS NOVAS
   ===================================================================== */
IF COL_LENGTH('CI.KZN_HIST_PEDRAVISAOCONSOLIDADA', 'SG_GM') IS NULL
    ALTER TABLE CI.KZN_HIST_PEDRAVISAOCONSOLIDADA ADD SG_GM VARCHAR(1) NOT NULL
        CONSTRAINT DF_KZN_HIST_PVC_SG_GM DEFAULT ('N');
GO

IF COL_LENGTH('CI.KZN_HIST_PEDRAVISAOCONSOLIDADA', 'URL_GM') IS NULL
    ALTER TABLE CI.KZN_HIST_PEDRAVISAOCONSOLIDADA ADD URL_GM VARCHAR(300) NULL;
GO

IF COL_LENGTH('CI.KZN_HIST_PEDRAVISAOCONSOLIDADA', 'ID_TIPO_KAIZEN') IS NULL
    ALTER TABLE CI.KZN_HIST_PEDRAVISAOCONSOLIDADA ADD ID_TIPO_KAIZEN INT NOT NULL
        CONSTRAINT DF_KZN_HIST_PVC_ID_TIPO_KAIZEN DEFAULT (0);
GO

PRINT 'E1 ok - SG_GM, URL_GM e ID_TIPO_KAIZEN alinhadas com a PVC.';
GO

/* =====================================================================
   E2 - Remove as colunas de duplicidade, se existirem
   (a PVC não as tem mais; foram para CI.KZN_ANALISE_DUPLICIDADE)
   ===================================================================== */
DECLARE @df SYSNAME, @sql NVARCHAR(MAX), @col SYSNAME, @i INT = 1;
DECLARE @alvos TABLE (ORDEM INT, COLUNA SYSNAME);
INSERT INTO @alvos VALUES (1,'PCT_DUPLICIDADE'), (2,'ID_DUPLICIDADE');

WHILE @i <= 2
BEGIN
    SELECT @col = COLUNA FROM @alvos WHERE ORDEM = @i;

    IF COL_LENGTH('CI.KZN_HIST_PEDRAVISAOCONSOLIDADA', @col) IS NOT NULL
    BEGIN
        SELECT @df = dc.name
        FROM   sys.default_constraints dc
        WHERE  dc.parent_object_id = OBJECT_ID('CI.KZN_HIST_PEDRAVISAOCONSOLIDADA')
          AND  dc.parent_column_id = COLUMNPROPERTY(OBJECT_ID('CI.KZN_HIST_PEDRAVISAOCONSOLIDADA'), @col, 'ColumnId');

        IF @df IS NOT NULL
        BEGIN
            SET @sql = N'ALTER TABLE CI.KZN_HIST_PEDRAVISAOCONSOLIDADA DROP CONSTRAINT ' + QUOTENAME(@df) + N';';
            EXEC sp_executesql @sql;
        END

        SET @sql = N'ALTER TABLE CI.KZN_HIST_PEDRAVISAOCONSOLIDADA DROP COLUMN ' + QUOTENAME(@col) + N';';
        EXEC sp_executesql @sql;
        PRINT '  E2 - ' + @col + ' removida.';
    END

    SET @i += 1;
END
PRINT 'E2 ok.';
GO

/* =====================================================================
   E3 - CONFERÊNCIA: o que ainda diverge entre produção e histórico
   Resultado vazio = estruturas equivalentes.
   ===================================================================== */
SELECT  COLUNA       = ISNULL(p.name, h.name),
        NA_PRODUCAO  = ISNULL(p.tipo, '-- ausente --'),
        NO_HISTORICO = ISNULL(h.tipo, '-- ausente --')
FROM (
    SELECT c.name, tipo = ty.name + CASE WHEN ty.name LIKE '%char%' THEN '(' + CAST(c.max_length AS VARCHAR(10)) + ')' ELSE '' END
    FROM sys.columns c JOIN sys.types ty ON ty.user_type_id = c.user_type_id
    WHERE c.object_id = OBJECT_ID('CI.KZN_PEDRAVISAOCONSOLIDADA')
) p
FULL JOIN (
    SELECT c.name, tipo = ty.name + CASE WHEN ty.name LIKE '%char%' THEN '(' + CAST(c.max_length AS VARCHAR(10)) + ')' ELSE '' END
    FROM sys.columns c JOIN sys.types ty ON ty.user_type_id = c.user_type_id
    WHERE c.object_id = OBJECT_ID('CI.KZN_HIST_PEDRAVISAOCONSOLIDADA')
) h ON h.name COLLATE DATABASE_DEFAULT = p.name COLLATE DATABASE_DEFAULT
WHERE   p.name IS NULL OR h.name IS NULL OR p.tipo <> h.tipo
ORDER BY COLUNA;
GO
