Status: draft v1, 2026-09-06. Revise in place as the design gets tuned.

# Auto-Scaling Example — Design

## Why

Kestra worker capacity is `worker_replicas × worker_threads`. A spiky,
webhook-triggered workload overruns that ceiling; the overflow queues inside
Kestra (executor / worker queue), not in the upstream transport. The usual
mitigation — a fixed, peak-sized worker pool — is wasteful during the (long)
quiet periods.

This example:

1. reproduces the problem with the smallest possible moving parts, and
2. gives each proposed fix its own **workstream** directory so they can be built
   and demoed independently.

## The baseline problem (what the demo shows)

- Distributed Kestra EE **v1.3.24** on `kind`: `webserver`, `executor`,
  `indexer`, `scheduler` (1 replica each) + **1 `worker` with `--thread=4`** +
  in-cluster `postgres:16`.
- `flows/webhook_sleep.yaml`: `Webhook` trigger → one `Sleep` task, `PT15S`.
  **No `concurrency:` block** — worker threads are the only limiter.
- `app/` fires the webhook at a controllable rate. At the default rate the
  worker sits at ~50 % (2 of 4 threads). The **Spike** preset pushes past 4
  concurrent, so `kestra_worker_job_pending` climbs and executions visibly wait.

## Deployment topology

`SQS/webhook → Kestra executor queue → worker thread → Sleep`

There is no task runner and no DinD (`dind.enabled: false`) — the `Sleep` task
runs directly on a worker thread. This keeps new-worker startup fast and the
laptop footprint small. `helm/values.yaml` is a trim of
`../../infra/my-kestra/values.yaml` with basic auth disabled and
`workerThreads: 4`.

## Calibration

`W` = 15 s (Sleep), `T` = 4 threads/worker, `R₀` = 1 → **capacity = R·T**.

Little's Law, stable system: `L = λ · W` (mean in-flight = arrival rate × service time).

| Preset | Rate | λ (/s) | `L` | 1 worker (cap 4) | 2 workers (cap 8) |
|---|---|---|---|---|---|
| drop | 2 /min | 0.033 | 0.5 | idle → scale to 1 | — |
| **baseline** | **8 /min** | 0.133 | **2** | steady, `pending≈0` | — |
| _saturation_ | 16 /min | 0.267 | 4 | queue starts growing | — |
| spike | 24 /min | 0.400 | 6 | `pending` +~8/min → scale to 2 | drains |

Slider: 0–30 /min, step 2, default 8. `MAX_REPLICAS = 2` (absolute cap 3).

**Metric lag:** the webserver re-aggregates worker gauges onto its own
`/prometheus` every 30 s. Treat `/stats` values as ≤30–60 s stale; scaler
windows are ≥ 60 s and there is a cooldown.

## Workstream 1 — Prometheus + worker scaling

A custom Python control-loop container (`workstream-1-.../scaler/`) that:

- scrapes `http://<webserver>:8081/prometheus`,
- sums `kestra_worker_job_pending` / `kestra_worker_job_running` across worker
  series,
- reads the `worker` Deployment's current replicas,
- **scales up** when `pending ≥ threshold` for a sustained window,
- **scales down** when `running ≤ 50 % of capacity` and `pending == 0` for a
  longer sustained window,
- respects `MIN/MAX_REPLICAS`, a `SCALE_STEP`, and a `COOLDOWN`.

Runs in-cluster with a namespaced `Role` granting `deployments/scale`
`get,patch,update`. KEDA / HPA + prometheus-adapter is the production-grade
path; this container exists so the control logic is explicit and tunable for
teaching. Full env-var table in the workstream README.

## Workstream 2 — flow `concurrency.limit` (deferred)

Placeholder only. Will patch the flow's `concurrency.limit` (which gives
`behavior: QUEUE` — bounded wait, back-pressure) dynamically off the **same**
Prometheus signal, at **fixed** worker capacity. Contrast with Workstream 1:
WS1 changes capacity, WS2 changes admission policy. Patch mechanism (flow API
`PUT`, a Kestra flow editing another flow, GitOps, terraform-provider-kestra) is
the user's call — nothing is built yet.

## Taxonomy (label scheme)

Modeled on `../kestra-demo-factory/PLAN.md` "Review surface".

**Workstream** — `ws:` (one or more per work item):

| Label | Scope |
|---|---|
| `ws:harness` | kind, Helm, secrets, scripts, Makefile |
| `ws:baseline` | the flow, the trigger app, "show the problem" story |
| `ws:prometheus-scaling` | Workstream 1 (control loop + RBAC) |
| `ws:concurrency-limit` | Workstream 2 (placeholder) |
| `ws:docs` | README / PLAN / SETUP / SKILL, calibration, OSS-swap |

**Component** — `comp:` (one or more):

`comp:flow`, `comp:helm`, `comp:kind`, `comp:compose`, `comp:scripts`,
`comp:app`, `comp:scaler`, `comp:rbac`, `comp:metrics`

**Status** — exactly one:

| Label | Meaning |
|---|---|
| `status:spike` | exploratory, not wired in |
| `status:building` | under active implementation |
| `status:calibrated` | works and hits the numbers above |
| `status:documented` | reproducible from a clean checkout |
| `status:deferred` | intentionally not being built now |

Example: the scaler is `ws:prometheus-scaling` + `comp:scaler` + `comp:rbac` +
`status:building`. Workstream 2 is `ws:concurrency-limit` + `comp:flow` +
`status:deferred`.

## Risks / verify at build time

- **Exact Prometheus metric names on v1.3.24** — `develop` shows a rename.
  `scripts/verify-metrics.sh` curls the live endpoint and pins the real names
  into `.state/metric-names.env`; every consumer reads names from env.
- **EE image pull on kind** — large. `docker pull` on the host then
  `kind load docker-image` avoids in-cluster registry auth.
- **EE boot without super-admin** — if it refuses, add a throwaway one; the
  webhook and `/prometheus` stay anonymous regardless.
- **Helm repo URL** — `https://helm.kestra.io/` per the `kestra-kubectl` skill;
  an older file used `https://charts.kestra.io`. `up.sh` fails loudly.
- **Footprint** — 5 JVMs + postgres on one kind node. `SETUP.md` asks for
  Docker ≥ 6 GB / 4 CPU. Single replicas, no memory limits, DinD off.
- **`pending` actually moves under spike** with `queue.type: postgres` — if it
  stays flat, fall back to `running == capacity` sustained as the scale-up
  signal.
- **New-worker start latency vs. windows** — `SCALE_UP_WINDOW` + `COOLDOWN`
  must exceed pod-ready time on kind; tune during end-to-end.

## Deferred / not building now

Workstream 2 implementation · KEDA/HPA variant · real Prometheus/Grafana ·
ingress / LoadBalancer · autoscaling non-worker components · EE-only features ·
cloud clusters (one note in this file, no manifests) · CI / image publishing ·
`/stats` history & dashboards · non-`main` tenants · scripted ramp profiles
beyond the three presets · `git init` automation (manual step in `SETUP.md`).

## Adapting to a real cluster

Replace `kind/` with your cluster context, drop the `up.sh` `port-forward` step
for an Ingress or LoadBalancer Service, point `helm/values.yaml`
`datasources.postgres` at a managed database, and supply real secrets. The
worker-thread setting, the metric names, and the scaler are unchanged.
