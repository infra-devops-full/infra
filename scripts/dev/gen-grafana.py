#!/usr/bin/env python3
"""Gera os dashboards do Grafana que não são de SLO (make gen-observability).

  k8s/grafana-dashboard-home.yaml        "Platform / Início" — página inicial
  k8s/grafana-dashboard-infra-*.yaml     dashboards da comunidade (grafana.com),
                                         em revisão fixa, apontados para o nosso
                                         Prometheus e com o cabeçalho da plataforma

    python3 scripts/dev/gen-grafana.py

Os da comunidade são baixados de grafana.com/api/dashboards/<id>/revisions/<rev>.
Para atualizar um, troque a revisão em COMMUNITY e rode de novo.
${INFRA_RAW_URL} (logo) é preenchido por scripts/apply-platform.sh.
"""
import json
import os
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
PROM = {"type": "prometheus", "uid": "prometheus"}
LOKI = {"type": "loki", "uid": "loki"}
LOGO = "${INFRA_RAW_URL}/config/branding/platform-logo.png"
# Namespaces da plataforma: o resto é namespace de projeto (<projeto>-<env>).
INFRA_NS = "argocd|argo-rollouts|cert-manager|kyverno|monitoring|kube-system|kube-public|kube-node-lease|default|treino"

COMMUNITY = [
    # id, revisão, uid fixo, arquivo, título, descrição, placeholders de datasource a trocar
    (1860, 45, "infra-node-exporter", "node-exporter", "Infra / Nodes (Node Exporter Full)",
     "CPU, memória, disco e rede de cada node do k3d", []),
    (15661, 2, "infra-kubernetes", "kubernetes", "Infra / Kubernetes (cluster, namespaces, pods)",
     "Uso e limites por node, namespace e container", ["${DS__VICTORIAMETRICS-PROD-ALL}"]),
    (14584, 1, "infra-argocd", "argocd", "Infra / ArgoCD",
     "Syncs, saúde das Applications, repo-server e controller", []),
    (10991, 15, "infra-rabbitmq", "rabbitmq", "Infra / RabbitMQ",
     "Filas, mensagens, conexões e consumidores dos RabbitMQ dos projetos", ["${DS_PROMETHEUS}"]),
]


def configmap(name, filename, folder, dashboard, header):
    body = json.dumps(dashboard, ensure_ascii=False, separators=(",", ":"))
    return (header + f"""apiVersion: v1
kind: ConfigMap
metadata:
  name: {name}
  namespace: monitoring
  labels:
    grafana_dashboard: "1"
  annotations:
    grafana_folder: "{folder}"
data:
  {filename}: |
    {body}
""")


def brand_header(title, subtitle):
    html = (
        '<div style="display:flex;align-items:center;gap:16px;height:100%">'
        f'<img src="{LOGO}" alt="" height="48" width="48" style="border-radius:12px">'
        '<div>'
        f'<div style="font-size:20px;font-weight:600">{title}</div>'
        f'<div style="opacity:.7">{subtitle}</div>'
        '</div></div>'
    )
    return {"type": "text", "title": "", "transparent": True,
            "options": {"mode": "html", "content": html}}


# --- Dashboards da comunidade -------------------------------------------------

