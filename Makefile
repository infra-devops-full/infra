.PHONY: help setup start stop restart destroy status logs k9s grafana prometheus alertmanager argocd alerts gen-observability \
        security trust-ca untrust-ca policies policy-check \
        delivery rollouts promote abort retry lab-canary \
        release rollback \
        sso sso-github \
        logos \
        verify-image \
        notifications notifications-webhooks notify-test \
        data db-status db-backup db-restore db-restore-test db-psql tracing cloud cloud-check cloud-backup-env \
        sealed-secrets seal ghcr helm-lint helm-template apply-argocd render-platform postgres \
        projects project-apply doctor github observability lab-up lab-status lab-down hosts pods apps describe events rollout shell pf refresh

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

logs: ## Logs de um app. Uso: make logs SERVICE=catalog-service NAMESPACE=wlstore-develop
	@if [ -z "$(SERVICE)" ] || [ -z "$(NAMESPACE)" ]; then \
		echo "$(YELLOW)⚠️  Uso: make logs SERVICE=<app> NAMESPACE=<projeto>-<env>$(RESET)"; exit 1; \
	fi
	@kubectl logs -n $(NAMESPACE) -l app.kubernetes.io/name=$(SERVICE) --tail=100 -f

pods: ## Pods dos projetos (ou de um namespace). Uso: make pods [NAMESPACE=<projeto>-<env>]
	@if [ -n "$(NAMESPACE)" ]; then kubectl get pods -n $(NAMESPACE) -o wide; \
	else bash -c 'source scripts/lib-project.sh; for p in $$(project_names); do for ns in $$(project_namespaces $$p); do \
		echo "── $$ns"; kubectl get pods -n $$ns 2>/dev/null; done; done'; fi

apps: ## Applications do ArgoCD (sync/health)
	@kubectl get applications -n argocd -o custom-columns='APP:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,REVISION:.status.sync.revision'

describe: ## Detalha o pod de um app (eventos no fim). Uso: make describe SERVICE=<app> NAMESPACE=<projeto>-<env>
	@if [ -z "$(SERVICE)" ] || [ -z "$(NAMESPACE)" ]; then \
		echo "$(YELLOW)⚠️  Uso: make describe SERVICE=<app> NAMESPACE=<projeto>-<env>$(RESET)"; exit 1; \
	fi
	@kubectl describe pod -n $(NAMESPACE) -l app.kubernetes.io/name=$(SERVICE)

events: ## Eventos recentes de um namespace (erros de pull, probes...). Uso: make events NAMESPACE=<projeto>-<env>
	@if [ -z "$(NAMESPACE)" ]; then echo "$(YELLOW)⚠️  Uso: make events NAMESPACE=<projeto>-<env>$(RESET)"; exit 1; fi
	@kubectl get events -n $(NAMESPACE) --sort-by=.lastTimestamp | tail -25

rollout: ## Reinicia um app (puxa a imagem de novo). Uso: make rollout SERVICE=<app> NAMESPACE=<projeto>-<env>
	@if [ -z "$(SERVICE)" ] || [ -z "$(NAMESPACE)" ]; then \
		echo "$(YELLOW)⚠️  Uso: make rollout SERVICE=<app> NAMESPACE=<projeto>-<env>$(RESET)"; exit 1; \
	fi
	@# Rollout (Argo Rollouts): restartAt recria os pods aos poucos, sem canary.
	@if kubectl get rollout $(SERVICE) -n $(NAMESPACE) >/dev/null 2>&1; then \
		kubectl patch rollout $(SERVICE) -n $(NAMESPACE) --type merge \
			-p "{\"spec\":{\"restartAt\":\"$$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}}" && \
		kubectl wait rollout/$(SERVICE) -n $(NAMESPACE) --for=jsonpath='{.status.phase}'=Healthy --timeout=180s; \
	else \
		kubectl rollout restart deploy/$(SERVICE) -n $(NAMESPACE) && \
		kubectl rollout status deploy/$(SERVICE) -n $(NAMESPACE) --timeout=180s; \
	fi

