#!/usr/bin/env bash
# ==============================================================================
# e-SUS APS PEC em Docker (Linux) - Banco novo (instalação do zero)
# ==============================================================================
# Para municípios sem backup a restaurar. Roda o migrador oficial (Liquibase),
# que cria as ~1.180 tabelas e os dados iniciais, e cria o usuário de leitura.
#
# Uso: ./scripts/init-new-db.sh [--treinamento]
#   --treinamento  cria uma base de TREINAMENTO (não usar em produção)
# ==============================================================================
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MIGR_FLAGS=""
case "${1:-}" in
  --treinamento) MIGR_FLAGS="-treinamento" ;;
  "") ;;
  *) die "Uso: $0 [--treinamento]" ;;
esac

load_env

echo "=========================================================="
echo "Banco novo do e-SUS APS PEC - $(date '+%d/%m/%Y %H:%M:%S')"
[ -n "$MIGR_FLAGS" ] && echo "MODO TREINAMENTO"
echo "=========================================================="

log "Subindo o PostgreSQL..."
docker compose up -d esus-db
wait_db 120

EXISTING="$(count_tables "$POSTGRES_DB")"
if [ "$EXISTING" -gt 0 ]; then
  die "O banco '${POSTGRES_DB}' já tem ${EXISTING} tabelas. Para atualizar a versão use ./scripts/atualizar-pec.sh; para trocar a base use ./scripts/restore.sh."
fi

if ! docker image inspect "esus-pec-docker:${PEC_IMAGE_TAG:-local}" >/dev/null 2>&1; then
  log "Imagem do PEC não encontrada. Construindo..."
  docker compose build esus-pec
fi

# O migrador sai com código 0 mesmo quando só imprime a ajuda; a contagem de
# tabelas abaixo é a confirmação real.
# shellcheck disable=SC2086
run_migrador "$POSTGRES_DB" $MIGR_FLAGS

TOTAL="$(count_tables "$POSTGRES_DB")"
[ "$TOTAL" -ge 1000 ] || die "O migrador terminou, mas o banco tem só ${TOTAL} tabelas. Veja a saída acima."
log "Migração OK: ${TOTAL} tabelas criadas."

log "Aplicando usuário de leitura (${ESUS_LEITURA_USER})..."
apply_leitura "$POSTGRES_DB"

echo "=========================================================="
echo "Banco pronto. Inicie o PEC com: docker compose up -d"
echo "=========================================================="
