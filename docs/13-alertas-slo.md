# Alertas e SLOs

## A ideia em uma frase

Em vez de alertar em "CPU alta" ou "um erro 500 apareceu", a plataforma
alerta quando **o usuário está sendo afetado o bastante para gastar o
orçamento de erro** combinado. Isso gera poucos alertas, e cada um pede ação.

## Vocabulário

| Termo | O que é | Aqui |
| ----- | ------- | ---- |
| **SLI** (indicador) | o que se mede | % de requests **não-5xx** no NGINX Ingress, por app |
| **SLO** (objetivo) | a meta para o SLI numa janela | **99,5% em 7 dias** |
| **Error budget** | o erro permitido pelo SLO | 0,5% dos requests (≈ 50 min de app 100% fora em 7 dias) |
| **Burn rate** | velocidade de gasto do budget | 1x = gasta tudo em exatamente 7 dias; 14,4x = em ~12h |

O SLI vem do Ingress, então **nenhum app precisa expor métricas**: todo app
com `ingress.enabled` ganha SLO automaticamente.

## Como os alertas decidem (multiwindow, multi-burn-rate)

Alertar em "taxa de erro > 0,5%" dispara com qualquer pico de 1 minuto e
demora a voltar. O método do *Google SRE Workbook* usa duas janelas por
alerta: uma **longa**, que prova que o problema é sério, e uma **curta**,
que prova que ele **ainda está acontecendo** (o alerta some poucos minutos
depois do conserto).

