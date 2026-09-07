# Workstream 2 — Flow `concurrency.limit` (placeholder)

> **Status:** not built. Mechanism to be specified.

## Idea

Instead of adding worker capacity (Workstream 1), keep the worker pool **fixed**
and control *admission* with the flow's `concurrency` block:

```yaml
concurrency:
  behavior: QUEUE     # executions beyond `limit` wait; they are not dropped or failed
  limit: <N>
```

A controller watches the **same** Prometheus signal
(`kestra_worker_job_pending` / `kestra_worker_job_running` on `:8081/prometheus`)
and adjusts `limit` up or down — a bounded queue with back-pressure rather than
elastic capacity.

## Contrast with Workstream 1

| | Workstream 1 | Workstream 2 |
|---|---|---|
| Lever | worker **replicas** (capacity) | flow **`concurrency.limit`** (admission) |
| Under a spike | more threads absorb the burst | burst waits in a bounded queue |
| Cost profile | scales with demand | flat |
| Blast radius | cluster (new pods, new nodes) | one flow definition |

## Open question — the patch mechanism

`concurrency.limit` lives in the flow definition and is not a runtime variable.
Candidates, to be chosen:

1. **Flow API** — `PUT /api/v1/{tenant}/flows/{namespace}/{id}` with the edited YAML.
2. **A Kestra flow that edits another flow** — self-referential control loop, no external service.
3. **GitOps** — commit the new limit; a sync applies it.
4. **`terraform-provider-kestra`** — `kestra_flow` resource re-applied.

Notes that will matter when this is built:

- Kestra applies an edited `concurrency.limit` to in-flight executions
  immediately (the executor reads the latest flow revision), so with
  `behavior: QUEUE` raising the limit releases queued executions up to the new
  value — verify the release rate on v1.3.24.
- If multiple flows share a worker pool, independent per-flow limits can
  collectively exceed capacity — a shared allocator is then needed.
- Keep the worker-thread count as an independent hard ceiling regardless.

## When we build it

Add here: `controller/` (the limit patcher), `k8s/` (Deployment + RBAC or a
Kestra system flow), and a section in `../PLAN.md`. The base flow
(`../flows/webhook_sleep.yaml`) will gain a `concurrency:` block for this
workstream only.
