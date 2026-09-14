/* =====================================================================
   VBM Kaizen — conserta as FOREIGN KEYS de ci.kzn_kaizen_hierarquia
   =====================================================================

   ATENÇÃO: com @APLICAR = 1 este script ALTERA CONSTRAINTS em produção.
   Para apenas ver o diagnóstico sem mexer em nada, troque para 0 e
   execute; nada é alterado e o relatório sai igual.

   Ele só mexe no que estiver comprovadamente errado. Constraint já
   correta é deixada em paz, e o script pode ser executado de novo sem
   efeito.

   O PROBLEMA
   ----------
   Um MERGE que lê o ID_KAIZEN de DENTRO de ci.kzn_pedravisaoconsolidada
   foi recusado por uma FK que referencia essa mesma coluna:

     Msg 547 ... "FK_KZN_KAIZEN_HIERARQUIA_KAIZEN" ... table
     "CI.KZN_PEDRAVISAOCONSOLIDADA", column 'ID_KAIZEN'.

   Um valor tirado da própria tabela referenciada não pode faltar nela.
   A explicação é que a constraint confere OUTRA coluna contra
   PEDRAVISAOCONSOLIDADA.ID_KAIZEN — o candidato é ID_USUARIO_LIDER,
   porque ID_KAIZEN é a única coluna única daquela tabela e quem montou
   a FK provavelmente foi levado a ela. Resultado: o líder 181222 passa
   a ser cobrado como se tivesse de existir um Kaizen de número 181222.

   O DESENHO CORRETO
   -----------------
   Os VALORES vêm de onde o app já os lê:
     ID_KAIZEN         <- ci.kzn_pedravisaoconsolidada.ID_KAIZEN
     ID_USUARIO_LIDER  <- ci.kzn_pedravisaoconsolidada.ID_USUARIO_LIDER
     NM_HIERARQUIA_N1..N8 <- ci.kzn_mdm_hierarquia

   As REFERÊNCIAS, porém, não podem as duas apontar para a PVC:
   ID_USUARIO_LIDER não é coluna única lá, e não dá para referenciar
   coluna não única. O alvo natural dele é ci.kzn_mdm_hierarquia
   (ID_USUARIO) — que é de onde aquele número vem originalmente, e é o
   mesmo alvo da FK equivalente na própria PVC.

     ID_KAIZEN        -> ci.kzn_pedravisaoconsolidada (ID_KAIZEN)
     ID_USUARIO_LIDER -> ci.kzn_mdm_hierarquia        (ID_USUARIO)
   ===================================================================== */

SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @APLICAR bit = 1;   /* 0 = só relatório, não altera nada */

/* ---------------------------------------------------------------------
   ANTES — como está hoje. Guarde esta saída: é com ela que se desfaz a
   alteração, se algum dia for preciso.
   --------------------------------------------------------------------- */
PRINT '=== FKs de ci.kzn_kaizen_hierarquia ANTES ===';

SELECT  fk.name AS CONSTRAINT_NAME,
        cp.name AS COLUNA,
        OBJECT_SCHEMA_NAME(fk.referenced_object_id) + '.'
          + OBJECT_NAME(fk.referenced_object_id) AS REFERENCIA,
        cr.name AS COLUNA_REFERENCIADA
  FROM sys.foreign_keys fk
  JOIN sys.foreign_key_columns fkc ON fkc.constraint_object_id = fk.object_id
  JOIN sys.columns cp ON cp.object_id = fkc.parent_object_id AND cp.column_id = fkc.parent_column_id
  JOIN sys.columns cr ON cr.object_id = fkc.referenced_object_id AND cr.column_id = fkc.referenced_column_id
 WHERE fk.parent_object_id = OBJECT_ID('ci.kzn_kaizen_hierarquia')
 ORDER BY fk.name;

/* ---------------------------------------------------------------------
   Identifica, por COLUNA, a constraint que está fora do lugar.
   Só considera FK de coluna única — uma composta seria outro desenho e
   é apenas relatada, nunca mexida.
   --------------------------------------------------------------------- */
DECLARE @fkKaizen  sysname, @fkKaizenOk  bit = 0,
        @fkLider   sysname, @fkLiderOk   bit = 0;

;WITH fks AS (
  SELECT fk.name AS nome, cp.name AS coluna,
         OBJECT_SCHEMA_NAME(fk.referenced_object_id) + '.' + OBJECT_NAME(fk.referenced_object_id) AS ref,
         cr.name AS refcol,
         COUNT(*) OVER (PARTITION BY fk.object_id) AS qtd_colunas
    FROM sys.foreign_keys fk
    JOIN sys.foreign_key_columns fkc ON fkc.constraint_object_id = fk.object_id
    JOIN sys.columns cp ON cp.object_id = fkc.parent_object_id AND cp.column_id = fkc.parent_column_id
    JOIN sys.columns cr ON cr.object_id = fkc.referenced_object_id AND cr.column_id = fkc.referenced_column_id
   WHERE fk.parent_object_id = OBJECT_ID('ci.kzn_kaizen_hierarquia')
)
SELECT @fkKaizen = MAX(CASE WHEN coluna = 'ID_KAIZEN'        AND qtd_colunas = 1 THEN nome END),
       @fkLider  = MAX(CASE WHEN coluna = 'ID_USUARIO_LIDER' AND qtd_colunas = 1 THEN nome END),
       @fkKaizenOk = MAX(CASE WHEN coluna = 'ID_KAIZEN' AND qtd_colunas = 1
                               AND ref = 'ci.kzn_pedravisaoconsolidada' AND refcol = 'ID_KAIZEN'
                              THEN 1 ELSE 0 END),
       @fkLiderOk  = MAX(CASE WHEN coluna = 'ID_USUARIO_LIDER' AND qtd_colunas = 1
                               AND ref = 'ci.kzn_mdm_hierarquia' AND refcol = 'ID_USUARIO'
                              THEN 1 ELSE 0 END)
  FROM fks;

