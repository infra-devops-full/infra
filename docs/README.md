# Documentação

O guia atual da plataforma (setup, adicionar projeto, testar deploy, promover
para prod) está no **[README principal](../README.md)**. A convenção de
projetos está em [`projects/README.md`](../projects/README.md).

## Documentos históricos

Os arquivos abaixo descrevem a **versão anterior** da infra, com chart e
ArgoCD específicos do crivo (Keycloak, Kong, Konga) e caminhos como
`helm/crivo-app`, `argocd/applicationsets/` e `config/secrets.*`. Essa
estrutura foi substituída pelo chart genérico (`charts/app`), pelo
ApplicationSet genérico (`argocd/`) e por `projects/<nome>/`. Eles ficam aqui
como referência de conceitos (k3d, ArgoCD, multi-ambiente, troubleshooting),
não como instrução.

- [01-installation.md](01-installation.md) – pré-requisitos e instalação
- [02-architecture.md](02-architecture.md) – arquitetura e decisões
- [04-argocd.md](04-argocd.md) – AppProjects e ApplicationSets
- [05-applications.md](05-applications.md) – modelagem antiga das apps do crivo
- [06-keycloak.md](06-keycloak.md) – Keycloak (stack antiga do crivo)
- [07-environments.md](07-environments.md) – multi-ambiente
- [08-troubleshooting.md](08-troubleshooting.md) – problemas comuns
- [09-cheatsheet.md](09-cheatsheet.md) – comandos úteis
- [10-kong.md](10-kong.md) – Kong / API Gateway (stack antiga do crivo)
