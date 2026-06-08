# k3s Cluster Setup

## Overview

This document covers installing and configuring a 2-node k3s Kubernetes cluster across both DGX Sparks, with Spark 1 as the control plane (master) and Spark 2 as the worker node.

## Architecture

```
Spark 1 (spark-720e) — Control Plane / Master
  IP: 192.168.86.30
  Role: k3s server, API server, etcd, scheduler, kubelet

Spark 2 (spark-7229) — Worker Node
  IP: 192.168.86.26
  Role: k3s agent, kubelet + containerd only
```

## Prerequisites

- Both Sparks on the same network with static IPs assigned
- SSH access from Spark 1 to Spark 2
- Docker configured with cgroup v2 settings (see dgx-spark-setup.md)

## Installation

### Step 1 — Install k3s on Spark 1 (Master)

Run on **Spark 1**:

```bash
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--write-kubeconfig-mode 644 --disable=traefik" sh -
```

> **Note:** We use `--disable=traefik` because Traefik ingress is not needed for this setup. We do NOT use `--docker` flag — k3s runs on containerd natively.

### Step 2 — Configure kubectl

```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
echo "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml" >> ~/.bashrc
```

### Step 3 — Get the Join Token

```bash
sudo cat /var/lib/rancher/k3s/server/node-token
```

Save this token — it is needed to join Spark 2 to the cluster.

### Step 4 — Join Spark 2 as Worker

Run on **Spark 2** (via SSH from Spark 1):

```bash
curl -sfL https://get.k3s.io | \
  K3S_URL=https://192.168.86.30:6443 \
  K3S_TOKEN=<TOKEN_FROM_SPARK1> \
  sh -
```

### Step 5 — Assign Worker Role Label

By default Spark 2 shows role `<none>`. Assign the worker role:

```bash
kubectl label node spark-7229 node-role.kubernetes.io/worker=worker
```

## Verification

```bash
# Both nodes should show Ready
kubectl get nodes

# Expected output:
# NAME         STATUS   ROLES                  AGE   VERSION
# spark-720e   Ready    control-plane,master   Xm    v1.35.5+k3s1
# spark-7229   Ready    worker                 Xm    v1.35.5+k3s1
```

```bash
# Check container runtime — should show containerd
kubectl get nodes -o wide
# CONTAINER-RUNTIME column should show: containerd://2.2.3-k3s1
```

## Uninstalling k3s

If reinstallation is needed:

```bash
# On Spark 1 (master)
/usr/local/bin/k3s-uninstall.sh

# On Spark 2 (worker)
/usr/local/bin/k3s-agent-uninstall.sh
```

> **Warning:** Uninstalling k3s leaves iptables rules that can block SSH. After uninstall, flush iptables on Spark 2:
> ```bash
> sudo iptables -F && sudo iptables -X
> sudo iptables -P INPUT ACCEPT
> sudo iptables -P FORWARD ACCEPT
> sudo iptables -P OUTPUT ACCEPT
> ```

## Installing Helm

Helm is required for installing GPU Operator, monitoring stack, and KubeRay:

```bash
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
helm version
```

## NVIDIA GPU Operator

Install after k3s is running to make GPUs visible to Kubernetes:

```bash
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia
helm repo update

helm install gpu-operator nvidia/gpu-operator \
  --namespace gpu-operator \
  --create-namespace
```

Verify GPUs are visible:

```bash
kubectl get nodes -o json | grep -i "nvidia.com/gpu.family"
# Should show: "nvidia.com/gpu.family": "blackwell"

kubectl get nodes -o json | grep "nvidia.com/gpu\":"
# Should show: "nvidia.com/gpu": "1" for each node
```

## Key Architecture Notes

- k3s uses **Flannel** as the default CNI (Container Network Interface)
- Flannel does not support RDMA/RoCE — NCCL falls back to TCP for cross-node GPU communication
- Future migration to RKE2 + Cilium CNI will enable full RDMA support over ConnectX-7
- k3s control plane services (CoreDNS, metrics-server) run as Deployments, not DaemonSets — this is by design for lightweight setups
- GPU-related services (device plugin, DCGM exporter) correctly run as DaemonSets on both nodes

## Namespace Structure

```
kube-system       — k3s core services (CoreDNS, metrics-server)
gpu-operator      — NVIDIA GPU management
kuberay-system    — KubeRay operator
monitoring        — Prometheus + Grafana
core-services     — vLLM + Ray cluster
aibrix-system     — AIBrix control plane
```
