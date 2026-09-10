-- Silver · CRM e financeiro — seis tabelas, e uma coluna que denuncia um problema.
--
-- Aqui esta a decisao mais desconfortavel da camada: existe vendedor DESLIGADO com
-- carteira de cliente vigente. Sao 441 carteiras.
--
-- A tentacao e "consertar": fechar a carteira na data do desligamento e seguir a
-- vida. Isso e reescrever a historia da empresa dentro de um pipeline, sem ninguem
-- ter decidido. A silver faz o oposto: cria a coluna vigente (que respeita data_fim
-- E data_desligamento) e a coluna orfao_vendedor_desligado, que EXPOE o caso para o
-- gestor resolver no sistema de origem, que e onde se resolve.
--
-- A ordem importa: vendedores primeiro, porque carteira faz join com ela.

-- ---------------------------------------------------------------------------
-- 1 · vendedores
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE lakehouse_rotaperfume.silver.vendedores
COMMENT
  'Silver vendedores: 42 vendedores com datas tipadas e meta em DECIMAL. Seis estao desligados, '
  'e e o cruzamento dessa data com silver.carteira que revela as 441 carteiras orfas.'
AS
SELECT
  CAST(vendedor_id AS INT)                                          AS vendedor_id,
  trim(nome)                                                        AS nome,
  trim(regiao)                                                      AS regiao,
  upper(trim(uf))                                                   AS uf,
  coalesce(try_to_date(data_admissao),
           try_to_date(data_admissao, 'dd/MM/yyyy'))                AS data_admissao,
  coalesce(try_to_date(data_desligamento),
           try_to_date(data_desligamento, 'dd/MM/yyyy'))            AS data_desligamento,
  CAST(meta_mensal AS DECIMAL(18,2))                                AS meta_mensal,
  coalesce(try_to_date(data_desligamento),
           try_to_date(data_desligamento, 'dd/MM/yyyy')) IS NULL    AS ativo,
  current_timestamp()                                               AS _processado_em,
  (SELECT COUNT(*) FROM lakehouse_rotaperfume.bronze.vendedores)     AS _linhas_origem
FROM lakehouse_rotaperfume.bronze.vendedores;

ALTER TABLE lakehouse_rotaperfume.silver.vendedores ALTER COLUMN data_desligamento
  COMMENT 'DATE via try_to_date. Nula para quem continua na empresa — a ausencia E a informacao, e por isso nao foi preenchida com nada.';

ALTER TABLE lakehouse_rotaperfume.silver.vendedores ALTER COLUMN ativo
  COMMENT 'BOOLEAN derivado da ausencia de data_desligamento. Seis dos 42 vendedores estao desligados.';

ALTER TABLE lakehouse_rotaperfume.silver.vendedores ALTER COLUMN _processado_em
  COMMENT 'Auditoria: quando esta linha foi processada pela silver.';

ALTER TABLE lakehouse_rotaperfume.silver.vendedores ALTER COLUMN _linhas_origem
  COMMENT 'Auditoria: quantas linhas a bronze tinha nesta execucao (42).';

-- ---------------------------------------------------------------------------
-- 2 · carteira — a tabela que expoe o problema em vez de esconde-lo
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE lakehouse_rotaperfume.silver.carteira
COMMENT
  'Silver carteira: quem atende qual cliente. A coluna vigente respeita data_fim E o desligamento '
  'do vendedor. A coluna orfao_vendedor_desligado marca as 441 carteiras que continuam abertas com '
  'vendedor ja desligado — o dado NAO foi corrigido de proposito: fechar essas carteiras dentro do '
  'pipeline seria reescrever a historia da empresa sem ninguem ter decidido isso.'
AS
WITH datada AS (
  SELECT
    CAST(c.carteira_id AS INT)                                      AS carteira_id,
    CAST(c.cliente_id  AS INT)                                      AS cliente_id,
    CAST(c.vendedor_id AS INT)                                      AS vendedor_id,
    coalesce(try_to_date(c.data_inicio),
             try_to_date(c.data_inicio, 'dd/MM/yyyy'))              AS data_inicio,
    coalesce(try_to_date(c.data_fim),
             try_to_date(c.data_fim, 'dd/MM/yyyy'))                 AS data_fim,
    v.data_desligamento                                             AS vendedor_desligado_em
  FROM lakehouse_rotaperfume.bronze.carteira c
  LEFT JOIN lakehouse_rotaperfume.silver.vendedores v
         ON CAST(c.vendedor_id AS INT) = v.vendedor_id
)

