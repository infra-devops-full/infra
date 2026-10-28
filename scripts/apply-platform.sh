#!/usr/bin/env bash
# =============================================================================
# apply-platform.sh  (genérico)
# -----------------------------------------------------------------------------
# Aplica os manifests genéricos da plataforma:
#   argocd/*.yaml  AppProject + ApplicationSet que descobrem os projetos no Git
#                  (renderizados com envsubst: ${INFRA_REPO_URL} ${INFRA_BRANCH})
#   k8s/*.yaml     manifests de plataforma (dashboards e datasources do Grafana)
#                  (renderizados com envsubst: ${INFRA_RAW_URL})
#
# Uso:
#   ./scripts/apply-platform.sh            # aplica
#   ./scripts/apply-platform.sh --render   # só mostra o que seria aplicado
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
if [[ -f "$INFRA_ROOT/.env" ]]; then
  set -a; # shellcheck disable=SC1091
  source "$INFRA_ROOT/.env"; set +a
fi
# shellcheck source=lib-project.sh
source "$SCRIPT_DIR/lib-project.sh"

INFRA_REPO_URL="$(infra_repo_url)"
INFRA_BRANCH="${INFRA_BRANCH:-main}"
# Arquivos do repo de infra servidos pelo GitHub (logos dos projetos no Grafana).
INFRA_SLUG="$(sed -E 's#^(https://github.com/|git@github.com:)##; s#\.git$##; s#/$##' <<<"$INFRA_REPO_URL")"
INFRA_RAW_URL="https://raw.githubusercontent.com/${INFRA_SLUG}/${INFRA_BRANCH}"
# Quem pode assinar imagens (k8s/kyverno-image-signatures.yaml): os workflows
# deploy.yml/release.yml dos repos de app declarados em projects/.
SIGNING_REPOS="$(for P in $(project_names); do project_app_repos "$P"; done \
  | sed -E 's#^https://github.com/##; s#\.git$##; s#/$##' | sort -u | sed 's/[.]/\\./g' | paste -sd '|' -)"
SIGNING_SUBJECT_REGEX="^https://github\\.com/(${SIGNING_REPOS})/\\.github/workflows/(deploy|release)\\.yml@refs/.+\$"
export INFRA_REPO_URL INFRA_BRANCH INFRA_RAW_URL SIGNING_SUBJECT_REGEX

if [[ -z "$INFRA_REPO_URL" ]]; then
  echo "❌ INFRA_REPO_URL vazio (defina no .env ou configure o git remote origin)"
  exit 1
fi

CHECK_KINDS=false

# O cluster conhece todos os kinds do arquivo? (CRDs do Kyverno, cert-manager,
# Prometheus Operator...). Evita que um componente ainda não instalado faça o
# apply inteiro falhar.
kinds_available() {
  local gv kind
  while IFS=' ' read -r gv kind; do
    [[ -z "$kind" ]] && continue
    # Última coluna do api-resources = KIND (compara exato: o nome do recurso
    # é plural e irregular — ValidatingPolicy → validatingpolicies).
    kubectl api-resources --api-group="$(sed -E 's#/?v[0-9]+[a-z0-9]*$##' <<<"$gv")" --no-headers 2>/dev/null \
      | awk '{print $NF}' | grep -qx "$kind" || { echo "$gv/$kind"; return 1; }
  done < <(yq -N 'select(.kind != null) | .apiVersion + " " + .kind' "$1" | sort -u)
}

render() {
  local f missing
  for f in "$INFRA_ROOT"/argocd/*.yaml; do
    echo "---"
    envsubst '${INFRA_REPO_URL} ${INFRA_BRANCH}' < "$f"
  done
  # Só ${INFRA_RAW_URL} é substituído: as variáveis do Grafana ($app,
  # ${project}...) passam intactas.
  for f in "$INFRA_ROOT"/k8s/*.yaml; do
    if $CHECK_KINDS && ! missing="$(kinds_available "$f")"; then
      echo "⚠ pulando k8s/$(basename "$f"): o cluster não conhece $missing (rode make security / make observability)" >&2
      continue
    fi
    echo "---"
    envsubst '${INFRA_RAW_URL} ${SIGNING_SUBJECT_REGEX}' < "$f"
  done
}

if [[ "${1:-}" == "--render" ]]; then
  render
  exit 0
fi

echo "▸ ArgoCD observando $INFRA_REPO_URL ($INFRA_BRANCH)"
CHECK_KINDS=true
# Server-side apply: sem a annotation last-applied-configuration (limite de
# 256 KB), que os dashboards grandes do Grafana estourariam.
render | kubectl apply --server-side --field-manager=devops-platform --force-conflicts -f -

# Cluster novo: os ApplicationSets de apps e de segredos geram tudo na hora,
# antes de o platform-projects criar os AppProjects ("application references
# project <p> which does not exist"), e o controller só tenta de novo minutos
# depois. Espera os AppProjects e pede a regeneração.
EXPECTED="$(project_names | sort | xargs)"
for _ in $(seq 1 60); do
  # `|| true`: sem AppProject de projeto ainda, o grep não acha nada e sai
  # com 1 — com pipefail, isso encerraria o script em silêncio.
  HAVE="$(kubectl get appprojects -n argocd -o name 2>/dev/null | sed 's#.*/##' | { grep -vxE 'default|platform' || true; } | sort | xargs)"
  [[ "$HAVE" == "$EXPECTED" ]] && break
  sleep 3
done
for a in $(kubectl get applicationsets -n argocd -o name 2>/dev/null); do
  kubectl -n argocd annotate "$a" argocd.argoproj.io/application-set-refresh=true --overwrite >/dev/null
done
echo "✅ Plataforma aplicada (argocd/ + k8s/)"
