# Compose quickstart (no cluster)

The fastest way to *see the problem*. One `docker compose` brings up:

- `postgres:16`
- a single-node Kestra (`server standalone --worker-thread 4`) on `:8080` / `:8081`
- `flow-init` — imports `../flows/webhook_sleep.yaml` once the API is up
- the trigger app on `:5173`

```bash
cp .env.example .env          # add the EE license, or set KESTRA_IMAGE=kestra/kestra:v1.3.24
docker compose up --build
# open http://localhost:5173
```

## What this demonstrates

- **Baseline (8/min)** — the worker sits at ~50 % (2 of 4 threads), queue empty.
- **Spike (24/min)** — arrivals exceed the 4-thread ceiling; `pending` climbs and
  executions visibly wait. This is the whole point: a fixed worker pool can't
  absorb the burst.
- **Drop (2/min)** — the backlog drains.

## What this does NOT do

- **No live worker scaling.** Workstream 1 scales a Kubernetes `Deployment`; a
  compose `standalone` process has no equivalent knob. Use the Kubernetes path
  (`../SETUP.md`, `make up` + `make scaler`) to watch replicas move.
- **No Workstream 2 yet** — it's a placeholder everywhere.

## Teardown

```bash
docker compose down -v
```
