# LLM-стенд в Kubernetes: OpenWebUI → LiteLLM → Ollama

Тестовый стенд в managed Kubernetes (TimeWeb Cloud): OpenWebUI работает через LiteLLM Proxy
и показывает две **on-prem** модели, инференс которых крутится на CPU через Ollama.
Сверху — observability (Prometheus + Grafana) и нагрузочный тест (k6).

Стенд собран на **готовых upstream Helm-чартах**, кастомизированных своими `values` (каталог `helm/`).

---

## Архитектура

Рабочий тракт (запрос идёт слева направо, ответ — обратно):

```
                                          ┌─ qwen2.5:0.5b
[Browser] → OpenWebUI → LiteLLM → Ollama ─┤
                                          └─ llama3.2:1b
```

- **OpenWebUI** знает только LiteLLM и считает его OpenAI-совместимым API
  (`openaiBaseApiUrls: http://litellm:4000/v1`).
- Обе модели появляются в UI, потому что OpenWebUI запрашивает `GET /v1/models` у LiteLLM
  и рисует то, что объявлено в его `model_list`.
- **LiteLLM** — прокси/роутер: сопоставляет имя модели с бэкендом Ollama
  (`api_base: http://ollama:11434`) и переводит OpenAI-формат в формат Ollama.
- **Ollama** — один сервис, хостит обе модели, инференс на CPU.
- Связь между сервисами — внутренняя, по DNS-именам Kubernetes Service.

Observability смотрит на тракт сбоку:

```
k6          ──load──→   LiteLLM /v1/chat/completions
Prometheus  ──scrape──→ поды (cAdvisor/kubelet)
Grafana     ──query──→  Prometheus
```

### Стек и решения

| Аспект | Решение |
|---|---|
| Платформа | Managed Kubernetes на TimeWeb Cloud, 1 узел 8 ГБ / 4 vCPU |
| GPU | Не нужен — инференс на CPU |
| Модели | `qwen2.5:0.5b`, `llama3.2:1b` через Ollama |
| Доступ к UI/Grafana/LiteLLM | `LoadBalancer` Service (port-forward — fallback) |
| Persistence | PVC для Ollama, Prometheus, Grafana |
| Нагрузка | k6 |
| Observability | kube-prometheus-stack |

### Используемые чарты

| Компонент | Chart | Репозиторий |
|---|---|---|
| Ollama | `otwld/ollama` | `https://helm.otwld.com/` |
| OpenWebUI | `open-webui/open-webui` | `https://helm.openwebui.com/` |
| LiteLLM | `litellm-helm` | `oci://ghcr.io/berriai/litellm-helm` |
| Prometheus+Grafana | `prometheus-community/kube-prometheus-stack` | `https://prometheus-community.github.io/helm-charts` |

---

## Структура репозитория

```
.
├── README.md
├── Makefile                       # обёртка над helm-командами
├── helm/
│   ├── ollama-values.yaml
│   ├── litellm-values.yaml        # proxy_config с model_list на обе модели; Postgres отключён
│   ├── openwebui-values.yaml
│   └── kube-prometheus-values.yaml
├── loadtest/
│   └── load.js                    # k6: ramp 1→5→10→20, чередование моделей
├── docs/
│   ├── README.md
│   ├── screenshots/               # скриншоты UI и Grafana (вручную)
│   └── k6-summary.txt             # summary k6 (пишется автоматически)
└── dashboards/                    # (опц.) дашборды как код
```

---

## Предусловия

Локально нужны `kubectl`, `helm` (v3.8+, для OCI-чартов) и `k6`.

1. **Создать кластер** в панели TimeWeb Cloud: managed Kubernetes, 1 узел `8 ГБ RAM / 4 vCPU`.
2. Скачать kubeconfig и активировать:
   ```bash
   export KUBECONFIG=$PWD/kubeconfig
   kubectl get nodes          # узел должен быть Ready
   ```
