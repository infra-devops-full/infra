#!/usr/bin/env python3
"""Gera docs/media/infra-lab.svg: a jornada de um `git push` até produção,
animada (SVG + SMIL, sem JavaScript). Ciclo de 14 s, 1080x1080.

    python3 scripts/dev/gen-lab-animation.py

O GitHub anima o SVG no README (<img src=...>). Para o LinkedIn, que não
aceita SVG, grave um vídeo: scripts/dev/record-lab-animation.cjs.
"""
import os

T = 14.0  # duração do ciclo (s)
W = H = 1080
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

BG, PANEL, LINE = "#0B1020", "#131A33", "#2A3358"
TEXT, MUTED = "#E8EBF7", "#8E97B8"
INDIGO, VIOLET, TEAL, AMBER, RED = "#6C7CFF", "#A27BFF", "#3DDC97", "#FFC94D", "#FF6B6B"
FONT = "Inter, -apple-system, 'Segoe UI', Helvetica, Arial, sans-serif"

out = []
w = out.append


def kt(*times):
    """keyTimes normalizados (0..1) a partir de segundos."""
    return ";".join(f"{min(max(t / T, 0), 1):.4f}" for t in times)


def show(on, off=T - 0.5, fade=0.35, base=0.0, peak=1.0):
    """Animação de opacidade: aparece em `on`, some em `off` (loop de T)."""
    return (f'<animate attributeName="opacity" dur="{T}s" repeatCount="indefinite" '
            f'values="{base};{base};{peak};{peak};{base};{base}" '
            f'keyTimes="{kt(0, on, on + fade, off, off + fade, T)}"/>')


def node(x, y, w_, h, title, sub, on, color=INDIGO, icon=""):
    w(f'<g transform="translate({x},{y})">')
    w(f'<rect width="{w_}" height="{h}" rx="16" fill="{PANEL}" stroke="{LINE}" stroke-width="2"/>')
    w(f'<rect width="{w_}" height="{h}" rx="16" fill="{color}" fill-opacity="0.10" stroke="{color}" '
      f'stroke-width="2.5" opacity="0">{show(on)}</rect>')
    tx = 18
    if icon:
        w(f'<text x="18" y="{h / 2 + 9}" font-size="26">{icon}</text>')
        tx = 56
    w(f'<text x="{tx}" y="{h / 2 - 4}" fill="{TEXT}" font-size="19" font-weight="650">{title}</text>')
    w(f'<text x="{tx}" y="{h / 2 + 20}" fill="{MUTED}" font-size="14.5">{sub}</text>')
    w('</g>')


def check(x, y, on, color=TEAL, r=13):
    w(f'<g transform="translate({x},{y})" opacity="0">{show(on)}'
      f'<circle r="{r}" fill="{color}"/>'
      f'<path d="M{-r * .45} 0 l{r * .3} {r * .32} l{r * .55} {-r * .62}" fill="none" stroke="{BG}" '
      f'stroke-width="3.2" stroke-linecap="round" stroke-linejoin="round"/></g>')


def arrow(d, on=None):
    w(f'<path d="{d}" fill="none" stroke="{LINE}" stroke-width="2.5" stroke-dasharray="6 7"/>')
    if on is not None:
        w(f'<path d="{d}" fill="none" stroke="{AMBER}" stroke-width="2.5" opacity="0">{show(on, fade=.2)}</path>')


def packet(d, t0, t1, color=AMBER):
    """Bolinha que percorre `d` entre t0 e t1 (visível só nesse trecho)."""
    w(f'<circle r="8" fill="{color}" opacity="0" filter="url(#glow)">'
      f'<animateMotion dur="{T}s" repeatCount="indefinite" path="{d}" calcMode="linear" '
      f'keyPoints="0;0;1;1" keyTimes="{kt(0, t0, t1, T)}"/>'
      f'<animate attributeName="opacity" dur="{T}s" repeatCount="indefinite" values="0;0;1;1;0;0" '
      f'keyTimes="{kt(0, t0, t0 + .1, t1 - .05, t1 + .1, T)}"/></circle>')


w(f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}" '
  f'font-family="{FONT}">')
w('<title>DevOps Platform · Lab — do git push à produção</title>')
w(f'''<defs>
  <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">
    <stop offset="0" stop-color="#0B1020"/><stop offset="1" stop-color="#141034"/></linearGradient>
  <linearGradient id="logo" x1="0" y1="0" x2="1" y2="1">
    <stop offset="0" stop-color="#3B5BDB"/><stop offset="1" stop-color="#7048E8"/></linearGradient>
  <linearGradient id="loop" x1="0" y1="0" x2="1" y2="0">
    <stop offset="0" stop-color="#63E6BE"/><stop offset="1" stop-color="#FFD43B"/></linearGradient>
  <filter id="glow" x="-100%" y="-100%" width="300%" height="300%">
    <feGaussianBlur stdDeviation="4" result="b"/><feMerge><feMergeNode in="b"/><feMergeNode in="SourceGraphic"/></feMerge></filter>
</defs>''')
w(f'<rect width="{W}" height="{H}" fill="url(#bg)"/>')

