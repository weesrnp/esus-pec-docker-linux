# e-SUS APS PEC em Docker (Linux)

[![Docker Compose](https://img.shields.io/badge/docker--compose-v2-blue?logo=docker)](https://docs.docker.com/compose/)
[![Java](https://img.shields.io/badge/OpenJDK-17-orange?logo=openjdk)](https://adoptium.net/)
[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-16%20%7C%209.6-blue?logo=postgresql)](https://www.postgresql.org/)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

Estrutura Docker de alto desempenho e arquitetura limpa para executar o **e-SUS APS PEC (Prontuário Eletrônico do Cidadão)** em servidores Linux.

---

## 🎯 Destaques Arquiteturais

- **Zero Mocks de Systemd:** Não utiliza gambiarras de sobrescrita de `/bin/ps` ou `/bin/systemctl`. Extrai diretamente os pacotes Spring Boot (`pec-bundle.jar`) e utilitários oficiais em um build multi-stage limpo.
- **Imagem Leve (~250 MB):** Runtime baseado na imagem oficial `eclipse-temurin:17-jre`, com fontes Microsoft Core Fonts (`msttcorefonts`) integradas para geração perfeita de receitas e relatórios em PDF.
- **Banco de Dados Afinado (DW 1.200 tabelas):** Parâmetros de PostgreSQL (`shared_buffers`, `effective_cache_size`, `work_mem`) otimizados para o modelo Star Schema da Atenção Primária à Saúde.
- **Conformidade LGPD:** Script de inicialização automática do usuário `esus_leitura` com privilégios estritamente `READ ONLY` e timeout de segurança para BI, relatórios e auditorias.
- **Gestão Segura de SSL:** Compatível com o utilitário oficial `certmgr.jar` para autogestão de certificados HTTPS na porta 443.

---

## 🚀 Início Rápido

### 1. Pré-Requisitos
- [Docker Engine](https://docs.docker.com/engine/install/) (v24+)
- [Docker Compose](https://docs.docker.com/compose/install/) (v2+)

### 2. Configuração de Ambiente
Clone o repositório e crie o seu arquivo de ambiente:
```bash
git clone https://github.com/SEU_USUARIO/esus-pec-docker-linux.git
cd esus-pec-docker-linux
cp .env.example .env
```
Edite o arquivo `.env` para ajustar senhas e portas conforme seu ambiente.

### 3. Obtenção do Pacote Oficial
Coloque o arquivo instalador oficial (`eSUS-AB-PEC-*-Linux64.jar`) na raiz do repositório ou use o script de download automático:
```bash
chmod +x scripts/*.sh docker/*.sh
./scripts/get-latest-pec.sh --download
```

### 4. Build e Inicialização
```bash
docker compose build
docker compose up -d
```
Acesse a aplicação no navegador em: `http://localhost:8080` (ou IP do seu servidor).

---

## 📂 Estrutura de Arquivos

```
esus-pec-docker-linux/
├── docker/
│   ├── Dockerfile         # Multi-stage: Extração oficial + Runtime Temurin 17 JRE
│   └── entrypoint.sh      # Inicialização com JAVA_OPTS e checagem de banco
├── sql/
│   └── 01-init-esus-leitura.sql # Provisionamento da conta somente leitura (LGPD)
├── scripts/
│   ├── backup.sh          # Rotina de backup consistente via pg_dump
│   ├── restore.sh         # Restauração com pg_restore e validação
│   └── get-latest-pec.sh  # Script de download da versão mais recente do SISAPS
├── docs/
│   └── POP-MIGRACAO.md    # Procedimento Operacional Padrão de migração Windows -> Linux
├── compose.yml            # Orquestração do banco e-SUS e da aplicação
├── .env.example           # Modelo sanitizado de variáveis
└── .gitignore             # Bloqueio estrito de dumps, senhas e certificados
```

---

## 💾 Rotinas Operacionais

### Backup Diário do Banco de Dados
```bash
./scripts/backup.sh
```
Gera um arquivo consistente `.backup` na pasta `backups/` com data e hora.

### Restauração de Backup
```bash
./scripts/restore.sh backups/esus_backup_YYYYMMDD_HHMMSS.backup
```

### Migração de Servidor Windows para Linux
Consulte o guia passo a passo em [docs/POP-MIGRACAO.md](docs/POP-MIGRACAO.md).

---

## 🔒 Segurança e LGPD

- As credenciais declaradas em `.env` jamais são commitadas (protegidas via `.gitignore`).
- Dumps de banco contendo dados nominais de cidadãos (`.backup`) são estritamente ignorados pelo versionamento.
- Recomenda-se a geração de senhas aleatórias de no mínimo 24 caracteres para as variáveis de banco de dados.

---

## 📄 Licença

Distribuído sob licença MIT. O e-SUS APS PEC é software público do Ministério da Saúde do Brasil. Este projeto fornece exclusivamente a automação e containerização do ambiente de execução.
