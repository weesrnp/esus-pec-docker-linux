#!/usr/bin/env bash
# ==============================================================================
# e-SUS APS PEC em Docker (Linux) - Localiza e baixa o instalador oficial
# ==============================================================================
# Os links ficam nos arquivos JS do portal SISAPS (site Docusaurus), não no HTML,
# no formato https://arquivos.esusaps.ufsc.br/PEC/<hash>/<versão>/eSUS-AB-PEC-<versão>-Linux64.jar.
# O <hash> muda a cada versão, então a URL não pode ser montada só com o número.
#
# Uso:
#   ./scripts/get-latest-pec.sh               mostra a versão mais recente e a URL
#   ./scripts/get-latest-pec.sh --download    baixa, valida e grava PEC_JAR_FILE/SHA256 no .env
#   ./scripts/get-latest-pec.sh --url <URL>   usa a URL informada (copiada do portal) em vez de procurar
# ==============================================================================
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PORTAL="https://sisaps.saude.gov.br/sistemas/esusaps"
LINK_RE='https://arquivos\.esusaps?\.ufsc\.br/PEC/[A-Za-z0-9]+/[0-9]+\.[0-9]+\.[0-9]+/eSUS-AB-PEC-[0-9]+\.[0-9]+\.[0-9]+-Linux64\.jar'

DOWNLOAD=0; URL=""
while [ $# -gt 0 ]; do
  case "$1" in
    --download) DOWNLOAD=1 ;;
    --url) shift; URL="${1:-}"; [ -n "$URL" ] || die "--url precisa de um endereço" ;;
    *) die "Uso: $0 [--download] [--url <URL>]" ;;
  esac
  shift
done

find_latest_url() {
  local page runtime expr names hashes chunk
  page="$(curl -fsSL --max-time 30 "${PORTAL}/docs/Versoes/")" || return 1
  runtime="$(printf '%s' "$page" | grep -Eo '/sistemas/esusaps/assets/js/runtime~main\.[a-f0-9]+\.js' | head -n 1)"
  [ -n "$runtime" ] || return 1
  # runtime do webpack: "assets/js/"+({id:"nome",...}[e]||e)+"."+{id:"hash",...}[e]+".js"
  expr="$(curl -fsSL --max-time 30 "https://sisaps.saude.gov.br${runtime}" \
    | grep -o 'assets/js/"+({[^}]*}\[e\]||e)+"\."+{[^}]*}\[e\]+"\.js"' | head -n 1)"
  [ -n "$expr" ] || return 1
  names="$(printf '%s' "$expr" | sed -E 's/^assets\/js\/"\+\(\{([^}]*)\}.*/\1/' | tr ',' '\n')"
  hashes="$(printf '%s' "$expr" | sed -E 's/.*\+"\."\+\{([^}]*)\}\[e\].*/\1/' | tr ',' '\n')"

  # Cada download passa pelo próprio grep: as linhas que saem são curtas e não
  # se misturam entre os 16 downloads paralelos.
  # shellcheck disable=SC2016
  while IFS=: read -r id hash; do
    hash="${hash//\"/}"
    chunk="$(printf '%s\n' "$names" | awk -F: -v id="$id" '$1 == id { gsub(/"/, "", $2); print $2 }')"
    echo "https://sisaps.saude.gov.br/sistemas/esusaps/assets/js/${chunk:-$id}.${hash}.js"
  done <<< "$hashes" \
    | xargs -P 16 -I{} sh -c 'curl -fsSL --max-time 30 "$1" 2>/dev/null | grep -Eo "$2" || true' _ {} "$LINK_RE" \
    | sort -u -t/ -k6,6V \
    | tail -n 1
}

if [ -z "$URL" ]; then
  log "Procurando a versão mais recente no portal SISAPS..."
  URL="$(find_latest_url || true)"
  [ -n "$URL" ] || die "Não encontrei o link no portal. Copie a URL do Linux64.jar em ${PORTAL}/docs/Versoes e rode: $0 --url <URL>"
