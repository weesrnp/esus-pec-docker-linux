# POP: Migração de e-SUS PEC (Windows Server para Docker Linux)

Este Procedimento Operacional Padrão orienta a migração do **e-SUS APS PEC** em ambiente legado Windows Server para a stack Docker Linux sem perda de dados ou inconsistência de chaves RNDS.

---

## 1. Pré-Requisitos

1. Servidor Linux (Ubuntu 22.04 LTS ou superior recomendado) com Docker Engine e Docker Compose v2 instalados.
2. Acesso de rede entre os dois servidores ou possibilidade de transferência de arquivos via pendrive/rede local.
3. Janela de manutenção programada (fora do horário de atendimento das Unidades Básicas de Saúde).

---

## 2. Passo a Passo da Migração

### Passo 1: Backup Completo no Servidor Windows
1. No servidor Windows de origem, abra o PowerShell como Administrador.
2. Execute o dump no formato customizado:
   ```powershell
   & "C:\Program Files\e-SUS\database\postgresql\bin\pg_dump.exe" -h 127.0.0.1 -p 5433 -U postgres -d esus -F c -b -v -f "C:\eSUS_backup_migracao.backup"
   ```

### Passo 2: Cópia das Chaves Criptográficas e Configurações
Copie as pastas essenciais do servidor Windows para o Linux:
- `C:\Program Files\e-SUS\webserver\config` $\rightarrow$ `./volumes/pec_config/`
- `C:\Program Files\e-SUS\webserver\chaves` $\rightarrow$ `./volumes/pec_chaves/` (Chaves RNDS)
- `C:\Program Files\e-SUS\webserver\certmgr\config` $\rightarrow$ `./volumes/pec_certmgr/` (Certificados SSL)

### Passo 3: Inicialização da Nova Stack no Linux
1. No servidor Linux, clone o repositório e configure as variáveis:
   ```bash
   cp .env.example .env
   # Edite o .env colocando a mesma senha do usuário postgres da origem
   ```
2. Inicie apenas o banco de dados:
   ```bash
   docker compose up -d esus-db
   ```
3. Restaure o backup gerado no Windows:
   ```bash
   ./scripts/restore.sh /caminho/eSUS_backup_migracao.backup
   ```
4. Suba a aplicação PEC:
   ```bash
   docker compose up -d esus-pec
   ```

### Passo 4: Validação Pós-Migração
1. Acompanhe a subida pelo log:
   ```bash
   docker compose logs -f esus-pec
   ```
2. Acesse no navegador `http://IP_DO_SERVIDOR:8080` e confirme o login de um profissional e o carregamento do prontuário.
