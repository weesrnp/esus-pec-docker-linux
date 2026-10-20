#!/usr/bin/env bash
# ==============================================================================
# Entrypoint do esus-db: confere as senhas antes de chamar o entrypoint oficial
# da imagem postgres.
# ==============================================================================
# Banco NOVO (volume vazio): recusa senha vazia, curta ou de exemplo. Sem isso,
# o script do usuário de leitura abortaria, mas o volume já ficaria criado: na
# subida seguinte o PostgreSQL estaria no ar com a senha pública.
#
# Banco EXISTENTE: a senha que vale é a gravada dentro do PostgreSQL, não a do
# .env. Recusar aqui travaria quem atualiza o repositório (o trocar-senhas.sh
# precisa do banco no ar). Então só avisa.
# ==============================================================================
set -euo pipefail

PGDATA="${PGDATA:-/var/lib/postgresql/data}"

weak() { [ "${#1}" -lt 16 ] || [[ "$1" == altere_* ]]; }

problems=()
weak "${POSTGRES_PASSWORD:-}" && problems+=("POSTGRES_PASSWORD")
weak "${ESUS_LEITURA_PASSWORD:-}" && problems+=("ESUS_LEITURA_PASSWORD")

if [ "${#problems[@]}" -gt 0 ]; then
  if [ -s "${PGDATA}/PG_VERSION" ]; then
    echo "[esus-db] AVISO: ${problems[*]} fraca ou com o valor de exemplo no .env. Rode ./scripts/trocar-senhas.sh." >&2
  else
    for p in "${problems[@]}"; do
      echo "[esus-db] ERRO: ${p} fraca ou com o valor de exemplo (mínimo 16 caracteres). Rode ./scripts/gerar-env.sh." >&2
    done
    echo "[esus-db] O banco NÃO foi criado." >&2
    exit 1
  fi
fi

exec docker-entrypoint.sh "$@"
