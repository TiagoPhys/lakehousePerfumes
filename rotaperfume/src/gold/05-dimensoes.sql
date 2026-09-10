-- Gold · as quatro dimensoes conformadas (e a ponte para o cadastro duplicado).
--
-- "Conformado" nao e enfeite de vocabulario: significa que a mesma dimensao vale
-- para todos os marts, entao os tres somam o MESMO numero. Se cada diretoria tiver
-- a sua propria dim_cliente, em tres meses elas divergem e a reuniao vira uma
-- discussao sobre qual sistema esta certo.
--
-- A gold le SO da silver. Nunca da bronze: a bronze e texto e sujeira preservada,
-- e voltar la seria refazer a limpeza por fora do contrato.

-- ---------------------------------------------------------------------------
-- 0 · _mapa_cliente — a ponte que traduz o cadastro descartado
-- ---------------------------------------------------------------------------
-- Ontem a silver deduplicou 40 CNPJs e guardou o cliente_id descartado num array,
-- com o argumento de que "os pedidos antigos continuam apontando para ele".
--
-- MEDIDO ANTES DE ACREDITAR NO ARGUMENTO: hoje nenhum aponta. Os 40 ids
-- descartados sao os de 3001 a 3040 — o segundo cadastro, criado depois — e
-- nenhum pedido, carteira, visita ou oportunidade referencia eles. A dedup
-- manteve justamente o cadastro que tem historico, que era o objetivo dela.
--
-- A ponte fica mesmo assim, por dois motivos honestos:
--   1. custa 40 linhas e um LEFT JOIN, e troca "confio que o ERP nunca vai mandar
--      o id antigo" por "se mandar, a gold traduz e o total continua fechando";
--   2. e o unico consumidor de cliente_ids_duplicados — sem ela, aquele array da
--      silver vira rastreabilidade que ninguem le.
--
-- O que ela NAO e: conserto de um problema existente. Hoje ela traduz ZERO
-- linhas, e esse numero esta escrito no COMMENT da tabela para ninguem contar
-- uma historia mais bonita do que a verdade.
CREATE OR REPLACE TABLE lakehouse_rotaperfume.gold._mapa_cliente
COMMENT
  'Ponte tecnica: cliente_id descartado na deduplicacao da silver -> cliente_id que sobreviveu. '
  'Sao 40 linhas, uma por CNPJ que estava cadastrado duas vezes. HOJE ELA TRADUZ ZERO LINHAS: '
  'medido, nenhum pedido, carteira, visita ou oportunidade aponta para um id descartado (todos '
  'estao na faixa 3001-3040, do segundo cadastro). Existe como defesa — se o ERP um dia mandar o '
  'id antigo, o fato traduz em vez de perder a receita ou criar um cliente orfao.'
AS
SELECT
  explode(cliente_ids_duplicados)                                   AS cliente_id_antigo,
  cliente_id                                                        AS cliente_id_valido,
  cnpj                                                              AS cnpj,
  current_timestamp()                                               AS _processado_em
FROM lakehouse_rotaperfume.silver.clientes
WHERE size(cliente_ids_duplicados) > 0;

-- ---------------------------------------------------------------------------
-- 1 · dim_cliente — uma linha por cliente, ja com o historico de compra
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE lakehouse_rotaperfume.gold.dim_cliente
COMMENT
  'Dimensao conformada de cliente: 3.000 linhas, uma por CNPJ. Alem do cadastro, traz o '
  'comportamento de compra (primeiro e ultimo pedido, quantos pedidos, receita acumulada, dias sem '
  'comprar), calculado sobre pedidos NAO cancelados. O cliente_id passa por gold._mapa_cliente antes '
  'de agrupar, para que um pedido preso no cadastro duplicado caisse no cliente certo — hoje isso '
  'nao acontece com nenhum pedido. SUM(receita_acumulada) fecha com a silver no centavo.'
AS
WITH pedido_do_cliente AS (
  SELECT
    -- o id antigo vira o id que sobreviveu; quem nunca foi duplicado passa direto
    coalesce(m.cliente_id_valido, p.cliente_id)                     AS cliente_id,
    p.pedido_id,
    p.data_pedido,
    p.valor_liquido
  FROM lakehouse_rotaperfume.silver.pedidos p
  LEFT JOIN lakehouse_rotaperfume.gold._mapa_cliente m
         ON m.cliente_id_antigo = p.cliente_id
  WHERE NOT p.cancelado
),

