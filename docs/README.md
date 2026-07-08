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

Read these in order when setting up the cluster from scratch. See [system-architecture.md](docs/system-architecture.md) for the full architecture visualization. 

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

> **Note on KubeRay — not currently used in active research work.**
> The QQQ pipelines and snackonai run against independent per-model vLLM deployments, one small model per Spark (qwen-3b / smollm-1b on Spark 1, gemma-2b / falcon-3b on Spark 2 — see [`docs/qqq/qqq-integration.md`](docs/qqq/qqq-integration.md)), not a single Ray-coordinated cluster. KubeRay and the tensor-parallel RayCluster setup in `kuberay-setup.md` and `vllm-setup.md` are kept in this repo as a reference setup path, not as the currently-deployed architecture.
>
> **When you'd actually reach for this instead:**
> - Hosting **one large model** (e.g. Qwen3-235B-A22B, Nemotron-3-Super-120B, or a quantized 70B+ model) that doesn't fit in a single Spark's 128GB unified memory and needs to be split via tensor parallelism across both Sparks' combined 256GB.
> - Any workload where you need **one model, higher throughput/quality**, rather than **several small models running independently** for comparison or ensembling — which is the shape of the current QQQ/snackonai work.
> - If a future project needs a model bigger than ~100-120B parameters, this is the setup path to come back to.

### Part 3 — Applied pipelines (current work)

| Document | What it covers |
|------|----------------|
| [docs/snack/snackonai-integration.md](docs/snackonai/snackonai-integration.md) | snackonai Telegram research bot: agent pipeline, Dockerization, Helm deployment, how it was integrated into the cluster |
| [docs/qqq/qqq-integration.md](docs/qqq/qqq-integration.md) | QQQ trading signal pipelines: models used, offline/real-time architecture, how each model was installed and registered, training/eval integration |

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

### Placeholders in `script.sh` — what you need to find yourself

The script fails fast with a clear error if any of these are left unfilled, but it doesn't know the *values* for your environment — you have to look each of these up before running it. None of these ship with a working default because they're either environment-specific (your network, your nodes) or credentials that shouldn't live in a committed file.

| Placeholder | What it is | Why it's needed | Where to find it |
|---|---|---|---|
| `PLACEHOLDER_SPARK1_IP` | Static LAN IP for Spark 1 (master) | k3s server, all other nodes and services address the control plane by this IP; it must not change between reboots | Pick an unused IP on your LAN, or check current IP with `ip a` |
| `PLACEHOLDER_SPARK2_IP` | Static LAN IP for Spark 2 (worker) | Same reasoning as above — Spark 2 must be reachable at a fixed address for k3s agent join and cross-node pod networking | Pick an unused IP on your LAN, or check current IP with `ip a` |
| `PLACEHOLDER_SPARK2_SSH_USER` | SSH username on Spark 2 | The script prints manual SSH instructions for steps that must run on Spark 2 (network config, k3s agent join) — needs the right login user | Whatever user was created during Spark 2's first-boot setup wizard |
| `PLACEHOLDER_LAN_CIDR` | Your local subnet in CIDR notation (e.g. `192.168.1.0/24`) | Used to scope the iptables ACCEPT rules so LAN traffic (SSH, k3s API, pod-to-pod) isn't blocked, without opening the node to the whole internet | Check your router's DHCP range, or run `ip route` and look at the subnet mask on your active interface |
| `PLACEHOLDER_GATEWAY_IP` | Default gateway / router IP | Required by `nmcli` when assigning the static IP — without it the node has no route out of the LAN | Usually `192.168.x.1` — check with `ip route \| grep default` before changing to static IP |
| `PLACEHOLDER_SPARK1_K8S_HOSTNAME` | Kubernetes node name for Spark 1 | Used in `nodeSelector` fields throughout (KubeRay operator pin, RayCluster head pod placement) — Kubernetes schedules by this name, not the LAN IP | Run `kubectl get nodes` **after** k3s is installed once, or it defaults to the machine's hostname (`hostname`) |
| `PLACEHOLDER_SPARK2_K8S_HOSTNAME` | Kubernetes node name for Spark 2 | Same reasoning — used to pin the RayCluster worker pod and Ray worker group to Spark 2 specifically | Run `kubectl get nodes` after Spark 2 joins, or `hostname` run on Spark 2 |
| `PLACEHOLDER_HUGGINGFACE_TOKEN` | HuggingFace API token | Required to download gated/rate-limited model weights (Qwen, Gemma, etc.) during Step 5; stored as a Kubernetes secret, never written to a pod spec directly | Generate at huggingface.co → Settings → Access Tokens |
| `PLACEHOLDER_VLLM_MODEL_ID` | HuggingFace model ID to serve (e.g. `Qwen/Qwen2.5-7B-Instruct`) | Tells vLLM which model to pull and serve on cluster startup | Depends on the project — pick based on what you're deploying (see `docs/qqq/qqq-integration.md` for the models used in the current research work) |

Two more values are **not** placeholder-gated but are worth double-checking before a real run:
- `GPU_MEMORY_UTIL` (default `0.85`) — fraction of GPU memory reserved for vLLM's KV cache; lower it if you're running other GPU workloads alongside vLLM.
- `MAX_NUM_SEQS` (default `4`) — max concurrent sequences vLLM will batch; raise it if you need more throughput and have memory headroom.

You'll also be prompted interactively mid-script for two things it can't automate: NGC registry login (Step 5, needed to pull `nvcr.io/nvidia/vllm`) and confirming Spark 2's manual k3s agent join (Step 3) — the script pauses and waits for `ENTER` at both points.

---

## Namespaces

| Namespace | Purpose |
|---|---|
| `kube-system` | k3s core (CoreDNS, metrics-server) |
| `gpu-operator` | NVIDIA GPU management |
| `kuberay-system` | KubeRay operator (installed, not actively used — see note above) |
| `monitoring` | Prometheus + Grafana |
| `core-services` | vLLM serving (per-model deployments) |
| `aibrix-system` | AIBrix routing layer |
| `qqq-data` | Offline QQQ pipeline (EOD data, CronJobs) |
| `fine-tune` | Real-time QQQ pipeline (RedPanda, 15-min ingestion) |
| `snackonai` | snackonai Telegram research bot, 6-agent pipeline |

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

# Check snackonai pipeline
kubectl get pods -n snackonai
kubectl logs -n snackonai -l app=composer-bot --tail=50
```
