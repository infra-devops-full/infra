# Assinatura de imagem e SBOM (supply chain)

## O problema

O cluster roda o que estiver no registry com aquela tag. Se alguém com
acesso ao GHCR (ou um token vazado) publicar uma imagem com a mesma tag,
ela roda em produção como se fosse nossa. A assinatura responde: **esta
imagem saiu do nosso CI, deste repositório, deste commit?**

## Como funciona

```
CI (deploy.yml / release.yml)                      cluster
──────────────────────────────                     ───────
build → push → digest sha256:ab12…                 Pod pedindo ghcr.io/…:1.4.0
          │                                               │
          ▼                                               ▼
GitHub Actions emite a identidade do workflow      Kyverno (ImageValidatingPolicy)
(OIDC: "crivo-sync/crivo, deploy.yml, develop")     baixa a assinatura do digest,
          │                                         confere no Sigstore e compara
          ▼                                         a identidade com os repos de
cosign assina o digest  ──► Sigstore (Fulcio emite  projects/ → aceita ou recusa
                            um certificado de 10 min;
                            Rekor registra no log público)
```

- **Keyless:** não existe chave privada para guardar, rotacionar ou vazar.
  A "chave" é a identidade do workflow, comprovada pelo GitHub.
- **Assina o digest**, não a tag: a release publica a mesma imagem como
  `:1.4.0` e assina de novo com a identidade do `release.yml`.
- **SBOM** (*Software Bill of Materials*): a lista de pacotes e libs da
  imagem (gerada pelo Syft), anexada como **atestado assinado**. Quando
  sair um CVE numa lib, dá para saber quais imagens a usam sem baixar
  nenhuma.

## A política

`k8s/kyverno-image-signatures.yaml`:

| Ponto | Valor |
| ----- | ----- |
| vale para | pods dos namespaces de projeto, imagens `ghcr.io/*` |
| identidade aceita | `deploy.yml` ou `release.yml` de um repo declarado em `projects/*/project.yaml` (`appRepo`/`appRepos`), emitida por `token.actions.githubusercontent.com` |
| ação | **Audit** (relata). Troque para `[Deny]` quando todas as imagens em uso forem assinadas |
| não mexe na tag | `mutateDigest: false`: o Kyverno não troca a tag pelo digest, que o ArgoCD veria como diferença do Git |

A lista de repos é gerada pelo `apply-platform.sh`, então projeto novo entra
sem editar a política. Um repo fora da lista, ou outro workflow do mesmo
repo, é recusado.

## Ver e testar

```bash
make verify-image IMAGE=ghcr.io/whitelabel-store/wlstore-fe/wlstore-fe:1.2.0
#   ✅ assinada por https://github.com/whitelabel-store/wlstore-fe/.github/workflows/release.yml@refs/heads/main
#      commit 1a2b3c…
#   ✅ 812 pacotes listados

make policies          # imagens sem assinatura aparecem como fail (Audit)
```

## Ligar o bloqueio (Deny)

1. Faça um push na develop de cada repo (o build passa a assinar) e uma
   release (assina a versão de prod).
2. `make policies`: nenhuma linha `platform-verify-image-signature … fail`
   nos apps em uso.
3. Em `k8s/kyverno-image-signatures.yaml`, troque `validationActions: [Audit]`
   por `[Deny]`, commite e rode `make apply-argocd`.

A partir daí, uma imagem que não saiu do CI é recusada no sync do ArgoCD
(e o canary nem começa).

## Detalhes de implementação

- **cosign v2** (`cosign-release: v2.6.5`): assinatura no formato clássico
  (tag `.sig` ao lado da imagem), verificado com o Kyverno 1.19. A v3 usa
  outro formato por padrão; fica para quando o Kyverno e o GHCR forem
  validados com ele.
- `id-token: write` nas permissões dos jobs que assinam: é o que permite
  ao workflow pedir a identidade OIDC ao GitHub.
- O Kyverno precisa de saída para a internet (Sigstore público: Fulcio,
  Rekor, TUF). Num ambiente sem internet, usa-se um Sigstore privado ou
  assinatura com chave (`cosign.key`).

## Problemas comuns

| Sintoma | Causa | Solução |
| ------- | ----- | ------- |
| CI: `cosign sign` → `getting OIDC token` / 403 | job sem `id-token: write` | usar o template atual (`templates/github/deploy.yml`) |
| `make verify-image`: sem assinatura | imagem buildada antes da assinatura no CI | novo push na develop / nova release |
| Kyverno recusa (com Deny) imagem do próprio CI | repo não está em `appRepo(s)` do projeto, ou o workflow tem outro nome | conferir o `project.yaml` e `make apply-argocd` |
| política reporta `failed to verify cosign signatures: none of the expected identities matched` | assinada por outra identidade | esperado para imagens de fora |