| Alerta | Severidade | Condição | Significa |
| ------ | ---------- | -------- | --------- |
| `AppErrorBudgetBurn` | critical | erro > 7,2% (14,4x) em **1h e 5m** | 2% do budget por hora: acaba em ~12h. Agir agora. |
| `AppErrorBudgetBurn` | warning | erro > 3% (6x) em **6h e 30m** | 5% do budget em 6h: acaba em ~1 dia. Agir hoje. |
| `AppHighLatencyP95` | warning | p95 > 1s por 10 min (com tráfego) | lento, mesmo sem erro |
| `AppDown` | critical | Deployment com 0 réplicas prontas por 5 min | fora do ar (vale também para postgres/redis/rabbitmq) |
| `ArgoAppDegraded` | warning | Application `Degraded`/`Missing`/`Unknown` por 10 min | o deploy não ficou saudável |
| `ArgoAppOutOfSync` | warning | Application fora de sincronia por 30 min | o cluster não bate com o Git |
| `RolloutAborted` | warning | canary abortado (análise reprovou ou não ficou pronto) | versão estável no ar; corrigir e publicar outra ([runbook](15-entrega-progressiva.md#rolloutaborted)) |
| `RolloutStuckPaused` | warning | canary pausado há 1h | aprovação manual esquecida |

Os alertas de burn exigem um mínimo de tráfego (~10 requests/h): com 2
requests, 1 erro já seria 50%.

Todo alerta da plataforma tem os labels **`project`, `env` e `app`**
(extraídos do namespace `<projeto>-<env>`), então dá para filtrar e rotear por
projeto e ambiente.

Os alertas padrão do kube-prometheus-stack (`KubePodCrashLooping`,
`KubePodNotReady`, `KubePersistentVolumeFillingUp`...) continuam ligados.

## Onde ver

| Onde | O quê |
| ---- | ----- |
| `make alerts` | alertas ativos no terminal (estado, severidade, projeto/env, app) |
| Grafana → *Platform / SLOs e alertas* | disponibilidade 7d, error budget restante, burn rate, tabela por app e alertas ativos |
| http://alertmanager.devops.local (`make alertmanager`) | alertas agrupados, **silêncios**, inibições |
| http://prometheus.devops.local/alerts | estado de cada regra (`inactive`, `pending`, `firing`) |

`pending` = a condição é verdadeira, mas ainda não pelo tempo do `for:`.
Só `firing` chega ao Alertmanager.

### Inibição: um problema, um alerta

Se o app caiu, ele também está queimando budget. O Alertmanager **inibe**
`AppErrorBudgetBurn` e `AppHighLatencyP95` quando há `AppDown` do mesmo
`project/env/app`, e o `critical` inibe o `warning` do mesmo alerta. Na UI
eles aparecem como *suppressed*.

### Silenciar durante manutenção

Alertmanager → **New Silence** → matchers `project="crivo"` e `env="develop"`
→ duração. Silêncio sempre com prazo e comentário (quem e por quê).

## Arquivos

| Arquivo | O quê |
| ------- | ----- |
| `config/observability/kube-prometheus-stack-values.yaml` | Prometheus (retenção 7d), Alertmanager (rotas, inibições, receivers), Grafana |
| `k8s/prometheus-rules-apps.yaml` | recording rules `app:*` e os alertas acima (**gerado**) |
| `k8s/grafana-dashboard-slo.yaml` | dashboard *Platform / SLOs e alertas* (**gerado**) |
| `scripts/dev/gen-prometheus-rules.py` / `gen-dashboard-slo.py` | geradores: **edite aqui** e rode `make gen-observability` |

O CI do repo de infra (`validate.yml`) falha se o `k8s/` estiver diferente do
que os geradores produzem e roda o `promtool check rules`.

### Recording rules

Pré-calculam as séries que os alertas e o dashboard usam (mais rápido e com o
mesmo número em todo lugar):

```
app:requests:rate{5m,30m,1h,6h}            req/s por project/env/app
app:request_errors:ratio_rate{5m,30m,1h,6h} fração de 5xx
app:request_duration_seconds:p95_5m         latência p95
```

Exemplo no Prometheus/Grafana:

```promql
# burn rate da última hora de cada app
app:request_errors:ratio_rate1h / (1 - 0.995)
```

### Mudar o SLO ou um limite

1. Edite `SLO`/limites em `scripts/dev/gen-prometheus-rules.py` (e `SLO` em
   `gen-dashboard-slo.py`, que precisa concordar).
2. `make gen-observability && make apply-argocd`.
3. Commite os geradores **e** o `k8s/` gerado.

O Prometheus recarrega as regras sozinho em ~1 a 2 min.

## Notificações (Discord, Slack, Telegram…)

> Implementado: [20-notificacoes.md](20-notificacoes.md). O texto abaixo é
> o raciocínio original.

Hoje o receiver padrão é `null`: os alertas só aparecem nas UIs. Para
notificar, o webhook (que é um segredo) segue o mesmo caminho do
[Sealed Secrets](12-segredos.md):

```bash
# 1. sele o webhook (nunca em texto puro no Git)
kubectl create secret generic alertmanager-webhooks -n monitoring \
  --from-literal=DISCORD_WEBHOOK_URL='https://discord.com/api/webhooks/...' \
  --dry-run=client -o yaml \
  | kubeseal --cert config/sealed-secrets/cert.pem --format yaml \
  > k8s/alertmanager-webhooks-sealed.yaml
```

2. Em `config/observability/kube-prometheus-stack-values.yaml`:
   - `alertmanager.alertmanagerSpec.secrets: [alertmanager-webhooks]` (monta
     em `/etc/alertmanager/secrets/alertmanager-webhooks/`);
   - descomente o receiver `discord` (usa `webhook_url_file`, então a URL não
     aparece na config) e a rota de exemplo.
3. `make observability`, e confira em Alertmanager → *Status* a config
   carregada.

Slack usa `slack_configs.api_url_file`; Telegram, `telegram_configs.bot_token_file`.
Dá para rotear por label, por exemplo só `env="prod"` vai para o canal de
plantão e `develop` para um canal silencioso.

## Runbooks

Cada alerta tem `runbook_url` apontando para cá. Formato: o que significa,
como confirmar, causas comuns.

### AppErrorBudgetBurn

O app está respondendo 5xx acima do aceitável.

1. Dashboard *Platform / SLOs e alertas*: qual app, desde quando, crítico ou
   warning.
2. *Platform / Apps* → mesmo projeto/env/app: **Logs de erro** e status HTTP.
3. Coincidiu com deploy? `make apps` / ArgoCD → histórico da Application.
   Se sim, **rollback pelo Git** (reverter o commit do `image.tag`).
4. 503 = nenhum pod pronto atrás do Service (`kubectl get endpoints -n <ns>`).
   502 = pod existe, conexão falha (porta, app travado). 500 = erro do app
   (logs).
5. Dependência fora (Postgres/Redis/RabbitMQ)? `make pods`.

### AppHighLatencyP95

1. *Platform / Apps* → latência p95 e CPU/memória do app: CPU no limite
   (throttling) é a causa mais comum. Ajuste `resources` ou HPA nos values.
2. Dependência lenta (banco, fila)? Logs do app.
3. Muito tráfego de repente? `app:requests:rate5m`.

### AppDown

1. `kubectl get pods -n <ns> -l app.kubernetes.io/name=<app>` e
   `kubectl describe pod`: `ImagePullBackOff`, `CrashLoopBackOff`,
   `CreateContainerConfigError`, `Pending`. O
   [treino](11-treino-quebre-e-conserte.md) tem um exercício para cada um.
2. `kubectl logs --previous` se estiver reiniciando.

### ArgoAppDegraded

1. ArgoCD → a Application → recurso em vermelho → *Events*/*Logs*.
2. Geralmente é o mesmo diagnóstico do `AppDown` (pod que não fica pronto).

### ArgoAppOutOfSync

1. ArgoCD → *App Diff*: o que difere do Git.
2. Sync falhando (manifesto inválido, CRD ausente)? Veja *Sync Status*.
3. Alguém mudou o cluster na mão e o selfHeal está desligado? O Git é a
   fonte da verdade.

## Limites deste lab

- Retenção de 7 dias, igual à janela do SLO: o primeiro "7d" só fica completo
  uma semana depois do `make setup` (ou de recriar o Prometheus, que não tem
  disco persistente).
- SLI só do Ingress: erro interno que o app devolve como 200, ou chamada
  serviço a serviço sem Ingress, não entra. Tracing (fase 6) cobre isso.
- Alertas não saem do cluster até configurar um receiver.
