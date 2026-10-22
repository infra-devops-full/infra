# syntax=docker/dockerfile:1
#
# Template de imagem para apps Next.js num monorepo Nx com pnpm.
# Copie para <repo-do-app>/<pasta-do-monorepo>/Dockerfile. O contexto de build é
# a raiz do monorepo (onde ficam nx.json e pnpm-lock.yaml), e cada app vira uma
# imagem:
#
#   docker build --build-arg APP=shell --build-arg PORT=3000 \
#     --build-arg BUILD_ENV="NEXT_PUBLIC_API_URL=http://catalog-service:8081" -t shell .
#
# BUILD_ENV: variáveis que o Next lê no BUILD (rewrites do next.config,
# NEXT_PUBLIC_*), separadas por espaço. Elas ficam embutidas na imagem — use
# endereços que valem em qualquer ambiente, como o Service interno
# (http://<app>:<porta>), quando a chamada parte do servidor Next.

# ---------------------------------------------------------------------------
# 1. Dependências + build
# ---------------------------------------------------------------------------
FROM node:24-alpine AS build
WORKDIR /app

ARG PNPM_VERSION=10.29.3
RUN corepack enable && corepack prepare "pnpm@${PNPM_VERSION}" --activate

ENV NX_DAEMON=false \
    NX_NO_CLOUD=true \
    NEXT_TELEMETRY_DISABLED=1

# Só os manifests primeiro: o `pnpm install` fica em cache enquanto as
# dependências não mudam.
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
COPY apps apps
COPY packages packages
RUN --mount=type=cache,target=/root/.local/share/pnpm/store \
    pnpm install --frozen-lockfile

COPY . .

ARG APP
ARG BUILD_ENV=""
RUN test -n "$APP" || (echo "Informe --build-arg APP=<app do Nx>" && exit 1)
# shellcheck disable=SC2086
RUN env ${BUILD_ENV} pnpm nx run "${APP}:build"

# ---------------------------------------------------------------------------
# 2. Runtime
# ---------------------------------------------------------------------------
FROM node:24-alpine AS runner
WORKDIR /app

ARG APP
ARG PORT=3000
ENV APP=${APP} \
    PORT=${PORT} \
    NODE_ENV=production \
    NEXT_TELEMETRY_DISABLED=1

# node_modules do workspace + o app buildado (o `next start` carrega o
# next.config em runtime).
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/packages ./packages
COPY --from=build /app/apps/${APP} ./apps/${APP}
COPY --from=build /app/package.json ./

USER node
EXPOSE ${PORT}

CMD ["sh", "-c", "exec node_modules/.bin/next start \"apps/$APP\" --port \"$PORT\""]