PRINT CONCAT('ID_KAIZEN        -> ', CASE WHEN @fkKaizenOk = 1 THEN 'correta' ELSE 'PRECISA CORRIGIR' END,
             ' (constraint: ', ISNULL(@fkKaizen, '<nenhuma>'), ')');
PRINT CONCAT('ID_USUARIO_LIDER -> ', CASE WHEN @fkLiderOk  = 1 THEN 'correta' ELSE 'PRECISA CORRIGIR' END,
             ' (constraint: ', ISNULL(@fkLider,  '<nenhuma>'), ')');

IF @APLICAR = 0
BEGIN
    PRINT '';
    PRINT '@APLICAR = 0: nada foi alterado. Troque para 1 para aplicar.';
    RETURN;
END

/* ---------------------------------------------------------------------
   Pré-condição: só dá para referenciar coluna com índice único. Se
   kzn_mdm_hierarquia.ID_USUARIO não for PK/único, a FK do líder não
   pode ser criada — nesse caso ela é apenas REMOVIDA, e o app continua
   gravando normalmente (quem garante o valor é a própria PVC).
   --------------------------------------------------------------------- */
DECLARE @mdmUnico bit = 0;
SELECT @mdmUnico = 1
  FROM sys.indexes i
  JOIN sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id
  JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
 WHERE i.object_id = OBJECT_ID('ci.kzn_mdm_hierarquia')
   AND (i.is_primary_key = 1 OR i.is_unique = 1)
   AND c.name = 'ID_USUARIO'
   AND (SELECT COUNT(*) FROM sys.index_columns x
         WHERE x.object_id = i.object_id AND x.index_id = i.index_id AND x.key_ordinal > 0) = 1;

DECLARE @cmd nvarchar(max);

BEGIN TRAN;

/* --- ID_KAIZEN --- */
IF @fkKaizenOk = 0
BEGIN
    IF @fkKaizen IS NOT NULL
    BEGIN
        SET @cmd = 'ALTER TABLE ci.kzn_kaizen_hierarquia DROP CONSTRAINT ' + QUOTENAME(@fkKaizen) + ';';
        PRINT @cmd; EXEC sys.sp_executesql @cmd;
    END
    SET @cmd = 'ALTER TABLE ci.kzn_kaizen_hierarquia WITH CHECK
                  ADD CONSTRAINT FK_KZN_KAIZEN_HIERARQUIA_KAIZEN
                      FOREIGN KEY (ID_KAIZEN)
                      REFERENCES ci.kzn_pedravisaoconsolidada (ID_KAIZEN);';
    PRINT @cmd; EXEC sys.sp_executesql @cmd;
END

/* --- ID_USUARIO_LIDER --- */
IF @fkLiderOk = 0
BEGIN
    IF @fkLider IS NOT NULL
    BEGIN
        SET @cmd = 'ALTER TABLE ci.kzn_kaizen_hierarquia DROP CONSTRAINT ' + QUOTENAME(@fkLider) + ';';
        PRINT @cmd; EXEC sys.sp_executesql @cmd;
    END
    IF @mdmUnico = 1
    BEGIN
        SET @cmd = 'ALTER TABLE ci.kzn_kaizen_hierarquia WITH CHECK
                      ADD CONSTRAINT FK_KZN_KAIZEN_HIERARQUIA_USUARIO
                          FOREIGN KEY (ID_USUARIO_LIDER)
                          REFERENCES ci.kzn_mdm_hierarquia (ID_USUARIO);';
        PRINT @cmd; EXEC sys.sp_executesql @cmd;
    END
    ELSE
        PRINT 'ci.kzn_mdm_hierarquia.ID_USUARIO nao e unico: a FK do lider ficou apenas removida.';
END

COMMIT;

/* ---------------------------------------------------------------------
   DEPOIS — como ficou.
   --------------------------------------------------------------------- */
PRINT '';
PRINT '=== FKs de ci.kzn_kaizen_hierarquia DEPOIS ===';

SELECT  fk.name AS CONSTRAINT_NAME,
        cp.name AS COLUNA,
        OBJECT_SCHEMA_NAME(fk.referenced_object_id) + '.'
          + OBJECT_NAME(fk.referenced_object_id) AS REFERENCIA,
        cr.name AS COLUNA_REFERENCIADA
  FROM sys.foreign_keys fk
  JOIN sys.foreign_key_columns fkc ON fkc.constraint_object_id = fk.object_id
  JOIN sys.columns cp ON cp.object_id = fkc.parent_object_id AND cp.column_id = fkc.parent_column_id
  JOIN sys.columns cr ON cr.object_id = fkc.referenced_object_id AND cr.column_id = fkc.referenced_column_id
 WHERE fk.parent_object_id = OBJECT_ID('ci.kzn_kaizen_hierarquia')
 ORDER BY fk.name;

PRINT 'Agora rode preencher_kaizen_hierarquia.sql e confira com:';
PRINT '  SELECT * FROM ci.kzn_kaizen_hierarquia;';
