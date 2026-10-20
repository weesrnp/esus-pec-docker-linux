# ==============================================================================
# e-SUS APS PEC em Docker (Linux) - Multi-Stage Dockerfile Oficial
# ==============================================================================
# Abordagem de Engenharia Reversa: Extração direta dos payloads JAR da camada
# 'container/', dispensando mocks de systemd, wrappers de ps ou instalador IzPack.
# ==============================================================================

# ------------------------------------------------------------------------------
# Estágio 1: Extrator (Descompactador do Pacote Oficial)
# ------------------------------------------------------------------------------
FROM alpine:3.20 AS builder

RUN apk add --no-cache unzip curl bash

WORKDIR /build

# Argumento para indicar o instalador local ou download remoto
ARG PEC_JAR
ARG DOWNLOAD_URL

# Script de extração resiliente: suporta arquivo local ou download direto
COPY . /src/
RUN if [ -n "${PEC_JAR}" ] && [ -f "/src/${PEC_JAR}" ]; then \
        echo "==> Usando instalador local: ${PEC_JAR}"; \
        cp "/src/${PEC_JAR}" /tmp/installer.jar; \
    elif [ -n "${DOWNLOAD_URL}" ]; then \
        echo "==> Baixando instalador oficial de: ${DOWNLOAD_URL}"; \
        curl -fsSL "${DOWNLOAD_URL}" -o /tmp/installer.jar; \
    else \
        # Tenta localizar qualquer arquivo .jar do instalador na raiz do contexto
        INSTALLER=$(find /src -maxdepth 2 -name "*eSUS*PEC*.jar" | head -n 1); \
        if [ -n "$INSTALLER" ]; then \
            echo "==> Instalador localizado automaticamente: $INSTALLER"; \
            cp "$INSTALLER" /tmp/installer.jar; \
        else \
            echo "ERRO: Nenhum arquivo instalador e-SUS PEC .jar encontrado no contexto." >&2; \
            echo "Informe o arquivo via build-arg PEC_JAR=<arquivo.jar> ou coloque-o na raiz." >&2; \
            exit 1; \
        fi; \
    fi && \
    echo "==> Extraindo pacotes internos do container oficial..." && \
    unzip -q /tmp/installer.jar "container/webserver/*" "container/database/*" -d /build/ && \
    rm -f /tmp/installer.jar

# ------------------------------------------------------------------------------
# Estágio 2: Runtime Final de Execução
# ------------------------------------------------------------------------------
FROM eclipse-temurin:17-jre-jammy AS runtime

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=America/Sao_Paulo

# Dependências de sistema: fontes para geração de receitas/PDFs e cliente PostgreSQL
RUN apt-get update && \
    echo "ttf-mscorefonts-installer msttcorefonts/accepted-mscorefonts-eula select true" | debconf-set-selections && \
    apt-get install -y --no-install-recommends \
        fontconfig \
        tzdata \
        curl \
        postgresql-client \
        ca-certificates \
        ttf-mscorefonts-installer && \
    fc-cache -fv && \
    rm -rf /var/lib/apt/lists/*

# Diretórios de trabalho do PEC
RUN mkdir -p /opt/pec/webserver /opt/pec/database /opt/pec/config /opt/pec/chaves /opt/pec/backups

WORKDIR /opt/pec/webserver

# Cópia seletiva dos artefatos descompactados do Estágio 1
COPY --from=builder /build/container/webserver/ /opt/pec/webserver/
COPY --from=builder /build/container/database/ /opt/pec/database/

# Script de entrada inteligente
COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Portas de serviço (HTTP e HTTPS)
EXPOSE 8080 443

HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
  CMD curl -fsS http://127.0.0.1:8080/ > /dev/null || exit 1

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
