#!/usr/bin/env bash
# ==============================================================================
# e-SUS APS PEC em Docker (Linux) - Entrypoint
# ==============================================================================
# Ordem: valida variáveis, ajusta dono dos volumes, espera o banco, cuida do
# HTTPS (certmgr) e troca para o usuário "pec" antes de iniciar a JVM.
# Espelha o standalone.sh oficial do pacote (container/webserver/standalone.sh).
# ==============================================================================
set -euo pipefail

PEC_HOME=/opt/pec/webserver
CERTMGR_DIR="${PEC_HOME}/certmgr"
SSL_PROPS="${CERTMGR_DIR}/config/ssl.properties"

log() { echo "[entrypoint] $*"; }
die() { echo "[entrypoint] ERRO: $*" >&2; exit 1; }

cd "$PEC_HOME"

# ------------------------------------------------------------------------------
# 1. Variáveis obrigatórias
# ------------------------------------------------------------------------------
: "${SPRING_DATASOURCE_URL:?defina SPRING_DATASOURCE_URL}"
: "${SPRING_DATASOURCE_USERNAME:?defina SPRING_DATASOURCE_USERNAME}"
: "${SPRING_DATASOURCE_PASSWORD:?defina SPRING_DATASOURCE_PASSWORD}"
# O pacote oficial grava o driver no application.properties; aqui ele vem do ambiente.
export SPRING_DATASOURCE_DRIVER_CLASS_NAME="${SPRING_DATASOURCE_DRIVER_CLASS_NAME:-org.postgresql.Driver}"
# O ":?" do compose só barra senha vazia; aqui também barra a de exemplo e as curtas.
if [ "${#SPRING_DATASOURCE_PASSWORD}" -lt 16 ] || [[ "$SPRING_DATASOURCE_PASSWORD" == altere_* ]]; then
  die "POSTGRES_PASSWORD fraca ou com o valor de exemplo. Rode ./scripts/gerar-env.sh (instalação nova) ou ./scripts/trocar-senhas.sh."
fi

# ------------------------------------------------------------------------------
# 2. Memória da JVM (mesmos parâmetros do standalone.sh oficial)
# ------------------------------------------------------------------------------
PEC_HEAP="${PEC_HEAP:-4096M}"
if [[ ! "$PEC_HEAP" =~ ^([0-9]+)([MmGg])$ ]]; then
  die "PEC_HEAP inválido: '${PEC_HEAP}' (use, por exemplo, 4096M ou 8G)"
fi
HEAP_MB="${BASH_REMATCH[1]}"
[[ "${BASH_REMATCH[2]}" =~ [Gg] ]] && HEAP_MB=$((HEAP_MB * 1024))
# -Xms não pode passar do -Xmx, senão a JVM recusa iniciar.
XMS_MB=$(( HEAP_MB < 2048 ? HEAP_MB : 2048 ))

JAVA_OPTS=(
  "-Xms${XMS_MB}M" "-Xmx${HEAP_MB}M"
  -XX:MetaspaceSize=256M -XX:MaxMetaspaceSize=512M
  -XX:ReservedCodeCacheSize=512M -XX:CompressedClassSpaceSize=256M
  -Djava.net.preferIPv4Stack=true
  -Dfile.encoding=UTF-8
  -Djava.awt.headless=true
  -Djboss.threads.eqe.statistics.active-count=true
)
# Opções extras (ex.: PEC_JAVA_OPTS_EXTRA="-XX:+HeapDumpOnOutOfMemoryError")
if [ -n "${PEC_JAVA_OPTS_EXTRA:-}" ]; then
  read -r -a EXTRA <<< "$PEC_JAVA_OPTS_EXTRA"
  JAVA_OPTS+=("${EXTRA[@]}")
fi

echo "=========================================================="
echo "e-SUS APS PEC em Docker (Linux)"
echo "Fuso horário: ${TZ:-America/Sao_Paulo} | Heap: -Xms${XMS_MB}M -Xmx${HEAP_MB}M"
echo "=========================================================="

