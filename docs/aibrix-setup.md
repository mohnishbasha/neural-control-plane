# AIBrix Setup

## Overview

This document covers installing AIBrix v0.6.0 as the AI inference routing and agent lifecycle management layer on top of the vLLM + Ray cluster.

## What is AIBrix

AIBrix is an open-source infrastructure platform for GenAI inference. It sits between AI agents and vLLM, providing:

- **Request routing** — routes agent requests to the correct model endpoint
- **Multi-tenancy** — isolates workloads across namespaces with quota enforcement
- **Agent lifecycle management** — manages autonomous agent startup, shutdown, and resource allocation
- **GPU optimization** — intelligent GPU utilization-aware scheduling
- **Model adapter management** — registers and manages multiple model endpoints

## Architecture Position

```
Agent Swarms (per-app namespaces)
        ↓
AIBrix Gateway (aibrix-system)
├── Request routing
├── Quota enforcement
├── Agent lifecycle
└── GPU optimization
        ↓
vLLM API (core-services)
        ↓
Ray cluster (both Sparks)
```

## Prerequisites

- k3s cluster running
- vLLM + RayCluster deployed and serving in core-services namespace
- kubectl access from Spark 1

## Installation

### Step 1 — Install Dependencies

```bash
kubectl apply -f https://github.com/vllm-project/aibrix/releases/download/v0.6.0/aibrix-dependency-v0.6.0.yaml \
  --server-side --force-conflicts
```

This installs:
- Envoy Gateway (traffic routing layer)
- Gateway API CRDs
- Ray CRDs

### Step 2 — Install AIBrix Core

```bash
kubectl apply -f https://github.com/vllm-project/aibrix/releases/download/v0.6.0/aibrix-core-v0.6.0.yaml
```

This creates the `aibrix-system` namespace and installs all core components.

## Verification

```bash
kubectl get pods -n aibrix-system
```

Expected output — all pods Running:

```
NAME                                        READY   STATUS    AGE
aibrix-controller-manager-xxx               1/1     Running   Xm
aibrix-gateway-plugins-xxx                  1/1     Running   Xm
aibrix-gpu-optimizer-xxx                    1/1     Running   Xm
aibrix-kuberay-operator-xxx                 1/1     Running   Xm
aibrix-metadata-service-xxx                 1/1     Running   Xm
aibrix-redis-master-xxx                     1/1     Running   Xm
```

## Components

| Component | Purpose |
|---|---|
| `aibrix-controller-manager` | Manages AIBrix CRDs and reconciles desired state |
| `aibrix-gateway-plugins` | Envoy gateway plugins for request routing |
| `aibrix-gpu-optimizer` | Optimizes GPU allocation across workloads |
| `aibrix-kuberay-operator` | AIBrix's own Ray cluster management |
| `aibrix-metadata-service` | Stores model and endpoint metadata |
| `aibrix-redis-master` | Caching layer for routing decisions |

## Custom Resource Definitions

AIBrix adds these CRDs to Kubernetes:

```
modeladapters.model.aibrix.ai          — registers model endpoints
podautoscalers.autoscaling.aibrix.ai   — AI-aware autoscaling
rayclusterfleets.orchestration.aibrix.ai — manages Ray cluster fleets
stormservices.orchestration.aibrix.ai  — storm service orchestration
kvcaches.orchestration.aibrix.ai       — KV cache management
```

## Registering a Model (ModelAdapter)

Once you have decided on a model and agent architecture, register vLLM as a model endpoint:

```bash
kubectl apply -f - <<EOF
apiVersion: model.aibrix.ai/v1alpha1
kind: ModelAdapter
metadata:
  name: <model-name>
  namespace: <target-namespace>
spec:
  modelName: <huggingface-model-id>
  replicas: 1
  podSelector:
    matchLabels:
      ray.io/node-type: head
EOF
```

> **Note:** ModelAdapter configuration is deferred until agent namespaces and specific model choices are finalized.

## Namespace Integration

AIBrix is designed to work with per-app namespaces. Each application gets its own namespace with AIBrix managing routing within it:

```
namespace: snackonai-dev
└── AIBrix routes agent requests → vLLM in core-services

namespace: snackonai-ops
└── AIBrix routes agent requests → vLLM in core-services
```

Multiple namespaces can share the same vLLM instance — AIBrix handles the routing and isolation.

## Version Information

- AIBrix version: v0.6.0 (released March 5, 2026)
- Envoy Gateway: v1.2.8
- Compatible with: Kubernetes 1.27+, vLLM 0.6+

## Next Steps

1. Configure namespace isolation per agent swarm (#7)
2. Create ModelAdapters for specific models once research topic is decided
3. Deploy agent definitions (SDLC, DevOps, Operations swarms)
4. Configure per-namespace resource quotas
