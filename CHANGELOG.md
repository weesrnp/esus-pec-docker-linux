# Changelog

## 2026-10-20: correções da auditoria técnica

### Corrigido
- **Backup corrompido.** `backup.sh` usava `docker exec -t`: o TTY trocava `\n` por `\r\n` e misturava as mensagens do `-v` no dump, que ficava impossível de restaurar mesmo com o script informando sucesso. Agora o dump só é aceito depois de passar no `pg_restore --list`.
- **Instalação nova não subia.** A imagem copiava o `application.properties` do pacote, que é um template, e o PEC tentava carregar o driver `{driverClassName}`. O template foi removido e o driver vem do ambiente.
- **`init-new-db.sh` não migrava.** O `migrador.jar` era chamado sem `-url/-username/-password`, imprimia a ajuda e saía com 0. Agora recebe os parâmetros e o script confere se o banco ficou com mais de 1.000 tabelas.
- **Download baixava HTML.** `get-latest-pec.sh` montava uma URL que não existe e salvava a página do portal como `.jar`. Agora acha o link oficial (`arquivos.esusaps.ufsc.br/PEC/<hash>/<versão>/`), valida o zip e grava o SHA-256.
- **Contexto de build com segredos.** Não havia `.dockerignore`: `.env`, dumps e `pg_data` iam para o build, que além disso falhava sem sudo depois do primeiro `up`.
- **Senha fixa do usuário de leitura** no SQL público (`ESUS_LEITURA_PASSWORD` era ignorada). Agora vem do `.env`.
- **Restauração** tratava erro fatal como aviso e, fora da raiz do projeto, não parava o PEC. Agora restaura num banco temporário e troca os nomes só no final, com rollback.
- **Backup pelo cron** caía em `~/backups`, a retenção não apagava nada e os arquivos ficavam com modo 644.
- **certmgr:** o jar estava fora de `certmgr/`, a renovação falhava sem aviso e a ativação nunca era feita.
- **Locale do banco:** ordenação pt-BR (ICU), `datestyle` dmy e busca textual em português, como no `postgresql.conf` oficial.
- **`-Xms` fixo em 2048M** impedia a JVM de subir com `PEC_HEAP` menor.
- **Fim de linha:** `.gitattributes` força LF; um clone no Windows gerava `bash\r` e o container entrava em loop.
- **CI** voltou a passar e agora testa o usuário de leitura num PostgreSQL real.

### Novo
- `scripts/gerar-env.sh`: `.env` com senhas aleatórias e permissão 600.
- `scripts/trocar-senhas.sh`: troca as senhas no banco e no `.env` e recria os containers.
- `scripts/atualizar-pec.sh`: backup, build, migrador e subida com conferência de versão.
- `scripts/lib.sh`: funções comuns; todos os scripts funcionam de qualquer diretório.
- `compose.ssl.yml`: HTTPS com o certmgr oficial (`PEC_SSL_DOMAIN`, porta 80).
- `tests/e2e.sh` e `tests/run-dind.sh`: teste ponta a ponta num Docker-in-Docker.
- Backup das pastas de config, chaves RNDS e certificados (`esus_config_<data>.tar.gz`).
- Usuário de leitura com limite de 5 conexões; o SQL recusa apontar `ESUS_LEITURA_USER` para um papel administrativo e não deixa a senha ir para o log do servidor.
- Restauração: troca de bancos numa transação, com os bancos fechados para conexões durante a troca; o banco anterior fica fechado para conexões (o BI não lê a cópia antiga); qualquer código de saída do `pg_restore` diferente de 0 conta como falha, salvo os erros conhecidos de dumps 9.6.
- A JVM roda com umask 027, as pastas de chaves e certificados ficam 700 e os jars pertencem ao root.
- O backup das chaves funciona com o PEC parado e o `backup.sh` sai com erro se as chaves não forem salvas.

### Mudou (atenção ao atualizar uma instalação existente)
- **O instalador fica em `instalador/`**, não mais na raiz. Exceções com curinga no `.dockerignore` fazem o BuildKit percorrer `volumes/pg_data` e o build falha com "permission denied" depois do primeiro `up`; com a pasta própria isso não acontece.
- **HTTPS:** quem usa `compose.ssl.yml` deve pôr `COMPOSE_FILE=compose.yml:compose.ssl.yml` no `.env`, senão os scripts recriam o PEC sem HTTPS.
- **`LAN_IP` não publica mais o banco.** O PEC usa `PEC_BIND_IP` (com `LAN_IP` como reserva) e o banco usa `POSTGRES_BIND_IP`, padrão `127.0.0.1`. Se algum BI acessava a porta 5433 pela rede, defina `POSTGRES_BIND_IP` de propósito ou passe a usar VPN/túnel.
- **`POSTGRES_PASSWORD` e `ESUS_LEITURA_PASSWORD` são obrigatórias.** O compose recusa valor vazio. Um banco novo não é criado com senha curta (menos de 16) ou com o valor de exemplo. Num banco já existente o container sobe só com aviso, porque a senha real está gravada no PostgreSQL e o `trocar-senhas.sh` precisa do banco no ar. O PEC e os scripts recusam o valor de exemplo (`altere_*`) e só avisam sobre senhas próprias curtas.
- **Quem atualiza com a senha de exemplo no `.env`:** o banco sobe, o PEC não. Rode `./scripts/trocar-senhas.sh`, que grava as duas senhas numa única transação e recria os containers. O `doctor.sh` também avisa se o `esus_leitura` ainda aceita a senha fixa que estava no SQL antigo.
- **Instalador na raiz:** o `init-new-db.sh` move sozinho o `.jar` da raiz para `instalador/`; o `doctor.sh` avisa. Num `docker compose build` direto, a mensagem de erro indica a pasta.
- **`LAN_IP`:** o `doctor.sh` avisa quando o `.env` antigo tem `LAN_IP` e nenhum `POSTGRES_BIND_IP`.
- **SCRAM no lugar de md5** para senhas novas. Bancos existentes continuam aceitando as senhas md5 até a próxima troca (`trocar-senhas.sh` regrava em SCRAM).
- **Locale pt-BR só vale para volumes novos.** Um banco já criado mantém o locale original; para mudar, faça backup, apague `volumes/pg_data` e restaure.
- **A JVM roda como usuário `pec` (uid 10001).** O entrypoint ajusta o dono de `volumes/pec_*` na subida.
- Healthcheck em `/api/public/info`, com 5 minutos de tolerância na subida.
- Nome do dump: `esus_<banco>_<data>.backup` (antes `esus_backup_<data>.backup`). O `restore.sh` aceita os dois.
- Imagem com o nome `esus-pec-docker:<PEC_IMAGE_TAG>`.
- `sql/01-init-esus-leitura.sql` virou `sql/esus-leitura.sql` (idempotente) + `sql/01-init-esus-leitura.sh`.
