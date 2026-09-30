/* =====================================================================
   06 - LIMPEZA  (conectado ao BDIBPBMSA_DEV, depois do 05 APROVADO)
   ---------------------------------------------------------------------
   Remove a ligação com a PRD (tabelas externas, fonte externa, credencial
   e a master key, se foi o 00 que a criou) e o material de trabalho do
   schema MIG. As evidências (MIG.EVIDENCIA, CARGA_LOG, CONTAGEM,
   DIFERENCA, VIOLACAO) ficam, salvo @APAGAR_EVIDENCIAS = 1.
   Não toca no schema CI.
   ===================================================================== */

SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @APAGAR_EVIDENCIAS BIT = 0;

DECLARE @sql NVARCHAR(MAX), @modo VARCHAR(10), @criouMk BIT;
SELECT @modo = MODO, @criouMk = CRIOU_MASTER_KEY FROM MIG.PARAMETRO;

/* Tabelas externas (AZURE) ou views (LOCAL) de leitura da PRD */
SELECT @sql = STRING_AGG(CONVERT(NVARCHAR(MAX),
           CASE WHEN o.type = 'V' THEN N'DROP VIEW ' ELSE N'DROP EXTERNAL TABLE ' END
           + N'MIG_EXT.' + QUOTENAME(o.name) + N';'), NCHAR(10))
FROM sys.objects o WHERE o.schema_id = SCHEMA_ID('MIG_EXT') AND o.type IN ('U', 'V');
IF @sql IS NOT NULL EXEC sp_executesql @sql;
IF SCHEMA_ID('MIG_EXT') IS NOT NULL EXEC (N'DROP SCHEMA MIG_EXT;');

IF EXISTS (SELECT 1 FROM sys.external_data_sources WHERE name = N'MIG_DS_PRD') EXEC (N'DROP EXTERNAL DATA SOURCE MIG_DS_PRD;');
IF EXISTS (SELECT 1 FROM sys.database_scoped_credentials WHERE name = N'MIG_CRED_PRD') EXEC (N'DROP DATABASE SCOPED CREDENTIAL MIG_CRED_PRD;');
IF @criouMk = 1
   AND NOT EXISTS (SELECT 1 FROM sys.database_scoped_credentials)
   AND EXISTS (SELECT 1 FROM sys.symmetric_keys WHERE name = N'##MS_DatabaseMasterKey##')
    EXEC (N'DROP MASTER KEY;');

/* Material de trabalho */
DROP PROCEDURE IF EXISTS MIG.SP_SNAPSHOT, MIG.SP_EXEC_ORIGEM, MIG.SP_EXEC_DESTINO;
DROP TABLE IF EXISTS MIG.CAT_BANCO, MIG.CAT_TABELA, MIG.CAT_COLUNA, MIG.CAT_CHAVE, MIG.CAT_INDICE, MIG.CAT_CHECK,
    MIG.CAT_FK, MIG.CAT_MODULO, MIG.CAT_SEQUENCIA, MIG.CAT_SINONIMO, MIG.CAT_EXTPROP, MIG.CAT_DEPEXT,
    MIG.CAT_PERMISSAO, MIG.ORDEM_CARGA;

IF @APAGAR_EVIDENCIAS = 1
BEGIN
    DROP PROCEDURE IF EXISTS MIG.SP_EVIDENCIA;
    DROP TABLE IF EXISTS MIG.EVIDENCIA, MIG.CARGA_LOG, MIG.CONTAGEM, MIG.DIFERENCA, MIG.VIOLACAO, MIG.PARAMETRO;
    IF SCHEMA_ID('MIG') IS NOT NULL AND NOT EXISTS (SELECT 1 FROM sys.objects WHERE schema_id = SCHEMA_ID('MIG'))
        EXEC (N'DROP SCHEMA MIG;');
END

SELECT RESTANTE = ISNULL(SCHEMA_NAME(schema_id) + N'.' + name, N'-'), TIPO = type_desc
FROM sys.objects WHERE schema_id IN (SCHEMA_ID('MIG'), SCHEMA_ID('MIG_EXT'))
UNION ALL SELECT N'fonte externa ' + name, N'EXTERNAL_DATA_SOURCE' FROM sys.external_data_sources WHERE name = N'MIG_DS_PRD'
UNION ALL SELECT N'credencial ' + name, N'CREDENTIAL' FROM sys.database_scoped_credentials WHERE name = N'MIG_CRED_PRD';
GO
