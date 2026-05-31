# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Что это

Воспроизводимый стенд в managed Kubernetes (TimeWeb Cloud): тракт **OpenWebUI → LiteLLM → Ollama**
с двумя on-prem моделями (`qwen2.5:0.5b`, `llama3.2:1b`) на CPU, плюс observability
(kube-prometheus-stack) и нагрузочный тест (k6). Снаружи всё закрыто **одним** LoadBalancer
(ingress-nginx) с host-роутингом и автоматическим TLS Let's Encrypt (cert-manager). Это
**не приложение с исходниками** — репозиторий содержит только конфигурацию деплоя: `values`
для готовых upstream Helm-чартов, k6-скрипт и README. Кастомизация идёт через `helm/*-values.yaml`;
единственное исключение — `manifests/cluster-issuer.yaml` (CRD cert-manager, у которого нет
chart-эквивалента).

## Команды

Требуются `kubectl`, `helm` (v3.8+, для OCI-чартов), `k6`; `KUBECONFIG` указывает на кластер.

```bash
make repos            # helm repo add + update (otwld, open-webui, prometheus-community, ingress-nginx, jetstack)
make deploy-platform  # ingress-nginx (единственный LB) + cert-manager + ClusterIssuer — ДО приложений
make deploy-all       # платформа → стек снизу вверх (ollama→litellm→openwebui→monitoring)
make deploy-ollama    # отдельный слой (deploy-litellm / deploy-openwebui / deploy-monitoring)
make ips              # внешний IP единственного LoadBalancer (цель wildcard DNS)
make urls             # публичные HTTPS-адреса chat./grafana./llm.raft.rootcrops.tech
make certs            # статус выпуска TLS-сертификатов (READY=True)
make loadtest BASE_URL=https://llm.raft.rootcrops.tech   # прогон k6
make teardown         # снести релизы, платформу и namespace
```

Переменные Makefile: `NS=llm-stand`, `MON_NS=monitoring`, `ING_NS=ingress-nginx`,
`CM_NS=cert-manager`, `API_KEY=sk-stand-1234`.

Запуск k6 напрямую (минуя Makefile):
```bash
k6 run -e BASE_URL=https://llm.raft.rootcrops.tech -e API_KEY=sk-stand-1234 loadtest/load.js
```

Локальная проверка артефактов без кластера:
```bash
python3 -c "import yaml; list(yaml.safe_load_all(open('helm/litellm-values.yaml')))"  # YAML
node --check loadtest/load.js                                                          # k6-скрипт
```

## Архитектура и неочевидные связи

Слои деплоятся **строго снизу вверх** (так задумано: отладка остаётся локальной для слоя):
платформа (ingress-nginx + cert-manager) → Ollama → LiteLLM → OpenWebUI → monitoring.
Это отражено в порядке зависимостей `make deploy-all`.

**Сетевой вход — один LoadBalancer.** Раньше каждый из трёх сервисов (litellm/openwebui/grafana)
просил свой LB и упирался в квоту TimeWeb. Теперь сервисы — `ClusterIP`, а наружу торчит только
ingress-nginx (один LB). Три Ingress'а создаются **из values самих чартов** (`ingress.*` у
open-webui/litellm, `grafana.ingress.*` у kube-prometheus-stack) — конвенция «только values»
сохранена. Хосты: `chat.` (OpenWebUI), `grafana.`, `llm.` (LiteLLM API/k6) под
`*.raft.rootcrops.tech`. **Критичный порядок:** платформа → завести wildcard DNS на IP её LB
(`make ips`) → приложения. HTTP-01 не выпустит сертификат, пока хост не резолвится в этот IP,
а фронтенд LB TimeWeb должен быть открыт снаружи на :80/:443 (иначе challenge зависнет).
TLS-секреты (`chat-raft-tls`/`grafana-raft-tls`/`llm-raft-tls`) создаёт cert-manager сам по
annotation `cert-manager.io/cluster-issuer: letsencrypt-prod`. На litellm/openwebui стоят
аннотации `proxy-read/send-timeout: 300` — CPU-инференс доходит до ~65 с, дефолтные 60 с дают 504.

Сцепка значений, которую легко сломать при правках — **три места должны быть согласованы**:

- **Имена моделей**: список в `helm/ollama-values.yaml` (`ollama.models.pull`) ↔ `model_name`
  в `helm/litellm-values.yaml` (`proxy_config.model_list`) ↔ массив `MODELS` в `loadtest/load.js`.
  OpenWebUI сам ничего не хардкодит — он берёт модели из `GET /v1/models` у LiteLLM, поэтому
  достаточно, чтобы LiteLLM их объявил.
- **api_base в LiteLLM** (`http://ollama:11434`) — это DNS-имя Service Ollama в том же namespace.
  Модели объявлены с префиксом `ollama_chat/` — корректный chat-эндпоинт для `/v1/chat/completions`.
