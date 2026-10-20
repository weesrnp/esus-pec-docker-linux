#!/usr/bin/env bash
# ==============================================================================
# e-SUS APS PEC em Docker (Linux) - Rotina de Backup Consistente
# ==============================================================================
set -euo pipefail

BACKUP_DIR="backups"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
BACKUP_FILE="${BACKUP_DIR}/esus_backup_${TIMESTAMP}.backup"

mkdir -p "$BACKUP_DIR"

echo "=========================================================="
echo "Iniciando Backup do e-SUS PEC (Container: esus-db)"
echo "Data/Hora: $(date)"
echo "Arquivo de Destino: ${BACKUP_FILE}"
echo "=========================================================="

# Executa pg_dump no formato customizado (comprimido e consistente)
docker exec -t esus-db pg_dump -U postgres -d esus -F c -b -v > "${BACKUP_FILE}"

# Verifica se o arquivo foi gerado e possui tamanho válido (> 1MB)
FILESIZE=$(stat -c%s "${BACKUP_FILE}" 2>/dev/null || stat -f%z "${BACKUP_FILE}" 2>/dev/null || echo 0)

if [ "$FILESIZE" -gt 1048576 ]; then
  echo "==> Backup concluído com sucesso!"
  echo "==> Tamanho: $(du -h "${BACKUP_FILE}" | cut -f1)"
else
  echo "ERRO: O arquivo gerado parece inconsistente ou corrompido (Tamanho: $FILESIZE bytes)." >&2
  exit 1
fi
