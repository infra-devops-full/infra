# Notificações no Discord

## Canais

| Canal | Recebe | Origem | Repete |
| ----- | ------ | ------ | ------ |
| `#alertas` | alertas **critical/warning** de **prod** e da plataforma | Alertmanager | a cada 4h enquanto durar |
| `#alertas-develop` | alertas de **develop** e do lab `treino` | Alertmanager | a cada 24h |
| `#deploys` | 🚀 deploy em prod · 🧪 deploy em develop · ❌ sync falhou · ⚠️ app degradado (inclui canary abortado) | ArgoCD Notifications | uma vez por revisão do Git |

Alertas `info` e o `Watchdog` não notificam. Inibições continuam valendo
(app fora do ar não manda também "queimando o error budget").

### Como as mensagens ficam

**Alerta** (`#alertas`):

```
🔥 AppErrorBudgetBurn · crivo/prod · crivo-be
🔴 critical — crivo/prod crivo-be: queimando o error budget rápido
10.9% de 5xx na última hora (limite 7,2%). Nesse ritmo o budget acaba em ~12h.
📊 Dashboard · 📖 Runbook · 🔕 Silenciar
⏱️ desde 26/10 13:49
```

Quando resolve, chega a mesma mensagem com **✅ Resolvido** e o horário.
Os links abrem o *Platform / Apps* já filtrado, o runbook do alerta
(`docs/13-alertas-slo.md`) e a tela de silêncio do Alertmanager já
preenchida.

**Deploy** (`#deploys`):

```
🚀 crivo-be → prod                                  (link para o ArgoCD)
Versão `1.4.0` no ar em `crivo-prod`. Canary concluído (20% → 50% → 100%).
Projeto: crivo   Versão: 1.4.0   Revisão da infra: e948ba8
```

## Configurar (uma vez)

1. **No Discord:** crie os canais `#alertas`, `#alertas-develop` e
   `#deploys` e, em cada um, *Editar canal → Integrações → Webhooks → Novo
   webhook → Copiar URL do webhook*. Dê nomes diferentes para reconhecer
   (ex.: "Alertmanager", "ArgoCD").
2. **Selar as URLs** (elas são senhas: quem tem a URL posta no canal):

   ```bash
   make notifications-webhooks   # cola as 3 URLs; não aparecem na tela
   git add config/notifications/*.sealed.yaml && git commit -m "feat: webhooks do discord" && git push
   ```

   Para `#alertas-develop`, Enter repete a URL do `#alertas` (um canal só
   para alertas).
3. **Aplicar e testar:**

   ```bash
   make notifications
   make notify-test     # 1 alerta em cada canal de alerta (resolve em ~3 min) + 1 deploy
   ```

> **Na primeira ativação** o `#deploys` recebe um "deploy" de cada app: o
> ArgoCD nunca tinha notificado a revisão atual deles. Acontece uma vez só.

> **URL de webhook vazada** (colada em chat, print, commit): no Discord,
> *Excluir Webhook* e crie outro; depois `make notifications-webhooks` e
> commit.

## Mudar o que notifica

| Quero | Onde |
| ----- | ---- |
| outro canal para um projeto (ex.: `#crivo`) | nova rota em `config/notifications/alertmanager-values.yaml` (`matchers: ['project = "crivo"']`) antes das genéricas + webhook novo no Secret |
| texto/emoji das mensagens de alerta | `templateFiles.discord.tmpl` no mesmo arquivo |
| texto das mensagens de deploy | `templates` em `config/notifications/argocd-notifications-values.yaml` |
| menos barulho em develop | `repeat_interval` da rota develop, ou tirar `on-deployed` de develop (condição no trigger) |
| Slack em vez de Discord | Alertmanager: `slack_configs` com `api_url_file`; ArgoCD: `service.slack` |

Depois: `make notifications`.

## Como funciona

| Peça | Para quê |
| ---- | -------- |
| `config/notifications/alertmanager-values.yaml` | rotas, receivers `discord_configs` (URL lida de arquivo: nunca aparece na config) e templates |
| `config/notifications/argocd-notifications-values.yaml` | triggers, templates (JSON de *embed* do Discord) e a assinatura global (só Applications `devops-platform/kind=app`) |
| `config/notifications/*.sealed.yaml` | URLs dos webhooks, seladas |
| `scripts/setup-notifications.sh` | `make notifications` |
| `scripts/seal-notifications.sh` | `make notifications-webhooks` |
| `scripts/notify-test.sh` | `make notify-test` (alertas via `amtool` dentro do Alertmanager) |

O `setup-observability.sh` inclui a config de alertas quando o Secret
`alertmanager-webhooks` existe, então `make observability` não desliga as
notificações.

## Problemas comuns

| Sintoma | Causa | Solução |
| ------- | ----- | ------- |
| nada chega | webhooks não selados/aplicados | `make notifications` mostra o que falta |
| alerta aparece no Alertmanager mas não no Discord | rota não casou (ex.: severidade `info`) | `amtool config routes test` (ver docs/13) |
| Discord recusa (log do Alertmanager: `400`) | mensagem passou do limite (4096) | menos alertas por grupo (`group_by`) ou encurtar o template |
| `#deploys` silencioso num deploy | a revisão já tinha sido notificada (uma vez por revisão) | esperado |
| alerta falso de um namespace de infra | namespace fora da lista de exclusão das regras | `INFRA` em `scripts/dev/gen-prometheus-rules.py` + `make gen-observability` |
