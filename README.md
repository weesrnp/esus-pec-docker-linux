<p align="center">
  <img src="assets/banner.png" alt="e-SUS APS PEC em Docker (Linux)" width="100%">
</p>

# e-SUS APS PEC em Docker (Linux)

<p align="left">
  <a href="https://github.com/weesrnp/esus-pec-docker-linux/actions/workflows/build-test.yml"><img src="https://github.com/weesrnp/esus-pec-docker-linux/actions/workflows/build-test.yml/badge.svg" alt="Validação"></a>
  <a href="https://docs.docker.com/compose/"><img src="https://img.shields.io/badge/docker--compose-v2-blue?logo=docker&logoColor=white" alt="Docker Compose"></a>
  <a href="https://adoptium.net/"><img src="https://img.shields.io/badge/Temurin-17-red?logo=openjdk&logoColor=white" alt="Java 17"></a>
  <a href="https://www.postgresql.org/"><img src="https://img.shields.io/badge/PostgreSQL-16-336791?logo=postgresql&logoColor=white" alt="PostgreSQL 16"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-yellow.svg" alt="License MIT"></a>
</p>

Stack Docker para instalar, operar e atualizar o **e-SUS APS PEC** (Prontuário Eletrônico do Cidadão) em servidores Linux, usando os artefatos do instalador oficial do Ministério da Saúde.

Validado com o PEC 5.5.28 (LEDI 8.7.0), Temurin 17 e PostgreSQL 16. O teste ponta a ponta (`tests/e2e.sh`) cobre instalação, migração, backup, restauração, troca de senhas e atualização.

---

## Como funciona

| Peça | O que faz |
| :--- | :--- |
| `docker/Dockerfile` | Extrai do instalador `pec-bundle.jar`, `certmgr.jar` e `migrador.jar` e monta uma imagem Temurin 17 sem systemd e sem mocks. A JVM roda como usuário `pec` (uid 10001). |
| `compose.yml` | PostgreSQL 16 (locale pt-BR via ICU, `datestyle` dmy, SCRAM) e o PEC, numa rede interna `198.18.200.0/24`. |
| `sql/esus-leitura.sql` | Usuário `esus_leitura` só com SELECT, no máximo 5 conexões e `statement_timeout` de 30s. A senha vem do `.env`. |
| `scripts/` | Instalação, backup validado, restauração com rollback, atualização de versão, troca de senhas e diagnóstico. |

O PEC é um Spring Boot. A conexão com o banco vem de variáveis de ambiente (`SPRING_DATASOURCE_*`), então não há `application.properties` com senha dentro da imagem.

---

## Requisitos

- Linux x86_64 (Ubuntu 22.04/24.04, Debian 12 ou equivalente), relógio sincronizado por NTP
- Docker Engine 24+ com Compose v2.20+
- 8 GB de RAM no mínimo (16 GB recomendados), 100 GB de disco (requisito oficial)
- `unzip`, `curl` e `flock` (pacote `util-linux`) no host

---

## Instalação nova

```bash
git clone https://github.com/weesrnp/esus-pec-docker-linux.git
cd esus-pec-docker-linux
chmod +x scripts/*.sh
```

1. Gere o `.env` com senhas aleatórias (permissão 600):
   ```bash
   ./scripts/gerar-env.sh
   ```
   Revise `PEC_BIND_IP` (IP da LAN para as UBS acessarem) e `PEC_HEAP`.
2. Baixe o instalador oficial para a pasta `instalador/`. O script acha a versão mais recente no portal SISAPS, valida o arquivo e grava `PEC_JAR_FILE`, `PEC_JAR_SHA256` e `PEC_IMAGE_TAG` no `.env`. Se já tiver o `.jar`, copie-o para `instalador/` e ajuste `PEC_JAR_FILE`.
   ```bash
   ./scripts/get-latest-pec.sh --download
   ```
3. Confira o servidor:
   ```bash
   ./scripts/doctor.sh
   ```
4. Construa a imagem e crie o banco (migrador oficial, cerca de 1.180 tabelas, de 5 a 15 minutos):
   ```bash
   docker compose build
   ./scripts/init-new-db.sh
   ```
   Para uma base de treinamento: `./scripts/init-new-db.sh --treinamento`.
