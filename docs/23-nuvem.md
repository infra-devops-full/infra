# Nuvem: Terraform na DigitalOcean (e o caminho para AWS e VPS)

## Lab × nuvem

A plataforma é a mesma; muda a camada de baixo. O Terraform cria essa camada
e os scripts de sempre instalam o resto por cima.

| Peça | Lab (k3d) | DigitalOcean (Terraform) | AWS (guia) | VPS (guia) |
| ---- | --------- | ------------------------ | ---------- | ---------- |
| Kubernetes | k3d no Docker | **DOKS** gerenciado, autoscaling 2–3 nodes | EKS + managed node group | k3s numa VM |
| Rede | rede do Docker | **VPC** privada | VPC, subnets privadas + NAT | rede da VPS + firewall |
| Entrada | servicelb em 127.0.0.1 | Load Balancer da DO (Service do Ingress) | NLB | IP público da VM |
| Disco dos pods | pasta no Mac (`local-path`) | Block Storage (`do-block-storage`) | EBS gp3 | disco local |
| Backups dos bancos | SeaweedFS num container | **Spaces**, versionado, chave só do bucket | S3 + IRSA (sem chave) | bucket externo (R2, B2, Spaces) |
| DNS / HTTPS | `/etc/hosts` + CA local | **DNS da DO** (`*.domínio`) + Let's Encrypt | Route 53 + Let's Encrypt/ACM | DNS do registrador + Let's Encrypt |
| Estado do Terraform | — | bucket no Spaces (`backend.tf`) | S3 + lock | — |

## O que já está pronto e o que falta

**Pronto (código validado no CI):**

- `terraform/digitalocean/`: VPC, cluster DOKS (Kubernetes 1.34, upgrades
  automáticos na janela de domingo, firewall da API, autoscaling), bucket de
  backups no Spaces (privado, versionado, versões antigas apagadas após 14
  dias, protegido contra `destroy`), chave do Spaces restrita a esse bucket,
  domínio + registro `*.domínio` opcionais, projeto no painel.
- `make cloud-check` (e o CI do repo): `terraform fmt`, `validate`, **tflint**
  e **trivy config**, a análise de segurança de IaC. Ela recusa bucket
  público, cluster sem upgrade automático etc. (testado: as duas coisas são
  apontadas como CRITICAL).
- Backups dos bancos no Spaces: fora do k3d, a `lib-backup.sh` usa o bucket
  do Terraform (`make cloud-backup-env`). Em vez do container local, o mesmo
  CloudNativePG grava WAL e backups lá.

**Falta (próxima etapa: "perfil nuvem" da plataforma):**

- **Domínio configurável.** Hoje `devops.local` e os hosts `*.local` dos
  apps estão fixos em ~20 arquivos (ArgoCD, Grafana, SSO, chart). Vira uma
  variável (`PLATFORM_DOMAIN`).
- **HTTPS público**: ClusterIssuer do Let's Encrypt no lugar da CA local
  (o chart já usa `ingress.tls.clusterIssuer`).
- **`setup.sh` sem k3d**: pular a criação do cluster e o `/etc/hosts`, e
  instalar o NGINX Ingress com o Load Balancer da DO.
- Callback do SSO e links das notificações com o domínio real.

Até lá, num DOKS criado por aqui já roda tudo que não depende de domínio:
`make security`, `make observability`, `make delivery`, `make data`,
`make tracing`, `make sealed-secrets`, `make project-apply` e
`make apply-argocd`. O acesso às telas é por `kubectl port-forward`.

## Passo a passo (DigitalOcean)

### 0. Custo

Cobrado por hora; destrua quando não estiver usando.

| Item | Mês (aprox., US$) |
| ---- | ----------------- |
| 2 nodes `s-4vcpu-8gb` (a plataforma usa ~10 GB) | 96 |
| Load Balancer (criado pelo Ingress) | 12 |
| Spaces (250 GB inclusos) | 5 |
| Volumes dos PVCs (bancos, Grafana, Tempo: ~10 GB) | 1 |
| Control plane | grátis (HA: +40) |
| **Total** | **~115** (~US$ 0,16/h) |

