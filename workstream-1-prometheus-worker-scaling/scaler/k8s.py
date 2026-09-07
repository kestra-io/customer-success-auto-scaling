"""Kubernetes helpers: read/patch the worker Deployment scale, and list worker pod IPs."""
from __future__ import annotations

from kubernetes import client, config


class K8sClient:
    def __init__(self, namespace: str, deployment: str, worker_label_selector: str) -> None:
        config.load_incluster_config()
        self._apps = client.AppsV1Api()
        self._core = client.CoreV1Api()
        self.namespace = namespace
        self.deployment = deployment
        self.worker_label_selector = worker_label_selector

    def get_replicas(self) -> int:
        scale = self._apps.read_namespaced_deployment_scale(self.deployment, self.namespace)
        return int(scale.spec.replicas or 0)

    def set_replicas(self, replicas: int) -> None:
        self._apps.patch_namespaced_deployment_scale(
            self.deployment,
            self.namespace,
            {"spec": {"replicas": int(replicas)}},
        )

    def worker_metrics_urls(self, port: int) -> list[str]:
        """`http://<podIP>:<port>/prometheus` for every Ready worker pod."""
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
