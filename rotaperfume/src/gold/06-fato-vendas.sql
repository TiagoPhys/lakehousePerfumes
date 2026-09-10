-- =========================================================================
-- CONTRATO DA gold.fato_vendas — escrito ANTES da primeira linha de SQL
-- =========================================================================
--
-- GRANULARIDADE
--   Uma linha por ITEM de pedido. Nao por pedido, nao por dia, nao por cliente.
--   Escrever esta frase custa dez segundos e evita seis meses de discussao sobre
--   por que dois relatorios contam "vendas" de formas diferentes.
--
-- FILTRO
--   Exclui pedido CANCELADO (957 pedidos, 6.644 itens).
--   NAO exclui DEVOLUCAO. Ela entra com quantidade e receita NEGATIVAS, marcada
--   na coluna devolucao.
--
--   POR QUE A DEVOLUCAO FICA DENTRO: se ficar de fora, a gold soma R$ 103,6 mi e
--   a silver soma R$ 102,3 mi. Um milhao e duzentos e sessenta mil reais de
--   diferenca entre duas camadas do MESMO pipeline, e alguem vai gastar uma
--   reuniao inteira procurando de onde saiu. Quem quiser o bruto pede:
--       SELECT SUM(receita) FILTER (WHERE NOT devolucao) FROM gold.fato_vendas
--
-- DIMENSOES
--   data_pedido, ano, mes, canal, cliente_id, razao_social, segmento, cidade,
--   vendedor_id, sku, categoria, marca, nota_olfativa
--
-- METRICAS
--   quantidade         com sinal: negativa quando e devolucao
--   preco_praticado    preco unitario efetivamente cobrado
--   receita            quantidade * preco_praticado
--   custo              quantidade * custo_unitario do produto
--   margem             receita - custo
--
--   O QUE A RECEITA NAO CONSIDERA: desconto comercial (a coluna desconto_pct da
--   origem NAO esta aplicada) e frete. Aplicar o desconto tiraria R$ 3,9 mi e a
--   gold deixaria de fechar com a silver — se um dia a empresa decidir que
--   receita e liquida de desconto, muda-se AQUI, uma vez, para todo mundo.
--
-- PARTICIONAMENTO
--   ano, mes. Quase toda pergunta da diretoria comeca com um recorte de tempo.
-- =========================================================================

CREATE OR REPLACE TABLE lakehouse_rotaperfume.gold.fato_vendas
PARTITIONED BY (ano, mes)
COMMENT
  'Fato de vendas no grao de ITEM de pedido: 191.080 linhas, uma por item dos pedidos nao '
  'cancelados. A devolucao esta DENTRO, com quantidade e receita negativas e a flag devolucao — e '
  'por isso SUM(receita) reproduz exatamente o faturamento da silver (R$ 102.303.828,05). Para o '
  'bruto vendido, use SUM(receita) FILTER (WHERE NOT devolucao). A regra de margem (receita menos '
  'custo do produto, sem desconto comercial e sem frete) esta escrita aqui uma vez e vale para a '
  'empresa inteira.'
AS
SELECT
  i.item_id,
  i.pedido_id,
  p.data_pedido,
  p.canal,
  -- o cliente_id passa por gold._mapa_cliente: se o pedido vier preso no cadastro
  -- que a deduplicacao descartou, ele e traduzido para o id valido. Hoje isso nao
  -- acontece com nenhum pedido — o LEFT JOIN e defesa, nao conserto
  cl.cliente_id,
  cl.razao_social,
  cl.segmento,
  cl.cidade,
  p.vendedor_id,
  pr.sku,
  pr.categoria,
  pr.marca,
  pr.nota_olfativa,
  i.quantidade,
  i.preco_praticado,
  CAST(i.quantidade * i.preco_praticado                        AS DECIMAL(18,2)) AS receita,
  CAST(i.quantidade * pr.custo_unitario                        AS DECIMAL(18,2)) AS custo,
  CAST(i.quantidade * (i.preco_praticado - pr.custo_unitario)  AS DECIMAL(18,2)) AS margem,
  i.devolucao,
  i.sku_descontinuado,
  current_timestamp()                                                            AS _processado_em,
  -- ano e mes por ultimo: sao as colunas de particao, e o Delta as move para o
  -- fim do schema de qualquer jeito
  p.ano,
  p.mes
FROM lakehouse_rotaperfume.silver.itens_pedido i
JOIN lakehouse_rotaperfume.silver.pedidos p
  ON p.pedido_id = i.pedido_id
 AND NOT p.cancelado
JOIN lakehouse_rotaperfume.gold.dim_produto pr
  ON pr.sku = i.sku
LEFT JOIN lakehouse_rotaperfume.gold._mapa_cliente m
  ON m.cliente_id_antigo = p.cliente_id
JOIN lakehouse_rotaperfume.gold.dim_cliente cl
  ON cl.cliente_id = coalesce(m.cliente_id_valido, p.cliente_id);

-- COMMENT em TODAS as colunas, em linguagem de NEGOCIO — nao tecnica.
-- Isso nao e capricho: e o que o Genie le no prompt 6 para escolher a coluna
-- certa. Coluna sem comentario e coluna que ele usa errado, com confianca.
ALTER TABLE lakehouse_rotaperfume.gold.fato_vendas ALTER COLUMN item_id
  COMMENT 'Identificador do item dentro do pedido. E a chave desta tabela: uma linha por item.';

ALTER TABLE lakehouse_rotaperfume.gold.fato_vendas ALTER COLUMN pedido_id
  COMMENT 'Pedido a que este item pertence. Um pedido tem em media 6,9 itens — para contar PEDIDOS, use COUNT(DISTINCT pedido_id), nunca COUNT(*).';

