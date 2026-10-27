#!/usr/bin/env bash
# =============================================================================
# apply-project.sh  (genérico)
# -----------------------------------------------------------------------------
# Prepara no cluster o que o ArgoCD NÃO cria para um projeto. Idempotente.
#
#   1. namespaces <projeto>-<env>     (um por values-<env>.yaml encontrado), com
#      os labels que ligam NetworkPolicies/Kyverno e o Pod Security "baseline"
#   2. SealedSecrets do projeto       (projects/<p>/sealed/<env>/, gerados por
#                                      `make seal`) → o controller cria os
#                                      Secrets postgres/rabbitmq/redis/app-secrets
#   3. dependências declaradas no project.yaml: Postgres, Redis, RabbitMQ
#      (leem as credenciais dos Secrets do passo 2)
#   4. ghcr-secret                    (se GITHUB_TOKEN disponível)
#
# Os apps e os SealedSecrets também são reconciliados pelo ArgoCD a partir do
# Git (argocd/applicationset*.yaml); aplicar os SealedSecrets aqui garante que
# os Secrets existam antes de subir as dependências. O /etc/hosts é atualizado à parte:
# ./scripts/hosts.sh apply
#
# Uso:
#   ./scripts/apply-project.sh <projeto>
# =============================================================================

set -euo pipefail

PROJ="${1:-}"
if [[ -z "$PROJ" ]]; then
  echo "Uso: $0 <projeto>"
  exit 1
fi

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
step() { echo -e "${CYAN}▸ [$PROJ] $1${NC}"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
if [[ -f "$INFRA_ROOT/.env" ]]; then
  set -a; # shellcheck disable=SC1091
  source "$INFRA_ROOT/.env"; set +a
fi
# shellcheck source=lib-project.sh
source "$SCRIPT_DIR/lib-project.sh"

if [[ ! -f "$(project_manifest "$PROJ")" ]]; then
  echo "❌ projects/$PROJ/project.yaml não encontrado"
  exit 1
fi

ENVS="$(project_envs "$PROJ" | xargs)"
if [[ -z "$ENVS" ]]; then
  echo "❌ nenhum projects/$PROJ/apps/<app>/values-<env>.yaml encontrado"
  exit 1
fi
NAMESPACES="$(project_namespaces "$PROJ" | xargs)"

# 1. Namespaces ---------------------------------------------------------------
step "namespaces: $NAMESPACES"
for NS in $NAMESPACES; do
  kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  # devops-platform/project: o Kyverno gera as NetworkPolicies e aplica as
  # políticas neste namespace. pod-security: o Kubernetes recusa pods
  # privilegiados/hostPath/hostNetwork (perfil "baseline") e avisa no apply o
  # que ainda falta para o perfil "restricted".
  kubectl label namespace "$NS" --overwrite >/dev/null \
    devops-platform/project="$PROJ" \
    pod-security.kubernetes.io/enforce=baseline \
    pod-security.kubernetes.io/enforce-version=latest \
    pod-security.kubernetes.io/warn=restricted \
    pod-security.kubernetes.io/warn-version=latest
done

# 2. SealedSecrets ------------------------------------------------------------
for ENV_NAME in $ENVS; do
  SDIR="$(project_dir "$PROJ")/sealed/$ENV_NAME"
  if [[ ! -d "$SDIR" ]] || [[ -z "$(ls "$SDIR"/*.yaml 2>/dev/null)" ]]; then
    if project_db_enabled "$PROJ" || project_redis_enabled "$PROJ" || project_rabbitmq_enabled "$PROJ"; then
      echo "❌ projects/$PROJ/sealed/$ENV_NAME/ não existe — rode \`make seal PROJECT=$PROJ\` e commite"
      exit 1
    fi
    continue
  fi
  step "SealedSecrets ($ENV_NAME)"
  # Secrets criados no modelo antigo (sem dono) não são sobrescritos pelo
  # controller; a anotação managed=true autoriza a adoção.
  for f in "$SDIR"/*.yaml; do
    NAME="$(yq -r '.metadata.name' "$f")"
    if kubectl get secret "$NAME" -n "${PROJ}-${ENV_NAME}" >/dev/null 2>&1 && \
       [[ -z "$(kubectl get secret "$NAME" -n "${PROJ}-${ENV_NAME}" -o jsonpath='{.metadata.ownerReferences[?(@.kind=="SealedSecret")].name}')" ]]; then
      kubectl annotate secret "$NAME" -n "${PROJ}-${ENV_NAME}" sealedsecrets.bitnami.com/managed=true --overwrite >/dev/null
    fi
  done
  kubectl apply -f "$SDIR" >/dev/null
  # Espera o controller abrir cada SealedSecret no Secret correspondente.
  for f in "$SDIR"/*.yaml; do
    NAME="$(yq -r '.metadata.name' "$f")"
    owned() { [[ -n "$(kubectl get secret "$NAME" -n "${PROJ}-${ENV_NAME}" -o jsonpath='{.metadata.ownerReferences[?(@.kind=="SealedSecret")].name}' 2>/dev/null)" ]]; }
    for _ in $(seq 1 30); do owned && break; sleep 2; done
    owned || { echo "❌ o controller não abriu $NAME em ${PROJ}-${ENV_NAME} (chave diferente? veja make doctor e kubectl describe sealedsecret $NAME -n ${PROJ}-${ENV_NAME})"; exit 1; }
  done
done

# 3. Dependências -------------------------------------------------------------
for NS in $NAMESPACES; do
  if project_db_enabled "$PROJ"; then
    step "Postgres em $NS"
    bash "$SCRIPT_DIR/setup-postgres.sh" --namespace "$NS" \
      --extra-dbs "$(project_db_extras "$PROJ")" \
      --instances "$(project_db_instances "$PROJ" "${NS#"$PROJ"-}")" \
      --storage "$(project_db_storage "$PROJ")" \
      --retention "$(project_db_retention "$PROJ")"
  fi
  if project_redis_enabled "$PROJ"; then
    step "Redis em $NS"
    bash "$SCRIPT_DIR/setup-redis.sh" --namespace "$NS"
  fi
  if project_rabbitmq_enabled "$PROJ"; then
    step "RabbitMQ em $NS"
    bash "$SCRIPT_DIR/setup-rabbitmq.sh" --namespace "$NS"
  fi
done

# 4. ghcr-secret --------------------------------------------------------------
if [[ -n "${GITHUB_TOKEN:-}" && "${GITHUB_TOKEN}" != ghp_your_github_token_here ]]; then
  step "ghcr-secret"
  bash "$INFRA_ROOT/create-ghcr-secrets.sh" --namespaces "$NAMESPACES" >/dev/null || \
    echo -e "  ${YELLOW}⚠️  falha ao criar ghcr-secret (confira GITHUB_TOKEN/GITHUB_USERNAME)${NC}"
else
  echo -e "  ${YELLOW}⚠️  GITHUB_TOKEN ausente: imagens privadas do GHCR não vão baixar.${NC}"
  echo -e "     make ghcr NAMESPACES=\"$NAMESPACES\" TOKEN=<token>"
fi

echo -e "${GREEN}✅ Projeto '$PROJ' preparado — o ArgoCD cria os apps a partir do Git${NC}"
