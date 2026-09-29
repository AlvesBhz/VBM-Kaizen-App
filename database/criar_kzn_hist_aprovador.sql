/* =====================================================================
   CI.KZN_HIST_APROVADOR + FK de CI.KZN_HIST_PEDRAVISAOCONSOLIDADA
   ---------------------------------------------------------------------
   Os ID_APROVADOR do historico (10001-10367) sao do sistema legado e nao
   existem em CI.KZN_APROVADOR — por isso a HIST ganha o proprio cadastro.

   ESTRUTURA: mesmas colunas de CI.KZN_APROVADOR, com duas diferencas:
     - CD_MATRICULA e ID_USUARIO NULL-aveis: a planilha nao traz os dados
       do aprovador, so o ID. Ficam NULL ate haver fonte.
     - Sem FK para CI.KZN_MDM_HIERARQUIA: aprovador historico pode nao
       existir mais no MDM atual.

   DADOS: os IDs sao os que JA ESTAO em KZN_HIST_PEDRAVISAOCONSOLIDADA
   (nada inventado). Nesta planilha: 368 aprovadores.

   ID_APROVADOR = 0: 608 Kaizens trazem 0, marcador de "sem aprovador" do
   legado (todo ID real e >= 10001). Uma FK nao aceita 0 sem um aprovador
   0 ficticio. Com @ZERO_VIRA_NULL = 1 (padrao) o 0 vira NULL, que e o que
   a producao usa para "ainda sem aprovador". Com 0, o script ABORTA
   listando a quantidade, sem alterar nada.

   Idempotente. Transacionado. So toca CI.KZN_HIST_*. Schema: 'ci'.
   ===================================================================== */

SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @ZERO_VIRA_NULL BIT = 1;   -- 0 = aborta se houver ID_APROVADOR = 0
DECLARE @qt INT, @sql NVARCHAR(MAX);

/* =====================================================================
   E0 - PRE-CHECAGENS
   ===================================================================== */
IF OBJECT_ID('CI.KZN_HIST_PEDRAVISAOCONSOLIDADA', 'U') IS NULL
BEGIN
    RAISERROR('Abortado: CI.KZN_HIST_PEDRAVISAOCONSOLIDADA nao existe.', 16, 1);
    RETURN;
END

IF NOT EXISTS (SELECT 1 FROM sys.columns c JOIN sys.types t ON t.user_type_id = c.user_type_id
               WHERE c.object_id = OBJECT_ID('CI.KZN_HIST_PEDRAVISAOCONSOLIDADA')
                 AND c.name = 'ID_APROVADOR' AND t.name = 'int')
BEGIN
    RAISERROR('Abortado: KZN_HIST_PEDRAVISAOCONSOLIDADA.ID_APROVADOR nao existe ou nao e INT.', 16, 1);
    RETURN;
END

SELECT @qt = COUNT(*) FROM CI.KZN_HIST_PEDRAVISAOCONSOLIDADA WHERE ID_APROVADOR = 0;
IF @qt > 0 AND @ZERO_VIRA_NULL = 0
BEGIN
    DECLARE @m NVARCHAR(300) = 'Abortado: ' + CAST(@qt AS VARCHAR(10))
        + ' Kaizen(s) com ID_APROVADOR = 0. Troque @ZERO_VIRA_NULL para 1 para grava-los como NULL.';
    RAISERROR(@m, 16, 1);
    RETURN;
END

/* Sem GO ate o fim: RAISERROR + RETURN so encerram o batch em que
   aparecem. */

