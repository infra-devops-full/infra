# ArgoCD

A camada GitOps. Argo lê os manifests deste repo e mantém o cluster
sincronizado.

## O que está no cluster

| Objeto                                | Onde                                                  |
| ------------------------------------- | ----------------------------------------------------- |
| `ApplicationSet crivo-apps`           | [`argocd/applicationsets/crivo-apps.yaml`](../argocd/applicationsets/crivo-apps.yaml) |
| `AppProject crivo-develop`, `crivo-prod` | [`argocd/projects/crivo-environments.yaml`](../argocd/projects/crivo-environments.yaml) |
| Applications geradas pelo ApplicationSet | criadas automaticamente, não em git                |

## ApplicationSet

```yaml
spec:
  goTemplate: true
  generators:
    - matrix:
        generators:
          - list:
              elements:
                - env: develop
                  branch: develop
                - env: prod
                  branch: main
          - list:
              elements:
                - app: crivo-auth
                - app: crivo-be
                - app: crivo-fe
  template:
    metadata:
      name: "{{ .app }}-{{ .env }}"
    spec:
      project: "crivo-{{ .env }}"
      source:
        repoURL: https://github.com/geraldobl58/infra.git
        targetRevision: "{{ .branch }}"
        path: helm/crivo-app
        helm:
          releaseName: "{{ .app }}"
          valueFiles:
            - "apps/{{ .app }}/values.yaml"
            - "apps/{{ .app }}/values-{{ .env }}.yaml"
      destination:
        server: https://kubernetes.default.svc
        namespace: "crivo-{{ .env }}"
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
          - PruneLast=true
          - ServerSideApply=true
```

Resultado: 3 apps × 2 envs = **6 Applications**.

| Application       | Source path        | Values                                     | Namespace      |
| ----------------- | ------------------ | ------------------------------------------ | -------------- |
| crivo-auth-develop | helm/crivo-app    | apps/crivo-auth/values.yaml + values-develop.yaml | crivo-develop |
| crivo-be-develop   | helm/crivo-app    | apps/crivo-be/values.yaml + values-develop.yaml   | crivo-develop |
| crivo-fe-develop   | helm/crivo-app    | apps/crivo-fe/values.yaml + values-develop.yaml   | crivo-develop |
| crivo-auth-prod    | helm/crivo-app    | apps/crivo-auth/values.yaml + values-prod.yaml    | crivo-prod    |
| crivo-be-prod      | helm/crivo-app    | apps/crivo-be/values.yaml + values-prod.yaml      | crivo-prod    |
| crivo-fe-prod      | helm/crivo-app    | apps/crivo-fe/values.yaml + values-prod.yaml      | crivo-prod    |

## AppProjects

Cada ambiente tem um `AppProject` que limita destination namespace e
sourceRepo. É a contenção mínima para que uma Application não consiga
escrever em outro namespace por acidente.

## Sync policies

- **automated**: Argo sincroniza sem ação manual
- **prune: true**: recursos removidos do git são apagados do cluster
- **selfHeal: true**: alteração manual no cluster é revertida
- **CreateNamespace=true**: cria o namespace se faltar
- **ServerSideApply=true**: usa SSA para evitar conflitos em CRDs

Para promoção develop→prod manual, abra PR de `develop` em `main`. Ao
mergear, Argo detecta a mudança em `main` e sincroniza `crivo-prod`.

## Acessar a UI

```bash
make argocd                # abre http://argocd.devops.local
```

Login `admin`. A senha inicial:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
```

## Operações no Argo via kubectl

```bash
# Listar Applications
kubectl get app -n argocd

# Forçar refresh + sync
kubectl annotate app crivo-be-develop -n argocd \
  argocd.argoproj.io/refresh=hard --overwrite

# Pausar auto-sync (debug)
kubectl patch app crivo-be-develop -n argocd --type=merge \
  -p '{"spec":{"syncPolicy":{"automated":null}}}'

# Religar auto-sync
kubectl patch app crivo-be-develop -n argocd --type=merge \
  -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
```

## Reaplicar a partir do git

Se você editou o ApplicationSet ou os AppProjects, reaplique:

```bash
make apply-argocd
```