ALTER TABLE lakehouse_rotaperfume.gold.fato_vendas ALTER COLUMN data_pedido
  COMMENT 'Data em que o pedido foi feito. Nao e data de entrega nem de pagamento.';

ALTER TABLE lakehouse_rotaperfume.gold.fato_vendas ALTER COLUMN canal
  COMMENT 'Por onde a venda entrou: Visita, App, Telefone ou WhatsApp.';

ALTER TABLE lakehouse_rotaperfume.gold.fato_vendas ALTER COLUMN cliente_id
  COMMENT 'Cliente que comprou, consolidado por CNPJ: se o ERP mandar o pedido no cadastro que a deduplicacao descartou, o id e traduzido por gold._mapa_cliente para o cadastro que a silver manteve. Sempre existe em gold.dim_cliente.';

ALTER TABLE lakehouse_rotaperfume.gold.fato_vendas ALTER COLUMN razao_social
  COMMENT 'Nome da empresa cliente, padronizado. Repetido aqui para responder pergunta por nome sem precisar de join.';

ALTER TABLE lakehouse_rotaperfume.gold.fato_vendas ALTER COLUMN segmento
  COMMENT 'Tipo de ponto de venda do cliente (loja de shopping, farmacia, distribuidor). E o corte que o comercial usa para politica de preco.';

ALTER TABLE lakehouse_rotaperfume.gold.fato_vendas ALTER COLUMN cidade
  COMMENT 'Cidade do cliente — onde o produto e vendido, nao de onde ele sai.';

ALTER TABLE lakehouse_rotaperfume.gold.fato_vendas ALTER COLUMN vendedor_id
  COMMENT 'Vendedor responsavel pelo pedido. Vendedor desligado continua aparecendo nas vendas que fez enquanto estava na empresa.';

ALTER TABLE lakehouse_rotaperfume.gold.fato_vendas ALTER COLUMN sku
  COMMENT 'Codigo do produto vendido.';

ALTER TABLE lakehouse_rotaperfume.gold.fato_vendas ALTER COLUMN categoria
  COMMENT 'Familia do produto (Eau de Parfum, Kit Presente, Oleo Concentrado...). E o corte de margem que mais varia: de 33% a 50%.';

ALTER TABLE lakehouse_rotaperfume.gold.fato_vendas ALTER COLUMN marca
  COMMENT 'Marca do produto. Layali e a lider, com R$ 18,4 milhoes.';

ALTER TABLE lakehouse_rotaperfume.gold.fato_vendas ALTER COLUMN nota_olfativa
  COMMENT 'Nota olfativa predominante do produto (Oud, Cardamomo, Ambar...). Atributo de marketing, nao de custo.';

ALTER TABLE lakehouse_rotaperfume.gold.fato_vendas ALTER COLUMN quantidade
  COMMENT 'Unidades do item, COM SINAL: negativa quando a linha e devolucao. Para contar volume vendido ignorando o sentido, filtre por devolucao em vez de usar abs().';

ALTER TABLE lakehouse_rotaperfume.gold.fato_vendas ALTER COLUMN preco_praticado
  COMMENT 'Preco unitario efetivamente cobrado neste item, que pode ser menor que o preco de tabela do produto.';

ALTER TABLE lakehouse_rotaperfume.gold.fato_vendas ALTER COLUMN receita
  COMMENT 'Quantidade vezes preco praticado. NAO considera desconto comercial nem frete. Negativa nas devolucoes: somar a coluna inteira da o faturamento liquido da empresa (R$ 102.303.828,05); para o bruto vendido, use FILTER (WHERE NOT devolucao).';

ALTER TABLE lakehouse_rotaperfume.gold.fato_vendas ALTER COLUMN custo
  COMMENT 'Quantidade vezes o custo unitario de aquisicao do produto. Nao inclui custo de frete, de armazenagem nem comissao de vendedor.';

ALTER TABLE lakehouse_rotaperfume.gold.fato_vendas ALTER COLUMN margem
  COMMENT 'Receita menos custo do produto. Nao considera desconto comercial nem frete. Margem total da empresa: R$ 41.125.619,86, 40,2% da receita.';

ALTER TABLE lakehouse_rotaperfume.gold.fato_vendas ALTER COLUMN devolucao
  COMMENT 'TRUE quando a linha e uma devolucao, e nao uma venda. Sao 2.258 linhas que somam R$ -1.264.758,30 — elas ficam no fato de proposito, para a gold fechar com a silver.';

ALTER TABLE lakehouse_rotaperfume.gold.fato_vendas ALTER COLUMN sku_descontinuado
  COMMENT 'TRUE quando o produto vendido ja saiu de linha. Venda antiga de produto descontinuado e normal; venda RECENTE merece uma pergunta ao comercial.';

ALTER TABLE lakehouse_rotaperfume.gold.fato_vendas ALTER COLUMN ano
  COMMENT 'Ano do pedido. Coluna de particao.';

ALTER TABLE lakehouse_rotaperfume.gold.fato_vendas ALTER COLUMN mes
  COMMENT 'Mes do pedido, de 1 a 12. Coluna de particao. Outubro e o pico do setor (R$ 7,02 mi em 2025) e janeiro o vale (R$ 2,46 mi em 2026).';

ALTER TABLE lakehouse_rotaperfume.gold.fato_vendas ALTER COLUMN _processado_em
  COMMENT 'Auditoria: quando esta linha foi processada pela gold.';