3. Проверить default StorageClass (нужен для PVC):
   ```bash
   kubectl get storageclass
   ```
   Если default (помечен `(default)`) **отсутствует** — задайте `storageClass`/`storageClassName`
   явно в `helm/*-values.yaml` (в файлах есть комментарии где именно).

---

## Развёртывание

Снизу вверх — каждый слой проверяется до следующего.

```bash
make repos          # helm repo add + update
make deploy-ollama  # инференс + обе модели (первый старт долгий: тянет модели на PVC)
make deploy-litellm # прокси
make deploy-openwebui
make deploy-monitoring
# либо всё разом:
make deploy-all
```

Получить внешние адреса LoadBalancer:

```bash
make ips
```

### Проверка каждого слоя

**Ollama** (изнутри кластера — Service внутренний):
```bash
kubectl exec -n llm-stand deploy/ollama -- ollama list      # обе модели
kubectl exec -n llm-stand deploy/ollama -- \
  curl -s localhost:11434/api/tags
```

**LiteLLM** (по внешнему IP из `make ips`, порт 4000):
```bash
LITELLM=http://<LITELLM_LB_IP>:4000
curl -s $LITELLM/v1/models -H "Authorization: Bearer sk-stand-1234"      # две модели
curl -s $LITELLM/v1/chat/completions -H "Authorization: Bearer sk-stand-1234" \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen2.5:0.5b","messages":[{"role":"user","content":"hi"}]}'
```

**OpenWebUI**: открыть `http://<OPENWEBUI_LB_IP>` в браузере → в выпадашке моделей
должны быть **обе** модели → отправить сообщение и убедиться, что чат отвечает на каждой.
Скриншоты сложить в `docs/screenshots/` (см. `docs/README.md`).

> Бесплатный fallback вместо LoadBalancer — port-forward (раскомментированы в `Makefile`):
> `kubectl port-forward -n llm-stand svc/openwebui 8080:80` и т.п.

---

## Нагрузочный тест

```bash
make ips                          # узнать внешний IP LiteLLM
make loadtest BASE_URL=http://<LITELLM_LB_IP>:4000
# эквивалент:
# k6 run -e BASE_URL=http://<LITELLM_LB_IP>:4000 -e API_KEY=sk-stand-1234 loadtest/load.js
```

Профиль: ramp-up VU `1 → 5 → 10 → 20`, поочерёдно обе модели, короткий промпт.
Во время прогона смотреть Grafana (`http://<GRAFANA_LB_IP>`, логин `admin` / `admin-stand-1234`):
**Kubernetes / Compute Resources / Namespace (Pods)** → namespace `llm-stand`.

k6 по окончании сам пишет `docs/k6-summary.txt` (p50/p95/p99, RPS, error rate).

---

## Результаты

Заполняется после прогона:

- **Параметры теста**: VU 1→5→10→20, длительность ~5.5 мин, две модели, `max_tokens=32`.
- **Цифры из k6** (`docs/k6-summary.txt`): latency p50/p95/p99, RPS, error rate.
- **Скриншоты** (`docs/screenshots/`): обе модели в UI, рабочий чат, Grafana на пике.
- **Интерпретация**: бутылочное горлышко — почти наверняка CPU-инференс Ollama.
  Низкий throughput и рост latency под нагрузкой на CPU — ожидаемый и валидный результат.

---

## Persistence и жизненный цикл

- PVC для Ollama (модели), Prometheus (история метрик), Grafana (дашборды) переживают
  рестарт подов и остановку/запуск кластера.
- При **полном удалении** кластера TimeWeb тома могут удалиться вместе с ним —
  для долгого хранения проверьте reclaim policy StorageClass и поведение TimeWeb при удалении.

---

## Teardown

```bash
make teardown
```

Сносит релизы и namespace. **Важно:** убедитесь, что LoadBalancer-сервисы удалены —
каждый LB в TimeWeb тарифицируется:

```bash
kubectl get svc -A | grep LoadBalancer    # должно быть пусто
```

Затем при необходимости удалить сам кластер в панели TimeWeb.
