# Cheatsheet

## Make targets

```
make setup                                # setup completo da infra (1x)
make secrets ENV=develop                  # aplica/atualiza Secrets de um ambiente
make apply-argocd                         # reaplica AppProjects + ApplicationSet
make helm-lint                            # lint do chart contra todos os values
make helm-template APP=crivo-be ENV=develop   # renderiza pra inspecionar

make logs SERVICE=crivo-be NAMESPACE=crivo-develop
make status
make argocd grafana prometheus            # abre as UIs

make start | stop | restart | destroy
```

## kubectl

```bash
# Listar apps gerenciadas
kubectl get app -n argocd

# Force-sync uma app
kubectl annotate app crivo-be-develop -n argocd \
  argocd.argoproj.io/refresh=hard --overwrite

# Reiniciar todos os pods de uma app
kubectl rollout restart deploy/crivo-be -n crivo-develop

# Ver logs de uma init container falhando
kubectl logs <pod> -n <ns> -c <init-container-name>

# Port-forward pro Postgres local
kubectl port-forward -n crivo-develop svc/postgres 5432:5432

# Exec dentro do Postgres
kubectl exec -it -n crivo-develop deploy/postgres -- \
  psql -U crivo -d crivo_app
```

## Helm

```bash
# Renderizar uma combinação app/env sem aplicar
helm template crivo-be helm/crivo-app \
  -f helm/crivo-app/apps/crivo-be/values.yaml \
  -f helm/crivo-app/apps/crivo-be/values-develop.yaml

# Lint
helm lint helm/crivo-app \
  -f helm/crivo-app/apps/crivo-be/values.yaml \
  -f helm/crivo-app/apps/crivo-be/values-develop.yaml
```

## ArgoCD CLI (opcional)

```bash
# Login
argocd login argocd.devops.local

# Listar apps
argocd app list

# Sync com detalhes
argocd app sync crivo-be-develop --prune

# Ver diff entre git e cluster
argocd app diff crivo-be-develop
```

## Postgres

```bash
# Listar bancos
kubectl exec -n crivo-develop deploy/postgres -- psql -U crivo -l

# Conectar local via port-forward
kubectl port-forward -n crivo-develop svc/postgres 5432:5432 &
psql postgresql://crivo:crivo_password@127.0.0.1:5432/crivo_app

# Rodar migrations (de fora)
cd ~/Development/fullstack/crivo/apps/crivo-be
DATABASE_URL='postgresql://crivo:crivo_password@127.0.0.1:5432/crivo_app?schema=public' \
  npx prisma migrate deploy
```

## /etc/hosts esperado

```
# DevOps Lab - Ferramentas
127.0.0.1 argocd.devops.local
127.0.0.1 grafana.devops.local
127.0.0.1 prometheus.devops.local
127.0.0.1 alertmanager.devops.local
# Crivo - Apps (develop)
127.0.0.1 develop.auth.crivo.local
127.0.0.1 develop.be.crivo.local
127.0.0.1 develop.fe.crivo.local
# Crivo - Apps (prod)
127.0.0.1 prod.auth.crivo.local
127.0.0.1 prod.be.crivo.local
127.0.0.1 prod.fe.crivo.local
```
