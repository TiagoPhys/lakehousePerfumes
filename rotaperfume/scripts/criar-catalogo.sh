#!/usr/bin/env bash
#
# Cria o catálogo da noite. Roda ANTES do `bundle deploy`.
#
# POR QUE ISSO NÃO ESTÁ NO BUNDLE
# -------------------------------
# Seria natural declarar o catálogo em resources/catalogo.yml, junto dos schemas.
# Não dá. No Databricks Free Edition o Default Storage está ligado, e nessa
# configuração a API do Unity Catalog RECUSA criar catálogo — ela exige um
# MANAGED LOCATION que a conta gratuita não tem:
#
#   Error: Metastore storage root URL does not exist.
#          Default Storage is enabled in your account. (400 INVALID_STATE)
#
# O comando SQL equivalente funciona sem reclamar. Então o catálogo nasce aqui,
# por SQL, e todo o RESTO (schemas, volume, job) é bundle.
#
# Uso: bash scripts/criar-catalogo.sh <profile> [catalogo]

set -euo pipefail

PROFILE="${1:?uso: bash scripts/criar-catalogo.sh <profile> [catalogo]}"
CATALOG="${2:-lakehouse_rotaperfume}"

echo ">> criando catálogo ${CATALOG} (profile: ${PROFILE})"

databricks experimental aitools tools query \
  "CREATE CATALOG IF NOT EXISTS ${CATALOG}
   COMMENT 'Lakehouse da RotaPerfume — ERP e CRM em bronze, silver e gold. Criado por scripts/criar-catalogo.sh; o resto do catálogo é bundle.'" \
  --profile "${PROFILE}"

echo ">> pronto. o resto do catálogo (schemas + volume) vem do bundle deploy."
