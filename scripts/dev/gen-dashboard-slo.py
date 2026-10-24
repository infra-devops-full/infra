#!/usr/bin/env python3
"""Gera k8s/grafana-dashboard-slo.yaml (dashboard "Platform / SLOs").

Lê as recording rules de k8s/prometheus-rules-apps.yaml (app:*), então os
dois arquivos precisam concordar no SLO (0,995) e nos nomes das métricas.

    python3 scripts/dev/gen-dashboard-slo.py > k8s/grafana-dashboard-slo.yaml
"""
import json

SLO = 0.995
PROM = {"type": "prometheus", "uid": "prometheus"}
SEL = 'project=~"$project", env=~"$env", app=~"$app"'
# Contadores crus (para a janela de 7 dias, que não tem recording rule).
RAW = 'exported_namespace=~"($project)-($env)", ingress=~"$app"'

panels = []
_id = 0


def add(panel, x, y, w, h):
    global _id
    _id += 1
    panel.update({"id": _id, "gridPos": {"x": x, "y": y, "w": w, "h": h}})
    panels.append(panel)


def row(title, y):
    add({"type": "row", "title": title, "collapsed": False, "panels": []}, 0, y, 24, 1)


def target(expr, legend="", ref="A", instant=False, fmt="time_series"):
    t = {"datasource": PROM, "expr": expr, "refId": ref, "legendFormat": legend, "format": fmt}
    if instant:
        t.update({"instant": True, "range": False})
    return t