# Cabeçalho -------------------------------------------------------------------
w('<g transform="translate(60,52)">'
  '<rect width="76" height="76" rx="18" fill="url(#logo)"/>'
  '<polygon points="38,12 61,25 61,51 38,64 15,51 15,25" fill="none" stroke="#fff" stroke-opacity=".9" '
  'stroke-width="4" stroke-linejoin="round"/>'
  '<path d="M25 38 C25 30,33 30,38 38 S51 46,51 38 S43 30,38 38 S25 46,25 38 Z" fill="none" '
  'stroke="url(#loop)" stroke-width="4" stroke-linecap="round"/></g>')
w(f'<text x="156" y="88" fill="{TEXT}" font-size="40" font-weight="750">DevOps Platform · Lab</text>')
w(f'<text x="156" y="120" fill="{MUTED}" font-size="19">Do git push à produção: GitOps em Kubernetes local (k3d no Mac)</text>')

# 1) Pipeline -----------------------------------------------------------------
w(f'<text x="60" y="190" fill="{MUTED}" font-size="14" letter-spacing="2">1 · CI (GITHUB ACTIONS)</text>')
xs = [60, 260, 460, 660, 860]
labels = [("git push", "develop/main", "⌨️"), ("Testes", "lint + testes", "🧪"),
          ("Segurança", "Trivy + CodeQL", "🛡️"), ("Imagem", "GHCR, multi-arch", "📦"),
          ("GitOps", "tag no Git", "📝")]
times = [0.4, 1.4, 2.4, 3.4, 4.4]
for x, (t, s, i), on in zip(xs, labels, times):
    node(x, 205, 160, 96, t, s, on, icon=i)
for a, b, on in zip(xs[:-1], xs[1:], times[1:]):
    arrow(f"M{a + 160} 253 L{b} 253", on - .4)
packet("M140 253 L940 253", 0.4, 4.4)
for x, on in zip(xs[1:3], times[1:3]):
    check(x + 148, 213, on + .5)

# 2) ArgoCD ---------------------------------------------------------------------
arrow("M940 301 L940 352 L590 352 L590 392", 4.6)
packet("M940 301 L940 352 L590 352 L590 392", 4.6, 5.3)

# Cluster -----------------------------------------------------------------------
w(f'<rect x="40" y="392" width="1000" height="470" rx="26" fill="#0E1430" stroke="{INDIGO}" '
  f'stroke-opacity=".55" stroke-width="2"/>')
w(f'<text x="64" y="428" fill="{MUTED}" font-size="14" letter-spacing="2">2 · CLUSTER K3D · KUBERNETES 1.34</text>')
node(64, 446, 230, 92, "ArgoCD", "Git é a fonte da verdade", 5.3, VIOLET, "🐙")
node(318, 446, 230, 92, "Kyverno", "admissão: tag, limites", 5.9, VIOLET, "🚦")
node(572, 446, 220, 92, "Sealed Secrets", "segredo cifrado no Git", 5.9, VIOLET, "🔐")
node(816, 446, 200, 92, "HTTPS", "cert-manager", 5.9, VIOLET, "🔒")
arrow("M294 492 L318 492", 5.8)
check(536, 456, 6.2)

# Canary ------------------------------------------------------------------------
w(f'<g transform="translate(64,560)">')
w(f'<rect width="952" height="170" rx="18" fill="{PANEL}" stroke="{LINE}" stroke-width="2"/>')
w(f'<text x="22" y="34" fill="{TEXT}" font-size="20" font-weight="650">🚀 Argo Rollouts · canary em produção</text>')
w(f'<text x="22" y="58" fill="{MUTED}" font-size="15">a versão nova recebe parte dos requests; o Prometheus mede os 5xx dela a cada passo</text>')
BX, BY, BW, BH = 22, 82, 700, 34
w(f'<rect x="{BX}" y="{BY}" width="{BW}" height="{BH}" rx="10" fill="{INDIGO}" fill-opacity=".35"/>')
w(f'<text x="{BX + 14}" y="{BY + 23}" fill="{TEXT}" font-size="15" font-weight="600">v1 estável</text>')
steps = [(0, 6.3), (.2, 6.8), (.2, 8.2), (.5, 8.7), (.5, 10.2), (1, 10.7), (1, 12.8), (0, 13.4)]
vals = ";".join(f"{BW * p:.0f}" for p, _ in [(0, 0)] + steps + [(0, T)])
kts = kt(0, *[t for _, t in steps], T)
w(f'<rect x="{BX + BW}" y="{BY}" width="0" height="{BH}" rx="10" fill="{AMBER}" transform="scale(-1,1)" '
  f'transform-origin="{BX + BW} 0">'
  f'<animate attributeName="width" dur="{T}s" repeatCount="indefinite" values="{vals}" keyTimes="{kts}"/></rect>')
