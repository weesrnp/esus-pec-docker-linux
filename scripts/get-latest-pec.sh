#!/usr/bin/env bash
# ==============================================================================
# e-SUS APS PEC em Docker (Linux) - Localizador Oficial de Releases SISAPS
# ==============================================================================
set -euo pipefail

BASE_URL="https://sisaps.saude.gov.br/sistemas/esusaps"

echo "==> Consultando portal oficial SISAPS do Ministério da Saúde..."
HOMEPAGE=$(curl -fsSL "${BASE_URL}/")

VERSION=$(echo "$HOMEPAGE" | grep -Eo 'Vers[aã]o[[:space:]]+[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n 1 | grep -Eo '[0-9]+\.[0-9]+(\.[0-9]+)?' || true)

if [ -z "$VERSION" ]; then
  echo "Aviso: Não foi possível detectar automaticamente a versão pela página inicial."
  echo "Tentando versão canônica 5.5.28..."
  VERSION="5.5.28"
fi

echo "==> Versão oficial identificada: $VERSION"
JAR_NAME="eSUS-AB-PEC-${VERSION}-Linux64.jar"
DOWNLOAD_URL="https://sisaps.saude.gov.br/sistemas/esusaps/downloads/${JAR_NAME}"

echo "==> URL calculada: $DOWNLOAD_URL"

if [ "${1:-}" = "--download" ]; then
  echo "==> Iniciando download de $JAR_NAME..."
  curl -L -C - --progress-bar "$DOWNLOAD_URL" -o "$JAR_NAME"
  echo "==> Download concluído com sucesso: $JAR_NAME"
else
  echo "Para baixar automaticamente, execute: $0 --download"
fi
