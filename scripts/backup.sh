#!/usr/bin/env bash
# ==============================================================================
# e-SUS APS PEC em Docker (Linux) - Backup do banco e das chaves
# ==============================================================================
# Gera em BACKUP_DIR (padrão ./backups), com permissão 600:
#   esus_<banco>_<data>.backup         dump -Fc validado com pg_restore --list
#   esus_<banco>_<data>.backup.sha256  checksum do dump
#   esus_config_<data>.tar.gz          config, chaves RNDS e certificados do PEC
# Depois apaga arquivos com mais de RETENTION_DAYS dias (padrão 30).
#
# Funciona de qualquer diretório (inclusive pelo cron). Não use "docker exec -t":
# o TTY converte \n em \r\n e mistura mensagens no dump, que fica irrecuperável.
# ==============================================================================
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_env

BACKUP_DIR="${BACKUP_DIR:-${PROJECT_ROOT}/backups}"
RETENTION_DAYS="${RETENTION_DAYS:-30}"
[[ "$RETENTION_DAYS" =~ ^[0-9]+$ ]] || die "RETENTION_DAYS inválido: ${RETENTION_DAYS}"

umask 077
mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

# Um backup por vez (cron + execução manual ao mesmo tempo).
exec 9> "${BACKUP_DIR}/.backup.lock"
flock -n 9 || die "Outro backup já está em andamento."

container_running "$DB_CONTAINER" || die "O container ${DB_CONTAINER} não está rodando."

TS="$(date +%Y%m%d_%H%M%S)"
DUMP="${BACKUP_DIR}/esus_${POSTGRES_DB}_${TS}.backup"
TMP="${DUMP}.part"
CFG="${BACKUP_DIR}/esus_config_${TS}.tar.gz"
trap 'rm -f "$TMP" "${CFG}.part"' EXIT

echo "=========================================================="
echo "Backup do e-SUS PEC - $(date '+%d/%m/%Y %H:%M:%S')"
echo "Banco: ${POSTGRES_DB} | Destino: ${BACKUP_DIR}"
echo "=========================================================="

# Espaço livre: o dump -Fc costuma ter de 10% a 20% do tamanho do banco.
DB_BYTES="$(sql_value postgres "SELECT pg_database_size('${POSTGRES_DB}')")"
FREE_BYTES="$(( $(df -Pk "$BACKUP_DIR" | awk 'NR==2 {print $4}') * 1024 ))"
if [ "$FREE_BYTES" -lt "$(( DB_BYTES / 2 ))" ]; then
  die "Pouco espaço em ${BACKUP_DIR}: $((FREE_BYTES / 1048576)) MB livres para um banco de $((DB_BYTES / 1048576)) MB."
fi

# 1. Dump do banco
log "Gerando dump (banco com $((DB_BYTES / 1048576)) MB)..."
docker exec "$DB_CONTAINER" pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc -Z 6 > "$TMP"

# 2. Validação: o arquivo precisa ser legível pelo pg_restore
TABLES="$(validate_dump "$TMP")" || die "O dump gerado não é válido (pg_restore --list falhou)."
[ "$TABLES" -gt 0 ] || die "O dump não contém tabelas do schema public."
mv "$TMP" "$DUMP"
(cd "$BACKUP_DIR" && sha256sum "$(basename "$DUMP")" > "$(basename "$DUMP").sha256")
log "Dump OK: $(basename "$DUMP") ($(du -h "$DUMP" | cut -f1), ${TABLES} tabelas)"

# 3. Configuração, chaves RNDS e certificados. São lidos de dentro de um
#    container (root lá dentro), porque no host os arquivos pertencem ao uid 10001
#    com permissão 700. Com o PEC parado, usa um container temporário da imagem.
CFG_OK=0
TAR_ARGS=(-czf - -C /opt/pec/webserver config chaves certmgr/config)
if container_running "$PEC_CONTAINER"; then
  docker exec "$PEC_CONTAINER" tar "${TAR_ARGS[@]}" > "${CFG}.part" && CFG_OK=1
else
  docker compose run --rm --no-deps -T --entrypoint tar esus-pec "${TAR_ARGS[@]}" > "${CFG}.part" 2>/dev/null && CFG_OK=1
fi
if [ "$CFG_OK" = 1 ]; then
  mv "${CFG}.part" "$CFG"
  log "Configuração e chaves: $(basename "$CFG") ($(du -h "$CFG" | cut -f1))"
else
  warn "Falha ao copiar config/chaves RNDS/certificados. O dump do banco foi salvo."
fi

# 4. Retenção (só depois de um backup bem-sucedido)
DELETED="$(find "$BACKUP_DIR" -maxdepth 1 -type f \
  \( -name 'esus_*.backup' -o -name 'esus_*.backup.sha256' -o -name 'esus_config_*.tar.gz' -o -name 'restore_*.log' \) \
  -mtime +"$RETENTION_DAYS" -print -delete | wc -l)"
if [ "$DELETED" -gt 0 ]; then
  log "Retenção: ${DELETED} arquivo(s) com mais de ${RETENTION_DAYS} dias removido(s)."
fi

# Log do cron: mantém as últimas 5.000 linhas quando passa de 5 MB.
CRON_LOG="${BACKUP_DIR}/cron_backup.log"
if [ -f "$CRON_LOG" ] && [ "$(stat -c %s "$CRON_LOG")" -gt 5242880 ]; then
  tail -n 5000 "$CRON_LOG" > "${CRON_LOG}.tmp" && mv "${CRON_LOG}.tmp" "$CRON_LOG"
fi

# Sem as chaves o backup está incompleto: o cron precisa registrar falha.
[ "$CFG_OK" = 1 ] || die "Backup incompleto: banco salvo, mas config/chaves não."

log "Backup concluído. Copie a pasta ${BACKUP_DIR} para outro equipamento (disco externo, NAS ou nuvem da prefeitura)."
