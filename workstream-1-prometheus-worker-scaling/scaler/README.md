# `scaler/` — worker autoscaler internals

A ~330-line Python service that polls Kestra's per-worker queue metrics and
patches the `kestra-worker` Deployment's replica count up or down. It runs as a
single-replica Deployment inside the cluster (`../k8s/deployment.yaml`) with a
namespaced ServiceAccount (`../k8s/role.yaml`).

This document is about **how the code works**. For what it does and how to run
it, see `../README.md`.

---

## Module map

| File | Responsibility | Depends on |
|---|---|---|
| `config.py` | Parse env vars once into an immutable `Config` | stdlib only |
| `promscrape.py` | Fetch a Prometheus endpoint and sum a metric across its series | stdlib only (`urllib`, `re`) |
| `k8s.py` | Read/patch the Deployment scale; list worker pod scrape URLs | `kubernetes` client |
| `controller.py` | The control loop: observe → decide → act → log | the three above |
| `statehttp.py` | Serve the last tick's observation as JSON at `GET /state` | stdlib only (`http.server`) |
| `__init__.py` | Package marker | — |

Entry point: `python -m scaler.controller` → `controller.main()`
(`../Dockerfile` `CMD`).

```
main()
 ├─ Config.from_env()                      # snapshot env
 ├─ logging.basicConfig(level=cfg.log_level)
 ├─ K8sClient(ns, deployment, selector)    # load_incluster_config()
 ├─ statehttp.start(cfg.state_http_port, ctrl.state)   # daemon thread, GET /state
 └─ Controller(cfg, k8s).run()
       └─ loop forever:
            tick()            # one observe/decide/act cycle
            sleep(poll_interval_s)
```

---

## `config.py`

`Config` is a **frozen dataclass** — an immutable snapshot of the environment
taken at process start. Nothing re-reads env after `from_env()`. To change a
knob you edit the ConfigMap (`../../scripts/deploy-scaler.sh` renders it from
`.env` + `.state/metric-names.env`) and restart the Deployment.

Helpers `_s / _i / _f / _b` each take `(name, default)` and fall back to the
default on a missing or unparseable value — so a typo in the ConfigMap degrades
to the default rather than crashing the loop.

Field groups:

- **Metric source** — `worker_label_selector`, `worker_metrics_port`, and an
  optional `prometheus_url`. If `prometheus_url` is non-empty the loop scrapes
  that single URL and never talks to the pod API (used by the `compose/` path
  and by unit tests). Otherwise it discovers pods by label every tick.
- **Metric names** — `metric_pending / metric_running / metric_threads`.
  Defaults are the EE 1.3.24 names; `verify-metrics.sh` overrides them on the
  ConfigMap if a Kestra build renamed them.
- **Target** — `namespace`, `worker_deployment_name`, `threads_per_worker`.
  `threads_per_worker` must equal the Helm `workerThreads`; the scaler cannot
  read the worker's `--thread` argument, so this is how it knows per-replica
  capacity.
- **Control knobs** — windows, thresholds, step, bounds, cooldown (see
  `controller.py` below).
- **Ops** — `dry_run`, `log_level`.

---

## `promscrape.py`

Deliberately dependency-free — the container needs only the `kubernetes` client,
not an HTTP library or a Prometheus client.

### `fetch(url, timeout=4.0) -> str`

`urllib.request.urlopen` GET, raises on non-200, returns the body. The 4 s
timeout means one slow/hanging worker pod can't stall the whole tick for long.

### `sum_metric(text, name) -> float | None`

Line-by-line parse of the Prometheus text exposition format:

- skips blank lines and `#` comment/HELP/TYPE lines,
- matches `^<name>{optional labels} <value>$` with `_SAMPLE`,
- keeps only lines whose metric name is **exactly** `name` (so
  `kestra_worker_job_pending` does not also match
  `kestra_worker_job_pending_created`),
- skips `NaN` / `Inf` values,
- returns the **sum** of every matching series, or `None` if the name never
  appeared.

Summing matters for two reasons: a metric may be reported with per-flow /
per-tenant label sets (several series under one name), and — when the loop
scrapes several worker pods — each pod contributes its own series. `None` vs.
`0.0` is a real distinction: `0.0` means "worker reported the gauge and it's
zero", `None` means "this endpoint didn't expose the metric" (wrong name, or
scraped the webserver by mistake).

