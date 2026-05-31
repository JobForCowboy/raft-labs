# LLM-стенд в Kubernetes: OpenWebUI → LiteLLM → Ollama

Тестовый стенд в managed Kubernetes (TimeWeb Cloud): OpenWebUI работает через LiteLLM Proxy
и показывает две **on-prem** модели, инференс которых крутится на CPU через Ollama.
Сверху — observability (Prometheus + Grafana) и нагрузочный тест (k6).

Стенд собран на **готовых upstream Helm-чартах**, кастомизированных своими `values` (каталог `helm/`).

---

## Архитектура

Рабочий тракт (запрос идёт слева направо, ответ — обратно):

```
                          ┌─ chat.   → OpenWebUI ┐
[Browser] →HTTPS→ ingress─┤  grafana.→ Grafana   │              ┌─ qwen2.5:0.5b
              (1×LB, TLS) └─ llm.    → LiteLLM ───┴→ Ollama ─────┤
                                                                 └─ llama3.2:1b
```

- Снаружи всё закрыто **одним** `LoadBalancer` (ingress-nginx). Он маршрутизирует по host'у
  на три сервиса (`chat.` / `grafana.` / `llm.raft.rootcrops.tech`), TLS-сертификаты
  Let's Encrypt выпускает **cert-manager** автоматически (HTTP-01). Сервисы приложений —
  внутренние (`ClusterIP`).
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
| Доступ к UI/Grafana/LiteLLM | Один `LoadBalancer` (ingress-nginx) → host-роутинг по HTTPS |
| TLS | Let's Encrypt через cert-manager (HTTP-01), автопродление |
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
| Ingress | `ingress-nginx/ingress-nginx` | `https://kubernetes.github.io/ingress-nginx` |
| TLS (cert-manager) | `jetstack/cert-manager` | `https://charts.jetstack.io` |

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
│   ├── ingress-nginx-values.yaml  # единственный LoadBalancer кластера
│   ├── cert-manager-values.yaml   # автоматический TLS Let's Encrypt
│   ├── secrets.example.yaml       # шаблон секретов (в гите)
│   └── secrets.local.yaml         # реальные секреты — gitignored, создаётся через cp
├── manifests/
│   ├── cluster-issuer.yaml        # ClusterIssuer LE (HTTP-01)
│   └── litellm-servicemonitor.yaml # ServiceMonitor на /metrics LiteLLM (Bearer-токен)
├── loadtest/
│   └── load.js                    # k6: ramp 1→5→10, стриминг, чередование моделей
├── docs/
│   ├── README.md
│   ├── screenshots/               # скриншоты UI и Grafana (вручную)
│   └── k6-summary.txt             # summary k6 (пишется автоматически)
└── dashboards/
    └── llm-stand.json             # Grafana-дашборд стенда как код (грузится ConfigMap'ом)
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

Порядок важен: **сначала платформа** (ingress-nginx + cert-manager), затем — DNS на её
внешний IP, и только потом приложения (HTTP-01 не выпустит сертификат, пока домен не
резолвится в IP балансировщика).

```bash
make repos            # helm repo add + update (вкл. ingress-nginx, jetstack)
make deploy-platform  # ingress-nginx (единственный LB) + cert-manager + ClusterIssuer
make ips              # внешний IP LoadBalancer ingress-nginx
```

**Заведите wildcard-запись DNS** `*.raft.rootcrops.tech` (A-запись) на полученный IP
(удобен короткий TTL ~300). Дождитесь резолва: `dig +short chat.raft.rootcrops.tech`.

Затем — приложения:

```bash
make deploy-ollama  # инференс + обе модели (первый старт долгий: тянет модели на PVC)
make deploy-litellm # прокси
make deploy-openwebui
make deploy-monitoring
# либо всё разом (платформа → приложения), но DNS всё равно завести между шагами:
make deploy-all
```

Адреса и статус TLS:

```bash
make ips     # внешний IP LoadBalancer (он же — цель wildcard DNS)
make urls    # публичные HTTPS-адреса chat./grafana./llm.
make certs   # статус выпуска сертификатов (READY=True — cert-manager прошёл HTTP-01)
```

### Проверка каждого слоя

**Ollama** (изнутри кластера — Service внутренний):
```bash
kubectl exec -n llm-stand deploy/ollama -- ollama list      # обе модели
kubectl exec -n llm-stand deploy/ollama -- \
  curl -s localhost:11434/api/tags
```

