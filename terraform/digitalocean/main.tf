# =============================================================================
# Infraestrutura da plataforma na DigitalOcean. docs/23-nuvem.md
#
#   VPC privada ── DOKS (Kubernetes gerenciado, nodes com autoscaling)
#   Spaces (S3)    bucket de backups dos bancos, versionado, com chave própria
#   DNS (opcional) *.domínio → load balancer do NGINX Ingress
#
# O resto (Ingress, ArgoCD, observabilidade, bancos...) é a mesma plataforma
# do lab, instalada pelos scripts no cluster que sai daqui.
# =============================================================================

locals {
  tags = concat(["devops-platform", var.name], var.tags)
}

# --- Rede ---------------------------------------------------------------------

resource "digitalocean_vpc" "this" {
  name        = "${var.name}-vpc"
  region      = var.region
  ip_range    = var.vpc_ip_range
  description = "Rede privada da plataforma (nodes do Kubernetes)"
}

# --- Kubernetes ---------------------------------------------------------------

data "digitalocean_kubernetes_versions" "this" {
  version_prefix = var.kubernetes_version_prefix
}

resource "digitalocean_kubernetes_cluster" "this" {
  name     = var.name
  region   = var.region
  version  = data.digitalocean_kubernetes_versions.this.latest_version
  vpc_uuid = digitalocean_vpc.this.id
  ha       = var.control_plane_ha
  tags     = local.tags

  # Patches do Kubernetes aplicados pela DO na janela de manutenção, um node
  # por vez com um node extra temporário (sem perder capacidade).
  auto_upgrade  = true
  surge_upgrade = true

  maintenance_policy {
    day        = "sunday"
    start_time = "07:00" # UTC = 04:00 em Brasília
  }

  # A API do Kubernetes só aceita conexões dos IPs listados.
  dynamic "control_plane_firewall" {
    for_each = length(var.api_allowed_cidrs) > 0 ? [1] : []
    content {
      enabled           = true
      allowed_addresses = var.api_allowed_cidrs
    }
  }

  node_pool {
    name       = "${var.name}-default"
    size       = var.node_size
    auto_scale = true
    min_nodes  = var.node_min
    max_nodes  = var.node_max
    tags       = local.tags
    labels = {
      "devops-platform/pool" = "default"
    }
  }

  lifecycle {
    # A DO troca o patch sozinha (auto_upgrade): sem isso o próximo plan
    # tentaria "voltar" a versão.
    ignore_changes = [version]
  }
}

# --- Backups (Spaces, compatível com S3) ----------------------------------------

# Nome de bucket é global na região: sufixo aleatório evita colisão.
resource "random_id" "bucket" {
  byte_length = 3
}

resource "digitalocean_spaces_bucket" "backups" {
  name   = "${var.name}-backups-${random_id.bucket.hex}"
  region = var.region
  acl    = "private"

  # Versionado: um arquivo de backup apagado ou sobrescrito (erro, invasor
  # com a chave) continua recuperável por backup_retention_days.
  versioning {
    enabled = true
  }

  lifecycle_rule {
    id      = "versoes-antigas"
    enabled = true

    noncurrent_version_expiration {
      days = var.backup_retention_days
    }

    abort_incomplete_multipart_upload_days = 2
  }

  lifecycle {
    prevent_destroy = true # apagar o bucket de backups exige remover isto de propósito
  }
}

# Chave só deste bucket, para o plugin de backup do Postgres (Secret
# backup-s3). Não é a chave da sua conta.
resource "digitalocean_spaces_key" "backups" {
  name = "${var.name}-backups"

  grant {
    bucket     = digitalocean_spaces_bucket.backups.name
    permission = "readwrite"
  }
}

# --- DNS (opcional) -------------------------------------------------------------

resource "digitalocean_domain" "this" {
  count = var.domain != "" ? 1 : 0
  name  = var.domain
}

# *.domínio → load balancer do Ingress (argocd., grafana., apps...). O LB é
# criado pelo Service do NGINX Ingress, depois do cluster: segundo apply.
resource "digitalocean_record" "wildcard" {
  count  = var.domain != "" && var.ingress_ip != "" ? 1 : 0
  domain = digitalocean_domain.this[0].id
  type   = "A"
  name   = "*"
  value  = var.ingress_ip
  ttl    = 300
}

# --- Projeto (agrupa tudo no painel da DO) -----------------------------------------

resource "digitalocean_project" "this" {
  name        = var.name
  description = "DevOps Platform (infra-devops-full/infra)"
  purpose     = "Web Application"
  environment = "Production"
  resources = concat(
    [digitalocean_kubernetes_cluster.this.urn, digitalocean_spaces_bucket.backups.urn],
    [for d in digitalocean_domain.this : d.urn],
  )
}
