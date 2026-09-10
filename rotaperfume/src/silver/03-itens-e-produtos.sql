-- Silver · produtos e itens_pedido — a devolucao e a decisao da noite.
--
-- Sao 2.327 itens com quantidade NEGATIVA. Isso nao e erro de digitacao: e
-- devolucao. E existem tres caminhos, cada um dando um numero diferente para o
-- diretor:
--
--   1. descartar as linhas negativas    -> o faturamento INFLA em mais de um milhao
--   2. manter, sem sinalizar            -> toda soma da empresa fica poluida
--   3. manter E sinalizar               -> preserva os dois numeros
--
-- Este arquivo faz o terceiro: nenhuma linha e descartada, e duas colunas novas
-- (devolucao e quantidade_abs) deixam quem faz a analise escolher o bruto ou o
-- liquido. A decisao vira coluna, nao vira filtro escondido.
--
-- A ordem dos dois blocos importa: produtos primeiro, porque itens_pedido faz
-- join com ela para marcar o SKU descontinuado.

-- ---------------------------------------------------------------------------
-- 1 · produtos
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE lakehouse_rotaperfume.silver.produtos
COMMENT
  'Silver produtos: catalogo tipado (precos em DECIMAL, ativo em BOOLEAN, data_lancamento em DATE). '
  'Sao 292 SKUs, 30 deles ja inativos — e e essa coluna que marca sku_descontinuado em '
  'silver.itens_pedido. data_lancamento e nula em 245 produtos: a origem nao preencheu, e a '
  'silver preserva a ausencia em vez de inventar uma data.'
AS
SELECT
  trim(sku)                                                        AS sku,
  trim(descricao)                                                  AS descricao,
  trim(categoria)                                                  AS categoria,
  trim(marca)                                                      AS marca,
  trim(nota_olfativa)                                              AS nota_olfativa,
  CAST(preco_tabela    AS DECIMAL(18,2))                           AS preco_tabela,
  CAST(custo_unitario  AS DECIMAL(18,2))                           AS custo_unitario,
  trim(unidade)                                                    AS unidade,
  upper(trim(ativo)) = 'S'                                         AS ativo,
  coalesce(try_to_date(data_lancamento),
           try_to_date(data_lancamento, 'dd/MM/yyyy'))             AS data_lancamento,
  current_timestamp()                                              AS _processado_em,
  (SELECT COUNT(*) FROM lakehouse_rotaperfume.bronze.produtos)      AS _linhas_origem
FROM lakehouse_rotaperfume.bronze.produtos;

ALTER TABLE lakehouse_rotaperfume.silver.produtos ALTER COLUMN ativo
  COMMENT 'BOOLEAN a partir do S/N da origem. 30 SKUs estao inativos — e sao eles que marcam sku_descontinuado nos itens de pedido.';

ALTER TABLE lakehouse_rotaperfume.silver.produtos ALTER COLUMN data_lancamento
  COMMENT 'DATE via try_to_date. Nula em 245 produtos porque a origem veio vazia: ausencia preservada de proposito, nao preenchida com uma data inventada.';

ALTER TABLE lakehouse_rotaperfume.silver.produtos ALTER COLUMN _processado_em
  COMMENT 'Auditoria: quando esta linha foi processada pela silver.';

ALTER TABLE lakehouse_rotaperfume.silver.produtos ALTER COLUMN _linhas_origem
  COMMENT 'Auditoria: quantas linhas a bronze tinha nesta execucao (292).';

-- ---------------------------------------------------------------------------
-- 2 · itens_pedido
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE lakehouse_rotaperfume.silver.itens_pedido
COMMENT
  'Silver itens_pedido: 197.724 linhas, as MESMAS da bronze — nada foi descartado. Os 2.327 itens '
  'com quantidade negativa sao devolucao, e estao marcados em devolucao (boolean) com o valor '
  'absoluto em quantidade_abs. Descartar essas linhas inflaria o faturamento em mais de um milhao; '
  'mante-las sem flag poluiria toda soma. sku_descontinuado cruza com silver.produtos e expoe 76 '
  'itens vendidos de SKU que nao esta mais ativo.'