SELECT
  carteira_id,
  cliente_id,
  vendedor_id,
  data_inicio,
  data_fim,
  vendedor_desligado_em,
  -- vigente de verdade: a carteira esta aberta E o vendedor ainda esta na empresa
  (data_fim IS NULL OR data_fim > current_date())
    AND vendedor_desligado_em IS NULL                               AS vigente,
  -- e o caso que ninguem quer ver: aberta pela data, mas o dono saiu
  (data_fim IS NULL OR data_fim > current_date())
    AND vendedor_desligado_em IS NOT NULL                           AS orfao_vendedor_desligado,
  current_timestamp()                                               AS _processado_em,
  (SELECT COUNT(*) FROM lakehouse_rotaperfume.bronze.carteira)       AS _linhas_origem
FROM datada;

ALTER TABLE lakehouse_rotaperfume.silver.carteira ALTER COLUMN data_fim
  COMMENT 'DATE via try_to_date. Nula em 3.000 carteiras, que e como a origem diz sem prazo de encerramento.';

ALTER TABLE lakehouse_rotaperfume.silver.carteira ALTER COLUMN vendedor_desligado_em
  COMMENT 'Data de desligamento do vendedor, trazida de silver.vendedores. Fica na linha para a investigacao nao precisar de mais um join.';

ALTER TABLE lakehouse_rotaperfume.silver.carteira ALTER COLUMN vigente
  COMMENT 'BOOLEAN que respeita as DUAS condicoes: carteira sem data_fim (ou com data_fim futura) E vendedor ainda na empresa. Uma carteira de vendedor desligado nao e vigente, por mais que a data diga que sim.';

ALTER TABLE lakehouse_rotaperfume.silver.carteira ALTER COLUMN orfao_vendedor_desligado
  COMMENT 'BOOLEAN que EXPOE o problema: 441 carteiras seguem abertas pela data, mas o vendedor esta desligado. O dado nao foi corrigido — quem resolve isso e o gestor, no sistema de origem. Mutuamente exclusiva com vigente.';

ALTER TABLE lakehouse_rotaperfume.silver.carteira ALTER COLUMN _processado_em
  COMMENT 'Auditoria: quando esta linha foi processada pela silver.';

ALTER TABLE lakehouse_rotaperfume.silver.carteira ALTER COLUMN _linhas_origem
  COMMENT 'Auditoria: quantas linhas a bronze tinha nesta execucao (3.637).';

-- ---------------------------------------------------------------------------
-- 3 · oportunidades
-- ---------------------------------------------------------------------------
-- CONFERIDO ANTES DE ESCREVER O CASE, com SELECT DISTINCT etapa:
--   Fechado ganho (1.487) · Fechado perdido (773) · Negociacao · Proposta enviada
--   Qualificacao · Prospeccao
-- As etapas NAO se chamam Ganha e Perdida. Chutar o nome do valor e o jeito mais
-- rapido de entregar uma coluna que da falso em toda linha sem ninguem perceber.
CREATE OR REPLACE TABLE lakehouse_rotaperfume.silver.oportunidades
COMMENT
  'Silver oportunidades: funil do CRM tipado. As colunas ganha/perdida/em_aberto vem das etapas '
  'REAIS da origem (Fechado ganho e Fechado perdido, conferidas com SELECT DISTINCT antes do CASE) '
  'e nao de nomes supostos. ciclo_dias e nulo nas 3.719 oportunidades ainda abertas.'
