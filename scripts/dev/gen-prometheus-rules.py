import sys
INFRA='argocd|argo-rollouts|cert-manager|kyverno|auth|monitoring|kube-system|kube-public|kube-node-lease|default'
def labels(expr, ns):
    # project = namespace sem o último "-<env>" (ou o namespace inteiro), env = sufixo
    return (f'label_replace(label_replace(label_replace({expr}, '
            f'"project", "$1", "{ns}", "(.*)"), '
            f'"project", "$1", "{ns}", "(.+)-[^-]+"), '
            f'"env", "$1", "{ns}", ".+-([^-]+)")')
out=[]
w=out.append
w('''# =============================================================================
# Regras de SLO e alertas dos apps (genérico: vale para todo projeto).
# GERADO por scripts/dev/gen-prometheus-rules.py — edite o gerador, não este arquivo.
#
# SLI  = requests do NGINX Ingress que NÃO são 5xx (o app não precisa expor métricas).
# SLO  = 99,5% em 7 dias  →  error budget = 0,5% dos requests (~50 min de erro total).
# Alertas multiwindow multi-burn-rate (Google SRE Workbook, cap. 5):
#   crítico  burn 14,4x em 1h E 5m   → gasta 2% do budget/hora (acaba em ~12h)
#   warning  burn 6x    em 6h E 30m  → gasta 5% do budget em 6h (acaba em ~1,2 dia)
# Labels de todo alerta: project, env, app (o namespace <projeto>-<env> é quebrado).
# Explicação e runbooks: docs/13-alertas-slo.md
# =============================================================================
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: platform-apps-slo
  namespace: monitoring
  labels:
    release: kube-prometheus-stack
spec:
  groups:
    - name: platform-apps.slo.recording
      interval: 60s
      rules:''')
for win in ['5m','30m','1h','6h']:
    req=f'sum by (exported_namespace, ingress) (rate(nginx_ingress_controller_requests{{exported_namespace!~"{INFRA}"}}[{win}]))'
    err=f'sum by (exported_namespace, ingress) (rate(nginx_ingress_controller_requests{{exported_namespace!~"{INFRA}",status=~"5.."}}[{win}]))'
    w(f'''        - record: app:requests:rate{win}
          expr: >-
            {labels(f'label_replace({req}, "app", "$1", "ingress", "(.*)")','exported_namespace')}
        - record: app:request_errors:ratio_rate{win}
          expr: >-
            {labels(f'label_replace(({err} or {req} * 0) / {req}, "app", "$1", "ingress", "(.*)")','exported_namespace')}''')