AS
SELECT
  CAST(i.item_id   AS INT)                                         AS item_id,
  CAST(i.pedido_id AS INT)                                         AS pedido_id,
  trim(i.sku)                                                      AS sku,
  CAST(i.quantidade AS INT)                                        AS quantidade,
  -- a decisao da noite: sinalizar em vez de descartar ou de somar calado
  CAST(i.quantidade AS INT) < 0                                    AS devolucao,
  abs(CAST(i.quantidade AS INT))                                   AS quantidade_abs,
  CAST(i.preco_praticado AS DECIMAL(18,2))                         AS preco_praticado,
  CAST(i.desconto_pct    AS DECIMAL(9,2))                          AS desconto_pct,
  CAST(i.valor_bruto     AS DECIMAL(18,2))                         AS valor_bruto,
  -- LEFT JOIN + coalesce: se amanha o ERP mandar um SKU que ainda nao esta no
  -- catalogo, o item entra marcado como nao-descontinuado em vez de derrubar a
  -- tarefa. Hoje sao zero SKUs orfaos, e e bom que continue assim.
  NOT coalesce(p.ativo, true)                                      AS sku_descontinuado,
  current_timestamp()                                              AS _processado_em,
  (SELECT COUNT(*) FROM lakehouse_rotaperfume.bronze.itens_pedido)  AS _linhas_origem
FROM lakehouse_rotaperfume.bronze.itens_pedido i
LEFT JOIN lakehouse_rotaperfume.silver.produtos p
       ON trim(i.sku) = p.sku;

ALTER TABLE lakehouse_rotaperfume.silver.itens_pedido ALTER COLUMN quantidade
  COMMENT 'INT, com o sinal da origem preservado. Negativo significa devolucao — nao e erro, e nao foi corrigido.';

ALTER TABLE lakehouse_rotaperfume.silver.itens_pedido ALTER COLUMN devolucao
  COMMENT 'BOOLEAN: quantidade negativa na origem. Sao 2.327 itens. A linha NAO foi descartada — descartar inflaria o faturamento em mais de um milhao de reais, e manter sem flag poluiria toda soma da empresa.';

ALTER TABLE lakehouse_rotaperfume.silver.itens_pedido ALTER COLUMN quantidade_abs
  COMMENT 'Valor absoluto de quantidade. E o campo para somar volume vendido sem que a devolucao subtraia por acidente; use devolucao para separar os dois sentidos.';

ALTER TABLE lakehouse_rotaperfume.silver.itens_pedido ALTER COLUMN sku_descontinuado
  COMMENT 'BOOLEAN do join com silver.produtos: o item foi vendido, mas o SKU nao esta mais ativo no catalogo. Sao 76 itens. A coluna EXPOE o caso em vez de esconde-lo.';

ALTER TABLE lakehouse_rotaperfume.silver.itens_pedido ALTER COLUMN _processado_em
  COMMENT 'Auditoria: quando esta linha foi processada pela silver.';

ALTER TABLE lakehouse_rotaperfume.silver.itens_pedido ALTER COLUMN _linhas_origem
  COMMENT 'Auditoria: quantas linhas a bronze tinha nesta execucao (197.724). Tem que ser igual ao COUNT(*): nenhum item foi descartado.';

-- Quantidade zero nao existe em item de pedido — nem vendido, nem devolvido.
-- Se um dia entrar, a tabela recusa, e alguem vai ter que explicar o que aquilo
-- significa antes de virar numero em dashboard.
ALTER TABLE lakehouse_rotaperfume.silver.itens_pedido DROP CONSTRAINT IF EXISTS quantidade_positiva;
ALTER TABLE lakehouse_rotaperfume.silver.itens_pedido ADD  CONSTRAINT quantidade_positiva
  CHECK (quantidade_abs > 0);
