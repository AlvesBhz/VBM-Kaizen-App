# Evidências dos testes da migração CI (PRD → DEV)

Executados em 30/09/2026 em **SQL Server 2022 (16.0.4295.3) local**, modo `LOCAL` dos scripts.
**Não** foram executados contra o Azure: a leitura por Elastic Query (`sp_execute_remote` e
`EXTERNAL TABLE`) não existe fora do Azure SQL Database e é validada pelo teste de fumaça do 00.
A evidência oficial da migração é a saída do `05_validacoes_evidencias.sql` rodado no Azure.

## Base de teste

| Item | Conteúdo |
|---|---|
| PRD simulada | `DDL_SCRIPT_DB.sql` do repositório + scripts das tabelas `KZN_HIST_*` + carga histórica real (26.290 linhas, textos longos com acentos) |
| Tabelas | as 31 da lista + `ZZ_BORDAS` (não listada) |
| Casos-limite | identity com lacuna, coluna calculada persistida e não persistida, rowversion, ROWGUIDCOL, collation por coluna (CS), índice filtrado com INCLUDE, compressão PAGE, FILLFACTOR, UNIQUE DESC, FK não confiável com linha órfã, CHECK desabilitado com violação, trigger desabilitado, 20 triggers, 2 sequences em uso, view sobre view, função, procedure com `QUOTED_IDENTIFIER OFF`/`ANSI_NULLS OFF`, sinônimo, propriedades estendidas, ciclo de FK (`KZN_MDM_HIERARQUIA` ↔ `KZN_TIPO_USUARIO`), view em `dbo` apontando para o CI |
| Par "contained" | mesma PRD em banco com collation diferente da do catálogo (reproduz o Azure SQL) e leitura pelo usuário de privilégio mínimo do `00a` |

## Resultados

| Cenário | Resultado |
|---|---|
| PRD → DEV, do zero, `@RECRIAR = 1` | APROVADA — 0 diferença estrutural; 26.290 = 26.290 linhas; soma de verificação igual nas 32 tabelas |
| Par contained, leitura como `mig_ci_leitura` | APROVADA — 0 diferença estrutural |
| Comportamento no DEV = PRD | procedure com `QUOTED_IDENTIFIER OFF` devolve o mesmo resultado; trigger de log grava `ID_LOG` 4 (próximo da sequence) nos dois; próximo identity 4 e 25 nos dois; trigger desabilitado segue desabilitado |
| Reexecução do 04 | idempotente: 0 objeto criado, 0 falha |
| Sabotagem no DEV (tipo de coluna, linha apagada, 1 caractere alterado, índice apagado, FK não confiável) | REPROVADA — as 5 detectadas; o caractere alterado pela soma de verificação com a mesma contagem |
| Travas | 00 conectado na PRD: aborta. CI existente no DEV com `@RECRIAR = 0`: 01 reprova e 02 aborta sem alterar nada. Falha no 02: rollback completo |
| Limpeza (06 / 06a) | CI intacto (178 objetos antes e depois); MIG_EXT removido; evidências mantidas; usuário de leitura removido |

## Defeitos encontrados e corrigidos durante o teste

| Defeito | Correção |
|---|---|
| Conflito de collation catálogo × banco (Msg 468) no 04 | `COLLATE DATABASE_DEFAULT` na comparação |
| `ALTER SEQUENCE RESTART` alterava o `START WITH` gravado | avanço por `sp_sequence_get_range` |
| Usuário de leitura não via `sys.sql_expression_dependencies` (mapeamento de dependências vazio sem aviso) | `GRANT SELECT` no 00a + FALHA no 01 se faltar |
| Ordem de carga marcava 21 tabelas como "em ciclo" | fecho transitivo: só `KZN_MDM_HIERARQUIA` e `KZN_TIPO_USUARIO` |

## Saída do 05 (PRD → DEV, execução aprovada)