shell: ## Abre um shell no container de um app. Uso: make shell SERVICE=<app> NAMESPACE=<projeto>-<env>
	@if [ -z "$(SERVICE)" ] || [ -z "$(NAMESPACE)" ]; then \
		echo "$(YELLOW)⚠️  Uso: make shell SERVICE=<app> NAMESPACE=<projeto>-<env>$(RESET)"; exit 1; \
	fi
	@kubectl exec -it -n $(NAMESPACE) deploy/$(SERVICE) -- sh

pf: ## Port-forward de um Service p/ localhost. Uso: make pf SERVICE=<svc> NAMESPACE=<ns> PORT=<porta> [LOCAL=<porta>]
	@if [ -z "$(SERVICE)" ] || [ -z "$(NAMESPACE)" ] || [ -z "$(PORT)" ]; then \
		echo "$(YELLOW)⚠️  Uso: make pf SERVICE=postgres NAMESPACE=wlstore-develop PORT=5432 [LOCAL=5433]$(RESET)"; exit 1; \
	fi
	@kubectl port-forward -n $(NAMESPACE) svc/$(SERVICE) $(or $(LOCAL),$(PORT)):$(PORT)

refresh: ## Força o ArgoCD a reler o Git agora. Uso: make refresh [APP=wlstore-fe-develop] (sem APP = todos)
	@if [ -n "$(APP)" ]; then \
		kubectl -n argocd annotate application $(APP) argocd.argoproj.io/refresh=hard --overwrite; \
	else \
		kubectl -n argocd annotate applicationset platform-apps argocd.argoproj.io/application-set-refresh=true --overwrite; \
		kubectl -n argocd annotate applications --all argocd.argoproj.io/refresh=hard --overwrite; \
	fi

ghcr: ## Cria ghcr-secret. Uso: make ghcr NAMESPACES="<projeto>-develop <projeto>-prod" [TOKEN=ghp_xxx]
	@if [ -z "$(NAMESPACES)" ]; then echo "$(YELLOW)⚠️  Informe NAMESPACES=\"ns1 ns2\"$(RESET)"; exit 1; fi
	@./create-ghcr-secrets.sh --namespaces "$(NAMESPACES)" $(if $(TOKEN),--token $(TOKEN),)

security: ## Instala/atualiza cert-manager + CA local e Kyverno, e aplica as políticas (cluster existente)
	@./scripts/setup-security.sh
	@./scripts/apply-platform.sh

CA_CERT := $(shell eval echo "$${PLATFORM_CA_DIR:-$$HOME/.config/devops-platform/ca}")/platform-ca.crt

trust-ca: ## Confia na CA local no macOS (https://*.local sem aviso). Pede a senha do Mac
	@test -f "$(CA_CERT)" || { echo "$(RED)✗ $(CA_CERT) não existe — rode make security$(RESET)"; exit 1; }
	@echo "$(BLUE)→ adicionando a CA ao keychain do sistema (sudo)$(RESET)"
	@sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain "$(CA_CERT)"
	@echo "$(GREEN)✅ CA confiada. Reabra o navegador. (Firefox usa repositório próprio: veja docs/14-seguranca.md)$(RESET)"

untrust-ca: ## Remove a CA local do keychain do macOS
	@sudo security remove-trusted-cert -d "$(CA_CERT)" 2>/dev/null || true
	@sudo security delete-certificate -c "DevOps Platform Local CA" /Library/Keychains/System.keychain 2>/dev/null || true
	@echo "$(GREEN)✅ CA removida do keychain$(RESET)"

policies: ## Violações das políticas do Kyverno nos projetos (PolicyReports)
	@kubectl get policyreport -A -o json | jq -r '(["NAMESPACE","RECURSO","POLÍTICA","RESULTADO","MENSAGEM"] | @tsv), \
		(.items[] | .metadata.namespace as $$ns | (.scope.kind + "/" + .scope.name) as $$r \
		| .results[]? | select(.result != "pass") \
		| [$$ns, $$r, .policy, .result, (.message | .[0:70])] | @tsv)' | column -t -s $$'\t'

policy-check: ## Testa as políticas do Kyverno contra todos os apps renderizados (sem cluster)
	@./scripts/policy-check.sh

