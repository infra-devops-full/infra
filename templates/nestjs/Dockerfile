# syntax=docker/dockerfile:1
#
# Template de imagem para apps NestJS da plataforma.
# Copie para <repo-do-app>/<app>/Dockerfile — o contexto de build é a pasta
# do app (o workflow usa `context: ./<app>`).

# ---------------------------------------------------------------------------
# 1. Dependências + build
# ---------------------------------------------------------------------------
FROM node:24-alpine AS build
WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci

COPY nest-cli.json tsconfig.json tsconfig.build.json ./
COPY src ./src
RUN npm run build \
  && npm prune --omit=dev

# ---------------------------------------------------------------------------
# 2. Runtime
# ---------------------------------------------------------------------------
FROM node:24-alpine AS runner
WORKDIR /app

ENV NODE_ENV=production
# main.ts lê process.env.PORT; tem de bater com service.port no values.yaml.
ENV PORT=3000

COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/dist ./dist
COPY package.json ./

USER node
EXPOSE 3000

CMD ["node", "dist/main"]
