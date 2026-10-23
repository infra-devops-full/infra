# Observabilidade

## Os três sinais

| Sinal | Pergunta que responde | Ferramenta aqui |
| ----- | --------------------- | --------------- |
| **Métricas** | está bom? quanto? desde quando? | Prometheus (+ NGINX Ingress, cAdvisor, kube-state-metrics) |
| **Logs** | o que exatamente aconteceu? | Loki (coletado pelo Alloy) |
| **Traces** | por onde o request passou e onde demorou? | *(fase 6 do roteiro: OpenTelemetry + Tempo)* |

## Dashboard *Platform / Apps*

http://grafana.devops.local → pasta **Platform**. Filtros: **Projeto →
Ambiente → App**.

| Seção | Painéis | Fonte |
| ----- | ------- | ----- |
| Cabeçalho | logo, pods rodando, requests/s, % 5xx, erros no log | `projects/<p>/logo.png` + as fontes abaixo |
| Requests | requests/s por app, status HTTP, latência p95, erros 4xx/5xx | métricas do Ingress |
| Logs de erro | erros por app e as linhas com `error`/`exception`/`fatal`/`panic` | Loki |
| Recursos | CPU, memória, rede, restarts | cAdvisor, kube-state-metrics |
| Todos os logs | logs completos (recolhido) | Loki |

O dashboard é gerado e versionado em
[`k8s/grafana-dashboard-apps.yaml`](../k8s/grafana-dashboard-apps.yaml).
Alterações feitas pela UI não persistem.

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
| Prometheus + Grafana + Alertmanager | `setup.sh` (kube-prometheus-stack) | values inline no `setup.sh` (coleta a cada 60 s, retenção de 3 dias) |
| métricas do Ingress | `setup-observability.sh` | ServiceMonitor do ingress-nginx |
| Loki 7.3.0 (single-binary) | `setup-observability.sh` | `config/observability/loki-values.yaml` |
| Alloy 1.13.0 | `setup-observability.sh` | `config/observability/alloy-values.yaml` |
| datasource Loki + dashboard | `apply-platform.sh` | `k8s/*.yaml` (sidecars do Grafana) |

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