5. Suba o PEC:
   ```bash
   docker compose up -d
   docker compose logs -f esus-pec
   ```
   O container fica `healthy` quando `http://<servidor>:8080/api/public/info` responde.
6. Agende o backup diário:
   ```bash
   ./scripts/setup-cron-backup.sh
   ```

Vindo de um servidor Windows? Siga o [POP de migração](docs/POP-MIGRACAO.md).

---

## Operação

| Tarefa | Comando |
| :--- | :--- |
| Backup agora | `./scripts/backup.sh` |
| Restaurar | `./scripts/restore.sh backups/esus_esus_AAAAMMDD_HHMMSS.backup` |
| Atualizar versão do PEC | `./scripts/atualizar-pec.sh instalador/eSUS-AB-PEC-X.Y.Z-Linux64.jar` |
| Trocar senhas do banco | `./scripts/trocar-senhas.sh` |
| Diagnóstico | `./scripts/doctor.sh` |
| Ver agendamento do backup | `./scripts/setup-cron-backup.sh --show` |

### Backup

`backup.sh` funciona de qualquer diretório, inclusive pelo cron. Cada execução gera em `backups/`, tudo com permissão 600:

- `esus_<banco>_<data>.backup`: dump `-Fc`, conferido com `pg_restore --list` antes de ser aceito;
- `.sha256` do dump;
- `esus_config_<data>.tar.gz`: config, chaves RNDS e certificados do PEC.

Arquivos com mais de `RETENTION_DAYS` dias (padrão 30) são apagados. O script não copia nada para fora do servidor: leve a pasta `backups/` para outro equipamento (NAS, disco externo, nuvem da prefeitura). Um backup que só existe no mesmo disco do banco não protege contra falha de disco nem ransomware.

### Restauração

`restore.sh` restaura num banco temporário. Só depois de conferir as tabelas é que para o PEC e troca os nomes. O banco anterior fica como `esus_antes_<data>` para rollback, e o script mostra o comando para apagá-lo. Em seguida roda o migrador, para que um backup de versão anterior suba na versão da imagem atual. Se o migrador falhar, os nomes voltam ao estado anterior.

### Atualização de versão

`atualizar-pec.sh` faz backup, constrói a imagem nova, para o PEC e roda o migrador da versão nova. O `.env` só muda depois que o migrador termina bem; se ele falhar, o script mostra o comando de restore do backup que acabou de fazer. No fim, sobe o PEC e confere a versão informada pela API.

### Senhas

- `gerar-env.sh` cria senhas de 192 bits. O `.env` não vai para o git (`.gitignore`) nem para o contexto de build (`.dockerignore`).
- Editar a senha no `.env` **não muda** a senha que já está gravada no PostgreSQL. Para trocar, use `trocar-senhas.sh`: ele altera no banco, atualiza o `.env` (guarda cópia em `.env.bak-<data>`) e recria os containers.
- Um banco novo não é criado com senha vazia, curta (menos de 16 caracteres) ou com o valor de exemplo. Num banco que já existe, a senha que vale é a gravada no PostgreSQL: o container sobe e avisa, para que o `trocar-senhas.sh` possa ser usado. O PEC e os scripts recusam o valor de exemplo publicado no repositório e só avisam sobre senhas próprias curtas.
- As senhas vão para os containers por variável de ambiente, visíveis para quem tem acesso ao Docker do servidor (`docker inspect`). Esse acesso já equivale a root no host; restrinja o grupo `docker`.
- O migrador oficial só aceita a senha como argumento. Os scripts passam esse argumento por um arquivo de argumentos do Java, para que ele não apareça no `ps` do host durante a migração.

### HTTPS

