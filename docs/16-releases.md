# Releases e rollback

## O fluxo

```
feature/x ──PR──► develop ──PR──► main ──release──► prod
   │                 │              │                 │
PR: test+build    push: test +   merge: só      Actions → release → Run workflow
(validação)       build + deploy  CodeQL         (ou make release PROJECT=<p>)
                  em develop     (candidato)      v1.4.0 · changelog · canary
```

- **develop** recebe cada push (tag `sha-<commit>`).
- **main** é o candidato a release: o merge não faz deploy.
- **prod** só recebe **versões** (`1.4.0`), publicadas pelo workflow
  `release` do repo do app.

Assim dá para responder "o que está em produção?" com um número e um
changelog, e voltar para qualquer versão anterior pelo nome.

## Publicar uma versão

```bash
make release PROJECT=crivo                     # versão calculada pelos commits
make release PROJECT=crivo BUMP=minor          # força o tipo
make release PROJECT=wlstore REPO=whitelabel-store/wlstore-fe   # projeto com vários repos
```

Ou no GitHub: **Actions → release → Run workflow** (branch `main`).

O que o workflow faz (`templates/github/release.yml`):

1. **Versão:** última tag `v*` + tipo de mudança dos commits desde ela
   ([Conventional Commits](https://www.conventionalcommits.org/pt-br/)):

   | Commits desde a última versão | Versão |
   | ----------------------------- | ------ |
   | algum `feat!:` ou `BREAKING CHANGE` | **major** (1.4.0 → 2.0.0) |
   | algum `feat:` | **minor** (1.4.0 → 1.5.0) |
   | só `fix:`, `chore:`, ... | **patch** (1.4.0 → 1.4.1) |
   | nenhuma versão ainda | **1.0.0** |

2. **Imagem sem rebuild:** para cada app, acha o commit mais recente com o
   mesmo código do app (`paths` do `APPS_JSON`) que já tem imagem
   `sha-<commit>` no GHCR (buildada e testada na develop) e publica **a
   mesma imagem** com a tag `1.4.0`. O que vai para prod é exatamente o que
   rodou em develop.
3. **Tag `v1.4.0` + GitHub Release** com o changelog agrupado em
   Novidades, Correções, Outros e Mudanças incompatíveis.
4. **Deploy:** commita `image.tag: "1.4.0"` nos `values-prod.yaml` do repo
   de infra. O ArgoCD aplica e o canary (Argo Rollouts) roda.

Um repo = uma versão para todos os apps dele (no crivo, `crivo-be` e
`crivo-fe` sobem juntos como "crivo 1.4.0").

### Hotfix

Actions → **build-and-deploy** → Run workflow na branch `main`: builda e
faz deploy direto em prod com a tag `sha-<commit>`. É a porta de emergência;
depois, traga a correção para a develop.

## Voltar uma versão (rollback)

### Opção 1: canary em andamento → abortar (segundos)

Se o problema aparece **durante** o canary (os ~5 min de 20% → 50%), aborte:
o tráfego volta inteiro para a versão estável na hora.

- **ArgoCD:** Application `<app>-prod` → clique no recurso **Rollout** →
  menu **⋮** → **Actions → abort**.
- **Terminal:** `make abort SERVICE=<app> NAMESPACE=<projeto>-prod`.

A análise automática faz isso sozinha se a taxa de 5xx subir. O abort manual
é para o que a métrica não pega (ex.: um texto errado na tela).

### Opção 2: versão já em produção → `make rollback` (o jeito GitOps)

```bash
make rollback PROJECT=wlstore ENV=prod                  # todos os apps → versão anterior
make rollback PROJECT=wlstore ENV=prod APP=wlstore-fe   # só um app
make rollback PROJECT=crivo ENV=prod TO=1.3.0           # versão específica
```

O script mostra `atual → anterior`, pede confirmação, commita no repo de
infra, dá push e avisa o ArgoCD (refresh). Em prod, voltar para uma das 3
últimas versões **não passa pelo canary** (`rollbackWindow`): aquela versão
já rodou 100% antes, então a troca é imediata.

### Por que não o botão "Rollback" do ArgoCD?

O ArgoCD tem **History and Rollback** (Application → *History and
Rollback* → versão anterior → *Rollback*). Mas, com **auto-sync** ligado
(como aqui), o botão fica **bloqueado** ("Auto-Sync is enabled"). O motivo:

```
Git diz: image.tag = 1.4.0 (com a <div>Test</div>)
Rollback pelo painel → cluster volta para 1.3.0
selfHeal: "o cluster difere do Git" → volta para 1.4.0 em segundos
```

Para usar o botão seria preciso desligar o auto-sync da Application (App
Details → Sync Policy → Disable Auto-Sync), fazer o rollback e, depois,
corrigir o Git e religar. Durante esse tempo o cluster não bate com o Git,
o alerta `ArgoAppOutOfSync` dispara em 30 min e qualquer sync manual desfaz
o rollback. **No GitOps, o rollback é um commit**: fica registrado quem
voltou, quando e por quê, e o cluster continua igual ao Git.

### Exemplo: a `<div>Test</div>` foi para prod por engano

```bash
make rollouts                                   # o canary já terminou?
# ainda no canary → abort (opção 1)
make abort SERVICE=wlstore-fe NAMESPACE=wlstore-prod
# já terminou → rollback (opção 2), imediato pela rollbackWindow
make rollback PROJECT=wlstore ENV=prod APP=wlstore-fe
```

Depois, no repo do app: `git revert <commit da div>` na develop → PR para
main → `make release` (sai uma versão nova, sem a div).

## Perguntas frequentes

**A release é sempre para prod?** Sim. Cada ambiente tem o seu gatilho:

| Ambiente | Recebe | Gatilho | Tag da imagem |
| -------- | ------ | ------- | ------------- |
| develop | cada push na `develop` | automático (build-and-deploy) | `sha-<commit>` |
| prod | só versões | **release** (botão ou `make release`) | `1.4.0` (a mesma imagem de um `sha-` já testado) |

A `main` não é um ambiente: é o código aprovado, pronto para virar versão.

**Por que o ArgoCD mostra "Suspended" durante o deploy?** Durante as pausas
do canary (`pause: 2m`), o Rollout fica pausado, e o ArgoCD mostra a saúde
dele (e da Application) como *Suspended*. É esperado: a versão nova está
recebendo 20% ou 50% dos requests enquanto a análise mede. No fim dos
passos, volta para *Healthy*. Se a análise reprovar, vira *Degraded*.

**Onde vejo o que entrou numa versão?** Na GitHub Release
(`github.com/<org>/<repo>/releases/tag/v1.4.0`), com o changelog e o
link de comparação. No ArgoCD, o recurso Rollout tem um ícone de link
externo que abre essa página (annotation gravada pela release). No dashboard
do Argo Rollouts aparece só a imagem (`:1.4.0`) de cada *Revision*.

**E os botões do dashboard do Argo Rollouts?**

| Botão | O que faz | Convive com o GitOps? |
| ----- | --------- | --------------------- |
| Abort | tira o peso do canary (status do Rollout) | **sim**: o ArgoCD não reverte status |
| Promote / PromoteFull | avança o canary | sim |
| Retry | tenta de novo um canary abortado | sim |
| **Rollback** (numa Revision) | troca o pod template para a revisão antiga | **não**: o selfHeal do ArgoCD reaplica a versão do Git e começa outro canary. Use `make rollback` |
| Restart | recria os pods (mesma versão) | sim |

Sem o login único, o dashboard é **somente leitura**: os botões aparecem,
mas a ação falha com "Error rolling back" / "An unexpected error occurred"
(a conta do dashboard só pode ler). Com o login único (`make sso`,
[18-login-sso.md](18-login-sso.md)), ele exige login de admin e as ações
ficam liberadas. Mesmo assim, para **voltar versão**, use `make rollback`:
o botão Rollback é desfeito pelo ArgoCD (tabela acima).

## Arquivos

| Arquivo | O quê |
| ------- | ----- |
| `templates/github/release.yml` | workflow de release (copiar para `.github/workflows/` do app) |
| `templates/github/deploy.yml` | build/deploy da develop; Run workflow na main = hotfix |
| `scripts/rollback.sh` | rollback pelo Git (`make rollback`) |
| `charts/app` → `rollout.rollbackWindow` | quantas versões recentes voltam sem canary (padrão 3) |

## Problemas comuns

| Sintoma | Causa | Solução |
| ------- | ----- | ------- |
| release: `nada novo desde v1.4.0` | não houve merge develop → main desde a última versão | merge e rode de novo |
| release: `sem imagem buildada para o código atual de: <app>` | o código do app na main nunca foi buildado (ex.: commit direto na main) | Run workflow do build-and-deploy na develop, ou faça a mudança passar pela develop |
| release: `a tag vX.Y.Z já existe` | versão explícita repetida | outra versão (ou `BUMP=`) |
| botão Rollback do ArgoCD desabilitado | auto-sync ligado | `make rollback` (commit no Git) |
| `make rollback` em prod passou pelo canary | a versão de destino é mais antiga que as 3 últimas | esperado; ou `make promote FULL=1` |
