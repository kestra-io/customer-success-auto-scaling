"""Env-driven configuration for the worker scaler.

`Config` is the single source of truth for every knob. It is read **once** at
process start (`from_env()`); nothing re-reads the environment afterwards. To
change a value: edit the `worker-scaler-config` ConfigMap (rendered by
`scripts/deploy-scaler.sh` from `.env` + `.state/metric-names.env`) and restart
the Deployment.
"""
from __future__ import annotations

import os
from dataclasses import dataclass


# --- env parsers -----------------------------------------------------------------
# Each takes (name, default) and returns the default on a missing OR unparseable
# value, so a typo in the ConfigMap degrades to a safe default instead of
# crashing the control loop on startup.

def _s(name: str, default: str) -> str:
    return os.environ.get(name, default)


def _i(name: str, default: int) -> int:
    try:
        return int(os.environ[name])
    except (KeyError, ValueError):
        return default


def _f(name: str, default: float) -> float:
    try:
        return float(os.environ[name])
    except (KeyError, ValueError):
        return default


def _b(name: str, default: bool) -> bool:
    return os.environ.get(name, str(default)).strip().lower() in ("1", "true", "yes", "on")


@dataclass(frozen=True)  # frozen -> an immutable snapshot; pass it around freely
class Config:
    # --- metric source ---------------------------------------------------------
    # KESTRA EE exposes kestra_worker_job_* ONLY on each worker pod's own :8081
    # (no cross-service aggregation), so the loop lists worker pods by label and
    # scrapes each one.
    worker_label_selector: str
    worker_metrics_port: int
    # If non-empty, scrape THIS one URL every tick and never call the pod API
    # (used by the compose/ path and by unit tests). Empty => pod discovery.
    prometheus_url: str

    # --- metric names (overridable in case a Kestra build renames them) -------
    metric_pending: str
    metric_running: str
    metric_threads: str

    # --- scaling target ------------------------------------------------------
    namespace: str
    worker_deployment_name: str
    # Must equal the Helm `workerThreads`. The scaler cannot read the worker's
    # `--thread` arg, so this is how it knows per-replica capacity:
    #   capacity = replicas * threads_per_worker
    threads_per_worker: int

    # --- control-loop knobs (see controller.py) ----------------------------
    poll_interval_s: int
    scale_up_window_s: int
    scale_down_window_s: int
    pending_scale_up_threshold: float
    running_scale_down_ratio: float
    scale_step: int
    min_replicas: int
    max_replicas: int
    cooldown_s: int

    # --- ops ---------------------------------------------------------------
    dry_run: bool
    log_level: str
    # Serve the last computed observation as JSON at GET /state on this port so
    # the trigger app can show the AUTHORITATIVE multi-worker sum + replica count
    # (a host `kubectl port-forward svc/...` only ever hits one worker pod).
    # 0 disables the endpoint.
    state_http_port: int

    @classmethod
    def from_env(cls) -> "Config":
        ns = _s("NAMESPACE", "autoscaling")
        return cls(
            worker_label_selector=_s(
                "WORKER_LABEL_SELECTOR",
                "app.kubernetes.io/name=kestra,app.kubernetes.io/component=worker",
            ),
            worker_metrics_port=_i("WORKER_METRICS_PORT", 8081),
            prometheus_url=_s("PROMETHEUS_URL", ""),
            metric_pending=_s("METRIC_PENDING", "kestra_worker_job_pending"),
            metric_running=_s("METRIC_RUNNING", "kestra_worker_job_running"),
            metric_threads=_s("METRIC_THREADS", "kestra_worker_job_thread"),
            namespace=ns,
            worker_deployment_name=_s("WORKER_DEPLOYMENT_NAME", "kestra-worker"),
            threads_per_worker=_i("THREADS_PER_WORKER", 4),
            poll_interval_s=_i("POLL_INTERVAL_SECONDS", 15),
            scale_up_window_s=_i("SCALE_UP_WINDOW_SECONDS", 60),
            scale_down_window_s=_i("SCALE_DOWN_WINDOW_SECONDS", 180),
            pending_scale_up_threshold=_f("PENDING_SCALE_UP_THRESHOLD", 1.0),
            running_scale_down_ratio=_f("RUNNING_SCALE_DOWN_RATIO", 0.5),
            scale_step=_i("SCALE_STEP", 1),
            min_replicas=_i("MIN_REPLICAS", 1),
            max_replicas=_i("MAX_REPLICAS", 2),
            cooldown_s=_i("COOLDOWN_SECONDS", 90),
            dry_run=_b("DRY_RUN", False),
            log_level=_s("LOG_LEVEL", "INFO").upper(),
            state_http_port=_i("STATE_HTTP_PORT", 8080),
        )
