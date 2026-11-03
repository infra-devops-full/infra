# 24 — Ligar o cluster local (e por que ele não voltava depois de reiniciar o Mac)

## Resumo

```bash
make start          # liga o cluster na ordem certa (12–30 s até a API; os pods levam mais alguns minutos)
make stop           # desliga (dados preservados)
make autostart      # macOS: liga sozinho a cada login (LaunchAgent do usuário, sem sudo)
make autostart-off  # remove o autostart
```

O Docker **não** religa mais os containers do cluster sozinho: quem liga é o
`make start` (ou o autostart). Log do autostart: `~/Library/Logs/devops-platform-start.log`.

## O problema

Sintoma: depois de reiniciar o Mac (ou o Docker Desktop), `docker ps` mostra
os containers `k3d-<cluster>-*` como *Up*, mas `kubectl` dá `EOF` / `connection
refused` e `make status` mostra tudo vazio. No log do server:

```bash
docker logs --since 10m k3d-devops-lab-server-0 | grep "not a member"
# Failed to test etcd connection: this server is not a member of the etcd cluster.
# Found [k3d-devops-lab-server-0-…=https://172.22.0.3:2380], expect: …=https://172.22.0.4:2380
```

Causa: o k3s usa **etcd embutido** (`--cluster-init`, ver `config/k3d-config.tmpl.yaml`),
e o etcd guarda o **IP do server** como identidade do membro. A rede Docker do
k3d sorteava IP por ordem de chegada. No boot, o Docker religava tudo ao mesmo
tempo (`restart=unless-stopped`): o registry, o backup S3 ou o container
`tools` que o `k3d cluster start` cria pegavam o IP do server, o server voltava
com outro, e o k3s nunca ficava pronto.

## A correção

1. **IP fixo para o server.** Cluster novo: `subnet` no `k3d-config`
   (`K3D_SUBNET`, padrão `172.28.0.0/16`). Com sub-rede declarada, o k3d fixa
   o IP do server.
2. **Ligar na ordem**, com `docker start` (`scripts/start-cluster.sh`):
   server → API pronta → agents → load balancer → auxiliares (registry, backup).
   Os auxiliares têm IP sorteado e por isso ligam por último, quando só sobram
   IPs livres. O script não usa `k3d cluster start`, que cria o `tools` antes do server.
3. **Sem auto-restart** do Docker nos nodes, no LB, no registry e no backup.
   O próprio `make start` aplica isso a cada execução.

Se o cluster estiver "de pé pela metade", o `make start` para tudo e liga de
novo na ordem.

## Cluster criado antes desta correção

`make start` avisa: *"…server-0 sem IP fixo na rede"*. Há duas saídas:
recriar (`make destroy && make setup`; os bancos voltam do backup) ou fixar o
IP uma vez, com o cluster parado. Use o IP que o etcd espera, o `Found […]` do
log acima (normalmente o `.3` da rede). Rode com **bash** (no zsh o `$a` não separa palavras):

```bash
make stop
docker stop registry.devops.local devops-lab-backup
NET=k3d-devops-lab
pin() { docker network disconnect "$NET" "$1"; docker network connect --ip "$2" --alias "$1" "$NET" "$1"; }
pin k3d-devops-lab-server-0 172.22.0.3   # o IP do "Found [...]"
# opcional, para não sobrar IP sorteado na rede:
pin registry.devops.local 172.22.0.2; pin devops-lab-backup 172.22.0.6
pin k3d-devops-lab-agent-0 172.22.0.5;  pin k3d-devops-lab-serverlb 172.22.0.7
make start
```

Para conferir: `docker inspect -f '{{json .NetworkSettings.Networks}}' k3d-devops-lab-server-0`
mostra `"IPAMConfig":{"IPv4Address":"…"}`.
