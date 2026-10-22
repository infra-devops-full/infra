# syntax=docker/dockerfile:1
#
# Template de imagem para apps Next.js da plataforma.
# Copie para <repo-do-app>/<app>/Dockerfile — o contexto de build é a pasta
# do app (o workflow usa `context: ./<app>`).
#
# NEXT_PUBLIC_* é embutido no BUILD (não adianta setar no Deployment). Para a
# mesma imagem servir todos os ambientes, aponte para algo que resolva igual em
# qualquer namespace — ex.: o Service interno da API (http://<app-api>:<porta>),
# desde que só o servidor Next (Server Actions, middleware, RSC) faça as chamadas.

# ---------------------------------------------------------------------------
# 1. Dependências + build
# ---------------------------------------------------------------------------
FROM node:24-alpine AS build
WORKDIR /app

# O npm da imagem node:24 pode ser mais novo que o que gerou o lock e recusar
# o `npm ci` ("Missing: @emnapi/... from lock file", peer opcional do
# @napi-rs/wasm-runtime). Fixe aqui a versão da máquina que gera o lock.
ARG NPM_VERSION=11.6.2
RUN npm install -g npm@${NPM_VERSION}

COPY package.json package-lock.json ./
RUN npm ci

COPY . .

ARG NEXT_PUBLIC_API_URL
ENV NEXT_PUBLIC_API_URL=${NEXT_PUBLIC_API_URL} \
    NEXT_TELEMETRY_DISABLED=1
RUN npm run build \
  && npm prune --omit=dev

# ---------------------------------------------------------------------------
# 2. Runtime
# ---------------------------------------------------------------------------
FROM node:24-alpine AS runner
WORKDIR /app

ENV NODE_ENV=production \
    NEXT_TELEMETRY_DISABLED=1 \
    PORT=3000

# `next start` carrega o next.config.ts em runtime (funciona sem as devDeps).
# Para uma imagem bem menor, use `output: "standalone"` no next.config e
# copie .next/standalone + .next/static em vez de node_modules.
COPY --from=build /app/package.json ./
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/next.config.* ./
COPY --from=build /app/public ./public
COPY --from=build /app/.next ./.next

USER node
EXPOSE 3000

CMD ["npx", "next", "start"]
