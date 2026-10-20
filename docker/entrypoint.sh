#!/usr/bin/env bash
# ==============================================================================
# e-SUS APS PEC em Docker (Linux) - Entrypoint de Produção
# ==============================================================================
set -e

cd /opt/pec/webserver

echo "=========================================================="
echo "Iniciando e-SUS APS PEC em Docker (Linux)"
echo "Fuso Horário: ${TZ:-America/Sao_Paulo}"
echo "Heap Máximo: ${PEC_HEAP:-4096M}"
echo "=========================================================="

# ------------------------------------------------------------------------------
# 1. Configurações de Memória e Profiling da JVM
# ------------------------------------------------------------------------------
export JAVA_OPTS="-Xms2048M -Xmx${PEC_HEAP:-4096M} \
  -XX:MetaspaceSize=256M -XX:MaxMetaspaceSize=512M \
  -XX:ReservedCodeCacheSize=512M \
  -Djava.net.preferIPv4Stack=true \
  -Dfile.encoding=UTF-8 \
  -Djava.awt.headless=true \
  -XX:+UseG1GC \
  -XX:+ExplicitGCInvokesConcurrent"

# ------------------------------------------------------------------------------
# 2. Aguardar Prontidão do Banco de Dados PostgreSQL
# ------------------------------------------------------------------------------
if [ -n "$DB_HOST" ]; then
  echo "==> Aguardando disponibilidade do PostgreSQL em ${DB_HOST}:${DB_PORT:-5432}..."
  until pg_isready -h "$DB_HOST" -p "${DB_PORT:-5432}" -U "${DB_USER:-postgres}" -d "${DB_NAME:-esus}" > /dev/null 2>&1; do
    echo "    Aguardando banco de dados responder..."
    sleep 3
  done
  echo "==> Banco de dados PostgreSQL online e pronto."
fi

# ------------------------------------------------------------------------------
# 3. Gestão e Renovação de Certificado SSL / HTTPS
# ------------------------------------------------------------------------------
if [ "${PEC_SSL:-0}" = "1" ]; then
  echo "==> Modo SSL ativado (PEC_SSL=1). Verificando certificados..."
  if [ -f "certmgr/config/ssl.properties" ]; then
    export SPRING_CONFIG_ADDITIONAL_LOCATION="$PWD/certmgr/config/ssl.properties"
    (cd certmgr && java -jar certmgr.jar --renew) || echo "Aviso: certmgr --renew retornou código diferente de zero (prosseguindo inicialização)."
  elif [ -f "certmgr.jar" ]; then
    java -jar certmgr.jar --renew || echo "Aviso: certmgr.jar renovação concluída."
  fi
else
  echo "==> Modo HTTP padrão (porta 8080). SSL desativado no container."
fi

# ------------------------------------------------------------------------------
# 4. Inicialização do Monolito Spring Boot (pec-bundle.jar)
# ------------------------------------------------------------------------------
echo "==> Executando pec-bundle.jar..."
exec java $JAVA_OPTS -jar pec-bundle.jar