```
VEREDITO|EXECUTADO_EM|ORIGEM|DESTINO
--------|------------|------|-------
APROVADA|2026-09-30 17:51:07.6569918|BDIBPBMSA_PRD|BDIBPBMSA_DEV
ORDEM|CRITERIO|RESULTADO|DETALHE
-----|--------|---------|-------
1|Todas as tabelas CI da PRD existem no DEV|OK|32 de 32
2|Estruturas idênticas (colunas, tipos, PK, FK, índices, defaults, constraints, identity, triggers, dependentes)|OK|0 diferença(s)
3|Quantidade de registros conciliada|OK|PRD 26290 | DEV 26290 linha(s); soma de verificação por tabela
4|Nenhuma constraint ou relacionamento perdido|OK|38 PK/UNIQUE, 38 FK, 2 CHECK, 42 DEFAULT
5|Integridade referencial válida|AVISO|2 linha(s) violando constraint
6|Identity e sequences com o mesmo próximo valor|OK|2 identity, 2 sequence(s)
7|Dependências fora do CI mapeadas|AVISO|Modulo de fora -> CI: dbo.VW_FORA_DO_CI / CI.KZN_PEDRAVISAOCONSOLIDADA
TABELA|LINHAS_PRD|LINHAS_DEV|SOMA_PRD|SOMA_DEV|RESULTADO
------|----------|----------|--------|--------|---------
KZN_ADMIN|1|1|367946069|367946069|OK
KZN_ANALISE_DUPLICIDADE|1|1|1195281459|1195281459|OK
KZN_APROVADOR|1|1|1707893312|1707893312|OK
KZN_CATEGORIA|2|2|-2123183476|-2123183476|OK
KZN_DESPERDICIO|2|2|-709598925|-709598925|OK
KZN_HIST_APROVADOR|395|395|849498611|849498611|OK
KZN_HIST_KAIZEN_DESPERDICIO|6694|6694|-177552710|-177552710|OK
KZN_HIST_KAIZEN_HIERARQUIA|4980|4980|1801844400|1801844400|OK
KZN_HIST_MDM_VBM_TERC|250|250|-2119520440|-2119520440|OK
KZN_HIST_MEMBROS_EQUIPE|4366|4366|-1451179690|-1451179690|OK
KZN_HIST_PEDRAVISAOCONSOLIDADA|4980|4980|1580443356|1580443356|OK
KZN_HIST_RESULTADO_KAIZEN|4569|4569|-130987068|-130987068|OK
KZN_IDIOMA|5|5|472512318|472512318|OK
KZN_KAIZEN_DESPERDICIO|1|1|314110974|314110974|OK
KZN_KAIZEN_HIERARQUIA|1|1|592149904|592149904|OK
KZN_LOG_PEDRAVISAOCONSOLIDADA|3|3|710021962|710021962|OK
KZN_LOG_PEDRAVISAOCONSOLIDADA_DETALHE|1|1|1024297123|1024297123|OK
KZN_MDM_HIERARQUIA|3|3|-1824173026|-1824173026|OK
KZN_MDM_TEMP|2|2|21784|21784|OK
KZN_MDM_TERCEIROS_TEMP|1|1|1407543489|1407543489|OK
KZN_MEMBROS_EQUIPE|2|2|10262704|10262704|OK
KZN_MOEDA|5|5|-577418496|-577418496|OK
KZN_PEDRAVISAOCONSOLIDADA|2|2|-256482106|-256482106|OK
KZN_REPLICACAO|2|2|-707788800|-707788800|OK
KZN_RESULTADO_KAIZEN|1|1|314072790|314072790|OK
KZN_RESULTADOS|1|1|1125399536|1125399536|OK
KZN_STATUS|10|10|1144636845|1144636845|OK
KZN_TB_NOTIFICACAO_TESTE|2|2|23634609|23634609|OK
KZN_TIPO_KAIZEN|1|1|-557318522|-557318522|OK
KZN_TIPO_RESULTADO|1|1|-1093836839|-1093836839|OK
KZN_TIPO_USUARIO|2|2|1164711714|1164711714|OK
ZZ_BORDAS|3|3|1521618142|1521618142|OK
ETAPA|RESULTADO|ITEM|DETALHE
-----|---------|----|-------
05|AVISO|Integridade — [CK_ZZ_QTD]|1 linha(s) em [CI].[ZZ_BORDAS] — pré-existente: a constraint é não confiável/desabilitada também na PRD.
```

## Script único de estrutura (`criar_estrutura_ci_dev.sql`)

Gerado por `gerar_script_estrutura_ci.sql` a partir de um banco montado só com os scripts do
repositório (DDL_SCRIPT_DB.sql + scripts HIST), sem os objetos de teste e sem
KZN_MDM_TEMP, KZN_MDM_TERCEIROS_TEMP e KZN_TB_NOTIFICACAO_TESTE.

