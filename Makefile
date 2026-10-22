.PHONY: help setup start stop restart destroy status logs k9s grafana prometheus argocd \
        secrets ghcr helm-lint helm-template apply-argocd render-platform postgres \
        projects project-apply hosts

# Cores
GREEN  := $(shell tput -Txterm setaf 2)
YELLOW := $(shell tput -Txterm setaf 3)
BLUE   := $(shell tput -Txterm setaf 4)
RED    := $(shell tput -Txterm setaf 1)
RESET  := $(shell tput -Txterm sgr0)

# Os scripts leem o .env por conta própria. Aqui só o CLUSTER_NAME importa
# (não usar `include .env`: o make interpretaria $HOME do DATA_DIR como $(H)).
CLUSTER_NAME ?= $(shell [ -f .env ] && . ./.env; echo $${CLUSTER_NAME:-devops-lab})

help: ## Mostra este menu de ajuda
	@echo "$(BLUE)🚀 DevOps Platform - Comandos$(RESET)"
	@echo ""
	@grep -E '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  $(YELLOW)%-18s$(RESET) %s\n", $$1, $$2}'
	@echo ""
	@echo "$(BLUE)💡 A plataforma é genérica. Projetos vivem em projects/<nome>/project.yaml$(RESET)"

projects: ## Lista projetos, apps e ambientes descobertos em projects/
	@bash -c 'source scripts/lib-project.sh; for p in $$(project_names); do \
		echo "  • $$p  apps: $$(project_apps $$p | xargs)  envs: $$(project_envs $$p | xargs)"; done'

setup: ## Setup completo (cluster + ArgoCD + observabilidade + projetos)
	@echo "$(GREEN)🚀 Iniciando setup...$(RESET)"
	@chmod +x setup.sh
	@./setup.sh

start: ## Inicia o cluster (se estiver parado)
	@k3d cluster start $(CLUSTER_NAME) && echo "$(GREEN)✅ Cluster iniciado$(RESET)"

stop: ## Para o cluster (mantém dados)
	@k3d cluster stop $(CLUSTER_NAME) && echo "$(YELLOW)✅ Cluster parado$(RESET)"

restart: stop start ## Reinicia o cluster

destroy: ## Destroi tudo (interativo com confirmação)
	@chmod +x destroy.sh
	@./destroy.sh

status: ## Mostra status completo do cluster e projetos
	@chmod +x status.sh
	@./status.sh

logs: ## Logs de um app. Uso: make logs SERVICE=products NAMESPACE=nest-rabbitmq-develop
	@if [ -z "$(SERVICE)" ] || [ -z "$(NAMESPACE)" ]; then \
		echo "$(YELLOW)⚠️  Uso: make logs SERVICE=<app> NAMESPACE=<projeto>-<env>$(RESET)"; exit 1; \
	fi
	@kubectl logs -n $(NAMESPACE) -l app.kubernetes.io/name=$(SERVICE) --tail=100 -f

ghcr: ## Cria ghcr-secret. Uso: make ghcr NAMESPACES="<projeto>-develop <projeto>-prod" [TOKEN=ghp_xxx]
	@if [ -z "$(NAMESPACES)" ]; then echo "$(YELLOW)⚠️  Informe NAMESPACES=\"ns1 ns2\"$(RESET)"; exit 1; fi
	@./create-ghcr-secrets.sh --namespaces "$(NAMESPACES)" $(if $(TOKEN),--token $(TOKEN),)

secrets: ## (Re)cria o Secret app-secrets. Uso: make secrets PROJECT=<p> ENV=develop
	@if [ -z "$(PROJECT)" ] || [ -z "$(ENV)" ]; then \
		echo "$(YELLOW)⚠️  Uso: make secrets PROJECT=<p> ENV=develop$(RESET)"; exit 1; \
	fi
	@./scripts/apply-secrets.sh $(PROJECT) $(ENV)

