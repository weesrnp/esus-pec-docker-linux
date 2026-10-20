#!/usr/bin/env bash
# ==============================================================================
# e-SUS APS PEC em Docker (Linux) - Diagnóstico do servidor (doctor)
# ==============================================================================
# Uso: ./scripts/doctor.sh
# Código de saída: número de falhas impeditivas (0 = pode subir).
# ==============================================================================
set -u

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
ERRORS=0; WARNINGS=0
ok()   { echo -e " [${GREEN}OK${NC}] $1"; }
aviso(){ echo -e " [${YELLOW}AVISO${NC}] $1"; WARNINGS=$((WARNINGS + 1)); }
falha(){ echo -e " [${RED}FALHA${NC}] $1"; ERRORS=$((ERRORS + 1)); }

# Lê uma chave do .env sem executá-lo
env_get() {
  [ -f "$ENV_FILE" ] || return 0
  env_value "$(grep -E "^[[:space:]]*$1[[:space:]]*=" "$ENV_FILE" | tail -n 1 | cut -d= -f2- | tr -d '\r')"
}

to_mb() { # 4096M | 8G | 2GB | 512MB -> MB
  local v="${1^^}"; v="${v%B}"
  case "$v" in
    *G) echo $(( ${v%G} * 1024 )) ;;
    *M) echo "${v%M}" ;;
    *) echo 0 ;;
  esac
}

echo "=========================================================="
echo "Diagnóstico do servidor: e-SUS APS PEC (Docker)"
echo "Data: $(date '+%d/%m/%Y %H:%M:%S') | Projeto: ${PROJECT_ROOT}"
echo "=========================================================="

# 1. Sistema e Docker -----------------------------------------------------------
ARCH="$(uname -m)"
if [ "$ARCH" = "x86_64" ]; then ok "Arquitetura ${ARCH}"; else falha "Arquitetura ${ARCH}: o PEC Linux64 só é distribuído para x86_64"; fi

if command -v docker >/dev/null 2>&1; then
  ok "Docker instalado ($(docker --version | awk '{print $3}' | tr -d ','))"
  if docker info >/dev/null 2>&1; then
    ok "Docker daemon respondendo"
  else
    falha "Docker daemon sem resposta (systemctl status docker; usuário no grupo docker?)"
  fi
  if docker compose version >/dev/null 2>&1; then
    ok "Docker Compose $(docker compose version --short 2>/dev/null)"
  else
    falha "Plugin Docker Compose v2 não encontrado"
  fi
else
  falha "Docker não encontrado"
fi
command -v unzip >/dev/null 2>&1 || aviso "unzip não instalado (usado para validar o instalador)"
command -v flock >/dev/null 2>&1 || aviso "flock não instalado (pacote util-linux; usado pelo backup)"

# 2. .env e senhas --------------------------------------------------------------
if [ -f "$ENV_FILE" ]; then
  ok ".env encontrado"
  PERM="$(stat -c '%a' "$ENV_FILE" 2>/dev/null || echo '?')"
  if [ "$PERM" = "600" ] || [ "$PERM" = "400" ]; then
    ok ".env com permissão ${PERM}"
  else
    aviso ".env com permissão ${PERM}: rode chmod 600 .env (contém as senhas do banco)"
  fi
  for key in POSTGRES_PASSWORD ESUS_LEITURA_PASSWORD; do
    val="$(env_get "$key")"
    if [ -z "$val" ]; then
      falha "${key} vazia no .env (rode ./scripts/gerar-env.sh)"
    elif [[ "$val" == altere_* ]]; then
      falha "${key} ainda é o valor de exemplo publicado no repositório. Use ./scripts/trocar-senhas.sh (instalação existente) ou ./scripts/gerar-env.sh (nova)"
    elif [ "${#val}" -lt 16 ]; then
      aviso "${key} com ${#val} caracteres (recomendado: 16 ou mais). Use ./scripts/trocar-senhas.sh"
    else
      ok "${key} definida (${#val} caracteres)"
    fi
  done
  if git -C "$PROJECT_ROOT" ls-files --error-unmatch .env >/dev/null 2>&1; then
    falha ".env está versionado no git! Rode: git rm --cached .env e troque as senhas"
  fi
