/* =====================================================================
   Cria as tabelas de HISTÓRICO (KZN_HIST_*) para carga de dados legados
   ---------------------------------------------------------------------
   Gera uma cópia estrutural de cada tabela da lista abaixo, com as
   colunas de texto ampliadas, e SEM NENHUM VÍNCULO:

       CI.KZN_PEDRAVISAOCONSOLIDADA  -> CI.KZN_HIST_PEDRAVISAOCONSOLIDADA
       CI.KZN_MEMBROS_EQUIPE         -> CI.KZN_HIST_MEMBROS_EQUIPE
       CI.KZN_RESULTADO_KAIZEN       -> CI.KZN_HIST_RESULTADO_KAIZEN
       CI.KZN_KAIZEN_HIERARQUIA      -> CI.KZN_HIST_KAIZEN_HIERARQUIA
       CI.KZN_KAIZEN_DESPERDICIO     -> CI.KZN_HIST_KAIZEN_DESPERDICIO

   ---------------------------------------------------------------------
   O QUE AS TABELAS HIST *NÃO* TÊM — e por quê

   Sem PK, sem FK, sem UNIQUE, sem CHECK, sem índice, sem DEFAULT e sem
   trigger. São tabelas de staging inertes, o formato certo pra subir
   histórico:

     - sem FK: o dado legado não precisa (e muitas vezes não consegue)
       casar com as tabelas de domínio atuais — era o vínculo que
       inviabilizaria a carga;
     - sem PK/UNIQUE: histórico costuma trazer chave repetida ou nula; a
       carga não pode falhar por isso no meio;
     - sem trigger: senão cada INSERT geraria linha de auditoria em
       KZN_LOG_*, poluindo o log com milhares de eventos que nunca
       aconteceram de verdade;
     - sem índice: carga em massa fica mais rápida em heap. Índices, se
       precisar consultar muito, são baratos de criar DEPOIS da carga.

   Estrutura gerada a partir dos METADADOS REAIS (sys.columns), não de
   uma lista fixa — então acompanha o banco mesmo onde ele divergir do
   DDL de referência, inclusive nas renomeações recentes
   (DS_RESULTADO_ALCANCADO, DS_COMPARA_META etc.).

   ---------------------------------------------------------------------
   PARÂMETROS (ajuste antes de rodar)

   @TAM_TEXTO         1200 = todo VARCHAR/NVARCHAR com tamanho definido
                      vira VARCHAR(1200)/NVARCHAR(1200).
                      -1   = vira VARCHAR(MAX)/NVARCHAR(MAX): zero risco
                      de truncamento, qualquer que seja o dado legado.
                      Colunas que JÁ são MAX continuam MAX nos dois casos.

   @RELAXAR_NOT_NULL  0 = preserva a nulidade original (cópia fiel).
                      1 = cria tudo NULL-ável. Use se a carga falhar com
                      "Cannot insert the value NULL" — histórico
                      incompleto é comum e o staging não deveria barrar.

   NOTA sobre o limite de 8060 bytes: a tabela principal tem 11 colunas
   de texto; a 1200 caracteres cada, a soma dos tamanhos declarados
   (~13.200 bytes) passa do limite in-row. O CREATE funciona, o SQL
   Server emite o aviso 1701 e as linhas que de fato estourarem usam
   páginas de ROW_OVERFLOW. Para staging isso é aceitável. Com
   @TAM_TEXTO = -1 o aviso não aparece (MAX já é off-row por natureza).

   ---------------------------------------------------------------------
   SEGURANÇA
     - NÃO toca em nenhuma tabela original: só executa CREATE TABLE de
       objetos novos com prefixo KZN_HIST_.
     - IDEMPOTENTE: pula a tabela HIST que já existir (não recria, não
       apaga). Para refazer uma, dropar manualmente antes.
     - Roda em transação: se qualquer CREATE falhar, nenhum é mantido.

   Schema: 'ci' (AZURE_SQL_SCHEMA em app.yaml).
   ===================================================================== */

SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @TAM_TEXTO        INT  = 1200;   -- <<< 1200 ou -1 para MAX
DECLARE @RELAXAR_NOT_NULL BIT  = 0;      -- <<< 1 para criar tudo NULL-ável

/* Pares origem -> destino. Para incluir também os logs de auditoria,
   acrescente aqui: KZN_LOG_PEDRAVISAOCONSOLIDADA e
   KZN_LOG_PEDRAVISAOCONSOLIDADA_DETALHE. */
