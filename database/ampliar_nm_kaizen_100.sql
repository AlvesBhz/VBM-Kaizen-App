/* =====================================================================
   Amplia NM_KAIZEN de VARCHAR(30) para VARCHAR(100)
   em CI.KZN_PEDRAVISAOCONSOLIDADA
   ---------------------------------------------------------------------
   Mudanca de escopo minimo: SO o tamanho da coluna. Nulidade, nome,
   posicao, indices, constraints e dados permanecem exatamente como
   estao.

   E SO AMPLIACAO - nenhum dado e truncado ou perdido. Titulos ja
   gravados continuam identicos; a coluna apenas passa a aceitar textos
   maiores.

   NOT NULL e repetido de proposito no ALTER COLUMN: no SQL Server, um
   ALTER COLUMN que omite a nulidade torna a coluna NULL-avel. Como
   NM_KAIZEN e NOT NULL, omitir isso mudaria a nulidade sem querer.

   E IDEMPOTENTE: se a coluna ja estiver com 100 (ou mais), o script
   avisa e nao executa nada.

   ---------------------------------------------------------------------
   ATENCAO - A APLICACAO AINDA LIMITA O TITULO EM 30

   Ampliar a coluna NAO libera titulos maiores sozinho. O server.js
   valida e trunca antes do banco:

     - PVC_LIMITES.NM_KAIZEN = 30 (server.js), usado em
       maxLen(titulo, PVC_LIMITES.NM_KAIZEN, "Titulo do Kaizen") - o
       cadastro REJEITA titulos com mais de 30 caracteres;
     - sql.NVarChar(PVC_LIMITES.NM_KAIZEN) no INSERT, que trunca o
       parametro em 30 antes de enviar.

   Enquanto PVC_LIMITES.NM_KAIZEN nao virar 100, a coluna maior fica sem
   efeito pratico. O ajuste no server.js precisa acompanhar este script.

   ---------------------------------------------------------------------
   NAO ha indice sobre NM_KAIZEN nesta tabela (os indices existentes sao
   IX_KZN_PVC_STATUS, IX_KZN_PVC_CATEGORIA e IX_KZN_PVC_USUARIO_LIDER),
   entao o ALTER COLUMN nao esbarra em nenhum. A etapa E1 confere isso
   no proprio banco em vez de confiar nesta nota - se algum indice
   aparecer, o script para em vez de falhar no meio.

   Schema: 'ci' (AZURE_SQL_SCHEMA em app.yaml).
   ===================================================================== */

SET NOCOUNT ON;
SET XACT_ABORT ON;

/* =====================================================================
   E1 - PRE-CHECAGENS
   ===================================================================== */
IF OBJECT_ID('CI.KZN_PEDRAVISAOCONSOLIDADA', 'U') IS NULL
BEGIN
    RAISERROR('Abortado: CI.KZN_PEDRAVISAOCONSOLIDADA nao existe neste banco.', 16, 1);
    RETURN;
END

IF NOT EXISTS (SELECT 1 FROM sys.columns
               WHERE object_id = OBJECT_ID('CI.KZN_PEDRAVISAOCONSOLIDADA') AND name = 'NM_KAIZEN')
BEGIN
    RAISERROR('Abortado: a coluna NM_KAIZEN nao existe em CI.KZN_PEDRAVISAOCONSOLIDADA.', 16, 1);
    RETURN;
END
GO

/* =====================================================================
   E2 - AMPLIACAO
   ---------------------------------------------------------------------
   A trava de indice e reconferida aqui, e nao so na E1: RAISERROR +
   RETURN encerram apenas o BATCH em que aparecem - os batches seguintes
   continuam rodando. Uma checagem feita num batch anterior nao protege
   este.
   ===================================================================== */
DECLARE @tamAtual INT, @idxComNmKaizen INT;

SELECT @tamAtual = c.max_length
FROM   sys.columns c
WHERE  c.object_id = OBJECT_ID('CI.KZN_PEDRAVISAOCONSOLIDADA') AND c.name = 'NM_KAIZEN';

/* Indices que usem a coluna (chave ou INCLUDE) impediriam o ALTER. */
SELECT @idxComNmKaizen = COUNT(DISTINCT i.name)
FROM   sys.indexes i
JOIN   sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id
WHERE  i.object_id = OBJECT_ID('CI.KZN_PEDRAVISAOCONSOLIDADA')
  AND  i.name IS NOT NULL
  AND  ic.column_id = COLUMNPROPERTY(OBJECT_ID('CI.KZN_PEDRAVISAOCONSOLIDADA'), 'NM_KAIZEN', 'ColumnId');

IF @idxComNmKaizen > 0
BEGIN
    SELECT INDICE_QUE_USA_NM_KAIZEN = i.name
    FROM   sys.indexes i
    JOIN   sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id
    WHERE  i.object_id = OBJECT_ID('CI.KZN_PEDRAVISAOCONSOLIDADA')
      AND  i.name IS NOT NULL
      AND  ic.column_id = COLUMNPROPERTY(OBJECT_ID('CI.KZN_PEDRAVISAOCONSOLIDADA'), 'NM_KAIZEN', 'ColumnId')
    GROUP BY i.name;

    RAISERROR('Abortado: %d indice(s) usam NM_KAIZEN (lista acima) e precisariam ser removidos e recriados. NADA foi alterado.', 16, 1, @idxComNmKaizen);
    RETURN;
END

IF @tamAtual >= 100
BEGIN
    PRINT 'Nada a fazer - NM_KAIZEN ja tem VARCHAR(' + CAST(@tamAtual AS VARCHAR(10)) + ').';
    RETURN;
END

PRINT 'Ampliando NM_KAIZEN de VARCHAR(' + CAST(@tamAtual AS VARCHAR(10)) + ') para VARCHAR(100)...';

ALTER TABLE CI.KZN_PEDRAVISAOCONSOLIDADA ALTER COLUMN NM_KAIZEN VARCHAR(100) NOT NULL;

PRINT 'E2 ok - NM_KAIZEN agora e VARCHAR(100) NOT NULL.';
GO

/* =====================================================================
   E3 - CONFERENCIA
   ===================================================================== */
SELECT  TABELA  = 'KZN_PEDRAVISAOCONSOLIDADA',
        COLUNA  = c.name,
        TIPO    = ty.name + '(' + CAST(c.max_length AS VARCHAR(10)) + ')',
        NULO    = CASE WHEN c.is_nullable = 1 THEN 'SIM' ELSE 'NAO' END,
        POSICAO = c.column_id
FROM        sys.columns c
JOIN        sys.types  ty ON ty.user_type_id = c.user_type_id
WHERE       c.object_id = OBJECT_ID('CI.KZN_PEDRAVISAOCONSOLIDADA')
  AND       c.name = 'NM_KAIZEN';

/* Nenhum titulo pode ter sido afetado: a operacao so amplia. */
SELECT  TOTAL_KAIZENS       = COUNT(*),
        MAIOR_TITULO_ATUAL  = MAX(LEN(NM_KAIZEN)),
        ACIMA_DE_30         = SUM(CASE WHEN LEN(NM_KAIZEN) > 30 THEN 1 ELSE 0 END)
FROM    CI.KZN_PEDRAVISAOCONSOLIDADA;
GO
