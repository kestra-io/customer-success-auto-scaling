"""Workstream 1 control loop: scale the Kestra worker Deployment off the
per-worker Prometheus queue gauges.

  observe   sum kestra_worker_job_pending / _running across all Ready worker pods
  decide    sustained-window policy (scale up / down / hold), gated by a cooldown
  act       patch deployments/scale (or just log, if DRY_RUN)
  log       one structured line per tick — the operator's live view

Scale UP   when `pending` stays >= threshold for a full up-window.
Scale DOWN when `pending == 0` AND `running <= ratio*capacity` for a full
           (longer) down-window.
Bounded by MIN/MAX replicas, moved by SCALE_STEP, and quiet for COOLDOWN_SECONDS
after any action.

Deliberately a small readable loop, not KEDA/HPA, so the logic is explicit and
every knob is a plain env var. See ./README.md for internals, ../README.md for
what/why/run.
"""
from __future__ import annotations

import logging
import time
from collections import deque
from dataclasses import dataclass

from .config import Config
from .k8s import K8sClient
from . import promscrape, statehttp


@dataclass
class Sample:
    """One observation. `ts` is time.monotonic() — a relative clock that never
    jumps backwards (NTP/DST), which is all the loop needs since every check is
    a duration."""
    ts: float
    pending: float
    running: float
    capacity: float


def _covered(samples: list[Sample], window_s: float, poll_s: float) -> bool:
    """True once the retained samples actually SPAN the window.

    Startup guard: for the first `window_s` after the process starts (or after
    the queue first goes non-empty) the history is only partially filled, and
    acting on it would let a single 15 s blip trigger a scale action. This
    blocks any decision until there is a full window of evidence. The `- poll_s`
    tolerates the gap before the next sample lands.
    """
    return bool(samples) and (samples[-1].ts - samples[0].ts) >= (window_s - poll_s)


