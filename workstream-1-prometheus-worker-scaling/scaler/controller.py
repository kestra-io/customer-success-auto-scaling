"""Workstream 1: scale the Kestra worker Deployment off Prometheus queue metrics.

Scale UP   when `pending` stays >= threshold for a sustained window.
Scale DOWN when `running` stays <= ratio * capacity AND `pending` == 0 for a
           longer sustained window.
Respects MIN/MAX replicas, a fixed step, and a cooldown after any action.

In EE there is no cross-service metric aggregation, so the loop lists the
worker pods and scrapes each pod's own :8081/prometheus, then sums.

This is deliberately a small, readable control loop rather than KEDA/HPA so the
logic is explicit and every knob is a plain env var.
"""
from __future__ import annotations

import logging
import time
from collections import deque
from dataclasses import dataclass

from .config import Config
from .k8s import K8sClient
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
    def __init__(self, cfg: Config, k8s: K8sClient) -> None:
        self.cfg = cfg
        self.k8s = k8s
        self.log = logging.getLogger("scaler")
        self.history: deque[Sample] = deque()
        self.last_action_ts = 0.0
        self._retain_s = max(cfg.scale_up_window_s, cfg.scale_down_window_s) + cfg.poll_interval_s * 2

    def _scrape_workers(self) -> tuple[float, float] | None:
        """Sum pending + running across every worker pod. None if nothing scrapeable."""
        cfg = self.cfg
        if cfg.prometheus_url:
            urls = [cfg.prometheus_url]
        else:
            try:
                urls = self.k8s.worker_metrics_urls(cfg.worker_metrics_port)
            except Exception as exc:  # noqa: BLE001
                self.log.warning("could not list worker pods: %s", exc)
                return None
        if not urls:
            self.log.warning("no Ready worker pods to scrape")
            return None

        pending = running = 0.0
        ok = 0
        for url in urls:
            try:
                text = promscrape.fetch(url, timeout=4.0)
            except Exception as exc:  # noqa: BLE001 - a rolling pod can refuse briefly
                self.log.debug("scrape %s failed: %s", url, exc)
                continue
            p = promscrape.sum_metric(text, cfg.metric_pending)
            r = promscrape.sum_metric(text, cfg.metric_running)
            if p is None or r is None:
                self.log.warning("metrics %s/%s not found at %s",
                                 cfg.metric_pending, cfg.metric_running, url)
                continue
            pending += p
            running += r
            ok += 1
        if ok == 0:
            return None
        return pending, running

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

        scraped = self._scrape_workers()
        if scraped is None:
            return
        pending, running = scraped

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
            "up_window=%ds down_window=%ds cooldown=%ds dry_run=%s selector=%r",
            self.cfg.worker_deployment_name, self.cfg.namespace, self.cfg.threads_per_worker,
            self.cfg.min_replicas, self.cfg.max_replicas, self.cfg.scale_up_window_s,
            self.cfg.scale_down_window_s, self.cfg.cooldown_s, self.cfg.dry_run,
            self.cfg.prometheus_url or self.cfg.worker_label_selector,
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
    k8s = K8sClient(cfg.namespace, cfg.worker_deployment_name, cfg.worker_label_selector)
    Controller(cfg, k8s).run()


if __name__ == "__main__":
    main()
