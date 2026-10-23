# Ambientes

A infra suporta múltiplos ambientes através de um único `ApplicationSet` em
`argocd/applicationsets/crivo-apps.yaml`. Hoje rodamos 2 ambientes:

| Ambiente | Branch    | Namespace      | URLs                                       |
| -------- | --------- | -------------- | ------------------------------------------ |
| develop  | `develop` | `crivo-develop` | `develop.{fe,be,auth}.crivo.local`        |
| prod     | `main`    | `crivo-prod`    | `prod.{fe,be,auth}.crivo.local`           |

## Como o ambiente é montado

Cada ambiente é um par (env, branch). O ApplicationSet usa um `matrix`
generator combinando essa lista com a lista de apps:

```yaml
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
```

Para cada combinação ele cria um Application:

```
crivo-{app}-{env}
  └─ source.repoURL = repo de infra
  └─ source.targetRevision = branch
  └─ source.path = helm/crivo-app
  └─ helm.valueFiles = [apps/{app}/values.yaml, apps/{app}/values-{env}.yaml]
  └─ destination.namespace = crivo-{env}
```

## Diferenças por ambiente

O que varia entre develop/prod fica em `apps/<app>/values-<env>.yaml`:

| Aspecto         | develop                          | prod                           |
| --------------- | -------------------------------- | ------------------------------ |
| Image tag       | `develop` (atualizada pelo CI)   | `develop` *(temp)*             |
| Ingress host    | `develop.<svc>.crivo.local`      | `prod.<svc>.crivo.local`       |
| NODE_ENV        | `development`                    | `production`                   |
| LOG_LEVEL       | `debug`                          | `warn`                         |
| Swagger         | habilitado                       | desabilitado                   |
| PDB             | desabilitado                     | habilitado                     |
| Keycloak URLs   | apontam pra `develop.auth.*`     | apontam pra `prod.auth.*`      |

## Secrets por ambiente

Cada ambiente tem seu próprio conjunto de Secrets, criado a partir de
`config/secrets.<env>.env` (gitignored) via:

```bash
make secrets ENV=develop
make secrets ENV=prod
```

Veja os Secrets esperados em [README.md](README.md#secrets).

## Adicionar um ambiente novo (ex.: staging)

1. Crie a branch `staging` no GitHub.

2. Adicione ao ApplicationSet:
   ```yaml
   # argocd/applicationsets/crivo-apps.yaml
   - env: staging
     branch: staging
   ```

3. Adicione um AppProject em `argocd/projects/crivo-environments.yaml`:
   ```yaml
   apiVersion: argoproj.io/v1alpha1
   kind: AppProject
   metadata:
     name: crivo-staging
     namespace: argocd
   spec:
     sourceRepos: [https://github.com/geraldobl58/infra.git]
     destinations:
       - namespace: crivo-staging
         server: https://kubernetes.default.svc
   ```

4. Crie `values-staging.yaml` em cada app (`helm/crivo-app/apps/<app>/`).

5. Crie os secrets:
   ```bash
   cp config/secrets.develop.env.example config/secrets.staging.env
   $EDITOR config/secrets.staging.env
   make secrets ENV=staging
   ```

6. Adicione ao `/etc/hosts`:
   ```
   127.0.0.1 staging.fe.crivo.local
   127.0.0.1 staging.be.crivo.local
   127.0.0.1 staging.auth.crivo.local
   ```

7. Commit + push. O ApplicationSet cria os 3 Applications automaticamente.

## Git flow

```
feature/* ──┐
            ├──▶ develop  ───▶ branch develop  ───▶ crivo-develop
            ▼
          main      ───────▶ branch main     ───▶ crivo-prod
```

Promoção develop → prod hoje é PR de `develop` em `main`. Quando o merge
acontece, ArgoCD sincroniza automaticamente.