for pct, on, off in [("20%", 6.8, 8.6), ("50%", 8.7, 10.6), ("100%", 10.7, 12.8)]:
    w(f'<text x="{BX + BW + 22}" y="{BY + 24}" fill="{AMBER}" font-size="24" font-weight="750" opacity="0">'
      f'v2 · {pct}{show(on, off, fade=.2)}</text>')
w(f'<text x="22" y="{BY + 66}" fill="{MUTED}" font-size="15">análise: taxa de 5xx da v2 &lt; 5%</text>')
for i, on in enumerate([7.3, 9.3, 11.2]):
    check(268 + i * 34, BY + 61, on, r=11)
w(f'<text x="390" y="{BY + 66}" fill="{MUTED}" font-size="15">· reprovou → volta sozinho para a v1</text>')
w('</g>')

# Namespaces / rede ------------------------------------------------------------
w(f'<text x="64" y="768" fill="{MUTED}" font-size="14" letter-spacing="2">PROJETOS ISOLADOS · NETWORKPOLICY DEFAULT-DENY</text>')
for i, (ns, c) in enumerate([("crivo", TEAL), ("wlstore", INDIGO), ("nest-rabbitmq", VIOLET)]):
    x = 64 + i * 318
    w(f'<g transform="translate({x},784)"><rect width="294" height="56" rx="14" fill="{PANEL}" stroke="{c}" '
      f'stroke-opacity=".7" stroke-width="2"/>'
      f'<circle cx="30" cy="28" r="9" fill="{c}"><animate attributeName="opacity" values="1;.35;1" dur="2.4s" '
      f'begin="{i * .5}s" repeatCount="indefinite"/></circle>'
      f'<text x="52" y="25" fill="{TEXT}" font-size="17" font-weight="600">{ns}</text>'
      f'<text x="52" y="45" fill="{MUTED}" font-size="13.5">develop · prod · 🛡️ isolado</text></g>')

# Banner final ------------------------------------------------------------------
w(f'<g opacity="0">{show(11.4, 13.1)}'
  f'<rect x="300" y="350" width="480" height="52" rx="26" fill="{TEAL}"/>'
  f'<text x="540" y="384" fill="{BG}" font-size="21" font-weight="750" text-anchor="middle">✓ v2 em produção, sem downtime</text></g>')

# 3) Observabilidade -------------------------------------------------------------
w(f'<text x="60" y="900" fill="{MUTED}" font-size="14" letter-spacing="2">3 · OBSERVABILIDADE E ALERTAS</text>')
chips = [("Prometheus", AMBER), ("Grafana", AMBER), ("Loki", AMBER), ("Alertmanager", RED), ("SLO 99,5%", TEAL)]
x = 60
for label, c in chips:
    cw = 26 + len(label) * 10.5
    w(f'<g transform="translate({x},914)"><rect width="{cw:.0f}" height="42" rx="21" fill="{c}" fill-opacity=".14" '
      f'stroke="{c}" stroke-opacity=".7"/><text x="{cw / 2:.0f}" y="27" fill="{TEXT}" font-size="16" '
      f'font-weight="600" text-anchor="middle">{label}</text></g>')
    x += cw + 12
spark = "M790 950 L820 938 L850 944 L880 926 L910 932 L940 916 L970 922 L1000 908"
w(f'<path d="{spark}" fill="none" stroke="{TEAL}" stroke-width="3" stroke-linecap="round" stroke-dasharray="260" '
  f'stroke-dashoffset="260"><animate attributeName="stroke-dashoffset" values="260;0;0" keyTimes="0;.6;1" '
  f'dur="3.5s" repeatCount="indefinite"/></path>')

# Rodapé ------------------------------------------------------------------------
w(f'<line x1="60" y1="990" x2="1020" y2="990" stroke="{LINE}" stroke-width="1.5"/>')
w(f'<text x="60" y="1030" fill="{MUTED}" font-size="17">github.com/infra-devops-full/infra</text>')
w(f'<text x="1020" y="1030" fill="{MUTED}" font-size="17" text-anchor="end">#DevOps #Kubernetes #GitOps #ArgoCD</text>')
w('</svg>')

path = os.path.join(ROOT, "docs", "media", "infra-lab.svg")
os.makedirs(os.path.dirname(path), exist_ok=True)
with open(path, "w") as f:
    f.write("\n".join(out) + "\n")
print(path)