**LiteLLM** (по HTTPS-домену, TLS от Let's Encrypt):
```bash
LITELLM=https://llm.raft.rootcrops.tech
curl -s $LITELLM/v1/models -H "Authorization: Bearer sk-stand-1234"      # две модели
curl -s $LITELLM/v1/chat/completions -H "Authorization: Bearer sk-stand-1234" \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen2.5:0.5b","messages":[{"role":"user","content":"hi"}]}'
```

**OpenWebUI**: открыть `https://chat.raft.rootcrops.tech` в браузере → в выпадашке моделей
должны быть **обе** модели → отправить сообщение и убедиться, что чат отвечает на каждой.
Скриншоты сложить в `docs/screenshots/` (см. `docs/README.md`).

> Бесплатный fallback вместо ingress — port-forward (раскомментированы в `Makefile`):
> `kubectl port-forward -n llm-stand svc/openwebui 8080:80` и т.п.

---

## Нагрузочный тест

```bash
make loadtest BASE_URL=https://llm.raft.rootcrops.tech
# эквивалент:
# k6 run -e BASE_URL=https://llm.raft.rootcrops.tech -e API_KEY=sk-stand-1234 loadtest/load.js
```

Профиль: ramp-up VU `1 → 5 → 10`, поочерёдно обе модели, короткий промпт, `stream:true`
(пик 10 VU и стриминг — чтобы не упираться в idle-таймаут LB, см. «Результаты»).
Во время прогона смотреть Grafana (`https://grafana.raft.rootcrops.tech`, логин `admin` /
пароль из `secrets.local.yaml`): дашборд **LLM Stand — ресурсы и API** (`/d/llm-stand-pods`,
грузится как код из `dashboards/llm-stand.json`) либо встроенный
**Kubernetes / Compute Resources / Namespace (Pods)** → namespace `llm-stand`.

k6 по окончании сам пишет `docs/k6-summary.txt` (p50/p95/p99, RPS, error rate).

### Метрики (что на дашборде)

Дашборд **LLM Stand** собирает три уровня наблюдаемости:

- **Ресурсы подов** (cAdvisor/kube-state): CPU, память, рестарты, готовность подов `ollama`/`litellm`.
- **HTTP-метрики ingress-nginx** по host'у `llm.raft.rootcrops.tech`: RPS по кодам ответа,
  латентность p50/p90/p95, доля 5xx — тот же путь, что нагружает k6. Включены через
  `controller.metrics` + ServiceMonitor (метка `release: monitoring`) в `helm/ingress-nginx-values.yaml`.
- **App-метрики LiteLLM** (`/metrics` прокси): запросы и токены по моделям, латентность обращения
  к модели. Эндпоинт у LiteLLM за master-key авторизацией и смонтирован на `/metrics/`, поэтому
  скрейпится своим `manifests/litellm-servicemonitor.yaml` (path `/metrics/` + Bearer-токен из
  секрета `litellm-masterkey`; токен оператору отдаёт `authorization.credentials`). Включается
  `litellm_settings.callbacks: ["prometheus"]` — в образе `main-stable` метрики доступны без
  enterprise-лицензии.

---

## Результаты

Реальный прогон на кластере TimeWeb (2 узла `2 vCPU / 4 ГБ`, СПб) через HTTPS-ingress
(`https://llm.raft.rootcrops.tech`), обе модели поочерёдно, `max_tokens=32`, `stream:true`.
Полный вывод — в `docs/k6-summary.txt`.

| Метрика | Значение |
|---|---|
| Профиль нагрузки | VU `1 → 5 → 10`, ~4 мин |
| Запросов всего | 112 (обе модели) |
| **Ошибок** | **0%** (`http_req_failed` 0/112, прервано 0) |
| **Throughput** | **0.46 req/s** |
| Latency p50 | 8.68 с |
| Latency p90 / p95 | 23.94 с / 27.68 с |
| Latency min / max | 0.67 с / 34.91 с |
| Пороги | ✓ `chat_latency_ms p95<60s`, ✓ `http_req_failed<20%` |

**Интерпретация.** Бутылочное горлышко — CPU-инференс Ollama: на свободном VU ответ ~0.8 с,
но под нагрузкой запросы выстраиваются в очередь к CPU (узлы 2 vCPU), throughput выходит на
плато ~0.4 req/s, latency растёт. Оба порога пройдены, ошибок нет.

> Прогонов делали несколько; цифры между ними немного гуляют (CPU-инференс, джиттер очереди) —
> например, ~80–112 запросов и p95 ~28–35 с в разных запусках. **Доля ошибок стабильно 0 %**,
> оба порога проходят всегда. Цифры в таблице — один из представительных прогонов.

**Как добивались 0% ошибок (путь трафика).** Первые прогоны через ingress давали ~16.8%
ошибок `unexpected EOF` с жёстким потолком latency ~50 с. Причина — **idle-таймаут
L4-балансировщика TimeWeb (~50 с)**: при `stream:false` во время генерации байты по
соединению не идут, и LB закрывает «простаивающее» соединение. Для сравнения, ранний прогон
**в обход LB** (напрямую в NodePort) держал нагрузку с **0% ошибок** и latency до 65 с — без
балансировщика длинные запросы доходили до конца. То есть ошибки порождал не инференс, а
managed-LB на пути через ingress — реальный trade-off проектирования через один LB. Два рычага
(оба применены, см. `loadtest/load.js`):

1. **`stream:true`** — SSE-чанки текут непрерывно, соединение не простаивает. После этого
   успешные запросы стали доходить до 62 с (выше прежнего «потолка» 50 с), но осталось ~12%
   ошибок: на пике 20 VU часть запросов ждала *первого* байта в очереди CPU >50 с и всё равно
   попадала под idle-таймаут.
2. **Пик ramp 20 → 10 VU** — на 2 vCPU 20 VU это глубокая перегрузка (очередь >50 с); 10 VU
   держит ожидание первого байта в пределах idle-окна LB. Система реально обслуживает нагрузку,
   а не захлёбывается → **0% ошибок**.

Альтернатива, недоступная здесь, — поднять idle-таймаут самого LB, но TimeWeb не даёт это
штатной аннотацией (в конфиге LB только health-check `timeout`, не idle), так что это
ограничение провайдера, обойдённое со стороны теста.

**Наглядный разбор со скриншотами** (что делает k6, связь с Grafana, где результаты) —
[`docs/walkthrough.md`](docs/walkthrough.md).

**Скриншоты** (`docs/screenshots/`, снимаются вручную из браузера): обе модели в выпадашке
OpenWebUI, рабочий чат, Grafana (CPU/RAM подов Ollama) на пике нагрузки.

> Прогон сделан против HTTPS-эндпоинта LiteLLM через ingress (`https://llm.raft.rootcrops.tech`).
> Если фронтенд LB недоступен с твоего адреса (TimeWeb может фильтровать вход по IP),
> как fallback можно прокинуть порт: `kubectl port-forward -n llm-stand svc/litellm 4000:4000`
> и бить в `make loadtest BASE_URL=http://localhost:4000`.

---

## Особенности TimeWeb (по реальному деплою)

Эти грабли уже учтены в репозитории — список на случай воспроизведения на другом кластере:

- **CSI / StorageClass.** В managed-кластере TimeWeb **нет default StorageClass** и CSI «из
  коробки». Поставьте драйвер: панель → **Дополнения → CSI-driver → Установить** (кластер
  должен быть в СПб для сетевых дисков). Появятся классы `nvme/hdd.network-drives.csi.timeweb.cloud`.
  В values класс задан **явно** (`nvme...`), т.к. default-класса нет.
- **Доступ к kube API.** API-сервер может фильтровать подключения по IP — добавьте свой адрес
  в разрешённые в панели, иначе `kubectl` виснет на TLS handshake (хост при этом пингуется).
- **Квота LoadBalancer → один ingress.** Изначально стенд просил 3 LB (LiteLLM, OpenWebUI,
  Grafana) и упирался в квоту TimeWeb (`SyncLoadBalancerFailed`, сервисы в `<pending>`).
  Решение в репозитории: **один** LB у ingress-nginx, все три приложения за ним по host'ам
  (`ClusterIP` + Ingress). Так нужен ровно один LB.
- **Инбаунд-доступность LB на :80/:443.** Фронтенд LB TimeWeb может быть закрыт для внешних
  IP (изнутри кластера отвечает 200, снаружи таймаут). Для работы HTTP-01 (Let's Encrypt
  стучится на :80) и публичного доступа фронтенд должен быть открыт на `0.0.0.0/0` —
  проверьте в панели. Иначе сертификаты зависнут в `Order`/`Challenge`.
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

Сносит релизы приложений, платформу (ingress-nginx, cert-manager, ClusterIssuer) и namespace.
**Важно:** убедитесь, что LoadBalancer удалён — каждый LB в TimeWeb тарифицируется:

```bash
kubectl get svc -A | grep LoadBalancer    # должно быть пусто
```

Затем при необходимости удалить сам кластер в панели TimeWeb.
