# Kestra Worker Auto-Scaling Example

A self-contained example that makes one problem tangible and then compares two
ways to solve it:

> A Kestra flow is triggered by a spiky, webhook-driven workload. The only thing
> limiting how many executions run at once is the worker pool
> (`worker_replicas × worker_threads`). When traffic spikes, work backs up in
> Kestra's internal queue. To keep latency acceptable, teams pre-provision a
> fixed, peak-sized worker pool — which is idle and wasteful most of the time.
> How do you make the pool grow and shrink with actual demand?

Nothing here is tied to a real customer. It is a teaching artifact and the
skeleton the two solution workstreams are built out in.

## What's in the box

| Piece | Path | Role |
|---|---|---|
| Distributed Kestra on Kubernetes | `helm/values.yaml`, `kind/cluster.yaml` | Kestra **EE v1.3.24**, 1 worker, **exactly 4 threads** → hard ceiling of 4 concurrent executions |
| The workload flow | `flows/webhook_sleep.yaml` | Webhook trigger → one `Sleep` task (`PT15S`). Deliberately trivial and quick to watch |
| Trigger app | `app/` | One Node container: a slider for **trigger rate**, **spike / baseline / drop** presets, and a live readout of `pending` vs. `capacity` scraped from Kestra's Prometheus endpoint |
| **Workstream 1** — Prometheus + worker scaling | `workstream-1-prometheus-worker-scaling/` | A small custom control-loop container that watches `kestra_worker_job_pending` / `kestra_worker_job_running` on `:8081/prometheus` and scales the `worker` Deployment up/down |
| **Workstream 2** — flow `concurrency.limit` | `workstream-2-flow-concurrency-limit/` | **Placeholder.** Same signal, different actuator (bounded queue instead of more capacity). Mechanism TBD |
| Compose quickstart | `compose/` | See the *problem* in ~2 minutes with no cluster (single-node Kestra + the app) |

## Quickstart (Kubernetes path)

Prerequisites and the full walk-through are in [`SETUP.md`](./SETUP.md). Short version:

```bash
# FILL REQUIRED ENV VARIABLES
# copy the example environment file to .env
# NOTES: fill in KESTRA_EE_LICENSE_* at minimum or switch to the OSS image (below)
cp .env.example .env

# login to the Kestra registry if using the EE image
docker login registry.kestra.io          # EE image only

# Start the demo. This will:
# - create a kind cluster
# - deploy Kestra with Helm
# - import the workload flow
# - start the trigger app
make up          # kind cluster + Helm + flow import + trigger app; prints all URLs

# Deploy Workstream 1 (Prometheus + worker scaling)
make scaler      # deploy Workstream 1

# TESTING: 
# - open the trigger app: http://localhost:5173/
# hit "Spike"
# watch:  kubectl get deploy -n autoscaling -w

# Tear down. 
# `make down` keeps the kind cluster so the next `make up` is fast
# `make down-hard` also deletes the cluster.
make down
```

## No EE license? Swap the image.

This example uses **no** Enterprise-only features (no worker groups, no EE RBAC).
Set one value in `.env` and skip the registry login and license entirely:

```bash
KESTRA_IMAGE=kestra/kestra:v1.3.37
```

Behavior is identical for the purposes of this demo.

## Calibration at a glance

`Sleep = 15 s`, `threads_per_worker = 4`, starting `replicas = 1` → **capacity = 4**.

| Preset | Trigger rate | In-flight (Little's Law `λ·15s`) | What happens |
|---|---|---|---|
| Drop | 2 / min | ~0.5 (≈12 %) | scaler returns worker to 1 replica |
| **Baseline (default)** | **8 / min** | **2 (50 %)** | steady, queue empty |
| Spike | 24 / min | 6 (150 %) | `pending` climbs → scaler adds a 2nd worker (capacity 8) → queue drains |


## Layout

| Path | Description |
|---|---|
| `README.md`, `PLAN.md`, `SETUP.md` | Project overview, implementation plan, and step-by-step setup instructions |
| `Makefile` | Commands for starting, testing, scaling, and tearing down the demo |
| `.env.example` | Template for the environment variables required by the Kubernetes setup |
| `kind/` | Kind cluster configuration used to run the demo locally |
| `helm/` | Kestra Helm values, including the worker replica and thread settings |
| `flows/` | The webhook-triggered workload flow used to create measurable demand |
| `scripts/` | Shell scripts for provisioning, deployment, port forwarding, verification, and cleanup |
| `app/` | Node.js trigger dashboard with rate controls, workload presets, and live metrics |
| `compose/` | Docker Compose quickstart for exploring the workload without Kubernetes |
| `workstream-1-prometheus-worker-scaling/` | Prometheus-driven controller that adjusts the Kestra worker Deployment |
| `workstream-2-flow-concurrency-limit/` | Placeholder for the flow-level concurrency-limit approach |