Para estudar: suba, teste por algumas horas e destrua. Com nodes menores
(`s-2vcpu-4gb`), a plataforma inteira não cabe.

### 1. Uma vez: conta e credenciais

```bash
doctl auth init                    # token da API (Painel → API → Tokens)
```

- **Token da API** com escopo só do necessário (*Custom scopes*:
  kubernetes, vpc, project, domain, spaces_key; leitura de regions/sizes).
  Exporte em vez de gravar: `export DIGITALOCEAN_TOKEN=...`.
- **Chave do Spaces** do Terraform (Painel → Spaces Object Storage → Access
  Keys): `export SPACES_ACCESS_KEY_ID=... SPACES_SECRET_ACCESS_KEY=...`.
  Ela cria o bucket de backups; o cluster recebe outra chave, restrita.
- Nunca em arquivo commitado, nunca no chat. Um gerenciador de senhas com
  CLI (1Password `op run`, por exemplo) evita até o histórico do shell.

### 2. Uma vez: estado remoto

O estado do Terraform tem segredos (a chave de backup) e precisa ser único
para quem aplica. Crie o bucket dele à mão e ligue o backend:

```bash
doctl spaces bucket create devops-platform-tfstate --region nyc3   # ou pelo painel; privado + versionado
cp terraform/digitalocean/backend.tf.example terraform/digitalocean/backend.tf
export AWS_ACCESS_KEY_ID=$SPACES_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY=$SPACES_SECRET_ACCESS_KEY
```

Sem `backend.tf`, o estado fica local (`terraform.tfstate`, ignorado pelo Git).

### 3. Variáveis

```bash
cp terraform/digitalocean/terraform.tfvars.example terraform/digitalocean/terraform.tfvars
# api_allowed_cidrs = ["<seu IP>/32"]   (curl -s ifconfig.me)
```

### 4. Criar

```bash
make cloud-check                 # valida antes (sem custo)
make cloud TF=init
make cloud TF=plan               # leia: tudo que vai ser criado
make cloud TF="apply"            # pede confirmação ("yes"); ~6 min
make cloud TF=output             # cluster, bucket, comando do kubeconfig
```

O `make cloud` usa o Terraform instalado ou, se não houver, a imagem Docker
`hashicorp/terraform:1.16.5`.

### 5. Usar o cluster

```bash
doctl kubernetes cluster kubeconfig save devops-platform   # contexto do-nyc3-devops-platform
kubectl get nodes
make cloud-backup-env            # backups dos bancos → bucket do Terraform
make security observability delivery data tracing sealed-secrets
make project-apply PROJECT=crivo && make apply-argocd
```

**Atenção ao contexto:** os comandos `make` agem no contexto atual do
kubectl. Volte ao lab com `kubectl config use-context k3d-devops-lab`.

### 6. DNS (opcional)

1. No registrador do domínio, aponte os nameservers para
   `ns1/ns2/ns3.digitalocean.com`.
2. `domain = "devops.exemplo.com.br"` no tfvars → `make cloud TF=apply`.
3. Depois que o Ingress existir:
   `kubectl -n kube-system get svc ingress-nginx-controller` → IP externo →
   `ingress_ip = "..."` → `make cloud TF=apply` cria `*.domínio`.

### 7. Destruir

```bash
make cloud TF=destroy
```

O bucket de backups tem `prevent_destroy`, então o `destroy` para com erro
nele de propósito. Para apagar de vez: tire o bloco `lifecycle` do bucket em
`main.tf`, esvazie-o (`doctl`/painel) e rode de novo. O Load Balancer e os
volumes criados pelo Kubernetes (não pelo Terraform) somem com o cluster;
confira no painel se nada ficou cobrando.

## AWS (guia)

O desenho é o mesmo; os blocos mudam:

