---
name: autoscaling-demo
description: Operator runbook for demoing the Kestra worker auto-scaling example (initiatives/auto-scaling) — bring up the kind cluster + Helm + trigger app, walk the baseline/spike/drop presets, run Workstream 1, tear down.
---

# Auto-Scaling Example — Operator Runbook

A human-driven demo, not an automation. Everything lives in
`initiatives/auto-scaling/`.

## Preflight

- `docker` (VM ≥ 6 GB / 4 CPU), `kind`, `kubectl`, `helm`, `envsubst`, `curl`, `jq`
- `initiatives/auto-scaling/.env` filled (`cp .env.example .env`; add
  `KESTRA_EE_LICENSE_*` + registry creds, or set `KESTRA_IMAGE=kestra/kestra:v1.3.24`)
- EE only: `docker login registry.kestra.io`
- Optional pre-warm: `docker pull "$KESTRA_IMAGE" && kind load docker-image "$KESTRA_IMAGE" --name kestra-autoscaling`

## Bring up

```bash
cd initiatives/auto-scaling
make up          # ~5-10 min first run (EE image pull). Prints 4 URLs at the end.
```

If `helm repo` fails, switch `HELM_REPO_URL` in `.env` to
`https://charts.kestra.io` and re-run.
If the port-forward drops later, `scripts/portforward.sh start`.

## Demo script

1. Open the trigger app (`http://localhost:5173`). Slider at **8/min** (Baseline).
   Wait ~90 s. Readout: `running ≈ 2`, `pending ≈ 0`, `capacity = 4` (~50 %).
   *Narrate: one worker, 4 threads, half full.*
2. Click **Spike** (24/min). Within 1-2 min `pending` climbs, `running` pins at 4.
   *Narrate: arrivals now exceed the ceiling; the backlog forms inside Kestra,
   not in the queue the app can see.*
3. Click **Drop** (2/min). `pending` drains.
4. `make scaler` (in another pane: `kubectl -n autoscaling get deploy -w` and
   `kubectl -n autoscaling logs -f deploy/worker-scaler`).
5. **Spike** again. After ~60 s the scaler logs `scaled ... 1 -> 2`; the
   Deployment goes `2/2`; app `capacity` → 8; `pending` stops growing and drains.
6. **Drop**. After ~3 min the scaler logs `scaled ... 2 -> 1`.
7. Mention Workstream 2 (`workstream-2-flow-concurrency-limit/README.md`) as the
   other approach — same signal, fixed capacity, bounded queue — not yet built.

## Compose-only quick look (no cluster)

```bash
cd initiatives/auto-scaling/compose
cp .env.example .env    # license or OSS image
docker compose up --build
# http://localhost:5173 -> Spike -> pending grows.  No live scaling here.
```

## Tear down

```bash
make down                       # kind cluster + app + scaler + port-forward
# compose path:
cd compose && docker compose down -v
```

## Troubleshooting

- **`/api/stats` shows `scrape_error`** — port-forward down, or basic auth on.
  `scripts/portforward.sh start`; confirm `helm/values.yaml` has
  `basicAuth.enabled: false`.
- **Metrics missing / flat** — run a few executions, wait 30 s (webserver
  re-aggregates on a timer), `make metrics`. If names differ from
  `kestra_worker_job_*`, `make metrics` pins the real ones into
  `.state/metric-names.env`; re-run `make scaler`.
- **Scaler never acts** — check `kubectl auth can-i patch deployments/scale
  --as=system:serviceaccount:autoscaling:worker-scaler`; check `DRY_RUN`.
- **Worker didn't get 4 threads** — `kubectl -n autoscaling get deploy
  kestra-worker -o jsonpath='{.spec.template.spec.containers[0].command}'`
  should contain `--thread=4`.