O certmgr oficial emite e renova o certificado. Ele exige um domínio público apontando para o servidor e as portas 80 e 443 liberadas no roteador ([manual oficial](https://sisaps.saude.gov.br/sistemas/esusaps/docs/manual/APOIO/HTTPS_Automatizado/)).

No `.env`: `PEC_SSL_DOMAIN=esus.municipio.pr.gov.br`, `PEC_BIND_IP` com o IP que recebe o encaminhamento (ou `0.0.0.0`) e `COMPOSE_FILE=compose.yml:compose.ssl.yml`, para que os scripts de backup, atualização e troca de senhas também usem o HTTPS. Depois:

```bash
docker compose up -d
```

Se a emissão falhar, o container espera 10 minutos (`PEC_SSL_RETRY_DELAY`) antes de tentar de novo, para não estourar o limite de tentativas da autoridade certificadora.

Na primeira subida, o entrypoint roda `certmgr --enable --verify` (como o instalador oficial). Ele confere DNS e portas sem emitir nada; só se passar vem o `--enable`. Se o domínio não resolver, o log mostra `Domínio inválido ou inacessível` e o container espera `PEC_SSL_RETRY_DELAY` antes de sair, sem tentar emitir.

O certificado é renovado a cada reinício do container, como no `standalone.sh` oficial. Se a renovação falhar, o log mostra `ERRO: certmgr --renew falhou` e o PEC sobe com o certificado atual.

O teste automático cobre o caminho de recusa (domínio que não resolve). A emissão real depende de um domínio público e não roda no teste. Uma alternativa sem certmgr é um proxy TLS (Caddy, nginx) na frente da porta 8080.

---

## Segurança

- O banco é publicado só em `127.0.0.1` (`POSTGRES_BIND_IP`), mesmo quando o PEC está na LAN. O Docker publica portas por cima do UFW/firewalld: para liberar o BI pela rede, use VPN, túnel SSH ou regra na chain `DOCKER-USER`.
- O `esus_leitura` tem só SELECT. `default_transaction_read_only` e `statement_timeout` são padrões que o próprio usuário consegue mudar com `SET`; a garantia real é a falta de permissão de escrita. Ele enxerga todas as tabelas, inclusive dados pessoais: entregue a senha só a quem tem base legal para tratar esses dados (LGPD).
- O PEC conecta como dono do banco (`POSTGRES_USER`). Separar um papel sem superusuário para a aplicação é uma melhoria possível, mas exige validar o migrador em cada versão.
- O backup não é criptografado. Se sair do servidor, cifre (age, gpg ou 7z AES).

---

## Estrutura

```
├── compose.yml              # banco + PEC
├── instalador/              # eSUS-AB-PEC-X.Y.Z-Linux64.jar (não versionado)
├── compose.ssl.yml          # complemento para HTTPS com certmgr
├── .env.example             # modelo (use scripts/gerar-env.sh)
├── docker/
│   ├── Dockerfile           # extração do instalador + runtime Temurin 17
│   └── entrypoint.sh        # JVM, espera do banco, certmgr, troca para o usuário pec
├── sql/
│   ├── esus-leitura.sql     # usuário de leitura (idempotente)
│   ├── 01-init-esus-leitura.sh
│   └── db-entrypoint.sh     # recusa senha fraca antes do initdb
├── scripts/
│   ├── lib.sh               # funções comuns (leitura do .env, psql, migrador)
│   ├── gerar-env.sh         # .env com senhas aleatórias
│   ├── trocar-senhas.sh     # rotação de senhas no banco e no .env
│   ├── doctor.sh            # diagnóstico do servidor
│   ├── get-latest-pec.sh    # localiza e baixa o instalador oficial
│   ├── init-new-db.sh       # banco novo via migrador oficial
│   ├── backup.sh            # dump validado + chaves, com retenção
│   ├── restore.sh           # restauração com rollback
│   ├── atualizar-pec.sh     # atualização de versão
│   └── setup-cron-backup.sh # agendamento diário
├── tests/
│   ├── e2e.sh               # teste ponta a ponta (destrutivo)
│   └── run-dind.sh          # roda o e2e num Docker-in-Docker descartável
└── docs/POP-MIGRACAO.md     # migração de Windows Server para Linux
```

---

## Desenvolvimento

- CI (`.github/workflows/build-test.yml`): ShellCheck, Hadolint, validação do compose e teste do usuário de leitura num PostgreSQL 16 real. O build da imagem não roda no CI porque o instalador (780 MB) não é versionado.
- Teste completo local, com o instalador em `instalador/`:
  ```bash
  tests/run-dind.sh
  ```

Atualizando de uma versão anterior deste repositório? Leia o [CHANGELOG](CHANGELOG.md): há mudanças de variáveis e de comportamento.

## Licença

MIT. Veja [LICENSE](LICENSE).
O e-SUS APS PEC é desenvolvido pelo Laboratório Bridge (UFSC) e mantido pelo Ministério da Saúde. Este projeto não tem vínculo oficial com eles.
