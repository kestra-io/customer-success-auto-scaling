"""Env-driven configuration for the worker scaler. Single source of truth for the knobs."""
from __future__ import annotations

import os
from dataclasses import dataclass


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


@dataclass(frozen=True)
class Config:
    prometheus_url: str
    metric_pending: str
    metric_running: str
    metric_threads: str

    namespace: str
    worker_deployment_name: str
    threads_per_worker: int

    poll_interval_s: int
    scale_up_window_s: int
    scale_down_window_s: int
    pending_scale_up_threshold: float
    running_scale_down_ratio: float
    scale_step: int
    min_replicas: int
    max_replicas: int
    cooldown_s: int

    dry_run: bool
    log_level: str

    @classmethod
    def from_env(cls) -> "Config":
        ns = _s("NAMESPACE", "autoscaling")
        return cls(
            prometheus_url=_s(
                "PROMETHEUS_URL",
                f"http://kestra.{ns}.svc:8081/prometheus",
            ),
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
        )