DECLARE @tabelas TABLE (ORDEM INT PRIMARY KEY, ORIGEM SYSNAME, DESTINO SYSNAME);
INSERT INTO @tabelas (ORDEM, ORIGEM, DESTINO) VALUES
    (1, 'KZN_PEDRAVISAOCONSOLIDADA', 'KZN_HIST_PEDRAVISAOCONSOLIDADA'),
    (2, 'KZN_MEMBROS_EQUIPE',        'KZN_HIST_MEMBROS_EQUIPE'),
    (3, 'KZN_RESULTADO_KAIZEN',      'KZN_HIST_RESULTADO_KAIZEN'),
    (4, 'KZN_KAIZEN_HIERARQUIA',     'KZN_HIST_KAIZEN_HIERARQUIA'),
    (5, 'KZN_KAIZEN_DESPERDICIO',    'KZN_HIST_KAIZEN_DESPERDICIO');

DECLARE @i INT = 1, @n INT, @origem SYSNAME, @destino SYSNAME,
        @cols NVARCHAR(MAX), @sql NVARCHAR(MAX), @objId INT, @criadas INT = 0;

SELECT @n = MAX(ORDEM) FROM @tabelas;

/* =====================================================================
   E1 - PRÉ-CHECAGEM: as origens existem? alguma HIST já existe?
   ===================================================================== */
SELECT  ORIGEM        = t.ORIGEM,
        ORIGEM_EXISTE = CASE WHEN OBJECT_ID('CI.' + t.ORIGEM, 'U') IS NULL THEN 'NAO' ELSE 'SIM' END,
        DESTINO       = t.DESTINO,
        DESTINO_JA_EXISTE = CASE WHEN OBJECT_ID('CI.' + t.DESTINO, 'U') IS NULL THEN 'nao' ELSE 'SIM (sera pulada)' END
FROM    @tabelas t
ORDER BY t.ORDEM;

IF EXISTS (SELECT 1 FROM @tabelas t WHERE OBJECT_ID('CI.' + t.ORIGEM, 'U') IS NULL)
BEGIN
    RAISERROR('Abortado: ao menos uma tabela de origem não existe neste banco (ver coluna ORIGEM_EXISTE acima). Ajuste a lista @tabelas.', 16, 1);
    RETURN;
END

/* =====================================================================
   E2 - GERAÇÃO E CRIAÇÃO
   ===================================================================== */
BEGIN TRANSACTION;

BEGIN TRY

    WHILE @i <= @n
    BEGIN
        SELECT @origem = ORIGEM, @destino = DESTINO FROM @tabelas WHERE ORDEM = @i;
        SET @objId = OBJECT_ID('CI.' + @origem, 'U');

        IF OBJECT_ID('CI.' + @destino, 'U') IS NOT NULL
            PRINT '  - CI.' + @destino + ': ja existe, pulada.';
        ELSE
        BEGIN
            /* Monta a lista de colunas a partir dos metadados reais.
               Colunas calculadas são ignoradas de propósito: numa tabela
               de staging elas não fazem sentido (o valor vem do dado
               legado, não de uma fórmula). IDENTITY também não é
               replicado — a carga informa o valor explicitamente. */
            SET @cols = NULL;

            SELECT @cols = ISNULL(@cols + ',' + CHAR(13) + CHAR(10), '') + '    ' + QUOTENAME(c.name) + ' '
                 + CASE
                     /* Texto com tamanho definido -> ampliado */
                     WHEN ty.name IN ('varchar','char') AND c.max_length <> -1
                          THEN 'VARCHAR(' + CASE WHEN @TAM_TEXTO = -1 THEN 'MAX' ELSE CAST(@TAM_TEXTO AS VARCHAR(10)) END + ')'
                     WHEN ty.name IN ('nvarchar','nchar') AND c.max_length <> -1
                          THEN 'NVARCHAR(' + CASE WHEN @TAM_TEXTO = -1 THEN 'MAX' ELSE CAST(@TAM_TEXTO AS VARCHAR(10)) END + ')'
                     /* Texto que já era MAX -> continua MAX */
                     WHEN ty.name IN ('varchar','char')   THEN 'VARCHAR(MAX)'
                     WHEN ty.name IN ('nvarchar','nchar') THEN 'NVARCHAR(MAX)'
                     /* Demais tipos -> idênticos ao original */
                     WHEN ty.name IN ('varbinary','binary')
                          THEN ty.name + '(' + CASE WHEN c.max_length = -1 THEN 'MAX' ELSE CAST(c.max_length AS VARCHAR(10)) END + ')'
                     WHEN ty.name IN ('decimal','numeric')
                          THEN ty.name + '(' + CAST(c.precision AS VARCHAR(10)) + ',' + CAST(c.scale AS VARCHAR(10)) + ')'
                     WHEN ty.name IN ('datetime2','time','datetimeoffset')
                          THEN ty.name + '(' + CAST(c.scale AS VARCHAR(10)) + ')'
                     ELSE ty.name
                   END
                 + CASE WHEN c.is_nullable = 1 OR @RELAXAR_NOT_NULL = 1 THEN ' NULL' ELSE ' NOT NULL' END
            FROM        sys.columns c
            JOIN        sys.types   ty ON ty.user_type_id = c.user_type_id
            WHERE       c.object_id = @objId
              AND       c.is_computed = 0
            ORDER BY    c.column_id;

            IF @cols IS NULL
            BEGIN
                DECLARE @m NVARCHAR(300) = 'Abortado: CI.' + @origem + ' não tem colunas replicáveis.';
                RAISERROR(@m, 16, 1);
            END

            SET @sql = N'CREATE TABLE CI.' + QUOTENAME(@destino) + N'