---

## `k8s.py`

`K8sClient` wraps two API groups. `config.load_incluster_config()` reads the
ServiceAccount token mounted at `/var/run/secrets/kubernetes.io/serviceaccount`
— so the container must run with `serviceAccountName: worker-scaler` and that SA
must be bound to `../k8s/role.yaml`.

### `get_replicas() -> int`

`read_namespaced_deployment_scale` — reads the **`scale` subresource**, not the
full Deployment. Two reasons:

1. it returns the *desired* `.spec.replicas`, which reflects the scaler's own
   last `set_replicas` immediately (no waiting for pods), so the control loop
   reasons about the value it just wrote;
2. it needs only `deployments/scale` `get`, keeping the Role minimal.

### `set_replicas(replicas)`

`patch_namespaced_deployment_scale` with `{"spec": {"replicas": n}}` — a
strategic-merge patch on the same subresource (`patch` verb). This is what
creates the field-manager ownership of `.spec.replicas` that later conflicts
with `helm upgrade` (see `../README.md` "Operational gotcha").

### `worker_metrics_urls(port) -> list[str]`

`list_namespaced_pod(label_selector=...)`, then for each pod keep it only if it
has a `pod_ip` **and** a `Ready` condition that is `"True"`, and return
`http://<podIP>:<port>/prometheus`. Filtering on `Ready` avoids scraping a
just-created worker that hasn't opened `:8081` yet (it would just be connection
refused, but skipping it keeps the logs clean and the sum honest).

Pod IPs are routable from inside the cluster, so no Service is needed for the
scaler's own scraping. (The `kestra-worker-metrics` Service exists only for the
host-side `:8082` port-forward the trigger app uses.)

---

## `controller.py`

### `Sample`

One observation: `(ts, pending, running, capacity)`. `ts` is a
`time.monotonic()` value — a relative clock that never jumps backwards on NTP
corrections or DST, which is all the loop needs since every comparison is a
duration.

### `_covered(samples, window_s, poll_s) -> bool`

`True` once the retained samples actually **span** the window —
`newest.ts - oldest.ts >= window_s - poll_s` (the `- poll_s` tolerates the gap
before the next sample lands). This is the startup guard: for the first
`window_s` after the process starts (or after the queue first goes non-empty)
the history is only partially filled, and acting on it would let a 15 s blip
trigger a scale-up. `_covered` blocks any decision until there's a full window
of evidence.

### `Controller` state

Only two mutable fields, both in memory:

| field | meaning |
|---|---|
| `history: deque[Sample]` | sliding window of observations, pruned each tick to `_retain_s = max(up_window, down_window) + 2·poll` |
| `last_action_ts: float` | monotonic time of the last scale patch; `0.0` = never |

Losing this state on a pod restart is safe: the loop simply can't act until it
has rebuilt a full window (`_covered`), and `last_action_ts = 0.0` means it
isn't wedged in a cooldown.

### `tick()` — one cycle

1. `now = time.monotonic()`.
2. `_scrape_workers()` → `(pending, running)` or `None`. `None` ⇒ **return
   early**: no sample recorded, no decision. Reasons it returns `None`: pod-list
   API error, zero Ready worker pods, or every scrape failed / lacked the
   metrics.