release: ## Publica uma versão em prod (Actions → 🏷️ Release em prod). Uso: make release PROJECT=<p> [REPO=owner/repo] [BUMP=auto|patch|minor|major] [VERSION=X.Y.Z]
	@if [ -z "$(PROJECT)" ]; then echo "$(YELLOW)⚠️  Uso: make release PROJECT=<p> [REPO=owner/repo] [BUMP=auto] [VERSION=X.Y.Z]$(RESET)"; exit 1; fi
	@REPOS="$$(bash -c 'source scripts/lib-project.sh; project_app_repos $(PROJECT)' | sed -E 's#https://github.com/##; s#\.git$$##')"; \
	REPO="$(REPO)"; \
	if [ -z "$$REPO" ]; then \
		if [ "$$(echo "$$REPOS" | wc -l | tr -d ' ')" != "1" ]; then \
			echo "$(YELLOW)⚠️  $(PROJECT) tem mais de um repo; escolha com REPO=:$(RESET)"; echo "$$REPOS" | sed 's/^/   /'; exit 1; \
		fi; REPO="$$REPOS"; \
	fi; \
	gh workflow run release.yml -R "$$REPO" --ref main -f bump="$(or $(BUMP),auto)" -f version="$(VERSION)" && \
	echo "$(GREEN)✅ release disparada em $$REPO$(RESET) — acompanhe em https://github.com/$$REPO/actions/workflows/release.yml"

rollback: ## Volta prod/develop para a versão anterior PELO GIT. Uso: make rollback PROJECT=<p> ENV=<e> [APP=<app>] [TO=<tag>]
	@if [ -z "$(PROJECT)" ] || [ -z "$(ENV)" ]; then echo "$(YELLOW)⚠️  Uso: make rollback PROJECT=<p> ENV=<e> [APP=<app>] [TO=<tag>]$(RESET)"; exit 1; fi
	@./scripts/rollback.sh $(PROJECT) $(ENV) $(if $(APP),--app $(APP)) $(if $(TO),--to $(TO))

notifications: ## Notificações no Discord (alertas e deploys) — precisa dos webhooks selados
	@./scripts/setup-notifications.sh

notifications-webhooks: ## Sela as URLs dos webhooks do Discord (#alertas, #alertas-develop, #deploys)
	@./scripts/seal-notifications.sh

notify-test: ## Manda notificações de teste para os canais do Discord
	@./scripts/notify-test.sh

verify-image: ## Confere a assinatura (CI da plataforma) e o SBOM de uma imagem. Uso: make verify-image IMAGE=ghcr.io/<org>/<repo>/<app>:<tag>
	@./scripts/verify-image.sh $(IMAGE)

logos: ## Baixa o logo de cada projeto (project.yaml → logo: URL) para projects/<p>/logo.png. Uso: make logos [PROJECT=<p>]
	@./scripts/sync-logos.sh $(PROJECT)

sso: ## Login único (GitHub via Dex) no ArgoCD, Grafana, Prometheus, Alertmanager e Rollouts
	@./scripts/setup-sso.sh

sso-github: ## Sela o Client ID/secret do OAuth App do GitHub (config/auth/github-oauth.sealed.yaml)
	@./scripts/seal-sso.sh

delivery: ## Instala/atualiza o Argo Rollouts (canary) e a análise padrão (cluster existente)
	@./scripts/setup-delivery.sh
	@./scripts/apply-platform.sh

rollouts: ## Rollouts (canary) de todos os projetos: fase, passo, peso e versões
	@kubectl get rollouts -A -o json | jq -r '(["NAMESPACE","APP","FASE","PASSO","PESO CANARY","ESTÁVEL","MENSAGEM"] | @tsv), \
		(.items[] | [.metadata.namespace, .metadata.name, .status.phase, \
		 (((.status.currentStepIndex // 0) | tostring) + "/" + ((.spec.strategy.canary.steps // []) | length | tostring)), \
		 ((.status.canary.weights.canary.weight // 0) | tostring) + "%", (.status.stableRS // "-"), \
		 ((.status.message // "") | .[0:60])] | @tsv)' | column -t -s $$'\t'

