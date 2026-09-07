# Workstream 1 — Prometheus metrics + worker scaling

**Idea:** a worker pool's concurrency ceiling is `replicas × threads_per_worker`.
Add replicas when Kestra's internal queue backs up; remove them when it's idle.
The demand signal is Kestra's own `kestra_worker_job_pending` / `_running`
gauges.

```
  ┌── list pods app.kubernetes.io/component=worker ──┐
  │                                                  │
  │   scrape each  http://<podIP>:8081/prometheus    │   every POLL_INTERVAL_SECONDS
  │     kestra_worker_job_pending                    │
  │     kestra_worker_job_running                    │
  │     kestra_worker_job_thread                     │
  │                                                  ▼
  │                                   ┌─────────────────────────┐
  │                                   │ worker-scaler (this)    │
  │                                   │  sum across pods        │
  │                                   │  sustained-window logic │
  │                                   └───────────┬─────────────┘
  │                                               │ patch deployments/scale
  │                                   ┌───────────▼─────────────┐
  └────────────────────────────────── │ Deployment kestra-worker │  replicas 1 ⇄ 2
                                      └─────────────────────────┘
```

## Why it scrapes worker pods directly

In **Kestra EE there is no cross-service metric aggregation**. The
`kestra_worker_job_*` gauges are exposed **only on each worker pod's own
`:8081/prometheus`** — the webserver's `/prometheus` has `kestra_jdbc_*` /
`kestra_queue_*` and nothing about worker threads.

So the scaler:

1. lists pods matching `WORKER_LABEL_SELECTOR` (needs `pods: get,list` RBAC),
2. scrapes `http://<podIP>:8081/prometheus` for every **Ready** worker pod,
3. sums `pending` and `running` across them — the signal is independent of how
   many replicas are reporting.

(The chart also creates a `kestra-worker-metrics` ClusterIP Service selecting the
worker pods, exposed on the host `:8082`)

### `GET /state` — authoritative readout for the trigger app

`statehttp.py` runs a stdlib HTTP thread inside the scaler pod. Every tick
publishes the observation it just computed — the cross-pod `pending`/`running`
sum and the real Deployment replica count — as JSON on `STATE_HTTP_PORT`
(default `8080`; `503` until the first tick). `k8s/service.yaml` fronts it as
`svc/worker-scaler`, and `scripts/portforward.sh` forwards it to host `:8083`.
The trigger app's `/api/stats` prefers `SCALER_STATE_URL` and shows a
`source: scaler` badge; if the scaler isn't deployed it falls back to the
single-pod `:8082` scrape and the badge turns amber.

## Prerequisite: cap Kestra's JDBC queue `poll-size`

**Without this the demo does not work.** With the Postgres/JDBC queue backend and
the default `poll-size: 100`, the first worker's queue consumer leases the entire
backlog into its local buffer and re-polls immediately — a second worker finds
the queue empty and starves. Adding replicas then adds ~no throughput.

`helm/values.yaml` sets, inside `KESTRA_CONFIGURATION`:

```yaml
kestra:
  jdbc:
    queues:
      poll-size: 2          # ~ per-worker thread batch; no single consumer can hoard
      min-poll-interval: 20ms
      max-poll-interval: 20ms   # idle worker never backs off -> grabs work as it appears
```

Trade-off: constant short polls raise DB load. Fine for a laptop demo; for a real
cluster tune `poll-size` up and let `min`/`max-poll-interval` diverge, or move to
the Kafka backend (partitioned, consumer-group rebalancing) for true fair
distribution.

## Algorithm (`scaler/controller.py`, ~180 lines)

- **Scale up** — `pending ≥ PENDING_SCALE_UP_THRESHOLD` for *every* sample across
  a full `SCALE_UP_WINDOW_SECONDS`, and `replicas < MAX_REPLICAS`
  → `replicas += SCALE_STEP`.
- **Scale down** — `pending == 0` **and**
  `running ≤ RUNNING_SCALE_DOWN_RATIO × capacity` for every sample across a full
  `SCALE_DOWN_WINDOW_SECONDS`, and `replicas > MIN_REPLICAS`
  → `replicas -= SCALE_STEP`.
