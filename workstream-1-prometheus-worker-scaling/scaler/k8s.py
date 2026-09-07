"""Kubernetes access: read/patch the worker Deployment scale, and enumerate
worker pod scrape URLs.

All calls use the in-cluster ServiceAccount token (mounted by Kubernetes at
/var/run/secrets/kubernetes.io/serviceaccount). The Deployment must set
`serviceAccountName: worker-scaler`, bound to `../k8s/role.yaml`:
  deployments        get,list,watch
  deployments/scale  get,patch,update
  pods               get,list
"""
from __future__ import annotations

from kubernetes import client, config


class K8sClient:
    def __init__(self, namespace: str, deployment: str, worker_label_selector: str) -> None:
        config.load_incluster_config()          # SA token; fails outside a pod
        self._apps = client.AppsV1Api()
        self._core = client.CoreV1Api()
        self.namespace = namespace
        self.deployment = deployment
        self.worker_label_selector = worker_label_selector

    def get_replicas(self) -> int:
        """Current DESIRED replica count, via the `scale` subresource.

        Reading `scale` (not the full Deployment) returns `.spec.replicas`, which
        already reflects this scaler's own last `set_replicas` — so the control
        loop reasons about the value it just wrote, with no wait for pods. It
        also needs only `deployments/scale: get`, keeping the Role small.
        """
        scale = self._apps.read_namespaced_deployment_scale(self.deployment, self.namespace)
        return int(scale.spec.replicas or 0)

    def set_replicas(self, replicas: int) -> None:
        """Patch `.spec.replicas` on the `scale` subresource.

        Note: this makes the API server record a field-manager owning
        `.spec.replicas`, which later conflicts with `helm upgrade`'s
        server-side apply (see ../README.md "Operational gotcha").
        """
        self._apps.patch_namespaced_deployment_scale(
            self.deployment,
            self.namespace,
            {"spec": {"replicas": int(replicas)}},
        )

    def worker_metrics_urls(self, port: int) -> list[str]:
        """`http://<podIP>:<port>/prometheus` for every READY worker pod.

        Pod IPs are routable from inside the cluster, so no Service is needed for
        the scaler's own scraping. Filtering on the `Ready` condition skips a
        just-created worker whose :8081 isn't listening yet (keeps the sum
        honest and the logs quiet).
        """
        pods = self._core.list_namespaced_pod(
            self.namespace, label_selector=self.worker_label_selector
        )
        urls: list[str] = []
        for p in pods.items:
            ip = getattr(p.status, "pod_ip", None)
            if not ip:
                continue
            ready = any(
                c.type == "Ready" and c.status == "True"
                for c in (p.status.conditions or [])
            )
            if ready:
                urls.append(f"http://{ip}:{port}/prometheus")
        return urls