BEGIN TRANSACTION;
BEGIN TRY

    /* =================================================================
       E1 - TABELA
       ================================================================= */
    IF OBJECT_ID('CI.KZN_HIST_APROVADOR', 'U') IS NULL
    BEGIN
        CREATE TABLE CI.KZN_HIST_APROVADOR
        (
            ID_APROVADOR    INT             NOT NULL,
            CD_MATRICULA    VARCHAR(30)         NULL,   -- sem fonte na planilha
            SG_ATIVO        VARCHAR(1)      NOT NULL
                CONSTRAINT DF_KZN_HIST_APROVADOR_SG_ATIVO DEFAULT ('S'),
            ID_USUARIO      INT                 NULL,   -- sem fonte na planilha
            DT_ATUALIZACAO  DATETIME2(3)    NOT NULL
                CONSTRAINT DF_KZN_HIST_APROVADOR_DT_ATUALIZACAO DEFAULT (SYSDATETIME()),

            CONSTRAINT PK_KZN_HIST_APROVADOR PRIMARY KEY CLUSTERED (ID_APROVADOR)
        );
        PRINT 'E1 - CI.KZN_HIST_APROVADOR criada.';
    END
    ELSE PRINT 'E1 - CI.KZN_HIST_APROVADOR ja existe.';

    /* =================================================================
       E2 - ID_APROVADOR = 0 -> NULL
       ================================================================= */
    UPDATE CI.KZN_HIST_PEDRAVISAOCONSOLIDADA SET ID_APROVADOR = NULL WHERE ID_APROVADOR = 0;
    PRINT 'E2 - ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' Kaizen(s) com ID_APROVADOR 0 gravados como NULL.';

    /* =================================================================
       E3 - CARGA: IDs ja usados no historico
       Dinamico: a tabela pode ter sido criada neste mesmo batch.
       ================================================================= */
    SET @sql = N'
    INSERT INTO CI.KZN_HIST_APROVADOR (ID_APROVADOR)
    SELECT DISTINCT p.ID_APROVADOR
    FROM   CI.KZN_HIST_PEDRAVISAOCONSOLIDADA p
    WHERE  p.ID_APROVADOR IS NOT NULL
      AND  NOT EXISTS (SELECT 1 FROM CI.KZN_HIST_APROVADOR a WHERE a.ID_APROVADOR = p.ID_APROVADOR);
    SET @c = @@ROWCOUNT;';
    EXEC sp_executesql @sql, N'@c INT OUTPUT', @c = @qt OUTPUT;
    PRINT 'E3 - ' + CAST(@qt AS VARCHAR(10)) + ' aprovador(es) incluido(s).';

    /* =================================================================
       E4 - FK (WITH CHECK: confere as linhas existentes e fica confiavel)
       ================================================================= */
    IF OBJECT_ID('CI.FK_KZN_HIST_PVC_APROVADOR', 'F') IS NULL
    BEGIN
        SET @sql = N'ALTER TABLE CI.KZN_HIST_PEDRAVISAOCONSOLIDADA WITH CHECK
            ADD CONSTRAINT FK_KZN_HIST_PVC_APROVADOR FOREIGN KEY (ID_APROVADOR)
            REFERENCES CI.KZN_HIST_APROVADOR (ID_APROVADOR);';
        EXEC sp_executesql @sql;
        PRINT 'E4 - FK_KZN_HIST_PVC_APROVADOR criada.';
    END
    ELSE PRINT 'E4 - FK_KZN_HIST_PVC_APROVADOR ja existe.';

    COMMIT TRANSACTION;
    PRINT 'Concluido.';
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    PRINT 'ERRO - nada foi alterado (rollback aplicado): ' + ERROR_MESSAGE();
    THROW;
END CATCH
GO

/* =====================================================================
   E5 - CONFERENCIA
   ===================================================================== */
SELECT  APROVADORES      = (SELECT COUNT(*) FROM CI.KZN_HIST_APROVADOR),
        KAIZENS_COM_APROVADOR = (SELECT COUNT(*) FROM CI.KZN_HIST_PEDRAVISAOCONSOLIDADA WHERE ID_APROVADOR IS NOT NULL),
        KAIZENS_SEM_APROVADOR = (SELECT COUNT(*) FROM CI.KZN_HIST_PEDRAVISAOCONSOLIDADA WHERE ID_APROVADOR IS NULL),
        ORFAOS           = (SELECT COUNT(*) FROM CI.KZN_HIST_PEDRAVISAOCONSOLIDADA p
                            WHERE p.ID_APROVADOR IS NOT NULL
                              AND NOT EXISTS (SELECT 1 FROM CI.KZN_HIST_APROVADOR a WHERE a.ID_APROVADOR = p.ID_APROVADOR));

SELECT  FK = name, CONFIAVEL = CASE WHEN is_not_trusted = 0 THEN 'SIM' ELSE 'NAO' END
FROM    sys.foreign_keys
WHERE   name = 'FK_KZN_HIST_PVC_APROVADOR';
GO