def stat(title, expr, unit, steps, desc, decimals=2):
    return {
        "type": "stat", "title": title, "description": desc, "datasource": PROM,
        "targets": [target(expr, instant=True)],
        "fieldConfig": {"defaults": {
            "unit": unit, "decimals": decimals,
            "thresholds": {"mode": "absolute", "steps": steps},
        }, "overrides": []},
        "options": {"colorMode": "background", "graphMode": "none", "textMode": "value",
                    "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}},
    }


avail_7d = (f'1 - (sum(increase(nginx_ingress_controller_requests{{{RAW}, status=~"5.."}}[7d])) or vector(0))'
            f' / sum(increase(nginx_ingress_controller_requests{{{RAW}}}[7d]))')
budget_7d = f'1 - ((1 - ({avail_7d})) / (1 - {SLO}))'

y = 0
row("Resumo (seleção atual, janela de 7 dias)", y)
y += 1
add(stat("Disponibilidade 7d", avail_7d, "percentunit",
         [{"color": "red", "value": None}, {"color": "orange", "value": SLO}, {"color": "green", "value": 0.999}],
         f"Requests não-5xx / total no Ingress em 7 dias. SLO = {SLO * 100:g}%.", 3), 0, y, 6, 4)
add(stat("Error budget restante", budget_7d, "percentunit",
         [{"color": "red", "value": None}, {"color": "orange", "value": 0.25}, {"color": "green", "value": 0.5}],
         "Quanto dos 0,5% de erro permitidos em 7 dias ainda sobra. Negativo = SLO estourado.", 1), 6, y, 6, 4)
add(stat("Burn rate (1h)",
         f"max(app:request_errors:ratio_rate1h{{{SEL}}}) / (1 - {SLO})", "x",
         [{"color": "green", "value": None}, {"color": "orange", "value": 6}, {"color": "red", "value": 14.4}],
         "Velocidade de gasto do budget (pior app). 1x = gasta tudo em 7 dias; 14,4x dispara alerta crítico.", 1),
    12, y, 6, 4)
add(stat("Alertas disparando",
         f'count(ALERTS{{alertstate="firing", {SEL}}}) or vector(0)', "none",
         [{"color": "green", "value": None}, {"color": "red", "value": 1}],
         "Alertas da plataforma com os labels project/env/app da seleção.", 0), 18, y, 6, 4)
y += 4

row("Por app", y)
y += 1
table_targets = [
    target(f"1 - app:request_errors:ratio_rate1h{{{SEL}}}", ref="A", instant=True, fmt="table"),
    target(f"app:request_errors:ratio_rate1h{{{SEL}}} / (1 - {SLO})", ref="B", instant=True, fmt="table"),
    target(f"app:request_errors:ratio_rate6h{{{SEL}}} / (1 - {SLO})", ref="C", instant=True, fmt="table"),
    target(f"app:request_duration_seconds:p95_5m{{{SEL}}}", ref="D", instant=True, fmt="table"),
    target(f"app:requests:rate5m{{{SEL}}}", ref="E", instant=True, fmt="table"),
]
add({
    "type": "table", "title": "SLIs por app", "datasource": PROM, "targets": table_targets,
    "description": "Burn rate: 14,4x (1h) = crítico, 6x (6h) = warning. Vazio = sem tráfego.",
    "transformations": [
        {"id": "merge", "options": {}},
        {"id": "organize", "options": {
            "excludeByName": {"Time": True, "exported_namespace": True, "ingress": True},
            "indexByName": {"project": 0, "env": 1, "app": 2, "Value #A": 3, "Value #B": 4,
                            "Value #C": 5, "Value #D": 6, "Value #E": 7},
            "renameByName": {"Value #A": "Disponib. 1h", "Value #B": "Burn 1h", "Value #C": "Burn 6h",
                             "Value #D": "p95", "Value #E": "req/s"}}},
    ],
    "fieldConfig": {"defaults": {}, "overrides": [
        {"matcher": {"id": "byName", "options": "Disponib. 1h"},
         "properties": [{"id": "unit", "value": "percentunit"}, {"id": "decimals", "value": 2}]},
        {"matcher": {"id": "byRegexp", "options": "Burn.*"}, "properties": [
            {"id": "unit", "value": "x"}, {"id": "decimals", "value": 1},
            {"id": "custom.cellOptions", "value": {"type": "color-background"}},
            {"id": "thresholds", "value": {"mode": "absolute", "steps": [
                {"color": "green", "value": None}, {"color": "orange", "value": 6}, {"color": "red", "value": 14.4}]}}]},
        {"matcher": {"id": "byName", "options": "p95"},
         "properties": [{"id": "unit", "value": "s"}, {"id": "decimals", "value": 3}]},
        {"matcher": {"id": "byName", "options": "req/s"},
         "properties": [{"id": "unit", "value": "reqps"}, {"id": "decimals", "value": 2}]},
    ]},
    "options": {"showHeader": True, "sortBy": [{"displayName": "Burn 1h", "desc": True}]},
}, 0, y, 24, 8)
y += 8


def timeseries(title, targets, unit, desc, thresholds=None):
    defaults = {"unit": unit, "custom": {"lineWidth": 2, "fillOpacity": 10}}
    if thresholds:
        defaults["thresholds"] = {"mode": "absolute", "steps": thresholds}
        defaults["custom"]["thresholdsStyle"] = {"mode": "dashed"}
    return {"type": "timeseries", "title": title, "description": desc, "datasource": PROM,
            "targets": targets, "fieldConfig": {"defaults": defaults, "overrides": []},
            "options": {"legend": {"displayMode": "list", "placement": "bottom"},
                        "tooltip": {"mode": "multi"}}}


row("Ao longo do tempo", y)
y += 1
add(timeseries("Burn rate (1h) por app",
               [target(f"app:request_errors:ratio_rate1h{{{SEL}}} / (1 - {SLO})", "{{project}}/{{env}} {{app}}")],
               "x", "Linhas tracejadas: 6x (warning, janela 6h) e 14,4x (crítico, janela 1h).",
               [{"color": "transparent", "value": None}, {"color": "orange", "value": 6},
                {"color": "red", "value": 14.4}]), 0, y, 12, 8)
add(timeseries("Taxa de erro 5xx (5m) por app",
               [target(f"app:request_errors:ratio_rate5m{{{SEL}}}", "{{project}}/{{env}} {{app}}")],
               "percentunit", "Fração de requests 5xx. Linha tracejada: 0,5% (o SLO).",
               [{"color": "transparent", "value": None}, {"color": "red", "value": 1 - SLO}]), 12, y, 12, 8)
y += 8

row("Alertas", y)
y += 1
add({
    "type": "table", "title": "Alertas ativos (Prometheus → Alertmanager)", "datasource": PROM,
    "description": "Detalhes, silêncios e histórico em http://alertmanager.devops.local",
    "targets": [target(f'ALERTS{{alertstate=~"firing|pending", {SEL}}}', instant=True, fmt="table")],
    "transformations": [{"id": "organize", "options": {
        "excludeByName": {"Time": True, "Value": True, "__name__": True, "exported_namespace": True,
                          "ingress": True, "container": True, "endpoint": True, "instance": True,
                          "job": True, "pod": True, "service": True, "uid": True},
        "indexByName": {"alertstate": 0, "severity": 1, "alertname": 2, "project": 3, "env": 4, "app": 5}}}],
    "fieldConfig": {"defaults": {}, "overrides": [
        {"matcher": {"id": "byName", "options": "severity"}, "properties": [
            {"id": "custom.cellOptions", "value": {"type": "color-text"}},
            {"id": "mappings", "value": [{"type": "value", "options": {
                "critical": {"color": "red", "index": 0}, "warning": {"color": "orange", "index": 1}}}]}]},
    ]},
    "options": {"showHeader": True},
}, 0, y, 24, 7)


def var(name, label, query, include_all=True):
    return {"name": name, "label": label, "type": "query", "datasource": PROM,
            "query": {"query": query, "refId": name}, "definition": query, "refresh": 2,
            "includeAll": include_all, "multi": True, "allValue": ".*",
            "current": {"selected": True, "text": ["All"], "value": ["$__all"]}, "sort": 1}


dashboard = {
    "uid": "platform-slos",
    "title": "Platform / SLOs e alertas",
    "tags": ["platform", "slo", "alerts"],
    "editable": True,
    "schemaVersion": 39,
    "time": {"from": "now-24h", "to": "now"},
    "refresh": "1m",
    # Os dois dashboards usam as mesmas variáveis (project, env, app), então a
    # navegação entre eles mantém a seleção.
    "links": [{"title": "Apps (requests, logs, recursos)", "type": "link", "url": "/d/platform-apps",
               "keepTime": True, "includeVars": True, "icon": "dashboard"},
              {"title": "ArgoCD do projeto", "type": "link",
               "url": "http://argocd.devops.local/applications?proj=${project}",
               "targetBlank": True, "icon": "external link"},
              {"title": "Alertmanager", "type": "link", "url": "http://alertmanager.devops.local",
               "targetBlank": True, "icon": "bolt"}],
    "templating": {"list": [
        var("project", "Projeto", "label_values(app:requests:rate5m, project)"),
        var("env", "Ambiente", 'label_values(app:requests:rate5m{project=~"$project"}, env)'),
        var("app", "App", 'label_values(app:requests:rate5m{project=~"$project", env=~"$env"}, app)'),
    ]},
    "panels": panels,
}

body = json.dumps(dashboard, indent=2, ensure_ascii=False)
print(f"""# =============================================================================
# Dashboard "Platform / SLOs e alertas" — GERADO por scripts/dev/gen-dashboard-slo.py
# (edite o gerador, não este arquivo). Usa as recording rules app:* de
# k8s/prometheus-rules-apps.yaml. SLO de disponibilidade: {SLO * 100:g}% em 7 dias.
# =============================================================================
apiVersion: v1
kind: ConfigMap
metadata:
  name: platform-dashboard-slos
  namespace: monitoring
  labels:
    grafana_dashboard: "1"
  annotations:
    grafana_folder: "Platform"
data:
  platform-slos.json: |""")
for line in body.splitlines():
    print("    " + line)
