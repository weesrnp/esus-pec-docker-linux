#!/usr/bin/env bash
# Arquivo de teste: funções chamadas via check/bash -c e aspas simples intencionais.
# shellcheck disable=SC2317,SC2012,SC2016,SC2069
# ==============================================================================
# Teste ponta a ponta da stack (instalação, migração, backup, restore, senhas,
# atualização). DESTRUTIVO: cria e apaga os containers esus-db/esus-pec e o
# diretório volumes/. Rode só num ambiente descartável (tests/run-dind.sh).
#
# Uso: tests/e2e.sh   (na raiz do projeto, com o instalador PEC_JAR na raiz)
# Saída: tabela de resultados; código = número de falhas.
# ==============================================================================
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
ROOT="$PWD"
PASS=0; FAIL=0; RESULTS=()

ok()   { PASS=$((PASS + 1)); RESULTS+=("PASSOU | $1"); echo "  [PASSOU] $1"; }
bad()  { FAIL=$((FAIL + 1)); RESULTS+=("FALHOU | $1"); echo "  [FALHOU] $1"; }
check(){ local name="$1"; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }
step() { echo; echo "######## $* ($(date +%T))"; }
envv() { grep -E "^$1=" .env | cut -d= -f2-; }
psqlq(){ docker exec esus-db psql -U postgres -d "${2:-esus}" -tAc "$1" | tr -d '\r'; }
leitura_err() { # stderr de comandos do esus_leitura (um -c por argumento)
  local pw="$1"; shift
  local args=(); for c in "$@"; do args+=(-c "$c"); done
  docker exec -e PGPASSWORD="$pw" esus-db psql -v ON_ERROR_STOP=1 -h 127.0.0.1 -U esus_leitura -d esus "${args[@]}" 2>&1 >/dev/null
}
expect_denied() { # $1 = nome do teste; demais = como em leitura_err
  local name="$1" out; shift
  # Sem pipe: com pipefail, o código 1 do psql (o erro esperado) faria o teste falhar.
  out="$(leitura_err "$@")"
  if grep -q 'permission denied' <<< "$out"; then ok "$name"; else bad "$name"; echo "    saída: ${out}"; fi
}
leitura_q() {
  docker exec -e PGPASSWORD="$1" esus-db psql -h 127.0.0.1 -U esus_leitura -d esus -tAc "$2" 2>/dev/null | tr -d '\r'
}
wait_healthy() {
  local c="$1" max="${2:-600}" t=0 s
  while [ "$t" -lt "$max" ]; do
    s="$(docker inspect -f '{{.State.Health.Status}}' "$c" 2>/dev/null)"
    [ "$s" = "healthy" ] && return 0
    sleep 5; t=$((t + 5))
  done
  docker logs --tail 40 "$c" 2>&1 | cut -c1-300
  return 1
}
api_version() { curl -fsS http://127.0.0.1:8080/api/public/info | grep -o '"versao":"[^"]*"' | cut -d'"' -f4; }

JAR="$(cd instalador 2>/dev/null && ls eSUS-AB-PEC-*-Linux64.jar 2>/dev/null | head -n 1)"
[ -n "$JAR" ] || { echo "Instalador eSUS-AB-PEC-*-Linux64.jar não está em instalador/"; exit 99; }
VERSION="$(echo "$JAR" | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+')"

step "0. Limpeza"
docker rm -f esus-pec esus-db >/dev/null 2>&1
rm -rf volumes backups .env .env.bak-* 2>/dev/null || sudo rm -rf volumes backups

step "1. gerar-env.sh"
check "gerar-env cria .env" ./scripts/gerar-env.sh
check ".env com permissão 600" test "$(stat -c %a .env)" = "600"
check "senha do postgres aleatória (48 hex)" grep -Eq '^POSTGRES_PASSWORD=[0-9a-f]{48}$' .env
check "senha de leitura aleatória (48 hex)" grep -Eq '^ESUS_LEITURA_PASSWORD=[0-9a-f]{48}$' .env
check "senhas diferentes entre si" test "$(envv POSTGRES_PASSWORD)" != "$(envv ESUS_LEITURA_PASSWORD)"
check "gerar-env recusa sobrescrever sem --force" bash -c '! ./scripts/gerar-env.sh 2>/dev/null'
# Ambiente de teste com pouca memória
sed -i -e "s/^PEC_JAR_FILE=.*/PEC_JAR_FILE=${JAR}/" -e "s/^PEC_IMAGE_TAG=.*/PEC_IMAGE_TAG=${VERSION}/" \
       -e 's/^PEC_HEAP=.*/PEC_HEAP=3072M/' -e 's/^PG_SHARED_BUFFERS=.*/PG_SHARED_BUFFERS=1GB/' \
       -e 's/^PG_EFFECTIVE_CACHE_SIZE=.*/PG_EFFECTIVE_CACHE_SIZE=3GB/' .env
PG_PASS="$(envv POSTGRES_PASSWORD)"; RO_PASS="$(envv ESUS_LEITURA_PASSWORD)"

step "2. Senhas obrigatórias e fortes"
mv .env .env.tmp
check "compose sem .env falha (senha obrigatória)" bash -c '! docker compose config -q 2>/dev/null'
cp .env.example .env
docker compose up -d esus-db >/dev/null 2>&1
sleep 10
check "banco recusa subir com a senha de exemplo" bash -c 'docker logs esus-db 2>&1 | grep -q "POSTGRES_PASSWORD fraca"'
check "volume do banco não foi inicializado com a senha de exemplo" bash -c '! sudo test -f volumes/pg_data/PG_VERSION'
check "scripts recusam .env com a senha de exemplo" bash -c '! ./scripts/backup.sh >/dev/null 2>&1'
docker rm -f esus-db >/dev/null 2>&1; sudo rm -rf volumes
mv .env.tmp .env
cp .env .env.antes-teste
echo 'PEC_JAVA_OPTS_EXTRA=-Xss1m # comentario no fim da linha' >> .env
check "lib.sh lê .env como o compose (comentário no fim da linha)"   bash -c 'source scripts/lib.sh; load_env; [ "$PEC_HEAP" = "3072M" ] && [ "$PEC_JAVA_OPTS_EXTRA" = "-Xss1m" ]'
check "compose lê o mesmo valor"   bash -c 'docker compose config | grep -E "^ +PEC_JAVA_OPTS_EXTRA: -Xss1m$" >/dev/null'
mv .env.antes-teste .env

step "3. doctor.sh"
./scripts/doctor.sh; echo "(doctor saiu com $?)"

step "4. Build"
T0=$(date +%s)
check "docker compose build" docker compose build esus-pec
echo "  build: $(( $(date +%s) - T0 ))s"
IMG="esus-pec-docker:${VERSION}"
SIZE_MB=$(( $(docker image inspect -f '{{.Size}}' "$IMG") / 1048576 ))
echo "  imagem: ${SIZE_MB} MB"
echo "  (tamanho só informativo: os jars oficiais somam ~640 MB)"
check "imagem sem application.properties template" bash -c "! docker run --rm --entrypoint test $IMG -e /opt/pec/webserver/application.properties"
check "certmgr.jar em webserver/certmgr/" docker run --rm --entrypoint test "$IMG" -f /opt/pec/webserver/certmgr/certmgr.jar
check "imagem sem instalador do PostgreSQL 9.6" bash -c "! docker run --rm --entrypoint sh $IMG -c 'ls /opt/pec/database/*.run' 2>/dev/null"

step "5. Banco novo (init-new-db.sh)"
T0=$(date +%s)
check "init-new-db.sh" ./scripts/init-new-db.sh
echo "  migração: $(( $(date +%s) - T0 ))s"
TABLES="$(psqlq "select count(*) from pg_tables where schemaname='public'")"
check "migrador criou >= 1000 tabelas (${TABLES})" test "${TABLES:-0}" -ge 1000
check "init-new-db recusa rodar de novo em banco cheio" bash -c '! ./scripts/init-new-db.sh >/dev/null 2>&1'

step "6. Banco: segurança e locale"
check "password_encryption scram-sha-256" test "$(psqlq 'show password_encryption')" = "scram-sha-256"
check "senha do postgres gravada em SCRAM" test "$(psqlq "select left(rolpassword,13) from pg_authid where rolname='postgres'")" = "SCRAM-SHA-256"
check "datestyle ISO, DMY" test "$(psqlq 'show datestyle')" = "ISO, DMY"
check "busca textual em português" test "$(psqlq 'show default_text_search_config')" = "pg_catalog.portuguese"
check "ordenação pt-BR (Álvaro,ana,Beatriz,Zélia)" \
  test "$(psqlq "select string_agg(n, ',' order by n) from (values ('Zélia'),('Álvaro'),('ana'),('Beatriz')) v(n)")" = "Álvaro,ana,Beatriz,Zélia"
check "data dd/mm aceita" test "$(psqlq "select '20/10/2026'::date")" = "2026-10-20"
check "leitura entra com a senha do .env" test "$(leitura_q "$RO_PASS" 'select current_user')" = "esus_leitura"
check "leitura recusa a senha antiga fixa do repositório" test -z "$(leitura_q esus_leitura_segura_2026 'select 1')"
check "leitura lê todas as tabelas" test "$(psqlq "select count(*) from pg_tables where schemaname='public' and not has_table_privilege('esus_leitura', schemaname||'.'||tablename, 'SELECT')")" = "0"
expect_denied "leitura não cria tabela, mesmo desligando read_only" \
  "$RO_PASS" 'set default_transaction_read_only=off' 'create table public.x_teste(i int)'
expect_denied "leitura não altera dados, mesmo desligando read_only" \
  "$RO_PASS" 'set default_transaction_read_only=off' 'delete from tb_config_sistema'
check "dados intactos" test "$(psqlq 'select count(*) > 0 from tb_config_sistema')" = "t"
# Banco vindo do PostgreSQL 9.6 dá CREATE em public para todos: o SQL precisa tirar.
psqlq "grant create on schema public to public" >/dev/null
docker exec -i -e ESUS_LEITURA_PASSWORD="$RO_PASS" esus-db \
  psql -v ON_ERROR_STOP=1 -X -q -U postgres -d esus -f - < sql/esus-leitura.sql >/dev/null
expect_denied "REVOKE CREATE em public (banco no estilo 9.6)" \
  "$RO_PASS" 'set default_transaction_read_only=off' 'create table public.x_teste(i int)'
check "leitura com limite de 5 conexões" test "$(psqlq "select rolconnlimit from pg_roles where rolname='esus_leitura'")" = "5"
check "porta do banco só no loopback" bash -c "docker port esus-db 5432 | grep -q '^127.0.0.1:'"

step "7. PEC"
docker compose up -d
check "PEC healthy" wait_healthy esus-pec 900
check "API informa a versão ${VERSION}" test "$(api_version)" = "$VERSION"
JAVA_PID_UID='for p in /proc/[0-9]*; do grep -qa pec-bundle "$p/cmdline" 2>/dev/null && stat -c %u "$p"; done'
check "JVM roda como usuário pec (uid 10001)" bash -c "docker exec esus-pec sh -c '$JAVA_PID_UID' | sort -u | grep -qx 10001"
check "volumes do PEC com dono 10001" test "$(stat -c %u volumes/pec_config)" = "10001"
check "ulimit nofile 500000" test "$(docker exec esus-pec sh -c 'ulimit -n')" = "500000"
check "PEC sem erro de permissão no log" \
  bash -c '[ "$(docker logs esus-pec 2>&1 | grep -ciE "permission denied|AccessDeniedException")" = 0 ]'
check "pec-bundle.jar pertence ao root (a JVM não troca o binário)" \
  test "$(docker exec esus-pec stat -c %u /opt/pec/webserver/pec-bundle.jar)" = "0"
check "pasta das chaves RNDS com permissão 700" test "$(stat -c %a volumes/pec_chaves)" = "700"
check "rotação de log configurada" test "$(docker inspect -f '{{index .HostConfig.LogConfig.Config "max-size"}}' esus-pec)" = "50m"

step "8. Rebuild com a stack de pé (antes falhava sem sudo por causa do pg_data)"
check "rebuild sem erro de contexto" docker compose build esus-pec

step "9. Backup (rodado de outro diretório, como o cron)"
(cd /tmp && "${ROOT}/scripts/backup.sh"); RC=$?
check "backup.sh saiu com 0" test "$RC" = 0
DUMP="$(ls -t backups/esus_esus_*.backup 2>/dev/null | head -n 1)"
check "dump criado em backups/ da raiz do projeto" test -n "$DUMP"
check "dump com permissão 600" test "$(stat -c %a "$DUMP")" = "600"
check "dump legível pelo pg_restore" bash -c "docker exec -i esus-db pg_restore --list < '$DUMP' >/dev/null"
check "checksum do dump confere" bash -c "cd backups && sha256sum -c --quiet '$(basename "$DUMP").sha256'"
check "backup da config/chaves criado" bash -c 'ls backups/esus_config_*.tar.gz >/dev/null 2>&1'
check "nenhum arquivo .part esquecido" bash -c '! ls backups/*.part >/dev/null 2>&1'
touch -d '40 days ago' backups/esus_esus_19990101_000000.backup
./scripts/backup.sh >/dev/null 2>&1
check "retenção apagou backup de 40 dias" test ! -f backups/esus_esus_19990101_000000.backup

step "10. Restore de backup corrompido (deve falhar sem tocar no banco)"
docker exec -t esus-db pg_dump -U postgres -d esus -Fc -v > /tmp/corrompido.backup 2>/dev/null
BEFORE="$(psqlq "select count(*) from pg_database")"
check "restore recusa backup corrompido" bash -c '! ./scripts/restore.sh --yes /tmp/corrompido.backup >/dev/null 2>&1'
check "nenhum banco novo criado pelo restore falho" test "$(psqlq "select count(*) from pg_database")" = "$BEFORE"
check "PEC continua no ar" test "$(docker inspect -f '{{.State.Running}}' esus-pec)" = "true"

step "11. Restore válido"
psqlq "create table public.marcador_pre_restore(i int)" >/dev/null
check "restore.sh --yes" ./scripts/restore.sh --yes "$DUMP"
check "marcador criado depois do backup sumiu" test -z "$(psqlq "select 1 from pg_tables where tablename='marcador_pre_restore'")"
check "banco anterior preservado para rollback" test -n "$(psqlq "select datname from pg_database where datname like 'esus_antes_%'")"
check "banco anterior fechado para conexões" \
  test "$(psqlq "select bool_and(not datallowconn) from pg_database where datname like 'esus_antes_%'")" = "t"
check "nenhum banco temporário esquecido" \
  test -z "$(psqlq "select datname from pg_database where datname like 'esus_restore_%'")"
check "leitura lê tudo após restore" test "$(psqlq "select count(*) from pg_tables where schemaname='public' and not has_table_privilege('esus_leitura', schemaname||'.'||tablename, 'SELECT')")" = "0"
check "PEC healthy após restore" wait_healthy esus-pec 900
check "PEC responde após restore" test "$(api_version)" = "$VERSION"

step "12. Cron (como root: o crontab do busybox deste ambiente de teste exige suid)"
if command -v crontab >/dev/null 2>&1; then
  check "setup-cron-backup instala" sudo ./scripts/setup-cron-backup.sh
  check "agendamento único (idempotente)" \
    bash -c 'sudo ./scripts/setup-cron-backup.sh >/dev/null && [ "$(sudo crontab -l | grep -c ESUS_PEC_DOCKER_BACKUP_JOB)" = 1 ]'
  check "linha do cron aponta para o backup.sh do projeto" \
    bash -c "sudo crontab -l | grep ESUS_PEC_DOCKER_BACKUP_JOB | grep -qF '${ROOT}/scripts/backup.sh'"
  check "remove agendamento" \
    bash -c 'sudo ./scripts/setup-cron-backup.sh --remove >/dev/null && ! sudo crontab -l 2>/dev/null | grep -q ESUS_PEC_DOCKER_BACKUP_JOB'
fi

step "13. Troca de senhas"
check "trocar-senhas.sh --yes" ./scripts/trocar-senhas.sh --yes
NEW_PG="$(envv POSTGRES_PASSWORD)"; NEW_RO="$(envv ESUS_LEITURA_PASSWORD)"
check "senha do postgres mudou no .env" test "$NEW_PG" != "$PG_PASS"
check "senha de leitura mudou no .env" test "$NEW_RO" != "$RO_PASS"
check "leitura entra com a senha nova" test "$(leitura_q "$NEW_RO" 'select 1')" = "1"
check "leitura recusa a senha antiga" test -z "$(leitura_q "$RO_PASS" 'select 1')"
check "postgres entra pela rede com a senha nova" bash -c "docker exec -e PGPASSWORD='$NEW_PG' esus-db psql -h 127.0.0.1 -U postgres -d esus -tAc 'select 1' | grep -qx 1"
check "container do PEC recebeu a senha nova" test "$(docker exec esus-pec printenv SPRING_DATASOURCE_PASSWORD)" = "$NEW_PG"
docker restart esus-pec >/dev/null
check "PEC healthy depois de reiniciar com a senha nova" wait_healthy esus-pec 900
check "cópia do .env antigo com permissão 600" bash -c 'for f in .env.bak-*; do [ "$(stat -c %a "$f")" = 600 ] || exit 1; done'

step "14. Atualização (mesma versão: exercita backup, build, migrador e subida)"
check "atualizar-pec.sh" ./scripts/atualizar-pec.sh "instalador/$JAR"
check "PEC na versão ${VERSION} após atualizar" test "$(api_version)" = "$VERSION"
check "PEC_JAR_SHA256 gravado no .env" grep -Eq '^PEC_JAR_SHA256=[0-9a-f]{64}$' .env

step "15. Instalador inválido"
echo "<html>nao sou um jar</html>" > instalador/eSUS-AB-PEC-0.0.0-Linux64.jar
check "build recusa instalador falso" bash -c '! PEC_JAR_FILE=eSUS-AB-PEC-0.0.0-Linux64.jar PEC_IMAGE_TAG=falso docker compose build esus-pec >/dev/null 2>&1'
rm -f instalador/eSUS-AB-PEC-0.0.0-Linux64.jar

step "16. get-latest-pec.sh (consulta ao portal oficial)"
if ./scripts/get-latest-pec.sh; then ok "localiza a versão mais recente no SISAPS"; else bad "localiza a versão mais recente no SISAPS"; fi

echo
echo "=================== RESULTADO ==================="
printf '%s\n' "${RESULTS[@]}"
echo "================================================="
echo "Passaram: ${PASS} | Falharam: ${FAIL}"
exit "$FAIL"
