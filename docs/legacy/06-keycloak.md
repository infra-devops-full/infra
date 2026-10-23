# Keycloak

O Keycloak roda como mais uma app do chart `crivo-app` (em
`helm/crivo-app/apps/crivo-auth/`). Esta página cobre o que é específico
dele.

## Configuração do realm

O Keycloak novo (no cluster) **não** tem o realm `crivo` configurado por
padrão. Há 3 maneiras de povoá-lo:

### Opção 1 — Importar realm.json (recomendado)

Se você já tem um Keycloak (docker-compose antigo, outro ambiente) com o
realm configurado, exporte e importe:

```bash
# 1. Exportar do Keycloak antigo (docker-compose). Subir só o necessário:
cd ~/Development/fullstack/crivo
docker compose -f infra/docker/docker-compose.yml up -d postgres keycloak
# (espera o Keycloak healthy ~60s)
docker exec crivo-auth-dev /opt/keycloak/bin/kc.sh export \
  --realm crivo --file /tmp/realm.json --users same_file
docker cp crivo-auth-dev:/tmp/realm.json ~/crivo-realm.json
docker compose -f infra/docker/docker-compose.yml down

# 2. Importar no Keycloak do cluster:
cd ~/Development/infra
make import-realm ENV=develop FILE=~/crivo-realm.json
make import-realm ENV=prod    FILE=~/crivo-realm.json
```

O script cria um ConfigMap `keycloak-realm-import` no namespace e
reinicia o Keycloak.

**Estratégia de import**: `OVERWRITE_EXISTING`. A cada restart, o realm
é re-aplicado com o conteúdo do `realm.json`. Como o Postgres usa
emptyDir (volátil), isso garante que o realm sempre volta ao estado
versionado. Para mudanças no realm:

1. Edite via UI do Keycloak.
2. Exporte de novo (`kc.sh export`).
3. Substitua `~/crivo-realm.json`.
4. `make import-realm ENV=develop FILE=~/crivo-realm.json`.

### Opção 2 — Criar via UI

```
http://develop.auth.crivo.local/admin
  user: admin
  pass: admin (ou o KC_BOOTSTRAP_ADMIN_PASSWORD do seu secret)
```

1. Dropdown realm → **Create Realm** → `crivo`.
2. Clients → Create:
   - `crivo-web`: client público (FE), redirect URI `http://develop.fe.crivo.local/*`
   - `crivo-api`: client confidential (BE), service account habilitado
3. Em **Client scopes** → **crivo-api-dedicated** (ou outro mapper de
   client) adicione um *Protocol Mapper* `User Attribute → plan_type`
   para popular o claim `plan_type` no JWT (lido pelo Kong para rate
   limiting).

### Opção 3 — Pular Keycloak realm e usar dev-token do BE

O `crivo-be` expõe `/auth/dev-token` (controller `AuthDevController`)
para development. Útil pra testar APIs sem subir o fluxo completo.

## Estrutura esperada do realm `crivo`

| Item                          | Detalhe                                              |
| ----------------------------- | ---------------------------------------------------- |
| Realm name                    | `crivo`                                              |
| Client `crivo-web`            | Tipo `public` (PKCE), FE Next.js + Better Auth       |
| Client `crivo-api`            | Tipo `confidential`, service account, BE NestJS      |
| Protocol Mapper `plan_type`   | Lê atributo do user, injeta como claim `plan_type` (TRIAL/BASIC/PROFESSIONAL/ENTERPRISE) |

### Redirect URIs esperados no `crivo-web`

Better Auth (`genericOAuth/keycloak`) usa o callback
`/api/auth/oauth2/callback/keycloak`. Inclua para cada ambiente:

```
http://develop.fe.crivo.local/*
http://develop.fe.crivo.local/api/auth/callback/keycloak
http://develop.fe.crivo.local/api/auth/oauth2/callback/keycloak
http://prod.fe.crivo.local/*
http://prod.fe.crivo.local/api/auth/callback/keycloak
http://prod.fe.crivo.local/api/auth/oauth2/callback/keycloak
```

E `Web Origins` correspondentes (`http://develop.fe.crivo.local`,
`http://prod.fe.crivo.local`).

## Renovar a chave do Kong após mudar o realm

Toda vez que você re-importa ou rotaciona a chave RS256 do realm, o Kong
precisa da chave pública nova:

```bash
curl http://develop.auth.crivo.local/realms/crivo/protocol/openid-connect/certs \
  | jq -r '.keys[] | select(.alg=="RS256") | .x5c[0]' \
  > config/keycloak.develop.pub
make kong-config ENV=develop
```

## Probes na porta 9000

Keycloak 26 expõe `/health/*` apenas na porta **management** (9000), não
na HTTP (8080). Os probes do chart já apontam corretamente — atenção se
estiver depurando manualmente.

## Tempo de boot

`start-dev` em modo lab demora 60-90s. As migrations do schema do
Keycloak (Liquibase) rodam no primeiro boot e podem demorar mais.
