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
`wlstore-vitrine-mfe-develop`).

Por isso **adicionar app ou ambiente não exige mexer no ArgoCD**: basta
commitar o arquivo.

## Um AppProject por projeto

Cada projeto aparece separado na UI (filtro **Projects** na barra lateral) e
só consegue aplicar nos seus próprios namespaces:

```
argocd/appproject.yaml               AppProject "platform" (só cria AppProjects)
argocd/applicationset-projects.yaml  projects/<p>/project.yaml → Application project-<p>
                                       └─ charts/argocd-project → AppProject <p>
argocd/applicationset.yaml           apps     → AppProject <p>
argocd/applicationset-secrets.yaml   segredos → AppProject <p>
```

| AppProject | Contém | Pode aplicar em |
| ---------- | ------ | --------------- |
| `platform` | `project-<p>` (um por projeto) | só `AppProject` no namespace `argocd` |
| `<p>` | apps (`kind=app`) e segredos (`kind=secrets`) do projeto | namespaces `<p>-*` |

A descrição de cada AppProject vem do campo `description` do
`projects/<p>/project.yaml`; os repos de código (`appRepos`/`appRepo`) viram
anotações dele.

### Atalhos na UI

Cada Application de app traz:

- **links** para o dashboard e para os SLOs do app no Grafana, já filtrados
  por projeto, ambiente e app (anotações `link.argocd.argoproj.io/*`);
- **Info** (aba *Summary*): ambiente e arquivo de values que a gerou.

Para achar algo rápido: filtro **Projects** (um projeto), **Labels**
`devops-platform/env=develop` (um ambiente) ou `devops-platform/kind=app`
(esconde segredos e AppProjects).

Os dashboards do Grafana linkam de volta: *ArgoCD do projeto* abre a lista já
filtrada no projeto selecionado.

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
| `AppProject <p> not found` numa Application | o `project-<p>` ainda não sincronizou | aguarde/`make refresh APP=project-<p>`; confira o `project.yaml` |
