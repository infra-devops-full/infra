# Entrega progressiva com Argo Rollouts

## O problema

Com um `Deployment`, a versão nova substitui a antiga pod a pod. Se ela tem
um bug que só aparece com tráfego real (erro 500 numa rota, lentidão), **100%
dos usuários** recebem o bug até alguém perceber e reverter.

Um **canary** expõe a versão nova a uma fração dos usuários primeiro, mede e
só então segue. Com **análise automática**, a decisão de seguir ou voltar sai
das mãos de quem está de plantão.

## Como funciona aqui

```
merge na main → CI promove a imagem → image.tag no values-prod.yaml → ArgoCD
                                                                         │
                          Rollout (Argo Rollouts) ◄────────────────────────┘
                                │
     ┌──────────────────────────┼──────────────────────────────┐
     ▼                          ▼                              ▼
  passo 1: 20% dos requests  pausa 2 min                passo 3: 50%, pausa 2 min
  na versão nova             (análise rodando)          → 100%: vira a estável
     │
     └── a cada minuto: AnalysisRun consulta o Prometheus
         taxa de 5xx da versão nova > 5% em 2 medições?
              sim → ABORTA: 100% volta para a estável, alerta RolloutAborted
              não → segue
```

- **Peso de tráfego, não de pods:** o controller cria um Ingress
  `<app>-<app>-canary` com as annotations `canary`/`canary-weight` do NGINX.
  Com 1 réplica, "20%" significa 20% dos **requests**, não "1 de 5 pods".
- **Dois Services:** `<app>` (estável) e `<app>-canary` (versão nova). O
  controller ajusta o selector de cada um.
- **A métrica:** o NGINX conta o tráfego do canary no Ingress estável e marca
  a versão nova no label `canary="<namespace>-<app>-canary-<porta>"`. A
  análise (`k8s/rollouts-analysis.yaml`) filtra por esse label.
- **Prazo:** versão nova que não fica pronta em 10 min (`ImagePullBackOff`,
  `CrashLoopBackOff`) também aborta (`progressDeadlineAbort`).
- **Onde está ligado:** em **prod** de todos os apps (`rollout.enabled: true`
  nos `values-prod.yaml`). Develop continua com `Deployment`: deploy rápido.

## Values do chart

```yaml
rollout:
  enabled: true              # Rollout canary em vez de Deployment
  steps:                     # passos padrão
    - setWeight: 20
    - pause: { duration: 2m }
    - setWeight: 50
    - pause: { duration: 2m }
  analysis:
    enabled: true
    template: platform-canary-error-rate
    maxErrorRate: "0.05"     # 5% de 5xx na versão nova = aborta
  progressDeadlineSeconds: 600
```

Variações úteis nos values do app:

```yaml
# aprovação manual antes de 100% (pausa sem duração)
rollout:
  steps:
    - setWeight: 20
    - pause: { duration: 2m }
    - setWeight: 50
    - pause: {}              # espera `make promote`
```

## Operar

```bash
make rollouts                                   # fase, passo, peso de todos
make promote SERVICE=<app> NAMESPACE=<ns>       # pula a pausa atual
make promote SERVICE=<app> NAMESPACE=<ns> FULL=1   # direto a 100% (pula análise!)
make abort   SERVICE=<app> NAMESPACE=<ns>       # volta tudo para a estável
make retry   SERVICE=<app> NAMESPACE=<ns>       # tenta de novo a mesma versão
make rollout SERVICE=<app> NAMESPACE=<ns>       # reinicia os pods (sem canary)
```

- **Dashboard:** https://rollouts.devops.local (somente leitura: ele não tem
  login; as ações passam pelo `kubectl` e pelo RBAC dele). Rode `make hosts`
  uma vez para o host entrar no `/etc/hosts`.
- **ArgoCD:** o Rollout aparece na árvore da Application, com ReplicaSets,
  AnalysisRuns e o Ingress canary. Durante a pausa a Application fica
  *Progressing*; abortado, *Degraded*.
- O plugin `kubectl argo rollouts` é opcional (os `make` usam só `kubectl`).
  Com ele: `kubectl argo rollouts get rollout <app> -n <ns> --watch`.

## Abortou. E agora?

O tráfego já voltou sozinho para a versão estável: **os usuários não estão
mais afetados**. Mas o Git ainda pede a versão nova (o ArgoCD mostra
*Degraded*). Duas saídas:

1. **Corrigir e publicar outra versão** (o normal): o próximo merge na main
   gera uma tag nova, e o canary recomeça.
2. **Reverter no Git** o commit `deploy(<p>/prod): ...` do repo de infra.

`make retry` só faz sentido se a falha foi externa (dependência fora do ar
durante a análise), porque a versão é a mesma.

## Runbooks

### RolloutAborted

1. `make rollouts`: qual app e a mensagem (`Metric "canary-5xx-rate" assessed
   Failed` = 5xx; `ProgressDeadlineExceeded` = não ficou pronta).
2. Para 5xx: Grafana → *Platform / Apps* → logs de erro do app, filtrando o
   pod novo (`kubectl get pods -n <ns>`, o ReplicaSet com hash diferente do
   `ESTÁVEL`).
3. Corrija no repo do app (develop → main). O usuário já está protegido; não
   há pressa de madrugada.

### RolloutStuckPaused

Um passo `pause: {}` (aprovação manual) está esperando há 1h. Decida:
`make promote` ou `make abort`.

## Limites deste lab

- **Sem tráfego, sem veredito:** se ninguém chama o app durante o canary, a
  análise passa (resultado vazio). Em produção real: mínimo de requests na
  query, ou tráfego sintético (k6, smoke test) durante os passos.
- Só 5xx é analisado. Latência (`histogram_quantile` com o mesmo label
  `canary`) e métricas de negócio entram como novas `metrics` no template.
- A troca de `Deployment` para `Rollout` num app já no ar: o ArgoCD cria o
  Rollout e só apaga o Deployment no fim do sync (`PruneLast=true`), então
  não há janela sem pods.
- A estratégia *blue-green* (duas versões completas, troca de uma vez) também
  existe no Argo Rollouts; canary foi escolhido por expor menos usuários.

## Arquivos

| Arquivo | O quê |
| ------- | ----- |
| `scripts/setup-delivery.sh` | instala o Argo Rollouts (`make delivery`) |
| `config/delivery/argo-rollouts-values.yaml` | controller, métricas, dashboard |
| `k8s/rollouts-analysis.yaml` | `ClusterAnalysisTemplate` da taxa de 5xx do canary |
| `charts/app/templates/deployment.yaml` | `Deployment` ou `Rollout` conforme `rollout.enabled` |
| `charts/app/templates/service-canary.yaml` | Service `<app>-canary` |
| `scripts/dev/gen-prometheus-rules.py` | alertas `RolloutAborted` e `RolloutStuckPaused` |