- **masterkey** вынесен из values в `helm/secrets.local.yaml` (gitignored; шаблон —
  `helm/secrets.example.yaml`). Один файл держит три согласованных значения: `masterkey`
  (LiteLLM), `openaiApiKeys` (OpenWebUI), `grafana.adminPassword`. Makefile передаёт его
  вторым `-f` в `deploy-litellm/openwebui/monitoring` (last wins). Для k6 то же значение —
  `API_KEY` в Makefile/`-e`. Меняешь ключ — меняй в `secrets.local.yaml` и `API_KEY`.
  OpenWebUI ходит в LiteLLM по `openaiBaseApiUrls: http://litellm:4000/v1`.
  Без `secrets.local.yaml` (`cp` из example) релизы поднимутся, но без masterkey/пароля Grafana.

Две намеренные «ловушки», уже обойдённые в values (не откатывать без причины):

- **LiteLLM без Postgres**: официальный chart по умолчанию поднимает standalone Bitnami Postgres.
  Стенду БД не нужна — в `litellm-values.yaml` стоит `db.deployStandalone: false`,
  `db.useExisting: false` и не-`database` образ `ghcr.io/berriai/litellm`.
- **OpenWebUI без встроенного Ollama**: чарт OpenWebUI тащит свои сабчарты Ollama и Pipelines.
  Оба выключены (`ollama.enabled: false`, `pipelines.enabled: false`) — ходим только через LiteLLM.

## Конвенции стенда

- **Доступ — через один ingress-nginx LoadBalancer** (TimeWeb тарифицирует каждый LB, поэтому
  держим ровно один). Сервисы приложений — `ClusterIP`. port-forward оставлен закомментированным
  fallback'ом в `Makefile`. При teardown проверять, что LB удалён: `kubectl get svc -A | grep LoadBalancer`.
- **Три узких исключения из «кастомизация только через values»:**
  1. `manifests/cluster-issuer.yaml` (ClusterIssuer LE, HTTP-01) — у CRD cert-manager нет
     chart-эквивалента. Makefile применяет его `kubectl apply` в `deploy-cert-manager`.
  2. **Дашборд `dashboards/llm-stand.json` грузится ConfigMap'ом**, а не через values. `deploy-monitoring`
     создаёт из JSON-файла ConfigMap с меткой `grafana_dashboard=1` (`kubectl create cm --from-file …
     | kubectl label --local … | kubectl apply`), который sidecar Grafana (env `LABEL=grafana_dashboard`,
     `NAMESPACE=ALL`) автоимпортит. Так JSON остаётся единственным источником правды и редактируемым
     файлом — values-чарта не умеет ссылаться на внешний файл, а инлайнить большой JSON в values грязно.
     В дашборде datasource задан как template-переменная `${datasource}` (тип datasource) → подхватывает
     дефолтный Prometheus (uid `prometheus`). `teardown` удаляет этот ConfigMap.
  3. `manifests/litellm-servicemonitor.yaml` — ServiceMonitor на `/metrics` LiteLLM. serviceMonitor
     чарта litellm-helm не умеет задать ни `path: /metrics/` (эндпоинт смонтирован со слешем; `/metrics`
     даёт 307), ни Bearer-авторизацию (метрики за master-key — 401 без ключа). Поэтому свой манифест:
     `authorization.credentials` берёт токен из секрета `litellm-masterkey` (его читает prometheus-operator,
     RBAC `secrets:*`, и подставляет в конфиг — самому Prometheus доступ к секретам в llm-stand не нужен).
     Применяется в `deploy-litellm`, удаляется в `teardown`.

- **Наблюдаемость — три уровня** (всё на дашборде LLM Stand): ресурсы подов (cAdvisor/kube-state),
  HTTP-метрики ingress-nginx по host'у `llm.` (`controller.metrics`+ServiceMonitor, RPS/латентность/коды),
  app-метрики LiteLLM (`litellm_settings.callbacks: ["prometheus"]` → `/metrics`, запросы/токены/латентность
  по моделям). Prometheus kube-prometheus-stack скрейпит ServiceMonitor'ы с меткой `release: monitoring`.
  В образе `main-stable` метрики LiteLLM доступны без enterprise-лицензии (проверено).
- **StorageClass** в values оставлен пустым (`""`) => default TimeWeb CSI. Если в кластере нет
  default-класса, задавать `storageClass`/`storageClassName` явно (в файлах есть комментарии где).
- **Persistence** включена для Ollama (модели), Prometheus (метрики), Grafana (дашборды) —
  переживает рестарт пода. При полном удалении кластера тома могут уйти вместе с ним.
- **k6 бьёт напрямую в LiteLLM** (`https://llm.raft.rootcrops.tech` через ingress), а не через
  OpenWebUI — это узкое место тракта (CPU-инференс). `handleSummary` пишет результат в
  `docs/k6-summary.txt` автоматически.
- README ведётся **инкрементально** как итог реальных команд — при изменении деплоя обновлять
  соответствующие шаги.
