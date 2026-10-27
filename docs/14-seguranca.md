# Segurança: HTTPS, rede e políticas

Três camadas, todas genéricas: valem para qualquer projeto em `projects/`
sem configuração extra.

| Camada | Ferramenta | Protege contra |
| ------ | ---------- | -------------- |
| **HTTPS** | cert-manager + CA local | tráfego legível na rede, senha/cookie em texto puro |
| **Rede** | NetworkPolicy (geradas pelo Kyverno) | um app comprometido alcançar outro projeto ou outro ambiente |
| **Admissão** | Kyverno + Pod Security Admission | manifesto inseguro ou frágil chegar ao cluster |

## 1. HTTPS com cert-manager

```
Ingress (annotation cert-manager.io/cluster-issuer: platform-ca)
   │  o cert-manager vê a annotation
   ▼
Certificate <app>-tls ──► ClusterIssuer platform-ca ──► assina com a CA local
   │
   ▼
Secret <app>-tls (certificado + chave) ──► o NGINX Ingress serve https
```

- O chart genérico já faz isso: todo app com `ingress.enabled` ganha
  `https://<host>`. Os certificados valem 90 dias e o cert-manager renova
  sozinho.
- **CA local:** no lab não existe domínio público, então o Let's Encrypt não
  consegue validar `*.local`. A plataforma cria uma CA própria
  (`config/security/platform-ca.yaml`).
- **Confiar na CA (uma vez por máquina):**

  ```bash
  make trust-ca      # adiciona ao keychain do macOS (pede a senha do Mac)
  ```

  Chrome e Safari usam o keychain. O **Firefox** tem repositório próprio:
  *Configurações → Privacidade e Segurança → Certificados → Ver certificados
  → Autoridades → Importar* `~/.config/devops-platform/ca/platform-ca.crt`.
  Para remover: `make untrust-ca`.
- **Backup da CA:** como a chave do Sealed Secrets, a chave da CA fica em
  `~/.config/devops-platform/ca/` (fora do Git, `chmod 600`). O `make destroy`
  não apaga, e o `make setup` restaura, então o navegador continua confiando
  depois de recriar o cluster.
- **http continua funcionando** (`sslRedirect: false`): CI, `curl` e scripts
  sem a CA não quebram. Em produção real: `sslRedirect: true` e HSTS.
- Telas da plataforma também: `https://argocd.devops.local`,
  `https://grafana.devops.local`, `https://prometheus.devops.local`,
  `https://alertmanager.devops.local`.

### Values do chart

```yaml
ingress:
  tls:
    enabled: true             # false = só http
    clusterIssuer: platform-ca
    secretName: ""            # vazio => <app>-tls
    sslRedirect: false
```

Os certificados levam o uso `serverAuth` (annotation `cert-manager.io/usages`):
o macOS e o iOS recusam certificado TLS sem ele, mesmo com a CA confiada.

### Na nuvem

Troque o emissor por um ClusterIssuer ACME do Let's Encrypt, com domínio
real. O chart não muda, só `ingress.tls.clusterIssuer` (ou o nome do
ClusterIssuer). A fase 7 do roteiro cobre isso.

## 2. Rede: NetworkPolicy

Sem NetworkPolicy, **todo pod do cluster fala com todo pod**: um app
comprometido em `crivo-develop` chega no Postgres de `wlstore-prod`.

Todo namespace com o label `devops-platform/project` (o `make project-apply`
põe) recebe do Kyverno (`k8s/kyverno-network-baseline.yaml`):

| NetworkPolicy | Libera |
| ------------- | ------ |
| `default-deny-ingress` | nada: bloqueia toda entrada |
| `allow-same-namespace` | pods do mesmo `<projeto>-<env>` (app → banco, front → API) |
| `allow-from-ingress-nginx` | o NGINX Ingress (tráfego de fora) |
| `allow-from-monitoring` | o Prometheus (métricas dos apps) |
| `allow-from-cnpg-operator` | o operador do Postgres, só na porta 8000 dos pods de banco ([21-banco-de-dados.md](21-banco-de-dados.md)) |

```
crivo-develop ──✗──► wlstore-prod        outro projeto: bloqueado
crivo-develop ──✗──► crivo-prod          outro ambiente: bloqueado
crivo-fe ──────✓──► crivo-be             mesmo namespace
ingress-nginx ─✓──► qualquer app          entrada pela porta da frente
```

- Os probes do kubelet (liveness/readiness) não passam pela política: o
  default-deny não derruba os pods.
- **Saída (egress) fica liberada**: DNS, APIs externas (Stripe), GHCR.
  Restringir egress é o próximo passo de maturidade, app a app.
- Apagar ou editar uma dessas políticas à mão não adianta: o Kyverno recria
  em segundos (`synchronize`).
- Tirar o label do namespace **não** apaga as políticas (falha fechada).
  Para remover: `kubectl delete networkpolicy --all -n <ns>`.
- Quem aplica as regras é o controlador de NetworkPolicy embutido no k3s
  (kube-router). Na nuvem, o CNI do cluster (Calico, Cilium, VPC CNI com
  policy) faz esse papel.

### Um app precisa falar com outro projeto?

Hoje, o caminho é pelo Ingress (host público do outro app), que já é
permitido. Uma exceção direta seria uma NetworkPolicy a mais no namespace de
destino, liberando o namespace de origem, versionada no Git.

## 3. Admissão: Kyverno e Pod Security

