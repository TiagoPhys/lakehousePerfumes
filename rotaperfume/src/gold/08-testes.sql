-- Gold · os 9 testes que QUEBRAM o pipeline.
--
-- Teste que nao quebra o job nao e teste, e relatorio. Se a verificacao falha e o
-- pipeline segue verde, o dashboard mostra numero errado com cara de numero certo,
-- e alguem so descobre numa reuniao, tres meses depois.
--
-- O mecanismo e raise_error(). Ele devolve o tipo NOTHING, entao so funciona
-- dentro de um CASE:
--     CASE WHEN <condicao ok> THEN 'PASSOU' ELSE raise_error('...') END
--
-- Esta consulta devolve UMA tabela com as 9 linhas — nome do teste, valor
-- calculado, valor esperado e resultado. Se algum falhar, a tarefa aborta com
-- [USER_RAISED_EXCEPTION] dizendo QUAL teste falhou e com quais numeros, e as
-- tarefas seguintes do job nao rodam.
--
-- Se um teste falhar, corrija a TRANSFORMACAO. Nunca o teste.

WITH medicoes AS (
  SELECT
    (SELECT SUM(valor_liquido) FROM lakehouse_rotaperfume.silver.pedidos)                     AS receita_silver,
    (SELECT SUM(receita)       FROM lakehouse_rotaperfume.gold.fato_vendas)                   AS receita_gold,
    (SELECT SUM(receita)       FROM lakehouse_rotaperfume.gold.mart_produto_performance)      AS receita_mart,
    (SELECT COUNT(*) - COUNT(DISTINCT cnpj) FROM lakehouse_rotaperfume.silver.clientes)       AS cnpj_duplicados,
    (SELECT COUNT(*) FROM lakehouse_rotaperfume.silver.clientes WHERE length(cnpj) <> 14)     AS cnpj_fora_do_padrao,
    (SELECT COUNT(*) FROM lakehouse_rotaperfume.silver.pedidos  WHERE data_pedido IS NULL)    AS datas_nulas,
    (SELECT COUNT(*) FROM lakehouse_rotaperfume.gold.fato_vendas)                             AS linhas_fato,
    (SELECT COUNT(*) FROM lakehouse_rotaperfume.gold.fato_vendas
      WHERE receita < 0 AND NOT devolucao)                                                    AS negativas_indevidas,
    (SELECT COUNT(*) FROM lakehouse_rotaperfume.gold.fato_vendas f
       LEFT ANTI JOIN lakehouse_rotaperfume.silver.pedidos p ON p.pedido_id = f.pedido_id)     AS pedidos_orfaos,
    (SELECT COUNT(*) FROM lakehouse_rotaperfume.gold.fato_vendas f
       LEFT ANTI JOIN lakehouse_rotaperfume.silver.clientes c ON c.cliente_id = f.cliente_id)  AS clientes_orfaos
),

resultados AS (
  -- 1 · O TESTE QUE MAIS IMPORTA: limpeza e modelagem nao podem mudar o faturamento.
  --     Se este falhar, alguma transformacao esta somando ou perdendo dinheiro.
  SELECT 1 AS n,
         'receita da gold = receita da silver'                       AS teste,
         CAST(receita_gold   AS STRING)                              AS valor_calculado,
         CAST(receita_silver AS STRING)                              AS esperado,
         abs(receita_gold - receita_silver) <= 0.01                  AS passou
  FROM medicoes

  UNION ALL
  SELECT 2, 'CNPJ unico na silver.clientes',
         CAST(cnpj_duplicados AS STRING), '0',
         cnpj_duplicados = 0
  FROM medicoes

  UNION ALL
  SELECT 3, 'nenhuma data_pedido nula na silver.pedidos',
         CAST(datas_nulas AS STRING), '0',
         datas_nulas = 0
  FROM medicoes

  UNION ALL
  SELECT 4, 'receita negativa so onde devolucao = true',
         CAST(negativas_indevidas AS STRING), '0',
         negativas_indevidas = 0
  FROM medicoes

  UNION ALL
  SELECT 5, 'volume da gold.fato_vendas dentro da faixa',
         CAST(linhas_fato AS STRING), 'entre 140.000 e 250.000',
         linhas_fato BETWEEN 140000 AND 250000
  FROM medicoes

  UNION ALL
  SELECT 6, 'nenhum pedido_id da gold fora da silver.pedidos',
         CAST(pedidos_orfaos AS STRING), '0',
         pedidos_orfaos = 0
  FROM medicoes

  -- 7 · O teste que vigia a deduplicacao da silver: se um dia o ERP mandar pedido
  --     no cadastro descartado e gold._mapa_cliente nao der conta, aparece aqui.
  UNION ALL
  SELECT 7, 'nenhum cliente_id da gold fora da silver.clientes',
         CAST(clientes_orfaos AS STRING), '0',
         clientes_orfaos = 0
  FROM medicoes

  UNION ALL
  SELECT 8, 'mart_produto_performance soma o mesmo que fato_vendas',
         CAST(receita_mart AS STRING), CAST(receita_gold AS STRING),
         abs(receita_mart - receita_gold) <= 0.01
  FROM medicoes

  UNION ALL
  SELECT 9, 'todo CNPJ com exatamente 14 digitos',
         CAST(cnpj_fora_do_padrao AS STRING), '0',
         cnpj_fora_do_padrao = 0
  FROM medicoes
)

SELECT
  n,
  teste,
  valor_calculado,
  esperado,
  CASE WHEN passou THEN 'PASSOU'
       ELSE raise_error(concat('TESTE ', CAST(n AS STRING), ' FALHOU: ', teste,
                               ' | calculado = ', valor_calculado,
                               ' | esperado = ',  esperado))
  END                                                                AS resultado
FROM resultados
ORDER BY n;
