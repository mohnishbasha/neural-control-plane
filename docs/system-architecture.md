# System Architecture

Layered view of the cluster: what's in GitHub, what's physical, what's cluster-wide infrastructure, and what actually runs where.

```
GitHub repo (neural-control-plane/)
│   docs/              ← infra + pipeline documentation
│   qqq/benchmarks/    ← QQQ results, findings docs
│   research/          ← snackonai long-form output
│   social/            ← snackonai short-form output
        ↓ manual kubectl / helm apply from Spark 1 (no GitOps currently)
─────────────────────────────────────────────
PHYSICAL HARDWARE
Spark 1 (master, 192.168.86.30) ──QSFP/ConnectX-7── Spark 2 (worker, 192.168.86.26)
─────────────────────────────────────────────
INFRASTRUCTURE LAYER (cluster-wide)
k3s + Flannel CNI + NVIDIA GPU Operator
─────────────────────────────────────────────
WORKLOAD LAYER
│
├── namespace: core-services
│   ├── qwen-3b     — served via vLLM (Spark 1)
│   ├── smollm-1b   — served via vLLM (Spark 1)
│   ├── gemma-2b    — served via vLLM (Spark 2)
│   └── falcon-3b   — served via vLLM (Spark 2)
│         (each model = its own independent vLLM process, not a shared/tensor-parallel instance)
│
├── namespace: aibrix-system
│   └── AIBrix — routing + quota layer, sits in front of core-services
│
├── namespace: kuberay-system
│   └── KubeRay operator — installed, reference path only (not actively routing traffic)
│         (tensor-parallel vLLM-over-Ray setup documented in docs/vllm-setup.md,
│          not the live deployment pattern — see core-services above for that)
│
├── namespace: qqq-data
│   └── Offline QQQ pipeline — yfinance EOD CronJob, ~/qqq-autoresearch/ training + eval
│
├── namespace: fine-tune
│   └── Real-time QQQ pipeline — RedPanda, ingestor + mid-day signal CronJobs
│
├── namespace: snackonai
│   └── 6-agent Telegram bot — composer-bot → researcher → analyst → writer → editor → social
│
└── namespace: monitoring
    ├── Prometheus
    └── Grafana
─────────────────────────────────────────────
MANAGEMENT LAYER
Manual kubectl / Helm from Spark 1 — no ArgoCD or GitOps operator currently deployed
```

## Notes

- **vLLM is not its own namespace or shared service.** It's the inference engine each of the four `core-services` models runs as an independent process — one vLLM instance per model, not a single tensor-parallel deployment. Two models share Spark 1's GPU, two share Spark 2's.
- **KubeRay's tensor-parallel path is a reference setup, not what's running.** `docs/vllm-setup.md` and `docs/kuberay-setup.md` document a single large model split across both Sparks via Ray — useful if a future project needs a model too big for one Spark's 128GB, but not the current architecture.
- **No GitOps loop yet.** GitHub is where research output and docs land, not where deployment config is sourced from. Deployments happen via manual `kubectl`/`helm` on Spark 1. Adding ArgoCD (or similar) to close that loop would be a real infrastructure change, not just a documentation update.
- **Hermes** appeared in early infra notes (namespace `hermes`, port 8080) but isn't reflected in the current namespace list above — worth confirming whether it's been retired in favor of snackonai or is still running separately.
