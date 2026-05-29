# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Что это

Воспроизводимый стенд в managed Kubernetes (TimeWeb Cloud): тракт **OpenWebUI → LiteLLM → Ollama**
с двумя on-prem моделями (`qwen2.5:0.5b`, `llama3.2:1b`) на CPU, плюс observability
(kube-prometheus-stack) и нагрузочный тест (k6). Это **не приложение с исходниками** —
репозиторий содержит только конфигурацию деплоя: `values` для готовых upstream Helm-чартов,
k6-скрипт и README. Своих Helm-шаблонов/манифестов здесь нет и не должно быть — кастомизация
идёт исключительно через `helm/*-values.yaml`.

## Команды

Требуются `kubectl`, `helm` (v3.8+, для OCI-чартов), `k6`; `KUBECONFIG` указывает на кластер.

```bash
make repos          # helm repo add + update (otwld, open-webui, prometheus-community)
make deploy-all     # развернуть весь стек снизу вверх (ollama→litellm→openwebui→monitoring)
make deploy-ollama  # отдельный слой (deploy-litellm / deploy-openwebui / deploy-monitoring)
make ips            # внешние IP LoadBalancer-сервисов
make loadtest BASE_URL=http://<LITELLM_LB_IP>:4000   # прогон k6
make teardown       # снести релизы и namespace
```

Переменные Makefile: `NS=llm-stand`, `MON_NS=monitoring`, `API_KEY=sk-stand-1234`.

Запуск k6 напрямую (минуя Makefile):
```bash
k6 run -e BASE_URL=http://<LITELLM_LB_IP>:4000 -e API_KEY=sk-stand-1234 loadtest/load.js
```

Локальная проверка артефактов без кластера:
```bash
python3 -c "import yaml; list(yaml.safe_load_all(open('helm/litellm-values.yaml')))"  # YAML
node --check loadtest/load.js                                                          # k6-скрипт
```

## Архитектура и неочевидные связи

Слои деплоятся **строго снизу вверх** (так задумано: отладка остаётся локальной для слоя):
Ollama → LiteLLM → OpenWebUI → monitoring. Это отражено в порядке зависимостей `make deploy-all`.

Сцепка значений, которую легко сломать при правках — **три места должны быть согласованы**:

- **Имена моделей**: список в `helm/ollama-values.yaml` (`ollama.models.pull`) ↔ `model_name`
  в `helm/litellm-values.yaml` (`proxy_config.model_list`) ↔ массив `MODELS` в `loadtest/load.js`.
  OpenWebUI сам ничего не хардкодит — он берёт модели из `GET /v1/models` у LiteLLM, поэтому
  достаточно, чтобы LiteLLM их объявил.
- **api_base в LiteLLM** (`http://ollama:11434`) — это DNS-имя Service Ollama в том же namespace.
  Модели объявлены с префиксом `ollama_chat/` — корректный chat-эндпоинт для `/v1/chat/completions`.
- **masterkey** `sk-stand-1234` повторяется в трёх местах: `litellm-values.yaml` (`masterkey`),
  `openwebui-values.yaml` (`openaiApiKeys`), и как `API_KEY` для k6. Меняешь — меняй везде.
  OpenWebUI ходит в LiteLLM по `openaiBaseApiUrls: http://litellm:4000/v1`.

Две намеренные «ловушки», уже обойдённые в values (не откатывать без причины):

- **LiteLLM без Postgres**: официальный chart по умолчанию поднимает standalone Bitnami Postgres.
  Стенду БД не нужна — в `litellm-values.yaml` стоит `db.deployStandalone: false`,
  `db.useExisting: false` и не-`database` образ `ghcr.io/berriai/litellm`.
- **OpenWebUI без встроенного Ollama**: чарт OpenWebUI тащит свои сабчарты Ollama и Pipelines.
  Оба выключены (`ollama.enabled: false`, `pipelines.enabled: false`) — ходим только через LiteLLM.

## Конвенции стенда

- **Доступ — через `LoadBalancer`** (TimeWeb тарифицирует каждый LB). port-forward оставлен
  закомментированным fallback'ом в `Makefile`. При teardown проверять, что LB удалены:
  `kubectl get svc -A | grep LoadBalancer`.
- **StorageClass** в values оставлен пустым (`""`) => default TimeWeb CSI. Если в кластере нет
  default-класса, задавать `storageClass`/`storageClassName` явно (в файлах есть комментарии где).
- **Persistence** включена для Ollama (модели), Prometheus (метрики), Grafana (дашборды) —
  переживает рестарт пода. При полном удалении кластера тома могут уйти вместе с ним.
- **k6 бьёт напрямую в LiteLLM**, а не через OpenWebUI — это узкое место тракта (CPU-инференс).
  `handleSummary` пишет результат в `docs/k6-summary.txt` автоматически.
- README ведётся **инкрементально** как итог реальных команд — при изменении деплоя обновлять
  соответствующие шаги.