Admissão é o "porteiro" da API do Kubernetes: todo objeto passa por ele
antes de ser gravado. Recusado aqui, o manifesto nem chega a existir. O
ArgoCD mostra o erro no sync, com a mensagem da política.

### Pod Security Admission (nativo do Kubernetes)

Labels que o `make project-apply` põe em cada namespace de projeto:

| Label | Efeito |
| ----- | ------ |
| `pod-security.kubernetes.io/enforce=baseline` | **recusa** pod privilegiado, `hostNetwork`, `hostPID`, `hostPath`, capabilities perigosas |
| `pod-security.kubernetes.io/warn=restricted` | **avisa** (não recusa) o que falta para o perfil mais rígido: rodar como não-root, `drop: [ALL]`, `seccompProfile`... |

Os avisos `would violate PodSecurity "restricted:latest"` que aparecem no
`kubectl apply` são esse `warn`: um roteiro de endurecimento dos apps.

### Políticas do Kyverno (`k8s/kyverno-pod-policies.yaml`)

| Política | Ação | Regra | Por quê |
| -------- | ---- | ----- | ------- |
| `platform-disallow-latest` | **Deny** | imagem com tag, e não `:latest` | `:latest` muda sem aviso; o rollback pelo Git deixa de funcionar |
| `platform-require-resources` | **Deny** | `requests.cpu`, `requests.memory`, `limits.memory` | sem requests o scheduler erra; sem limit um vazamento derruba o node |
| `platform-require-probes` | Audit | `readinessProbe` | sem ela, tráfego chega antes do app estar pronto |
| `platform-restrict-registries` | Audit | `ghcr.io/`, `registry.devops.local:5000/`, oficiais do Docker Hub | imagem de origem desconhecida |

- **Deny** recusa. **Audit** só registra no relatório.
- As regras de Pod valem também para Deployment, StatefulSet, Job e CronJob
  (autogen): o erro aparece no objeto que você escreveu.
- Só namespaces de projeto: a plataforma (`kube-system`, `argocd`,
  `monitoring`...) nunca é bloqueada, nem se o Kyverno cair.
- O formato é o **ValidatingPolicy/GeneratingPolicy** (CEL), o atual. O
  `ClusterPolicy` clássico aparece como depreciado no Kyverno 1.19 e vai ser
  removido.

### Ver e testar

```bash
make policies        # violações nos namespaces de projeto (PolicyReports)
make policy-check    # testa TODOS os apps renderizados contra as políticas, sem cluster
```

O `make policy-check` usa o Kyverno CLI e roda no CI do repo de infra:
um values que o cluster recusaria falha **no PR**, não no sync.

Exemplo de recusa:

```
admission webhook "vpol.validate.kyverno.svc-fail" denied the request:
Policy platform-disallow-latest failed: Use uma tag imutável na imagem
(ex.: sha-abc1234), não ":latest" nem imagem sem tag.
```

### Mudar ou criar uma política

1. Edite `k8s/kyverno-pod-policies.yaml`. As expressões são
   [CEL](https://kubernetes.io/docs/reference/using-api/cel/), com `object`
   sendo o Pod.
2. Política nova: comece em `validationActions: [Audit]`, veja o
   `make policies` por uns dias e só então passe para `[Deny]`. É assim que
   se liga uma regra sem quebrar quem já está rodando.
3. `make policy-check`, commit, `make apply-argocd`.

## 4. Assinatura de imagem

O CI assina cada imagem (cosign keyless) e anexa o SBOM; o Kyverno confere
que a imagem saiu do workflow de um repo de projeto. Detalhes:
[19-assinatura-de-imagem.md](19-assinatura-de-imagem.md).

## Arquivos

| Arquivo | O quê |
| ------- | ----- |
| `scripts/setup-security.sh` | instala cert-manager e Kyverno, restaura/faz backup da CA (`make security`) |
| `config/security/platform-ca.yaml` | CA local e ClusterIssuers |
| `config/security/kyverno-values.yaml` | Kyverno enxuto, webhooks só nos namespaces de projeto |
| `k8s/kyverno-network-baseline.yaml` | NetworkPolicies geradas por namespace |
| `k8s/kyverno-pod-policies.yaml` | políticas de admissão |
| `scripts/policy-check.sh` | teste das políticas sem cluster |
| `scripts/apply-project.sh` | labels do namespace (projeto + Pod Security) |

## Problemas comuns

| Sintoma | Causa | Solução |
| ------- | ----- | ------- |
| navegador: "conexão não é privada" | CA não confiada nesta máquina | `make trust-ca`; Firefox: importar à mão |
| aviso voltou depois de recriar o cluster | backup da CA ausente, então uma CA nova foi gerada | `make trust-ca` de novo; o `make doctor` avisa |
| Safari/Chrome recusam mesmo com a CA confiada | certificado sem `serverAuth` (emitido antes da annotation) | `kubectl delete certificate <app>-tls -n <ns>`: o cert-manager recria |
| Certificate `Ready=False` | ClusterIssuer ausente ou CA sem Secret | `kubectl describe certificate -n <ns>`; `make security` |
| ArgoCD: `denied the request: Policy platform-…` | o manifesto viola uma política Deny | corrigir os values (a mensagem diz o quê); `make policy-check` antes do commit |
| app não alcança outro serviço (timeout, não "connection refused") | NetworkPolicy bloqueando entre namespaces | é o esperado entre projetos; usar o Ingress ou uma exceção versionada |
| `make apply-argocd`: `pulando k8s/kyverno-…` | Kyverno ainda não instalado | `make security` |
