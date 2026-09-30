/* =====================================================================
   06a - REMOVER USUÁRIO DE LEITURA  (executar no BDIBPBMSA_PRD, depois do 06)
   ===================================================================== */

SET NOCOUNT ON;

DECLARE @USUARIO SYSNAME = N'mig_ci_leitura';

IF DB_NAME() <> N'BDIBPBMSA_PRD'
BEGIN
    RAISERROR('Abortado: execute no BDIBPBMSA_PRD.', 16, 1);
    RETURN;
END

IF DATABASE_PRINCIPAL_ID(@USUARIO) IS NOT NULL
BEGIN
    DECLARE @sql NVARCHAR(MAX) = N'DROP USER ' + QUOTENAME(@USUARIO) + N';';
    EXEC (@sql);
END

SELECT USUARIO_REMOVIDO = @USUARIO, AINDA_EXISTE = CASE WHEN DATABASE_PRINCIPAL_ID(@USUARIO) IS NULL THEN 'NAO' ELSE 'SIM' END;
GO
