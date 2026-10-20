#!/usr/bin/env bash
# ==============================================================================
# e-SUS APS PEC em Docker (Linux) - Utilitário de Diagnóstico Pré-Voo (Doctor)
# ==============================================================================
set -u

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

echo "=========================================================="
echo "Diagnóstico Pré-Voo do Ambiente: e-SUS APS PEC (Docker)"
echo "Data: $(date)"
echo "Diretório do Projeto: ${PROJECT_ROOT}"
echo "=========================================================="

ERRORS=0
WARNINGS=0

check_ok() {
  echo -e " [${GREEN}OK${NC}] $1"
}

check_warn() {
  echo -e " [${YELLOW}AVISO${NC}] $1"
  WARNINGS=$((WARNINGS + 1))
}

check_fail() {
  echo -e " [${RED}FALHA${NC}] $1"
  ERRORS=$((ERRORS + 1))
}

# ------------------------------------------------------------------------------
# 1. Docker Engine e Docker Compose
# ------------------------------------------------------------------------------
if command -v docker >/dev/null 2>&1; then
  DOCKER_VER=$(docker --version | cut -d ' ' -f3 | tr -d ',')
  check_ok "Docker Engine instalado (versão: ${DOCKER_VER})"
  if docker info >/dev/null 2>&1; then
    check_ok "Docker daemon em execução e comunicável"
  else
    check_fail "Docker daemon não está respondendo (verifique: systemctl status docker)"
  fi
else
  check_fail "Docker Engine não encontrado no sistema"
fi

if docker compose version >/dev/null 2>&1; then
  COMPOSE_VER=$(docker compose version --short 2>/dev/null || echo "v2")
  check_ok "Docker Compose v2 disponível (versão: ${COMPOSE_VER})"
else
  check_fail "Plugin Docker Compose (v2) não localizado"
fi

# ------------------------------------------------------------------------------
# 2. Memória RAM e Espaço em Disco
# ------------------------------------------------------------------------------
if [ -f /proc/meminfo ]; then
  TOTAL_MEM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
  TOTAL_MEM_MB=$((TOTAL_MEM_KB / 1024))
  if [ "$TOTAL_MEM_MB" -ge 7500 ]; then
    check_ok "Memória RAM total: ${TOTAL_MEM_MB} MB (atende ao requisito mínimo de 8 GB)"
  else
    check_warn "Memória RAM total: ${TOTAL_MEM_MB} MB. Recomendado no mínimo 8 GB para produção."
  fi
else
  check_warn "Não foi possível inspecionar /proc/meminfo (verificação de memória ignorada)"
fi

AVAIL_DISK_KB=$(df -P "$PROJECT_ROOT" | tail -1 | awk '{print $4}')
AVAIL_DISK_GB=$((AVAIL_DISK_KB / 1024 / 1024))
if [ "$AVAIL_DISK_GB" -ge 20 ]; then
  check_ok "Espaço livre em disco: ${AVAIL_DISK_GB} GB (mínimo recomendado: 20 GB)"
else
  check_warn "Espaço livre em disco reduzido: ${AVAIL_DISK_GB} GB. Monitore o crescimento do banco e backups."
fi

# ------------------------------------------------------------------------------
# 3. Arquivo de Ambiente (.env) e Senhas Padrão
# ------------------------------------------------------------------------------
ENV_FILE="${PROJECT_ROOT}/.env"
if [ -f "$ENV_FILE" ]; then
  check_ok "Arquivo de configuração .env localizado"
  if grep -q "altere_essa_senha_super_secreta_aqui_123" "$ENV_FILE"; then
    check_warn "A senha padrão do PostgreSQL não foi alterada no arquivo .env!"
  fi
else
  check_warn "Arquivo .env não encontrado. Copie o .env.example para .env antes de subir a stack."
fi

# ------------------------------------------------------------------------------
# 4. Checagem de Conflito de Portas Locais
# ------------------------------------------------------------------------------
check_port() {
  PORT=$1
  NAME=$2
  if command -v ss >/dev/null 2>&1; then
    if ss -tuln | grep -q ":${PORT} "; then
      check_warn "Porta ${PORT} (${NAME}) já está em uso por outro processo no host."
    else
      check_ok "Porta ${PORT} (${NAME}) disponível"
    fi
  fi
}

check_port 8080 "e-SUS PEC HTTP"
check_port 443 "e-SUS PEC HTTPS"
check_port 5433 "PostgreSQL Externo"

# ------------------------------------------------------------------------------
# 5. Sincronização de Relógio / Fuso Horário
# ------------------------------------------------------------------------------
CURRENT_TZ=$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo "Desconhecido")
check_ok "Fuso horário do host: ${CURRENT_TZ} (Horário atual: $(date +"%H:%M:%S"))"

# ------------------------------------------------------------------------------
# Resumo do Diagnóstico
# ------------------------------------------------------------------------------
echo "=========================================================="
if [ "$ERRORS" -eq 0 ] && [ "$WARNINGS" -eq 0 ]; then
  echo -e "${GREEN}Ambiente 100% aprovado para execução do e-SUS PEC!${NC}"
elif [ "$ERRORS" -eq 0 ]; then
  echo -e "${YELLOW}Ambiente pronto com ${WARNINGS} aviso(s). Revise os itens antes de produção.${NC}"
else
  echo -e "${RED}Ambiente requer correção de ${ERRORS} problema(s) impeditivo(s).${NC}"
fi
echo "=========================================================="

exit "$ERRORS"
