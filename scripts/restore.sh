#!/usr/bin/env bash
# ==============================================================================
# e-SUS APS PEC em Docker (Linux) - Rotina de Restauração Segura
# ==============================================================================
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "Uso: $0 <caminho_do_arquivo.backup>" >&2
  echo "Exemplo: $0 backups/esus_backup_20261019_220000.backup" >&2
  exit 1
fi

BACKUP_FILE="$1"

if [ ! -f "$BACKUP_FILE" ]; then
  echo "ERRO: O arquivo de backup '$BACKUP_FILE' não foi encontrado." >&2
  exit 1
fi

echo "=========================================================="
echo "ATENÇÃO: Processo de Restauração de Banco de Dados"
echo "Arquivo: $BACKUP_FILE"
echo "Destino: Container esus-db (Banco: esus)"
echo "=========================================================="
read -p "Deseja realmente sobrescrever a base 'esus'? Todos os dados não salvos serão perdidos. (s/N): " CONFIRM

if [[ ! "$CONFIRM" =~ ^[sS]$ ]]; then
  echo "Operação cancelada pelo usuário."
  exit 0
fi

echo "==> Parando container da aplicação (esus-pec) para evitar concorrência..."
docker compose stop esus-pec 2>/dev/null || true

echo "==> Executando restauração com pg_restore..."
docker exec -i esus-db pg_restore -U postgres -d esus --clean --if-exists --no-owner --no-acl -v < "$BACKUP_FILE" || {
  echo "Aviso: pg_restore finalizou com avisos (comum em restores com --clean)."
}

echo "==> Reiniciando aplicação e-SUS PEC..."
docker compose start esus-pec

echo "=========================================================="
echo "Restauração finalizada. Verifique os logs com: docker compose logs -f esus-pec"
echo "=========================================================="
