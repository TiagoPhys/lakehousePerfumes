-- Silver · clientes — o CNPJ vira chave, e 3.040 cadastros viram 3.000.
--
-- Quatro decisoes de limpeza moram neste arquivo, e todas estao registradas em
-- COMMENT na coluna correspondente:
--
--   1. CNPJ nunca vira numero. Ele e um identificador escrito com digitos, nao um
--      valor. Um CAST para BIGINT apagaria o zero da frente de 309 clientes, para
--      sempre, sem erro nenhum.
--   2. data_cadastro chega em dois formatos no MESMO campo. try_to_date, nunca
--      to_date: o ANSI mode esta ligado e to_date ABORTA a query com
--      CAST_INVALID_INPUT em vez de devolver nulo.
--   3. Deduplicar nao e DISTINCT. Os 40 CNPJs repetidos tem cliente_id diferente
--      em cada cadastro, entao DISTINCT devolveria as 80 linhas achando que sao
--      clientes diferentes. Quem resolve e row_number() por CNPJ.
--   4. O cadastro descartado nao some: o id dele fica guardado em
--      cliente_ids_duplicados, porque os pedidos antigos continuam apontando
--      para ele.

CREATE OR REPLACE TABLE lakehouse_rotaperfume.silver.clientes
COMMENT
  'Silver clientes: CNPJ normalizado para 14 digitos (trim, so digitos, zero a esquerda), '
  'razao social padronizada, data_cadastro convertida dos dois formatos de origem e '
  'deduplicacao por CNPJ mantendo o cadastro MAIS ANTIGO. Sao 3.040 linhas na bronze para '
  '3.000 CNPJs reais: 40 empresas foram cadastradas duas vezes. O id descartado fica em '
  'cliente_ids_duplicados para rastrear os pedidos antigos.'
AS
WITH normalizado AS (
  SELECT
    CAST(cliente_id AS INT)                                           AS cliente_id,
    -- trim -> tira o que nao e digito -> completa 14 com zero a esquerda.
    -- A ordem importa: lpad por ultimo, senao o ponto contaria como caractere.
    lpad(regexp_replace(trim(cnpj), '[^0-9]', ''), 14, '0')           AS cnpj,
    -- ' +' (espaco literal), e nao '\\s+': dentro de uma string SQL a barra e
    -- caractere de escape, e '\s' chega no regex como um 's' comum — o que faria
    -- este regexp_replace apagar todo "s" minusculo da razao social.
    initcap(regexp_replace(trim(razao_social), ' +', ' '))           AS razao_social,
    trim(segmento)                                                    AS segmento,
    trim(cidade)                                                      AS cidade,
    upper(trim(uf))                                                   AS uf,
    trim(bairro)                                                      AS bairro,
    -- os dois formatos, no mesmo campo. O coalesce nao deixa NENHUMA data para tras.
    coalesce(try_to_date(data_cadastro),
             try_to_date(data_cadastro, 'dd/MM/yyyy'))                AS data_cadastro,
    upper(trim(ativo)) = 'S'                                          AS ativo
  FROM lakehouse_rotaperfume.bronze.clientes
),

ordenado AS (
  SELECT
    *,
    -- o cadastro mais antigo do CNPJ e o que fica
    row_number() OVER (PARTITION BY cnpj ORDER BY data_cadastro, cliente_id) AS ordem,
    -- todos os ids do CNPJ, menos o que estamos mantendo = exatamente os descartados.
    -- Array vazio quando o CNPJ so tem um cadastro.
    array_remove(collect_list(cliente_id) OVER (PARTITION BY cnpj), cliente_id)
                                                                             AS cliente_ids_duplicados
  FROM normalizado
)

SELECT
  cliente_id,
  cnpj,
  razao_social,
  segmento,
  cidade,
  uf,
  bairro,
  data_cadastro,
  ativo,
  cliente_ids_duplicados,
  current_timestamp()                                                   AS _processado_em,
  (SELECT COUNT(*) FROM lakehouse_rotaperfume.bronze.clientes)           AS _linhas_origem
FROM ordenado
WHERE ordem = 1;

-- As colunas que exigiram decisao. Quem abrir o Catalog Explorer daqui a um ano
-- le a decisao junto com o dado.
ALTER TABLE lakehouse_rotaperfume.silver.clientes ALTER COLUMN cnpj
  COMMENT 'Sempre 14 digitos, sempre STRING. Vinha da origem em tres formatos (puro, pontuado, com espaco em volta): trim + regexp_replace + lpad. Nunca convertido para numero — o CAST apagaria o zero a esquerda de 309 clientes.';

ALTER TABLE lakehouse_rotaperfume.silver.clientes ALTER COLUMN razao_social
  COMMENT 'Padronizada com initcap e espaco duplo colapsado. A origem mistura CAIXA ALTA, caixa baixa e espacamento irregular no mesmo campo.';

ALTER TABLE lakehouse_rotaperfume.silver.clientes ALTER COLUMN data_cadastro
  COMMENT 'DATE. A origem mistura ISO (yyyy-MM-dd) e brasileiro (dd/MM/yyyy) no mesmo campo: coalesce de dois try_to_date. try_ e obrigatorio — com ANSI mode ligado, to_date sobre data malformada aborta a query.';

ALTER TABLE lakehouse_rotaperfume.silver.clientes ALTER COLUMN ativo
  COMMENT 'BOOLEAN a partir do S/N da origem.';

ALTER TABLE lakehouse_rotaperfume.silver.clientes ALTER COLUMN cliente_ids_duplicados
  COMMENT 'Os cliente_id descartados na deduplicacao deste CNPJ (array vazio quando nao houve duplicata). Sao 40 CNPJs com dois cadastros: o mais antigo ficou, e o id do outro esta aqui porque os pedidos antigos continuam apontando para ele.';

ALTER TABLE lakehouse_rotaperfume.silver.clientes ALTER COLUMN _processado_em
  COMMENT 'Auditoria: quando esta linha foi processada pela silver.';

ALTER TABLE lakehouse_rotaperfume.silver.clientes ALTER COLUMN _linhas_origem
  COMMENT 'Auditoria: quantas linhas a bronze tinha nesta execucao (3.040). A diferenca para o COUNT(*) da silver e a deduplicacao.';

-- O contrato. Nao e comentario: o Delta passa a RECUSAR a escrita que violar.
-- DROP IF EXISTS antes do ADD porque o job tem que poder rodar de novo — o ADD
-- continua validando as linhas que ja estao la, que e o efeito que interessa.
ALTER TABLE lakehouse_rotaperfume.silver.clientes DROP CONSTRAINT IF EXISTS cnpj_14_digitos;
ALTER TABLE lakehouse_rotaperfume.silver.clientes ADD  CONSTRAINT cnpj_14_digitos
  CHECK (length(cnpj) = 14);

ALTER TABLE lakehouse_rotaperfume.silver.clientes DROP CONSTRAINT IF EXISTS data_cadastro_obrigatoria;
ALTER TABLE lakehouse_rotaperfume.silver.clientes ADD  CONSTRAINT data_cadastro_obrigatoria
  CHECK (data_cadastro IS NOT NULL);
