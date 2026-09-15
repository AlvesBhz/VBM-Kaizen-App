/* =====================================================================
   Exclui um Kaizen de CI.KZN_PEDRAVISAOCONSOLIDADA e suas dependências
   ---------------------------------------------------------------------
   USO PREVISTO: período de testes/validação, pra limpar um cadastro de
   teste. NÃO é um script de uso rotineiro em produção com dado real —
   toda exclusão aqui é definitiva (sem soft-delete).

   Apaga, NESTA ORDEM (dependentes primeiro, o Kaizen por último):
     1. CI.KZN_LOG_PEDRAVISAOCONSOLIDADA_DETALHE (depende do LOG, não do
        Kaizen diretamente — por isso vem antes do próprio LOG)
     2. CI.KZN_LOG_PEDRAVISAOCONSOLIDADA        (histórico de auditoria)
     3. CI.KZN_MEMBROS_EQUIPE
     4. CI.KZN_RESULTADO_KAIZEN
     5. CI.KZN_KAIZEN_HIERARQUIA                (fotografia da hierarquia)
     6. CI.KZN_KAIZEN_DESPERDICIO
     7. CI.KZN_PEDRAVISAOCONSOLIDADA            (o próprio Kaizen)

   ---------------------------------------------------------------------
   O QUE MUDOU NESTA VERSÃO

   A lista acima já contemplava a KZN_KAIZEN_HIERARQUIA (era o passo 5).
   O que faltava era PROVA de que cada tabela foi mesmo limpa — antes o
   script só imprimia um contador e seguia. Agora:

     - E1 confere a COBERTURA contra os metadados: descobre no próprio
       banco todas as tabelas com FK pra KZN_PEDRAVISAOCONSOLIDADA e
       aborta se alguma não estiver na lista deste script. Antes isso era
       um passo manual ("rode o verificar_amarracoes antes"), fácil de
       esquecer — e o sintoma de esquecer era um erro de FK no passo 7;
     - E1 também mostra, ANTES de apagar, quantas linhas cada tabela tem
       pra esse Kaizen;
     - E3 reconfere DENTRO da transação que sobrou ZERO linha em cada
       dependente. Se sobrar qualquer uma, faz ROLLBACK em vez de commit;
     - as contagens saem por parâmetro OUTPUT, de dentro do próprio batch
       dinâmico, em vez de @@ROWCOUNT lido depois do EXEC — que é frágil e
       pode reportar número errado (era o que tornava possível o script
       apagar e mesmo assim imprimir "0 linha(s)").

   SEGURANÇA:
     - @ID_KAIZEN é OBRIGATÓRIO: com NULL o script para antes de tocar
       em qualquer dado (proteção contra apagar tudo por engano).
     - Cada DELETE só roda se a tabela existir (via SQL dinâmico) — T-SQL
       não faz resolução de nomes adiada em batch avulso; uma referência
       estática a tabela ausente quebraria o script todo, mesmo dentro de
       um IF que nunca executasse.
     - Tudo roda em UMA transação: erro em qualquer etapa desfaz TUDO
       (ROLLBACK), nenhuma exclusão parcial.

   Schema: 'ci' (AZURE_SQL_SCHEMA em app.yaml).
   ===================================================================== */

SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @ID_KAIZEN INT = NULL;   -- <<< OBRIGATÓRIO: informe o ID_KAIZEN a excluir

/* =====================================================================
   E0 - GUARDAS
   ===================================================================== */
IF @ID_KAIZEN IS NULL
BEGIN
    RAISERROR('Informe um ID_KAIZEN válido na variável @ID_KAIZEN antes de rodar este script — por segurança, ele não executa com @ID_KAIZEN NULL.', 16, 1);
    RETURN;
END

IF NOT EXISTS (SELECT 1 FROM CI.KZN_PEDRAVISAOCONSOLIDADA WHERE ID_KAIZEN = @ID_KAIZEN)
BEGIN
    RAISERROR('Kaizen %d não encontrado em CI.KZN_PEDRAVISAOCONSOLIDADA — nada a excluir.', 16, 1, @ID_KAIZEN);
    RETURN;
END

/* Dependentes cobertos por este script, na ordem de exclusão.
   VIA_LOG = 1 -> a tabela não tem ID_KAIZEN próprio; liga-se ao Kaizen
   através de CI.KZN_LOG_PEDRAVISAOCONSOLIDADA (ID_LOG). */
DECLARE @dependentes TABLE (ORDEM INT PRIMARY KEY, TABELA SYSNAME, VIA_LOG BIT);
INSERT INTO @dependentes (ORDEM, TABELA, VIA_LOG) VALUES
    (1, 'CI.KZN_LOG_PEDRAVISAOCONSOLIDADA_DETALHE', 1),
    (2, 'CI.KZN_LOG_PEDRAVISAOCONSOLIDADA',         0),
    (3, 'CI.KZN_MEMBROS_EQUIPE',                    0),
    (4, 'CI.KZN_RESULTADO_KAIZEN',                  0),
    (5, 'CI.KZN_KAIZEN_HIERARQUIA',                 0),
    (6, 'CI.KZN_KAIZEN_DESPERDICIO',                0);

