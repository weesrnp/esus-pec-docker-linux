# Pasta do instalador oficial

Coloque aqui o `eSUS-AB-PEC-X.Y.Z-Linux64.jar` (ou rode `./scripts/get-latest-pec.sh --download`, que baixa para cá).

O `.jar` não é versionado (`.gitignore`). O nome do arquivo usado no build vem de `PEC_JAR_FILE` no `.env`.

O instalador fica numa pasta própria porque o contexto de build do Docker só inclui esta pasta e o entrypoint. Com o arquivo na raiz do projeto, o Docker precisaria percorrer `volumes/pg_data`, que pertence ao usuário do PostgreSQL, e o build falharia com "permission denied".
