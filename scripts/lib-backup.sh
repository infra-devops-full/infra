#!/usr/bin/env bash
# =============================================================================
# lib-backup.sh
# -----------------------------------------------------------------------------
# Storage de backup da plataforma: um S3 (SeaweedFS) num container Docker FORA
# do cluster, na rede do k3d. Os bancos mandam WAL e backups para lá; um
# `make destroy` apaga o cluster mas não o container nem o volume, e o próximo
# `make setup` restaura os bancos dali. docs/21-banco-de-dados.md
#
#   container  <cluster>-backup        (ex.: devops-lab-backup)
#   volume     <cluster>-backup        (Docker: os dados ficam aqui)
#   endpoint   http://<cluster>-backup:8333   (os pods resolvem pelo DNS do Docker)
#   bucket     postgres → s3://postgres/<namespace>/<serverName>/
#   credencial ~/.config/devops-platform/backup/s3.json (gerada uma vez, 600)
#
# Fora do k3d (cluster na nuvem), o storage é um bucket de verdade (Spaces,
# S3, R2): endpoint, bucket e chave vêm de ~/.config/devops-platform/backup/
# <contexto do kubectl>.env (600), gerado por `make cloud-backup-env` a partir
# dos outputs do Terraform. docs/23-nuvem.md
#
# Uso: source "$(dirname …)/lib-backup.sh"
# =============================================================================

BACKUP_IMAGE="chrislusf/seaweedfs:4.45"
BACKUP_BUCKET="${BACKUP_BUCKET:-postgres}"
BACKUP_AWSCLI_IMAGE="amazon/aws-cli:2.37.9"   # versão fixa
BACKUP_CONF_DIR="$(eval echo "${BACKUP_CONF_DIR:-$HOME/.config/devops-platform/backup}")"

# Rede do k3d = nome do contexto do kubectl (k3d-<cluster>).
backup_network() {
  local ctx; ctx="$(kubectl config current-context 2>/dev/null || true)"
  [[ "$ctx" == k3d-* ]] || { echo "❌ contexto do kubectl não é um cluster k3d ($ctx)" >&2; return 1; }
  echo "$ctx"
}
backup_container() { local n; n="$(backup_network)" || return 1; echo "${n#k3d-}-backup"; }

# Cluster fora do k3d = bucket externo. Carrega a config do contexto atual.
backup_external() {
  local ctx; ctx="$(kubectl config current-context 2>/dev/null || true)"
  [[ "$ctx" != k3d-* ]] || return 1
  local f="$BACKUP_CONF_DIR/$ctx.env"
  [[ -f "$f" ]] || { echo "❌ cluster $ctx sem storage de backup configurado: make cloud-backup-env (docs/23-nuvem.md)" >&2; exit 1; }
  # shellcheck disable=SC1090
  source "$f"   # BACKUP_S3_ENDPOINT BACKUP_BUCKET BACKUP_S3_ACCESS_KEY_ID BACKUP_S3_SECRET_ACCESS_KEY
}
backup_endpoint() {
  if backup_external; then echo "$BACKUP_S3_ENDPOINT"; else echo "http://$(backup_container):8333"; fi
}
# Onde estão os backups (para mensagens).
backup_where() {
  if backup_external; then echo "s3://$BACKUP_BUCKET em $BACKUP_S3_ENDPOINT"; else echo "container $(backup_container)"; fi
}

# Chave de acesso do S3 (gera na primeira vez). Imprime "ACCESS SECRET".
backup_credentials() {
  if backup_external; then echo "$BACKUP_S3_ACCESS_KEY_ID $BACKUP_S3_SECRET_ACCESS_KEY"; return; fi
  local f="$BACKUP_CONF_DIR/s3.json"
  if [[ ! -f "$f" ]]; then
    mkdir -p "$BACKUP_CONF_DIR" && chmod 700 "$BACKUP_CONF_DIR"
    local a s
    a="backup$(openssl rand -hex 6)"
    s="$(openssl rand -hex 20)"
    (umask 077; printf '{"identities":[{"name":"platform","credentials":[{"accessKey":"%s","secretKey":"%s"}],"actions":["Admin","Read","Write","List","Tagging"]}]}\n' "$a" "$s" >"$f")
  fi
  yq -p json -o yaml -r '.identities[0].credentials[0] | .accessKey + " " + .secretKey' "$f"
}

