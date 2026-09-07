# Kestra worker auto-scaling example
# Thin wrapper over scripts/. Requires a filled-in .env (see .env.example / SETUP.md).

SHELL := /bin/bash
.DEFAULT_GOAL := help

.PHONY: help up down flow app app-down scaler scaler-down status metrics logs

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

up: ## Full bring-up: kind + Helm + flow + trigger app; prints URLs
	./scripts/up.sh

down: ## Tear everything down (cluster, app, scaler, port-forward)
	./scripts/down.sh

flow: ## (Re)import flows/webhook_sleep.yaml and smoke-test the webhook
	./scripts/import-flow.sh

app: ## Build + start the trigger app container
	docker compose -f app/docker-compose.yml --env-file .env up -d --build

app-down: ## Stop the trigger app
	docker compose -f app/docker-compose.yml down -v

scaler: ## Build, load, and deploy the Workstream 1 scaler
	./scripts/deploy-scaler.sh

scaler-down: ## Remove the Workstream 1 scaler + RBAC
	kubectl delete -f workstream-1-prometheus-worker-scaling/k8s/ \
	  -n $$(grep -E '^K8S_NAMESPACE=' .env | cut -d= -f2) --ignore-not-found

status: ## Show URLs + cluster workloads
	./scripts/urls.sh
	@echo
	kubectl get deploy,pods -n $$(grep -E '^K8S_NAMESPACE=' .env | cut -d= -f2)

metrics: ## Curl :8081/prometheus and print the worker metrics
	./scripts/verify-metrics.sh

logs: ## Follow the scaler logs
	kubectl logs -f deploy/worker-scaler -n $$(grep -E '^K8S_NAMESPACE=' .env | cut -d= -f2)
