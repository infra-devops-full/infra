# Troubleshooting

Problemas reais que aconteceram nesta plataforma, com causa e solução. Para
treinar o diagnóstico, veja [11-treino-quebre-e-conserte.md](11-treino-quebre-e-conserte.md).

## Método

1. **Sintoma:** o que o usuário vê (HTTP 404/502/503, página lenta, deploy que não chega).
2. **Onde:** `make apps` (ArgoCD), `make pods` (cluster), Grafana (métricas e logs).
3. **Por quê:** `make describe`, `make events`, `make logs` (e `--previous`).
4. **Correção:** no Git, se o app é de projeto.
5. **Prevenção:** o que impede de acontecer de novo (teste, `doctor`, gate).

## Imagens

| Sintoma | Causa | Solução |
| ------- | ----- | ------- |
| `ImagePullBackOff` + `403 Forbidden` | `ghcr-secret` com token inválido (PAT fine-grained). O kubelet envia a credencial até para imagem pública | deixar `GITHUB_TOKEN` vazio e apagar o secret, ou PAT **classic** `read:packages` (`make ghcr`) |
| `no match for platform in manifest` | imagem só amd64; os nodes do k3d no Mac são arm64 | build multi-arch (o workflow já faz) |
| `ImagePullBackOff` + `not found` | a tag ainda não foi publicada | rodar o CI do app |
| `npm ci` falha com `Missing: @emnapi/... from lock file` | o npm da imagem é mais novo que o que gerou o lock | fixar `npm@11.6.2` (os templates já fazem) |
| imagem Next.js com URL errada da API | `NEXT_PUBLIC_*` é embutido no **build** | passar em `build-args`; usar o Service interno (`http://<api>:<porta>`) |

## CI/CD

| Sintoma | Causa | Solução |
| ------- | ----- | ------- |
| deploy: `INFRA_DEPLOY_KEY ausente` | repo não configurado | `make github PROJECT=<p>` |
| deploy: `could not read Username` / `Permission denied (publickey)` | credencial inválida, ou deploy key só leitura | `make github PROJECT=<p> ARGS=--rotate` |
| `make github`: `Deploy keys are disabled for this repository` | política da org desliga deploy keys | o script liga sozinho (é preciso ser admin da org) |
| `gh` não autentica dentro de um script | `GITHUB_TOKEN` no ambiente tem prioridade sobre o `gh auth login` | os scripts fazem `unset GITHUB_TOKEN` |
| `git push` na infra recusado (`non-fast-forward`) | o CI dos apps commitou na `main` | `git pull --rebase` e `git push` (`git config pull.rebase true`); **nunca** `--force` |
| PR não libera merge | check `ci` vermelho | abrir o job *test* ou *build* no Actions |
| job *test* falha só no CI | dependência do ambiente local | rodar o comando `test` do `APPS_JSON` numa cópia limpa (`git archive HEAD`) |

## Cluster e rede

| Sintoma | Causa | Solução |
| ------- | ----- | ------- |
| upgrade do Ingress trava (`Pending termination`) ou `svclb-*` em `Pending` (`didn't have free ports`) | controller com `hostPort` 80/443 **e** Service `LoadBalancer` (servicelb do k3s) disputando as portas | só o `LoadBalancer`: `helm upgrade ingress-nginx … --reuse-values --set controller.hostPort.enabled=false` (o setup atual já faz assim) |
| Grafana "No data" depois de reiniciar o Docker | os nodes voltam com IP novo; o Prometheus recoleta em minutos | aguardar 2 a 5 min |
| `*.local` não resolve | cache mDNS do macOS ou bloco ausente | `make hosts`, ou `curl --resolve host:80:127.0.0.1` |
| app de microfrontend responde 404 | `ingress.path` ≠ `basePath`, ou falta o app em `projects/` | conferir os dois valores |
| Docker com CPU alta | muitos nodes k3d, ou Kubernetes do Docker Desktop ligado | `K3D_AGENTS=1`; desligar o k8s do Docker Desktop |

## Banco e logs

| Sintoma | Causa | Solução |
| ------- | ----- | ------- |
| `FATAL: database "<user>" does not exist` a cada 5 s no Postgres | `pg_isready` sem `-d` testa um banco com o nome do usuário | o script atual usa `-d <defaultDb>` (recriar com `make postgres`) |
| tabelas sumiram | Postgres com `emptyDir` foi recriado | `make rollout SERVICE=<api> NAMESPACE=<ns>` para as migrations rodarem de novo |
| erro de compilação MapStruct `Unmapped target property: "withX"` | método `withX(...)` no record é lido como setter fluente | `@Mapping(target = "withX", ignore = true)` |

## Segredos (Sealed Secrets)

| Sintoma | Causa | Solução |
| ------- | ----- | ------- |
| `no key could decrypt secret` / `ErrUnsealFailed` | selado para outro namespace ou nome, ou o cluster tem outra chave | `make doctor`; selar para o destino certo, ou restaurar a chave (`make sealed-secrets`) |
| `already exists and is not managed by SealedSecret` | Secret antigo criado à mão | `make project-apply` adota (anotação `managed=true`) |
| `password authentication failed` por 1 a 2 min após rotacionar | pods antigos do app (rolling update) com a senha velha | esperado; para quando eles terminam |
| app usa a senha antiga | env é lido só na subida | `make rollout SERVICE=<app> NAMESPACE=<ns>` |

## HTTPS, rede e políticas

| Sintoma | Causa | Solução |
| ------- | ----- | ------- |
| "conexão não é privada" no navegador | CA local não confiada | `make trust-ca` (Firefox: importar à mão) |
| ArgoCD: `denied the request: Policy platform-…` | values violam uma política Deny | corrigir o que a mensagem diz; `make policy-check` antes do commit |
| timeout entre apps de namespaces diferentes | NetworkPolicy default-deny | esperado; detalhes em [14-seguranca.md](14-seguranca.md) |
| `would violate PodSecurity "restricted:latest"` no apply | aviso (não erro) do perfil restricted | roteiro de endurecimento; não bloqueia |

## Alertas

| Sintoma | Causa | Solução |
| ------- | ----- | ------- |
| regra nova não aparece em prometheus.devops.local/rules | o ConfigMap das regras leva ~1 a 2 min para chegar ao pod | aguardar; conferir `kubectl get prometheusrule -n monitoring` |
| alerta fica em `pending` e não chega ao Alertmanager | ainda não passou o tempo do `for:` | esperado (ex.: `AppDown` exige 5 min) |
| `AppErrorBudgetBurn` aparece como *suppressed* | inibido por `AppDown` do mesmo app, ou pelo crítico | esperado: um problema, um alerta |
| dashboard de SLO mostra "No data" para um app | o app não tem Ingress, ou não recebeu nenhum request | o SLI vem do Ingress; gere tráfego |

## Helm e ArgoCD

| Sintoma | Causa | Solução |
| ------- | ----- | ------- |
| `Apply failed with N conflicts … kubectl-patch` | server-side apply: o campo foi alterado com `kubectl` e tem outro dono | `helm upgrade --force-conflicts` (ou corrigir no Git) |
| mudança via `kubectl` some | selfHeal do ArgoCD | commitar no Git |
| app não aparece no ArgoCD | `projects/` sem push, ou sem `values-<env>.yaml` | `git push`; *Refresh* |
