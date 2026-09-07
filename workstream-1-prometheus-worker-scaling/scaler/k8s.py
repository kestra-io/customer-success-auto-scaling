"""Thin Kubernetes helpers: read the worker Deployment's replica count and patch it."""
from __future__ import annotations

from kubernetes import client, config


class WorkerScaleClient:
    def __init__(self, namespace: str, deployment: str) -> None:
        config.load_incluster_config()
        self._apps = client.AppsV1Api()
        self.namespace = namespace
        self.deployment = deployment

    def get_replicas(self) -> int:
        scale = self._apps.read_namespaced_deployment_scale(self.deployment, self.namespace)
        return int(scale.spec.replicas or 0)

    def set_replicas(self, replicas: int) -> None:
        self._apps.patch_namespaced_deployment_scale(
            self.deployment,
            self.namespace,
            {"spec": {"replicas": int(replicas)}},
        )
