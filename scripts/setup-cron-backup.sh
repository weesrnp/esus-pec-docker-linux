#!/usr/bin/env bash
# ==============================================================================
# e-SUS APS PEC em Docker (Linux) - Instalador de Agendamento de Backup (Cron)
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
BACKUP_SCRIPT="${PROJECT_ROOT}/scripts/backup.sh"
BACKUP_DIR="${PROJECT_ROOT}/backups"
LOG_FILE="${BACKUP_DIR}/cron_backup.log"

CRON_HOUR="${CRON_HOUR:-23}"
CRON_MINUTE="${CRON_MINUTE:-0}"
RETENTION_DAYS="${RETENTION_DAYS:-30}"

JOB_MARKER="# ESUS_PEC_DOCKER_BACKUP_JOB"

show_current() {
  echo "==> Agendamentos ativos para e-SUS PEC:"
  (crontab -l 2>/dev/null || true) | grep "$JOB_MARKER" || echo "    Nenhum agendamento configurado."
}

remove_cron() {
  echo "==> Removendo agendamento automático de backup..."
  (crontab -l 2>/dev/null || true) | grep -v "$JOB_MARKER" | crontab -
  echo "==> Agendamento removido com sucesso."
}

install_cron() {
  mkdir -p "$BACKUP_DIR"
  chmod +x "$BACKUP_SCRIPT"

  # Linha do agendamento: roda no horário configurado e expurga arquivos com mais de X dias
  CRON_LINE="${CRON_MINUTE} ${CRON_HOUR} * * * /usr/bin/env bash \"${BACKUP_SCRIPT}\" >> \"${LOG_FILE}\" 2>&1 && find \"${BACKUP_DIR}\" -name \"*.backup\" -type f -mtime +${RETENTION_DAYS} -delete ${JOB_MARKER}"

  # Remove agendamento antigo do mesmo marcador para não duplicar
  CURRENT_CRON=$( (crontab -l 2>/dev/null || true) | grep -v "$JOB_MARKER" || true )

  # Adiciona a nova linha
  if [ -n "$CURRENT_CRON" ]; then
    printf "%s\n%s\n" "$CURRENT_CRON" "$CRON_LINE" | crontab -
  else
    printf "%s\n" "$CRON_LINE" | crontab -
  fi

  echo "=========================================================="
  echo "Agendamento de Backup configurado com sucesso no crontab!"
  echo "Horário: Diariamente às $(printf "%02d:%02d" "$CRON_HOUR" "$CRON_MINUTE")"
  echo "Retenção: Manter últimos ${RETENTION_DAYS} dias"
  echo "Log de Execução: ${LOG_FILE}"
  echo "=========================================================="
}

case "${1:-}" in
  --show)
    show_current
    ;;
  --remove)
    remove_cron
    ;;
  *)
    install_cron
    ;;
esac