resumo AS (
  SELECT
    cliente_id,
    MIN(data_pedido)                                                AS primeiro_pedido,
    MAX(data_pedido)                                                AS ultimo_pedido,
    COUNT(DISTINCT pedido_id)                                       AS total_pedidos,
    SUM(valor_liquido)                                              AS receita_acumulada
  FROM pedido_do_cliente
  GROUP BY cliente_id
)

SELECT
  c.cliente_id,
  c.cnpj,
  c.razao_social,
  c.segmento,
  c.cidade,
  c.uf,
  c.bairro,
  c.data_cadastro,
  c.ativo,
  r.primeiro_pedido,
  r.ultimo_pedido,
  coalesce(r.total_pedidos, 0)                                      AS total_pedidos,
  coalesce(r.receita_acumulada, CAST(0 AS DECIMAL(18,2)))           AS receita_acumulada,
  datediff(current_date(), r.ultimo_pedido)                         AS dias_sem_comprar,
  current_timestamp()                                               AS _processado_em
FROM lakehouse_rotaperfume.silver.clientes c
LEFT JOIN resumo r ON r.cliente_id = c.cliente_id;

ALTER TABLE lakehouse_rotaperfume.gold.dim_cliente ALTER COLUMN receita_acumulada
  COMMENT 'Quanto este cliente ja comprou, somando so pedidos NAO cancelados. Zero para quem nunca comprou. A soma da coluna inteira reproduz o faturamento da empresa.';

ALTER TABLE lakehouse_rotaperfume.gold.dim_cliente ALTER COLUMN total_pedidos
  COMMENT 'Pedidos NAO cancelados do cliente. Pedido cancelado nao conta como compra — e a mesma regra que o fato aplica.';

ALTER TABLE lakehouse_rotaperfume.gold.dim_cliente ALTER COLUMN dias_sem_comprar
  COMMENT 'Dias entre HOJE e o ultimo pedido do cliente. E nula para quem nunca comprou (nao zero: zero significaria comprou hoje). Recalculada a cada execucao do pipeline, entao o valor envelhece se o job parar de rodar.';

ALTER TABLE lakehouse_rotaperfume.gold.dim_cliente ALTER COLUMN _processado_em
  COMMENT 'Auditoria: quando esta linha foi processada pela gold.';

-- ---------------------------------------------------------------------------
-- 2 · dim_produto
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE lakehouse_rotaperfume.gold.dim_produto
COMMENT
  'Dimensao conformada de produto: 292 SKUs com marca, categoria, nota olfativa, custo e preco de '
  'tabela. E a fonte do custo que o fato usa para calcular margem.'
AS
SELECT
  sku,
  descricao,
  categoria,
  marca,
  nota_olfativa,
  unidade,
  preco_tabela,
  custo_unitario,
  data_lancamento,
  NOT ativo                                                         AS descontinuado,
  current_timestamp()                                               AS _processado_em
FROM lakehouse_rotaperfume.silver.produtos;

ALTER TABLE lakehouse_rotaperfume.gold.dim_produto ALTER COLUMN descontinuado
  COMMENT 'TRUE quando o SKU saiu de linha. Sao 30 dos 292 — e produto descontinuado continua aparecendo em venda antiga, o que e correto: a historia nao se apaga.';

ALTER TABLE lakehouse_rotaperfume.gold.dim_produto ALTER COLUMN custo_unitario
  COMMENT 'Custo de aquisicao por unidade, como veio do ERP. E o que o fato multiplica pela quantidade para chegar no custo da linha.';

ALTER TABLE lakehouse_rotaperfume.gold.dim_produto ALTER COLUMN _processado_em
  COMMENT 'Auditoria: quando esta linha foi processada pela gold.';

-- ---------------------------------------------------------------------------
-- 3 · dim_vendedor
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE lakehouse_rotaperfume.gold.dim_vendedor
COMMENT
  'Dimensao conformada de vendedor: 42 linhas com regiao, meta mensal e situacao. A meta e o '
  'denominador do atingimento em gold.mart_vendas_por_vendedor.'
AS
SELECT
  vendedor_id,
  nome,
  regiao,
  uf,
  data_admissao,
  data_desligamento,
  meta_mensal,
  ativo,
  current_timestamp()                                               AS _processado_em
FROM lakehouse_rotaperfume.silver.vendedores;