| Teste | Resultado |
|---|---|
| 1ª execução em banco vazio `SQL_Latin1_General_CP1_CI_AS` | 0 erros; conferência 14/14 OK (28 tabelas, 37 FKs) |
| 1ª execução em banco vazio `Latin1_General_CI_AS` | 0 erros; 14/14 OK |
| 2ª execução nos dois bancos (idempotência) | 0 erros; 14/14 OK; nada recriado |
| Estrutura criada x origem (gerador rodado nos dois e comparado) | idêntica, nas duas collations |
| Execução por engano na PRD | abortada na 1ª linha (`SET NOEXEC ON`), nada executado |
| Comportamento | TR_KZN_PVC_INS/UPD gravam log C e A via sequence; FK barra órfão (547); 0 FK não confiável |

Correções no gerador feitas neste teste: separador de STRING_AGG precisa ser variável
(Msg 8733); ordem de trigger montada fora do agregado (Msg 130/8124); bloco de PRINT com
exatamente 4000 caracteres perdia 1 caractere (concatenação de NVARCHAR(4000) truncava).

## Transferência de dados (`transferir_dados_prd_dev.sql`)

Origem: banco PRD de teste (26.290 linhas). Destino: banco criado pelo `criar_estrutura_ci_dev.sql`. Modo LOCAL.

| Teste | Resultado |
|---|---|
| DEV com dados e `@SUBSTITUIR_DADOS_DEV = 0` | abortado antes de gravar, listando as tabelas com dados |
| Cópia completa (`@SUBSTITUIR_DADOS_DEV = 1`) | 28 tabelas OK (contagem e soma de verificação iguais: PRD, leitura e DEV); tabelas só da PRD listadas como NAO COPIADA |
| Comparação linha a linha (EXCEPT nos dois sentidos, todas as colunas) | 0 diferenças nas 28 tabelas |
| Estado depois da cópia | 38 FKs/CHECKs religados e confiáveis (revalidados WITH CHECK); 19 triggers habilitados; sequences = próximo valor da PRD |
| Uso normal depois da cópia | Kaizen novo no DEV gera log 51 (C) e 52 (A), após os IDs copiados |
| Falha forçada na revalidação (CHECK que a PRD viola) | ROLLBACK: DEV igual ao de antes (linhas, constraints, triggers); mensagem aponta a constraint |
| Coluna com tamanho diferente no DEV | abortado antes de copiar, listando tabela/coluna PRD x DEV |
| DEV com collation `Latin1_General_CI_AS` e banco contido | OK, 0 erros |
| Limpeza | nenhuma sobra (TRF_EXT, TRF_STG, fonte externa, credencial) em sucesso e em falha |

Não testado aqui: o caminho Elastic Query do Azure (`@MODO = 'AZURE'`), que exige os dois bancos no Azure.

## MERGE da KZN_MDM_HIERARQUIA (`merge_kzn_mdm_hierarquia_prd_dev.sql`)

Modo LOCAL; origem = banco PRD de teste; destino = DEV criado pelos scripts acima.

| Teste | Resultado |
|---|---|
| Usuário novo na PRD, usuário alterado no DEV, usuário só no DEV (`@APAGAR_AUSENTES_NO_DEV = 0`) | 1 inserido, 1 atualizado, 1 mantido; 0 linhas da PRD diferentes no DEV |
| DT_ATUALIZACAO após o UPDATE | igual à da PRD (o trigger não recarimbou) |
| 2ª execução | 0 inseridas, 0 atualizadas (idempotente) |
| `@APAGAR_AUSENTES_NO_DEV = 1` | linha só do DEV apagada; DEV = PRD |
| Linha a apagar referenciada por KZN_ADMIN (+ 1 atualização pendente) | FK barrou; ROLLBACK total (a atualização também voltou); mensagem cita a FK |
| ID_TIPO_USUARIO da PRD inexistente no DEV | abortado antes de gravar, listando o tipo |
| Coluna com tamanho ou collation diferente | abortado antes de gravar, listando a coluna |
| Banco contido `Latin1_General_CI_AS` (estrutura → transferência → merge) | OK, 0 erros |
| Ligação com a PRD | removida ao final em todos os casos |
