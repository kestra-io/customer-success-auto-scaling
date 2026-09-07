# Setup

## 1. Prerequisites

| Tool | Why | Check |
|---|---|---|
| Docker (≥ 6 GB RAM, 4 CPU for the VM) | runs `kind`, the trigger app, image builds | `docker info` |
| [`kind`](https://kind.sigs.k8s.io/) | local Kubernetes cluster | `kind version` |
| `kubectl` | talk to the cluster | `kubectl version --client` |
| `helm` (v3) | install the Kestra chart | `helm version` |
| `curl`, `jq` | flow import + smoke tests | — |

**Enterprise image (default):** a Kestra EE license and registry access.
```bash
docker login registry.kestra.io       # username = LICENSE_ID, password = LICENSE_FINGERPRINT
```

**No license?** Skip the login and set `KESTRA_IMAGE=kestra/kestra:v1.3.24` in
`.env` (step 2). This example uses no EE-only features.

## 2. Configure

```bash
cd initiatives/auto-scaling
cp .env.example .env
$EDITOR .env
```

Fill in, at minimum:

- `KESTRA_EE_LICENSE_ID`, `KESTRA_EE_LICENSE_FINGERPRINT`, `KESTRA_EE_LICENSE_KEY`
- `KESTRA_REGISTRY_USERNAME`, `KESTRA_REGISTRY_PASSWORD`

(or, for OSS, just set `KESTRA_IMAGE=kestra/kestra:v1.3.24` and leave the license/registry blank).

Everything else has a working default. Pin `HELM_CHART_VERSION` after checking
`helm search repo kestra/kestra --versions` (see step 3 note).

## 3. Bring it up (Kubernetes path)

```bash
make up
```

`make up` runs `scripts/up.sh`, which:

1. creates the `kind` cluster from `kind/cluster.yaml` (skips if it exists),
2. creates the `autoscaling` namespace,
3. creates the `registry.kestra.io` image-pull secret from `.env` (EE only),
4. `helm repo add kestra $HELM_REPO_URL && helm repo update`,
5. `helm upgrade --install` the chart with `helm/values.yaml` rendered through `envsubst`,
6. waits for every component + postgres to be Ready and the API to answer,
7. starts a background `kubectl port-forward` for `8080` / `8081` on `127.0.0.1`,
8. imports `flows/webhook_sleep.yaml` and fires one smoke webhook,
9. verifies the worker Prometheus metrics and records their exact names in `.state/metric-names.env`,
10. builds + starts the trigger app (`app/`),
11. prints the URLs.

> **Helm repo URL:** the `kestra-kubectl` skill uses `https://helm.kestra.io/`.

> **Slow first run:** the EE image is ~3.5 GB and the node pulls it once per
> component. On a cold node / slow link the first `make up` can sit in
> "waiting for the webserver" for **20–30 minutes**. The script timeouts
> (`helm --wait` 40m, rollout waits 40m) allow for this. To pre-warm the host
> cache: `docker pull $KESTRA_IMAGE` before `make up`.
> (`kind load docker-image` does *not* work here — Docker Desktop's containerd
> image store produces an archive kind's `ctr import` rejects — so the node
> pulls from the registry regardless.)

## Expected URLs

**Kestra UI**: [http://localhost:8080](http://localhost:8080) (user: `admin@example.com`, password: `Autoscaling123`)

**Trigger app**: [http://localhost:5173](http://localhost:5173)

**Other URLs:**
- Webhook — `http://localhost:8080/api/v1/main/executions/webhook/company.autoscaling/webhook_sleep/demo-key`
- Prometheus — <http://localhost:8081/prometheus>

## 4. Run the demo

1. Open the trigger app: [http://localhost:5173](http://localhost:5173)  
2. Leave the slider at the default (**8 / min**). After
   ~90 s the readout should show `running ≈ 2`, `pending ≈ 0`, `capacity = 4`
   (~50 %). If it sits high or low, adjust `RATE_BASELINE` in `.env` and
   `make app` again.
3. Click **Spike** (24 / min). Within a minute or two `pending` climbs and
   `running` pins at 4.
4. Click **Drop** (2 / min). `pending` drains, `running` falls below 1.

## 5. Workstream 1 — Prometheus + worker scaling

```bash
make scaler
kubectl get deploy -n autoscaling -w        # in another pane
kubectl logs -f deploy/worker-scaler -n autoscaling
```

`make scaler` builds the scaler image, `kind load`s it, renders its ConfigMap
from `.env` + `.state/metric-names.env`, and applies the RBAC + Deployment.

Now repeat step 4:

- **Spike** → after `SCALE_UP_WINDOW_SECONDS` the scaler logs `scale up 1->2`,
  the Deployment goes to `2/2`, `/stats` capacity rises to 8, `pending` stops
  growing.
- **Drop** → after `SCALE_DOWN_WINDOW_SECONDS` the scaler logs `scale down 2->1`.

## 6. Tear down

```bash
make down
```

Removes the trigger app compose project, deletes the scaler resources, kills the
port-forward, and `kind delete cluster`.

## 7. Compose quickstart (no cluster)

For a fast look at *just the problem*:

```bash
cd compose
cp .env.example .env      # license (or OSS image) + a couple of knobs
docker compose up --build
# open http://localhost:5173 , click "Spike", watch pending grow
```

See `compose/README.md` for exactly what this does and does not demonstrate
(it does **not** do live Kubernetes worker scaling).
