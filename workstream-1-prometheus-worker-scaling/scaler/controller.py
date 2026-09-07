"""Workstream 1: scale the Kestra worker Deployment off Prometheus queue metrics.

Scale UP   when `pending` stays >= threshold for a sustained window.
Scale DOWN when `running` stays <= ratio * capacity AND `pending` == 0 for a
           longer sustained window.
Respects MIN/MAX replicas, a fixed step, and a cooldown after any action.

This is deliberately a small, readable control loop rather than KEDA/HPA so the
logic is explicit and every knob is a plain env var. KEDA's Prometheus scaler +
HPA `behavior` stabilization windows are the production-grade equivalent.
"""
from __future__ import annotations

import logging
import time
from collections import deque
from dataclasses import dataclass

from .config import Config
from .k8s import WorkerScaleClient
from . import promscrape


@dataclass
class Sample:
    ts: float
    pending: float
    running: float
    capacity: float


def _covered(samples: list[Sample], window_s: float, poll_s: float) -> bool:
    """True once the retained samples actually span the window (guards startup)."""
    return bool(samples) and (samples[-1].ts - samples[0].ts) >= (window_s - poll_s)


class Controller:
    def __init__(self, cfg: Config, k8s: WorkerScaleClient) -> None:
        self.cfg = cfg
        self.k8s = k8s
        self.log = logging.getLogger("scaler")
        self.history: deque[Sample] = deque()
        self.last_action_ts = 0.0
        self._retain_s = max(cfg.scale_up_window_s, cfg.scale_down_window_s) + cfg.poll_interval_s * 2

    def _decide(self, now: float, replicas: int) -> tuple[int | None, str]:
        cfg = self.cfg
        if now - self.last_action_ts < cfg.cooldown_s:
            return None, "cooldown"

        up = [s for s in self.history if now - s.ts <= cfg.scale_up_window_s]
        if (
            replicas < cfg.max_replicas
            and _covered(up, cfg.scale_up_window_s, cfg.poll_interval_s)
            and all(s.pending >= cfg.pending_scale_up_threshold for s in up)
        ):
            return min(replicas + cfg.scale_step, cfg.max_replicas), "sustained pending -> scale up"

        dn = [s for s in self.history if now - s.ts <= cfg.scale_down_window_s]
        if (
            replicas > cfg.min_replicas
            and _covered(dn, cfg.scale_down_window_s, cfg.poll_interval_s)
            and all(s.pending == 0 and s.running <= cfg.running_scale_down_ratio * s.capacity for s in dn)
        ):
            return max(replicas - cfg.scale_step, cfg.min_replicas), "sustained low utilization -> scale down"

        return None, "hold"

    def tick(self) -> None:
        cfg = self.cfg
        now = time.monotonic()

        try:
            text = promscrape.fetch(cfg.prometheus_url, timeout=4.0)
        except Exception as exc:  # noqa: BLE001 - transient scrape failures are expected
            self.log.warning("scrape failed: %s", exc)
            return

        pending = promscrape.sum_metric(text, cfg.metric_pending)
        running = promscrape.sum_metric(text, cfg.metric_running)
        if pending is None or running is None:
            self.log.warning(
                "metrics not found (pending=%s running=%s) — check METRIC_* names against %s",
                cfg.metric_pending, cfg.metric_running, cfg.prometheus_url,
            )
            return

        try:
            replicas = self.k8s.get_replicas()
        except Exception as exc:  # noqa: BLE001
            self.log.error("could not read %s replicas: %s", cfg.worker_deployment_name, exc)
            return

        capacity = replicas * cfg.threads_per_worker
        self.history.append(Sample(now, pending, running, capacity))
        while self.history and now - self.history[0].ts > self._retain_s:
            self.history.popleft()

        target, reason = self._decide(now, replicas)

        if target is not None and target != replicas:
            if cfg.dry_run:
                self.log.info("DRY_RUN would scale %s %d -> %d (%s)",
                              cfg.worker_deployment_name, replicas, target, reason)
            else:
                try:
                    self.k8s.set_replicas(target)
                    self.log.info("scaled %s %d -> %d (%s)",
                                  cfg.worker_deployment_name, replicas, target, reason)
                except Exception as exc:  # noqa: BLE001
                    self.log.error("scale patch failed: %s", exc)
                    return
            self.last_action_ts = now
            decision = f"{replicas}->{target}"
        else:
            decision = reason

        self.log.info(
            "pending=%.1f running=%.1f replicas=%d capacity=%d util=%.0f%% decision=%s",
            pending, running, replicas, capacity,
            (running / capacity * 100) if capacity else 0.0, decision,
        )

    def run(self) -> None:
        self.log.info(
            "scaler up | deploy=%s ns=%s threads/worker=%d min=%d max=%d "
            "up_window=%ds down_window=%ds cooldown=%ds dry_run=%s prom=%s",
            self.cfg.worker_deployment_name, self.cfg.namespace, self.cfg.threads_per_worker,
            self.cfg.min_replicas, self.cfg.max_replicas, self.cfg.scale_up_window_s,
            self.cfg.scale_down_window_s, self.cfg.cooldown_s, self.cfg.dry_run, self.cfg.prometheus_url,
        )
        while True:
            try:
                self.tick()
            except Exception as exc:  # noqa: BLE001 - never let one bad tick kill the loop
                self.log.exception("tick error: %s", exc)
            time.sleep(self.cfg.poll_interval_s)


def main() -> None:
    cfg = Config.from_env()
    logging.basicConfig(
        level=getattr(logging, cfg.log_level, logging.INFO),
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )
    Controller(cfg, WorkerScaleClient(cfg.namespace, cfg.worker_deployment_name)).run()


if __name__ == "__main__":
    main()
