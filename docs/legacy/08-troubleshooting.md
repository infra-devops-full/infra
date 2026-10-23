# Troubleshooting

## Application fica `OutOfSync` indefinidamente

Causa comum: o `spec.selector` do Deployment é imutável. Se você mudou
labels (`app.kubernetes.io/instance`, etc.) num chart já implantado, o
patch falha.

```bash
kubectl describe app <app-name> -n argocd | grep -A 2 "Message:"
# Procure por: 'Invalid value: ...selector: field is immutable'
```

**Solução**: apague o Deployment, Argo recria com as labels novas.

```bash
kubectl delete deploy <name> -n <namespace>
kubectl annotate app <app-name> -n argocd argocd.argoproj.io/refresh=hard --overwrite
```

## FE no browser tentando `http://localhost:8000/api/...` (ou outro host errado)

`NEXT_PUBLIC_*` em Next.js são **inlined no JS no momento do `next build`**,
não lidos do `env` em runtime. Setar essas variáveis via Helm values só
afeta SSR; o JS que vai pro browser já tem o valor "congelado" do build.

Onde corrigir:
1. `apps/crivo-fe/Dockerfile` — declare `ARG NEXT_PUBLIC_*` e `ENV` nas
   stages `build`.
2. `.github/workflows/pipeline.yml` — passe os valores como `build-args`
   na etapa `docker/build-push-action`, com um valor diferente por
   ambiente.

Para confirmar qual valor a imagem atual tem embedded:
```bash
kubectl exec -n crivo-develop deploy/crivo-fe -- \
  grep -rh 'localhost:8000\|develop.api' /app/apps/crivo-fe/.next 2>/dev/null | head -3
```

Se trocar `NEXT_PUBLIC_API_URL` em values e nada mudar no browser — é
isso. Precisa rebuild da imagem.

## Pod do `crivo-be` falha com `relation "public.Plan" does not exist`

Faltam migrations do Prisma. Hoje rodamos manualmente porque a imagem
runtime não inclui `prisma.config.ts` (corrigido no Dockerfile, mas
depende da próxima build no CI).

```bash
# port-forward pra rodar local apontando pro cluster
kubectl port-forward -n crivo-develop svc/postgres 5432:5432 &
cd ~/Development/fullstack/crivo/apps/crivo-be
DATABASE_URL='postgresql://crivo:crivo_password@127.0.0.1:5432/crivo_app?schema=public' \
  npx prisma migrate deploy
kill %1
```

Quando a imagem nova sair, reative o init container nos values:

```yaml
# helm/crivo-app/apps/crivo-be/values-<env>.yaml
initContainers:
  - name: prisma-migrate
    command: ["sh", "-c", "npx prisma migrate deploy"]
```

(O default em `apps/crivo-be/values.yaml` já habilita. Em `values-<env>.yaml`
hoje há `initContainers: []` desativando — basta remover essa linha.)

## Keycloak: `503 Service Temporarily Unavailable` no admin console

Causas comuns:
1. Pod ainda subindo (Keycloak 26 demora 1-2min no `start-dev`).
2. Probe configurado na porta errada (deve ser `management` = 9000, não `http` = 8080).
3. Conflito `KC_HOSTNAME` + `KC_HOSTNAME_URL` no env (use só `KC_HOSTNAME_URL`).

```bash
kubectl logs -n crivo-develop deploy/crivo-auth --tail=30
```

Procure por:
- `started in X.Xs` → tudo OK, é só esperar.
- `You can not set both 'hostname' and 'hostname-url'` → remover `KC_HOSTNAME` dos values.

## Pods em `ImagePullBackOff`

```bash
kubectl describe pod <pod> -n <ns> | grep -A 3 Failed
```

Possibilidades:

- **Tag não existe**: a tag que está em `values-<env>.yaml` não foi
  publicada no GHCR. Confirme em https://github.com/users/geraldobl58/packages
  ou rode o pipeline CI da branch correspondente.
- **Sem `ghcr-secret`**: rode `./create-ghcr-secrets.sh`.
- **GitHub token expirado**: gere um novo em
  https://github.com/settings/tokens, atualize `.env`, rode
  `./create-ghcr-secrets.sh`.

## Postgres em `CrashLoopBackOff` com avalanche de `find: ... Operation not permitted` (arquivos `._*`)

Causa: macOS criou arquivos AppleDouble metadata (`._*`) no path do PV do
`local-path` provisioner do k3d. Acontece especialmente após `make stop`/`make start`.

