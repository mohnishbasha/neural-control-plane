# vLLM Setup

## Overview

This document covers deploying vLLM as a distributed inference engine across both DGX Sparks using Ray for tensor parallelism. vLLM runs inside the RayCluster as part of the Ray head pod startup command.

## What is vLLM

vLLM is a high-performance LLM inference engine. Key features relevant to this setup:

- **PagedAttention** — efficient GPU memory management, enables higher concurrency
- **Tensor parallelism** — splits model weights across multiple GPUs/nodes
- **OpenAI-compatible API** — drop-in replacement for OpenAI API endpoints
- **ARM64 native** — NVIDIA's vLLM image supports DGX Spark's Grace Blackwell architecture

## Architecture

```
Ray Head Pod (Spark 1)
├── Ray head node (port 6379)
├── Ray dashboard (port 8265)
└── vLLM API server (port 8000)
    └── tensor parallel rank 0 (Spark 1 GPU)

Ray Worker Pod (Spark 2)
└── tensor parallel rank 1 (Spark 2 GPU)

Combined: model split across 256GB unified memory
```

## Prerequisites

- k3s cluster running
- KubeRay operator installed
- RayCluster deployed (see kuberay-setup.md)
- Hugging Face account and API token
- NVIDIA NGC credentials

## Hugging Face Token Setup

Create a Kubernetes secret to store the HF token securely:

```bash
export HF_TOKEN="your_token_here"

kubectl create secret generic hf-token \
  --from-literal=token=$HF_TOKEN \
  -n core-services
```

> **Security note:** Never commit HF tokens to Git or share them publicly. Always use Kubernetes secrets.

## Image Information

NVIDIA's official vLLM image for DGX Spark:
```
nvcr.io/nvidia/vllm:25.09-py3
```

- ARM64 native (Grace Blackwell compatible)
- Ray 2.49.2 built in
- CUDA 13.0
- vLLM 0.10.1.1

## Deployment

vLLM is deployed as part of the RayCluster head pod startup command (see kuberay-setup.md). The head pod automatically:

1. Starts Ray head node
2. Waits 30 seconds for Ray to initialize
3. Starts vLLM with tensor parallelism across both nodes

Key vLLM flags:
```bash
python3 -m vllm.entrypoints.openai.api_server \
  --model Qwen/Qwen2.5-7B-Instruct \
  --tensor-parallel-size 2 \          # split across 2 GPUs
  --distributed-executor-backend ray \ # use Ray for distribution
  --host 0.0.0.0 \
  --port 8000 \
  --gpu-memory-utilization 0.85 \     # 85% GPU memory for KV cache
  --max-num-seqs 4                    # max concurrent sequences
```

## Startup Time

First load after fresh deployment:
- Model download: ~20 minutes (14GB model)
- Model loading + compilation: ~5 minutes
- Total first startup: ~25 minutes

Subsequent startups (model cached):
- ~3-5 minutes

## Verification

```bash
# Check pod is running
kubectl get pods -n core-services

# Check logs for startup complete
kubectl logs -n core-services -l ray.io/node-type=head --tail=5
# Look for: "Application startup complete."

# Test model endpoint
kubectl exec -n core-services <HEAD_POD_NAME> -- \
  curl -s http://localhost:8000/v1/models

# Test chat completion
kubectl exec -n core-services <HEAD_POD_NAME> -- \
  curl -s http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen/Qwen2.5-7B-Instruct",
    "messages": [{"role": "user", "content": "Say hello."}],
    "max_tokens": 50
  }'
```

## Services

Two Kubernetes services expose vLLM:

```
vllm-cluster-head-svc   ClusterIP   None            10001,8265,6379,8080,8000
vllm-service            ClusterIP   10.43.55.139    8000
```

- `vllm-cluster-head-svc` — headless service used by Ray worker to find the head node
- `vllm-service` — ClusterIP service for other pods to reach vLLM API on port 8000

## Current Model

- **Model:** Qwen/Qwen2.5-7B-Instruct
- **Parameters:** 7 billion
- **Context length:** 32,768 tokens
- **Tensor parallel:** 2 (one rank per Spark)
- **Purpose:** Development and testing

## Scaling to Larger Models

With both Sparks combined (256GB), larger models are possible:
- Qwen3-235B-A22B-NVFP4
- Nemotron-3-Super-120B
- Llama 405B (quantized)

For larger models, update `--model` and ensure quantization flags match the model format.

## Version Prerequisites

| Component | Minimum Version |
|---|---|
| NVIDIA Driver | 525+ (580.159.03 on DGX Spark) |
| CUDA | 12.1+ (13.0 on DGX Spark) |
| Kubernetes | 1.27+ |
| Ray | 2.49.2 (built into NVIDIA image) |
