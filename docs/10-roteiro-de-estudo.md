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
| 4 | **HTTPS + NetworkPolicy + Kyverno**: cert-manager, isolamento entre namespaces, políticas de admissão | próximo |
| 5 | **Argo Rollouts**: canary com rollback automático por métricas | |
| 6 | **Tracing**: OpenTelemetry + Tempo (front → API → RabbitMQ → serviço) | |
| 7 | **Nuvem**: Terraform, cluster de prod separado, banco gerenciado, DNS/TLS reais, backup (Velero); guia para AWS, DigitalOcean e VPS | |
