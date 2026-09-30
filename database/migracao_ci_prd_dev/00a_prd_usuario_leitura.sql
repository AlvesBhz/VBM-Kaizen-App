/* =====================================================================
   00a - USUÁRIO DE LEITURA DA MIGRAÇÃO  (executar no BDIBPBMSA_PRD, por um DBA)
   ---------------------------------------------------------------------
   Elastic Query (00) só aceita autenticação SQL. Em vez de usar um login
   administrativo, este usuário contido no banco só LÊ:
     - SELECT e VIEW DEFINITION no schema CI (dados e DDL);
     - VIEW DEFINITION no banco e SELECT em sys.sql_expression_dependencies
       (dependências de outros schemas que apontam para o CI, permissões,
       políticas de segurança). Sem o SELECT explícito essa view de
       catálogo volta VAZIA para quem não é db_owner — e o mapeamento de
       dependências sairia vazio sem avisar;
     - UNMASK somente se houver coluna com máscara dinâmica no CI — sem
       ele o dado copiado seria o mascarado.
   Nada é gravado na PRD pela migração. Remover ao final com o 06a.
   ===================================================================== */

SET NOCOUNT ON;

DECLARE @USUARIO SYSNAME       = N'mig_ci_leitura';
DECLARE @SENHA   NVARCHAR(256) = N'<senha forte, a mesma de @SENHA_ORIGEM no 00>';

IF @SENHA LIKE N'<%'
BEGIN
    RAISERROR('Abortado: preencha @SENHA.', 16, 1);
    RETURN;
END
IF DB_NAME() <> N'BDIBPBMSA_PRD'
BEGIN
    RAISERROR('Abortado: execute no BDIBPBMSA_PRD.', 16, 1);
    RETURN;
END

DECLARE @sql NVARCHAR(MAX);
IF DATABASE_PRINCIPAL_ID(@USUARIO) IS NULL
BEGIN
    SET @sql = N'CREATE USER ' + QUOTENAME(@USUARIO) + N' WITH PASSWORD = ' + QUOTENAME(@SENHA, '''') + N';';
    EXEC (@sql);
END

SET @sql = N'GRANT SELECT, VIEW DEFINITION ON SCHEMA::CI TO ' + QUOTENAME(@USUARIO) + N';'
         + N' GRANT VIEW DEFINITION TO ' + QUOTENAME(@USUARIO) + N';'
         + N' GRANT SELECT ON sys.sql_expression_dependencies TO ' + QUOTENAME(@USUARIO) + N';';
EXEC (@sql);

IF EXISTS (SELECT 1 FROM sys.masked_columns mc JOIN sys.objects o ON o.object_id = mc.object_id WHERE o.schema_id = SCHEMA_ID(N'CI'))
BEGIN
    SET @sql = N'GRANT UNMASK ON SCHEMA::CI TO ' + QUOTENAME(@USUARIO) + N';';
    EXEC (@sql);
END

SELECT USUARIO = dp.name, PERMISSAO = p.permission_name, ESCOPO = p.class_desc,
       OBJETO = CASE WHEN p.class = 3 THEN SCHEMA_NAME(p.major_id) ELSE DB_NAME() END
FROM sys.database_principals dp JOIN sys.database_permissions p ON p.grantee_principal_id = dp.principal_id
WHERE dp.name = @USUARIO;
GO