else
  falha ".env não encontrado. Rode ./scripts/gerar-env.sh"
fi

# 3. Instalador ------------------------------------------------------------------
JAR="$(env_get PEC_JAR_FILE)"
if [ -n "$JAR" ] && [ -f "${PROJECT_ROOT}/instalador/${JAR}" ]; then
  if unzip -l "${PROJECT_ROOT}/instalador/${JAR}" container/webserver/pec-bundle.jar >/dev/null 2>&1; then
    ok "Instalador instalador/${JAR} válido"
  else
    falha "instalador/${JAR} não é um instalador válido do PEC (baixe de novo: ./scripts/get-latest-pec.sh --download)"
  fi
elif docker image inspect "esus-pec-docker:$(env_get PEC_IMAGE_TAG)" >/dev/null 2>&1; then
  ok "Imagem do PEC já construída (instalador não necessário agora)"
else
  aviso "Instalador ${JAR:-<PEC_JAR_FILE vazio>} não está em instalador/ e a imagem ainda não existe"
fi
if compgen -G "${PROJECT_ROOT}/eSUS-AB-PEC-*-Linux64.jar" >/dev/null; then
  aviso "Há instalador na raiz do projeto: mova para instalador/ (o build não lê a raiz)"
fi

# 3b. Banco em execução ------------------------------------------------------------
if container_running "$DB_CONTAINER"; then
  PGU="$(env_get POSTGRES_USER)"; PGU="${PGU:-postgres}"
  # Senha fixa que existia no SQL público das versões antigas deste repositório
  if docker exec -e PGPASSWORD=esus_leitura_segura_2026 "$DB_CONTAINER" \
       psql -h 127.0.0.1 -U esus_leitura -d postgres -tAc 'select 1' >/dev/null 2>&1; then
    falha "esus_leitura ainda aceita a senha antiga publicada no repositório. Rode ./scripts/trocar-senhas.sh --leitura"
  else
    ok "esus_leitura não aceita a senha antiga do repositório"
  fi
  OLD_DBS="$(docker exec "$DB_CONTAINER" psql -U "$PGU" -d postgres -tAc \
    "select string_agg(datname, ', ') from pg_database where datname ~ '_(antes|restore)_[0-9]{8}_'" 2>/dev/null | tr -d '\r')"
  if [ -n "$OLD_DBS" ]; then
    aviso "Bancos antigos de restauração ocupando disco (cópias de dados de pacientes): ${OLD_DBS}. Apague com dropdb depois de conferir o PEC."
  fi
fi

# 4. Memória e disco -------------------------------------------------------------
if [ -r /proc/meminfo ]; then
  MEM_MB=$(( $(awk '/MemTotal/ {print $2}' /proc/meminfo) / 1024 ))
  HEAP_MB="$(to_mb "$(env_get PEC_HEAP)")"; [ "$HEAP_MB" -gt 0 ] || HEAP_MB=4096
  SB_MB="$(to_mb "$(env_get PG_SHARED_BUFFERS)")"; [ "$SB_MB" -gt 0 ] || SB_MB=2048
  NEED_MB=$(( HEAP_MB + 1024 + SB_MB + 1024 ))   # heap + metaspace/JIT + shared_buffers + SO
  if [ "$MEM_MB" -lt 7500 ]; then
    falha "RAM total ${MEM_MB} MB: o mínimo oficial é 8 GB"
  elif [ "$MEM_MB" -lt "$NEED_MB" ]; then
    aviso "RAM ${MEM_MB} MB < ${NEED_MB} MB estimados (PEC_HEAP ${HEAP_MB} + shared_buffers ${SB_MB}). Reduza PEC_HEAP ou PG_SHARED_BUFFERS."
  else
    ok "RAM ${MEM_MB} MB (estimativa de uso: ${NEED_MB} MB)"
  fi
fi
DISK_GB=$(( $(df -Pk "$PROJECT_ROOT" | awk 'NR==2 {print $4}') / 1048576 ))
if [ "$DISK_GB" -ge 50 ]; then
  ok "Disco livre: ${DISK_GB} GB"
elif [ "$DISK_GB" -ge 20 ]; then
  aviso "Disco livre: ${DISK_GB} GB. O manual oficial pede 100 GB; banco e backups crescem."
