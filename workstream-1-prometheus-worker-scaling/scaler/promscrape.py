"""Minimal Prometheus text-exposition-format helpers (stdlib only)."""
from __future__ import annotations

import re
import urllib.request

_SAMPLE = re.compile(
    r"^(?P<name>[a-zA-Z_:][a-zA-Z0-9_:]*)(?:\{[^}]*\})?\s+(?P<value>-?(?:[0-9.]+(?:[eE][-+]?[0-9]+)?|Inf|NaN))\s*$"
)


def fetch(url: str, timeout: float = 4.0) -> str:
    with urllib.request.urlopen(url, timeout=timeout) as resp:  # noqa: S310 (trusted in-cluster URL)
        if resp.status != 200:
            raise RuntimeError(f"prometheus HTTP {resp.status}")
        return resp.read().decode("utf-8", "replace")


def sum_metric(text: str, name: str) -> float | None:
    """Sum every series that shares this base metric name. None if the name is absent.

    Summing makes the signal independent of how many worker replicas are reporting.
    Ignores Micrometer's `_created` / `_bucket` companion series.
    """
    total = 0.0
    seen = False
    for line in text.splitlines():
        if not line or line[0] == "#":
            continue
        m = _SAMPLE.match(line)
        if not m or m.group("name") != name:
            continue
        raw = m.group("value")
        if raw in ("NaN", "Inf", "-Inf"):
            continue
        total += float(raw)
        seen = True
    return total if seen else None