promote: ## Avança o canary (pula a pausa atual; FULL=1 vai direto a 100%). Uso: make promote SERVICE=<app> NAMESPACE=<ns>
	@if [ -z "$(SERVICE)" ] || [ -z "$(NAMESPACE)" ]; then echo "$(YELLOW)⚠️  Uso: make promote SERVICE=<app> NAMESPACE=<ns> [FULL=1]$(RESET)"; exit 1; fi
	@if [ -n "$(FULL)" ]; then \
		kubectl patch rollout $(SERVICE) -n $(NAMESPACE) --subresource=status --type merge -p '{"status":{"promoteFull":true}}'; \
	else \
		kubectl patch rollout $(SERVICE) -n $(NAMESPACE) --subresource=status --type merge -p '{"status":{"pauseConditions":null}}' && \
		kubectl patch rollout $(SERVICE) -n $(NAMESPACE) --type merge -p '{"spec":{"paused":false}}'; \
	fi

abort: ## Aborta o canary: todo o tráfego volta para a versão estável. Uso: make abort SERVICE=<app> NAMESPACE=<ns>
	@if [ -z "$(SERVICE)" ] || [ -z "$(NAMESPACE)" ]; then echo "$(YELLOW)⚠️  Uso: make abort SERVICE=<app> NAMESPACE=<ns>$(RESET)"; exit 1; fi
	@kubectl patch rollout $(SERVICE) -n $(NAMESPACE) --subresource=status --type merge -p '{"status":{"abort":true}}'

retry: ## Tenta de novo um canary abortado (mesma versão). Uso: make retry SERVICE=<app> NAMESPACE=<ns>
	@if [ -z "$(SERVICE)" ] || [ -z "$(NAMESPACE)" ]; then echo "$(YELLOW)⚠️  Uso: make retry SERVICE=<app> NAMESPACE=<ns>$(RESET)"; exit 1; fi
	@kubectl patch rollout $(SERVICE) -n $(NAMESPACE) --subresource=status --type merge -p '{"status":{"abort":false}}'

sealed-secrets: ## Instala o controller do Sealed Secrets + backup/restauração da chave
	@./scripts/setup-sealed-secrets.sh

seal: ## Gera os SealedSecrets (commitáveis) de um projeto. Uso: make seal PROJECT=<p> [ENV=<e>]
	@if [ -z "$(PROJECT)" ]; then echo "$(YELLOW)⚠️  Uso: make seal PROJECT=<p> [ENV=<e>]$(RESET)"; exit 1; fi
	@./scripts/seal-secrets.sh $(PROJECT) $(ENV)

data: ## Instala/atualiza o operador do Postgres (CloudNativePG), o backup e o storage S3 (cluster existente)
	@./scripts/setup-data.sh

CLOUD ?= digitalocean
cloud-check: ## Terraform da nuvem: fmt, validate, tflint e trivy (sem credenciais). Uso: make cloud-check [CLOUD=digitalocean]
	@./scripts/terraform.sh check $(CLOUD)

cloud: ## Terraform da nuvem (cria recursos PAGOS). Uso: make cloud TF="init|plan|apply|output" [CLOUD=digitalocean]
	@if [ -z "$(TF)" ]; then echo "$(YELLOW)⚠️  Uso: make cloud TF=plan [CLOUD=digitalocean] (docs/23-nuvem.md)$(RESET)"; exit 1; fi
	@./scripts/terraform.sh tf $(CLOUD) $(TF)

cloud-backup-env: ## Liga os backups do cluster atual (nuvem) ao bucket do Terraform. Depois: make data
	@./scripts/cloud-backup-env.sh $(CLOUD)

tracing: ## Instala/atualiza o tracing: Tempo + OpenTelemetry Operator (cluster existente; depois make observability)
	@./scripts/setup-tracing.sh

postgres: ## Recria o Postgres VAZIO (apaga os dados; backups antigos ficam no S3). Uso: make postgres PROJECT=<p> ENV=<e>
	@if [ -z "$(PROJECT)" ] || [ -z "$(ENV)" ]; then \
		echo "$(YELLOW)⚠️  Uso: make postgres PROJECT=<p> ENV=develop$(RESET)"; exit 1; \
	fi
	@read -r -p "Apagar os dados de $(PROJECT)-$(ENV)? Digite o namespace: " a && [ "$$a" = "$(PROJECT)-$(ENV)" ] || { echo "Cancelado."; exit 1; }
	@bash -c 'source scripts/lib-project.sh; ./scripts/setup-postgres.sh --namespace $(PROJECT)-$(ENV) --reset --fresh \
		--extra-dbs "$$(project_db_extras $(PROJECT))" --instances "$$(project_db_instances $(PROJECT) $(ENV))" \
		--storage "$$(project_db_storage $(PROJECT))" --retention "$$(project_db_retention $(PROJECT))"'

