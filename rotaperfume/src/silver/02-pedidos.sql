-- Silver · pedidos — a data que derruba pipeline, e o cancelado que ninguem sinalizou.
--
-- Duas armadilhas moram aqui:
--
--   1. data_pedido chega nos dois formatos (3.443 linhas em dd/MM/yyyy). Com ANSI
--      mode ligado, to_date('15/10/2025') nao devolve nulo: ABORTA a query com
--      CAST_INVALID_INPUT. Esse erro e o bom — o ruim e o banco que devolve nulo
--      calado e some com o mes de outubro do relatorio.
--   2. Os 957 pedidos cancelados vieram com valor_total zerado e NENHUMA flag no
--      dado. Quem quiser somar "faturamento" tem que saber disso de cabeca — ou
--      seja, o numero depende da memoria de quem escreveu a query. A silver
--      transforma isso em coluna: cancelado (boolean) e valor_liquido.
--
-- O teste desta tabela: SUM(valor_liquido) tem que dar exatamente o mesmo numero
-- que a bronze dava para os nao-cancelados. Limpeza que muda faturamento e
-- limpeza que jogou dado fora sem querer.

CREATE OR REPLACE TABLE lakehouse_rotaperfume.silver.pedidos
COMMENT
  'Silver pedidos: data convertida dos dois formatos de origem, valor tipado como DECIMAL(18,2) '
  'e o cancelamento virou coluna booleana em vez de regra na cabeca de quem escreve a query. '
  'Nenhuma linha foi descartada — os 957 cancelados continuam aqui, com valor_liquido zero. '
  'SUM(valor_liquido) reproduz o faturamento da bronze ate o centavo: R$ 102.303.828,05.'
AS
WITH datado AS (
  SELECT
    CAST(pedido_id  AS INT)                                       AS pedido_id,
    CAST(cliente_id AS INT)                                       AS cliente_id,
    CAST(vendedor_id AS INT)                                      AS vendedor_id,
    -- try_to_date, sempre. Os dois formatos no mesmo campo, nenhuma data perdida.
    coalesce(try_to_date(data_pedido),
             try_to_date(data_pedido, 'dd/MM/yyyy'))              AS data_pedido,
    trim(canal)                                                   AS canal,
    trim(status)                                                  AS status,
    CAST(valor_total AS DECIMAL(18,2))                            AS valor_total
  FROM lakehouse_rotaperfume.bronze.pedidos
)

SELECT
  pedido_id,
  cliente_id,
  vendedor_id,
  data_pedido,
  year(data_pedido)                                               AS ano,
  month(data_pedido)                                              AS mes,
  canal,
  status,
  valor_total,
  status = 'Cancelado'                                            AS cancelado,
  -- a regra escrita UMA vez, na tabela, em vez de repetida em cada dashboard
  CASE WHEN status = 'Cancelado' THEN CAST(0 AS DECIMAL(18,2))
       ELSE valor_total END                                       AS valor_liquido,
  current_timestamp()                                             AS _processado_em,
  (SELECT COUNT(*) FROM lakehouse_rotaperfume.bronze.pedidos)      AS _linhas_origem
FROM datado;

ALTER TABLE lakehouse_rotaperfume.silver.pedidos ALTER COLUMN data_pedido
  COMMENT 'DATE. A origem mistura ISO e dd/MM/yyyy no mesmo campo (3.443 linhas no formato brasileiro): coalesce de dois try_to_date. Com ANSI mode ligado, to_date abortaria a query.';

ALTER TABLE lakehouse_rotaperfume.silver.pedidos ALTER COLUMN valor_total
  COMMENT 'DECIMAL(18,2). Na bronze era texto — e texto ordena em ordem alfabetica, entao o maior pedido parecia ser o que comeca com 9.';

ALTER TABLE lakehouse_rotaperfume.silver.pedidos ALTER COLUMN cancelado
  COMMENT 'BOOLEAN derivado de status = Cancelado. Sao 957 pedidos que a origem entregou com valor zerado e sem flag nenhuma: a regra estava so na cabeca de quem escrevia a query.';

ALTER TABLE lakehouse_rotaperfume.silver.pedidos ALTER COLUMN valor_liquido
  COMMENT 'Zero quando cancelado, valor_total caso contrario. E a coluna que se soma para responder faturamento — sem precisar lembrar do filtro status <> Cancelado.';

ALTER TABLE lakehouse_rotaperfume.silver.pedidos ALTER COLUMN ano
  COMMENT 'Derivada de data_pedido, para a gold nao ter que reconverter data.';

ALTER TABLE lakehouse_rotaperfume.silver.pedidos ALTER COLUMN mes
  COMMENT 'Derivada de data_pedido, para a gold nao ter que reconverter data.';

ALTER TABLE lakehouse_rotaperfume.silver.pedidos ALTER COLUMN _processado_em
  COMMENT 'Auditoria: quando esta linha foi processada pela silver.';

ALTER TABLE lakehouse_rotaperfume.silver.pedidos ALTER COLUMN _linhas_origem
  COMMENT 'Auditoria: quantas linhas a bronze tinha nesta execucao (28.729). Aqui tem que ser igual ao COUNT(*) — pedido nao se deduplica nem se descarta.';

ALTER TABLE lakehouse_rotaperfume.silver.pedidos DROP CONSTRAINT IF EXISTS data_pedido_obrigatoria;
ALTER TABLE lakehouse_rotaperfume.silver.pedidos ADD  CONSTRAINT data_pedido_obrigatoria
  CHECK (data_pedido IS NOT NULL);

-- ATENCAO a esta. A regra intuitiva seria valor_liquido >= 0, e ela FALHA:
-- 135 pedidos tem valor negativo. Nao e sujeira — sao pedidos que contem item
-- devolvido, e o saldo virou negativo. Negocio legitimo.
-- O que a gente realmente quer garantir e outra coisa: pedido cancelado tem que
-- ter valor ZERO.
ALTER TABLE lakehouse_rotaperfume.silver.pedidos DROP CONSTRAINT IF EXISTS pedido_cancelado_zerado;
ALTER TABLE lakehouse_rotaperfume.silver.pedidos ADD  CONSTRAINT pedido_cancelado_zerado
  CHECK (NOT cancelado OR valor_liquido = 0);