(' + @cols + N'
);';
            EXEC sp_executesql @sql;
            SET @criadas += 1;
            PRINT '  - CI.' + @destino + ': criada.';
        END

        SET @i += 1;
    END

    COMMIT TRANSACTION;
    PRINT 'Concluido: ' + CAST(@criadas AS VARCHAR(10)) + ' tabela(s) de historico criada(s), sem vinculos.';

END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0
        ROLLBACK TRANSACTION;
    PRINT 'ERRO — nada foi criado (rollback aplicado): ' + ERROR_MESSAGE();
    THROW;
END CATCH
GO

/* =====================================================================
   E3 - CONFERÊNCIA
   ---------------------------------------------------------------------
   Confirma a estrutura e prova que as HIST nasceram sem amarração
   nenhuma (todas as contagens de constraint/índice/trigger = 0).
   ===================================================================== */
SELECT  TABELA  = OBJECT_NAME(c.object_id),
        POSICAO = c.column_id,
        COLUNA  = c.name,
        TIPO    = ty.name + CASE
                    WHEN ty.name IN ('varchar','char','nvarchar','nchar')
                         THEN '(' + CASE WHEN c.max_length = -1 THEN 'MAX'
                                         WHEN ty.name IN ('nvarchar','nchar') THEN CAST(c.max_length/2 AS VARCHAR(10))
                                         ELSE CAST(c.max_length AS VARCHAR(10)) END + ')'
                    WHEN ty.name IN ('decimal','numeric')
                         THEN '(' + CAST(c.precision AS VARCHAR(10)) + ',' + CAST(c.scale AS VARCHAR(10)) + ')'
                    WHEN ty.name IN ('datetime2','time','datetimeoffset')
                         THEN '(' + CAST(c.scale AS VARCHAR(10)) + ')'
                    ELSE '' END,
        NULO    = CASE WHEN c.is_nullable = 1 THEN 'SIM' ELSE 'NAO' END
FROM        sys.columns c
JOIN        sys.types  ty ON ty.user_type_id = c.user_type_id
JOIN        sys.tables t  ON t.object_id = c.object_id
WHERE       t.schema_id = SCHEMA_ID('CI')
  AND       t.name LIKE 'KZN_HIST_%'
ORDER BY    t.name, c.column_id;

SELECT  TABELA      = t.name,
        COLUNAS     = (SELECT COUNT(*) FROM sys.columns       WHERE object_id = t.object_id),
        CONSTRAINTS = (SELECT COUNT(*) FROM sys.key_constraints WHERE parent_object_id = t.object_id)
                    + (SELECT COUNT(*) FROM sys.check_constraints WHERE parent_object_id = t.object_id)
                    + (SELECT COUNT(*) FROM sys.default_constraints WHERE parent_object_id = t.object_id),
        FKS_SAIDA   = (SELECT COUNT(*) FROM sys.foreign_keys  WHERE parent_object_id = t.object_id),
        FKS_ENTRADA = (SELECT COUNT(*) FROM sys.foreign_keys  WHERE referenced_object_id = t.object_id),
        INDICES     = (SELECT COUNT(*) FROM sys.indexes       WHERE object_id = t.object_id AND type IN (1,2)),
        TRIGGERS    = (SELECT COUNT(*) FROM sys.triggers      WHERE parent_id = t.object_id),
        LINHAS      = (SELECT ISNULL(SUM(rows),0) FROM sys.partitions WHERE object_id = t.object_id AND index_id IN (0,1))
FROM        sys.tables t
WHERE       t.schema_id = SCHEMA_ID('CI')
  AND       t.name LIKE 'KZN_HIST_%'
ORDER BY    t.name;
GO
