# snackonai Integration

## Overview

snackonai is a Telegram research bot (`@SnackOnAiBot`) that runs as a 6-agent pipeline in the `snackonai` namespace, generating and publishing research write-ups from technical topics, then committing the output to GitHub.

This document covers how the pipeline is packaged (Docker), deployed (Helm), and wired into the rest of the cluster.

Each agent's code (or the pipeline as a whole, if it shares one codebase) gets packaged into a container image via a Dockerfile in the snackonai-composer repo — this bundles the Python runtime, whatever bot/orchestration libraries the agents use, and the application code itself, but deliberately leaves out secrets like the Telegram token, GitHub PAT, and LLM API keys. Those get built with docker build, tagged with a version, and pushed to a registry (something like GHCR or Docker Hub) so Kubernetes can pull them by name later — this is the same pattern used elsewhere in the cluster, like the nvcr.io/nvidia/vllm image referenced in vllm-setup.md.

Helm comes in as the deployment layer on top of that. Instead of writing out raw Kubernetes YAML for every agent's Deployment, Service, and Secret, a Helm chart templates all of that and exposes the parts that change between environments — image tags, replica counts, which vLLM endpoint to hit, which LLM backend to use — as values in a values.yaml file. Running helm install snackonai ./helm/snackonai-composer -n snackonai -f values.yaml takes that chart, fills in the values, and applies the resulting manifests to the snackonai namespace in one shot. The secrets themselves (Telegram token, GitHub PAT, API keys) get created separately as Kubernetes Secrets ahead of time, and the chart just references them by name — mirroring how hf-token is handled for vLLM — so nothing sensitive ever lives in the chart or the image.

---

## Pipeline Architecture

```
Telegram (new topic)
   └─▶ composer-bot — orchestrates the pipeline
          └─▶ researcher — extracts technical research
                 └─▶ analyst — MoE, 5 expert personas
                        └─▶ writer — drafts 14-section article
                               └─▶ editor — checks 9 failure conditions
                                      │
                                      ├─▶ fails a check → back to writer (revise loop)
                                      │
                                      └─▶ passes → social — generates short post
                                             │
                                             ├─▶ Telegram — publishes post
                                             └─▶ GitHub — commits output

Shared model backend (called by all 5 agents):
   vllm-service.core-services.svc.cluster.local:8000 → Qwen2.5-3B
```

A new topic enters via Telegram and `composer-bot` orchestrates the five-agent chain: researcher → analyst → writer → editor → social. The editor can send a draft back to the writer if it fails one of its 9 checks (the revise loop). All five agents call the same shared Qwen2.5-3B vLLM backend rather than each running their own model. The finished piece is published back to Telegram and committed to GitHub.

### Agent roles

| Agent | Purpose |
|---|---|
| `composer-bot` | Telegram polling, topic intake, orchestration across the other 5 agents |
| `snackonai-composer-researcher` | Pulls and extracts technical research relevant to the topic |
| `snackonai-composer-analyst` | Mixture-of-Experts pass across 5 personas (Systems Architect, ML Research Expert, Infrastructure Engineer, Code Reviewer, Contrarian Thinker); produces architecture diagrams, annotated code, worked examples, 2 contrarian insights, 1 surprising takeaway |
| `snackonai-composer-writer` | Assembles the 14 mandatory sections into a Beehiiv-ready draft with the SnackOnAI Engineering signature |
| `snackonai-composer-editor` | Reflection loop — checks the draft against 9 failure conditions, sends it back to the writer with specific feedback until it passes or hits a retry cap |
| `snackonai-composer-social` | Generates a short social media post from the finished draft |

**Output destinations:** `neural-control-plane/research/` (long-form) and `neural-control-plane/social/` (short-form), committed via GitHub after the pipeline completes.

---

## Model Backend

All agents currently call the shared vLLM endpoint in `core-services`:

```
http://vllm-service.core-services.svc.cluster.local:8000/v1/chat/completions
```

Model served: `Qwen2.5-3B-Instruct` (via the `vllm-service` ClusterIP — see `docs/qqq/qqq-integration.md` for how this model deployment itself is set up).

### Pending: dual LLM backend

`llm.py` has been partially rewritten to support an `LLM_BACKEND` environment variable with three modes:

| Value | Backend | Status |
|---|---|---|
| `local` | In-cluster vLLM (Qwen2.5-3B) | Active |
| `large` | Together.ai (Qwen2.5-72B) | Together.ai API key |
| `claude` | Anthropic API (`claude-sonnet-4-6`) | Anthropic API key |

---

### Verification

```bash
# Check all 6 agent pods (or however the release is structured) are running
kubectl get pods -n snackonai

# Check composer-bot is polling Telegram successfully
kubectl logs -n snackonai -l app=composer-bot --tail=50

# Check most recent pipeline run's output landed in the repo
# (confirm this against the actual GitHub push step / commit history)
```
