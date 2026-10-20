#!/usr/bin/env bash
# ==============================================================================
# e-SUS APS PEC em Docker (Linux) - Atualização de versão
# ==============================================================================
# Uso: ./scripts/atualizar-pec.sh <eSUS-AB-PEC-X.Y.Z-Linux64.jar>
#
# 1. valida o instalador novo e o coloca em instalador/;
# 2. faz backup completo (aborta se falhar);
# 3. constrói a imagem da versão nova;
# 4. para o PEC e roda o migrador da versão nova no banco;
# 5. só então grava a versão nova no .env e sobe o PEC, conferindo a API.
# Se o passo 4 falhar, o .env continua na versão anterior e o script mostra o
# comando de rollback (restore do backup do passo 2 com a imagem anterior).
# ==============================================================================
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NEW_JAR="${1:-}"
[ -n "$NEW_JAR" ] || die "Uso: $0 <eSUS-AB-PEC-X.Y.Z-Linux64.jar>"
case "$NEW_JAR" in /*) ;; *) NEW_JAR="${OLDPWD:-$PWD}/${NEW_JAR}" ;; esac
[ -f "$NEW_JAR" ] || die "Instalador não encontrado: $NEW_JAR"

JAR_NAME="$(basename "$NEW_JAR")"
[[ "$JAR_NAME" =~ ^eSUS-AB-PEC-([0-9]+\.[0-9]+\.[0-9]+)-Linux64\.jar$ ]] \
  || die "Nome inesperado: ${JAR_NAME} (esperado eSUS-AB-PEC-X.Y.Z-Linux64.jar)"
NEW_VERSION="${BASH_REMATCH[1]}"

load_env
OLD_TAG="${PEC_IMAGE_TAG:-local}"

# 1. Instalador
unzip -l "$NEW_JAR" container/webserver/pec-bundle.jar >/dev/null 2>&1 \
  || die "${JAR_NAME} não é um instalador válido do PEC."
DEST="${PROJECT_ROOT}/instalador/${JAR_NAME}"
mkdir -p "${PROJECT_ROOT}/instalador"
if [ ! "$NEW_JAR" -ef "$DEST" ]; then
  log "Copiando ${JAR_NAME} para instalador/..."
  cp "$NEW_JAR" "$DEST"
fi
NEW_SHA="$(sha256sum "$DEST" | cut -d' ' -f1)"

# 2. Backup
log "Backup antes da atualização..."
"${LIB_DIR}/backup.sh"
BACKUP_DIR="${BACKUP_DIR:-${PROJECT_ROOT}/backups}"
LAST_DUMP="$(find "$BACKUP_DIR" -maxdepth 1 -name 'esus_*.backup' -type f -printf '%T@ %p\n' | sort -n | tail -n 1 | cut -d' ' -f2-)"

# 3. Imagem nova. As variáveis abaixo valem só para os comandos deste script;
#    o .env só muda no passo 5.
export PEC_JAR_FILE="$JAR_NAME" PEC_JAR_SHA256="$NEW_SHA" PEC_IMAGE_TAG="$NEW_VERSION"
log "Construindo a imagem ${NEW_VERSION}..."
docker compose build esus-pec

# 4. Migração do banco com o migrador da versão nova
if container_running "$PEC_CONTAINER"; then
  log "Parando o PEC..."
  docker stop -t 60 "$PEC_CONTAINER" >/dev/null
fi
if ! run_migrador "$POSTGRES_DB"; then
  echo >&2
  warn "O migrador da versão ${NEW_VERSION} falhou. O .env continua na versão anterior (${OLD_TAG})."
  warn "Para voltar ao estado de antes da atualização:"
  warn "    ./scripts/restore.sh --yes ${LAST_DUMP}"
  warn "    docker compose up -d"
  die "Atualização interrompida."
fi
apply_leitura "$POSTGRES_DB" >/dev/null

# 5. .env com a versão nova e PEC no ar
umask 077
TMP="$(mktemp "${PROJECT_ROOT}/.env.XXXXXX")"
trap 'rm -f "$TMP"' EXIT
awk -v jar="$JAR_NAME" -v sha="$NEW_SHA" -v tag="$NEW_VERSION" '
  /^PEC_JAR_FILE=/   { print "PEC_JAR_FILE=" jar; f1=1; next }
  /^PEC_JAR_SHA256=/ { print "PEC_JAR_SHA256=" sha; f2=1; next }
  /^PEC_IMAGE_TAG=/  { print "PEC_IMAGE_TAG=" tag; f3=1; next }
  { print }
  END {
    if (!f1) print "PEC_JAR_FILE=" jar
    if (!f2) print "PEC_JAR_SHA256=" sha
    if (!f3) print "PEC_IMAGE_TAG=" tag
  }
' "$ENV_FILE" > "$TMP"
chmod 600 "$TMP"
mv "$TMP" "$ENV_FILE"
trap - EXIT
unset PEC_JAR_FILE PEC_JAR_SHA256 PEC_IMAGE_TAG

log "Subindo o PEC ${NEW_VERSION}..."
docker compose up -d esus-pec
log "Aguardando o PEC responder (até 10 minutos)..."
STATUS="?"
for _ in $(seq 1 120); do
  STATUS="$(docker inspect -f '{{.State.Health.Status}}' "$PEC_CONTAINER" 2>/dev/null || echo "?")"
  [ "$STATUS" = "healthy" ] && break
  sleep 5
done
[ "$STATUS" = "healthy" ] || die "O PEC não ficou saudável. Veja: docker compose logs esus-pec"

RUNNING_VERSION="$(docker exec "$PEC_CONTAINER" curl -fsS http://127.0.0.1:8080/api/public/info 2>/dev/null \
  | grep -o '"versao":"[^"]*"' | cut -d'"' -f4 || true)"
log "PEC no ar. Versão informada pela API: ${RUNNING_VERSION:-desconhecida}"
if [ "$RUNNING_VERSION" != "$NEW_VERSION" ]; then
  warn "A versão da API (${RUNNING_VERSION:-?}) difere da esperada (${NEW_VERSION})."
fi
