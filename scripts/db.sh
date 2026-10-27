#!/usr/bin/env bash
# =============================================================================
# db.sh  (genérico) — operação do Postgres de um projeto/ambiente.
# -----------------------------------------------------------------------------
#   db.sh status       <projeto> <env>   instâncias, primário, backups, janela de restauração
#   db.sh backup       <projeto> <env>   backup base agora (além do diário)
#   db.sh restore      <projeto> <env> [TIME] [FROM]
#                                        RECRIA o banco a partir do backup (PITR com TIME)
#   db.sh restore-test <projeto> <env>   restaura numa cópia temporária, compara e apaga
#   db.sh psql         <projeto> <env> [DB]
#
# Chamado pelo Makefile (make db-*). docs/21-banco-de-dados.md
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-project.sh
source "$SCRIPT_DIR/lib-project.sh"
# shellcheck source=lib-backup.sh
source "$SCRIPT_DIR/lib-backup.sh"

CMD="${1:-}"; PROJ="${2:-}"; ENV_NAME="${3:-}"
if [[ -z "$CMD" || -z "$PROJ" || -z "$ENV_NAME" ]]; then
  echo "Uso: $0 <status|backup|restore|restore-test|psql> <projeto> <env>"; exit 1
fi
NS="${PROJ}-${ENV_NAME}"
PLUGIN="barman-cloud.cloudnative-pg.io"

kubectl get cluster postgres -n "$NS" >/dev/null 2>&1 || {
  echo "❌ $NS não tem Postgres (project.yaml sem database:, ou rode make project-apply PROJECT=$PROJ)"; exit 1; }

primary() { kubectl get cluster "${1:-postgres}" -n "$NS" -o jsonpath='{.status.currentPrimary}'; }
psql_in() { local pod="$1"; shift; kubectl exec -n "$NS" "$pod" -c postgres -- psql -X -At "$@"; }
step() { echo -e "\033[0;36m▸ $1\033[0m"; }

# Bancos de aplicação (sem os de sistema).
app_dbs() { psql_in "$1" -d postgres -c "select datname from pg_database where not datistemplate and datname <> 'postgres' order by 1"; }
# Tabelas e linhas (contagem exata) de um banco: "tabelas linhas".
db_summary() {
  psql_in "$1" -d "$2" -F' ' -c "
    select count(*), coalesce(sum((xpath('/row/c/text()', query_to_xml(
             format('select count(*) as c from %I.%I', table_schema, table_name), false, true, '')))[1]::text::bigint), 0)
    from information_schema.tables
    where table_type = 'BASE TABLE' and table_schema not in ('pg_catalog', 'information_schema')"
}

wait_ready() {
  local name="$1" t="${2:-600}"
  for _ in $(seq 1 30); do
    kubectl get cluster "$name" -n "$NS" -o jsonpath='{.status.conditions}' 2>/dev/null | grep -q '"Ready"' && break
    sleep 2
  done
  kubectl wait "cluster/$name" -n "$NS" --for=condition=Ready --timeout="${t}s" >/dev/null
}

case "$CMD" in
  status)
    kubectl get cluster postgres -n "$NS"
    echo
    kubectl get pods -n "$NS" -l cnpg.io/cluster=postgres -L cnpg.io/instanceRole
    echo
    step "Backups recentes"
    kubectl get backups -n "$NS" --sort-by=.metadata.creationTimestamp 2>/dev/null | tail -6
    echo
    step "Janela de restauração (PITR)"
    kubectl get objectstore backup -n "$NS" -o json | yq -p json -o yaml -r '
      .status.serverRecoveryWindow // {} | to_entries[] |
      "  " + .key + ":  de " + (.value.firstRecoverabilityPoint // "?") + "  até agora   (último backup base " + (.value.lastSuccessfulBackupTime // "?") + ")"'
    echo "  serverName em uso: $(kubectl get cluster postgres -n "$NS" -o jsonpath='{.spec.plugins[0].parameters.serverName}')"
    echo "  no S3 ($(backup_container)): $(backup_servers "$NS" | xargs)"
    ;;

  backup)
    NAME="manual-$(date -u +%Y%m%d%H%M%S)"
    step "Backup base $NAME"
    kubectl apply -f - >/dev/null <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata: { name: ${NAME}, namespace: ${NS} }
spec:
  cluster: { name: postgres }
  method: plugin
  pluginConfiguration: { name: ${PLUGIN} }
