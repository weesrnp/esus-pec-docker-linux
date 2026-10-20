#!/usr/bin/env bash
# ==============================================================================
# e-SUS APS PEC em Docker (Linux) - Restauração segura
# ==============================================================================
# Fluxo (o banco em uso só é trocado se tudo der certo):
#   1. valida o arquivo (pg_restore --list e .sha256, se existir);
#   2. restaura num banco temporário;
#   3. confere as tabelas e aplica o usuário de leitura;
#   4. para o PEC e, numa única transação, troca os nomes:
#      atual -> <banco>_antes_<data> (fechado para conexões), temporário -> <banco>;
#   5. roda o migrador oficial (atualiza o schema se o backup for de versão anterior);
#   6. sobe o PEC.
# Se o passo 5 falhar, os nomes voltam ao estado anterior.
#
# Uso: ./scripts/restore.sh [--yes] [--drop-old] <arquivo.backup>
#   --yes       não pergunta (para automação)
#   --drop-old  apaga o banco anterior ao final (padrão: mantém para rollback)
# Espaço necessário: o tamanho do banco restaurado, além do banco atual.
# ==============================================================================
set -euo pipefail
umask 077

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ASSUME_YES=0; DROP_OLD=0; BACKUP_FILE=""
for arg in "$@"; do
  case "$arg" in
    --yes) ASSUME_YES=1 ;;
    --drop-old) DROP_OLD=1 ;;
    -*) die "Opção desconhecida: $arg" ;;
    *) BACKUP_FILE="$arg" ;;
  esac
done
[ -n "$BACKUP_FILE" ] || die "Uso: $0 [--yes] [--drop-old] <arquivo.backup>"

