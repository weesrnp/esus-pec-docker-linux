# POP: migração do e-SUS PEC de Windows Server para Docker Linux

Roteiro para levar uma instalação do e-SUS APS PEC em Windows para esta stack, sem perder histórico clínico, cadastros e chaves da RNDS.

Tempo estimado: de 1 a 3 horas, conforme o tamanho do banco. Faça fora do horário de atendimento das UBS.

---

## 1. Antes de começar

1. Servidor Linux pronto (Docker, Compose, NTP), com o repositório clonado. Siga o README até o passo 3 (`gerar-env.sh`, `get-latest-pec.sh --download`, `doctor.sh`) e confira que o `doctor.sh` não mostra falhas.
2. Use no Linux **a mesma versão do PEC** do Windows, ou mais nova. O `restore.sh` roda o migrador e atualiza o banco; voltar para uma versão mais antiga não é possível.
3. Avise as equipes: o PEC do Windows precisa ficar parado do backup em diante, senão os atendimentos feitos depois do dump se perdem.

## 2. No servidor Windows

1. Pare o serviço do PEC (`services.msc` → e-SUS PEC → Parar). Deixe o PostgreSQL rodando.
2. Num PowerShell como Administrador, gere o dump em formato customizado. A pasta do `pg_dump.exe` muda com a versão instalada; confira antes:
   ```powershell
   Get-ChildItem "C:\Program Files\e-SUS\database" -Recurse -Filter pg_dump.exe | Select-Object FullName
   & "<caminho encontrado>\pg_dump.exe" -h 127.0.0.1 -p 5433 -U postgres -d esus -F c -f "C:\eSUS_migracao.backup"
   ```
3. Copie também estas pastas (as chaves da RNDS e o certificado HTTPS ficam aqui):
   - `C:\Program Files\e-SUS\webserver\config`
   - `C:\Program Files\e-SUS\webserver\chaves`
   - `C:\Program Files\e-SUS\webserver\certmgr\config` (se o HTTPS estiver ativo)
4. O dump tem dados de saúde de toda a população atendida. Transfira por rede interna ou num pendrive criptografado (BitLocker To Go, 7z com AES) e apague as cópias temporárias quando terminar.

## 3. No servidor Linux

1. Coloque as pastas copiadas nos volumes do projeto:
   ```bash
   mkdir -p volumes/pec_config volumes/pec_chaves volumes/pec_certmgr
   cp -r /caminho/config/.  volumes/pec_config/
   cp -r /caminho/chaves/.  volumes/pec_chaves/
   cp -r /caminho/certmgr_config/. volumes/pec_certmgr/   # se houver
   ```
   O `application.properties` vindo do Windows aponta para `localhost:5433`. Pode deixar: o compose define a conexão por variável de ambiente, que tem prioridade.
2. Suba só o banco:
   ```bash
   docker compose up -d esus-db
   ```
3. Restaure. O script valida o arquivo, restaura num banco temporário, roda o migrador e reaplica o usuário de leitura:
   ```bash
   ./scripts/restore.sh /caminho/eSUS_migracao.backup
   ```
   Em dumps do PostgreSQL 9.6 podem aparecer avisos sobre `schema "public" already exists` ou `plpgsql`. O script reconhece esses casos e não os trata como falha; qualquer outro erro interrompe a restauração sem mexer no banco em uso.
4. Suba o PEC:
   ```bash
   docker compose up -d
   docker compose logs -f esus-pec
   ```

O banco do Windows usa a senha antiga do `postgres`. Depois da restauração vale a senha do `.env` do Linux, porque a restauração cria os objetos sem dono (`--no-owner`) e as senhas dos papéis não vêm no dump.

## 4. Validação

1. `http://IP_DO_SERVIDOR:8080` abre a tela de login.
2. Um profissional consegue entrar e abrir um prontuário com histórico anterior à migração.
3. A configuração de transmissão (chaves, centralizador, RNDS) continua presente na administração do PEC.
4. `docker exec esus-db psql -U postgres -d esus -tAc "select count(*) from pg_tables where schemaname='public'"` mostra mais de 1.000 tabelas.
5. Rode `./scripts/backup.sh` e `./scripts/setup-cron-backup.sh`.

## 5. Depois de alguns dias

- Com o PEC Linux estável, apague o banco anterior que o `restore.sh` deixou para rollback (o comando aparece no fim da saída dele).
- Mantenha o servidor Windows desligado, mas guardado, por pelo menos um ciclo de envio ao SISAB.
- Atualize o link de acesso nas UBS e, se houver HTTPS, o apontamento do domínio.
