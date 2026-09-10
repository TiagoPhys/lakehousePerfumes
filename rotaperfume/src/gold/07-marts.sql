-- Gold · tres marts, uma diretoria cada, o MESMO fato embaixo.
--
-- O erro classico e criar fato_vendas_comercial e fato_vendas_produto. Em tres
-- meses eles divergem, e ninguem sabe qual esta certo — porque os dois estao
-- errados de formas diferentes.
--
-- O que separa um mart do outro NAO e a tabela base: e a dimensao dominante e as
-- metricas. Os dois primeiros aqui saem da mesma gold.fato_vendas, so mudam o
-- GROUP BY, e por isso somam identico: R$ 102.303.828,05 nos dois.
--
-- O terceiro e a excecao honesta: recebimento nao existe no fato de vendas
-- (venda e recebimento sao eventos diferentes, em datas diferentes), entao ele
-- sai de silver.pagamentos. Esta escrito no COMMENT dele para ninguem tentar
-- cruzar as duas tabelas por engano.

-- ---------------------------------------------------------------------------
-- 1 · mart_vendas_por_vendedor — a diretoria comercial
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE lakehouse_rotaperfume.gold.mart_vendas_por_vendedor
COMMENT
  'Mart da diretoria comercial, no grao VENDEDOR x MES: receita, margem, meta e atingimento, mais '
  'quantos clientes o vendedor atendeu e o ticket medio dos pedidos dele. Sai inteiro de '
  'gold.fato_vendas — SUM(receita) aqui e igual a SUM(receita) do fato e igual ao faturamento da '
  'silver. E isso que a palavra conformado significa.'
AS
WITH por_vendedor_mes AS (
  SELECT
    f.vendedor_id,
    f.ano,
    f.mes,
    SUM(f.receita)                                                  AS receita,
    SUM(f.margem)                                                   AS margem,
    COUNT(DISTINCT f.cliente_id)                                    AS clientes_atendidos,
    COUNT(DISTINCT f.pedido_id)                                     AS pedidos
  FROM lakehouse_rotaperfume.gold.fato_vendas f
  GROUP BY f.vendedor_id, f.ano, f.mes
)

SELECT
  a.vendedor_id,
  v.nome                                                            AS vendedor,
  v.regiao,
  v.uf,
  v.ativo                                                           AS vendedor_ativo,
  a.ano,
  a.mes,
  a.receita,
  a.margem,
  v.meta_mensal,
  ROUND(100 * a.receita / v.meta_mensal, 1)                         AS atingimento_pct,
  a.clientes_atendidos,
  a.pedidos,
  ROUND(a.receita / a.pedidos, 2)                                   AS ticket_medio,
  current_timestamp()                                               AS _processado_em
-- LEFT JOIN de proposito: se um dia aparecer venda de um vendedor que nao esta
-- na dimensao, a receita dele NAO pode sumir do mart — o total tem que continuar
-- fechando, e o buraco tem que aparecer como meta nula.
FROM por_vendedor_mes a
LEFT JOIN lakehouse_rotaperfume.gold.dim_vendedor v
       ON v.vendedor_id = a.vendedor_id;

ALTER TABLE lakehouse_rotaperfume.gold.mart_vendas_por_vendedor ALTER COLUMN atingimento_pct
  COMMENT 'Receita do mes dividida pela meta MENSAL do vendedor, em porcentagem: 100 significa meta batida na risca. A meta e sempre mensal, entao comparar com receita de outro periodo da numero errado.';

ALTER TABLE lakehouse_rotaperfume.gold.mart_vendas_por_vendedor ALTER COLUMN clientes_atendidos
  COMMENT 'Clientes distintos que compraram com este vendedor no mes. Nao e a carteira dele: e quem efetivamente comprou.';

ALTER TABLE lakehouse_rotaperfume.gold.mart_vendas_por_vendedor ALTER COLUMN ticket_medio
  COMMENT 'Receita do mes dividida pelo numero de PEDIDOS (nao de itens). Devolucao entra no calculo, entao um mes com muita devolucao derruba o ticket — que e o comportamento correto.';

ALTER TABLE lakehouse_rotaperfume.gold.mart_vendas_por_vendedor ALTER COLUMN _processado_em
  COMMENT 'Auditoria: quando esta linha foi processada pela gold.';

-- ---------------------------------------------------------------------------
-- 2 · mart_produto_performance — a diretoria de produto
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE lakehouse_rotaperfume.gold.mart_produto_performance
COMMENT
  'Mart da diretoria de produto, no grao SKU x MES: receita, margem, margem percentual, quantidade '
  'e a curva ABC por receita acumulada DENTRO DO MES. Sai inteiro de gold.fato_vendas: SUM(receita) '
  'aqui bate com o fato, e e exatamente isso que o teste 8 verifica.'
AS
WITH por_sku_mes AS (
  SELECT
    f.ano,
    f.mes,
    f.sku,
    f.categoria,
    f.marca,
    SUM(f.receita)                                                  AS receita,
    SUM(f.margem)                                                   AS margem,
    SUM(f.quantidade)                                               AS quantidade
  FROM lakehouse_rotaperfume.gold.fato_vendas f
  GROUP BY f.ano, f.mes, f.sku, f.categoria, f.marca
),