**Solução permanente já aplicada**: o Postgres tem um `initContainer`
`cleanup-macos-metadata` que apaga `._*` e `.DS_Store` antes de subir o
container principal. Veja [`scripts/setup-postgres.sh`](../scripts/setup-postgres.sh).

Se ainda assim travar, force reset:
```bash
make postgres ENV=develop RESET_DATA=1   # apaga PVC e recria
make migrate ENV=develop                  # remigração Prisma
make seed ENV=develop                     # repopula plans
make import-realm ENV=develop FILE=...    # reimporta realm Keycloak
```

## Pod do Postgres em `Pending` com `persistentvolumeclaim "postgres-pvc" not found`

PVC não foi criado. Crie manualmente:

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgres-pvc
  namespace: crivo-prod
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: local-path
  resources:
    requests:
      storage: 5Gi
EOF
```

## Pod do Postgres em `ContainerCreating` com `configmap "postgres-init" not found`

```bash
# Copia o configmap do ambiente que funciona
kubectl get cm postgres-init -n crivo-develop -o yaml | \
  yq eval 'del(.metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp, .metadata.managedFields) | .metadata.namespace = "crivo-prod"' - | \
  kubectl apply -f -

# Mata o pod pra recriar (kubelet cacheia o mount falho)
kubectl delete pod -n crivo-prod -l app=postgres
```

## App `Synced` mas `Degraded`

Pode ser readiness probe falhando. Confira:

```bash
kubectl describe app <name> -n argocd | grep -A 5 "Health:"
kubectl get events -n <namespace> --sort-by='.lastTimestamp' | tail -20
```

## /etc/hosts errado / 404 no browser mas curl com Host funciona

Cache de DNS do macOS pode ser teimoso:

```bash
sudo dscacheutil -flushcache
sudo killall -HUP mDNSResponder
```

E confirme que `/etc/hosts` tem só uma linha por host (sem duplicatas).

## Saber o que está em sync com o git agora

```bash
kubectl get app -n argocd -o custom-columns=\
NAME:.metadata.name,REV:.status.sync.revision,STATUS:.status.sync.status,HEALTH:.status.health.status
```

## Comparar values renderizado entre develop e prod

```bash
diff \
  <(make helm-template APP=crivo-be ENV=develop) \
  <(make helm-template APP=crivo-be ENV=prod)
```

## ArgoCD não sincroniza após commit no repo do crivo

O fluxo é em duas etapas: commit no crivo → CI builda imagem → CI commita
novo image tag no values do infra → ArgoCD vê mudança no infra → sync.

Se o ArgoCD continua mostrando revision antiga, depure a etapa do CI:

```bash
# Última run do pipeline
gh api 'repos/geraldobl58/crivo/actions/runs?per_page=1' \
  | jq '.workflow_runs[0] | {id, status, conclusion, head_sha}'

# Pegar o id do job Deploy:
gh api 'repos/geraldobl58/crivo/actions/runs/<id>/jobs' \
  | jq '.jobs[] | select(.name|contains("Deploy")) | .id'

# Ler log do Deploy:
gh api 'repos/geraldobl58/crivo/actions/jobs/<job-id>/logs' \
  | grep -E "Updated|Values file not found|No changes|denied|fatal"
```

Sintomas vs causa:

| Log diz... | Causa | Fix |
|------------|-------|-----|
| `Values file not found` | path no awk errado | corrigir caminho no pipeline.yml |
| `No changes to commit` | awk não substituiu (regex não bate) | tag no values em formato inesperado |
| `denied` / `403` | `INFRA_GH_TOKEN` sem `repo` scope | rotacionar token |
| `Updated ... + Deployed` mas Argo não sync | branch errada no checkout do infra | conferir `ref:` |

## Métricas no Grafana mostram "No data"

Causa comum: filtro de namespace no dashboard JSON aponta para namespace
inexistente (ex.: `namespace=~"devops-.*"` quando os namespaces são `crivo-.*`).

```bash
# Ver quais namespaces o dashboard espera:
kubectl get cm -n monitoring devops-dashboard-backend -o jsonpath='{.data}' \
  | grep -oE 'namespace=~"[^"]*"' | sort -u
```

Se aparecer `devops-.*` ou outro padrão antigo, edite
`k8s/grafana-dashboard-apps.yaml` e reaplique.

Para validar que Prometheus está coletando dos apps:

```bash
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090 &
curl -s 'http://localhost:9090/api/v1/targets?state=active' \
  | jq '.data.activeTargets[] | select(.scrapePool|contains("crivo")) | {pool: .scrapePool, health, error: .lastError}'
```
