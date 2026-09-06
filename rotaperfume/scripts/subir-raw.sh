#!/usr/bin/env bash
#
# Sobe os 10 CSVs de dados/erp e dados/crm para o Volume do Unity Catalog.
#
# Roda DEPOIS do `bundle deploy` — o Volume precisa existir antes de receber
# arquivo. Rodar de novo é seguro: --overwrite substitui o que já está lá.
#
# Uso: bash scripts/subir-raw.sh <profile> [catalogo]

set -euo pipefail

PROFILE="${1:?uso: bash scripts/subir-raw.sh <profile> [catalogo]}"
CATALOG="${2:-lakehouse_rotaperfume}"

# O bundle vive em rotaperfume/; os dados vivem na raiz do repositório.
REPO_RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DADOS="${REPO_RAIZ}/dados"

if [[ ! -d "${DADOS}/erp" || ! -d "${DADOS}/crm" ]]; then
  echo "ERRO: não encontrei ${DADOS}/erp e ${DADOS}/crm." >&2
  echo "      Os 10 CSVs da RotaPerfume precisam estar na raiz do repositório," >&2
  echo "      em dados/erp (5 arquivos) e dados/crm (5 arquivos)." >&2
  exit 1
fi

# O `databricks fs cp` exige o esquema dbfs: no destino — mesmo quando o destino
# é um Volume do Unity Catalog, e não o DBFS. É uma pegadinha da CLI.
DESTINO="dbfs:/Volumes/${CATALOG}/bronze/raw"

for SISTEMA in erp crm; do
  echo ">> subindo dados/${SISTEMA} -> ${DESTINO}/${SISTEMA}"
  databricks fs cp --recursive --overwrite \
    "${DADOS}/${SISTEMA}" "${DESTINO}/${SISTEMA}" \
    --profile "${PROFILE}"
done

echo ">> conferindo o que chegou:"
for SISTEMA in erp crm; do
  databricks fs ls "${DESTINO}/${SISTEMA}" --profile "${PROFILE}"
done