db-status: ## Postgres de um projeto: instâncias, primário, backups e janela de restauração. Uso: make db-status PROJECT=<p> ENV=<e>
	@./scripts/db.sh status "$(PROJECT)" "$(ENV)"

db-backup: ## Backup base agora (além do diário). Uso: make db-backup PROJECT=<p> ENV=<e>
	@./scripts/db.sh backup "$(PROJECT)" "$(ENV)"

db-restore: ## RECRIA o banco a partir do backup. Uso: make db-restore PROJECT=<p> ENV=<e> [TIME="2026-10-26 14:30:00-03"]
	@./scripts/db.sh restore "$(PROJECT)" "$(ENV)" "$(TIME)" "$(FROM)"

db-restore-test: ## Testa o backup: restaura numa cópia, compara com o banco em uso e apaga. Uso: make db-restore-test PROJECT=<p> ENV=<e> [TIME=...] [KEEP=1]
	@./scripts/db.sh restore-test "$(PROJECT)" "$(ENV)" "$(TIME)"

db-psql: ## psql no primário. Uso: make db-psql PROJECT=<p> ENV=<e> [DB=<banco>]
	@./scripts/db.sh psql "$(PROJECT)" "$(ENV)" "$(DB)"

project-apply: ## Prepara UM projeto no cluster (deps, secrets) + /etc/hosts. Uso: make project-apply PROJECT=<p>
	@if [ -z "$(PROJECT)" ]; then echo "$(YELLOW)⚠️  Uso: make project-apply PROJECT=<nome>$(RESET)"; exit 1; fi
	@./scripts/apply-project.sh $(PROJECT)
	@./scripts/hosts.sh apply

doctor: ## Confere tokens, variáveis, GitHub e Docker antes do deploy (não altera nada)
	@./scripts/doctor.sh

github: ## Configura o GitHub dos apps (develop, deploy key, proteção da main). Uso: make github [PROJECT=<p>] [ARGS=--dry-run]
	@./scripts/github-bootstrap.sh $(ARGS) $(PROJECT)

hosts: ## Regrava o bloco da plataforma no /etc/hosts (sudo). Ver antes: ./scripts/hosts.sh show
	@./scripts/hosts.sh apply

observability: ## Instala/atualiza Prometheus/Alertmanager/Grafana, Loki, Alloy, alertas e dashboards (cluster existente)
	@./scripts/setup-observability.sh
	@./scripts/apply-platform.sh

gen-observability: ## Regenera regras de alerta e dashboards gerados em k8s/ (depois: make apply-argocd)
	@python3 scripts/dev/gen-prometheus-rules.py > k8s/prometheus-rules-apps.yaml
	@python3 scripts/dev/gen-dashboard-slo.py > k8s/grafana-dashboard-slo.yaml
	@python3 scripts/dev/gen-grafana.py >/dev/null
	@echo "$(GREEN)✅ regras e dashboards gerados em k8s/$(RESET)"

alerts: ## Alertas ativos no Alertmanager (silenciados/inibidos marcados)
	@kubectl get --raw '/api/v1/namespaces/monitoring/services/kube-prometheus-stack-alertmanager:9093/proxy/api/v2/alerts' \
		| jq -r '(["ESTADO","SEVERIDADE","ALERTA","PROJETO/ENV","APP","RESUMO"] | @tsv), \
			(sort_by(.labels.severity) | .[] | select(.labels.alertname | IN("Watchdog", "InfoInhibitor") | not) \
			| [.status.state, .labels.severity, .labels.alertname, \
			   ((.labels.project // "-") + "/" + (.labels.env // "-")), (.labels.app // "-"), \
			   (.annotations.summary // .annotations.description // "" | .[0:80])] | @tsv)' \
		| column -t -s $$'\t'

