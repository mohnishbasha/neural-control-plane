# Neural Control Plane

A personal AI infrastructure platform for orchestrating a swarm of autonomous agents across development, deployment, and operations — running on NVIDIA DGX Spark with Kubernetes, vLLM, and AIBrix.

## Goal

Build a self-contained, GPU-accelerated control plane that provisions and runs a **swarm of AI agents** capable of:

- **SDLC agents** — plan, manage, and execute software generation (product manager, developer, QA, and manager agents)
- **Deployment & Monitoring agents** — deploy and observe generated software on target cloud/on-prem providers
- **Operational agents** — run GTM, marketing, SEO/AEO, and campaigns for shipped software

The stack is: **DGX Spark → Kubernetes → vLLM → AIBrix → Agent swarms**

## Stack

| Layer | Technology |
|-------|-----------|
| Compute | NVIDIA DGX Spark (GPU-accelerated) |
| Orchestration | Kubernetes (k3d / minikube / native) |
| Model Serving | vLLM |
| Agent Runtime | AIBrix |
| Models | Qwen, Ollama, and others (evaluated per use case) |
| Agent Framework | Hermes Agent |

## Open Issues

| # | Title | Status |
|---|-------|--------|
| [#9](https://github.com/mohnishbasha/neural-control-plane/issues/9) | Evaluate Qwen, Ollama, and other models for coding and operational agents | Open |
| [#8](https://github.com/mohnishbasha/neural-control-plane/issues/8) | Evaluate Hermes agent — document integration with kube → vLLM → AIBrix | Open |
| [#7](https://github.com/mohnishbasha/neural-control-plane/issues/7) | Configure Kubernetes on DGX Spark with namespace isolation | Open |
| [#6](https://github.com/mohnishbasha/neural-control-plane/issues/6) | Architecture review — system diagram checkin | Open |
| [#5](https://github.com/mohnishbasha/neural-control-plane/issues/5) | Evaluate vLLM and AIBrix — install, research, system diagram | Open |
| [#4](https://github.com/mohnishbasha/neural-control-plane/issues/4) | Evaluate k3d, minikube, or native Kubernetes for DGX Spark | Open |
| [#3](https://github.com/mohnishbasha/neural-control-plane/issues/3) | Research Kubernetes configuration approaches for DGX Spark (pros/cons) | Open |
| [#2](https://github.com/mohnishbasha/neural-control-plane/issues/2) | Run OS, CUDA, and apt system updates on DGX Spark | Open |
| [#1](https://github.com/mohnishbasha/neural-control-plane/issues/1) | Boot DGX Spark and review system specifications | Open |

## Repository Structure

```
neural-control-plane/
├── docs/           # Architecture diagrams, research notes, evaluation reports
├── infra/          # Kubernetes manifests, Helm charts, cluster config
├── agents/         # Agent definitions, swarm topology configs
├── models/         # vLLM / AIBrix model serving configs
└── scripts/        # Setup, bootstrap, and operational scripts
```

## Agent Swarm Architecture

```
DGX Spark (GPU Compute)
  └── Kubernetes Cluster
        ├── vLLM (model serving)
        │     └── AIBrix (agent runtime)
        │           ├── SDLC Swarm
        │           │     ├── Product Manager Agent
        │           │     ├── Developer Agent
        │           │     ├── QA Agent
        │           │     └── Manager Agent
        │           ├── Deployment & Monitoring Swarm
        │           │     ├── Deploy Agent
        │           │     └── Monitor Agent
        │           └── Operations Swarm
        │                 ├── GTM Agent
        │                 ├── Marketing Agent
        │                 └── SEO/AEO Agent
        └── Namespaced isolation per swarm group
```

## Roadmap

1. Boot and inventory DGX Spark hardware (#1, #2)
2. Evaluate and select Kubernetes distribution (#3, #4)
3. Deploy vLLM + AIBrix on cluster (#5)
4. Validate system diagram with architecture review (#6)
5. Configure production Kubernetes namespaces (#7)
6. Integrate Hermes agent framework (#8)
7. Evaluate and select models per agent role (#9)
8. Run end-to-end swarm across all three agent groups