else
  falha "Disco livre: ${DISK_GB} GB (mínimo 20 GB)"
fi

# 5. Portas ----------------------------------------------------------------------
check_port() {
  local port="$1" name="$2"
  if command -v ss >/dev/null 2>&1; then
    if ss -Htln "sport = :${port}" 2>/dev/null | grep -q .; then
      if docker ps --format '{{.Ports}}' 2>/dev/null | grep -q ":${port}->"; then
        ok "Porta ${port} (${name}) em uso por um container Docker"
      else
        aviso "Porta ${port} (${name}) ocupada por outro processo no host"
      fi
    else
      ok "Porta ${port} (${name}) livre"
    fi
  fi
}
P_HTTP="$(env_get PEC_HTTP_PORT)"; P_HTTPS="$(env_get PEC_HTTPS_PORT)"; P_PG="$(env_get POSTGRES_EXTERNAL_PORT)"
check_port "${P_HTTP:-8080}" "PEC HTTP"
check_port "${P_HTTPS:-443}" "PEC HTTPS"
check_port "${P_PG:-5433}" "PostgreSQL"
if [ -n "$(env_get PEC_SSL_DOMAIN)" ]; then
  PEC_BIND="$(env_get PEC_BIND_IP)"
  if [ -z "$PEC_BIND" ] || [ "$PEC_BIND" = "127.0.0.1" ]; then
    falha "PEC_SSL_DOMAIN definido, mas PEC_BIND_IP=${PEC_BIND:-127.0.0.1}: a validação do domínio (portas 80/443) não chega ao container"
  fi
fi
# Compatibilidade: até 2026-10 o LAN_IP publicava também o banco.
if [ -n "$(env_get LAN_IP)" ] && [ -z "$(env_get POSTGRES_BIND_IP)" ] && [ "$(env_get LAN_IP)" != "127.0.0.1" ]; then
  aviso "LAN_IP=$(env_get LAN_IP) no .env: o PEC continua nesse IP, mas o banco agora fica só em 127.0.0.1. Se algum BI acessava a porta do banco pela rede, defina POSTGRES_BIND_IP (de preferência com VPN/túnel)."
fi
PG_BIND="$(env_get POSTGRES_BIND_IP)"
if [ -n "$PG_BIND" ] && [ "$PG_BIND" != "127.0.0.1" ]; then
  aviso "POSTGRES_BIND_IP=${PG_BIND}: o banco fica acessível na rede e o Docker ignora o UFW. Prefira 127.0.0.1 + VPN/túnel."
fi

# 6. Relógio ---------------------------------------------------------------------
# Hora errada quebra certificados, envio ao SISAB/RNDS e registros clínicos.
if command -v timedatectl >/dev/null 2>&1; then
  TZ_HOST="$(timedatectl show -p Timezone --value 2>/dev/null)"
  NTP="$(timedatectl show -p NTPSynchronized --value 2>/dev/null)"
  if [ "$NTP" = "yes" ]; then
    ok "Relógio sincronizado por NTP (fuso do host: ${TZ_HOST})"
  else
    falha "Relógio NÃO sincronizado por NTP (timedatectl set-ntp true)"
  fi
else
  aviso "timedatectl indisponível: confira o NTP manualmente (hora atual $(date '+%H:%M:%S'))"
fi

# 7. Backup ----------------------------------------------------------------------
if (crontab -l 2>/dev/null || true) | grep -q "ESUS_PEC_DOCKER_BACKUP_JOB"; then
  ok "Backup diário agendado no crontab deste usuário"
else
  aviso "Backup diário não agendado (./scripts/setup-cron-backup.sh)"
fi

echo "=========================================================="
if [ "$ERRORS" -eq 0 ] && [ "$WARNINGS" -eq 0 ]; then
  echo -e "${GREEN}Servidor aprovado para o e-SUS PEC.${NC}"
elif [ "$ERRORS" -eq 0 ]; then
  echo -e "${YELLOW}Pronto, com ${WARNINGS} aviso(s). Revise antes de produção.${NC}"
else
  echo -e "${RED}${ERRORS} falha(s) impeditiva(s) e ${WARNINGS} aviso(s).${NC}"
fi
echo "=========================================================="
exit "$ERRORS"
