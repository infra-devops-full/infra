# Cheatsheet

`SERVICE` = nome do app (pasta em `apps/`). `NAMESPACE` = `<projeto>-<env>`.

## Plataforma

```bash
make help                          # todos os comandos
make doctor                        # confere tudo (não altera nada)
make setup | status | destroy
make start | stop | restart
make projects                      # projetos, apps e ambientes descobertos
make project-apply PROJECT=<p>     # namespaces, dependências, secrets, hosts
make github [PROJECT=<p>] [ARGS=--dry-run|--rotate|--no-protect]
make observability                 # Prometheus/Alertmanager/Grafana, Loki, Alloy, alertas, dashboards
make gen-observability             # regenera regras de alerta e dashboard de SLO (k8s/)
make apply-argocd | render-platform
make hosts                         # regrava o bloco do /etc/hosts
make helm-lint                     # valida todos os values
make helm-template PROJECT=<p> APP=<a> ENV=<e>
make seal PROJECT=<p> [ENV=<e>]   # secrets/<env>.env → sealed/<env>/ (commitar)
make sealed-secrets                # controller + backup/restauração da chave
make security                      # cert-manager + CA local, Kyverno e políticas
make trust-ca | untrust-ca         # navegador confia (ou não) na CA local (sudo)
make policy-check                  # políticas × todos os apps, sem cluster
make delivery                      # Argo Rollouts + análise padrão
make data                          # operador do Postgres + backup + storage S3
make tracing                       # Tempo + OpenTelemetry Operator (depois: make observability)
make db-status PROJECT=<p> ENV=<e> # instâncias, backups, janela de restauração
make db-backup | db-restore-test | db-psql PROJECT=<p> ENV=<e>
make db-restore PROJECT=<p> ENV=<e> [TIME="2026-10-26 14:29:00-03"]   # recria do backup (PITR)
make postgres PROJECT=<p> ENV=<e>  # recria VAZIO
make ghcr NAMESPACES="ns1 ns2" [TOKEN=...]
```

## Dia a dia

```bash
make alerts                        # alertas ativos (Alertmanager)
make policies                      # violações das políticas (Kyverno)
make rollouts                      # canaries: fase, passo, peso
make promote|abort|retry SERVICE=<app> NAMESPACE=<ns> [FULL=1]
make release PROJECT=<p> [REPO=owner/repo] [BUMP=auto|patch|minor|major]
make sso-github && make sso        # login único (GitHub via Dex)
make verify-image IMAGE=<imagem:tag>   # assinatura do CI + SBOM
make notifications-webhooks && make notifications && make notify-test   # Discord
make logos [PROJECT=<p>]           # logo do project.yaml → logo.png
make rollback PROJECT=<p> ENV=prod [APP=<app>] [TO=1.3.0]
make pods [NAMESPACE=<ns>]         # pods dos projetos
make apps                          # Applications (sync/health)
make logs     SERVICE=<a> NAMESPACE=<ns>
make describe SERVICE=<a> NAMESPACE=<ns>
make events   NAMESPACE=<ns>
make rollout  SERVICE=<a> NAMESPACE=<ns>     # reinicia (relê env e secrets)
make shell    SERVICE=<a> NAMESPACE=<ns>
make pf SERVICE=postgres NAMESPACE=<ns> PORT=5432 LOCAL=5433
make refresh [APP=<application>]   # ArgoCD relê o Git
```

## kubectl essencial

```bash
kubectl config current-context                       # k3d-devops-lab
kubectl get pods -n <ns> -o wide
kubectl get all -n <ns>
kubectl describe pod <pod> -n <ns>                   # leia os Events no fim
kubectl logs deploy/<app> -n <ns> -f --tail=100
kubectl logs <pod> -n <ns> --previous                # o container que morreu
kubectl get events -n <ns> --sort-by=.lastTimestamp
kubectl get endpoints <svc> -n <ns>                  # o Service acha pods?
kubectl get ingress -A                               # hosts publicados
kubectl rollout status|history|undo deploy/<app> -n <ns>
kubectl exec -it deploy/<app> -n <ns> -- sh
kubectl get secret <s> -n <ns> -o json | jq -r '.data | map_values(@base64d)'
kubectl get deploy -n <ns> -o custom-columns='APP:.metadata.name,IMAGE:.spec.template.spec.containers[0].image'
kubectl run tmp --rm -it --image=curlimages/curl -n <ns> -- sh      # testar de dentro do cluster
kubectl top pods -n <ns>                             # (metrics-server desligado: use o Grafana)
```

## Git do repo de infra

```bash
git config pull.rebase true          # o CI também commita na main
git pull && git push
git log --oneline -- projects/<p>/apps/<a>/values-prod.yaml   # histórico de deploys
git revert <commit-de-deploy> && git push                     # rollback
```

## Promover uma tag manualmente

```bash
TAG=$(yq '.image.tag' projects/<p>/apps/<a>/values-develop.yaml)
yq -i ".image.tag = \"$TAG\"" projects/<p>/apps/<a>/values-prod.yaml
git commit -am "deploy(<p>/prod): <a> → $TAG" && git push
```

## Laboratório

```bash
make lab-up | lab-status | lab-down
curl --resolve demo.treino.local:80:127.0.0.1 http://demo.treino.local/
```

## URLs

| | |
| - | - |
| ArgoCD | https://argocd.devops.local (admin / senha no `make status`) |
| Grafana | https://grafana.devops.local (admin / `devops.local2026`) |
| Prometheus | https://prometheus.devops.local |
| Alertmanager | https://alertmanager.devops.local |
| Rollouts | https://rollouts.devops.local (somente leitura) |
| crivo | http://develop.crivo.local · http://crivo.local |
| wlstore | http://develop.wlstore.local · http://wlstore.local |
