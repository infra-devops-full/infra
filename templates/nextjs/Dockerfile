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
#
# Multi-arch (amd64 + arm64) sem emulação: o CI builda as duas arquiteturas
# num runner amd64, e o arm64 emulado (QEMU) levava minutos. Aqui o
# `next build` (JavaScript, igual para as duas) roda na arquitetura do runner
# ($BUILDPLATFORM) e as dependências de produção são baixadas já com os
# binários da arquitetura de destino. O estágio final só copia arquivos.

ARG NODE_IMAGE=node:24-alpine
# O npm da imagem node:24 pode ser mais novo que o que gerou o lock e recusar
# o `npm ci` ("Missing: @emnapi/... from lock file", peer opcional do
# @napi-rs/wasm-runtime). Fixe aqui a versão da máquina que gera o lock.
ARG NPM_VERSION=11.6.2

# ---------------------------------------------------------------------------
# 1. Build — arquitetura do runner (nativo)
# ---------------------------------------------------------------------------
FROM --platform=$BUILDPLATFORM ${NODE_IMAGE} AS build
ARG NPM_VERSION
WORKDIR /app
RUN npm install -g npm@${NPM_VERSION}

COPY package.json package-lock.json ./
RUN --mount=type=cache,target=/root/.npm npm ci

COPY . .

ARG NEXT_PUBLIC_API_URL
ENV NEXT_PUBLIC_API_URL=${NEXT_PUBLIC_API_URL} \
    NEXT_TELEMETRY_DISABLED=1
RUN npm run build

# ---------------------------------------------------------------------------
# 2. Dependências de produção — no runner, PARA a arquitetura de destino.
#    --cpu/--os/--libc baixam os binários pré-compilados certos (sharp,
#    @next/swc...) sem executar nada da outra arquitetura. Sem scripts de
#    instalação: confira antes que nenhuma dependência de produção COMPILA
#    código no install (o do sharp só confere o binário):
#      npm query ':root > .prod, :root > .prod *' | grep -E '"(pre|post)?install"'
# ---------------------------------------------------------------------------
FROM --platform=$BUILDPLATFORM ${NODE_IMAGE} AS deps
ARG NPM_VERSION
ARG TARGETARCH
WORKDIR /app
RUN npm install -g npm@${NPM_VERSION}

COPY package.json package-lock.json ./
RUN --mount=type=cache,target=/root/.npm \
    npm ci --omit=dev --ignore-scripts --os=linux --libc=musl \
      --cpu="$([ "$TARGETARCH" = amd64 ] && echo x64 || echo "$TARGETARCH")"

# ---------------------------------------------------------------------------
# 3. Runtime — arquitetura de destino
# ---------------------------------------------------------------------------
FROM ${NODE_IMAGE} AS runner
WORKDIR /app

ENV NODE_ENV=production \
    NEXT_TELEMETRY_DISABLED=1 \
    PORT=3000

# `next start` carrega o next.config.ts em runtime (funciona sem as devDeps).
# Para uma imagem bem menor, use `output: "standalone"` no next.config e
# copie .next/standalone + .next/static em vez de node_modules.
COPY --from=deps  /app/package.json ./
COPY --from=deps  /app/node_modules ./node_modules
COPY --from=build /app/next.config.* ./
COPY --from=build /app/public ./public
COPY --from=build /app/.next ./.next

USER node
EXPOSE 3000

CMD ["npx", "next", "start"]
