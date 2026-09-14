/* =====================================================================
   Remove a coluna URL_ICONE de CI.KZN_RESULTADO_KAIZEN
   ---------------------------------------------------------------------
   A tabela passa de 4 para 3 colunas:
       ID_KAIZEN, ID_RESULTADO, DT_ATUALIZACAO

   URL_ICONE existia aqui como "override por ocorrencia": a ideia era
   permitir que um Kaizen especifico sobrescrevesse o icone padrao do
   resultado, que vive em CI.KZN_RESULTADOS.URL_ICONE. Esse override
   nunca foi usado (ver ESCOPO abaixo) e a coluna sai.

   O icone padrao de cada resultado CONTINUA existindo, intacto, em
   CI.KZN_RESULTADOS.URL_ICONE - esta remocao nao toca naquela tabela.

   ---------------------------------------------------------------------
   IMPACTO NA APLICACAO: NENHUM

   Diferente da remocao de DT_CRIACAO, esta e transparente. O server.js
   referencia CI.KZN_RESULTADO_KAIZEN em apenas 2 consultas, e nenhuma
   das duas toca em URL_ICONE:

     - o INSERT de resultados do Kaizen lista explicitamente
       (ID_KAIZEN, ID_RESULTADO, DT_ATUALIZACAO) - nunca gravou a coluna;
     - a leitura busca NM_RESULTADO/DS_RESULTADO de CI.KZN_RESULTADOS
       (a tabela mestre), nao o override.

   As dezenas de outras mencoes a URL_ICONE no server.js sao do CRUD
   generico dos cadastros de dominio (KZN_IDIOMA, KZN_CATEGORIA,
   KZN_REPLICACAO, KZN_DESPERDICIO, KZN_RESULTADOS, KZN_MOEDA,
   KZN_STATUS) e nao passam por esta tabela.

   O trigger TR_KZN_RESULTADO_KAIZEN_UPD tambem NAO cita a coluna (so
   DT_ATUALIZACAO e a PK), entao nao precisa ser recriado - nao ha aqui
   a janela de "trigger citando coluna inexistente" que produziu os erros
   "Invalid column name 'ID_MOTIVO'" numa rodada anterior.

   ---------------------------------------------------------------------
   PROTECAO CONTRA PERDA SILENCIOSA DE DADO

   A expectativa e que a coluna esteja 100% NULL, ja que a aplicacao
   nunca a gravou. O script CONFERE isso em vez de supor:

     - se estiver toda NULL, remove a coluna sem friccao;
     - se houver QUALQUER valor preenchido, PARA e mostra as linhas
       afetadas, sem remover nada. Para seguir mesmo assim (ciente de que
       esses valores serao perdidos), troque o @CONFIRMA_PERDA abaixo
       para 1.

   E IDEMPOTENTE: se a coluna ja tiver sido removida, o script avisa e
   nao executa nada.

   Schema: 'ci' (AZURE_SQL_SCHEMA em app.yaml).
   ===================================================================== */

SET NOCOUNT ON;
SET XACT_ABORT ON;

/* =====================================================================
   E1 - INSPECAO: o que existe na coluna hoje
   ===================================================================== */
IF OBJECT_ID('CI.KZN_RESULTADO_KAIZEN', 'U') IS NULL
BEGIN
    RAISERROR('Abortado: CI.KZN_RESULTADO_KAIZEN nao existe neste banco.', 16, 1);
    RETURN;
END

IF NOT EXISTS (SELECT 1 FROM sys.columns
               WHERE object_id = OBJECT_ID('CI.KZN_RESULTADO_KAIZEN') AND name = 'URL_ICONE')
BEGIN
    PRINT 'Nada a fazer - URL_ICONE ja foi removida de CI.KZN_RESULTADO_KAIZEN.';
    RETURN;
END

DECLARE @preenchidas INT;
EXEC sp_executesql
    N'SELECT @qt = COUNT(*) FROM CI.KZN_RESULTADO_KAIZEN WHERE URL_ICONE IS NOT NULL;',
    N'@qt INT OUTPUT', @qt = @preenchidas OUTPUT;

PRINT 'E1 - linhas com URL_ICONE preenchida: ' + CAST(@preenchidas AS VARCHAR(10)) + '.';

IF @preenchidas > 0
    EXEC sp_executesql
        N'SELECT TOP (50) ID_KAIZEN, ID_RESULTADO, URL_ICONE
          FROM   CI.KZN_RESULTADO_KAIZEN
          WHERE  URL_ICONE IS NOT NULL
          ORDER BY ID_KAIZEN, ID_RESULTADO;';
GO

/* =====================================================================
   E2 - REMOCAO
   ---------------------------------------------------------------------
   As pre-condicoes sao reconferidas aqui, e nao so na E1: RAISERROR +
   RETURN encerram apenas o BATCH em que aparecem - os batches seguintes
   continuam rodando. Uma checagem feita num batch anterior nao protege
   este.
   ===================================================================== */

/* <<< AJUSTAR se a E1 encontrar valores preenchidos e voce quiser
       remove-los mesmo assim. 0 = protege os dados (padrao). >>> */
DECLARE @CONFIRMA_PERDA BIT = 0;