acumulado AS (
  SELECT
    *,
    SUM(receita) OVER (PARTITION BY ano, mes)                       AS receita_do_mes,
    -- receita acumulada do maior para o menor, dentro do mes: e a curva ABC
    SUM(receita) OVER (PARTITION BY ano, mes ORDER BY receita DESC, sku
                       ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
                                                                    AS receita_acumulada
  FROM por_sku_mes
)

SELECT
  ano,
  mes,
  sku,
  categoria,
  marca,
  receita,
  margem,
  ROUND(100 * margem / receita, 1)                                  AS margem_pct,
  quantidade,
  ROUND(100 * receita_acumulada / receita_do_mes, 1)                AS receita_acumulada_pct,
  CASE
    WHEN 100 * receita_acumulada / receita_do_mes <= 80 THEN 'A'
    WHEN 100 * receita_acumulada / receita_do_mes <= 95 THEN 'B'
    ELSE 'C'
  END                                                               AS curva_abc,
  current_timestamp()                                               AS _processado_em
FROM acumulado;

ALTER TABLE lakehouse_rotaperfume.gold.mart_produto_performance ALTER COLUMN curva_abc
  COMMENT 'Classificacao ABC por receita acumulada DENTRO DE CADA MES: A ate 80% da receita do mes, B ate 95%, C o resto. Como a curva e mensal, o mesmo SKU pode ser A em outubro e C em janeiro — e essa mudanca e a informacao, nao um defeito.';

ALTER TABLE lakehouse_rotaperfume.gold.mart_produto_performance ALTER COLUMN margem_pct
  COMMENT 'Margem dividida pela receita do SKU no mes, em porcentagem. Por categoria a variacao e grande: Kit Presente fica em 33% e Oleo Concentrado em 50%.';

ALTER TABLE lakehouse_rotaperfume.gold.mart_produto_performance ALTER COLUMN quantidade
  COMMENT 'Unidades liquidas no mes: venda menos devolucao. Pode ser negativa num mes em que o SKU so foi devolvido.';

ALTER TABLE lakehouse_rotaperfume.gold.mart_produto_performance ALTER COLUMN receita_acumulada_pct
  COMMENT 'Onde este SKU cai na curva acumulada do mes, do maior para o menor. E o numero que sustenta a coluna curva_abc.';

ALTER TABLE lakehouse_rotaperfume.gold.mart_produto_performance ALTER COLUMN _processado_em
  COMMENT 'Auditoria: quando esta linha foi processada pela gold.';

-- ---------------------------------------------------------------------------
-- 3 · mart_financeiro_recebimento — a diretoria financeira
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE lakehouse_rotaperfume.gold.mart_financeiro_recebimento
COMMENT
  'Mart da diretoria financeira, no grao MES DE VENCIMENTO: quanto ha a receber, quanto entrou, o '
  'atraso medio e o custo das taxas de meio de pagamento. Unico mart que NAO sai de gold.fato_vendas: '
  'venda e recebimento sao eventos diferentes, em datas diferentes, e por isso ele le '
  'silver.pagamentos. O total a receber (R$ 102.303.828,05) coincide com o faturamento porque todo '
  'pedido nao cancelado gerou lancamento — mas o MES aqui e o de vencimento, nao o da venda.'
AS
SELECT
  year(data_vencimento)                                             AS ano_vencimento,
  month(data_vencimento)                                            AS mes_vencimento,
  COUNT(*)                                                          AS lancamentos,
  SUM(valor)                                                        AS valor_a_receber,
  SUM(valor) FILTER (WHERE data_pagamento IS NOT NULL)              AS recebido,
  SUM(valor) FILTER (WHERE data_pagamento IS NULL)                  AS em_aberto,
  ROUND(AVG(datediff(data_pagamento, data_vencimento))
          FILTER (WHERE data_pagamento IS NOT NULL), 1)             AS atraso_medio_dias,
  SUM(valor - valor_liquido)                                        AS custo_taxa,
  current_timestamp()                                               AS _processado_em
FROM lakehouse_rotaperfume.silver.pagamentos
GROUP BY year(data_vencimento), month(data_vencimento);

ALTER TABLE lakehouse_rotaperfume.gold.mart_financeiro_recebimento ALTER COLUMN valor_a_receber
  COMMENT 'Tudo que vence neste mes, pago ou nao. E o compromisso do mes, nao o caixa realizado.';

ALTER TABLE lakehouse_rotaperfume.gold.mart_financeiro_recebimento ALTER COLUMN recebido
  COMMENT 'Do que vencia neste mes, quanto ja foi pago — mesmo que o pagamento tenha caido depois do vencimento.';

ALTER TABLE lakehouse_rotaperfume.gold.mart_financeiro_recebimento ALTER COLUMN em_aberto
  COMMENT 'Do que vencia neste mes, quanto ainda nao entrou. Em mes passado isso e inadimplencia; em mes futuro e so previsao.';

ALTER TABLE lakehouse_rotaperfume.gold.mart_financeiro_recebimento ALTER COLUMN atraso_medio_dias
  COMMENT 'Media de dias entre vencimento e pagamento, considerando SO os lancamentos ja pagos. Valor negativo significa pagamento antecipado, e ele puxa a media para baixo: a media geral e de 5 dias, mas entre os que atrasaram de fato o atraso e de 11.';

ALTER TABLE lakehouse_rotaperfume.gold.mart_financeiro_recebimento ALTER COLUMN custo_taxa
  COMMENT 'Quanto a empresa deixou na mesa em taxa de meio de pagamento (valor bruto menos valor liquido). Sao R$ 537.927,96 no periodo inteiro — meio milhao que nao aparece em nenhum relatorio de vendas.';

ALTER TABLE lakehouse_rotaperfume.gold.mart_financeiro_recebimento ALTER COLUMN _processado_em
  COMMENT 'Auditoria: quando esta linha foi processada pela gold.';
