# neural-control-plane

AI research platform running on a 2-node NVIDIA DGX Spark cluster. This repo contains infrastructure documentation, QQQ stock signal pipeline outputs, and research artifacts.

## Cluster at a glance

| Property | Value |
|---|---|
| Nodes | Spark 1 (`<SPARK1_IP>`) · Spark 2 (`<SPARK2_IP>`) |
| GPU | 2× NVIDIA GB10 Blackwell · 256 GB unified memory |
| Kubernetes | k3s v1.35.5 · containerd · ARM64 |
| Models served | Qwen2.5-7B-Instruct · Qwen2.5-3B-Instruct |
| Inference engine | vLLM 0.10.1.1 via KubeRay |

---

## Documentation index

Read these in order when setting up the cluster from scratch.

### Part 1 — Node setup

| Step | Document | What it covers |
|------|----------|----------------|
| 1 | [dgx-spark-setup.md](docs/dgx-spark-setup.md) | Hardware first-boot, static IPs, SSH, Docker config |
| 2 | [cuda-updates.md](docs/cuda-updates.md) | OS, CUDA, and driver updates via DGX Dashboard |
| 3 | [k3s-setup.md](docs/k3s-setup.md) | k3s install, worker join, GPU Operator, Helm, namespace structure |

### Part 2 — Model serving

| Step | Document | What it covers |
|------|----------|----------------|
| 4 | [kuberay-setup.md](docs/kuberay-setup.md) | KubeRay operator, RayCluster, cross-node networking |
| 5 | [vllm-setup.md](docs/vllm-setup.md) | vLLM deployment, tensor parallelism, HF token secret, verification |
| 6 | [aibrix-setup.md](docs/aibrix-setup.md) | AIBrix routing layer, ModelAdapters, multi-namespace isolation |
| 7 | [cluster-setup.md](docs/cluster-setup.md) | Full cluster overview, monitoring stack, Grafana, GPU metrics |

---

## Automated setup

To reproduce the full cluster from scratch on two fresh DGX Sparks, fill in your values and run:

```bash
git clone https://github.com/<YOUR_GITHUB_ORG>/neural-control-plane.git
cd neural-control-plane
bash scripts/script.sh \
  --spark1-ip <SPARK1_IP> \
  --spark2-ip <SPARK2_IP> \
  --spark2-user <SPARK2_SSH_USER> \
  --spark1-hostname <SPARK1_K8S_HOSTNAME> \
  --spark2-hostname <SPARK2_K8S_HOSTNAME> \
  --hf-token <HUGGINGFACE_TOKEN>
```

See [scripts/script.sh](scripts/script.sh) for all flags and what each step does. The script is idempotent — safe to re-run.

---

## Namespaces

| Namespace | Purpose |
|---|---|
| `kube-system` | k3s core (CoreDNS, metrics-server) |
| `gpu-operator` | NVIDIA GPU management |
| `kuberay-system` | KubeRay operator |
| `monitoring` | Prometheus + Grafana |
| `core-services` | vLLM + Ray cluster |
| `aibrix-system` | AIBrix routing layer |

---

## Quick commands

```bash
# Check cluster health
kubectl get nodes
kubectl get pods -A | grep -v Running

# Access Grafana
kubectl -n monitoring get secret monitoring-grafana \
  -o jsonpath="{.data.admin-password}" | base64 -d; echo
kubectl -n monitoring port-forward svc/monitoring-grafana 3000:80

# Test vLLM
HEAD=$(kubectl get pods -n core-services -l ray.io/node-type=head -o name | head -1)
kubectl exec -n core-services $HEAD -- curl -s http://localhost:8000/v1/models

# Check QQQ pipeline
kubectl get cronjobs -n qqq-data
kubectl get pods -n qqq-data --sort-by=.status.startTime | tail -5
```
