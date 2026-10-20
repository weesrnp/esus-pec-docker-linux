#!/usr/bin/env bash
# shellcheck disable=SC2012
# ==============================================================================
# Roda tests/e2e.sh num Docker-in-Docker descartável (Linux de verdade, sem
# tocar nos containers do host). Precisa do instalador em instalador/.
#
# Uso: tests/run-dind.sh [arquivo-de-log]
# Requer ~6 GB de RAM livres no Docker e uns 8 GB de disco.
# ==============================================================================
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
LOG="${1:-tests/e2e-$(date +%Y%m%d_%H%M%S).log}"
NAME="esus-e2e-dind"
JAR="$(ls instalador/eSUS-AB-PEC-*-Linux64.jar 2>/dev/null | head -n 1)"
[ -n "$JAR" ] || { echo "Coloque o eSUS-AB-PEC-*-Linux64.jar em instalador/."; exit 1; }

docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --privileged --name "$NAME" -e DOCKER_TLS_CERTDIR= docker:29-dind >/dev/null
trap 'docker rm -f "$NAME" >/dev/null 2>&1 || true' EXIT

echo "==> Preparando o ambiente de teste..."
docker exec "$NAME" sh -c 'until docker info >/dev/null 2>&1; do sleep 1; done'
docker exec "$NAME" apk add --no-cache -q bash coreutils findutils util-linux procps unzip curl git sudo
# Operador comum com acesso ao Docker, como num servidor real
docker exec "$NAME" sh -c 'adduser -D operador && addgroup operador wheel && chmod 666 /var/run/docker.sock \
  && echo "operador ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/operador && mkdir -p /proj && chown operador /proj'

# Só os arquivos do projeto (versionados ou novos), mais o instalador
{ git ls-files -co --exclude-standard; echo "$JAR"; } | grep -v '^_dossie_interno/' \
  | tar -cf - -T - | docker exec -i "$NAME" su operador -c 'tar -xf - -C /proj'

echo "==> Executando tests/e2e.sh (pode levar 40 minutos). Log: ${LOG}"
set +e
docker exec "$NAME" su operador -c 'cd /proj && bash tests/e2e.sh' 2>&1 | tee "$LOG"
RC=${PIPESTATUS[0]}
exit "$RC"
