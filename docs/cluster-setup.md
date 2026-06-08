# Cluster Setup

## Overview

This document covers the complete 2-node DGX Spark Kubernetes cluster setup including monitoring, namespace structure, and overall architecture.

## Cluster Specifications

| Property | Value |
|---|---|
| Nodes | 2 (Spark 1 master, Spark 2 worker) |
| Kubernetes | k3s v1.35.5+k3s1 |
| Container runtime | containerd 2.2.3-k3s1 |
| Architecture | ARM64 (aarch64) |
| GPU | 2× NVIDIA GB10 Blackwell |
| Total GPU memory | 256GB unified |
| Total CPU cores | 40 (20 per Spark) |
| Total memory | ~256GB system RAM |
| Interconnect | ConnectX-7 RDMA via QSFP cable |
| CNI | Flannel (default k3s) |
| OS | Ubuntu 24.04.4 LTS (DGX OS) |

## Node Information

```
NAME         STATUS   ROLES                  IP              CONTAINER-RUNTIME
spark-720e   Ready    control-plane,master   192.168.86.30   containerd://2.2.3-k3s1
spark-7229   Ready    worker                 192.168.86.26   containerd://2.2.3-k3s1
```

## Full Namespace Structure

```
kube-system         — k3s core (CoreDNS, metrics-server, local-path-provisioner)
gpu-operator        — NVIDIA GPU management and monitoring
kuberay-system      — KubeRay operator
monitoring          — Prometheus, Grafana, AlertManager
core-services       — vLLM + Ray cluster (primary AI inference)
aibrix-system       — AIBrix control plane
envoy-gateway-system — Envoy Gateway (AIBrix dependency)
```

## Workload Distribution

### DaemonSets (run on every node)

| DaemonSet | Namespace | Purpose |
|---|---|---|
| gpu-feature-discovery | gpu-operator | Discovers GPU capabilities per node |
| nvidia-container-toolkit-daemonset | gpu-operator | GPU container runtime on each node |
| nvidia-dcgm-exporter | gpu-operator | GPU metrics collection per node |
| nvidia-device-plugin-daemonset | gpu-operator | Makes GPUs available to Kubernetes |
| nvidia-operator-validator | gpu-operator | Validates GPU operator on each node |
| monitoring-prometheus-node-exporter | monitoring | System metrics collection per node |

### Deployments (stateless, single instance)

| Deployment | Namespace | Purpose |
|---|---|---|
| coredns | kube-system | Cluster DNS |
| metrics-server | kube-system | CPU/memory metrics for autoscaling |
| local-path-provisioner | kube-system | Local storage provisioning |
| gpu-operator | gpu-operator | GPU operator controller |
| kuberay-operator | kuberay-system | Manages Ray clusters |
| monitoring-grafana | monitoring | Metrics visualization |
| aibrix-controller-manager | aibrix-system | AIBrix resource management |
| aibrix-gateway-plugins | aibrix-system | Request routing plugins |
| aibrix-gpu-optimizer | aibrix-system | GPU utilization optimization |
| aibrix-metadata-service | aibrix-system | Model metadata storage |
| aibrix-redis-master | aibrix-system | Routing cache |

### StatefulSets (stateful, persistent storage)

| StatefulSet | Namespace | Purpose |
|---|---|---|
| prometheus | monitoring | Metrics storage (persistent) |
| alertmanager | monitoring | Alert management (persistent) |

### Custom Resources (Ray)

| Resource | Namespace | Purpose |
|---|---|---|
| RayCluster/vllm-cluster | core-services | 2-node Ray cluster for vLLM |

## Monitoring Stack

### Installation

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

kubectl create namespace monitoring

helm install monitoring prometheus-community/kube-prometheus-stack \
  --namespace monitoring
```

### Components Installed

- **Prometheus** — scrapes and stores metrics from all namespaces
- **Grafana** — visualization dashboard
- **AlertManager** — alert routing and management
- **Node Exporter** — system metrics (CPU, memory, disk) per node
- **kube-state-metrics** — Kubernetes object metrics

### Accessing Grafana

```bash
# Get admin password
kubectl --namespace monitoring get secrets monitoring-grafana \
  -o jsonpath="{.data.admin-password}" | base64 -d; echo

# Port forward to access dashboard
kubectl --namespace monitoring port-forward \
  $(kubectl --namespace monitoring get pod \
    -l "app.kubernetes.io/name=grafana" -oname) 3000
```

Then open `http://localhost:3000` in browser. Login: `admin` / <password from above>

### Key Dashboards

- **Kubernetes / Compute Resources / Cluster** — overall CPU/memory usage
- **Kubernetes / Nodes** — per-node resource usage
- **Node Exporter / Nodes** — detailed system metrics

### GPU Metrics

GPU metrics are automatically collected via DCGM Exporter (installed by GPU Operator) and scraped by Prometheus. Available metrics include:

- `DCGM_FI_DEV_GPU_UTIL` — GPU utilization %
- `DCGM_FI_DEV_MEM_COPY_UTIL` — Memory bandwidth utilization
- `DCGM_FI_DEV_FB_FREE` — Free GPU memory
- `DCGM_FI_DEV_FB_USED` — Used GPU memory
- `DCGM_FI_DEV_POWER_USAGE` — Power draw

## Cross-Node Networking

### Validating Pod-to-Pod Communication

```bash
kubectl run test-spark1 \
  --image=busybox \
  --overrides='{"spec":{"nodeSelector":{"kubernetes.io/hostname":"spark-720e"}}}' \
  --command -- sleep 3600

kubectl run test-spark2 \
  --image=busybox \
  --overrides='{"spec":{"nodeSelector":{"kubernetes.io/hostname":"spark-7229"}}}' \
  --command -- sleep 3600

kubectl get pods -o wide  # get Spark 2 pod IP

kubectl exec test-spark1 -- ping -c 4 <SPARK2_POD_IP>

kubectl delete pod test-spark1 test-spark2
```

## GPU Verification

```bash
# Verify both GPUs are visible to Kubernetes
kubectl get nodes -o json | grep -A2 "nvidia.com/gpu.family"

# Expected:
# "nvidia.com/gpu.family": "blackwell"  (on both nodes)
# "nvidia.com/gpu.product": "NVIDIA-GB10"
# "nvidia.com/gpu.count": "1"           (per node)
# "rdma.available": "true"              (RDMA capable)
```

## Future Architecture Considerations

### k3s → RKE2 Migration

The current k3s setup uses Flannel CNI which does not support RDMA/RoCE. A future migration to RKE2 with Cilium CNI will:

- Enable RDMA-aware networking for NCCL cross-node GPU communication
- Provide proper scheduler extender support for GPU-utilization-aware scheduling
- Enable CIS hardening for production security

### Cilium Service Mesh

Future addition of Cilium as both CNI and service mesh will:

- Replace Flannel with RDMA/RoCE-capable networking
- Enable both nodes to act as one unified machine
- Provide eBPF-based network policies and observability via Hubble UI
- Improve NCCL performance for tensor parallel workloads

### MIG (Multi-Instance GPU) Configuration

Future MIG configuration will allow GPU slicing for multi-tenant workloads:

```yaml
mig-configs:
  my-config:
  - devices: [0]
    mig-enabled: true
    mig-devices:
      "3g.40gb": 2   # large slices for vLLM
      "1g.10gb": 4   # small slices for agents
```