fi
[[ "$URL" =~ $LINK_RE ]] || warn "A URL não segue o padrão oficial (arquivos.esusaps.ufsc.br/PEC/...)."

JAR_NAME="$(basename "$URL")"
VERSION="$(printf '%s' "$JAR_NAME" | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+')"
log "Versão: ${VERSION}"
log "URL: ${URL}"

# Confere se o servidor entrega um .jar de verdade (e não uma página HTML com status 200)
HEADERS="$(curl -fsSIL --max-time 30 "$URL")" || die "O servidor não respondeu para ${URL}"
CTYPE="$(printf '%s' "$HEADERS" | tr -d '\r' | awk -F': ' 'tolower($1)=="content-type"{v=$2} END{print v}')"
SIZE="$(printf '%s' "$HEADERS" | tr -d '\r' | awk -F': ' 'tolower($1)=="content-length"{v=$2} END{print v}')"
case "$CTYPE" in
  *java-archive*|*octet-stream*|*zip*) ;;
  *) die "O servidor devolveu '${CTYPE:-sem tipo}', não um .jar." ;;
esac
log "Arquivo disponível: $(( ${SIZE:-0} / 1048576 )) MB"

if [ "$DOWNLOAD" != 1 ]; then
  echo "Para baixar: $0 --download"
  exit 0
fi

mkdir -p "${PROJECT_ROOT}/instalador"
DEST="${PROJECT_ROOT}/instalador/${JAR_NAME}"
if [ -f "$DEST" ] && unzip -l "$DEST" container/webserver/pec-bundle.jar >/dev/null 2>&1; then
  log "${JAR_NAME} já existe e é válido."
else
  log "Baixando ${JAR_NAME}..."
  curl -fL --retry 3 --progress-bar -o "${DEST}.part" "$URL"
  unzip -l "${DEST}.part" container/webserver/pec-bundle.jar >/dev/null 2>&1 \
    || { rm -f "${DEST}.part"; die "O arquivo baixado não é um instalador válido do PEC."; }
  mv "${DEST}.part" "$DEST"
fi

SHA="$(sha256sum "$DEST" | cut -d' ' -f1)"
echo "${SHA}  ${JAR_NAME}" > "${DEST}.sha256"
log "SHA-256: ${SHA}"

# Instalação nova (sem banco ainda): já deixa o .env apontando para esta versão.
# Instalação em uso: o .env só muda pelo atualizar-pec.sh, que faz backup e migração.
if [ -f "$ENV_FILE" ] && ! container_exists "$DB_CONTAINER"; then
  umask 077
  TMP="$(mktemp "${PROJECT_ROOT}/.env.XXXXXX")"
  awk -v jar="$JAR_NAME" -v sha="$SHA" -v tag="$VERSION" '
    /^PEC_JAR_FILE=/   { print "PEC_JAR_FILE=" jar; f1=1; next }
    /^PEC_JAR_SHA256=/ { print "PEC_JAR_SHA256=" sha; f2=1; next }
    /^PEC_IMAGE_TAG=/  { print "PEC_IMAGE_TAG=" tag; f3=1; next }
    { print }
    END { if (!f1) print "PEC_JAR_FILE=" jar; if (!f2) print "PEC_JAR_SHA256=" sha; if (!f3) print "PEC_IMAGE_TAG=" tag }
  ' "$ENV_FILE" > "$TMP"
  chmod 600 "$TMP"
  mv "$TMP" "$ENV_FILE"
  log ".env atualizado (PEC_JAR_FILE, PEC_JAR_SHA256 e PEC_IMAGE_TAG)."
  echo "Próximo passo: docker compose build && ./scripts/init-new-db.sh"
else
  echo "Instalação em uso: atualize com ./scripts/atualizar-pec.sh instalador/${JAR_NAME}"
fi
