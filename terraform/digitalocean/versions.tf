terraform {
  required_version = ">= 1.9"

  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "~> 2.100"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Estado remoto (recomendado): copie backend.tf.example para backend.tf.
  # Sem ele, o estado fica local (terraform.tfstate, fora do Git).
}

# Credenciais só por variável de ambiente, nunca em arquivo:
#   DIGITALOCEAN_TOKEN                          API (cluster, VPC, DNS, chaves)
#   SPACES_ACCESS_KEY_ID / SPACES_SECRET_ACCESS_KEY   buckets do Spaces
provider "digitalocean" {}
