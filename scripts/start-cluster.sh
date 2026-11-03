#!/usr/bin/env bash
# =============================================================================
# start-cluster.sh  (genérico) — liga o cluster k3d do jeito certo
# -----------------------------------------------------------------------------
# Por que existe: depois de reiniciar o Mac o cluster não voltava. O k3s usa
# etcd embutido (--cluster-init), e o etcd grava o IP do server como
# identidade do membro. A rede do k3d entregava IP por ordem de chegada:
# quem ligasse primeiro (registry, backup S3, o container "tools" que o
# `k3d cluster start` cria) pegava o IP do server, o server voltava com outro,
# e o k3s ficava preso em "this server is not a member of the etcd cluster"
# — containers "Up", API morta, `make status` vazio.
#
# A correção tem duas partes:
#   - nodes com IP FIXO na rede (cluster novo: `subnet` no k3d-config, o k3d
#     fixa sozinho; cluster antigo: docs/24-cluster-local.md, uma vez);
#   - ligar NA ORDEM, com `docker start`: server → API → agents → LB →
#     auxiliares (registry, backup). Auxiliares por último porque têm IP
#     dinâmico: ligando depois, só sobram IPs livres para eles. Sem
#     `k3d cluster start`, que cria o tools antes do server.
#   Nada disso fica a cargo do Docker: auto-restart desligado em todos.
#
# Uso:
#   ./scripts/start-cluster.sh            # make start
#   ./scripts/start-cluster.sh --login    # launchd (make autostart): espera o Docker subir antes
#   ./scripts/start-cluster.sh --no-restart-policy   # só desliga o auto-restart (setup.sh)
# =============================================================================

set -euo pipefail

MODE="${1:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$INFRA_ROOT/.env" ]] && set -a && . "$INFRA_ROOT/.env" && set +a
CLUSTER_NAME="${CLUSTER_NAME:-devops-lab}"
NETWORK="k3d-$CLUSTER_NAME"
API_TIMEOUT="${API_TIMEOUT:-300}"   # segundos esperando a API e os nodes

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
ok()   { echo -e "${GREEN}✅ $*${NC}"; }
info() { echo -e "${YELLOW}➜  $*${NC}"; }
warn() { echo -e "${YELLOW}⚠️  $*${NC}"; }
fail() { echo -e "${RED}❌ $*${NC}" >&2; exit 1; }

by_role() {
  docker ps -aq --filter "label=k3d.cluster=$CLUSTER_NAME" --filter "label=k3d.role=$1"
}

# Registry do k3d e backup S3 (lib-backup.sh): ficam na rede do cluster.
aux_containers() {
  local c
  for c in registry.devops.local "${CLUSTER_NAME}-backup"; do
    docker ps -aq --filter "name=^${c}$"
  done
}

all_containers() {
  by_role server; by_role agent; by_role loadbalancer; aux_containers
}

disable_auto_restart() {
  local ids
  ids="$(all_containers | xargs)"
  [[ -n "$ids" ]] || return 0
  # shellcheck disable=SC2086
  docker update --restart=no $ids >/dev/null
}

# IP fixo na rede do cluster? (IPAMConfig preenchido = o Docker não sorteia)
has_static_ip() {
  [[ "$(docker inspect -f "{{with index .NetworkSettings.Networks \"$NETWORK\"}}{{with .IPAMConfig}}{{.IPv4Address}}{{end}}{{end}}" "$1" 2>/dev/null)" != "" ]]
}

# Pergunta de DENTRO do server: o kubeconfig do Mac passa pelo load balancer,
# que só liga depois da API.
kube() {
  docker exec "$NETWORK-server-0" kubectl --request-timeout=5s "$@" 2>/dev/null
}

api_ready() {
  kube get --raw=/readyz >/dev/null
}

nodes_ready() {
  local nodes
  nodes="$(kube get nodes --no-headers)" || return 1
  [[ -n "$nodes" ]] && ! awk '$2!="Ready"{bad=1} END{exit !bad}' <<<"$nodes"
}

wait_until() { # descrição, função
  SECONDS=0
  until "$2"; do
    (( SECONDS < API_TIMEOUT )) || fail "$1 não ficou pronto em ${API_TIMEOUT}s. Veja: docker logs --since 10m $NETWORK-server-0 | grep -v memcache | tail -30"
    sleep 5
  done
}

wait_docker() {
  local _
  for _ in $(seq 1 60); do
    docker info >/dev/null 2>&1 && return 0
    sleep 5
  done
  fail "Docker não respondeu em 5 min"
}

start_ids() { # ids... (docker start ignora quem já está rodando)
  [[ $# -gt 0 ]] || return 0
  docker start "$@" >/dev/null
}

# -----------------------------------------------------------------------------
[[ "$MODE" == "--login" ]] && { echo "[$(date '+%F %T')] login: esperando o Docker..."; wait_docker; }
docker info >/dev/null 2>&1 || fail "Docker não está rodando (abra o Docker Desktop)"
[[ -n "$(by_role server)" ]] || fail "Cluster '$CLUSTER_NAME' não existe (make setup)"

disable_auto_restart
[[ "$MODE" == "--no-restart-policy" ]] && exit 0

for id in $(by_role server) $(by_role agent); do
  has_static_ip "$id" || warn "$(docker inspect -f '{{.Name}}' "$id" | tr -d /) sem IP fixo na rede: pode não voltar depois de reiniciar o Mac (docs/24-cluster-local.md)"
done

if api_ready && nodes_ready && kubectl --context "k3d-$CLUSTER_NAME" --request-timeout=5s get --raw=/readyz >/dev/null 2>&1; then
  ok "Cluster '$CLUSTER_NAME' já está no ar"
  # shellcheck disable=SC2046
  start_ids $(aux_containers)
  exit 0
fi

# Containers "Up" com a API morta (largada errada): para tudo e liga na ordem.
# shellcheck disable=SC2046
if [[ -n "$(docker ps -q $(printf -- '--filter id=%s ' $(all_containers)))" ]]; then
  info "Cluster de pé pela metade: parando para ligar na ordem (dados preservados)..."
  k3d cluster stop "$CLUSTER_NAME" >/dev/null
  # shellcheck disable=SC2046
  docker stop $(aux_containers) >/dev/null 2>&1 || true
fi
docker rm -f "$NETWORK-tools" >/dev/null 2>&1 || true

info "Server..."
# shellcheck disable=SC2046
start_ids $(by_role server)
wait_until "A API" api_ready

info "Agents e load balancer..."
# shellcheck disable=SC2046
start_ids $(by_role agent) $(by_role loadbalancer)
wait_until "Os nodes" nodes_ready

info "Auxiliares (registry, backup S3)..."
# shellcheck disable=SC2046
start_ids $(aux_containers)

ok "Cluster '$CLUSTER_NAME' no ar — os pods ainda levam alguns minutos (make status)"
