# docs/

Артефакты результатов нагрузочного теста и наблюдаемости.

## Что сюда положить

- `k6-summary.txt` — заполняется **автоматически** при `make loadtest`
  (функция `handleSummary` в `loadtest/load.js`). Содержит p50/p95/p99, RPS, error rate.
- `screenshots/` — скриншоты, снятые **вручную**:
  - `openwebui-models.png` — выпадашка OpenWebUI с обеими моделями (`qwen2.5:0.5b`, `llama3.2:1b`).
  - `openwebui-chat.png` — рабочий чат (ответ хотя бы на одной модели).
  - `grafana-peak.png` — дашборд Grafana (CPU/RAM подов Ollama) на пике нагрузки k6.

## Куда смотреть в Grafana

Dashboards → **Kubernetes / Compute Resources / Namespace (Pods)** → namespace `llm-stand`.
Снимать на пике (стадия 20 VU прогона k6) — там виден потолок CPU подов Ollama.