AS
SELECT
  CAST(oportunidade_id AS INT)                                      AS oportunidade_id,
  CAST(cliente_id      AS INT)                                      AS cliente_id,
  CAST(vendedor_id     AS INT)                                      AS vendedor_id,
  trim(origem)                                                      AS origem,
  coalesce(try_to_date(data_abertura),
           try_to_date(data_abertura, 'dd/MM/yyyy'))                AS data_abertura,
  trim(etapa)                                                       AS etapa,
  trim(etapa) = 'Fechado ganho'                                     AS ganha,
  trim(etapa) = 'Fechado perdido'                                   AS perdida,
  trim(etapa) NOT IN ('Fechado ganho', 'Fechado perdido')           AS em_aberto,
  CAST(probabilidade_pct AS DECIMAL(9,2))                           AS probabilidade_pct,
  CAST(valor_estimado    AS DECIMAL(18,2))                          AS valor_estimado,
  coalesce(try_to_date(data_fechamento),
           try_to_date(data_fechamento, 'dd/MM/yyyy'))              AS data_fechamento,
  -- nullif antes do CAST: com ANSI mode, CAST de texto vazio para INT aborta
  CAST(nullif(trim(ciclo_dias), '') AS INT)                         AS ciclo_dias,
  nullif(trim(motivo_perda), '')                                    AS motivo_perda,
  current_timestamp()                                               AS _processado_em,
  (SELECT COUNT(*) FROM lakehouse_rotaperfume.bronze.oportunidades)  AS _linhas_origem
FROM lakehouse_rotaperfume.bronze.oportunidades;

ALTER TABLE lakehouse_rotaperfume.silver.oportunidades ALTER COLUMN ganha
  COMMENT 'BOOLEAN da etapa Fechado ganho — o nome REAL na origem, conferido com SELECT DISTINCT etapa antes de escrever o CASE. Nao e Ganha: chutar o valor entrega uma coluna que da falso em toda linha, sem erro nenhum.';

ALTER TABLE lakehouse_rotaperfume.silver.oportunidades ALTER COLUMN perdida
  COMMENT 'BOOLEAN da etapa Fechado perdido — idem, o nome real da origem.';

ALTER TABLE lakehouse_rotaperfume.silver.oportunidades ALTER COLUMN em_aberto
  COMMENT 'BOOLEAN: qualquer etapa que nao seja um dos dois fechamentos. Definida por exclusao para que uma etapa nova do CRM caia aqui em vez de sumir da conta.';

ALTER TABLE lakehouse_rotaperfume.silver.oportunidades ALTER COLUMN ciclo_dias
  COMMENT 'INT, nulo nas oportunidades ainda abertas (3.719). O nullif antes do CAST e obrigatorio: com ANSI mode ligado, CAST de texto vazio para INT aborta a query.';

ALTER TABLE lakehouse_rotaperfume.silver.oportunidades ALTER COLUMN _processado_em
  COMMENT 'Auditoria: quando esta linha foi processada pela silver.';

ALTER TABLE lakehouse_rotaperfume.silver.oportunidades ALTER COLUMN _linhas_origem
  COMMENT 'Auditoria: quantas linhas a bronze tinha nesta execucao (5.979).';

-- ---------------------------------------------------------------------------
-- 4 · visitas
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE lakehouse_rotaperfume.silver.visitas
COMMENT
  'Silver visitas: agenda de campo tipada. Sem regra de negocio inventada — a origem esta limpa '
  'aqui, e a silver so converte tipo. Inventar coluna onde nao ha decisao a tomar e ruido.'
AS
SELECT
  CAST(visita_id   AS INT)                                          AS visita_id,
  CAST(cliente_id  AS INT)                                          AS cliente_id,
  CAST(vendedor_id AS INT)                                          AS vendedor_id,
  coalesce(try_to_date(data_visita),
           try_to_date(data_visita, 'dd/MM/yyyy'))                  AS data_visita,
  trim(resultado)                                                   AS resultado,
  CAST(duracao_min AS INT)                                          AS duracao_min,
  current_timestamp()                                               AS _processado_em,
  (SELECT COUNT(*) FROM lakehouse_rotaperfume.bronze.visitas)        AS _linhas_origem
FROM lakehouse_rotaperfume.bronze.visitas;

ALTER TABLE lakehouse_rotaperfume.silver.visitas ALTER COLUMN _processado_em
  COMMENT 'Auditoria: quando esta linha foi processada pela silver.';

ALTER TABLE lakehouse_rotaperfume.silver.visitas ALTER COLUMN _linhas_origem
  COMMENT 'Auditoria: quantas linhas a bronze tinha nesta execucao (37.936).';

