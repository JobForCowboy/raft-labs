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
│   ├── kube-prometheus-values.yaml
│   ├── secrets.example.yaml       # шаблон секретов (в гите)
│   └── secrets.local.yaml         # реальные секреты — gitignored, создаётся через cp
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

Сначала создайте файл с секретами (он в `.gitignore`, в репозиторий не попадает):

```bash
cp helm/secrets.example.yaml helm/secrets.local.yaml   # при желании поменяйте значения
```

`secrets.local.yaml` держит `masterkey` (LiteLLM), `openaiApiKeys` (OpenWebUI) и
`grafana.adminPassword`; Makefile передаёт его вторым `-f` в соответствующие релизы.

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

Реальный прогон на кластере TimeWeb (2 узла `2 vCPU / 4 ГБ`, СПб), k6 бил в LiteLLM,
обе модели поочерёдно, `max_tokens=32`. Полный вывод — в `docs/k6-summary.txt`.

| Метрика | Значение |
|---|---|
| Профиль нагрузки | VU `1 → 5 → 10 → 20`, ~5.5 мин |
| Запросов всего | 157 (обе модели) |
| **Ошибок** | **0%** (`http_req_failed` 0/157, проверок 314/314 ✓) |
| **Throughput** | **0.50 req/s** |
| Latency p50 | 7.75 с |
| Latency p90 / p95 | 45.6 с / 58.1 с |
| Latency min / max | 0.81 с / 65 с |
| Пороги | ✓ `chat_latency_ms p95<60s`, ✓ `http_req_failed<20%` |

**Интерпретация.** Бутылочное горлышко — CPU-инференс Ollama: на одном свободном VU
ответ ~0.8 с, но при росте до 20 VU latency p95 поднимается до ~58 с при **нулевых ошибках**
и throughput ~0.5 req/s. Запросы не падают, а выстраиваются в очередь к CPU — низкая
пропускная способность и рост задержек под нагрузкой это ожидаемый и валидный результат
для on-prem моделей на CPU без GPU.

**Скриншоты** (`docs/screenshots/`, снимаются вручную из браузера): обе модели в выпадашке
OpenWebUI, рабочий чат, Grafana (CPU/RAM подов Ollama) на пике нагрузки.

> Прогон сделан против внешнего эндпоинта LiteLLM. Если LoadBalancer-фронтенд недоступен
> с твоего адреса (TimeWeb может фильтровать вход по IP), бей в NodePort:
> `make loadtest BASE_URL=http://<EXTERNAL_NODE_IP>:<litellm_nodePort>` — путь к LiteLLM тот же.

---

## Особенности TimeWeb (по реальному деплою)

Эти грабли уже учтены в репозитории — список на случай воспроизведения на другом кластере:

- **CSI / StorageClass.** В managed-кластере TimeWeb **нет default StorageClass** и CSI «из
  коробки». Поставьте драйвер: панель → **Дополнения → CSI-driver → Установить** (кластер
  должен быть в СПб для сетевых дисков). Появятся классы `nvme/hdd.network-drives.csi.timeweb.cloud`.
  В values класс задан **явно** (`nvme...`), т.к. default-класса нет.
- **Доступ к kube API.** API-сервер может фильтровать подключения по IP — добавьте свой адрес
  в разрешённые в панели, иначе `kubectl` виснет на TLS handshake (хост при этом пингуется).
- **Квота LoadBalancer.** Дизайн использует 3 LB (LiteLLM, OpenWebUI, Grafana). Если 2-й/3-й
  LB не создаются (`SyncLoadBalancerFailed` в `kubectl describe svc`), поднимите квоту LB в панели.
  Сам LB-фронтенд тоже может быть закрыт для внешних IP (изнутри кластера отвечает 200) —
  тогда внешний доступ через NodePort на публичном IP узла.
- **Ресурсы LiteLLM.** Прокси OOMKilled при 512Mi/1Gi (gunicorn × воркеры) — в values стоит
  лимит **2Gi**.
- **Первый старт Ollama медленный.** Образ `ollama/ollama` ~4 ГБ + первичное создание сетевого
  диска → первый rollout может упереться в Deployment progress deadline (helm `--wait` отвалится
  по `Progress deadline exceeded`). Под при этом доезжает сам — повторите `make deploy-ollama`
  (образ уже в кэше, диск создан), релиз станет `deployed`.

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
