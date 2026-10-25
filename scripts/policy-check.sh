#!/usr/bin/env bash
# =============================================================================
# policy-check.sh  (genérico)
# -----------------------------------------------------------------------------
# Testa as políticas do Kyverno (k8s/kyverno-pod-policies.yaml) contra TODOS
# os apps renderizados (charts/app × projects/<p>/apps/<app>/values-<env>.yaml;
# Rollouts são testados como Deployment — o pod é o mesmo)
# SEM cluster — o mesmo veredito que o cluster daria no sync do ArgoCD, mas
# antes do commit (make policy-check) e no CI (validate.yml).
#
# Falha se alguma política Deny recusaria um app. Violações de políticas
# Audit aparecem, mas não falham.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
KYVERNO_CLI_IMAGE="reg.kyverno.io/kyverno/kyverno-cli:v1.19.2"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/resources"

cd "$INFRA_ROOT"
# Labels dos namespaces: as políticas só valem onde há devops-platform/project.
printf 'apiVersion: cli.kyverno.io/v1alpha1\nkind: Values\nmetadata:\n  name: values\nnamespaceSelector:\n' > "$WORK/values.yaml"
namespaces=""
for f in projects/*/apps/*/values-*.yaml; do
  dir="$(dirname "$f")"; app="$(basename "$dir")"
  proj="$(basename "$(dirname "$(dirname "$dir")")")"
  env="$(basename "$f" .yaml)"; env="${env#values-}"
  ns="$proj-$env"
  helm template "$app" charts/app --namespace "$ns" \
    -f "$dir/values.yaml" -f "$f" \
    --set "app.name=$app,app.environment=$env,app.project=$proj" \
    | yq "select(.kind == \"Deployment\" or .kind == \"Rollout\")
          | .metadata.namespace = \"$ns\"
          | .apiVersion = \"apps/v1\" | .kind = \"Deployment\" | del(.spec.strategy)" \
    > "$WORK/resources/$proj-$app-$env.yaml"
  case " $namespaces " in
    *" $ns "*) ;;
    *) namespaces="$namespaces $ns"
       printf '  - name: %s\n    labels:\n      devops-platform/project: %s\n' "$ns" "$proj" >> "$WORK/values.yaml" ;;
  esac
done
cp k8s/kyverno-pod-policies.yaml "$WORK/policies.yaml"

echo "▸ Kyverno CLI: $(find "$WORK/resources" -name '*.yaml' | wc -l | tr -d ' ') apps renderizados × políticas"
# Sai com código != 0 quando há violação: quem decide é a análise abaixo.
docker run --rm -v "$WORK:/w" "$KYVERNO_CLI_IMAGE" apply /w/policies.yaml \
  --resource /w/resources --values-file /w/values.yaml --policy-report \
  2>/dev/null | sed -n '/^apiVersion:/,$p' > "$WORK/report.yaml" || true

[[ -s "$WORK/report.yaml" ]] || { echo "❌ o Kyverno CLI não gerou relatório"; exit 1; }

# Uma linha por violação: resultado, política, recurso.
yq -r '.results[] | select(.result == "fail" or .result == "warn" or .result == "error")
  | [.result, .policy, (.resources[0].namespace + "/" + .resources[0].name), .message] | @tsv' \
  "$WORK/report.yaml" > "$WORK/violations.tsv"

enforced="$(yq -r 'select(.spec.validationActions[] == "Deny") | .metadata.name' "$WORK/policies.yaml")"
blocking=0
while IFS=$'\t' read -r _result policy resource message; do
  [[ -z "$policy" ]] && continue
  if grep -qx "$policy" <<<"$enforced"; then
    echo "  ✗ [Deny]  $policy  $resource: $message"; blocking=1
  else
    echo "  ⚠ [Audit] $policy  $resource: $message"
  fi
done < "$WORK/violations.tsv"

pass="$(yq -r '[.results[] | select(.result == "pass")] | length' "$WORK/report.yaml")"
if [[ "$blocking" == 1 ]]; then
  echo "❌ Algum app seria RECUSADO pelo cluster (políticas Deny acima)."
  exit 1
fi
echo "✅ Políticas OK ($pass verificações passaram; avisos de Audit não bloqueiam)"