# Sobe (ou religa à rede do cluster) o container do S3 e cria o bucket.
backup_store_up() {
  if backup_external; then
    backup_aws s3 ls "s3://$BACKUP_BUCKET" >/dev/null || {
      echo "❌ bucket $BACKUP_BUCKET inacessível em $BACKUP_S3_ENDPOINT (chave? nome?)" >&2; return 1; }
    return 0
  fi
  local c net vol
  c="$(backup_container)" || return 1; net="$(backup_network)"; vol="$c"
  backup_credentials >/dev/null
  if ! docker container inspect "$c" >/dev/null 2>&1; then
    # Blocos de 512 MB: o padrão (30 GB) não cabe no disco da VM do Docker
    # e o upload falha com "No writable volumes".
    # -ip.bind=0.0.0.0: sem isso ele só escuta no IP que tinha ao subir, e
    # a rede do k3d (ligada depois, e trocada a cada cluster novo) fica sem
    # resposta. -ip=127.0.0.1: master, volume e filer se falam por dentro.
    docker run -d --name "$c" --restart unless-stopped \
      --label devops-platform/role=backup \
      -v "$vol:/data" -v "$BACKUP_CONF_DIR/s3.json:/etc/seaweedfs/s3.json:ro" \
      "$BACKUP_IMAGE" server -dir=/data -ip=127.0.0.1 -ip.bind=0.0.0.0 \
      -master.volumeSizeLimitMB=512 -volume.max=100 \
      -s3 -s3.port=8333 -s3.config=/etc/seaweedfs/s3.json >/dev/null
  else
    docker start "$c" >/dev/null
  fi
  # Cluster recriado = rede nova: religa o container.
  if ! docker inspect "$c" -f '{{json .NetworkSettings.Networks}}' | grep -q "\"$net\""; then
    docker network connect "$net" "$c"
  fi
  local i
  for i in $(seq 1 30); do
    backup_weed "s3.bucket.list" 2>/dev/null | grep -qw "$BACKUP_BUCKET" && return 0
    backup_weed "s3.bucket.create -name $BACKUP_BUCKET" 2>/dev/null | grep -q "created bucket" && return 0
    sleep 2
  done
  echo "❌ storage de backup ($c) não respondeu: docker logs $c" >&2
  return 1
}

backup_weed() { echo "$1" | docker exec -i "$(backup_container)" weed shell 2>/dev/null; }

# aws s3 ... contra o bucket externo (container: não exige o AWS CLI instalado).
backup_aws() {
  docker run --rm -e AWS_ACCESS_KEY_ID="$BACKUP_S3_ACCESS_KEY_ID" -e AWS_SECRET_ACCESS_KEY="$BACKUP_S3_SECRET_ACCESS_KEY" \
    -e AWS_DEFAULT_REGION=us-east-1 "$BACKUP_AWSCLI_IMAGE" --endpoint-url "$BACKUP_S3_ENDPOINT" "$@"
}

# serverNames com backup base de um namespace, do mais antigo ao mais novo.
backup_servers() {
  local ns="$1" s
  if backup_external; then
    for s in $(backup_aws s3 ls "s3://$BACKUP_BUCKET/$ns/" 2>/dev/null | awk '$1 == "PRE" {sub("/$", "", $2); print $2}' | grep -E '^postgres-[0-9]{14}$' | sort); do
      [[ -n "$(backup_aws s3 ls "s3://$BACKUP_BUCKET/$ns/$s/base/" 2>/dev/null)" ]] && echo "$s"
    done
    return
  fi
  for s in $(backup_weed "fs.ls /buckets/$BACKUP_BUCKET/$ns" | grep -E '^postgres-[0-9]{14}$' | sort); do
    [[ -n "$(backup_weed "fs.ls /buckets/$BACKUP_BUCKET/$ns/$s/base" | grep -E '^[0-9]{8}T')" ]] && echo "$s"
  done
}

# Carrega já a config do bucket externo (se o cluster não for k3d): as
# funções acima rodam em subshells ($(...)), que não devolvem variáveis.
backup_external >/dev/null || true
