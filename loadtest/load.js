// k6 нагрузочный тест тракта OpenWebUI → LiteLLM → Ollama.
// Бьём напрямую в LiteLLM (/v1/chat/completions) — это узкое место тракта (CPU-инференс).
//
// Запуск:
//   k6 run -e BASE_URL=http://<LITELLM_LB_IP>:4000 -e API_KEY=sk-stand-1234 loadtest/load.js
//
// BASE_URL  — внешний IP LoadBalancer сервиса litellm (см. `make ips`).
// API_KEY   — masterkey из helm/litellm-values.yaml (по умолчанию sk-stand-1234).
//
// Ожидаемый результат: на CPU инференс медленный — низкий throughput и рост latency
// под нагрузкой это валидный результат, который и нужно показать.

import http from 'k6/http';
import { check, sleep } from 'k6';
import { Trend, Rate } from 'k6/metrics';
import { textSummary } from 'https://jslib.k6.io/k6-summary/0.0.1/index.js';

const BASE_URL = __ENV.BASE_URL || 'http://localhost:4000';
const API_KEY = __ENV.API_KEY || 'sk-stand-1234';

// Обе модели нагружаем поочерёдно, чтобы метрики были по обеим.
const MODELS = ['qwen2.5:0.5b', 'llama3.2:1b'];

// Кастомные метрики для разбивки по модели.
const ttfb = new Trend('chat_latency_ms', true);
const chatErrors = new Rate('chat_errors');

export const options = {
  // ramp-up VU 1 → 5 → 10 → 20, короткий прогон.
  stages: [
    { duration: '30s', target: 1 },
    { duration: '1m', target: 5 },
    { duration: '1m', target: 10 },
    { duration: '2m', target: 20 },
    { duration: '30s', target: 0 },
  ],
  thresholds: {
    // Пороги мягкие — на CPU-инференсе важнее зафиксировать цифры, чем «пройти».
    http_req_failed: ['rate<0.20'],
    chat_latency_ms: ['p(95)<60000'],
  },
};

export default function () {
  // Чередуем модели по номеру итерации виртуального пользователя.
  const model = MODELS[(__ITER + __VU) % MODELS.length];

  const payload = JSON.stringify({
    model: model,
    messages: [
      { role: 'user', content: 'Say hello in one short sentence.' },
    ],
    max_tokens: 32,
    stream: false,
  });

  const params = {
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${API_KEY}`,
    },
    timeout: '120s',
    tags: { model: model },
  };

  const res = http.post(`${BASE_URL}/v1/chat/completions`, payload, params);

  ttfb.add(res.timings.duration, { model: model });
  const ok = check(res, {
    'status is 200': (r) => r.status === 200,
    'has choices': (r) => {
      try {
        return JSON.parse(r.body).choices.length > 0;
      } catch (e) {
        return false;
      }
    },
  });
  chatErrors.add(!ok, { model: model });

  sleep(1);
}

// Пишем человекочитаемый summary в docs/ — для раздела «Результаты» в README.
export function handleSummary(data) {
  return {
    stdout: textSummary(data, { indent: ' ', enableColors: true }),
    'docs/k6-summary.txt': textSummary(data, { indent: ' ', enableColors: false }),
  };
}