ALTER TABLE lakehouse_rotaperfume.gold.dim_vendedor ALTER COLUMN meta_mensal
  COMMENT 'Meta de receita por MES, em reais. Nao e meta anual nem por trimestre — comparar com receita de qualquer outro periodo da um atingimento errado.';

ALTER TABLE lakehouse_rotaperfume.gold.dim_vendedor ALTER COLUMN ativo
  COMMENT 'FALSE para vendedor desligado. Seis dos 42 sairam, e as vendas deles continuam no fato: quem saiu vendeu de verdade enquanto estava aqui.';

ALTER TABLE lakehouse_rotaperfume.gold.dim_vendedor ALTER COLUMN _processado_em
  COMMENT 'Auditoria: quando esta linha foi processada pela gold.';

-- ---------------------------------------------------------------------------
-- 4 · dim_calendario
-- ---------------------------------------------------------------------------
-- O intervalo NAO esta escrito a mao: sai do proprio periodo dos pedidos, do
-- primeiro dia do mes mais antigo ao ultimo dia do mes mais novo. Se amanha
-- chegarem mais tres meses de dado, o calendario cresce sozinho.
CREATE OR REPLACE TABLE lakehouse_rotaperfume.gold.dim_calendario
COMMENT
  'Dimensao conformada de tempo: uma linha por dia dos 24 meses de historia (2024-09-01 a '
  '2026-08-31, 730 dias). O intervalo e derivado do periodo real de silver.pedidos, nao escrito a '
  'mao. Serve para responder pergunta de calendario que o fato nao sabe sozinho — dia da semana, '
  'trimestre, mes de pico do setor.'
AS
WITH periodo AS (
  SELECT trunc(MIN(data_pedido), 'MM') AS inicio,
         last_day(MAX(data_pedido))    AS fim
  FROM lakehouse_rotaperfume.silver.pedidos
),

dias AS (
  SELECT explode(sequence(inicio, fim, INTERVAL 1 DAY)) AS data
  FROM periodo
)

SELECT
  data,
  year(data)                                                        AS ano,
  month(data)                                                       AS mes,
  -- CASE em vez de date_format(data, 'MMMM'): o locale do warehouse e en-US e
  -- devolveria "September". Nome de mes e conteudo de negocio, nao configuracao.
  CASE month(data)
    WHEN  1 THEN 'Janeiro'   WHEN  2 THEN 'Fevereiro' WHEN  3 THEN 'Marco'
    WHEN  4 THEN 'Abril'     WHEN  5 THEN 'Maio'      WHEN  6 THEN 'Junho'
    WHEN  7 THEN 'Julho'     WHEN  8 THEN 'Agosto'    WHEN  9 THEN 'Setembro'
    WHEN 10 THEN 'Outubro'   WHEN 11 THEN 'Novembro'  WHEN 12 THEN 'Dezembro'
  END                                                               AS nome_mes,
  quarter(data)                                                     AS trimestre,
  dayofweek(data)                                                   AS dia_semana,
  CASE dayofweek(data)
    WHEN 1 THEN 'Domingo' WHEN 2 THEN 'Segunda' WHEN 3 THEN 'Terca'
    WHEN 4 THEN 'Quarta'  WHEN 5 THEN 'Quinta'  WHEN 6 THEN 'Sexta'
    WHEN 7 THEN 'Sabado'
  END                                                               AS nome_dia_semana,
  dayofweek(data) IN (1, 7)                                         AS fim_de_semana,
  month(data) IN (4, 6, 10)                                         AS mes_pico_setor,
  current_timestamp()                                               AS _processado_em
FROM dias;

ALTER TABLE lakehouse_rotaperfume.gold.dim_calendario ALTER COLUMN mes_pico_setor
  COMMENT 'Abril, junho e outubro — os meses de pico do setor de perfumaria (Dia das Maes, Dia dos Namorados e a antecipacao do Natal no atacado). E uma regra do NEGOCIO, nao um calculo: quem discordar dela discute a lista, nao a query.';

ALTER TABLE lakehouse_rotaperfume.gold.dim_calendario ALTER COLUMN dia_semana
  COMMENT 'Numero do dia da semana no padrao do Spark: 1 = domingo, 7 = sabado. Use nome_dia_semana para exibir.';

ALTER TABLE lakehouse_rotaperfume.gold.dim_calendario ALTER COLUMN _processado_em
  COMMENT 'Auditoria: quando esta linha foi processada pela gold.';