def community(gid, rev, uid, slug, title, desc, placeholders):
    url = f"https://grafana.com/api/dashboards/{gid}/revisions/{rev}/download"
    raw = urllib.request.urlopen(url, timeout=60).read().decode()
    for ph in placeholders:
        raw = raw.replace(ph, "prometheus")
    d = json.loads(raw)
    for k in ("__inputs", "__requires", "__elements", "id"):
        d.pop(k, None)
    d["uid"] = uid
    d["title"] = title
    d["tags"] = sorted(set(d.get("tags", [])) | {"devops-platform", "infra"})
    d["editable"] = True

    # Painel sem posição no original (RabbitMQ rev. 15: "Ready messages"): vai
    # para o primeiro buraco do topo, onde o autor o tinha posto.
    for p in d.get("panels", []):
        p.setdefault("gridPos", {"x": 0, "y": 0, "w": 6, "h": 3})

    # Cabeçalho com o logo: empurra todos os painéis 3 linhas para baixo.
    h = 3
    for p in d.get("panels", []):
        p["gridPos"]["y"] += h
        for child in p.get("panels", []):   # filhos de rows recolhidas
            child["gridPos"]["y"] += h
    header = brand_header(f"DevOps Platform · {title.split(' / ', 1)[-1]}",
                          f"{desc} — base: grafana.com/dashboards/{gid} (rev. {rev})")
    header.update({"id": 9000, "gridPos": {"x": 0, "y": 0, "w": 24, "h": h}})
    d["panels"].insert(0, header)
    d["links"] = HOME_LINK + d.get("links", [])
    return d


HOME_LINK = [{"title": "Início", "type": "link", "url": "/d/platform-home", "icon": "doc", "keepTime": True}]


# --- Página inicial -------------------------------------------------------------

panels = []


def add(panel, x, y, w, h):
    panel["id"] = len(panels) + 1
    panel["gridPos"] = {"x": x, "y": y, "w": w, "h": h}
    panels.append(panel)


def target(expr, legend="", ref="A", instant=False, fmt="time_series", ds=PROM):
    t = {"datasource": ds, "expr": expr, "refId": ref, "legendFormat": legend, "format": fmt}
    if instant:
        t.update({"instant": True, "range": False})
    return t


def row(title, y):
    add({"type": "row", "title": title, "collapsed": False, "panels": []}, 0, y, 24, 1)


