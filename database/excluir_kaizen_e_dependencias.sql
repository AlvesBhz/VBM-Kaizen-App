/* =====================================================================
   Exclui um Kaizen de CI.KZN_PEDRAVISAOCONSOLIDADA e suas dependências
   ---------------------------------------------------------------------
   USO PREVISTO: período de testes/validação, pra limpar um cadastro de
   teste. NÃO é um script de uso rotineiro em produção com dado real —
   toda exclusão aqui é definitiva (sem soft-delete).

   Apaga, NESTA ORDEM (dependentes primeiro, o Kaizen por último — a
   ordem inversa das dependências, mesmo raciocínio do DROP da seção 1
   do DDL de referência):
     1. CI.KZN_LOG_PEDRAVISAOCONSOLIDADA_DETALHE (depende do LOG, não do
        Kaizen diretamente — por isso vem antes do próprio LOG)
     2. CI.KZN_LOG_PEDRAVISAOCONSOLIDADA        (histórico de auditoria)
     3. CI.KZN_MEMBROS_EQUIPE
     4. CI.KZN_RESULTADO_KAIZEN
     5. CI.KZN_KAIZEN_HIERARQUIA
     6. CI.KZN_KAIZEN_DESPERDICIO
     7. CI.KZN_PEDRAVISAOCONSOLIDADA               (o próprio Kaizen)

   Rode verificar_amarracoes_kaizen.sql (PARTE 1) ANTES, pra confirmar
   que essa lista de 6 dependentes ainda bate com a realidade deste
   banco — se surgir uma tabela dependente nova que não esteja aqui, a
   exclusão do Kaizen vai falhar por violação de FK (comportamento
   seguro: nada é apagado pela metade, ver TRY/CATCH com ROLLBACK
   abaixo), e é hora de atualizar este script.

   SEGURANÇA:
     - Cada DELETE de tabela dependente roda dentro de um
       IF OBJECT_ID(...) IS NOT NULL (via SQL dinâmico) — se alguma
       dessas 6 tabelas não existir neste ambiente, o script pula essa
       linha em vez de falhar a compilação inteira (T-SQL não faz
       resolução de nomes adiada em batch avulso; uma referência
       estática a tabela ausente quebraria o script todo mesmo dentro
       de um IF que nunca executasse).
     - @ID_KAIZEN é OBRIGATÓRIO: com NULL o script para antes de tocar
       em qualquer dado (proteção contra apagar tudo por engano).
     - Tudo roda em UMA transação: erro em qualquer etapa desfaz TUDO
       (ROLLBACK), nenhuma exclusão parcial.

   Schema: 'ci' (AZURE_SQL_SCHEMA em app.yaml).
   ===================================================================== */

SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @ID_KAIZEN INT = NULL;   -- <<< OBRIGATÓRIO: informe o ID_KAIZEN a excluir

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

PRINT 'Excluindo Kaizen ' + CAST(@ID_KAIZEN AS VARCHAR(20)) + ' e suas dependências...';

BEGIN TRANSACTION;

BEGIN TRY

    /* 1) Detalhe do log — depende do LOG (ID_LOG), não do Kaizen direto */
    IF OBJECT_ID('CI.KZN_LOG_PEDRAVISAOCONSOLIDADA_DETALHE', 'U') IS NOT NULL
       AND OBJECT_ID('CI.KZN_LOG_PEDRAVISAOCONSOLIDADA', 'U') IS NOT NULL
    BEGIN
        EXEC sp_executesql
            N'DELETE d
              FROM CI.KZN_LOG_PEDRAVISAOCONSOLIDADA_DETALHE d
              JOIN CI.KZN_LOG_PEDRAVISAOCONSOLIDADA l ON l.ID_LOG = d.ID_LOG
              WHERE l.ID_KAIZEN = @id',
            N'@id INT', @id = @ID_KAIZEN;
        PRINT '  - KZN_LOG_PEDRAVISAOCONSOLIDADA_DETALHE: ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' linha(s).';
    END

    /* 2) Cabeçalho do log de auditoria */
    IF OBJECT_ID('CI.KZN_LOG_PEDRAVISAOCONSOLIDADA', 'U') IS NOT NULL
    BEGIN
        EXEC sp_executesql
            N'DELETE FROM CI.KZN_LOG_PEDRAVISAOCONSOLIDADA WHERE ID_KAIZEN = @id',
            N'@id INT', @id = @ID_KAIZEN;
        PRINT '  - KZN_LOG_PEDRAVISAOCONSOLIDADA: ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' linha(s).';
    END

    /* 3) Membros de equipe */
    IF OBJECT_ID('CI.KZN_MEMBROS_EQUIPE', 'U') IS NOT NULL
    BEGIN
        EXEC sp_executesql
            N'DELETE FROM CI.KZN_MEMBROS_EQUIPE WHERE ID_KAIZEN = @id',
            N'@id INT', @id = @ID_KAIZEN;
        PRINT '  - KZN_MEMBROS_EQUIPE: ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' linha(s).';
    END

    /* 4) Resultados do Kaizen */
    IF OBJECT_ID('CI.KZN_RESULTADO_KAIZEN', 'U') IS NOT NULL
    BEGIN
        EXEC sp_executesql
            N'DELETE FROM CI.KZN_RESULTADO_KAIZEN WHERE ID_KAIZEN = @id',
            N'@id INT', @id = @ID_KAIZEN;
        PRINT '  - KZN_RESULTADO_KAIZEN: ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' linha(s).';
    END

    /* 5) Fotografia da hierarquia organizacional */
    IF OBJECT_ID('CI.KZN_KAIZEN_HIERARQUIA', 'U') IS NOT NULL
    BEGIN
        EXEC sp_executesql
            N'DELETE FROM CI.KZN_KAIZEN_HIERARQUIA WHERE ID_KAIZEN = @id',
            N'@id INT', @id = @ID_KAIZEN;
        PRINT '  - KZN_KAIZEN_HIERARQUIA: ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' linha(s).';
    END

    /* 6) Desperdícios do Kaizen */
    IF OBJECT_ID('CI.KZN_KAIZEN_DESPERDICIO', 'U') IS NOT NULL
    BEGIN
        EXEC sp_executesql
            N'DELETE FROM CI.KZN_KAIZEN_DESPERDICIO WHERE ID_KAIZEN = @id',
            N'@id INT', @id = @ID_KAIZEN;
        PRINT '  - KZN_KAIZEN_DESPERDICIO: ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' linha(s).';
    END

    /* 7) Por último, o próprio Kaizen (referenciado por todos acima) */
    DELETE FROM CI.KZN_PEDRAVISAOCONSOLIDADA WHERE ID_KAIZEN = @ID_KAIZEN;
    PRINT '  - KZN_PEDRAVISAOCONSOLIDADA: ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' linha(s).';

    COMMIT TRANSACTION;
    PRINT 'Kaizen ' + CAST(@ID_KAIZEN AS VARCHAR(20)) + ' e suas dependências excluídos com sucesso.';

END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0
        ROLLBACK TRANSACTION;
    PRINT 'ERRO — nada foi excluído (rollback aplicado): ' + ERROR_MESSAGE();
    THROW;
END CATCH
