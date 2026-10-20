#!/usr/bin/env bash
# ==============================================================================
# e-SUS APS PEC em Docker (Linux) - Agenda o backup diário no crontab
# ==============================================================================
# Uso: ./scripts/setup-cron-backup.sh [--show | --remove]
#   Variáveis opcionais: CRON_HOUR (23), CRON_MINUTE (0)
#   A retenção (RETENTION_DAYS) e a pasta (BACKUP_DIR) vêm do .env.
# Instale no crontab de um usuário do grupo "docker" (ou do root).
# ==============================================================================
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BACKUP_SCRIPT="${PROJECT_ROOT}/scripts/backup.sh"
load_env
BACKUP_DIR="${BACKUP_DIR:-${PROJECT_ROOT}/backups}"
LOG_FILE="${BACKUP_DIR}/cron_backup.log"
CRON_HOUR="${CRON_HOUR:-23}"
CRON_MINUTE="${CRON_MINUTE:-0}"
JOB_MARKER="# ESUS_PEC_DOCKER_BACKUP_JOB"

[[ "$CRON_HOUR" =~ ^([01]?[0-9]|2[0-3])$ ]] || die "CRON_HOUR inválida: ${CRON_HOUR}"
[[ "$CRON_MINUTE" =~ ^[0-5]?[0-9]$ ]] || die "CRON_MINUTE inválido: ${CRON_MINUTE}"
command -v crontab >/dev/null 2>&1 || die "crontab não encontrado (instale o pacote cron)."

current_without_job() {
  (crontab -l 2>/dev/null || true) | grep -vF "$JOB_MARKER" || true
}

case "${1:-}" in
  --show)
    log "Agendamento do backup do e-SUS PEC:"
    (crontab -l 2>/dev/null || true) | grep -F "$JOB_MARKER" || echo "    Nenhum agendamento configurado."
    ;;
  --remove)
    current_without_job | crontab -
    log "Agendamento removido."
    ;;
  "")
    mkdir -p "$BACKUP_DIR"
    chmod 700 "$BACKUP_DIR"
    chmod +x "$BACKUP_SCRIPT"
    # O backup.sh entra sozinho na raiz do projeto e aplica a retenção do .env.
    CRON_LINE="${CRON_MINUTE} ${CRON_HOUR} * * * /usr/bin/env bash \"${BACKUP_SCRIPT}\" >> \"${LOG_FILE}\" 2>&1 ${JOB_MARKER}"
    { current_without_job; echo "$CRON_LINE"; } | sed '/^$/d' | crontab -
    echo "=========================================================="
    echo "Backup agendado: diariamente às $(printf '%02d:%02d' "$((10#$CRON_HOUR))" "$((10#$CRON_MINUTE))")"
    echo "Log: ${LOG_FILE}"
    echo "Retenção: RETENTION_DAYS do .env (padrão 30 dias)"
    echo "=========================================================="
    ;;
  *) die "Uso: $0 [--show | --remove]" ;;
esac
