# tflint: erros que o `terraform validate` não pega (variável sem uso, sem
# descrição, versão de provider solta...). scripts/terraform.sh lint
plugin "terraform" {
  enabled = true
  preset  = "recommended"
}
