# Arquitetura

## Visão geral

```
┌─────────────────── Mac (k3d) ──────────────────────────┐
│                                                       │
│   Docker network: k3d-devops-lab                      │
│                                                       │
│   ┌──── k3s cluster (1 server + 6 agents) ─────┐      │
│   │                                            │      │
│   │   ┌─── ingress-nginx ────┐                 │      │
│   │   │  hosts .crivo.local  │                 │      │
│   │   └─────────┬────────────┘                 │      │
│   │             │                              │      │
│   │   ┌─────────▼──────────────┐               │      │
│   │   │  crivo-develop namespace│              │      │
│   │   │   crivo-fe ─┐          │               │      │
│   │   │   crivo-be ─┼─▶ postgres │             │      │
│   │   │   crivo-auth┘          │               │      │
│   │   │   secrets: crivo-be-* etc            │      │
│   │   └────────────────────────┘               │      │
│   │                                            │      │
│   │   ┌────────────────────────┐               │      │
│   │   │  crivo-prod namespace  │ (mirror)      │      │
│   │   └────────────────────────┘               │      │
│   │                                            │      │
│   │   ┌── argocd ──┐  ┌── monitoring ──┐       │      │
│   │   │  ArgoCD UI │  │  Prom + Graf   │       │      │
│   │   └────────────┘  └────────────────┘       │      │
│   └────────────────────────────────────────────┘      │
└───────────────────────────────────────────────────────┘
        │                                  │
        ▼ git push                         ▼ /etc/hosts → 127.0.0.1
   GitHub (infra)                     browser do dev
        │
        └─▶ Argo polls (3min) ou via webhook
```

## Princípios

1. **Um chart genérico (`crivo-app`) serve qualquer aplicação Crivo.**
   Tudo o que diferencia uma app da outra vive em
   `helm/crivo-app/apps/<app>/values*.yaml`. Não há chart por app.

2. **Um ApplicationSet gera todos os Applications.** Adicionar um app
   novo ou um ambiente novo é editar uma lista, não criar arquivos no
   ArgoCD.

3. **Secrets ficam fora do values.** Tudo sensível é Kubernetes Secret,
   referenciado por `envFrom`. O values só descreve config pública.

4. **Cada ambiente tem seu próprio Postgres.** Não há banco compartilhado;
   `crivo-develop` e `crivo-prod` rodam Postgres dedicado no namespace.

## Componentes

| Camada           | Tecnologia                            |
| ---------------- | ------------------------------------- |
| Cluster local    | k3d (1 server + 6 agents)             |
| Ingress          | nginx-ingress (`ingressClassName: nginx`) |
| GitOps           | ArgoCD (helm chart oficial)           |
| Monitoring       | kube-prometheus-stack (Prom + Graf)   |
| Apps             | crivo-be (NestJS), crivo-fe (Next.js), crivo-auth (Keycloak 26) |
| DB               | PostgreSQL 16 (Deployment por env)    |
| Image registry   | GHCR (`ghcr.io/geraldobl58/*`)        |

## Fluxo de deploy

```
dev push em branch develop
      │
      ▼
   GitHub Actions (CI no repo crivo)
      │ build da imagem crivo-be:develop-<sha>
      │ push GHCR
      │ atualiza helm/crivo-app/apps/crivo-be/values-develop.yaml
      │   (image.tag) e commita no repo infra branch develop
      ▼
   Argo poll do repo infra (branch develop)
      │
      ▼
   Argo sincroniza crivo-be-develop
      │
      ▼
   Deployment crivo-be no namespace crivo-develop
   é atualizado (RollingUpdate)
```

## Por que esse formato

| Decisão                   | Razão                                                          |
| ------------------------- | -------------------------------------------------------------- |
| Chart único genérico      | Adicionar app/ambiente vira N-arquivo de values, não N-chart   |
| Secrets via envFrom       | Permite rotação sem rebuild; values fica em git, secrets não   |
| ApplicationSet com matrix | Source of truth única para a topologia env×app                 |
| Postgres dentro do cluster | Resolução DNS interna estável; sem dependência da rede Docker  |
| `app.kubernetes.io/instance` = nome da app, não `<app>-<env>` | Permite selectors estáveis e múltiplas releases no mesmo namespace sem colisão |
