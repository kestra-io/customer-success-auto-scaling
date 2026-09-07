# Trigger app

One Node container (no build step, no dependencies — Node 20 built-ins only):

- serves the static slider UI from `public/`,
- runs a **server-side loop** that POSTs the Kestra webhook at `rate` triggers/min,
- `GET /api/stats` scrapes Kestra `:8081/prometheus`, sums the worker
  `pending` / `running` / `thread` series, and derives
  `capacity = worker_replicas × threads_per_worker`.

## Endpoints

| Method | Path | Purpose |
|---|---|---|
| GET | `/api/config` | webhook URL, presets, rate ceiling |
| GET | `/api/stats` | live `{pending, running, worker_replicas, concurrent_capacity, utilization, rate_per_min, fired_total, …}` |
| PUT | `/api/rate` | `{ "perMin": <0..RATE_MAX> }` |
| POST | `/api/preset` | `{ "name": "baseline" \| "spike" \| "drop" }` |
| GET | `/api/health` | — |

## Config

Environment variables (set by `docker-compose.yml`, values from the repo-root `.env`):

`KESTRA_BASE_URL`, `KESTRA_MGMT_URL`, `KESTRA_TENANT`, `FLOW_NAMESPACE`,
`FLOW_ID`, `WEBHOOK_KEY`, `WORKER_THREADS`, `METRIC_PENDING` / `_RUNNING` /
`_THREADS`, `RATE_BASELINE` / `_SPIKE` / `_DROP` / `_MAX`, `APP_PORT`.

In the Kubernetes path the container reaches Kestra at
`host.docker.internal:8080/8081` (the background `kubectl port-forward` from
`scripts/up.sh`). In the `compose/` quickstart it reaches `kestra:8080/8081` on
the compose network.
