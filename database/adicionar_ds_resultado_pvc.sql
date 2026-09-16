/* ============================================================
   Coluna DS_RESULTADO em CI.KZN_PEDRAVISAOCONSOLIDADA
   ------------------------------------------------------------
   Guarda a "Descrição dos Resultados Alcançados" — o texto livre
   que o autor escreve na etapa 4 do Novo Kaizen, ao lado do combo
   "Resultado" do bloco "Outros".

   POR QUE A COLUNA PRECISA EXISTIR

   Até aqui essa descrição não tinha onde morar. O servidor criava
   uma LINHA NOVA em CI.KZN_RESULTADOS a cada Kaizen salvo
   (ID = MAX(ID_RESULTADO) + 1, nos dois idiomas) e usava o
   DS_RESULTADO dela para guardar o texto. Consequências:

     · o catálogo de resultados crescia um registro por Kaizen e
       aparecia inchado na aba Resultados da Administração;
     · o que o usuário ESCOLHEU no combo não era gravado como
       escolha — o valor ia para ID_TIPO_RESULTADO da linha nova;
     · reabrir o Kaizen não devolvia a seleção.

   Com o combo passando a referenciar o catálogo (CI.KZN_RESULTADOS
   filtrado por ID_TIPO_RESULTADO), CI.KZN_RESULTADO_KAIZEN volta a
   ser o que é — o vínculo Kaizen ↔ Resultado — e a descrição, que é
   do KAIZEN e não do catálogo, passa a morar aqui.

   Não reaproveita DS_RESULTADO_ESPERADO: aquela coluna já é do campo
   obrigatório "Comparação com a Meta Inicial / Declaração do
   Problema". Os dois textos na mesma coluna se sobrescreveriam.

   SEGURANÇA

   VARCHAR(100) NULL, o mesmo limite que a tela já aplica (contador
   0/100) e que o servidor valida. NULL porque o bloco "Outros" é
   opcional e todos os Kaizens já cadastrados ficam sem o campo.

   Idempotente: rodar duas vezes não dá erro.

   O APLICATIVO NÃO DEPENDE DESTE SCRIPT PARA SUBIR. O servidor
   verifica a coluna no INFORMATION_SCHEMA uma vez e só a inclui no
   INSERT/UPDATE quando ela existe — sem ela, registra no log
   "[resultados] DS_RESULTADO ausente" e grava o resto normalmente.
   Rodar este script é o que liga a gravação da descrição.
   ============================================================ */

IF NOT EXISTS (
    SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS
     WHERE TABLE_SCHEMA = 'ci'
       AND TABLE_NAME   = 'kzn_pedravisaoconsolidada'
       AND COLUMN_NAME  = 'DS_RESULTADO'
)
BEGIN
    ALTER TABLE ci.kzn_pedravisaoconsolidada
        ADD DS_RESULTADO VARCHAR(100) NULL;

    PRINT 'DS_RESULTADO criada em ci.kzn_pedravisaoconsolidada.';
END
ELSE
    PRINT 'DS_RESULTADO ja existe — nada a fazer.';
GO

/* Conferência: deve devolver uma linha, VARCHAR(100), IS_NULLABLE = YES. */
SELECT COLUMN_NAME, DATA_TYPE, CHARACTER_MAXIMUM_LENGTH, IS_NULLABLE
  FROM INFORMATION_SCHEMA.COLUMNS
 WHERE TABLE_SCHEMA = 'ci'
   AND TABLE_NAME   = 'kzn_pedravisaoconsolidada'
   AND COLUMN_NAME  = 'DS_RESULTADO';
GO
