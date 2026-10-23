# GitOps com ArgoCD

## A ideia

O Git descreve **como o cluster deve estar**. O ArgoCD compara esse **estado
desejado** com o **estado real** e corrige a diferença. Ninguém faz deploy com
`kubectl apply`: deploy é commit.

| Termo | Significado |
| ----- | ----------- |
| **Synced / OutOfSync** | o cluster está (ou não) igual ao Git |
| **Healthy / Progressing / Degraded** | os recursos estão saudáveis, subindo ou com problema |
| **auto-sync** | aplica sozinho quando o Git muda (consulta a cada ~3 min) |
| **selfHeal** | desfaz mudanças feitas direto no cluster |
| **prune** | apaga do cluster o que saiu do Git |

## Um ApplicationSet para todos os projetos

[`argocd/applicationset.yaml`](../argocd/applicationset.yaml) usa o gerador
**git files**: cada arquivo `projects/*/apps/*/values-*.yaml` no Git vira uma
Application.

```
projects/wlstore/apps/catalog-service/values-develop.yaml
         └──┬──┘      └──────┬──────┘        └──┬──┘
         projeto            app                ambiente
→ Application: wlstore-catalog-service-develop
→ namespace:   wlstore-develop
→ chart:       charts/app  +  values.yaml  +  values-develop.yaml
→ parâmetros:  app.name=catalog-service, app.environment=develop, app.project=wlstore
```

O nome da Application é `<app>-<env>`. Ele ganha o prefixo `<projeto>-` quando
o app não começa com o nome do projeto (`crivo-be-develop`,
`wlstore-shell-develop`).

Por isso **adicionar app ou ambiente não exige mexer no ArgoCD**: basta
commitar o arquivo.

[`argocd/appproject.yaml`](../argocd/appproject.yaml) define o projeto
`platform-apps`: só o repo de infra como origem, e os namespaces de infra
(`argocd`, `monitoring`, `kube-*`) bloqueados como destino.

## Operando

| Quero | Como |
| ----- | ---- |
| ver todos os apps | http://argocd.devops.local ou `make apps` |
| forçar leitura do Git agora | botão *Refresh* ou `make refresh [APP=<application>]` |
| entender por que está OutOfSync | *App Details → Diff* |
| ver eventos e logs de um recurso | clique no recurso → *Events* / *Logs* |
| histórico de deploys | *History and Rollback*, ou o `git log` do repo de infra |
| rollback | **`git revert` do commit de deploy** e push |
| reaplicar o ApplicationSet | `make apply-argocd` |
| ver o que seria aplicado | `make render-platform` |

### Por que o rollback é pelo Git e não pelo botão

O botão *Rollback* do ArgoCD aplica uma revisão antiga, mas o Git continua
dizendo outra coisa. Com selfHeal/auto-sync, o Git volta a ganhar. Reverter o
commit mantém o Git como fonte única e deixa registrado quem, quando e por quê.

## Problemas típicos

| Sintoma | Causa | Solução |
| ------- | ----- | ------- |
| app não aparece | `projects/` não foi pushado, ou falta `values-<env>.yaml` | `git push`; *Refresh* no ApplicationSet |
| `ComparisonError` / `values file not found` | caminho de values errado | `make helm-template` local |
| Synced mas Degraded | o problema é no pod, não no Git | [11-treino](11-treino-quebre-e-conserte.md): `describe`/`events` |
| mudança feita com `kubectl` sumiu | selfHeal | commitar no Git |
| ApplicationSet não gera apps | erro no template | `kubectl logs -n argocd deploy/argocd-applicationset-controller` |
