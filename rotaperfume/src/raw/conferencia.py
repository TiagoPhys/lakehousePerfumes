# Databricks notebook source
# MAGIC %md
# MAGIC # Conferência de chegada do raw
# MAGIC
# MAGIC A tarefa mais chata do pipeline, e a que mais salva emprego.
# MAGIC
# MAGIC O erro mais caro de pipeline não é o que quebra — é o arquivo que **não
# MAGIC chegou** e ninguém viu. Ele não dá erro: dá número menor, e o dashboard
# MAGIC mostra metade da receita com cara de número certo.
# MAGIC
# MAGIC Este notebook confere que os 10 arquivos estão no Volume, mede cada um,
# MAGIC registra o resultado em `bronze._raw_arquivos` e **falha alto** se faltar
# MAGIC arquivo ou se algum vier vazio.

# COMMAND ----------

from datetime import datetime, timezone

dbutils.widgets.text("catalog", "lakehouse_rotaperfume", "Catálogo")
catalog = dbutils.widgets.get("catalog").strip()

VOLUME = f"/Volumes/{catalog}/bronze/raw"
TABELA_CONTROLE = f"{catalog}.bronze._raw_arquivos"

# O que TEM que estar lá. A lista é fixa no código de propósito: é ela que
# transforma "não chegou" em erro, em vez de em silêncio.
ESPERADOS = {
    "erp": ["produtos", "pedidos", "itens_pedido", "pagamentos", "estoque"],
    "crm": ["clientes", "vendedores", "carteira", "oportunidades", "visitas"],
}

print(f"catálogo : {catalog}")
print(f"volume   : {VOLUME}")
print(f"esperados: {sum(len(v) for v in ESPERADOS.values())} arquivos")

# COMMAND ----------

# MAGIC %md ## 1. O que chegou de fato ao Volume

# COMMAND ----------


def listar(sistema: str) -> dict:
    """Nome do arquivo -> tamanho em bytes, para uma pasta do Volume.

    Se a pasta inteira não existir, devolve vazio — quem reclama é a
    conferência abaixo, com a lista do que faltou.
    """
    try:
        return {f.name: f.size for f in dbutils.fs.ls(f"{VOLUME}/{sistema}")}
    except Exception as e:  # pasta ausente é um caso legítimo de "não chegou"
        print(f"!! não consegui listar {VOLUME}/{sistema}: {e}")
        return {}


chegaram = {sistema: listar(sistema) for sistema in ESPERADOS}

for sistema, arquivos in chegaram.items():
    print(f"{sistema}: {len(arquivos)} arquivo(s) — {sorted(arquivos)}")

# COMMAND ----------

# MAGIC %md
# MAGIC ## 2. Medir cada arquivo
# MAGIC
# MAGIC Contamos linha *física* com `spark.read.text` e descontamos o cabeçalho.
# MAGIC É a mesma contagem de um `wc -l` na sua máquina — dá para conferir o
# MAGIC número do Volume contra o número do laptop sem conversa.

# COMMAND ----------

conferido_em = datetime.now(timezone.utc)
linhas_controle = []
faltando = []
vazios = []

for sistema, nomes in ESPERADOS.items():
    for nome in nomes:
        arquivo = f"{nome}.csv"
        if arquivo not in chegaram[sistema]:
            faltando.append(f"{sistema}/{arquivo}")
            continue

        caminho = f"{VOLUME}/{sistema}/{arquivo}"
        bytes_ = int(chegaram[sistema][arquivo])
        linhas = spark.read.text(caminho).count() - 1  # -1 = cabeçalho

        if bytes_ == 0 or linhas <= 0:
            vazios.append(f"{sistema}/{arquivo}")

        linhas_controle.append((sistema, arquivo, bytes_, int(linhas), conferido_em))
        print(f"  {sistema}/{arquivo:<20} {bytes_:>10,} bytes  {linhas:>8,} linhas")

# COMMAND ----------

# MAGIC %md ## 3. Registrar o que chegou

# COMMAND ----------

if linhas_controle:
    df_controle = spark.createDataFrame(
        linhas_controle,
        "sistema string, arquivo string, bytes long, linhas long, conferido_em timestamp",
    )

    # overwrite: a tabela é uma FOTO da última conferência, não um histórico.
    # Assim `SELECT COUNT(*)` responde "quantos arquivos chegaram hoje", que é a
    # pergunta que a gente quer fazer.
    df_controle.write.mode("overwrite").option("overwriteSchema", "true").saveAsTable(
        TABELA_CONTROLE
    )

    spark.sql(
        f"COMMENT ON TABLE {TABELA_CONTROLE} IS "
        "'Conferência de chegada do raw: um registro por arquivo esperado no Volume "
        "bronze.raw, com tamanho e número de linhas de dado. Sobrescrita a cada "
        "execução do job — é a foto da última chegada, não o histórico.'"
    )
    print(f"gravado: {TABELA_CONTROLE} ({len(linhas_controle)} registros)")

# COMMAND ----------

# MAGIC %md
# MAGIC ## 4. A parte que interrompe o pipeline
# MAGIC
# MAGIC Sem isto, o pipeline seguiria verde, a bronze teria nove tabelas em vez de
# MAGIC dez, e o dashboard mostraria um faturamento menor — com cara de número certo.

# COMMAND ----------

problemas = []
if faltando:
    problemas.append(f"não chegaram ao Volume: {', '.join(faltando)}")
if vazios:
    problemas.append(f"chegaram vazios: {', '.join(vazios)}")

if problemas:
    raise Exception(
        "CONFERÊNCIA DE CHEGADA FALHOU — o pipeline para aqui.\n  "
        + "\n  ".join(problemas)
        + "\n\nSuba o raw de novo: bash scripts/subir-raw.sh <profile>"
    )

# COMMAND ----------

# MAGIC %md ## 5. O resumo legível

# COMMAND ----------

total_bytes = sum(l[2] for l in linhas_controle)
total_linhas = sum(l[3] for l in linhas_controle)

print(f"{'SISTEMA':<8} {'ARQUIVO':<20} {'BYTES':>12} {'LINHAS':>10}")
print("-" * 54)
for sistema, arquivo, bytes_, linhas, _ in sorted(
    linhas_controle, key=lambda l: -l[3]
):
    print(f"{sistema:<8} {arquivo:<20} {bytes_:>12,} {linhas:>10,}")
print("-" * 54)
print(
    f"{'TOTAL':<8} {len(linhas_controle):<20} {total_bytes:>12,} {total_linhas:>10,}"
)
print(f"\n{total_bytes / 1024 / 1024:.1f} MB · conferido em {conferido_em:%Y-%m-%d %H:%M:%S} UTC")

display(spark.table(TABELA_CONTROLE).orderBy("linhas", ascending=False))
