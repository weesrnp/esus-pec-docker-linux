# e-SUS APS PEC em Docker (Linux)

Ambiente Docker para instalação e execução do **e-SUS APS PEC (Prontuário Eletrônico do Cidadão)** em servidores Linux.

---

## Características

- **Build multi-stage:** O Dockerfile extrai os componentes necessários (`pec-bundle.jar`, `certmgr.jar`) diretamente do instalador oficial em tempo de build, mantendo a imagem final limpa e enxuta.
- **Imagem base oficial:** Utiliza `eclipse-temurin:17-jre-jammy` com fontes `msttcorefonts` instaladas para correta renderização de relatórios e impressões clínicas em PDF.
- **Configuração de banco:** Parâmetros do PostgreSQL ajustados para atender a volumetria e complexidade das tabelas do Data Warehouse da Atenção Primária.
- **Usuário de consulta (LGPD):** Criação automática de usuário com permissões de somente leitura (`esus_leitura`) e limite de tempo por consulta, voltado para integração com painéis e relatórios externos.
- **Suporte a HTTPS:** Compatível com o utilitário `certmgr.jar` para uso de certificados na porta 443.

---

## Requisitos

- Docker Engine 24.0 ou superior
- Docker Compose v2 instalado

---

## Instalação e uso

### 1. Clonar o repositório e preparar variáveis
```bash
git clone https://github.com/SEU_USUARIO/esus-pec-docker-linux.git
cd esus-pec-docker-linux
cp .env.example .env
```
Ajuste as credenciais e portas no arquivo `.env` conforme a topologia da sua rede.

### 2. Baixar o instalador oficial do PEC
Coloque o arquivo `.jar` do instalador Linux na raiz do diretório do projeto ou utilize o script auxiliar:
```bash
chmod +x scripts/*.sh docker/*.sh
./scripts/get-latest-pec.sh --download
```

### 3. Subir os contêineres
```bash
docker compose build
docker compose up -d
```
A aplicação estará disponível em `http://localhost:8080` (ou no IP configurado no servidor).

---

## Estrutura do projeto

```
esus-pec-docker-linux/
├── docker/
│   ├── Dockerfile         # Definição multi-stage da imagem da aplicação
│   └── entrypoint.sh      # Script de inicialização da JVM e checagem de dependências
├── sql/
│   └── 01-init-esus-leitura.sql # Criação do usuário de leitura no banco
├── scripts/
│   ├── backup.sh          # Rotina de dump do banco de dados
│   ├── restore.sh         # Script de restauração de base com pg_restore
│   └── get-latest-pec.sh  # Consulta e download da versão atual no portal SISAPS
├── docs/
│   └── POP-MIGRACAO.md    # Roteiro de migração de ambientes Windows para Linux
├── compose.yml            # Definição dos serviços esus-db e esus-pec
├── .env.example           # Modelo de variáveis de ambiente
└── .gitignore             # Regras de exclusão de dados sensíveis e binários
```

---

## Rotinas operacionais

### Gerar backup da base
```bash
./scripts/backup.sh
```
O script gera um arquivo comprimido (`.backup`) dentro do diretório `backups/`.

### Restaurar base existente
```bash
./scripts/restore.sh backups/arquivo_de_backup.backup
```

### Migração de ambiente legado
Caso esteja migrando uma instalação existente do e-SUS PEC que roda em Windows Server, siga o roteiro detalhado em [docs/POP-MIGRACAO.md](docs/POP-MIGRACAO.md).

---

## Segurança

- Arquivos de backup, credenciais locais (`.env`), certificados digitais (`.p12`) e chaves privadas estão bloqueados no `.gitignore`.
- O banco de dados nunca deve ser exposto diretamente para a internet sem regras de firewall ou VPN.
- Mantenha senhas com complexidade adequada para os usuários administrativos do banco.

---

## Licença

Distribuído sob licença MIT. Consulte o arquivo [LICENSE](LICENSE) para mais detalhes.  
O e-SUS APS PEC é desenvolvido pelo Laboratório Bridge (UFSC) e mantido pelo Ministério da Saúde.