postgres: ## Recria o Postgres de um projeto/ambiente. Uso: make postgres PROJECT=<p> ENV=develop [RESET_DATA=1]
	@if [ -z "$(PROJECT)" ] || [ -z "$(ENV)" ]; then \
		echo "$(YELLOW)⚠️  Uso: make postgres PROJECT=<p> ENV=develop$(RESET)"; exit 1; \
	fi
	@if [ "$$(yq -r '.database != null' projects/$(PROJECT)/project.yaml)" != "true" ]; then \
		echo "$(YELLOW)⚠️  $(PROJECT) não declara database no project.yaml$(RESET)"; exit 1; \
	fi
	@USER=$$(yq -r '.database.user // "postgres"' projects/$(PROJECT)/project.yaml); \
	 PASS=$$(yq -r '.database.password // "postgres"' projects/$(PROJECT)/project.yaml); \
	 DB=$$(yq -r '.database.defaultDb // "app"' projects/$(PROJECT)/project.yaml); \
	 EXTRAS=$$(yq -r '.database.extraDbs // [] | join(" ")' projects/$(PROJECT)/project.yaml); \
	 ARGS="--namespace $(PROJECT)-$(ENV) --user $$USER --password $$PASS --db $$DB --extra-dbs \"$$EXTRAS\""; \
	 if [ "$(RESET_DATA)" = "1" ]; then ARGS="$$ARGS --reset"; fi; \
	 eval ./scripts/setup-postgres.sh $$ARGS

project-apply: ## Prepara UM projeto no cluster (deps, secrets) + /etc/hosts. Uso: make project-apply PROJECT=<p>
	@if [ -z "$(PROJECT)" ]; then echo "$(YELLOW)⚠️  Uso: make project-apply PROJECT=<nome>$(RESET)"; exit 1; fi
	@./scripts/apply-project.sh $(PROJECT)
	@./scripts/hosts.sh apply

hosts: ## Regrava o bloco da plataforma no /etc/hosts (sudo). Ver antes: ./scripts/hosts.sh show
	@./scripts/hosts.sh apply

apply-argocd: ## (Re)aplica a plataforma genérica: argocd/ + k8s/
	@./scripts/apply-platform.sh

render-platform: ## Mostra argocd/ + k8s/ renderizados (sem aplicar)
	@./scripts/apply-platform.sh --render

helm-lint: ## Valida charts/app contra cada projects/<p>/apps/<app>/values-<env>.yaml
	@for f in projects/*/apps/*/values-*.yaml; do \
		dir=$$(dirname $$f); app=$$(basename $$dir); proj=$$(basename $$(dirname $$(dirname $$dir))); \
		env=$$(basename $$f .yaml); env=$${env#values-}; \
		echo "$(BLUE)→ helm lint $$proj/$$app/$$env$(RESET)"; \
		[ -f $$dir/values.yaml ] || { echo "$(RED)✗ falta $$dir/values.yaml$(RESET)"; exit 1; }; \
		helm lint charts/app --quiet -f $$dir/values.yaml -f $$f \
			--set app.name=$$app,app.environment=$$env,app.project=$$proj || exit 1; \
	done
	@echo "$(GREEN)✅ Lint OK$(RESET)"

helm-template: ## Renderiza um app. Uso: make helm-template PROJECT=<p> APP=<app> ENV=develop
	@if [ -z "$(PROJECT)" ] || [ -z "$(APP)" ] || [ -z "$(ENV)" ]; then \
		echo "$(YELLOW)⚠️  Uso: make helm-template PROJECT=<p> APP=<app> ENV=develop$(RESET)"; exit 1; \
	fi
	@helm template $(APP) charts/app \
		-f projects/$(PROJECT)/apps/$(APP)/values.yaml \
		-f projects/$(PROJECT)/apps/$(APP)/values-$(ENV).yaml \
		--set app.name=$(APP),app.environment=$(ENV),app.project=$(PROJECT)

k9s: ## Abre k9s
	@k9s
grafana: ## Abre o Grafana no browser
	@open http://grafana.devops.local
prometheus: ## Abre o Prometheus no browser
	@open http://prometheus.devops.local
argocd: ## Abre o ArgoCD no browser
	@open http://argocd.devops.local

.DEFAULT_GOAL := help