# O lib.sh entra na raiz do projeto: caminhos relativos valem a partir de onde o script foi chamado.
case "$BACKUP_FILE" in
  /*) ;;
  *) BACKUP_FILE="${OLDPWD:-$PWD}/${BACKUP_FILE}" ;;
esac
[ -f "$BACKUP_FILE" ] || die "Arquivo não encontrado: $BACKUP_FILE"

# Também valida as senhas do .env (o usuário de leitura é aplicado no fim do restore).
load_env
container_running "$DB_CONTAINER" || die "Suba o banco antes: docker compose up -d esus-db"
wait_db 120

DB="$POSTGRES_DB"
TS="$(date +%Y%m%d_%H%M%S)"
TMP_DB="${DB}_restore_${TS}"
OLD_DB="${DB}_antes_${TS}"
BACKUP_DIR="${BACKUP_DIR:-${PROJECT_ROOT}/backups}"
mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"
# Pode conter trechos de dados em mensagens de erro: fica com permissão 600 e
# entra na retenção do backup.sh.
LOG_FILE="${BACKUP_DIR}/restore_${TS}.log"

db_exists() {
  [ "$(sql_value postgres "SELECT count(*) FROM pg_database WHERE datname = '$1'")" = "1" ]
}

# ------------------------------------------------------------------------------
# 1. Validação do arquivo
# ------------------------------------------------------------------------------
log "Validando ${BACKUP_FILE}..."
if [ -f "${BACKUP_FILE}.sha256" ]; then
  (cd "$(dirname "$BACKUP_FILE")" && sha256sum -c --quiet "$(basename "$BACKUP_FILE").sha256") \
    || die "Checksum não confere: o arquivo foi alterado ou está incompleto."
  log "Checksum OK."
fi
DUMP_TABLES="$(validate_dump "$BACKUP_FILE")" \
  || die "Arquivo inválido para o pg_restore (não é um dump -Fc ou está corrompido)."
[ "$DUMP_TABLES" -gt 100 ] || die "O backup tem só ${DUMP_TABLES} tabelas; não parece um banco do PEC."
log "Backup válido: ${DUMP_TABLES} tabelas."

DB_EXISTS=0; CUR_TABLES=0
if db_exists "$DB"; then
  DB_EXISTS=1
  CUR_TABLES="$(count_tables "$DB")"
fi

echo "=========================================================="
echo "ATENÇÃO: restauração do banco '${DB}'"
echo "Arquivo: ${BACKUP_FILE}"
[ "$DB_EXISTS" = 1 ] && echo "Banco atual: ${CUR_TABLES} tabelas (será mantido como '${OLD_DB}')"
echo "=========================================================="
if [ "$ASSUME_YES" != 1 ]; then
  read -r -p "Confirmar a restauração? O PEC ficará fora do ar durante a troca. (s/N): " CONFIRM
  [[ "$CONFIRM" =~ ^[sS]$ ]] || { echo "Operação cancelada."; exit 0; }
fi

# ------------------------------------------------------------------------------
# Estado para a limpeza em caso de erro
# ------------------------------------------------------------------------------
STAGE="restaurando"      # restaurando -> trocado -> concluido
PEC_WAS_RUNNING=0

on_exit() {
  local rc=$?
  [ "$rc" -eq 0 ] && return
  case "$STAGE" in
    restaurando)
      # Banco em uso intacto: apaga o temporário e religa o PEC se ele foi parado.
      if db_exists "$TMP_DB"; then
        psql_db postgres -c "DROP DATABASE \"${TMP_DB}\" WITH (FORCE)" >/dev/null 2>&1 \
          || warn "Não consegui apagar o banco temporário ${TMP_DB}; apague manualmente."
      fi
      if [ "$PEC_WAS_RUNNING" = 1 ]; then docker start "$PEC_CONTAINER" >/dev/null 2>&1 || true; fi
      warn "Restauração interrompida. O banco '${DB}' não foi alterado."
      ;;
    trocado)
      # Falha depois da troca e antes do fim: tenta voltar ao banco anterior.
      if swap_back; then
        if [ "$PEC_WAS_RUNNING" = 1 ]; then docker start "$PEC_CONTAINER" >/dev/null 2>&1 || true; fi
        warn "Revertido: '${DB}' voltou a ser o banco anterior. O restaurado ficou em '${TMP_DB}'."
      else
        warn "NÃO consegui reverter a troca. O PEC ficou PARADO de propósito."
        warn "Confira os bancos com: docker exec ${DB_CONTAINER} psql -U ${POSTGRES_USER} -l"
        warn "O banco anterior deve estar em '${OLD_DB}'."
      fi
      ;;
  esac
}
trap on_exit EXIT

# Troca de nomes numa única transação, com o banco fechado para novas conexões
# (um BI com pool de conexões não consegue entrar no meio da troca).
# Fase 1 fecha os bancos (vale após o COMMIT); fase 2 derruba quem ainda está
# conectado, esperando até 10s por sessão, e renomeia.
swap_in() {
  psql_db postgres -f - >/dev/null <<SQL || return 1
$( [ "$DB_EXISTS" = 1 ] && echo "ALTER DATABASE \"${DB}\" WITH ALLOW_CONNECTIONS false;" )
ALTER DATABASE "${TMP_DB}" WITH ALLOW_CONNECTIONS false;
SQL
  if ! psql_db postgres -1 -f - >/dev/null <<SQL
SELECT pg_terminate_backend(pid, 10000) FROM pg_stat_activity
 WHERE datname IN ('${DB}', '${TMP_DB}') AND pid <> pg_backend_pid();
$( [ "$DB_EXISTS" = 1 ] && echo "ALTER DATABASE \"${DB}\" RENAME TO \"${OLD_DB}\";" )
ALTER DATABASE "${TMP_DB}" RENAME TO "${DB}";
ALTER DATABASE "${DB}" WITH ALLOW_CONNECTIONS true;
SQL
  then
    # Desfeito pela transação: reabre o banco em uso para conexões.
    [ "$DB_EXISTS" = 1 ] && psql_db postgres -c "ALTER DATABASE \"${DB}\" WITH ALLOW_CONNECTIONS true" >/dev/null 2>&1
    return 1
  fi
}

swap_back() {
  psql_db postgres -c "ALTER DATABASE \"${DB}\" WITH ALLOW_CONNECTIONS false" >/dev/null 2>&1 || return 1
  psql_db postgres -1 -f - >/dev/null 2>&1 <<SQL
SELECT pg_terminate_backend(pid, 10000) FROM pg_stat_activity
 WHERE datname = '${DB}' AND pid <> pg_backend_pid();
ALTER DATABASE "${DB}" RENAME TO "${TMP_DB}";
$( [ "$DB_EXISTS" = 1 ] && printf '%s\n' "ALTER DATABASE \"${OLD_DB}\" RENAME TO \"${DB}\";" "ALTER DATABASE \"${DB}\" WITH ALLOW_CONNECTIONS true;" )
SQL
}

# ------------------------------------------------------------------------------
# 2. Restauração no banco temporário (o banco em uso não é tocado)
# ------------------------------------------------------------------------------
log "Criando banco temporário ${TMP_DB}..."
psql_db postgres -c "CREATE DATABASE \"${TMP_DB}\" TEMPLATE template0 ENCODING 'UTF8'"

log "Restaurando (log em ${LOG_FILE})..."
set +e
docker exec -i "$DB_CONTAINER" pg_restore -U "$POSTGRES_USER" -d "$TMP_DB" \
  --no-owner --no-acl < "$BACKUP_FILE" > "$LOG_FILE" 2>&1
RC=$?
set -e

# Erros esperados em dumps de PostgreSQL 9.6 restaurados no 16 e que não afetam os dados.
BENIGN='schema "public" already exists|extension "plpgsql" already exists|must be owner of extension plpgsql|must be owner of schema public'
ALL_ERRORS="$(grep -E '^pg_restore: (error|erro)' "$LOG_FILE" | grep -v 'errors ignored on restore' || true)"
REAL_ERRORS="$(printf '%s\n' "$ALL_ERRORS" | grep -vE "$BENIGN" | sed '/^$/d' || true)"
BENIGN_COUNT="$(printf '%s\n' "$ALL_ERRORS" | grep -cE "$BENIGN" || true)"
IGNORED="$(grep -Eo 'errors ignored on restore: [0-9]+' "$LOG_FILE" | grep -Eo '[0-9]+$' || echo 0)"

if [ -n "$REAL_ERRORS" ]; then
  printf '%s\n' "$REAL_ERRORS" | head -20 >&2
  die "pg_restore falhou (código ${RC}). Detalhes: ${LOG_FILE}"
fi
# Só vale código 0, ou 1 com exatamente os erros conhecidos. Qualquer outro
# código (processo morto, falta de memória, daemon reiniciado) é falha, mesmo
# sem linha de erro no log.
if [ "$RC" -ne 0 ] && { [ "$RC" -ne 1 ] || [ "$IGNORED" != "$BENIGN_COUNT" ]; }; then
  die "pg_restore terminou com código ${RC} (erros ignorados: ${IGNORED}, conhecidos: ${BENIGN_COUNT}). Detalhes: ${LOG_FILE}"
fi
[ "$RC" -ne 0 ] && warn "pg_restore registrou ${BENIGN_COUNT} erro(s) conhecido(s) e inofensivo(s) (ver ${LOG_FILE})."

NEW_TABLES="$(count_tables "$TMP_DB")"
[ "$NEW_TABLES" -ge "$DUMP_TABLES" ] || die "Restauradas ${NEW_TABLES} de ${DUMP_TABLES} tabelas."
log "Restauração OK: ${NEW_TABLES} tabelas."

log "Aplicando usuário de leitura no banco restaurado..."
apply_leitura "$TMP_DB" >/dev/null

# ------------------------------------------------------------------------------
# 3. Troca dos bancos (PEC parado)
# ------------------------------------------------------------------------------
if container_running "$PEC_CONTAINER"; then
  PEC_WAS_RUNNING=1
  log "Parando o PEC..."
  docker stop -t 60 "$PEC_CONTAINER" >/dev/null
fi

log "Trocando bancos: ${DB} -> ${OLD_DB}, ${TMP_DB} -> ${DB}..."
swap_in || die "Falha na troca de nomes (nada foi trocado: a transação foi desfeita)."
STAGE="trocado"

# ------------------------------------------------------------------------------
# 4. Migrador oficial: deixa o schema na versão da imagem atual
# ------------------------------------------------------------------------------
run_migrador "$DB" || die "O migrador falhou no banco restaurado."
apply_leitura "$DB" >/dev/null
STAGE="concluido"

# ------------------------------------------------------------------------------
# 5. Sobe o PEC
# ------------------------------------------------------------------------------
if container_exists "$PEC_CONTAINER"; then
  log "Iniciando o PEC..."
  docker start "$PEC_CONTAINER" >/dev/null
else
  log "Container do PEC ainda não existe. Suba com: docker compose up -d"
fi

if [ "$DB_EXISTS" = 1 ]; then
  if [ "$DROP_OLD" = 1 ]; then
    psql_db postgres -c "DROP DATABASE \"${OLD_DB}\"" >/dev/null
    log "Banco anterior ${OLD_DB} apagado (--drop-old)."
  else
    # O banco anterior fica fechado para conexões: o usuário de leitura (BI)
    # não enxerga essa cópia antiga dos dados.
    log "Banco anterior mantido como '${OLD_DB}' (fechado para conexões). Depois de conferir o PEC, apague com:"
    echo "    docker exec ${DB_CONTAINER} dropdb -U ${POSTGRES_USER} ${OLD_DB}"
  fi
fi

echo "=========================================================="
echo "Restauração concluída. Acompanhe: docker compose logs -f esus-pec"
echo "=========================================================="
