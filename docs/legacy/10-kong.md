# Kong + Konga

## O que é

- **Kong**: API Gateway entre o Frontend e o Backend/Auth. Faz JWT
  validation (RS256 do Keycloak), rate limiting global e por plano (lê
  claim `plan_type`), CORS, headers de segurança.
- **Konga**: UI de administração do Kong. No nosso lab serve só pra
  visualizar (Kong está em DB-less mode; a config vive em `kong.yml` no
  ConfigMap).

## Topologia

```
                                   ┌──────────────────────┐
browser ──▶ develop.api.crivo.local ──▶ Kong develop ──▶ BE develop
                                   │                  ──▶ Auth develop
                                   │
            prod.api.crivo.local   ──▶ Kong prod    ──▶ BE prod
                                   │                  ──▶ Auth prod
                                   │
            konga.devops.local     ──▶ Konga (tooling ns) ─┐
                                                          │
                                              admin API ◄─┴── http://crivo-kong.<ns>.svc:8001
```

## Kong (per-env, app do chart)

Vive em `helm/crivo-app/apps/crivo-kong/`. Os ConfigMaps com `kong.yml`
**não** são parte do chart — eles são renderizados via
`scripts/apply-kong-config.sh` (`make kong-config ENV=...`).

Motivo: o `kong.yml` contém:
- A chave pública RS256 do realm Keycloak (renovada quando o realm muda)
- Scripts Lua (rate limit por plano)

Manter o ConfigMap fora do chart deixa o reload mais rápido (rollout só
do Kong) e a chave RS256 fora do git.

### Quando re-aplicar Kong config

- Depois de `make import-realm` (realm regenera a chave RS256)
- Depois de mudar `helm/crivo-app/apps/crivo-kong/kong.tmpl.yml`
- Depois de mudar `config/keycloak.<env>.pub`

```bash
make kong-config ENV=develop
make kong-config ENV=prod
```

## Konga (única, namespace `tooling`)

Vive em [k8s/konga.yaml](../k8s/konga.yaml). Aplicado por `make setup` ou
`kubectl apply -f k8s/konga.yaml`.

Configuração:
- Imagem: `pantsel/konga:0.14.9`
- Storage: `localDiskDb` num PVC `konga-data` (sqlite + JSON)
- Pré-seedado via ConfigMap `konga-seeds` com **duas conexões**:
  - `crivo-develop` → `http://crivo-kong.crivo-develop.svc:8001`
  - `crivo-prod`    → `http://crivo-kong.crivo-prod.svc:8001`

### Acessar

```
http://konga.devops.local
```

Primeira vez pede pra criar um usuário admin local (apenas Konga; não é
o admin do Keycloak/Kong).

Depois de logado, vá em **Connections** — deve ver `crivo-develop` e
`crivo-prod` pré-cadastradas. Clica em **Activate** numa e o dashboard
passa a refletir aquele Kong (services, routes, plugins, consumers).

## Por que o Service do Kong expõe 8001

O chart `crivo-app` ganhou suporte a `extraPorts[].servicePort`. O Kong
seta:

```yaml
extraPorts:
  - name: admin
    containerPort: 8001
    servicePort: 8001
```

Service vira ClusterIP com 8000+8001 → Konga (do namespace `tooling`)
consome o `:8001` via DNS interno.

**Nota de segurança**: a porta 8001 NÃO é exposta via ingress, só
ClusterIP. Em prod real, restrinja com NetworkPolicy permitindo apenas
o namespace `tooling` (não fazemos isso no lab pra simplicidade).
