output "cluster_name" {
  value = digitalocean_kubernetes_cluster.this.name
}

output "cluster_id" {
  value = digitalocean_kubernetes_cluster.this.id
}

output "kubernetes_version" {
  value = digitalocean_kubernetes_cluster.this.version
}

output "kubeconfig_command" {
  description = "Grava o acesso ao cluster no ~/.kube/config (token de curta duração, renovado pelo doctl)."
  value       = "doctl kubernetes cluster kubeconfig save ${digitalocean_kubernetes_cluster.this.name}"
}

output "backup_bucket" {
  value = digitalocean_spaces_bucket.backups.name
}

output "backup_s3_endpoint" {
  description = "Endpoint S3 do Spaces: vai em BACKUP_S3_ENDPOINT (scripts/lib-backup.sh)."
  value       = "https://${var.region}.digitaloceanspaces.com"
}

output "backup_access_key_id" {
  value     = digitalocean_spaces_key.backups.access_key
  sensitive = true
}

output "backup_secret_access_key" {
  value     = digitalocean_spaces_key.backups.secret_key
  sensitive = true
}

output "dns" {
  value = var.domain == "" ? "sem domínio (variável domain vazia)" : (
    var.ingress_ip == "" ? "domínio ${var.domain} criado; preencha ingress_ip e rode apply de novo" : "*.${var.domain} → ${var.ingress_ip}"
  )
}
