#!/usr/bin/env bash
# ==============================================================================
# Entrypoint do esus-db: confere as senhas antes de chamar o entrypoint oficial
# da imagem postgres.
# ==============================================================================
# O ":?" do compose só barra senha vazia. Se o banco fosse criado com a senha de
# exemplo, o script do usuário de leitura abortaria, mas o volume já estaria
# inicializado: na subida seguinte o PostgreSQL ficaria no ar com a senha pública
# e sem o esus_leitura. Por isso a checagem acontece antes de qualquer initdb.
# ==============================================================================
set -euo pipefail

weak() { [ "${#1}" -lt 16 ] || [[ "$1" == altere_* ]]; }

if weak "${POSTGRES_PASSWORD:-}"; then
  echo "[esus-db] ERRO: POSTGRES_PASSWORD fraca ou com o valor de exemplo. Rode ./scripts/gerar-env.sh ou ./scripts/trocar-senhas.sh." >&2
  exit 1
fi
if weak "${ESUS_LEITURA_PASSWORD:-}"; then
  echo "[esus-db] ERRO: ESUS_LEITURA_PASSWORD fraca ou com o valor de exemplo. Rode ./scripts/gerar-env.sh ou ./scripts/trocar-senhas.sh." >&2
  exit 1
fi

exec docker-entrypoint.sh "$@"
