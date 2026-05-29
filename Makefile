# Makefile — тонкая обёртка над helm-командами для стенда OpenWebUI → LiteLLM → Ollama.
# Предполагается, что KUBECONFIG указывает на кластер TimeWeb и helm/kubectl установлены.
#
#   make repos          # добавить helm-репозитории
#   make deploy-all     # развернуть весь стек снизу вверх
#   make ips            # внешние IP LoadBalancer-сервисов
#   make loadtest       # прогнать k6 (нужен внешний IP LiteLLM)
#   make teardown       # снести всё (включая LoadBalancer'ы — они тарифицируются)

NS        ?= llm-stand
MON_NS    ?= monitoring
API_KEY   ?= sk-stand-1234

.PHONY: repos namespace deploy-ollama deploy-litellm deploy-openwebui deploy-monitoring \
        deploy-all ips loadtest teardown

repos:
	helm repo add otwld https://helm.otwld.com/
	helm repo add open-webui https://helm.openwebui.com/
	helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
	helm repo update

namespace:
	kubectl create namespace $(NS) --dry-run=client -o yaml | kubectl apply -f -

deploy-ollama: namespace
	helm upgrade --install ollama otwld/ollama \
		-n $(NS) -f helm/ollama-values.yaml --wait --timeout 15m

deploy-litellm: namespace
	helm upgrade --install litellm oci://ghcr.io/berriai/litellm-helm \
		-n $(NS) -f helm/litellm-values.yaml --wait --timeout 10m

deploy-openwebui: namespace
	helm upgrade --install openwebui open-webui/open-webui \
		-n $(NS) -f helm/openwebui-values.yaml --wait --timeout 10m

deploy-monitoring:
	helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
		-n $(MON_NS) --create-namespace -f helm/kube-prometheus-values.yaml --wait --timeout 10m

# Снизу вверх: сначала инференс, потом прокси, потом UI, затем мониторинг.
deploy-all: repos deploy-ollama deploy-litellm deploy-openwebui deploy-monitoring
	@echo "Готово. Внешние адреса:" && $(MAKE) ips

ips:
	@echo "== LiteLLM (k6 target) =="
	@kubectl get svc litellm -n $(NS) -o wide 2>/dev/null || true
	@echo "== OpenWebUI (UI) =="
	@kubectl get svc openwebui -n $(NS) -o wide 2>/dev/null || true
	@echo "== Grafana =="
	@kubectl get svc monitoring-grafana -n $(MON_NS) -o wide 2>/dev/null || true

# BASE_URL передавать так:  make loadtest BASE_URL=http://<LITELLM_LB_IP>:4000
loadtest:
	k6 run -e BASE_URL=$(BASE_URL) -e API_KEY=$(API_KEY) loadtest/load.js

teardown:
	-helm uninstall openwebui -n $(NS)
	-helm uninstall litellm -n $(NS)
	-helm uninstall ollama -n $(NS)
	-helm uninstall monitoring -n $(MON_NS)
	-kubectl delete namespace $(NS)
	-kubectl delete namespace $(MON_NS)
	@echo "Проверьте, что LoadBalancer'ы удалены (тарифицируются поштучно):"
	@echo "  kubectl get svc -A | grep LoadBalancer"

# --- Бесплатный fallback вместо LoadBalancer (port-forward) ---
# pf-openwebui:
#	kubectl port-forward -n $(NS) svc/openwebui 8080:80
# pf-litellm:
#	kubectl port-forward -n $(NS) svc/litellm 4000:4000
# pf-grafana:
#	kubectl port-forward -n $(MON_NS) svc/monitoring-grafana 3000:80