apply-argocd: ## (Re)aplica a plataforma genérica: argocd/ + k8s/
	@./scripts/apply-platform.sh

render-platform: ## Mostra argocd/ + k8s/ renderizados (sem aplicar)
	@./scripts/apply-platform.sh --render

helm-lint: ## Valida charts/app (cada values-<env>.yaml) e charts/argocd-project (cada project.yaml)
	@for f in projects/*/project.yaml; do \
		proj=$$(basename $$(dirname $$f)); \
		echo "$(BLUE)→ helm lint argocd-project/$$proj$(RESET)"; \
		helm lint charts/argocd-project --quiet -f $$f \
			--set project.name=$$proj,infraRepoUrl=https://example.invalid/infra.git || exit 1; \
	done
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

# --- Laboratório de treino (docs/11-treino-quebre-e-conserte.md) ------------
LAB_NS := treino

lab-up: ## Treino: instala/restaura o app demo no namespace treino (fora do ArgoCD)
	@kubectl create namespace $(LAB_NS) --dry-run=client -o yaml | kubectl apply -f - >/dev/null
	@# O treino fica FORA das políticas de projeto (exercícios 17 e 18 ligam de propósito).
	@kubectl label namespace $(LAB_NS) devops-platform/project- pod-security.kubernetes.io/enforce- >/dev/null 2>&1 || true
	@kubectl delete networkpolicy --all -n $(LAB_NS) --ignore-not-found >/dev/null
	@kubectl -n $(LAB_NS) create secret generic demo-config --from-literal=GREETING=ola \
		--dry-run=client -o yaml | kubectl apply -f - >/dev/null
	@# --force-conflicts: o Helm 4 usa server-side apply e recusa sobrescrever campos
	@# que o `kubectl patch/set` "tomou para si". No lab queremos sempre restaurar.
	@helm upgrade --install demo charts/app -n $(LAB_NS) -f docs/labs/demo-values.yaml \
		--set app.name=demo,app.environment=treino,app.project=lab \
		--force-conflicts --wait --timeout 3m >/dev/null
	@echo "$(GREEN)✅ demo no ar:$(RESET) curl --resolve demo.treino.local:80:127.0.0.1 http://demo.treino.local"

lab-canary: ## Treino: o demo vira um Rollout canary (passos de 1 min) — exercício 19
	@$(MAKE) --no-print-directory lab-up >/dev/null
	@helm upgrade demo charts/app -n $(LAB_NS) -f docs/labs/demo-values.yaml -f docs/labs/demo-canary-values.yaml \
		--set app.name=demo,app.environment=treino,app.project=lab \
		--force-conflicts --wait --timeout 3m >/dev/null
	@kubectl wait rollout/demo -n $(LAB_NS) --for=jsonpath='{.status.phase}'=Healthy --timeout=180s >/dev/null
	@echo "$(GREEN)✅ demo é um Rollout:$(RESET) make rollouts | https://rollouts.devops.local"

lab-status: ## Treino: pods, eventos e resposta HTTP do app demo
	@kubectl get deploy,pods,svc,endpoints,ingress -n $(LAB_NS) 2>/dev/null
	@echo; kubectl get events -n $(LAB_NS) --sort-by=.lastTimestamp 2>/dev/null | tail -6
	@echo; printf "HTTP: "; curl -s -o /dev/null -w "%{http_code}\n" --max-time 5 \
		--resolve demo.treino.local:80:127.0.0.1 http://demo.treino.local/ || true

lab-down: ## Treino: remove o laboratório (namespace treino)
	@kubectl delete namespace $(LAB_NS) --ignore-not-found --wait=false
	@echo "$(YELLOW)namespace $(LAB_NS) removido$(RESET)"

k9s: ## Abre k9s
	@k9s
grafana: ## Abre o Grafana no browser
	@open http://grafana.devops.local
prometheus: ## Abre o Prometheus no browser
	@open http://prometheus.devops.local
alertmanager: ## Abre o Alertmanager no browser
	@open http://alertmanager.devops.local
argocd: ## Abre o ArgoCD no browser
	@open http://argocd.devops.local

.DEFAULT_GOAL := help
