# syntax=docker/dockerfile:1
#
# Template de imagem para serviços Spring Boot num multi-módulo Maven.
# Copie para <repo-do-app>/<pasta-do-pom-raiz>/Dockerfile. O contexto de build
# é a pasta do pom.xml raiz (o que lista os <modules>), e cada serviço vira uma
# imagem escolhendo o módulo:
#
#   docker build --build-arg SERVICE=catalog-service -t catalog .
#
# Os módulos de que o serviço depende (ex.: uma lib *-common) são compilados
# junto (`-pl <serviço> -am`), sem precisar de `mvn install` antes.

# ---------------------------------------------------------------------------
# 1. Build
# ---------------------------------------------------------------------------
# --platform=$BUILDPLATFORM: o Maven roda na arquitetura do runner (nativo).
# O .jar é o mesmo em amd64 e arm64, então no build multi-arch só o estágio de
# runtime é por arquitetura — sem emular a compilação no QEMU, que é lenta.
FROM --platform=$BUILDPLATFORM maven:3.9-eclipse-temurin-21 AS build
WORKDIR /src

ARG SERVICE
RUN test -n "$SERVICE" || (echo "Informe --build-arg SERVICE=<módulo>" && exit 1)

COPY . .
# Cache do ~/.m2 entre builds (BuildKit) — sem ele, cada build baixa tudo.
RUN --mount=type=cache,target=/root/.m2 \
    mvn -B -q -pl "$SERVICE" -am -DskipTests package \
 && cp "$(ls "$SERVICE"/target/*.jar | grep -v -- '-plain.jar$' | head -1)" /app.jar

# ---------------------------------------------------------------------------
# 2. Runtime
# ---------------------------------------------------------------------------
FROM eclipse-temurin:21-jre
WORKDIR /app

RUN useradd --system --uid 1001 --no-create-home app
COPY --from=build /app.jar /app/app.jar
USER app

# A JVM respeita o limite de memória do container: o heap usa até 75% dele
# (o resources.limits.memory do values.yaml).
ENV JAVA_TOOL_OPTIONS="-XX:MaxRAMPercentage=75 -XX:+ExitOnOutOfMemoryError"

# A porta vem do server.port do application.yaml (ou SERVER_PORT no values).
ENTRYPOINT ["java", "-jar", "/app/app.jar"]
