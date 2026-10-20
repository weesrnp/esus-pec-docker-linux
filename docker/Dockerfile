# ==============================================================================
# e-SUS APS PEC em Docker (Linux)
# ==============================================================================
# Build multi-stage: extrai do instalador oficial só o que roda em produção
# (pec-bundle.jar, certmgr.jar e migrador.jar) e monta uma imagem Temurin 17.
#
# O contexto de build é filtrado pelo .dockerignore (só instalador/ e o entrypoint).
# O instalador entra por bind mount e não fica em nenhuma camada da imagem.
# ==============================================================================

# ------------------------------------------------------------------------------
# Estágio 1: extração dos artefatos do instalador
# ------------------------------------------------------------------------------
FROM alpine:3.20 AS builder

SHELL ["/bin/ash", "-eo", "pipefail", "-c"]

# Até 5 tentativas: o CDN do Alpine às vezes responde 503 por alguns minutos.
# hadolint ignore=DL3018
RUN for i in 1 2 3 4 5; do \
        apk add --no-cache unzip curl && exit 0; \
        echo "apk falhou (tentativa $i), nova tentativa em 15s..." >&2; sleep 15; \
    done; \
    exit 1

# PEC_JAR: nome do instalador dentro de instalador/ (ex.: eSUS-AB-PEC-5.5.28-Linux64.jar)
# DOWNLOAD_URL: alternativa ao arquivo local (URL oficial em arquivos.esusaps.ufsc.br)
# PEC_JAR_SHA256: opcional; se informado, o instalador é conferido antes de extrair
ARG PEC_JAR=""
ARG DOWNLOAD_URL=""
ARG PEC_JAR_SHA256=""

WORKDIR /build

RUN --mount=type=bind,source=.,target=/src,ro \
    if [ -n "${PEC_JAR}" ]; then \
        INSTALLER="/src/instalador/${PEC_JAR}"; \
        if [ ! -f "${INSTALLER}" ]; then \
            echo "ERRO: PEC_JAR_FILE=${PEC_JAR} não está na pasta instalador/." >&2; \
            exit 1; \
        fi; \
    elif [ -n "${DOWNLOAD_URL}" ]; then \
        echo "==> Baixando instalador: ${DOWNLOAD_URL}"; \
        curl -fL --retry 3 -o /tmp/installer.jar "${DOWNLOAD_URL}"; \
        INSTALLER=/tmp/installer.jar; \
    else \
        COUNT=$(find /src/instalador -maxdepth 1 -name 'eSUS-AB-PEC-*-Linux64.jar' 2>/dev/null | wc -l); \
        if [ "$COUNT" -ne 1 ]; then \
            echo "ERRO: esperado exatamente 1 eSUS-AB-PEC-*-Linux64.jar em instalador/ (encontrados: $COUNT)." >&2; \
            echo "Defina PEC_JAR_FILE no .env ou DOWNLOAD_URL no build." >&2; \
            exit 1; \
        fi; \
        INSTALLER=$(find /src/instalador -maxdepth 1 -name 'eSUS-AB-PEC-*-Linux64.jar'); \
    fi; \
    echo "==> Instalador: ${INSTALLER}"; \
    if [ -n "${PEC_JAR_SHA256}" ]; then \
        echo "${PEC_JAR_SHA256}  ${INSTALLER}" | sha256sum -c -; \
    fi; \
    if ! unzip -l "${INSTALLER}" container/webserver/pec-bundle.jar >/dev/null 2>&1; then \
        echo "ERRO: ${INSTALLER} não é um instalador válido do PEC (zip sem container/webserver/pec-bundle.jar)." >&2; \
        exit 1; \
    fi; \
    unzip -q "${INSTALLER}" 'container/webserver/*' container/database/migrador.jar -d /build; \
    rm -f /tmp/installer.jar; \
    W=/build/container/webserver; \
    # O application.properties do pacote é um template com placeholders
    # ({driverClassName}, {connectionUrl}...). Se ficar no WORKDIR, o PEC
    # tenta carregar o driver "{driverClassName}" e não sobe.
    rm -f "$W/application.properties" "$W/standalone.sh" "$W/e-SUS-PEC.service"; \
    # O standalone.sh oficial roda o certmgr de dentro de webserver/certmgr/.
    # Ele fica separado para ser copiado com dono "pec" (o certmgr grava ali).
    mkdir -p /build/certmgr/config; \
    mv "$W/certmgr.jar" /build/certmgr/

# ------------------------------------------------------------------------------
# Estágio 2: runtime
# ------------------------------------------------------------------------------
FROM eclipse-temurin:17-jre-jammy AS runtime

SHELL ["/bin/bash", "-eo", "pipefail", "-c"]

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=America/Sao_Paulo \
    LANG=C.UTF-8

ARG PEC_UID=10001

# Fontes para relatórios (receitas, espelho SOAP) e pg_isready para esperar o banco.
# hadolint ignore=DL3008
RUN echo 'Acquire::Retries "5";' > /etc/apt/apt.conf.d/80-retries && \
    apt-get update && \
    echo "ttf-mscorefonts-installer msttcorefonts/accepted-mscorefonts-eula select true" | debconf-set-selections && \
    apt-get install -y --no-install-recommends \
        fontconfig \
        tzdata \
        curl \
        postgresql-client \
        ca-certificates \
        ttf-mscorefonts-installer && \
    fc-cache -f && \
    rm -rf /var/lib/apt/lists/* && \
    groupadd -g "${PEC_UID}" pec && \
    useradd -r -l -u "${PEC_UID}" -g pec -d /opt/pec -s /usr/sbin/nologin pec

WORKDIR /opt/pec/webserver

# Os jars pertencem ao root: a JVM (usuário pec) não consegue substituí-los.
# Só as pastas de dados e a do certmgr ficam com o usuário pec.
COPY --from=builder /build/container/webserver/ /opt/pec/webserver/
COPY --from=builder /build/container/database/migrador.jar /opt/pec/database/migrador.jar
COPY --from=builder --chown=${PEC_UID}:${PEC_UID} /build/certmgr/ /opt/pec/webserver/certmgr/
COPY --chmod=755 docker/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN install -d -o pec -g pec -m 700 \
      /opt/pec/webserver/config /opt/pec/webserver/chaves /opt/pec/webserver/logs

EXPOSE 8080 443

# /api/public/info é público e só responde depois do boot completo do Spring.
# start-period longo porque a primeira subida após atualização aplica migrações.
HEALTHCHECK --interval=30s --timeout=10s --start-period=300s --retries=5 \
  CMD curl -fsS -o /dev/null http://127.0.0.1:8080/api/public/info \
   || curl -fsSk -o /dev/null https://127.0.0.1:443/api/public/info \
   || exit 1

# O entrypoint começa como root só para ajustar o dono dos volumes montados
# e troca para o usuário "pec" (setpriv) antes de iniciar a JVM.
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