EOF
    for _ in $(seq 1 150); do
      P="$(kubectl get backup "$NAME" -n "$NS" -o jsonpath='{.status.phase}')"
      [[ "$P" == completed || "$P" == failed ]] && break
      sleep 2
    done
    kubectl get backup "$NAME" -n "$NS"
    [[ "$P" == completed ]] || { echo "❌ backup não concluiu (kubectl describe backup $NAME -n $NS)"; exit 1; }
    echo -e "\033[0;32m✅ backup concluído\033[0m"
    ;;

  restore)
    TARGET_TIME="${4:-}"; FROM="${5:-}"
    echo -e "\033[1;33m⚠️  Isto APAGA o Postgres de $NS e o recria a partir do backup"
    echo -e "   ${TARGET_TIME:+até $TARGET_TIME}${TARGET_TIME:-até o último WAL arquivado}. Os apps ficam sem banco por ~2 min.\033[0m"
    if [[ "${YES:-}" != 1 ]]; then
      read -r -p "Digite o namespace ($NS) para confirmar: " ANS
      [[ "$ANS" == "$NS" ]] || { echo "Cancelado."; exit 1; }
    fi
    # Sem TIME: força a troca do arquivo de WAL e espera ele chegar no S3,
    # para a restauração incluir as últimas escritas.
    if [[ -z "$TARGET_TIME" ]]; then
      P="$(primary)"
      WAL="$(psql_in "$P" -d postgres -c "select pg_walfile_name(pg_switch_wal())")"
      step "Esperando o WAL $WAL chegar no S3"
      for _ in $(seq 1 60); do
        LAST="$(psql_in "$P" -d postgres -c "select coalesce(last_archived_wal, '') from pg_stat_archiver")"
        [[ "$LAST" > "$WAL" || "$LAST" == "$WAL" ]] && break
        sleep 2
      done
    fi
    START=$(date +%s)
    ARGS=(--namespace "$NS" --reset
      --extra-dbs "$(project_db_extras "$PROJ")"
      --instances "$(project_db_instances "$PROJ" "$ENV_NAME")"
      --storage "$(project_db_storage "$PROJ")"
      --retention "$(project_db_retention "$PROJ")")
    [[ -n "$FROM" ]] && ARGS+=(--from "$FROM")
    [[ -n "$TARGET_TIME" ]] && ARGS+=(--target-time "$TARGET_TIME")
    bash "$SCRIPT_DIR/setup-postgres.sh" "${ARGS[@]}"
    echo -e "\033[0;32m✅ restaurado em $(( $(date +%s) - START ))s. Os apps reconectam sozinhos; se algum ficar com erro: make rollout SERVICE=<app> NAMESPACE=$NS\033[0m"
    ;;

  restore-test)
    # Prova que o backup VOLTA: restaura numa cópia ao lado (o banco em uso
    # não é tocado), compara tabelas e linhas e apaga a cópia.
    # TIME: restaura a cópia até esse instante. KEEP=1: mantém a cópia (para
    # recuperar só algumas linhas sem mexer no banco em uso).
    T=postgres-restore-test; TARGET_TIME="${4:-}"
    SERVER="$(kubectl get cluster postgres -n "$NS" -o jsonpath='{.spec.plugins[0].parameters.serverName}')"
    kubectl delete cluster "$T" -n "$NS" --ignore-not-found --wait=true >/dev/null
    # O delete volta antes dos discos sumirem; a cópia nova adotaria o antigo.
    for _ in $(seq 1 90); do
      [[ -z "$(kubectl get pods,pvc -n "$NS" -l cnpg.io/cluster="$T" -o name)" ]] && break
      sleep 2
    done
    step "Restaurando $SERVER${TARGET_TIME:+ até $TARGET_TIME} numa cópia ($T)"
    START=$(date +%s)
    kubectl apply -f - >/dev/null <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata: { name: ${T}, namespace: ${NS} }
spec:
  instances: 1
  imageName: $(kubectl get cluster postgres -n "$NS" -o jsonpath='{.spec.imageName}')
  storage: { size: $(kubectl get cluster postgres -n "$NS" -o jsonpath='{.spec.storage.size}') }
  resources:
    requests: { cpu: 50m, memory: 128Mi }
    limits: { memory: 512Mi }
  bootstrap:
    recovery:
      source: origem$( [[ -n "$TARGET_TIME" ]] && printf '\n      recoveryTarget: { targetTime: "%s" }' "$TARGET_TIME")
  externalClusters:
    - name: origem
      plugin:
        name: ${PLUGIN}
        parameters: { barmanObjectName: backup, serverName: ${SERVER} }
EOF
    cleanup() { kubectl delete cluster "$T" -n "$NS" --ignore-not-found --wait=false >/dev/null; }
    [[ "${KEEP:-}" == 1 ]] || trap cleanup EXIT
    wait_ready "$T" 900 || { echo "❌ a restauração não ficou pronta: kubectl get pods -n $NS -l cnpg.io/cluster=$T"; exit 1; }
    RTO=$(( $(date +%s) - START ))
    LIVE="$(primary)"; COPY="$(primary "$T")"
    printf "\n  %-18s %22s %22s\n" "banco" "em uso (tab/linhas)" "restaurado (tab/linhas)"
    OK=true
    for db in $(app_dbs "$LIVE"); do
      read -r LT LR <<<"$(db_summary "$LIVE" "$db")"
      if psql_in "$COPY" -d postgres -c "select 1 from pg_database where datname='$db'" | grep -q 1; then
        read -r CT CR <<<"$(db_summary "$COPY" "$db")"
      else CT="-"; CR="-"; OK=false; fi
      [[ "$LT" == "$CT" ]] || OK=false
      printf "  %-18s %22s %22s\n" "$db" "$LT / $LR" "$CT / $CR"
    done
    echo
    echo "  tempo de restauração: ${RTO}s (do pedido até o banco aceitar conexões)"
    echo "  linhas a menos na cópia = escritas depois do último WAL arquivado (até 5 min)"
    if [[ "${KEEP:-}" == 1 ]]; then
      echo "  cópia mantida: kubectl exec -it -n $NS $COPY -c postgres -- psql -d <banco>"
      echo "  apagar depois:  kubectl delete cluster $T -n $NS"
    fi
    if [[ -n "$TARGET_TIME" ]]; then
      echo -e "\033[0;32m✅ cópia restaurada até $TARGET_TIME (diferenças são esperadas)\033[0m"
    elif $OK; then
      echo -e "\033[0;32m✅ backup restaurável: mesmos bancos e tabelas\033[0m"
    else
      echo -e "\033[0;31m❌ a cópia restaurada difere (banco ou tabela faltando)\033[0m"; exit 1
    fi
    ;;

  psql)
    DB="${4:-$(kubectl get secret postgres -n "$NS" -o jsonpath='{.data.DB_NAME}' | base64 -d)}"
    kubectl exec -it -n "$NS" "$(primary)" -c postgres -- psql -d "$DB"
    ;;

  *) echo "Comando desconhecido: $CMD"; exit 1 ;;
esac