- After any change: hold for `COOLDOWN_SECONDS` (≥ a new worker pod's
  start-and-register time, so the loop doesn't stack scale-ups).
- `capacity = replicas × THREADS_PER_WORKER`.
- `window_covered(...)`: only act once the retained samples actually span the
  window (guards the first minute after startup).

Pseudocode and the design reasoning are in `../PLAN.md`.

## Observed behaviour (validated end-to-end)

| phase | trigger rate | what the scaler does |
|---|---|---|
| baseline | 8/min | `decision=hold`, `util≈50%`, 1 replica |
| spike | 24/min | `pending` climbs on 1 worker → after ~60 s: `scaled kestra-worker 1 -> 2` |
| — | — | new worker Ready + registers in ~30–60 s (cooldown covers it), then backlog drains over ~2–3 min, `running` → ~6/8 |
| drop | 2/min | after `SCALE_DOWN_WINDOW_SECONDS` + cooldown: `scaled kestra-worker 2 -> 1` |

## Env vars

Set on the `worker-scaler-config` ConfigMap by `../scripts/deploy-scaler.sh`
from the repo-root `.env` + `.state/metric-names.env`.

| Var | Default | Meaning |
|---|---|---|
| `WORKER_LABEL_SELECTOR` | `app.kubernetes.io/name=kestra,app.kubernetes.io/component=worker` | which pods to scrape |
| `WORKER_METRICS_PORT` | `8081` | worker management port |
| `PROMETHEUS_URL` | *(empty)* | optional: scrape this **one** URL instead of discovering pods (compose path / tests) |
| `METRIC_PENDING` / `METRIC_RUNNING` / `METRIC_THREADS` | `kestra_worker_job_pending` / `_running` / `_thread` | pinned at bring-up by `scripts/verify-metrics.sh` → `.state/metric-names.env` |
| `NAMESPACE` | `autoscaling` | |
| `WORKER_DEPLOYMENT_NAME` | `kestra-worker` | resolved by label in `deploy-scaler.sh` |
| `THREADS_PER_WORKER` | `4` | must equal the Helm `workerThreads` |
| `POLL_INTERVAL_SECONDS` | `15` | loop period |
| `SCALE_UP_WINDOW_SECONDS` | `60` | how long `pending` must stay elevated |
| `SCALE_DOWN_WINDOW_SECONDS` | `180` | how long it must stay quiet (repo `.env` lowers this for faster demos) |
| `PENDING_SCALE_UP_THRESHOLD` | `1` | `pending ≥ this` counts as "backed up" |
| `RUNNING_SCALE_DOWN_RATIO` | `0.5` | scale down only below this fraction of capacity |
| `SCALE_STEP` | `1` | replicas per action |
| `MIN_REPLICAS` / `MAX_REPLICAS` | `1` / `2` | bounds (this demo only needs 1 ⇄ 2) |
| `COOLDOWN_SECONDS` | `90` | quiet period after any scale action |
| `DRY_RUN` | `false` | log decisions, don't patch |
| `LOG_LEVEL` | `INFO` | |
| `STATE_HTTP_PORT` | `8080` | port for `GET /state` (`0` disables it) |

## Run

```bash
make scaler                                   # build image, kind load, RBAC, ConfigMap, Deployment
kubectl -n autoscaling logs -f deploy/worker-scaler
kubectl -n autoscaling get deploy kestra-worker -w
```

Then drive load from the trigger app: **Spike** → 1 → 2; **Drop** → 2 → 1.

## RBAC (`k8s/`, namespaced)

| resource | verbs | why |
|---|---|---|
| `apps/deployments` | `get, list, watch` | read the worker Deployment |
| `apps/deployments/scale` | `get, patch, update` | change `replicas` |
| `pods` | `get, list` | discover worker pod IPs to scrape |

Bound to the `worker-scaler` ServiceAccount; the container uses
`kubernetes.config.load_incluster_config()`.

## Operational gotcha: Helm vs. the scaler on `spec.replicas`

Once the scaler has patched `kestra-worker` via the `scale` subresource, a later
`helm upgrade` (server-side apply) **conflicts** on `.spec.replicas` and fails:

```
conflict with "OpenAPI-Generator" ... subresource "scale" ... .spec.replicas
```

Before re-running `helm upgrade` / `make up` on a live cluster:

```bash
kubectl -n autoscaling scale deploy/worker-scaler --replicas=0
kubectl -n autoscaling scale deploy/kestra-worker --replicas=1
```

`make down` sidesteps this entirely (it deletes the cluster).

## Production-grade equivalent (not built here)

KEDA `ScaledObject` (Prometheus scaler on `kestra_worker_job_pending`) + HPA
`behavior.scaleDown.stabilizationWindowSeconds` for the quiet period. That's the
right tool for real systems; this container exists so the control logic —
asymmetric sustained windows, cooldown, capacity-relative scale-down, summing
across pods — is visible and tunable in one file.