3. `k8s.get_replicas()`. On error ⇒ log and **return early** (don't guess).
4. `capacity = replicas × threads_per_worker`.
5. Append the `Sample`; pop samples older than `_retain_s` off the left.
6. `_decide(now, replicas)` → `(target | None, reason)`.
7. If `target` is set and differs from `replicas`:
   - `dry_run` ⇒ log `DRY_RUN would scale …`;
   - else `k8s.set_replicas(target)`; on patch error, log and return early
     *without* updating `last_action_ts` (so it retries next tick);
   - on success, set `last_action_ts = now`.
8. Emit one structured log line every tick — `pending`, `running`, `replicas`,
   `capacity`, `util%`, `decision` — this is the operator's live view
   (`kubectl logs -f deploy/worker-scaler`).

### `_decide(now, replicas)` — the policy

Order of checks:

1. **Cooldown** — if `now - last_action_ts < cooldown_s` ⇒ `(None, "cooldown")`.
   Nothing else is evaluated. `cooldown_s` must exceed the time for a new worker
   pod to start and register, otherwise the loop would see the still-high
   `pending` and stack a second scale-up before the first worker's threads come
   online.
2. **Scale up** — take the samples within `scale_up_window_s`; if
   `replicas < max_replicas` **and** `_covered(...)` **and** *every* sample has
   `pending >= pending_scale_up_threshold`, return
   `min(replicas + scale_step, max_replicas)`.
3. **Scale down** — take the samples within `scale_down_window_s`; if
   `replicas > min_replicas` **and** `_covered(...)` **and** *every* sample has
   `pending == 0` **and** `running <= running_scale_down_ratio × capacity`,
   return `max(replicas - scale_step, min_replicas)`.
4. Otherwise `(None, "hold")`.

Design choices:

- **Every sample must pass**, not the average — a single tick that breaks the
  condition resets the case for action. This makes both directions require a
  genuinely *sustained* signal and rejects transients.
- **Asymmetric windows** — `scale_down_window_s` is longer than
  `scale_up_window_s` by default (react fast to load, release capacity
  cautiously).
- **Scale-down is capacity-relative** — `running <= ratio × capacity`, not an
  absolute number, so the same 50 % rule works whether the pool is at 1 or 2
  replicas.
- **Bounded and stepped** — `min/max_replicas` clamp, `scale_step` caps how far
  one action moves (this demo uses 1 ⇄ 2, step 1).

### `run()`

Logs a one-line startup banner with the effective config, then loops forever:
`tick()` inside a `try/except` (a scrape or API blip logs a traceback but the
loop survives), then `sleep(poll_interval_s)`.

---

## Timing model

```
t0        process starts; history empty; last_action_ts = 0
t0..t+W   history filling; _covered() is False -> decision can only be "hold"
          (W = scale_up_window_s)
t+W       first window covered; if pending was >= threshold every tick -> scale up
t+W       last_action_ts = t+W ; next ~cooldown_s: decision is "cooldown"
          (new worker pod starts + registers during this window)
...       once cooldown ends and capacity relief shows in the metrics,
          decision returns to "hold"; if load drops, the scale_down_window_s
          + cooldown gate the way back down
```

All durations are env knobs; nothing is hard-coded.

---

## Failure model

Every outbound call is defensive and the fallback is always **"do nothing this
tick"**:

| failure | handling |
|---|---|
| pod-list API error | `_scrape_workers` logs a warning, returns `None`, tick returns early |
| all worker scrapes fail (rolling pods) | same |
| metric name absent at an endpoint | that endpoint skipped; if all skipped ⇒ `None` |
| `get_replicas` error | logged, tick returns early — never scales on a guessed count |
| `set_replicas` patch error (e.g. field-manager conflict) | logged; `last_action_ts` **not** updated ⇒ retried next tick |
| any unexpected exception in `tick()` | `run()` logs `tick error` with traceback and continues |

Consequence: a partial outage makes the scaler **stall at the current replica
count**, which is the safe default. It never scales to zero (min clamp) and
never thrashes (cooldown + sustained windows).

---

## Extending it

- **Scale on a different signal** — change `metric_pending` / `metric_running`
  via env, or add a metric in `_scrape_workers` and a term in `_decide`.
  `promscrape.sum_metric` already handles multi-series names.
- **More than 1 ⇄ 2** — raise `MAX_REPLICAS` and optionally `SCALE_STEP`; the
  math and history logic are replica-count-agnostic.
- **Scrape a fixed endpoint** (no pod API / no RBAC on pods) — set
  `PROMETHEUS_URL` to a single aggregating URL; `worker_metrics_urls` is then
  never called.
- **`GET /state`** (`statehttp.py`) — each `tick()` publishes its observation to
  `Controller.last_state`; a daemon `http.server` thread serves it as JSON on
  `STATE_HTTP_PORT` (503 until the first tick). `svc/worker-scaler` +
  `scripts/portforward.sh` (`:8083`) expose it so the trigger app reads the
  authoritative cross-pod sum + real replica count instead of a single-pod
  `:8082` scrape (a `port-forward svc/...` pins to one worker pod). To add a
  field, extend the dict in `tick()` — no schema, the app treats keys as
  optional.
- **Unit tests** — `_decide`, `_covered`, and `promscrape.sum_metric` are pure
  functions of their inputs; construct `Sample`s with fake `ts` values and a
  `Controller(cfg, k8s=None)` (nothing in `_decide` touches `k8s`).
