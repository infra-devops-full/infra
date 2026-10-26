# Variáveis de ambiente e `.env`

## A regra em uma frase

**Configuração mora no ambiente, não na imagem.** A mesma imagem roda na sua
máquina, em develop e em prod. O que muda são as variáveis que cada lugar
injeta. É isso que permite a release promover para prod exatamente a imagem
testada em develop ([16-releases.md](16-releases.md)).

## Onde cada variável mora

| Tipo | Exemplo | Local (sua máquina) | Cluster |
| ---- | ------- | ------------------- | ------- |
| **config comum** (não é segredo, igual em todo ambiente) | `PORT`, nome de fila | `.env.local` / `.env` | `env:` em `projects/<p>/apps/<app>/values.yaml` |
| **config por ambiente** (não é segredo) | URL de outro serviço, feature flag, nível de log | `.env.local` / `.env` | `env:` em `values-<env>.yaml` (sobrescreve o comum) |
| **segredo do app** | `STRIPE_SECRET_KEY`, `JWT_SECRET` | `.env.local` / `.env` | `projects/<p>/secrets/<env>.env` → `make seal` → Secret `app-secrets` |
| **credencial de infra** | senha do Postgres/Redis/RabbitMQ | docker compose local | gerada pelo `make seal` → Secrets `postgres`, `redis`, `rabbitmq` |

No values do app, os Secrets entram com `envFrom`:

```yaml
env:                      # config (pode ir para o Git em texto puro)
  CATALOG_API_URL: "http://catalog-service:8081"
envFrom:                  # segredos (selados no Git, abertos só no cluster)
  - secretRef: postgres
  - secretRef: app-secrets
    optional: true
```

## No repositório do app

```
meu-app/
├── .env.example      ✅ vai para o Git: TODAS as chaves, valores de exemplo, comentários
├── .env.local        ❌ gitignored: seus valores reais (Next.js)
├── .env              ❌ gitignored: seus valores reais (NestJS, Spring, etc.)
└── .gitignore        →  .env*   e   !.env.example
```

- **`.env.example` é a documentação das variáveis.** Variável nova no
  código entra no `.env.example` no mesmo commit.
- **Nunca** commite `.env`, `.env.production` etc., nem com segredo
  "fake". O `make github` liga o *push protection*, que barra token
  conhecido no push, mas ele não reconhece senha inventada.
- O `.dockerignore` também deve excluir `.env*`: segredo não entra na
  imagem.

### Next.js: o cuidado com `NEXT_PUBLIC_*`

O Next lê os `.env` da **raiz** do projeto (não de `src/`), e trata as
variáveis de dois jeitos:

| | Lida quando | Vai para o navegador? | Muda por ambiente com a mesma imagem? |
| - | ----------- | --------------------- | ------------------------------------- |
| `MINHA_VAR` (sem prefixo) | em **runtime**, no servidor | não | **sim** |
| `NEXT_PUBLIC_MINHA_VAR` | no **`next build`** (gravada no JS) | sim | **não**: fica a do build |

Por isso: URLs de API, tenant, flags → **sem** `NEXT_PUBLIC_`, lidas no
servidor (Server Components, Server Actions, Route Handlers), como o
`wlstore-fe` já faz. Se o navegador precisar de um valor por ambiente,
entregue pelo servidor (prop de um Server Component ou um Route Handler
`/api/config`) ou use caminho relativo no mesmo domínio.

`NEXT_PUBLIC_` só para o que é igual em todo ambiente (ex.: nome do
produto).

### NestJS / Node

`@nestjs/config` (ou `dotenv`) lê o `.env` local. No cluster não há arquivo:
as variáveis chegam pelo `env`/`envFrom` do pod, e o `ConfigService` lê do
mesmo jeito.

### Spring Boot

`application.yml` com placeholders (`${DB_HOST}`) e valores padrão de
desenvolvimento. No cluster os mesmos nomes vêm do pod (veja
`projects/wlstore/apps/*/values.yaml`, que monta `JDBC_URL` com `$(DB_HOST)`).

## Validar na subida (falhar cedo)

Variável faltando deve derrubar o app **na subida**, com mensagem clara, e
não no primeiro request. No Kubernetes isso vira `CrashLoopBackOff` e o
canary aborta antes de afetar usuário.

```ts
// src/config/env.ts (Next/Node) — exemplo com zod
import { z } from 'zod';
export const env = z.object({
  CATALOG_API_URL: z.string().url(),
  PRICING_API_URL: z.string().url(),
  TENANT_ID: z.string().uuid().optional(),
}).parse(process.env);
```

NestJS: `ConfigModule.forRoot({ validationSchema })` (Joi) ou `validate`.
Spring: `@ConfigurationProperties` + `@Validated`.

## Checklist ao criar uma variável

1. Código lê a variável (e valida na subida).
2. `.env.example` ganha a chave, com comentário.
3. **Não é segredo?** `env:` no `values.yaml` (ou `values-<env>.yaml` se
   muda por ambiente).
   **É segredo?** `projects/<p>/secrets/<env>.env` em cada ambiente →
   `make seal PROJECT=<p>` → commit do `sealed/` → `envFrom: app-secrets`.
4. O app lê env só na subida: depois de mudar um Secret,
   `make rollout SERVICE=<app> NAMESPACE=<ns>`.

## Estado dos repos

| Repo | `.gitignore` | `.env.example` |
| ---- | ------------ | -------------- |
| crivo | `.env*` + `!.env.example` | `crivo-be/.env.example` |
| microservice-with-nestjs-rabbitmq | `products/.gitignore`: `.env*` + `!.env.example` | `products/.env.example` |
| wlstore-be | `**/.env*` + `!**/.env.example` | `.env.example` |
| wlstore-fe | `.env*` + `!.env.example` | `.env.example` (raiz) |