def stat(title, expr, desc, unit="none", steps=None, decimals=0, link=None, mappings=None):
    p = {
        "type": "stat", "title": title, "description": desc, "datasource": PROM,
        "targets": [target(expr, instant=True)],
        "fieldConfig": {"defaults": {
            "unit": unit, "decimals": decimals,
            "thresholds": {"mode": "absolute", "steps": steps or [{"color": "text", "value": None}]},
            "mappings": mappings or [],
        }, "overrides": []},
        "options": {"colorMode": "value" if steps else "none", "graphMode": "area", "textMode": "value",
                    "justifyMode": "center", "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}},
    }
    if link:   # clique no número abre os detalhes (sem ícone extra no título)
        p["fieldConfig"]["defaults"]["links"] = [{"title": "Abrir detalhes", "url": link}]
    return p


def timeseries(title, targets, unit, desc, ds=PROM):
    return {"type": "timeseries", "title": title, "description": desc, "datasource": ds, "targets": targets,
            "fieldConfig": {"defaults": {"unit": unit, "custom": {"lineWidth": 2, "fillOpacity": 8, "showPoints": "never"}},
                            "overrides": []},
            "options": {"legend": {"displayMode": "list", "placement": "bottom"}, "tooltip": {"mode": "multi", "sort": "desc"}}}


GOOD_BAD = [{"color": "green", "value": None}, {"color": "red", "value": 1}]
ZERO_OK = [{"type": "value", "options": {"0": {"text": "0 ✓"}}}]
PROJECT_NS = f'exported_namespace!~"{INFRA_NS}"'

tools = "".join(
    f'<a href="{url}" target="_blank" style="display:inline-block;margin:4px 6px 0 0;padding:6px 12px;'
    f'border-radius:8px;border:1px solid rgba(127,127,127,.35);text-decoration:none">{label}</a>'
    for label, url in [
        ("ArgoCD", "https://argocd.devops.local"),
        ("Rollouts", "https://rollouts.devops.local/rollouts/"),
        ("Alertmanager", "https://alertmanager.devops.local"),
        ("Prometheus", "https://prometheus.devops.local"),
        ("Infra no GitHub", "https://github.com/infra-devops-full/infra"),
    ])
dashes = "".join(
    f'<a href="/d/{uid}" style="display:inline-block;margin:4px 6px 0 0;padding:6px 12px;border-radius:8px;'
    f'background:rgba(112,72,232,.18);text-decoration:none">{label}</a>'
    for label, uid in [
        ("Apps", "platform-apps"), ("SLOs e alertas", "platform-slos"), ("Kubernetes", "infra-kubernetes"),
        ("Nodes", "infra-node-exporter"), ("ArgoCD", "infra-argocd"), ("RabbitMQ", "infra-rabbitmq"),
    ])
header = {
    "type": "text", "title": "", "transparent": True,
    "options": {"mode": "html", "content": (
        '<div style="display:flex;align-items:center;gap:20px;flex-wrap:wrap">'
        f'<img src="{LOGO}" alt="" height="72" width="72" style="border-radius:16px">'
        '<div style="flex:1;min-width:280px">'
        '<div style="font-size:26px;font-weight:600">DevOps Platform · Lab</div>'
        '<div style="opacity:.75">GitOps (ArgoCD) · canary (Argo Rollouts) · SLOs e alertas · Sealed Secrets · '
        'HTTPS (cert-manager) · NetworkPolicy + Kyverno — k3d no Mac</div>'
        f'<div style="margin-top:6px">{dashes}</div>'
        f'<div>{tools}</div>'
        '</div></div>')},
}

y = 0
add(header, 0, y, 24, 5)
y += 5
row("Agora", y)
y += 1
tiles = [
    stat("Apps falhando",
         'count(argocd_app_info{health_status!~"Healthy|Progressing"}) or vector(0)',
         "Applications do ArgoCD Degraded/Missing/Unknown.", steps=GOOD_BAD, mappings=ZERO_OK,
         link="https://argocd.devops.local"),
    stat("Alertas",
         'count(ALERTS{alertstate="firing", alertname!~"Watchdog|InfoInhibitor", severity=~"critical|warning"}) or vector(0)',
         "Alertas critical/warning ativos.", steps=GOOD_BAD, mappings=ZERO_OK, link="/d/platform-slos"),
    stat("Disponib. 24h",
         f'1 - (sum(increase(nginx_ingress_controller_requests{{{PROJECT_NS}, status=~"5.."}}[24h])) or vector(0))'
         f' / sum(increase(nginx_ingress_controller_requests{{{PROJECT_NS}}}[24h]))',
         "Requests sem 5xx em todos os apps, últimas 24h (SLO por app: 99,5%).", unit="percentunit", decimals=2,
         steps=[{"color": "red", "value": None}, {"color": "orange", "value": 0.995}, {"color": "green", "value": 0.999}],
         link="/d/platform-slos"),
    stat("Requests/s", "sum(app:requests:rate5m) or vector(0)", "Tráfego de todos os apps pelo Ingress.",
         unit="reqps", decimals=2, link="/d/platform-apps"),
    stat("Canaries", 'count(rollout_info{phase=~"Progressing|Paused"}) or vector(0)',
         "Rollouts no meio de um canary (Argo Rollouts).", mappings=[{"type": "value", "options": {"0": {"text": "nenhum"}}}],
         link="https://rollouts.devops.local/rollouts/"),
    stat("Certs < 14d",
         "count((certmanager_certificate_expiration_timestamp_seconds - time()) < 14 * 86400) or vector(0)",
         "Certificados do cert-manager que vencem em menos de 14 dias (a renovação é automática).",
         steps=GOOD_BAD, mappings=ZERO_OK),
]
for i, t in enumerate(tiles):
    add(t, i * 4, y, 4, 4)
y += 4
tiles = [
    stat("Applications", "count(argocd_app_info) or vector(0)", "Applications gerenciadas (apps + segredos + projetos).",
         link="https://argocd.devops.local"),
    stat("Pods", 'sum(kube_pod_status_phase{phase="Running"})', "Todos os namespaces.", link="/d/infra-kubernetes"),
    stat("CPU", '1 - avg(rate(node_cpu_seconds_total{mode="idle"}[5m]))', "Média dos nodes.",
         unit="percentunit", decimals=1,
         steps=[{"color": "green", "value": None}, {"color": "orange", "value": 0.7}, {"color": "red", "value": 0.9}],
         link="/d/infra-node-exporter"),
    stat("Memória", "1 - sum(node_memory_MemAvailable_bytes) / sum(node_memory_MemTotal_bytes)",
         "Usada / total dos nodes.", unit="percentunit", decimals=1,
         steps=[{"color": "green", "value": None}, {"color": "orange", "value": 0.75}, {"color": "red", "value": 0.9}],
         link="/d/infra-node-exporter"),
    stat("Fila RabbitMQ", "sum(rabbitmq_queue_messages_ready) or vector(0)",
         "Mensagens prontas e não consumidas em todos os RabbitMQ.", link="/d/infra-rabbitmq"),
    stat("Erros log 1h",
         'sum(count_over_time({project=~".+", project!="treino"} |~ "(?i)(error|exception|fatal|panic)" [1h])) or vector(0)',
         "Linhas de log com error/exception/fatal/panic (Loki).", link="/d/platform-apps"),
]
tiles[-1]["datasource"] = LOKI
tiles[-1]["targets"] = [target(tiles[-1]["targets"][0]["expr"], instant=True, ds=LOKI)]
for i, t in enumerate(tiles):
    add(t, i * 4, y, 4, 4)
y += 4

row("Projetos", y)
y += 1
apps_table = {
    "type": "table", "title": "Apps (ArgoCD)", "datasource": PROM,
    "description": "Saúde e sincronia de cada app (sem as Applications de segredos e de projeto).",
    "targets": [target('argocd_app_info{name!~"project-.*|.*-secrets-.*"}', instant=True, fmt="table")],
    "transformations": [{"id": "organize", "options": {
        "excludeByName": {k: True for k in ["Time", "Value", "__name__", "autosync_enabled", "container", "dest_server",
                                            "endpoint", "instance", "job", "namespace", "pod", "repo", "service", "dest_namespace"]},
        "indexByName": {"project": 0, "name": 1, "dest_namespace": 2, "health_status": 3, "sync_status": 4},
        "renameByName": {"project": "projeto", "name": "application", "dest_namespace": "namespace",
                         "health_status": "saúde", "sync_status": "sync"}}}],
    "fieldConfig": {"defaults": {"custom": {"filterable": True}}, "overrides": [
        {"matcher": {"id": "byName", "options": "saúde"}, "properties": [
            {"id": "custom.cellOptions", "value": {"type": "color-text"}},
            {"id": "mappings", "value": [{"type": "value", "options": {
                "Healthy": {"color": "green", "text": "✓ Healthy"}, "Progressing": {"color": "blue", "text": "↻ Progressing"},
                "Degraded": {"color": "red", "text": "✗ Degraded"}, "Missing": {"color": "orange", "text": "? Missing"},
                "Suspended": {"color": "text", "text": "Ⅱ Suspended"}}}]}]},
        {"matcher": {"id": "byName", "options": "sync"}, "properties": [
            {"id": "custom.cellOptions", "value": {"type": "color-text"}},
            {"id": "mappings", "value": [{"type": "value", "options": {
                "Synced": {"color": "green", "text": "✓ Synced"}, "OutOfSync": {"color": "orange", "text": "△ OutOfSync"}}}]}]},
    ]},
    "options": {"showHeader": True, "sortBy": [{"displayName": "saúde", "desc": False}]},
}
add(apps_table, 0, y, 12, 10)
add(timeseries("Requests/s por projeto",
               [target('sum by (project) (app:requests:rate5m{project!="treino"})', "{{project}}")],
               "reqps", "Tráfego pelo Ingress, somando os ambientes."), 12, y, 12, 5)
add(timeseries("Taxa de 5xx por projeto",
               [target('sum by (project) (app:requests:rate5m{project!="treino"} * app:request_errors:ratio_rate5m)'
                       ' / sum by (project) (app:requests:rate5m{project!="treino"})', "{{project}}")],
               "percentunit", "Fração de requests com erro 5xx (SLO: até 0,5%)."), 12, y + 5, 12, 5)
y += 10

row("Recursos e logs", y)
y += 1
add(timeseries("CPU por namespace de projeto",
               [target(f'sum by (namespace) (rate(container_cpu_usage_seconds_total{{namespace!~"{INFRA_NS}", container!=""}}[5m]))',
                       "{{namespace}}")], "cores", "Uso de CPU dos containers (cAdvisor)."), 0, y, 8, 8)
add(timeseries("Memória por namespace de projeto",
               [target(f'sum by (namespace) (container_memory_working_set_bytes{{namespace!~"{INFRA_NS}", container!=""}})',
                       "{{namespace}}")], "bytes", "Working set dos containers."), 8, y, 8, 8)
add(timeseries("Erros no log por projeto",
               [target('sum by (project) (count_over_time({project=~".+", project!="treino"} |~ "(?i)(error|exception|fatal|panic)" [5m]))',
                       "{{project}}", ds=LOKI)], "short", "Linhas de erro a cada 5 min (Loki).", ds=LOKI), 16, y, 8, 8)
y += 8

row("Alertas ativos", y)
y += 1
add({
    "type": "table", "title": "", "datasource": PROM,
    "targets": [target('ALERTS{alertstate="firing", alertname!~"Watchdog|InfoInhibitor"}', instant=True, fmt="table")],
    "transformations": [{"id": "filterFieldsByName", "options": {"include": {
        "names": ["severity", "alertname", "project", "env", "app", "namespace"]}}},
        {"id": "organize", "options": {"indexByName": {"severity": 0, "alertname": 1, "project": 2, "env": 3, "app": 4}}}],
    "fieldConfig": {"defaults": {"noValue": "Nenhum alerta disparando ✓"}, "overrides": [
        {"matcher": {"id": "byName", "options": "severity"}, "properties": [
            {"id": "custom.cellOptions", "value": {"type": "color-text"}},
            {"id": "mappings", "value": [{"type": "value", "options": {
                "critical": {"color": "red", "text": "● critical"}, "warning": {"color": "orange", "text": "▲ warning"}}}]}]}]},
    "options": {"showHeader": True},
}, 0, y, 24, 5)

home = {
    "uid": "platform-home", "title": "Platform / Início", "tags": ["devops-platform", "platform"],
    "editable": True, "schemaVersion": 39, "time": {"from": "now-6h", "to": "now"}, "refresh": "1m",
    "panels": panels,
}


def main():
    out = os.path.join(ROOT, "k8s")
    gen = "# GERADO por scripts/dev/gen-grafana.py — edite o gerador, não este arquivo.\n"
    with open(os.path.join(out, "grafana-dashboard-home.yaml"), "w") as f:
        f.write(configmap("platform-dashboard-home", "platform-home.json", "Platform", home,
                          gen + "# Página inicial do Grafana (default_home_dashboard_path nos values do\n"
                                "# kube-prometheus-stack aponta para este arquivo).\n"))
    for gid, rev, uid, slug, title, desc, ph in COMMUNITY:
        d = community(gid, rev, uid, slug, title, desc, ph)
        with open(os.path.join(out, f"grafana-dashboard-infra-{slug}.yaml"), "w") as f:
            f.write(configmap(f"infra-dashboard-{slug}", f"infra-{slug}.json", "Infra", d,
                              gen + f"# Base: https://grafana.com/grafana/dashboards/{gid} (revisão {rev}).\n"))
        print(f"k8s/grafana-dashboard-infra-{slug}.yaml  ({title})")
    print("k8s/grafana-dashboard-home.yaml  (Platform / Início)")


if __name__ == "__main__":
    main()
