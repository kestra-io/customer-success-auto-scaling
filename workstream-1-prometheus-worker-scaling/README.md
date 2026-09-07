# Workstream 1 — Prometheus metrics + worker scaling

**Idea:** the worker pool's concurrency ceiling is `replicas × threads`. Add
replicas when the queue backs up; remove them when it's idle. The demand signal
is Kestra's own queue-depth metric, not the upstream transport.

```
                 ┌──────────────────────────────┐
   scrape  ◄──── │ kestra webserver :8081        │
   every 15s     │   /prometheus                 │
                 │   kestra_worker_job_pending   │
                 │   kestra_worker_job_running   │
                 └──────────────┬───────────────┘
                                │  sum across worker series
                    ┌───────────▼────────────┐
                    │ worker-scaler (this)   │
                    │  sustained-window logic│
                    └───────────┬────────────┘
                                │ patch deployments/scale
                    ┌───────────▼────────────┐
                    │ Deployment .../worker  │  replicas 1 ⇄ 2
                    └────────────────────────┘
```

## Algorithm

- **Scale up** — `pending ≥ PENDING_SCALE_UP_THRESHOLD` for every sample across a
  full `SCALE_UP_WINDOW_SECONDS`, and `replicas < MAX_REPLICAS` → `replicas += SCALE_STEP`.
- **Scale down** — `pending == 0` *and* `running ≤ RUNNING_SCALE_DOWN_RATIO ×
  capacity` for every sample across a full (longer) `SCALE_DOWN_WINDOW_SECONDS`,
  and `replicas > MIN_REPLICAS` → `replicas -= SCALE_STEP`.
- After any change, do nothing for `COOLDOWN_SECONDS` (≥ a new worker pod's
  start time, so the loop doesn't stack scale-ups before threads come online).
- `capacity = replicas × THREADS_PER_WORKER`. Metrics are summed across all
  worker series, so the signal doesn't depend on how many replicas are reporting.

Pseudocode and the reasoning are in `../PLAN.md`. The implementation is
`scaler/controller.py` (~140 lines).

## Env vars

| Var | Default | Meaning |
|---|---|---|
| `PROMETHEUS_URL` | `http://<webserver-svc>:8081/prometheus` | scrape target (set by `deploy-scaler.sh`) |
| `METRIC_PENDING` / `METRIC_RUNNING` / `METRIC_THREADS` | `kestra_worker_job_pending` / `_running` / `_thread` | **verified at bring-up** by `scripts/verify-metrics.sh` → `.state/metric-names.env` |
| `NAMESPACE` | `autoscaling` | namespace of the worker Deployment |
| `WORKER_DEPLOYMENT_NAME` | `kestra-worker` | discovered from the `component=worker` label |
| `THREADS_PER_WORKER` | `4` | must equal the Helm `workerThreads` |
| `POLL_INTERVAL_SECONDS` | `15` | loop period |
| `SCALE_UP_WINDOW_SECONDS` | `60` | how long `pending` must stay elevated |
| `SCALE_DOWN_WINDOW_SECONDS` | `180` | how long it must stay quiet |
| `PENDING_SCALE_UP_THRESHOLD` | `1` | `pending ≥ this` counts as "backed up" |
| `RUNNING_SCALE_DOWN_RATIO` | `0.5` | scale down only below this fraction of capacity |
| `SCALE_STEP` | `1` | replicas per action |
| `MIN_REPLICAS` / `MAX_REPLICAS` | `1` / `2` | bounds (this demo only needs 1⇄2) |
| `COOLDOWN_SECONDS` | `90` | quiet period after any scale action |
| `DRY_RUN` | `false` | log decisions, don't patch |
| `LOG_LEVEL` | `INFO` | — |

All are set on the `worker-scaler-config` ConfigMap by
`../scripts/deploy-scaler.sh` from the repo-root `.env` + `.state/metric-names.env`.

## Run

```bash
make scaler                       # build + kind load + RBAC + ConfigMap + Deployment
kubectl -n autoscaling logs -f deploy/worker-scaler
kubectl -n autoscaling get deploy kestra-worker -w
```

Then drive load from the trigger app: **Spike** → scale up to 2; **Drop** →
scale back to 1.

## RBAC

`k8s/role.yaml` grants, in this namespace only:

- `apps/deployments` — `get, list, watch`
- `apps/deployments/scale` — `get, patch, update`

Bound to the `worker-scaler` ServiceAccount. The container uses in-cluster
credentials (`kubernetes.config.load_incluster_config()`).

## Production-grade equivalent (not built here)

KEDA `ScaledObject` with the Prometheus scaler on `kestra_worker_job_pending`,
plus HPA `behavior.scaleDown.stabilizationWindowSeconds` for the quiet-period.
That's the right choice for real systems; this container exists so the control
logic — sustained windows, asymmetric up/down, cooldown, capacity-relative
scale-down — is visible and tunable in one file.