class Controller:
    def __init__(self, cfg: Config, k8s: K8sClient) -> None:
        self.cfg = cfg
        self.k8s = k8s
        self.log = logging.getLogger("scaler")
        # The only mutable state. Losing it on a pod restart is safe: the loop
        # can't act until it rebuilds a full window (_covered), and
        # last_action_ts = 0.0 means it is not wedged in a cooldown.
        self.history: deque[Sample] = deque()
        self.last_action_ts = 0.0
        # Keep enough history for the longest window plus a margin.
        self._retain_s = max(cfg.scale_up_window_s, cfg.scale_down_window_s) + cfg.poll_interval_s * 2
        # Published by the /state HTTP endpoint (see statehttp.py). None until the
        # first successful tick.
        self.last_state: dict | None = None

    def state(self) -> dict | None:
        return self.last_state

    def _scrape_workers(self) -> tuple[float, float] | None:
        """Sum (pending, running) across every worker pod. `None` => this tick
        has no usable observation and must be skipped."""
        cfg = self.cfg
        if cfg.prometheus_url:
            urls = [cfg.prometheus_url]              # single-endpoint mode (compose / tests)
        else:
            try:
                urls = self.k8s.worker_metrics_urls(cfg.worker_metrics_port)
            except Exception as exc:  # noqa: BLE001 - transient API error
                self.log.warning("could not list worker pods: %s", exc)
                return None
        if not urls:
            self.log.warning("no Ready worker pods to scrape")
            return None

        pending = running = 0.0
        ok = 0                                       # count of endpoints that gave usable metrics
        for url in urls:
            try:
                text = promscrape.fetch(url, timeout=4.0)
            except Exception as exc:  # noqa: BLE001 - a rolling pod can refuse briefly
                self.log.debug("scrape %s failed: %s", url, exc)
                continue
            p = promscrape.sum_metric(text, cfg.metric_pending)
            r = promscrape.sum_metric(text, cfg.metric_running)
            if p is None or r is None:              # wrong metric names, or wrong endpoint
                self.log.warning("metrics %s/%s not found at %s",
                                 cfg.metric_pending, cfg.metric_running, url)
                continue
            pending += p
            running += r
            ok += 1
        if ok == 0:                                 # every endpoint failed -> skip the tick
            return None
        return pending, running

    def _decide(self, now: float, replicas: int) -> tuple[int | None, str]:
        """Pure policy: (target_replicas | None, human-readable reason).
        Touches no external state, so it is trivially unit-testable."""
        cfg = self.cfg

        # Cooldown is checked FIRST and short-circuits everything: after a scale
        # action we must wait long enough for a new worker pod to start and
        # register, or we'd see the still-high `pending` and stack another
        # scale-up before the first worker's threads come online.
        if now - self.last_action_ts < cfg.cooldown_s:
            return None, "cooldown"

        # Scale up: EVERY sample in the up-window must be at/over threshold
        # (a single tick below resets the case) -> requires a sustained signal.
        up = [s for s in self.history if now - s.ts <= cfg.scale_up_window_s]
        if (
            replicas < cfg.max_replicas
            and _covered(up, cfg.scale_up_window_s, cfg.poll_interval_s)
            and all(s.pending >= cfg.pending_scale_up_threshold for s in up)
        ):
            return min(replicas + cfg.scale_step, cfg.max_replicas), "sustained pending -> scale up"

        # Scale down: longer window (release capacity cautiously), and the test
        # is capacity-relative (running <= ratio * capacity) so the same rule
        # works at any replica count. Also requires an empty queue.
        dn = [s for s in self.history if now - s.ts <= cfg.scale_down_window_s]
        if (
            replicas > cfg.min_replicas
            and _covered(dn, cfg.scale_down_window_s, cfg.poll_interval_s)
            and all(s.pending == 0 and s.running <= cfg.running_scale_down_ratio * s.capacity for s in dn)
        ):
            return max(replicas - cfg.scale_step, cfg.min_replicas), "sustained low utilization -> scale down"

        return None, "hold"

    def tick(self) -> None:
        """One observe/decide/act/log cycle. Any early `return` means
        'do nothing this tick' — the safe default on partial failure."""
        cfg = self.cfg
        now = time.monotonic()

        scraped = self._scrape_workers()
        if scraped is None:
            return                                   # no observation -> no sample, no decision
        pending, running = scraped

        try:
            replicas = self.k8s.get_replicas()
        except Exception as exc:  # noqa: BLE001
            self.log.error("could not read %s replicas: %s", cfg.worker_deployment_name, exc)
            return                                   # never scale on a guessed count

        capacity = replicas * cfg.threads_per_worker
        self.history.append(Sample(now, pending, running, capacity))
        while self.history and now - self.history[0].ts > self._retain_s:
            self.history.popleft()                   # prune the sliding window

        target, reason = self._decide(now, replicas)

        if target is not None and target != replicas:   # idempotent: skip a no-op patch
            if cfg.dry_run:
                self.log.info("DRY_RUN would scale %s %d -> %d (%s)",
                              cfg.worker_deployment_name, replicas, target, reason)
            else:
                try:
                    self.k8s.set_replicas(target)
                    self.log.info("scaled %s %d -> %d (%s)",
                                  cfg.worker_deployment_name, replicas, target, reason)
                except Exception as exc:  # noqa: BLE001
                    # e.g. field-manager conflict with helm. Do NOT update
                    # last_action_ts -> the patch is retried next tick.
                    self.log.error("scale patch failed: %s", exc)
                    return
            self.last_action_ts = now
            decision = f"{replicas}->{target}"
        else:
            decision = reason

        util = (running / capacity) if capacity else 0.0

        # One line per tick == `kubectl logs -f deploy/worker-scaler`.
        self.log.info(
            "pending=%.1f running=%.1f replicas=%d capacity=%d util=%.0f%% decision=%s",
            pending, running, replicas, capacity, util * 100, decision,
        )

        # Publish for the /state endpoint (the trigger app's authoritative source).
        self.last_state = {
            "ts": time.time(),
            "pending": pending,
            "running": running,
            "worker_replicas": replicas,
            "threads_per_worker": cfg.threads_per_worker,
            "concurrent_capacity": capacity,
            "utilization": round(util, 3),
            "decision": decision,
            "min_replicas": cfg.min_replicas,
            "max_replicas": cfg.max_replicas,
        }

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
            except Exception as exc:  # noqa: BLE001 - belt & suspenders: one bad tick must not kill the loop
                self.log.exception("tick error: %s", exc)
            time.sleep(self.cfg.poll_interval_s)


def main() -> None:
    cfg = Config.from_env()
    logging.basicConfig(
        level=getattr(logging, cfg.log_level, logging.INFO),
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )
    k8s = K8sClient(cfg.namespace, cfg.worker_deployment_name, cfg.worker_label_selector)
    ctrl = Controller(cfg, k8s)
    statehttp.start(cfg.state_http_port, ctrl.state)   # non-blocking daemon thread
    ctrl.run()


if __name__ == "__main__":
    main()
