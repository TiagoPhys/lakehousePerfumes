# Databricks notebook source
# MAGIC %md
# MAGIC # Bronze — arquivo vira tabela
# MAGIC
# MAGIC Dez tabelas Delta, uma função, uma lista.
# MAGIC
# MAGIC **A bronze preserva a sujeira de propósito.** Se o Spark adivinhar o tipo,
# MAGIC ele converte `15/10/2025` em nulo e apaga o zero da frente de 309 CNPJs — e
# MAGIC ninguém recebe erro nenhum. A sujeira sumiria antes de alguém ver que ela
# MAGIC existiu, e depois seria impossível saber se o número errado veio da origem
# MAGIC ou da nossa limpeza.
# MAGIC
# MAGIC Por isso: **tudo entra como texto**. Converter é trabalho da silver, feito
# MAGIC sabendo o que se faz.

# COMMAND ----------

from pyspark.sql import functions as F

dbutils.widgets.text("catalog", "lakehouse_rotaperfume", "Catálogo")
catalog = dbutils.widgets.get("catalog").strip()

VOLUME = f"/Volumes/{catalog}/bronze/raw"
TABELA_CONTROLE = f"{catalog}.bronze._raw_arquivos"

# A mesma lista da conferência de chegada (src/raw/conferencia.py). Se amanhã o
# ERP mandar a décima primeira tabela, é uma linha aqui.
ORIGENS = {
    "erp": ["produtos", "pedidos", "itens_pedido", "pagamentos", "estoque"],
    "crm": ["clientes", "vendedores", "carteira", "oportunidades", "visitas"],
}

SISTEMAS = {"erp": "ERP", "crm": "CRM"}

print(f"catálogo: {catalog}")
print(f"volume  : {VOLUME}")
print(f"tabelas : {sum(len(v) for v in ORIGENS.values())}")

# COMMAND ----------

# MAGIC %md
# MAGIC ## A função de ingestão — escrita uma vez
# MAGIC
# MAGIC As regras da bronze estão todas aqui dentro, e não se repetem por tabela:
# MAGIC
# MAGIC - `inferSchema=False` — **todas** as colunas entram STRING. Não é preguiça,
# MAGIC   é decisão: é o que impede o CNPJ de virar número.
# MAGIC - sem `multiLine` — os CSVs são CRLF e não têm quebra de linha dentro de
# MAGIC   campo; ligar `multiLine` mudaria a contagem e esconderia o problema.
# MAGIC - `spark.read.csv` em vez de `read_files` — é o `read_files` que inventa a
# MAGIC   coluna `_rescued_data`.
# MAGIC - duas colunas técnicas, e só duas.

# COMMAND ----------


def ingerir(sistema: str, tabela: str) -> int:
    """Lê um CSV do Volume e grava a tabela Delta da bronze. Devolve as linhas."""
    caminho = f"{VOLUME}/{sistema}/{tabela}.csv"
    destino = f"{catalog}.bronze.{tabela}"

    df = (
        spark.read.option("header", True)
        .option("inferSchema", False)  # tudo texto: a bronze não converte nada
        .csv(caminho)
        .withColumn("_ingerido_em", F.current_timestamp())
        .withColumn("_arquivo_origem", F.lit(caminho))
    )

    (
        df.write.mode("overwrite")
        .option("overwriteSchema", "true")  # o job tem que poder rodar de novo
        .saveAsTable(destino)
    )

    spark.sql(
        f"COMMENT ON TABLE {destino} IS "
        f"'Bronze: cópia fiel de {sistema}/{tabela}.csv, vindo do {SISTEMAS[sistema]}. "
        "Todas as colunas de negócio são texto — nenhuma limpeza, nenhuma conversão "
        "de tipo. Conversão é trabalho da silver.'"
    )

    return spark.table(destino).count()


# COMMAND ----------

# MAGIC %md ## Ingerir as dez

# COMMAND ----------

ingeridas = {}
for sistema, tabelas in ORIGENS.items():
    for tabela in tabelas:
        ingeridas[tabela] = ingerir(sistema, tabela)
        print(f"  {sistema}/{tabela:<15} {ingeridas[tabela]:>8,} linhas")

# COMMAND ----------

# MAGIC %md
# MAGIC ## A conferência que interrompe
# MAGIC
# MAGIC Linhas da tabela = linhas do arquivo (que a conferência de chegada já
# MAGIC registrou em `bronze._raw_arquivos`). A referência é a tabela de controle,
# MAGIC não uma lista escrita à mão: o número certo é o que chegou no Volume hoje.
# MAGIC
# MAGIC Divergiu? Quase sempre é `multiLine` ligado ou separador trocado — e é muito
# MAGIC melhor descobrir agora do que num dashboard daqui a três semanas.

# COMMAND ----------

no_arquivo = {
    linha["arquivo"].removesuffix(".csv"): linha["linhas"]
    for linha in spark.table(TABELA_CONTROLE).select("arquivo", "linhas").collect()
}

divergencias = []
print(f"{'TABELA':<16}{'NA TABELA':>12}{'NO ARQUIVO':>12}{'BATE':>7}")
print("-" * 47)
for tabela, linhas in sorted(ingeridas.items(), key=lambda item: -item[1]):
    esperado = no_arquivo.get(tabela)
    bate = linhas == esperado
    if not bate:
        divergencias.append(f"{tabela}: tabela {linhas:,} != arquivo {esperado:,}")
    print(f"{tabela:<16}{linhas:>12,}{esperado:>12,}{str(bate):>7}")
print("-" * 47)
print(f"{'TOTAL':<16}{sum(ingeridas.values()):>12,}{sum(no_arquivo.values()):>12,}")

# COMMAND ----------

if divergencias:
    raise Exception(
        "INGESTÃO DA BRONZE DIVERGIU DO ARQUIVO — o pipeline para aqui.\n  "
        + "\n  ".join(divergencias)
        + "\n\nO CSV foi lido errado. Suspeite de multiLine ligado ou separador trocado."
    )

print(f"{len(ingeridas)} tabelas na bronze, {sum(ingeridas.values()):,} linhas.")
print("Nada foi limpo. A sujeira é o conteúdo do próximo prompt.")