DECLARE @i INT, @n INT, @tab SYSNAME, @viaLog BIT,
        @sql NVARCHAR(MAX), @linhas INT, @naoCobertas INT, @msg NVARCHAR(400);

/* =====================================================================
   E1 - COBERTURA (via metadados) E PRÉVIA DO QUE SERÁ APAGADO
   ---------------------------------------------------------------------
   DISTINCT importa: desde que a hierarquia ganhou também a FK composta
   (ID_KAIZEN, ID_USUARIO_LIDER), uma mesma tabela aparece mais de uma vez
   em sys.foreign_keys.

   COLLATE DATABASE_DEFAULT nas comparações de nome é OBRIGATÓRIO, não
   estilo: OBJECT_SCHEMA_NAME()/OBJECT_NAME() devolvem texto na collation
   do CATÁLOGO (ex.: Latin1_General_CI_AS), enquanto a coluna SYSNAME da
   variável de tabela herda a collation do BANCO (ex.:
   SQL_Latin1_General_CP1_CI_AS). Sem o COLLATE, o '=' falha com
   "Cannot resolve the collation conflict" em qualquer servidor onde as
   duas difiram.
   ===================================================================== */
SELECT @naoCobertas = COUNT(*)
FROM (
    SELECT DISTINCT TAB = OBJECT_SCHEMA_NAME(fk.parent_object_id) + '.' + OBJECT_NAME(fk.parent_object_id)
    FROM   sys.foreign_keys fk
    WHERE  fk.referenced_object_id = OBJECT_ID('CI.KZN_PEDRAVISAOCONSOLIDADA')
      AND  fk.parent_object_id <> OBJECT_ID('CI.KZN_PEDRAVISAOCONSOLIDADA')
) x
WHERE NOT EXISTS (SELECT 1 FROM @dependentes d
                  WHERE UPPER(d.TABELA) COLLATE DATABASE_DEFAULT = UPPER(x.TAB) COLLATE DATABASE_DEFAULT);

IF @naoCobertas > 0
BEGIN
    SELECT DISTINCT
           TABELA_DEPENDENTE_NAO_COBERTA = OBJECT_SCHEMA_NAME(fk.parent_object_id) + '.' + OBJECT_NAME(fk.parent_object_id)
    FROM   sys.foreign_keys fk
    WHERE  fk.referenced_object_id = OBJECT_ID('CI.KZN_PEDRAVISAOCONSOLIDADA')
      AND  fk.parent_object_id <> OBJECT_ID('CI.KZN_PEDRAVISAOCONSOLIDADA')
      AND  NOT EXISTS (SELECT 1 FROM @dependentes d
                       WHERE UPPER(d.TABELA) COLLATE DATABASE_DEFAULT
                           = UPPER(OBJECT_SCHEMA_NAME(fk.parent_object_id) + '.' + OBJECT_NAME(fk.parent_object_id)) COLLATE DATABASE_DEFAULT);

    RAISERROR('Abortado: %d tabela(s) têm FK pra CI.KZN_PEDRAVISAOCONSOLIDADA e NÃO estão na lista deste script (listada[s] acima). Excluir assim falharia por violação de FK no passo final. Acrescente-a(s) a @dependentes.', 16, 1, @naoCobertas);
    RETURN;
END

PRINT 'Kaizen ' + CAST(@ID_KAIZEN AS VARCHAR(20)) + ' — linhas que serão excluídas:';

SELECT @i = 1, @n = MAX(ORDEM) FROM @dependentes;
WHILE @i <= @n
BEGIN
    SELECT @tab = TABELA, @viaLog = VIA_LOG FROM @dependentes WHERE ORDEM = @i;

    IF OBJECT_ID(@tab, 'U') IS NULL
        PRINT '  - ' + @tab + ': tabela não existe neste banco (será pulada).';
    ELSE
    BEGIN
        /* Os nomes vêm da lista fixa acima, não de entrada externa. */
        IF @viaLog = 1 AND OBJECT_ID('CI.KZN_LOG_PEDRAVISAOCONSOLIDADA','U') IS NOT NULL
            SET @sql = N'SELECT @qt = COUNT(*) FROM ' + @tab + N' d
                         JOIN CI.KZN_LOG_PEDRAVISAOCONSOLIDADA l ON l.ID_LOG = d.ID_LOG
                         WHERE l.ID_KAIZEN = @id;';
        ELSE IF @viaLog = 1
            SET @sql = N'SET @qt = 0;';
        ELSE
            SET @sql = N'SELECT @qt = COUNT(*) FROM ' + @tab + N' WHERE ID_KAIZEN = @id;';

        EXEC sp_executesql @sql, N'@id INT, @qt INT OUTPUT', @id = @ID_KAIZEN, @qt = @linhas OUTPUT;
        PRINT '  - ' + @tab + ': ' + CAST(@linhas AS VARCHAR(10)) + ' linha(s).';
    END

    SET @i += 1;
