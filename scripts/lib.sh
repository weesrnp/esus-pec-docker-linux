#!/usr/bin/env bash
# ==============================================================================
# e-SUS APS PEC em Docker (Linux) - Funções compartilhadas pelos scripts
# ==============================================================================
# Uso: source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# Ao ser carregado, entra na raiz do projeto (scripts funcionam de qualquer
# diretório, inclusive pelo cron) e lê o .env sem executá-lo.
# ==============================================================================

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$LIB_DIR")"
ENV_FILE="${PROJECT_ROOT}/.env"
# Usadas pelos scripts que carregam este arquivo.
DB_CONTAINER="esus-db"
# shellcheck disable=SC2034
PEC_CONTAINER="esus-pec"

cd "$PROJECT_ROOT" || exit 1

log()  { echo "==> $*"; }
warn() { echo "AVISO: $*" >&2; }
die()  { echo "ERRO: $*" >&2; exit 1; }

# Lê KEY=VALOR do .env sem executá-lo, com as regras do Docker Compose para
# aspas, comentário no fim da linha (" #") e espaços. As variáveis ficam no
# shell do script, mas NÃO são exportadas: assim todo "docker compose" chamado
# pelos scripts lê o .env por conta própria e vê sempre o valor atual do arquivo.
# Variáveis já definidas no ambiente têm prioridade, como no Compose.
env_value() { # $1 = valor bruto depois do "="
  local v="$1"
  if [[ "$v" =~ ^\"(.*)\"[[:space:]]*(#.*)?$ ]] || [[ "$v" =~ ^\'(.*)\'[[:space:]]*(#.*)?$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return
  fi
  # Mesma ordem do Compose: tira os espaços à esquerda; se o valor então começa
  # com "#", é literal; senão, " #..." é comentário.
  v="${v#"${v%%[![:space:]]*}"}"          # espaços à esquerda
  [[ "$v" == \#* ]] || v="${v%%[[:space:]]#*}"
  v="${v%"${v##*[![:space:]]}"}"          # espaços à direita
  printf '%s' "$v"
}

load_env() {
  load_env_sem_checar_senhas
  check_password POSTGRES_PASSWORD "${POSTGRES_PASSWORD:-}"
  check_password ESUS_LEITURA_PASSWORD "${ESUS_LEITURA_PASSWORD:-}"
}

# Usado só pelo trocar-senhas.sh, que existe justamente para trocar senhas fracas.
load_env_sem_checar_senhas() {
  [ -f "$ENV_FILE" ] || die "Arquivo .env não encontrado em ${PROJECT_ROOT}. Rode ./scripts/gerar-env.sh"
  local line key name
  # Como no Compose: variável que já veio exportada do ambiente vale mais que o
  # arquivo; entre linhas repetidas do arquivo, vale a última.
  local -A from_env=()
  while IFS= read -r name; do from_env["$name"]=1; done < <(compgen -e)
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=(.*)$ ]] || continue
    key="${BASH_REMATCH[2]}"
    if [ -z "${from_env[$key]:-}" ]; then
      printf -v "$key" '%s' "$(env_value "${BASH_REMATCH[3]}")"
    fi
  done < "$ENV_FILE"

  POSTGRES_USER="${POSTGRES_USER:-postgres}"
  POSTGRES_DB="${POSTGRES_DB:-esus}"
  ESUS_LEITURA_USER="${ESUS_LEITURA_USER:-esus_leitura}"
}

# Mesma regra do entrypoint do banco: nada vazio, curto ou com o valor de exemplo.
check_password() {
  local name="$1" value="$2"
  [ -n "$value" ] || die "${name} vazia no .env (rode ./scripts/gerar-env.sh)"
  if [ "${#value}" -lt 16 ] || [[ "$value" == altere_* ]]; then
    die "${name} fraca ou com o valor de exemplo (mínimo 16 caracteres). Use ./scripts/trocar-senhas.sh"
  fi
}

container_running() {
  [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = "true" ]
}

container_exists() {
  docker inspect "$1" >/dev/null 2>&1
}

# Espera o esus-db responder (até $1 segundos, padrão 120).
wait_db() {
  local max="${1:-120}" waited=0
  # -h 127.0.0.1: durante o initdb o servidor temporário só escuta no socket;
  # pelo TCP o "pronto" só vem quando o servidor definitivo subiu.
  until docker exec "$DB_CONTAINER" pg_isready -q -h 127.0.0.1 -U "$POSTGRES_USER" -d postgres 2>/dev/null; do
    waited=$((waited + 2))
    [ "$waited" -ge "$max" ] && die "PostgreSQL (${DB_CONTAINER}) não respondeu em ${max}s"
    sleep 2
  done
}

# psql no container do banco. Uso: psql_db <banco> [args do psql...]
psql_db() {
  local db="$1"; shift
  docker exec -i "$DB_CONTAINER" psql -v ON_ERROR_STOP=1 -X -q -U "$POSTGRES_USER" -d "$db" "$@"
}

# Valor único de uma consulta. Uso: sql_value <banco> "<sql>"
sql_value() {
  psql_db "$1" -tA -c "$2" | tr -d '\r'
}

count_tables() {
  sql_value "$1" "SELECT count(*) FROM pg_tables WHERE schemaname = 'public'"
}

# Cria/atualiza o usuário de leitura no banco $1 com a senha do .env.
# A senha segue por variável de ambiente (docker exec -e), fora da linha de comando.
apply_leitura() {
  local db="${1:-$POSTGRES_DB}" pwd="${2:-$ESUS_LEITURA_PASSWORD}"
  check_password ESUS_LEITURA_PASSWORD "$pwd"
  # A senha vai como variável de ambiente só deste comando (-e NOME, sem valor
  # na linha de comando), então não aparece no "ps" do host.
  ESUS_LEITURA_USER="$ESUS_LEITURA_USER" ESUS_LEITURA_PASSWORD="$pwd" \
    docker exec -i -e ESUS_LEITURA_USER -e ESUS_LEITURA_PASSWORD "$DB_CONTAINER" \
    psql -v ON_ERROR_STOP=1 -X -q -U "$POSTGRES_USER" -d "$db" -f - < "${PROJECT_ROOT}/sql/esus-leitura.sql"
}

# Roda o migrador oficial (Liquibase) contra o banco $1.
# Argumentos extras são repassados (ex.: -treinamento).
# O migrador só aceita a senha como argumento (-password=). Para ela não ficar
# visível no "ps" durante os minutos da migração, os argumentos vão num
# argfile do Java (@arquivo, permissão 600) dentro do container descartável.
run_migrador() {
  local db="$1"; shift
  local flags="$*"
  log "Executando migrador.jar no banco '${db}' (pode levar de 5 a 15 minutos)..."
  # As variáveis são expandidas dentro do container, por isso as aspas simples.
  # shellcheck disable=SC2016
  docker compose run --rm --no-deps -T \
    -e MIGR_DB="$db" -e MIGR_FLAGS="$flags" \
    --entrypoint sh esus-pec -c '
      set -e
      umask 077
      ARGS=$(mktemp)
      {
        echo "-jar /opt/pec/database/migrador.jar"
        echo "\"-url=jdbc:postgresql://esus-db:5432/${MIGR_DB}\""
        echo "\"-username=${SPRING_DATASOURCE_USERNAME}\""
        echo "\"-password=${SPRING_DATASOURCE_PASSWORD}\""
        for f in ${MIGR_FLAGS}; do echo "$f"; done
      } > "$ARGS"
      exec java -Xms512M -Xmx2048M "@${ARGS}"'
}

# Confere se um arquivo é um dump -Fc legível. Imprime o número de tabelas.
validate_dump() {
  local file="$1" list
  list="$(docker exec -i "$DB_CONTAINER" pg_restore --list < "$file" 2>/dev/null)" || return 1
  printf '%s\n' "$list" | grep -c ' TABLE public ' || true
}
