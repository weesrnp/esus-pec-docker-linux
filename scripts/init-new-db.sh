#!/usr/bin/env bash
# ==============================================================================
# e-SUS APS PEC em Docker (Linux) - Inicializador de Nova Base de Dados (Zero)
# ==============================================================================
# Finalidade: Para municípios que estão instalando uma base nova do zero
# (sem backup existente para restaurar). Executa o migrador oficial (Liquibase)
# criando todas as 1.200 tabelas estruturais e sementes do sistema.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_ROOT"

echo "=========================================================="
echo "Inicialização de Nova Base de Dados: e-SUS APS PEC"
echo "Data: $(date)"
echo "Ambiente: Base Zerada (Execução do Migrador Oficial)"
echo "=========================================================="

# 1. Garante que o banco de dados PostgreSQL esteja em execução e pronto
echo "==> Verificando disponibilidade do container esus-db..."
docker compose up -d esus-db

echo "==> Aguardando banco de dados responder..."
until docker exec esus-db pg_isready -U postgres -d esus >/dev/null 2>&1; do
  sleep 2
done
echo "==> PostgreSQL ativo e pronto."

# 2. Executa o migrador oficial Liquibase empacotado na imagem
echo "==> Executando migrações estruturais do e-SUS PEC (migrador.jar)..."
echo "    (Isso pode levar de 2 a 5 minutos na primeira execução)"

docker compose run --rm \
  --entrypoint "java -Xms1024M -Xmx2048M -jar /opt/pec/database/migrador.jar" \
  esus-pec

echo "==> Migração estrutural concluída com sucesso."

# 3. Aplica permissões de segurança para a role esus_leitura (LGPD)
echo "==> Aplicando permissões do usuário de leitura (esus_leitura)..."
docker exec -i esus-db psql -U postgres -d esus < "${PROJECT_ROOT}/sql/01-init-esus-leitura.sql"

# 4. Checagem de integridade e contagem de tabelas criadas
TOTAL_TABLES=$(docker exec -t esus-db psql -U postgres -d esus -t -c "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public';" | tr -d ' \r\n')

echo "=========================================================="
echo "Inicialização concluída com êxito!"
echo "Tabelas criadas no schema public: ${TOTAL_TABLES}"
echo "Agora você pode iniciar a aplicação com: docker compose up -d"
echo "=========================================================="
