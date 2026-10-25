# Documentação

O [README principal](../README.md) é o guia rápido: instalar, adicionar
projeto, testar o deploy. Aqui está o **como funciona** de cada parte, mais o
material de estudo e treino.

## Referência

| Doc | Conteúdo |
| --- | -------- |
| [01-visao-geral.md](01-visao-geral.md) | o que é a plataforma, componentes, caminho de uma mudança até prod, domínios, limites do lab |
| [02-instalacao.md](02-instalacao.md) | pré-requisitos, etapas do `make setup`, `.env`, operação do dia a dia |
| [03-projetos.md](03-projetos.md) | anatomia de um projeto, `project.yaml`, Secrets da plataforma, values, como adicionar projeto/app/ambiente/microfrontend |
| [04-gitops-argocd.md](04-gitops-argocd.md) | GitOps, o ApplicationSet genérico, sync, selfHeal, rollback pelo Git |
| [05-ci-cd.md](05-ci-cd.md) | branches e ambientes, pipeline (plan → test → build → deploy → ci), `APPS_JSON`, Dockerfiles, Trivy, CodeQL, Dependabot |
| [06-observabilidade.md](06-observabilidade.md) | dashboard *Platform / Apps*, PromQL e LogQL úteis, componentes |
| [07-scripts.md](07-scripts.md) | o que cada script e cada comando do Makefile faz, e como se encadeiam |
| [08-troubleshooting.md](08-troubleshooting.md) | problemas reais que já aconteceram, com causa e solução |
| [09-cheatsheet.md](09-cheatsheet.md) | comandos `make`, `kubectl` e `git` do dia a dia |
| [15-entrega-progressiva.md](15-entrega-progressiva.md) | Argo Rollouts: canary pelo NGINX, análise de 5xx no Prometheus, rollback automático, promote/abort |
| [14-seguranca.md](14-seguranca.md) | HTTPS com cert-manager e CA local, NetworkPolicies por namespace, Kyverno e Pod Security, `make policy-check` |
| [13-alertas-slo.md](13-alertas-slo.md) | SLI/SLO/error budget, alertas multi-burn-rate, Alertmanager (inibição, silêncio, notificação) e runbooks |
| [12-segredos.md](12-segredos.md) | Sealed Secrets: onde fica cada segredo, `make seal`, rotação, backup da chave e recuperação de desastre |

## Estudo e treino

| Doc | Conteúdo |
| --- | -------- |
| [10-roteiro-de-estudo.md](10-roteiro-de-estudo.md) | o que estudar e em que ordem, hábitos de operação, roteiro de evolução da plataforma |
| [11-treino-quebre-e-conserte.md](11-treino-quebre-e-conserte.md) | **19 exercícios práticos** num laboratório isolado (`make lab-up`), com sintomas reais, dicas, soluções e o conceito por trás |

## Histórico

[`legacy/`](legacy/README.md): a documentação da primeira versão (stack com
Keycloak, Kong e chart próprio do crivo), mantida só como referência.