-- ---------------------------------------------------------------------------
-- 5 · pagamentos
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE lakehouse_rotaperfume.silver.pagamentos
COMMENT
  'Silver pagamentos: recebiveis tipados. data_pagamento e nula em 1.865 lancamentos, e essa '
  'ausencia E a informacao (em aberto ou inadimplente) — nao foi preenchida com nada.'
AS
SELECT
  CAST(pagamento_id AS INT)                                         AS pagamento_id,
  CAST(pedido_id    AS INT)                                         AS pedido_id,
  trim(forma_pagamento)                                             AS forma_pagamento,
  CAST(parcelas AS INT)                                             AS parcelas,
  CAST(valor         AS DECIMAL(18,2))                              AS valor,
  CAST(taxa_pct      AS DECIMAL(9,2))                               AS taxa_pct,
  CAST(valor_liquido AS DECIMAL(18,2))                              AS valor_liquido,
  coalesce(try_to_date(data_vencimento),
           try_to_date(data_vencimento, 'dd/MM/yyyy'))              AS data_vencimento,
  coalesce(try_to_date(data_pagamento),
           try_to_date(data_pagamento, 'dd/MM/yyyy'))               AS data_pagamento,
  trim(status_pagamento)                                            AS status_pagamento,
  current_timestamp()                                               AS _processado_em,
  (SELECT COUNT(*) FROM lakehouse_rotaperfume.bronze.pagamentos)     AS _linhas_origem
FROM lakehouse_rotaperfume.bronze.pagamentos;

ALTER TABLE lakehouse_rotaperfume.silver.pagamentos ALTER COLUMN data_pagamento
  COMMENT 'DATE via try_to_date. Nula em 1.865 lancamentos ainda nao pagos — ausencia preservada, porque e ela que diz que o dinheiro nao entrou.';

ALTER TABLE lakehouse_rotaperfume.silver.pagamentos ALTER COLUMN valor_liquido
  COMMENT 'Valor ja descontada a taxa da forma de pagamento, como veio da origem. Nao confundir com silver.pedidos.valor_liquido, que trata cancelamento.';

ALTER TABLE lakehouse_rotaperfume.silver.pagamentos ALTER COLUMN _processado_em
  COMMENT 'Auditoria: quando esta linha foi processada pela silver.';

ALTER TABLE lakehouse_rotaperfume.silver.pagamentos ALTER COLUMN _linhas_origem
  COMMENT 'Auditoria: quantas linhas a bronze tinha nesta execucao (27.772).';

-- ---------------------------------------------------------------------------
-- 6 · estoque
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE lakehouse_rotaperfume.silver.estoque
COMMENT
  'Silver estoque: snapshot diario por SKU. ruptura e RECALCULADA a partir de saldo = 0 em vez de '
  'copiada do S/N da origem — sao 984 rupturas, e nesta carga as duas versoes concordam em 100% '
  'das 8.400 linhas. Recalcular deixa a definicao visivel no codigo: ruptura e saldo zero, e nao '
  'o que alguem marcou num campo la atras.'
AS
SELECT
  coalesce(try_to_date(data_snapshot),
           try_to_date(data_snapshot, 'dd/MM/yyyy'))                AS data_snapshot,
  trim(sku)                                                         AS sku,
  CAST(saldo AS INT)                                                AS saldo,
  CAST(saldo AS INT) = 0                                            AS ruptura,
  current_timestamp()                                               AS _processado_em,
  (SELECT COUNT(*) FROM lakehouse_rotaperfume.bronze.estoque)        AS _linhas_origem
FROM lakehouse_rotaperfume.bronze.estoque;

ALTER TABLE lakehouse_rotaperfume.silver.estoque ALTER COLUMN ruptura
  COMMENT 'BOOLEAN recalculado de saldo = 0 (984 linhas). A origem tambem traz um campo ruptura S/N, e nesta carga ele concorda em 100% das linhas — mas a definicao fica no codigo, onde da para conferir, em vez de depender do que o ERP marcou.';

ALTER TABLE lakehouse_rotaperfume.silver.estoque ALTER COLUMN _processado_em
  COMMENT 'Auditoria: quando esta linha foi processada pela silver.';

ALTER TABLE lakehouse_rotaperfume.silver.estoque ALTER COLUMN _linhas_origem
  COMMENT 'Auditoria: quantas linhas a bronze tinha nesta execucao (8.400).';
