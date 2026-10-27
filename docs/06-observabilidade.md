# Observabilidade

## Os três sinais

| Sinal | Pergunta que responde | Ferramenta aqui |
| ----- | --------------------- | --------------- |
| **Métricas** | está bom? quanto? desde quando? | Prometheus (+ NGINX Ingress, cAdvisor, kube-state-metrics) |
| **Logs** | o que exatamente aconteceu? | Loki (coletado pelo Alloy) |
| **Traces** | por onde o request passou e onde demorou? | Tempo, via agentes OpenTelemetry ([22-tracing.md](22-tracing.md)) |

## Página inicial: *Platform / Início*

Ao abrir o Grafana (https://grafana.devops.local), a home é o
**Platform / Início**: logo, atalhos para os dashboards e ferramentas, e
o estado geral da plataforma, cada número clicável para os detalhes:

| Linha | O quê |
| ----- | ----- |
| Agora | apps falhando (ArgoCD), alertas disparando, disponibilidade 24h, requests/s, canaries em andamento, certificados vencendo em 14 dias |
| | Applications, pods, CPU e memória do cluster, mensagens paradas no RabbitMQ, erros no log na última hora |
| Projetos | saúde/sync de cada app, requests/s e taxa de 5xx por projeto |
| Recursos e logs | CPU e memória por namespace de projeto, erros no log por projeto (Loki) |
| Alertas ativos | tabela com severidade, projeto, ambiente e app |

## Dashboards de infraestrutura (pasta *Infra*)

Dashboards conhecidos da comunidade (grafana.com), em revisão fixa,
apontados para o nosso Prometheus e com o cabeçalho da plataforma:

| Dashboard | Base | Fonte das métricas |
| --------- | ---- | ------------------ |
| Infra / Nodes | [Node Exporter Full (1860)](https://grafana.com/grafana/dashboards/1860) | node-exporter (kube-prometheus-stack) |
| Infra / Kubernetes | [K8S Dashboard (15661)](https://grafana.com/grafana/dashboards/15661) | kube-state-metrics + cAdvisor |
| Infra / ArgoCD | [ArgoCD (14584)](https://grafana.com/grafana/dashboards/14584) | ServiceMonitors do controller, server e repo-server |
| Infra / RabbitMQ | [RabbitMQ-Overview (10991)](https://grafana.com/grafana/dashboards/10991) | plugin `rabbitmq_prometheus` (porta 15692) + ServiceMonitor criado pelo `setup-rabbitmq.sh` |

Gerados por `scripts/dev/gen-grafana.py` (`make gen-observability`), que
baixa cada um na revisão de `COMMUNITY`, troca o datasource e adiciona o
cabeçalho. Para atualizar: mude a revisão e rode de novo. O logo vem de
`config/branding/platform-logo.png` no GitHub (aparece depois do push).

> Os ConfigMaps dos dashboards passam de 200 KB. Por isso o
> `apply-platform.sh` usa *server-side apply*: o `kubectl apply` comum guarda
> uma cópia do objeto numa annotation limitada a 256 KB.

## Dashboard *Platform / Apps*

http://grafana.devops.local → pasta **Platform**. Filtros: **Projeto →
Ambiente → App**.

| Seção | Painéis | Fonte |
| ----- | ------- | ----- |
| Cabeçalho | logo, pods rodando, requests/s, % 5xx, erros no log | `projects/<p>/logo.png` + as fontes abaixo |
| Traces (Tempo) | mapa de serviços (quem chama quem) e traces recentes, com link | Tempo (apps com `tracing.enabled`, [22-tracing.md](22-tracing.md)) |

O filtro **App** lista os donos dos ReplicaSets do namespace
(`kube_replicaset_owner`): Deployments (develop e dependências) **e**
Rollouts (apps em prod, com canary).

### Logo do projeto

O logo vem de `projects/<p>/logo.png` **no GitHub**. Para trocar:

```bash
# no project.yaml:  logo: https://avatars.githubusercontent.com/u/<id>?v=4
#   (avatar da org: gh api orgs/<org> -q .avatar_url)
make logos PROJECT=<p>        # baixa, converte para PNG 256x256 em logo.png
git add projects/<p> && git commit -m "chore(<p>): logo" && git push
```

Não troque o logo editando o painel pela interface do Grafana: a mudança
fica só no banco dele, vale para todos os projetos de uma vez (o painel é o
mesmo) e é sobrescrita quando o dashboard do Git muda.

### O que fica salvo no Grafana

O Grafana tem disco próprio (PVC de 1 Gi, `local-path`, dentro do
`DATA_DIR`): usuários do login único, preferências, favoritos e anotações
sobrevivem a reinícios. **Dashboards** são do Git
(`k8s/grafana-dashboard-*.yaml`): edite lá, ou edite pela UI para testar e
depois copie o JSON (*Share → Export*) para o arquivo.
| Requests | requests/s por app, status HTTP, latência p95, erros 4xx/5xx | métricas do Ingress |
| Logs de erro | erros por app e as linhas com `error`/`exception`/`fatal`/`panic` | Loki |
| Recursos | CPU, memória, rede, restarts | cAdvisor, kube-state-metrics |
| Todos os logs | logs completos (recolhido) | Loki |

O dashboard é gerado e versionado em
[`k8s/grafana-dashboard-apps.yaml`](../k8s/grafana-dashboard-apps.yaml).
Alterações feitas pela UI não persistem.

## Dashboard *Platform / SLOs e alertas*

Disponibilidade em 7 dias, error budget restante, burn rate por app e os
alertas ativos. Conceitos, regras e runbooks em
[13-alertas-slo.md](13-alertas-slo.md).

## PromQL: o mínimo útil

```promql
# requests/s por app de um projeto-ambiente
sum by (ingress) (rate(nginx_ingress_controller_requests{exported_namespace="wlstore-develop"}[5m]))

# % de 5xx
100 * sum(rate(nginx_ingress_controller_requests{exported_namespace="crivo-prod", status=~"5.."}[5m]))
    / sum(rate(nginx_ingress_controller_requests{exported_namespace="crivo-prod"}[5m]))

# latência p95 por app
histogram_quantile(0.95, sum by (le, ingress) (
  rate(nginx_ingress_controller_request_duration_seconds_bucket{exported_namespace="crivo-develop"}[5m])))

# memória por pod
sum by (pod) (container_memory_working_set_bytes{namespace="crivo-develop", container!=""})

# pods que reiniciaram na última hora
increase(kube_pod_container_status_restarts_total{namespace="wlstore-develop"}[1h]) > 0
```

- `rate(...[5m])` transforma um contador em "por segundo". Use janelas de pelo
  menos 4× o intervalo de coleta (60 s aqui). Nos painéis, use
  `$__rate_interval`.
- As métricas do Ingress usam `exported_namespace` (o namespace do app) e
  `ingress` (o nome do app).

## LogQL: o mínimo útil

Em **Explore → Loki**:

```logql
{project="wlstore", env="develop", app="catalog-service"}             # todos os logs do app
{namespace="crivo-develop", app="crivo-be"} |= "nao-existe"            # contém o texto
{project="crivo"} |~ `(?i)\b(error|exception)\b`                        # regex, sem diferenciar maiúsculas
{app="crivo-be"} | json | req_url="/health"                             # logs JSON: filtra por campo
sum by (app) (count_over_time({project="wlstore"} |~ "(?i)error" [5m])) # contagem (vira gráfico)
```

Labels disponíveis: `project`, `env`, `app`, `namespace`, `pod`, `container`.

## Componentes e arquivos

| Componente | Instalação | Configuração |
| ---------- | ---------- | ------------ |
| Prometheus + Grafana + Alertmanager | `setup-observability.sh` (kube-prometheus-stack 92.11.0) | `config/observability/kube-prometheus-stack-values.yaml` (coleta a cada 60 s, retenção de 7 dias, rotas do Alertmanager) |
| métricas do Ingress | `setup-observability.sh` | ServiceMonitor do ingress-nginx |
| métricas do ArgoCD | `setup-observability.sh` | ServiceMonitor do application-controller |
| regras de SLO e alertas | `apply-platform.sh` | `k8s/prometheus-rules-apps.yaml` (gerado por `scripts/dev/gen-prometheus-rules.py`) |
| Loki 7.3.0 (single-binary) | `setup-observability.sh` | `config/observability/loki-values.yaml` |
| Alloy 1.13.0 | `setup-observability.sh` | `config/observability/alloy-values.yaml` |
| datasource Loki + dashboards | `apply-platform.sh` | `k8s/*.yaml` (sidecars do Grafana); home em `grafana.ini` → `default_home_dashboard_path` |
| métricas do cert-manager e do RabbitMQ | `setup-observability.sh` / `setup-rabbitmq.sh` | ServiceMonitors |
| Tempo 3.1 + OpenTelemetry Operator | `setup-tracing.sh` (`make tracing`) | `config/tracing/*.yaml`, `k8s/otel-instrumentation.yaml`, `k8s/grafana-datasource-tempo.yaml`; o Alloy recebe os spans (OTLP) |

Reinstalar/atualizar num cluster existente: `make observability`.

## Métricas do próprio app (opcional)

Se o app expõe métricas Prometheus em `/metrics` (por exemplo, `prom-client`
no Node ou Micrometer/actuator no Spring), habilite no `values.yaml`:

```yaml
metrics:
  enabled: true
  path: /metrics
  serviceMonitor:
    enabled: true
```

O chart cria o ServiceMonitor, e o Prometheus passa a coletar.
