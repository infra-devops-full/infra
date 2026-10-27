# Tracing distribuído (OpenTelemetry + Tempo)

## Para que serve

Métricas dizem **que** algo está lento ou falhando ("p95 do catalog subiu para
2s"). Logs dizem **o que** um serviço registrou. O trace mostra **onde**: o
caminho de uma requisição por todos os serviços, com o tempo de cada etapa.

```
PUT /api/v1/products/42                              1.74s   (exemplo)
└─ catalog-service  PUT /api/v1/products/{id}         1.74s
   ├─ SELECT tb_product …                             1.62s   ← aqui
   ├─ UPDATE tb_product …                             0.03s
   └─ publish catalog.events                          0.01s
      └─ pricing-service  process catalog.events      0.04s   (via RabbitMQ)
         └─ INSERT tb_price …                         0.02s
```

Sem mudar uma linha de código dos apps.

## Como funciona

```
 pod do app (namespace de projeto)                 monitoring
 ─────────────────────────────────                 ─────────────────────────────────
 init container copia o agente                     Alloy :4317/:4318 ──► Tempo (72h)
 (injetado pelo OpenTelemetry Operator)              (o mesmo dos logs)      │
 app + agente Java/Node.js ──OTLP──────────────►                            │ metrics-generator
   mede cada requisição recebida, chamada                                    ▼
   HTTP, query SQL, mensagem RabbitMQ...           Prometheus ◄── traces_service_graph_*
   e repassa o contexto (header traceparent)                      traces_spanmetrics_*
   para o próximo serviço                          Grafana: Tempo + Loki + Prometheus ligados
```

- **OpenTelemetry**: o padrão aberto de telemetria. O **agente** (Java ou
  Node.js) se pluga no runtime e instrumenta as bibliotecas conhecidas
  (Spring MVC, JDBC, RestClient, RabbitMQ; Express/Nest, http, pg, ioredis,
  amqplib...), sem tocar no código. Exceção: o **Prisma** (crivo-be) fala com
  o banco pelo motor próprio, não pelo `pg`; as queries só viram spans com o
  pacote `@prisma/instrumentation` no código. Sem ele, o trace do crivo-be
  mostra a requisição e as chamadas HTTP/Redis, mas não o SQL.
- **OpenTelemetry Operator**: quando um pod com a annotation
  `instrumentation.opentelemetry.io/inject-<linguagem>` é criado, ele injeta o
  agente (init container + `JAVA_TOOL_OPTIONS` / `NODE_OPTIONS`) e as
  variáveis `OTEL_*`. Se o operador estiver fora do ar, o pod sobe sem agente
  (nunca deixa de subir).
- **Propagação**: cada chamada HTTP leva o header `traceparent` (padrão W3C).
  Por isso um trace atravessa Node.js → Java → Node.js como uma coisa só.
- **Tempo**: guarda os traces (72h, `config/tracing/tempo-values.yaml`) e, a
  partir deles, gera métricas para o Prometheus: o **mapa de serviços** (quem
  chama quem, com taxa, erro e latência) e RED por serviço e rota.
- **Amostragem**: 100% no lab (`k8s/otel-instrumentation.yaml`). Em produção,
  com muito tráfego, algo como 10%: a decisão é do primeiro serviço da
  chamada e vale para todos os outros (`parentbased_traceidratio`), então
  nunca sai um trace pela metade.

## Ligar num app

Nos values do app (`values.yaml` para todos os ambientes, ou só num
`values-<env>.yaml`):

```yaml
tracing:
  enabled: true
  language: java      # java (Spring...) | nodejs (NestJS, Express...)
```

Push no repo de infra → o ArgoCD recria os pods (em prod, pelo canary). O
chart:

| Põe no pod | Para quê |
| ---------- | -------- |
| annotation `instrumentation.opentelemetry.io/inject-<language>: monitoring/platform` | o operador injeta o agente |
| `OTEL_SERVICE_NAME=<app>` | nome do serviço nos traces (= nome do app/workload) |
| `OTEL_RESOURCE_ATTRIBUTES=service.namespace=<projeto>,deployment.environment.name=<env>` | separar develop de prod e projetos entre si |
| (Java) `JAVA_TOOL_OPTIONS` = `tracing.javaToolOptions` | o operador **substituiria** o `JAVA_TOOL_OPTIONS` da imagem (`-XX:MaxRAMPercentage=75`); declarado no pod, ele só acrescenta o `-javaagent` |

Ligados hoje: `catalog-service`, `pricing-service` (Java), `crivo-be`,
`products` (Node.js).

**Custo:** o agente Java soma ~50–100 MB de memória e alguns segundos na
subida; o Node.js, ~30–50 MB. Confira os `resources` e o `initialDelaySeconds`
do liveness de apps no limite.

**Fronts Next.js** ficam de fora por enquanto: o agente Node.js funciona no
servidor do Next, mas o próprio Next tem instrumentação OpenTelemetry nativa
(`instrumentation.ts` + `@vercel/otel`), que entende rotas e Server
Components. É o caminho certo para eles, e exige mudar o código do front.

## No Grafana

| Onde | O quê |
| ---- | ----- |
| **Platform / Apps → Traces (Tempo)** | mapa de serviços do projeto/ambiente e os últimos traces dos apps selecionados |
| **Explore → Tempo** | busca: *Search* (serviço, rota, duração mínima, só erros) ou TraceQL; aba *Service Graph* |
| trace aberto → **Logs for this span** | logs do mesmo pod no Loki, ±5 min |
| trace aberto → **Related metrics** | requests/s, erros/s e p95 do serviço |
| Loki: linha com `trace_id=...` | vira link para o trace (campo derivado `TraceID`) |

TraceQL úteis (Explore → Tempo → TraceQL):

```
{resource.service.name="catalog-service" && duration > 500ms}       # lentos
{resource.deployment.environment.name="prod" && status=error}         # erros em prod
{span.http.route="/api/v1/products" && span.http.response.status_code >= 500}
{resource.service.name="catalog-service"} >> {span.db.system="postgresql"}   # queries do catalog
```

### Logs com trace id

O agente sabe o trace id de cada requisição; o link log → trace só aparece
se o app **imprimir** esse id:

- **Spring**: o agente Java põe `trace_id`/`span_id` no MDC do logback. Os
  values do catalog e do pricing já imprimem com
  `LOGGING_PATTERN_LEVEL: "%5p [trace_id=%X{trace_id:-} span_id=%X{span_id:-}]"`.
- **Node.js**: com `pino` ou `winston`, o agente injeta `trace_id` no objeto
  de log sozinho. O `Logger` padrão do NestJS não tem esse gancho: trocar por
  `nestjs-pino` resolve.

O caminho inverso (trace → logs) funciona sempre: filtra pelo pod e pelo
horário do span.

## Exemplo: achar o gargalo

1. *Platform / Apps* (wlstore, prod): a latência p95 do `catalog-service` subiu.
2. Na seção Traces, o mapa mostra o `catalog-service` lento e o
   `pricing-service` normal.
3. Explore → Tempo: `{resource.service.name="catalog-service" && duration > 1s}`.
4. No trace: o span `SELECT tb_product` leva 1,6 s dos 1,7 s. Falta índice.
5. *Logs for this span*: o log daquela requisição, no mesmo lugar.

## Na nuvem

O mesmo desenho, com o Tempo guardando em object storage (S3/GCS) em vez de
disco, ou um serviço gerenciado (Grafana Cloud Traces, AWS X-Ray, Datadog,
Honeycomb). Como os apps só falam OTLP com o coletor (Alloy), trocar o
destino é mudar o `otelcol.exporter` no Alloy: os apps não mudam.

## Arquivos

| Arquivo | O quê |
| ------- | ----- |
| `scripts/setup-tracing.sh` | instala Tempo e OpenTelemetry Operator (`make tracing`, roda no setup) |
| `config/tracing/tempo-values.yaml` | retenção, metrics-generator (mapa de serviços, span metrics) |
| `config/tracing/opentelemetry-operator-values.yaml` | operador; webhook só nos namespaces de projeto |
| `k8s/otel-instrumentation.yaml` | agentes: destino (Alloy), amostragem, só traces |
| `config/observability/alloy-values.yaml` | receptor OTLP e envio ao Tempo |
| `k8s/grafana-datasource-tempo.yaml` | datasource Tempo ligado a Loki e Prometheus |
| `charts/app` (`tracing:`) | annotation e variáveis no pod |

## Problemas comuns

| Sintoma | Causa | Solução |
| ------- | ----- | ------- |
| app ligado, mas sem traces | pod criado antes do operador, ou sem a annotation | `kubectl get pod -n <ns> <pod> -o yaml \| grep inject-`; recriar o pod (`make rollout`) |
| pod sem o init container `opentelemetry-auto-instrumentation-*` | operador fora do ar na criação (o webhook é *fail-open*) | `make tracing`; recriar o pod |
| Java: `JDK tool detected, agent will not be started` | normal em `javac`/`jshell`; o agente se desliga em ferramentas do JDK | só preocupa se aparecer para o app; rode o app com `java -jar`/classe |
| app Java com OOMKilled depois de ligar | agente + heap passaram do limite | subir `resources.limits.memory` ou baixar `MaxRAMPercentage` em `tracing.javaToolOptions` |
| Node.js: `MetadataLookupWarning` | detectores de nuvem (GCP/AWS) tentando metadados | já desligados no Instrumentation (`OTEL_NODE_RESOURCE_DETECTORS`); recriar o pod |
| traces chegam, mapa de serviços vazio | Prometheus sem `enableRemoteWriteReceiver` | `make observability` |
| Grafana: busca do Tempo vazia logo depois do tráfego | ingestão leva alguns segundos | esperar ~30 s |
| nada chega no Tempo | Alloy sem as portas OTLP | `kubectl get svc alloy -n monitoring` (4317/4318); `make observability` |