DECLARE @sql NVARCHAR(MAX), @nome SYSNAME, @qtPreenchidas INT, @qtIdx INT;

IF NOT EXISTS (SELECT 1 FROM sys.columns
               WHERE object_id = OBJECT_ID('CI.KZN_RESULTADO_KAIZEN') AND name = 'URL_ICONE')
BEGIN
    PRINT 'E2 pulada - URL_ICONE ja nao existe.';
    RETURN;
END

EXEC sp_executesql
    N'SELECT @qt = COUNT(*) FROM CI.KZN_RESULTADO_KAIZEN WHERE URL_ICONE IS NOT NULL;',
    N'@qt INT OUTPUT', @qt = @qtPreenchidas OUTPUT;

IF @qtPreenchidas > 0 AND @CONFIRMA_PERDA = 0
BEGIN
    RAISERROR('E2 NAO EXECUTADA: %d linha(s) tem URL_ICONE preenchida (listadas na E1) e seriam perdidas. A coluna foi PRESERVADA. Se esses valores nao importam, troque @CONFIRMA_PERDA para 1 e rode de novo.', 16, 1, @qtPreenchidas);
    RETURN;
END

/* DEFAULT da coluna: nome descoberto por metadados. O DDL de referencia
   nao declara DEFAULT aqui, mas em bancos migrados a mao pode existir. */
SELECT @nome = dc.name
FROM   sys.default_constraints dc
WHERE  dc.parent_object_id = OBJECT_ID('CI.KZN_RESULTADO_KAIZEN')
  AND  dc.parent_column_id = COLUMNPROPERTY(OBJECT_ID('CI.KZN_RESULTADO_KAIZEN'), 'URL_ICONE', 'ColumnId');

IF @nome IS NOT NULL
BEGIN
    SET @sql = N'ALTER TABLE CI.KZN_RESULTADO_KAIZEN DROP CONSTRAINT ' + QUOTENAME(@nome) + N';';
    EXEC sp_executesql @sql;
    PRINT '  E2.1 ok - DEFAULT ' + @nome + ' removido.';
END
ELSE
    PRINT '  E2.1 - nenhum DEFAULT em URL_ICONE.';

/* Indices que usem a coluna (chave ou INCLUDE) impediriam o DROP COLUMN. */
DECLARE @idx TABLE (SEQ INT IDENTITY(1,1) PRIMARY KEY, NOME SYSNAME);
INSERT INTO @idx (NOME)
SELECT DISTINCT i.name
FROM   sys.indexes i
JOIN   sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id
WHERE  i.object_id = OBJECT_ID('CI.KZN_RESULTADO_KAIZEN')
  AND  i.is_primary_key = 0 AND i.is_unique_constraint = 0 AND i.name IS NOT NULL
  AND  ic.column_id = COLUMNPROPERTY(OBJECT_ID('CI.KZN_RESULTADO_KAIZEN'), 'URL_ICONE', 'ColumnId');

SELECT @qtIdx = ISNULL(MAX(SEQ), 0) FROM @idx;

DECLARE @i INT = 1;
WHILE @i <= @qtIdx
BEGIN
    SELECT @nome = NOME FROM @idx WHERE SEQ = @i;
    SET @sql = N'DROP INDEX ' + QUOTENAME(@nome) + N' ON CI.KZN_RESULTADO_KAIZEN;';
    EXEC sp_executesql @sql;
    PRINT '  E2.2 ok - indice ' + @nome + ' removido (usava URL_ICONE).';
    SET @i += 1;
END
IF @qtIdx = 0 PRINT '  E2.2 - nenhum indice usava URL_ICONE.';

/* A coluna. SQL dinamico: numa 2a execucao ela ja nao existe, e a
   referencia estatica quebraria a compilacao do batch inteiro. */
EXEC sp_executesql N'ALTER TABLE CI.KZN_RESULTADO_KAIZEN DROP COLUMN URL_ICONE;';
PRINT '  E2.3 ok - coluna URL_ICONE removida. A tabela agora tem 3 colunas.';
GO

/* =====================================================================
   E3 - CONFERENCIA
   ===================================================================== */
SELECT  POSICAO = c.column_id,
        COLUNA  = c.name,
        TIPO    = ty.name
                  + CASE WHEN ty.name = 'varchar'   THEN '(' + CAST(c.max_length AS VARCHAR(10)) + ')'
                         WHEN ty.name = 'datetime2' THEN '(' + CAST(c.scale AS VARCHAR(10)) + ')'
                         ELSE '' END,
        NULO    = CASE WHEN c.is_nullable = 1 THEN 'SIM' ELSE 'NAO' END
FROM        sys.columns c
JOIN        sys.types  ty ON ty.user_type_id = c.user_type_id
WHERE       c.object_id = OBJECT_ID('CI.KZN_RESULTADO_KAIZEN')
ORDER BY    c.column_id;

SELECT  LINHAS_PRESERVADAS = COUNT(*) FROM CI.KZN_RESULTADO_KAIZEN;

/* O icone padrao de cada resultado continua em CI.KZN_RESULTADOS. */
SELECT  RESULTADOS_COM_ICONE_PADRAO = COUNT(*)
FROM    CI.KZN_RESULTADOS
WHERE   URL_ICONE IS NOT NULL;
GO