| DigitalOcean | AWS |
| ------------ | --- |
| `digitalocean_vpc` | módulo `terraform-aws-modules/vpc` (subnets públicas/privadas em 2–3 zonas, NAT gateway) |
| `digitalocean_kubernetes_cluster` | módulo `terraform-aws-modules/eks` (managed node group, addons vpc-cni, ebs-csi, coredns) |
| Spaces + chave restrita | S3 com versionamento, *Block Public Access*, *Object Lock*; **IRSA/Pod Identity**: o pod do banco assume um papel IAM, sem chave nenhuma |
| `control_plane_firewall` | `cluster_endpoint_public_access_cidrs` (ou endpoint só privado + VPN) |
| DNS da DO | Route 53 (+ external-dns) |
| Load Balancer da DO | NLB (AWS Load Balancer Controller) na frente do NGINX Ingress |

Custo de referência: EKS US$ 73/mês + 2× `t3.large` ~US$ 120 + NLB ~US$ 16 +
NAT ~US$ 32 → **~US$ 250/mês**. É a escolha mais pedida em vaga; para
estudar, `terraform apply` + `destroy` no mesmo dia custa poucos dólares.

## VPS (guia)

Uma VM (Hetzner CX32, DO Droplet 8 GB, ~US$ 10–50/mês) com k3s, o mesmo
Kubernetes do lab:

```bash
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--disable=traefik --tls-san=<IP>" sh -
```

- O servicelb do k3s publica o Ingress no IP da VM: aponte o DNS para ele.
- Firewall da VM: só 80/443 abertos ao mundo; 6443 (API) e 22 só do seu IP.
- Backups **fora** da VM (Spaces, R2, Backblaze B2): o mesmo
  `make cloud-backup-env`, com o `.env` preenchido à mão.
- Sem alta disponibilidade: a VM caiu, tudo caiu. Para portfólio e
  projetos pessoais, é o melhor custo-benefício.

O Terraform também cria VPS (`digitalocean_droplet`, `hcloud_server`) com
`user_data` instalando o k3s. Fica como evolução.

## Arquivos

| Arquivo | O quê |
| ------- | ----- |
| `terraform/digitalocean/*.tf` | a infraestrutura (rede, cluster, bucket, DNS) |
| `terraform/digitalocean/.terraform.lock.hcl` | versões exatas dos providers (commitado) |
| `terraform/digitalocean/*.example` | variáveis e backend remoto (copie sem `.example`) |
| `terraform/.tflint.hcl` | regras do tflint |
| `scripts/terraform.sh` | `make cloud-check` / `make cloud` (Terraform local ou em Docker) |
| `scripts/cloud-backup-env.sh` | `make cloud-backup-env`: outputs → `~/.config/devops-platform/backup/<contexto>.env` |

## Problemas comuns

| Sintoma | Causa | Solução |
| ------- | ----- | ------- |
| `Error: Unable to authenticate you` | `DIGITALOCEAN_TOKEN` ausente ou sem escopo | `export DIGITALOCEAN_TOKEN=...`; escopos do passo 1 |
| erro no bucket: `InvalidAccessKeyId` | chave do Spaces ausente | `SPACES_ACCESS_KEY_ID` / `SPACES_SECRET_ACCESS_KEY` |
| `BucketAlreadyExists` | nome de bucket é global | troque `name` (o sufixo aleatório já reduz isso) |
| `kubectl` sem resposta | seu IP mudou e o firewall da API barra | atualize `api_allowed_cidrs` → apply |
| `destroy` falha no bucket | `prevent_destroy` (de propósito) | passo 7 |
| `make data`: `cluster ... sem storage de backup configurado` | contexto da nuvem sem o `.env` de backup | `make cloud-backup-env` |
| `make` mexeu no cluster errado | contexto do kubectl | `kubectl config current-context` antes de tudo |
| `make cloud-check` falha no trivy | configuração insegura (bucket público, API aberta...) | a mensagem diz o recurso e a regra (DIG-xxxx) |
