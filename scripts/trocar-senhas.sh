#!/usr/bin/env bash
# ==============================================================================
# e-SUS APS PEC em Docker (Linux) - Troca de senhas do banco
# ==============================================================================
# Gera senhas novas, grava no PostgreSQL e no .env e recria os containers.
# Necessário porque editar o .env não altera a senha já gravada no banco.
#
# Uso: ./scripts/trocar-senhas.sh [--postgres] [--leitura] [--yes]
#   sem --postgres/--leitura: troca as duas
# O PEC fica fora do ar por cerca de 1 a 3 minutos (reinício).
#
# Ordem segura: o .env novo é escrito antes (como .env.novo), as duas senhas
# mudam numa única transação e só depois do COMMIT o .env novo entra no lugar.
# Se algo falhar antes do COMMIT, banco e .env continuam com as senhas antigas.
# ==============================================================================
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DO_PG=0; DO_RO=0; ASSUME_YES=0
for arg in "$@"; do
  case "$arg" in
    --postgres) DO_PG=1 ;;
    --leitura)  DO_RO=1 ;;
    --yes)      ASSUME_YES=1 ;;
    *) die "Uso: $0 [--postgres] [--leitura] [--yes]" ;;
  esac
done
[ "$DO_PG" = 0 ] && [ "$DO_RO" = 0 ] && DO_PG=1 && DO_RO=1

# Aceita senhas antigas fracas: trocá-las é justamente o objetivo.
load_env_sem_checar_senhas

container_running "$DB_CONTAINER" || die "O container ${DB_CONTAINER} precisa estar rodando (docker compose up -d esus-db)."
wait_db 60

gen_password() { od -An -N24 -tx1 /dev/urandom | tr -d ' \n'; }

if [ "$ASSUME_YES" != 1 ]; then
  read -r -p "Trocar as senhas e reiniciar o PEC agora? (s/N): " CONFIRM
  [[ "$CONFIRM" =~ ^[sS]$ ]] || { echo "Cancelado."; exit 0; }
fi

NEW_PG="${POSTGRES_PASSWORD:-}"
NEW_RO="${ESUS_LEITURA_PASSWORD:-}"
[ "$DO_PG" = 1 ] && NEW_PG="$(gen_password)"
[ "$DO_RO" = 1 ] && NEW_RO="$(gen_password)"
check_password POSTGRES_PASSWORD "$NEW_PG"
check_password ESUS_LEITURA_PASSWORD "$NEW_RO"

umask 077
TS="$(date +%Y%m%d_%H%M%S)"
BAK="${ENV_FILE}.bak-${TS}"
NEW_ENV="${ENV_FILE}.novo-${TS}"
cp -p "$ENV_FILE" "$BAK"
chmod 600 "$BAK"
trap 'rm -f "$NEW_ENV"' EXIT

# 1. .env novo, ainda fora do lugar
awk -v pg="$NEW_PG" -v ro="$NEW_RO" '
  /^POSTGRES_PASSWORD=/     { print "POSTGRES_PASSWORD=" pg; next }
  /^ESUS_LEITURA_PASSWORD=/ { print "ESUS_LEITURA_PASSWORD=" ro; found_ro=1; next }
  { print }
  END { if (!found_ro) print "ESUS_LEITURA_PASSWORD=" ro }
' "$ENV_FILE" > "$NEW_ENV"
chmod 600 "$NEW_ENV"

# 2. As duas senhas numa transação. A conexão é pelo socket local do container,
#    que não pede senha, então funciona mesmo se a senha antiga estiver errada.
#    As senhas seguem por variável de ambiente (-e NOME), fora do "ps" do host.
log "Gravando as senhas novas no PostgreSQL..."
PGU="$POSTGRES_USER" PGP="$NEW_PG" ROU="$ESUS_LEITURA_USER" ROP="$NEW_RO" \
docker exec -i -e PGU -e PGP -e ROU -e ROP "$DB_CONTAINER" \
  psql -v ON_ERROR_STOP=1 -X -q -U "$POSTGRES_USER" -d postgres -f - <<'SQL' \
  || die "Falha ao gravar as senhas no banco. Nada foi alterado (banco e .env com as senhas antigas)."
SET log_statement = 'none';
SET log_min_error_statement = 'panic';
\getenv pgu PGU
\getenv pgp PGP
\getenv rou ROU
\getenv rop ROP
BEGIN;
SELECT format('ALTER ROLE %I PASSWORD %L', :'pgu', :'pgp') \gexec
SELECT format('ALTER ROLE %I PASSWORD %L', :'rou', :'rop')
 WHERE EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'rou') \gexec
COMMIT;
SQL

# 3. A partir daqui o banco já usa as senhas novas: o .env novo entra no lugar.
mv "$NEW_ENV" "$ENV_FILE"
trap - EXIT
log ".env atualizado (cópia do anterior: $(basename "$BAK"))."

# 4. Permissões e limites do usuário de leitura (cria o papel se não existir).
apply_leitura "$POSTGRES_DB" "$NEW_RO" >/dev/null \
  || warn "Senhas trocadas, mas a reaplicação das permissões do ${ESUS_LEITURA_USER} falhou. Rode de novo este script com --leitura."

# 5. Containers com o ambiente novo. O compose lê o .env atualizado.
log "Recriando os containers com as senhas novas..."
docker compose up -d --force-recreate esus-db
wait_db 120
docker compose up -d --force-recreate esus-pec

log "Senhas trocadas. Confira o PEC e depois apague $(basename "$BAK")."
log "Atualize as conexões de BI/Metabase/Power BI que usam ${ESUS_LEITURA_USER}."
