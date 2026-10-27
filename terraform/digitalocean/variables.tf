variable "name" {
  description = "Prefixo dos recursos (cluster, VPC, projeto, bucket)."
  type        = string
  default     = "devops-platform"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,30}$", var.name))
    error_message = "Use 3 a 31 caracteres: letras minúsculas, números e hífen, começando por letra."
  }
}

variable "region" {
  description = "Região do cluster e do Spaces (precisa ter os dois: nyc3, sfo3, ams3, fra1, sgp1, syd1...)."
  type        = string
  default     = "nyc3"
}

variable "kubernetes_version_prefix" {
  description = "Minor do Kubernetes; o patch mais recente dele é escolhido. Mesmo minor do lab (k3d)."
  type        = string
  default     = "1.34."
}

variable "node_size" {
  description = "Tamanho dos nodes (doctl kubernetes options sizes). A plataforma inteira usa ~10 GB no lab."
  type        = string
  default     = "s-4vcpu-8gb"
}

variable "node_min" {
  description = "Mínimo de nodes (autoscaling)."
  type        = number
  default     = 2
}

variable "node_max" {
  description = "Máximo de nodes (autoscaling)."
  type        = number
  default     = 3

  validation {
    condition     = var.node_max >= var.node_min
    error_message = "node_max precisa ser >= node_min."
  }
}

variable "control_plane_ha" {
  description = "Control plane em alta disponibilidade (custa a mais; recomendado em produção real)."
  type        = bool
  default     = false
}

variable "api_allowed_cidrs" {
  description = "IPs/redes que podem falar com a API do Kubernetes (ex.: [\"203.0.113.10/32\"]). Vazio = qualquer um (só com autenticação)."
  type        = list(string)
  default     = []
}

variable "vpc_ip_range" {
  description = "Faixa privada da VPC (não pode colidir com outras VPCs da conta)."
  type        = string
  default     = "10.20.0.0/16"
}

variable "backup_retention_days" {
  description = "Dias que uma versão antiga/apagada de arquivo de backup fica no bucket (proteção contra exclusão acidental ou ransomware)."
  type        = number
  default     = 14
}

variable "domain" {
  description = "Domínio da plataforma (ex.: devops.exemplo.com.br), já delegado aos nameservers da DigitalOcean. Vazio = sem DNS."
  type        = string
  default     = ""
}

variable "ingress_ip" {
  description = "IP do load balancer do NGINX Ingress (kubectl -n kube-system get svc ingress-nginx-controller). Com domain, cria *.domain → este IP. Preencha no segundo apply."
  type        = string
  default     = ""
}

variable "tags" {
  description = "Tags extras em todos os recursos que aceitam."
  type        = list(string)
  default     = []
}
