# Makefile — тонкая обёртка над helm-командами для стенда OpenWebUI → LiteLLM → Ollama.
# Предполагается, что KUBECONFIG указывает на кластер TimeWeb и helm/kubectl установлены.
#
# Перед deploy создайте файл с секретами (он gitignored):
#   cp helm/secrets.example.yaml helm/secrets.local.yaml
#
#   make repos          # добавить helm-репозитории
#   make deploy-all     # развернуть весь стек снизу вверх
#   make ips            # внешние IP LoadBalancer-сервисов
#   make loadtest       # прогнать k6 (нужен внешний IP LiteLLM)
#   make teardown       # снести всё (включая LoadBalancer'ы — они тарифицируются)

NS        ?= llm-stand
MON_NS    ?= monitoring
ING_NS    ?= ingress-nginx
CM_NS     ?= cert-manager
# Должен совпадать с masterkey из helm/secrets.local.yaml.
API_KEY   ?= sk-stand-1234

.PHONY: repos namespace deploy-ingress deploy-cert-manager deploy-platform \
        deploy-ollama deploy-litellm deploy-openwebui deploy-monitoring \
        deploy-all ips urls certs loadtest teardown

repos:
	helm repo add otwld https://helm.otwld.com/
	helm repo add open-webui https://helm.openwebui.com/
	helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
	helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
	helm repo add jetstack https://charts.jetstack.io
	helm repo update

namespace:
	kubectl create namespace $(NS) --dry-run=client -o yaml | kubectl apply -f -

# --- Платформа: один LoadBalancer (ingress-nginx) + автоматический TLS (cert-manager) ---
# Ставим ДО приложений: их ingress'ы и выпуск сертификатов опираются на эти компоненты.
deploy-ingress:
	helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
		-n $(ING_NS) --create-namespace -f helm/ingress-nginx-values.yaml --wait --timeout 10m

deploy-cert-manager:
	helm upgrade --install cert-manager jetstack/cert-manager \
		-n $(CM_NS) --create-namespace -f helm/cert-manager-values.yaml --wait --timeout 10m
	kubectl apply -f manifests/cluster-issuer.yaml

deploy-platform: deploy-ingress deploy-cert-manager
	@echo "Платформа готова. Внешний IP единственного LoadBalancer:" && $(MAKE) ips

deploy-ollama: namespace
	helm upgrade --install ollama otwld/ollama \
		-n $(NS) -f helm/ollama-values.yaml --wait --timeout 15m

deploy-litellm: namespace
	helm upgrade --install litellm oci://ghcr.io/berriai/litellm-helm \
		-n $(NS) -f helm/litellm-values.yaml -f helm/secrets.local.yaml --wait --timeout 10m

deploy-openwebui: namespace
	helm upgrade --install openwebui open-webui/open-webui \
		-n $(NS) -f helm/openwebui-values.yaml -f helm/secrets.local.yaml --wait --timeout 10m

deploy-monitoring:
	helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
		-n $(MON_NS) --create-namespace -f helm/kube-prometheus-values.yaml -f helm/secrets.local.yaml --wait --timeout 10m
	@echo "== Загружаем дашборд стенда как код (sidecar Grafana подхватит ConfigMap с меткой grafana_dashboard=1) =="
	kubectl create configmap llm-stand-dashboard --from-file=dashboards/llm-stand.json \
		-n $(MON_NS) --dry-run=client -o yaml \
		| kubectl label --local -f - grafana_dashboard=1 -o yaml \
		| kubectl apply -f -

# Снизу вверх: сначала платформа (ingress+TLS), потом инференс, прокси, UI, мониторинг.
# ВАЖНО: между deploy-platform и приложениями заведите wildcard DNS *.raft.rootcrops.tech
# на внешний IP из `make ips` — иначе HTTP-01 не выпустит сертификаты.
deploy-all: repos deploy-platform deploy-ollama deploy-litellm deploy-openwebui deploy-monitoring
	@echo "Готово." && $(MAKE) urls

# Единственный внешний IP кластера — у LoadBalancer ingress-nginx.
# Его значение и заводится как A-запись *.raft.rootcrops.tech.
ips:
	@echo "== ingress-nginx (ЕДИНСТВЕННЫЙ LoadBalancer; его IP → *.raft.rootcrops.tech) =="
	@kubectl get svc ingress-nginx-controller -n $(ING_NS) -o wide 2>/dev/null || true
	@echo "== Прочие LoadBalancer'ы (должно быть пусто, кроме ingress-nginx) =="
	@kubectl get svc -A 2>/dev/null | grep LoadBalancer || true

# Публичные HTTPS-адреса сервисов за ingress.
urls:
	@echo "OpenWebUI : https://chat.raft.rootcrops.tech"
	@echo "Grafana   : https://grafana.raft.rootcrops.tech   (admin / пароль из secrets.local.yaml)"
	@echo "LiteLLM   : https://llm.raft.rootcrops.tech/v1/models   (Bearer $(API_KEY))"

# Статус выпуска TLS-сертификатов (READY=True — cert-manager прошёл HTTP-01).
certs:
	@kubectl get certificate -A 2>/dev/null || true

# BASE_URL передавать так:  make loadtest BASE_URL=https://llm.raft.rootcrops.tech
loadtest:
	k6 run -e BASE_URL=$(BASE_URL) -e API_KEY=$(API_KEY) loadtest/load.js

teardown:
	-helm uninstall openwebui -n $(NS)
	-helm uninstall litellm -n $(NS)
	-helm uninstall ollama -n $(NS)
	-kubectl delete configmap llm-stand-dashboard -n $(MON_NS)
	-helm uninstall monitoring -n $(MON_NS)
	-kubectl delete -f manifests/cluster-issuer.yaml
	-helm uninstall cert-manager -n $(CM_NS)
	-helm uninstall ingress-nginx -n $(ING_NS)
	-kubectl delete namespace $(NS)
	-kubectl delete namespace $(MON_NS)
	-kubectl delete namespace $(CM_NS)
	-kubectl delete namespace $(ING_NS)
	@echo "Проверьте, что LoadBalancer удалён (тарифицируется):"
	@echo "  kubectl get svc -A | grep LoadBalancer"

# --- Бесплатный fallback вместо ingress/LoadBalancer (port-forward) ---
# pf-openwebui:
#	kubectl port-forward -n $(NS) svc/openwebui 8080:80
# pf-litellm:
#	kubectl port-forward -n $(NS) svc/litellm 4000:4000
# pf-grafana:
#	kubectl port-forward -n $(MON_NS) svc/monitoring-grafana 3000:80