lat='sum by (le, exported_namespace, ingress) (rate(nginx_ingress_controller_request_duration_seconds_bucket{exported_namespace!~"%s"}[5m]))'%INFRA
w(f'''        - record: app:request_duration_seconds:p95_5m
          expr: >-
            {labels(f'label_replace(histogram_quantile(0.95, {lat}), "app", "$1", "ingress", "(.*)")','exported_namespace')}
        # SLO como métrica: o Grafana e as regras leem daqui.
        - record: app:slo:objective
          expr: vector(0.995)

    - name: platform-apps.slo.alerts
      rules:
        - alert: AppErrorBudgetBurn
          # Mínimo de tráfego (~10 req/h): com 2 requests, 1 erro já é 50%.
          expr: |
            (
              app:request_errors:ratio_rate1h > (14.4 * 0.005)
              and app:request_errors:ratio_rate5m > (14.4 * 0.005)
            )
            and app:requests:rate1h > (10 / 3600)
          for: 2m
          labels:
            severity: critical
            slo: availability
          annotations:
            summary: "{{{{ $labels.project }}}}/{{{{ $labels.env }}}} {{{{ $labels.app }}}}: queimando o error budget rápido"
            description: "{{{{ $value | humanizePercentage }}}} de 5xx na última hora (limite 7,2%). Nesse ritmo o budget de 7 dias acaba em ~12h."
            runbook_url: https://github.com/infra-devops-full/infra/blob/main/docs/13-alertas-slo.md#apperrorbudgetburn
        - alert: AppErrorBudgetBurn
          expr: |
            (
              app:request_errors:ratio_rate6h > (6 * 0.005)
              and app:request_errors:ratio_rate30m > (6 * 0.005)
            )
            and app:requests:rate6h > (10 / 3600)
          for: 15m
          labels:
            severity: warning
            slo: availability
          annotations:
            summary: "{{{{ $labels.project }}}}/{{{{ $labels.env }}}} {{{{ $labels.app }}}}: queimando o error budget"
            description: "{{{{ $value | humanizePercentage }}}} de 5xx nas últimas 6h (limite 3%). Nesse ritmo o budget de 7 dias acaba em ~1 dia."
            runbook_url: https://github.com/infra-devops-full/infra/blob/main/docs/13-alertas-slo.md#apperrorbudgetburn
        - alert: AppHighLatencyP95
          expr: app:request_duration_seconds:p95_5m > 1 and app:requests:rate5m > 0.05
          for: 10m
          labels:
            severity: warning
            slo: latency
          annotations:
            summary: "{{{{ $labels.project }}}}/{{{{ $labels.env }}}} {{{{ $labels.app }}}}: p95 acima de 1s"
            description: "p95 = {{{{ $value | humanizeDuration }}}} há 10 min."
            runbook_url: https://github.com/infra-devops-full/infra/blob/main/docs/13-alertas-slo.md#apphighlatencyp95
        - alert: AppDown
          # Deployment que deveria ter réplica e não tem nenhuma pronta
          # (inclui as dependências: postgres, redis, rabbitmq).
          expr: >-
            {labels('label_replace(kube_deployment_spec_replicas{namespace!~"%s"} > 0 and on (namespace, deployment) kube_deployment_status_replicas_available == 0, "app", "$1", "deployment", "(.*)")' % INFRA, 'namespace')}
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: "{{{{ $labels.project }}}}/{{{{ $labels.env }}}} {{{{ $labels.app }}}}: nenhuma réplica pronta"
            description: "O Deployment {{{{ $labels.namespace }}}}/{{{{ $labels.deployment }}}} está sem pods prontos há 5 min."
            runbook_url: https://github.com/infra-devops-full/infra/blob/main/docs/13-alertas-slo.md#appdown

    - name: platform-apps.argocd
      rules:
        - alert: ArgoAppDegraded
          expr: >-
            {labels('label_replace(argocd_app_info{health_status=~"Degraded|Missing|Unknown"}, "app", "$1", "name", "(.*)")', 'dest_namespace')}
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "ArgoCD: {{{{ $labels.name }}}} está {{{{ $labels.health_status }}}}"
            description: "A Application {{{{ $labels.name }}}} (namespace {{{{ $labels.dest_namespace }}}}) não está saudável há 10 min."
            runbook_url: https://github.com/infra-devops-full/infra/blob/main/docs/13-alertas-slo.md#argoappdegraded
        - alert: ArgoAppOutOfSync
          expr: >-
            {labels('label_replace(argocd_app_info{sync_status!="Synced"}, "app", "$1", "name", "(.*)")', 'dest_namespace')}
          for: 30m
          labels:
            severity: warning
          annotations:
            summary: "ArgoCD: {{{{ $labels.name }}}} fora de sincronia"
            description: "O cluster difere do Git para {{{{ $labels.name }}}} há 30 min (sync falhando ou selfHeal desligado)."
            runbook_url: https://github.com/infra-devops-full/infra/blob/main/docs/13-alertas-slo.md#argoappoutofsync

    - name: platform-apps.rollouts
      rules:
        - alert: RolloutAborted
          # A análise reprovou o canary (ou ele não ficou pronto no prazo): o
          # tráfego voltou para a versão estável, mas o Git ainda pede a nova.
          expr: >-
            {labels('label_replace(rollout_info{phase=~"Abort|Degraded|Error|Timeout"}, "app", "$1", "name", "(.*)")', 'exported_namespace')}
          for: 1m
          labels:
            severity: warning
          annotations:
            summary: "{{{{ $labels.project }}}}/{{{{ $labels.env }}}} {{{{ $labels.app }}}}: canary abortado, versão estável no ar"
            description: "O Rollout {{{{ $labels.exported_namespace }}}}/{{{{ $labels.name }}}} abortou a versão nova. Corrija e publique outra versão (ou reverta o image.tag no Git)."
            runbook_url: https://github.com/infra-devops-full/infra/blob/main/docs/15-entrega-progressiva.md#rolloutaborted
        - alert: RolloutStuckPaused
          # Pausa sem duração (aprovação manual) esquecida.
          expr: >-
            {labels('label_replace(rollout_info{phase="Paused"}, "app", "$1", "name", "(.*)")', 'exported_namespace')}
          for: 1h
          labels:
            severity: warning
          annotations:
            summary: "{{{{ $labels.project }}}}/{{{{ $labels.env }}}} {{{{ $labels.app }}}}: canary pausado há 1h"
            description: "O Rollout {{{{ $labels.exported_namespace }}}}/{{{{ $labels.name }}}} está pausado esperando promoção (make promote) ou aborto (make abort)."
            runbook_url: https://github.com/infra-devops-full/infra/blob/main/docs/15-entrega-progressiva.md#rolloutstuckpaused''')
print('\n'.join(out))