# ------------------------------------------------------------------------------
# 3. Usuário sem privilégios
# ------------------------------------------------------------------------------
# Volumes montados do host chegam com dono root. Ajusta e roda a JVM como "pec".
# Chaves RNDS, certificado e logs ficam só para o usuário pec (700/umask 027).
RUN_AS=()
if [ "$(id -u)" = "0" ]; then
  for dir in config chaves logs certmgr/config; do
    mkdir -p "${PEC_HOME}/${dir}"
    { chown -R pec:pec "${PEC_HOME}/${dir}" && chmod 700 "${PEC_HOME}/${dir}"; } 2>/dev/null \
      || log "AVISO: não foi possível ajustar dono/permissão de ${dir} (sistema de arquivos sem chown?)"
  done
  RUN_AS=(setpriv --reuid=pec --regid=pec --init-groups --)
fi
umask 027

# ------------------------------------------------------------------------------
# 4. Espera o PostgreSQL (com limite de tempo)
# ------------------------------------------------------------------------------
if [ -n "${DB_HOST:-}" ]; then
  WAIT_MAX="${DB_WAIT_TIMEOUT:-300}"
  log "Aguardando PostgreSQL em ${DB_HOST}:${DB_PORT:-5432} (até ${WAIT_MAX}s)..."
  waited=0
  until pg_isready -q -h "$DB_HOST" -p "${DB_PORT:-5432}" -U "$SPRING_DATASOURCE_USERNAME" -d "${DB_NAME:-esus}"; do
    waited=$((waited + 3))
    [ "$waited" -ge "$WAIT_MAX" ] && die "PostgreSQL não respondeu em ${WAIT_MAX}s"
    sleep 3
  done
  log "PostgreSQL pronto."
fi

# ------------------------------------------------------------------------------
# 5. HTTPS com o certmgr oficial
# ------------------------------------------------------------------------------
if [ "${PEC_SSL:-0}" = "1" ]; then
  if [ ! -f "$SSL_PROPS" ]; then
    [ -n "${PEC_SSL_DOMAIN:-}" ] \
      || die "PEC_SSL=1, mas não há certificado ativado. Defina PEC_SSL_DOMAIN (domínio público apontando para este servidor, com as portas 80 e 443 liberadas)."
    log "Ativando HTTPS para ${PEC_SSL_DOMAIN} (porta ${PEC_SSL_PORT:-443})..."
    if ! (cd "$CERTMGR_DIR" && "${RUN_AS[@]}" java -jar certmgr.jar --enable \
        --domain="$PEC_SSL_DOMAIN" --port="${PEC_SSL_PORT:-443}"); then
      # Sem a pausa, o restart automático repetiria a emissão em loop e
      # estouraria o limite de validações falhas da autoridade certificadora.
      RETRY="${PEC_SSL_RETRY_DELAY:-600}"
      log "ERRO: certmgr --enable falhou. Confira o DNS do domínio e as portas 80/443 no roteador."
      log "Nova tentativa em ${RETRY}s (PEC_SSL_RETRY_DELAY). Para subir sem HTTPS, use PEC_SSL=0."
      sleep "$RETRY"
      exit 1
    fi
  fi
  export SPRING_CONFIG_ADDITIONAL_LOCATION="$SSL_PROPS"
  log "Renovando certificado (certmgr --renew)..."
  if ! (cd "$CERTMGR_DIR" && "${RUN_AS[@]}" java -jar certmgr.jar --renew); then
    log "ERRO: certmgr --renew falhou. O PEC sobe com o certificado atual; confira a validade dele."
  fi
else
  log "HTTPS desativado (PEC_SSL=0): PEC em HTTP na porta 8080."
fi

# ------------------------------------------------------------------------------
# 6. PEC (Spring Boot / Undertow)
# ------------------------------------------------------------------------------
log "Iniciando pec-bundle.jar..."
exec "${RUN_AS[@]}" java "${JAVA_OPTS[@]}" -jar pec-bundle.jar
