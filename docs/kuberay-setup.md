# KubeRay Setup

## Overview

This document covers installing KubeRay and deploying a 2-node Ray cluster across both DGX Sparks for distributed AI inference.

## What is KubeRay

KubeRay is a Kubernetes operator that manages Ray clusters inside Kubernetes. It enables distributed AI workloads to span multiple nodes by coordinating Ray head and worker pods.

For this setup, KubeRay allows vLLM to use tensor parallelism across both Sparks — splitting large models across 256GB of combined GPU memory.

## ARM64 Architecture Note

> **Critical:** The standard `rayproject/ray` Docker image is **x86 only** and will not run on DGX Spark's ARM64 architecture. Always use `nvcr.io/nvidia/vllm:25.09-py3` as the Ray image — it is ARM64-native and has Ray built in.
>
> Ray version inside the NVIDIA vLLM image: **2.49.2**

## Prerequisites

- k3s cluster running with both nodes Ready
- NVIDIA GPU Operator installed
- Helm installed
- NVIDIA NGC credentials (for pulling `nvcr.io/nvidia/vllm` image)

## Installation

### Step 1 — Install KubeRay Operator

```bash
helm repo add kuberay https://ray-project.github.io/kuberay-helm/
helm repo update

helm install kuberay-operator kuberay/kuberay-operator \
  --namespace kuberay-system \
  --create-namespace \
  --set nodeSelector."kubernetes\\.io/hostname"=spark-720e
```

> **Note:** We pin the KubeRay operator to Spark 1 using nodeSelector. The operator itself only needs to run on the master node.

Verify:
```bash
kubectl get pods -n kuberay-system
# kuberay-operator pod should show Running
```

### Step 2 — NGC Registry Login

Required to pull the NVIDIA vLLM image:

```bash
docker login nvcr.io
# Username: $oauthtoken
# Password: <your NGC API key>
```

Get an NGC API key at ngc.nvidia.com → Setup → Generate Personal Key → select NGC Catalog.

### Step 3 — Validate Cross-Node Networking

Before deploying the Ray cluster, verify pods on different nodes can communicate:

```bash
# Create test pods on each node
kubectl run test-spark1 \
  --image=busybox \
  --overrides='{"spec":{"nodeSelector":{"kubernetes.io/hostname":"spark-720e"}}}' \
  --command -- sleep 3600

kubectl run test-spark2 \
  --image=busybox \
  --overrides='{"spec":{"nodeSelector":{"kubernetes.io/hostname":"spark-7229"}}}' \
  --command -- sleep 3600

# Get Spark 2 pod IP
kubectl get pods -o wide

# Ping from Spark 1 pod to Spark 2 pod
kubectl exec test-spark1 -- ping -c 4 <SPARK2_POD_IP>

# Cleanup
kubectl delete pod test-spark1 test-spark2
```

## Deploy RayCluster

Create a RayCluster using the NVIDIA vLLM image for both head and worker:

```bash
kubectl apply -f - <<EOF
apiVersion: ray.io/v1
kind: RayCluster
metadata:
  name: vllm-cluster
  namespace: core-services
spec:
  rayVersion: '2.49.2'
  headGroupSpec:
    rayStartParams:
      dashboard-host: '0.0.0.0'
      num-gpus: '1'
    template:
      spec:
        nodeSelector:
          kubernetes.io/hostname: spark-720e
        containers:
        - name: ray-head
          image: nvcr.io/nvidia/vllm:25.09-py3
          command: ["/bin/bash", "-c"]
          args:
          - |
            ray start --head \
              --dashboard-host=0.0.0.0 \
              --num-gpus=1 \
              --block &
            RAY_PID=$!
            echo "Waiting for Ray to be ready..."
            sleep 30
            echo "Starting vLLM..."
            python3 -m vllm.entrypoints.openai.api_server \
              --model Qwen/Qwen2.5-7B-Instruct \
              --tensor-parallel-size 2 \
              --distributed-executor-backend ray \
              --host 0.0.0.0 \
              --port 8000 \
              --gpu-memory-utilization 0.85 \
              --max-num-seqs 4
          env:
          - name: HF_TOKEN
            valueFrom:
              secretKeyRef:
                name: hf-token
                key: token
          resources:
            limits:
              nvidia.com/gpu: "1"
              memory: "100Gi"
            requests:
              nvidia.com/gpu: "1"
              memory: "100Gi"
          ports:
          - containerPort: 8000
          - containerPort: 8265
  workerGroupSpecs:
  - replicas: 1
    minReplicas: 1
    maxReplicas: 1
    groupName: worker-group
    rayStartParams:
      num-gpus: '1'
    template:
      spec:
        nodeSelector:
          kubernetes.io/hostname: spark-7229
        containers:
        - name: ray-worker
          image: nvcr.io/nvidia/vllm:25.09-py3
          command: ["/bin/bash", "-c"]
          args:
          - |
            ray start \
              --address=vllm-cluster-head-svc.core-services.svc.cluster.local:6379 \
              --num-gpus=1 \
              --block
          env:
          - name: HF_TOKEN
            valueFrom:
              secretKeyRef:
                name: hf-token
                key: token
          resources:
            limits:
              nvidia.com/gpu: "1"
              memory: "100Gi"
            requests:
              nvidia.com/gpu: "1"
              memory: "100Gi"
EOF
```

## Verification

```bash
# Both pods should show Running
kubectl get pods -n core-services

# Verify Ray sees both nodes and both GPUs
kubectl exec -n core-services <HEAD_POD_NAME> -- python3 -c \
  "import ray; ray.init(); print(ray.cluster_resources())"

# Expected output should include:
# 'GPU': 2.0
# 'CPU': 40.0
# 'accelerator_type:GB10': 2.0
# Two node IPs listed
```

## How It Works

```
KubeRay Operator (Spark 1, kuberay-system)
        ↓ manages
RayCluster (core-services)
├── Ray Head Pod (Spark 1) — coordinates cluster + runs vLLM API server
└── Ray Worker Pod (Spark 2) — tensor parallel rank 1

vLLM with --tensor-parallel-size 2
├── Rank 0 on Spark 1 GPU
└── Rank 1 on Spark 2 GPU (via NCCL over network)
```

## Troubleshooting

**Worker fails with "exec format error":**
The Ray image is x86 only. Use `nvcr.io/nvidia/vllm:25.09-py3` instead.

**Worker fails with "Malformed host":**
The `$RAY_HEAD_SERVICE_HOST` env var is empty. Use the explicit service DNS name:
`vllm-cluster-head-svc.core-services.svc.cluster.local:6379`

**Worker fails with "Failed to validate connection to cluster":**
The head service IP has changed (network change between sessions). Check with:
```bash
kubectl get services -n core-services
```
And update the worker's K3S_URL if needed.
