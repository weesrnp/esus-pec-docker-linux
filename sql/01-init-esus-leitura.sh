#!/usr/bin/env bash
# Executado pelo entrypoint oficial do postgres na primeira inicialização do
# volume (docker-entrypoint-initdb.d). Cria o usuário de leitura com a senha
# do .env. Em bancos já existentes, os scripts init-new-db.sh e restore.sh
# reaplicam o mesmo SQL.
set -euo pipefail

psql -v ON_ERROR_STOP=1 \
  --username "$POSTGRES_USER" \
  --dbname "$POSTGRES_DB" \
  -f /esus-sql/esus-leitura.sql
