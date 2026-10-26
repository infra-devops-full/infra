# Roteiro de estudo e evolução

## O que estudar, em ordem

Do maior para o menor retorno. Para cada tema: onde ele aparece **neste repo**
e um exercício.

| # | Tema | Por que importa | Onde estudar aqui | Pratique |
| - | ---- | --------------- | ----------------- | -------- |
| 1 | **Debug no Kubernetes** (`describe`, `events`, `logs`) | é a maior parte do trabalho real | [11-treino](11-treino-quebre-e-conserte.md) | exercícios 1 a 10 |
| 2 | **Objetos centrais**: Pod, Deployment, Service, Ingress, Secret, ConfigMap, probes, resources | base de tudo | `charts/app/templates/` (um arquivo por objeto) | `make helm-template PROJECT=crivo APP=crivo-be ENV=develop` e leia cada objeto |
| 3 | **Redes**: DNS, portas, HTTP (404/502/503), TLS | quase todo incidente daqui foi de rede | Ingress, Service, `hosts.sh` | exercícios 2, 3, 9 e 10 |
| 4 | **Containers**: Dockerfile multi-stage, camadas, cache, arquitetura | imagem é o artefato de deploy | `templates/*/Dockerfile` | build local, `docker history <img>`, compare tamanhos |
| 5 | **GitOps / ArgoCD** | o coração da plataforma | [04-gitops-argocd](04-gitops-argocd.md), `argocd/` | exercícios 11 e 13 |
| 6 | **CI/CD (GitHub Actions)**: jobs, `needs`, matrix, permissions, secrets | é por onde todo código entra | [05-ci-cd](05-ci-cd.md), `templates/github/deploy.yml` | exercício 14; leia um run job por job |
| 7 | **Helm**: templates, values, `tpl`, helpers | empacotamento padrão de mercado | `charts/app/` | adicione um campo novo ao chart (ex.: `nodeSelector`) |
| 8 | **Observabilidade**: PromQL, LogQL, RED/USE, SLO | diagnóstico pelo dado, não pelo palpite | [06-observabilidade](06-observabilidade.md) | exercício 12; crie um painel seu |
| 9 | **Segurança**: menor privilégio, segredos, cadeia de suprimentos | o que separa lab de produção | [05-ci-cd](05-ci-cd.md#segurança) | ler um alerta do Trivy e do CodeQL de ponta a ponta |
| 10 | **Shell/Bash** (ler, não decorar) | automação e scripts da plataforma | [07-scripts](07-scripts.md) | rodar `hosts.sh show`, `apply-platform.sh --render` |
| 11 | **Terraform + nuvem** | infra como código fora do lab | fase 7 abaixo | depois de 1 a 9 |

## Hábitos de quem opera produção

- **Mudança só pelo Git.** `kubectl edit` é para diagnóstico.
- **Sintoma → evidência → causa → correção → prevenção.** Escreva um
  mini-postmortem para cada problema que resolver.
- **Leia os eventos antes dos logs**, e os logs antes de mudar código.
- **Teste localmente o que vai para o CI** (o comando `test` do `APPS_JSON`).
- **Uma mudança por vez**, e observe o efeito no Grafana.

## Roteiro de evolução da plataforma

| Fase | Entrega | Status |
| ---- | ------- | ------ |
| 1 | CI com lint + testes + Trivy + CodeQL + Dependabot, check `ci` obrigatório | ✅ feito |
| 2 | **Sealed Secrets**: senhas fora do Git, segredos selados e aplicados pelo ArgoCD, backup da chave | ✅ feito |
| 3 | **Alertas + SLOs**: SLO de 99,5% por app, alertas multi-burn-rate, latência, app fora, ArgoCD; dashboard de SLO; notificação pronta para plugar | ✅ feito |
| 4 | **HTTPS + NetworkPolicy + Kyverno**: Kubernetes 1.34, cert-manager com CA local, default-deny por namespace, Pod Security, políticas de admissão testadas no CI | ✅ feito |
| 5 | **Argo Rollouts**: canary em prod (20% → 50% → 100%) com análise de 5xx no Prometheus e rollback automático | ✅ feito |
| 5.1 | **Releases**: versão semântica, changelog, prod só por release (mesma imagem de develop), `make rollback` | ✅ feito |
| 5.2 | **SSO e RBAC**: login GitHub (Dex) no ArgoCD, Grafana, Prometheus, Alertmanager e Rollouts; perfis admin / dev do projeto / leitura por time | ✅ pronto (falta o OAuth App) |
| 5.3 | **Assinatura de imagem**: cosign keyless + SBOM atestado no CI, Kyverno verificando (Audit → Deny) | ✅ feito |
| 5.4 | **Notificações**: Discord com 3 canais (#alertas, #alertas-develop, #deploys), webhooks selados | ✅ pronto (falta selar os webhooks) |
| 5.5 | **Dados persistentes**: Postgres com operador (CloudNativePG), backup e restore testado | próximo |
| 6 | **Tracing**: OpenTelemetry + Tempo (front → API → RabbitMQ → serviço) | |
| 7 | **Nuvem**: Terraform, cluster de prod separado, banco gerenciado, DNS/TLS reais, backup (Velero); guia para AWS, DigitalOcean e VPS | |