END

/* =====================================================================
   E2 - EXCLUSÃO
   ===================================================================== */
BEGIN TRANSACTION;

BEGIN TRY

    SELECT @i = 1, @n = MAX(ORDEM) FROM @dependentes;
    WHILE @i <= @n
    BEGIN
        SELECT @tab = TABELA, @viaLog = VIA_LOG FROM @dependentes WHERE ORDEM = @i;

        IF OBJECT_ID(@tab, 'U') IS NOT NULL
        BEGIN
            IF @viaLog = 1 AND OBJECT_ID('CI.KZN_LOG_PEDRAVISAOCONSOLIDADA','U') IS NOT NULL
                SET @sql = N'DELETE d FROM ' + @tab + N' d
                             JOIN CI.KZN_LOG_PEDRAVISAOCONSOLIDADA l ON l.ID_LOG = d.ID_LOG
                             WHERE l.ID_KAIZEN = @id;
                             SET @qt = @@ROWCOUNT;';
            ELSE IF @viaLog = 1
                SET @sql = N'SET @qt = 0;';
            ELSE
                SET @sql = N'DELETE FROM ' + @tab + N' WHERE ID_KAIZEN = @id;
                             SET @qt = @@ROWCOUNT;';

            /* @qt volta por OUTPUT, medido DENTRO do batch dinâmico:
               ler @@ROWCOUNT aqui fora, depois do EXEC, é frágil. */
            EXEC sp_executesql @sql, N'@id INT, @qt INT OUTPUT', @id = @ID_KAIZEN, @qt = @linhas OUTPUT;
            PRINT '  - ' + @tab + ': ' + CAST(@linhas AS VARCHAR(10)) + ' linha(s) excluída(s).';
        END

        SET @i += 1;
    END

    /* Por último, o próprio Kaizen (referenciado por todos acima) */
    DELETE FROM CI.KZN_PEDRAVISAOCONSOLIDADA WHERE ID_KAIZEN = @ID_KAIZEN;
    SET @linhas = @@ROWCOUNT;
    PRINT '  - CI.KZN_PEDRAVISAOCONSOLIDADA: ' + CAST(@linhas AS VARCHAR(10)) + ' linha(s) excluída(s).';

    /* =================================================================
       E3 - VERIFICAÇÃO ANTES DO COMMIT
       Se sobrou qualquer linha em qualquer dependente, desfaz tudo.
       ================================================================= */
    SELECT @i = 1, @n = MAX(ORDEM) FROM @dependentes;
    WHILE @i <= @n
    BEGIN
        SELECT @tab = TABELA, @viaLog = VIA_LOG FROM @dependentes WHERE ORDEM = @i;

        IF OBJECT_ID(@tab, 'U') IS NOT NULL
        BEGIN
            IF @viaLog = 1 AND OBJECT_ID('CI.KZN_LOG_PEDRAVISAOCONSOLIDADA','U') IS NOT NULL
                SET @sql = N'SELECT @qt = COUNT(*) FROM ' + @tab + N' d
                             JOIN CI.KZN_LOG_PEDRAVISAOCONSOLIDADA l ON l.ID_LOG = d.ID_LOG
                             WHERE l.ID_KAIZEN = @id;';
            ELSE IF @viaLog = 1
                SET @sql = N'SET @qt = 0;';
            ELSE
                SET @sql = N'SELECT @qt = COUNT(*) FROM ' + @tab + N' WHERE ID_KAIZEN = @id;';

            EXEC sp_executesql @sql, N'@id INT, @qt INT OUTPUT', @id = @ID_KAIZEN, @qt = @linhas OUTPUT;

            IF @linhas > 0
            BEGIN
                SET @msg = 'Abortado na verificação: ainda restam ' + CAST(@linhas AS VARCHAR(10))
                         + ' linha(s) em ' + @tab + ' para o Kaizen ' + CAST(@ID_KAIZEN AS VARCHAR(20))
                         + '. ROLLBACK aplicado — nada foi excluído.';
                RAISERROR(@msg, 16, 1);
            END
        END

        SET @i += 1;
    END

    IF EXISTS (SELECT 1 FROM CI.KZN_PEDRAVISAOCONSOLIDADA WHERE ID_KAIZEN = @ID_KAIZEN)
        RAISERROR('Abortado na verificação: o Kaizen ainda existe em CI.KZN_PEDRAVISAOCONSOLIDADA. ROLLBACK aplicado.', 16, 1);

    COMMIT TRANSACTION;
    PRINT 'Kaizen ' + CAST(@ID_KAIZEN AS VARCHAR(20)) + ' e suas dependências excluídos e conferidos com sucesso.';

END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0
        ROLLBACK TRANSACTION;
    PRINT 'ERRO — nada foi excluído (rollback aplicado): ' + ERROR_MESSAGE();
    THROW;
END CATCH
