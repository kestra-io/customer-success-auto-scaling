"""Minimal Prometheus text-exposition-format helpers (stdlib only).

The container ships with just the `kubernetes` client — no HTTP library and no
Prometheus client. These two functions are all the scraping the scaler needs.
"""
from __future__ import annotations

import re
import urllib.request

# One data line of the text exposition format:
#   <name>{label="v",...} <value>       (labels optional)
# value: int/float, optional scientific notation, or Inf / NaN.
_SAMPLE = re.compile(
    r"^(?P<name>[a-zA-Z_:][a-zA-Z0-9_:]*)(?:\{[^}]*\})?\s+(?P<value>-?(?:[0-9.]+(?:[eE][-+]?[0-9]+)?|Inf|NaN))\s*$"
)


def fetch(url: str, timeout: float = 4.0) -> str:
    """GET `url` and return the body. Raises on non-200 or timeout.

    The short timeout means one slow/hanging worker pod can stall a tick for at
    most ~4 s rather than indefinitely.
    """
    with urllib.request.urlopen(url, timeout=timeout) as resp:  # noqa: S310 - trusted in-cluster URL
        if resp.status != 200:
            raise RuntimeError(f"prometheus HTTP {resp.status}")
        return resp.read().decode("utf-8", "replace")


def sum_metric(text: str, name: str) -> float | None:
    """Sum every series whose metric name is exactly `name`. `None` if absent.

    - Exact-name match, so `kestra_worker_job_pending` does NOT also pick up
      `kestra_worker_job_pending_created` (Micrometer's companion series).
    - Sums across series: one name can have several label sets (per-flow /
      per-tenant), and when the caller scrapes several worker pods each pod adds
      its own series.
    - `None` vs `0.0` is meaningful: `0.0` = "the gauge is present and zero";
      `None` = "this endpoint never exposed the metric" (wrong name, or the
      wrong endpoint was scraped).
    """
    total = 0.0
    seen = False
    for line in text.splitlines():
        if not line or line[0] == "#":          # blank / HELP / TYPE lines
            continue
        m = _SAMPLE.match(line)
        if not m or m.group("name") != name:
            continue
        raw = m.group("value")
        if raw in ("NaN", "Inf", "-Inf"):        # not summable
            continue
        total += float(raw)
        seen = True
    return total if seen else None
