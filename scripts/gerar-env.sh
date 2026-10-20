#!/usr/bin/env bash
# ==============================================================================
# e-SUS APS PEC em Docker (Linux) - Gera o .env com senhas fortes
# ==============================================================================
# Uso: ./scripts/gerar-env.sh [--force]
#   --force  recria o .env (o atual é guardado em .env.bak-<data>)
# ==============================================================================
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FORCE=0
case "${1:-}" in
  --force) FORCE=1 ;;
  "") ;;
  *) die "Uso: $0 [--force]" ;;
esac

# 24 bytes aleatórios em hexadecimal (192 bits): sem caracteres que precisem de
# escape em URL JDBC, YAML ou shell.
gen_password() {
  od -An -N24 -tx1 /dev/urandom | tr -d ' \n'
}

[ -f "${PROJECT_ROOT}/.env.example" ] || die ".env.example não encontrado"

if [ -f "$ENV_FILE" ]; then
  [ "$FORCE" = "1" ] || die ".env já existe. Para trocar senhas de uma instalação em uso, rode ./scripts/trocar-senhas.sh (ou use --force para recriar)."
  BAK="${ENV_FILE}.bak-$(date +%Y%m%d_%H%M%S)"
  (umask 077; cp -p "$ENV_FILE" "$BAK")
  chmod 600 "$BAK"
  log "Cópia do .env anterior: $(basename "$BAK")"
fi

if [ -d "${PROJECT_ROOT}/volumes/pg_data" ] && [ -n "$(ls -A "${PROJECT_ROOT}/volumes/pg_data" 2>/dev/null || echo x)" ]; then
  warn "O banco já foi inicializado (volumes/pg_data). Senhas novas no .env NÃO mudam as senhas dentro do PostgreSQL."
  warn "Para uma instalação existente, use ./scripts/trocar-senhas.sh."
fi

PG_PASS="$(gen_password)"
RO_PASS="$(gen_password)"

umask 077
TMP="$(mktemp "${PROJECT_ROOT}/.env.XXXXXX")"
trap 'rm -f "$TMP"' EXIT

awk -v pg="$PG_PASS" -v ro="$RO_PASS" '
  /^POSTGRES_PASSWORD=/     { print "POSTGRES_PASSWORD=" pg; next }
  /^ESUS_LEITURA_PASSWORD=/ { print "ESUS_LEITURA_PASSWORD=" ro; next }
  { print }
' "${PROJECT_ROOT}/.env.example" > "$TMP"

chmod 600 "$TMP"
mv "$TMP" "$ENV_FILE"
trap - EXIT

log ".env criado com senhas aleatórias (permissão 600)."
log "Revise PEC_BIND_IP, PEC_HEAP e PEC_JAR_FILE antes de subir a stack."
log "Guarde as senhas no cofre de senhas da secretaria: o .env não vai para o git nem para o backup."
