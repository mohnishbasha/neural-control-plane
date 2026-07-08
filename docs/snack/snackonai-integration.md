# snackonai Integration

## Overview

snackonai is a Telegram research bot (`@SnackOnAiBot`) that runs as a 6-agent pipeline in the `snackonai` namespace, generating and publishing research write-ups from technical topics, then committing the output to GitHub.

This document covers how the pipeline is packaged (Docker), deployed (Helm), and wired into the rest of the cluster. Several sections below are marked **`[CONFIRM]`** — fill in the exact values/commands from your actual Dockerfiles, Helm charts, and deployment history so this doc matches what's really running rather than the general shape of it.

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
| `large` | Together.ai (Qwen2.5-72B) | Pending — Together.ai API key not yet provisioned |
| `claude` | Anthropic API (`claude-sonnet-4-6`) | Key available, not yet wired into `pipeline_runner.py` |

Remaining work: `pipeline_runner.py` needs updating to run the pipeline twice per topic (once per configured backend) once both keys are live, producing two parallel articles per topic — one from the large open-weight model, one from Claude.

`[CONFIRM]`: exact env var names, secret name/key holding the Anthropic and Together.ai API keys once provisioned, and how `pipeline_runner.py` selects/parallelizes the two runs.

---

## Dockerization

`[CONFIRM — fill in per actual Dockerfile(s)]`

Each agent (or the pipeline as a single image, depending on how it's structured) is built into a container image from the `snackonai-composer` repo.

Suggested structure to document here once confirmed:

- **Base image:** `[CONFIRM]` (e.g. `python:3.x-slim`, `nvcr.io/nvidia/...` if any agent needs GPU access directly rather than calling vLLM over HTTP)
- **Build context / Dockerfile path:** `[CONFIRM]` — e.g. one Dockerfile per agent under `snackonai-composer/<agent>/Dockerfile`, or a single multi-stage Dockerfile
- **Key dependencies baked into the image:** `[CONFIRM]` — Telegram bot library, GitHub API client, prompt/agent framework in use
- **Image registry:** `[CONFIRM]` — where images are pushed (e.g. GHCR, Docker Hub, a private registry) and the naming convention used (`snackonai-composer-researcher:<tag>`, etc.)
- **Build/push command:**
  ```bash
  # [CONFIRM] — example shape:
  docker build -t <registry>/snackonai-composer-<agent>:<tag> .
  docker push <registry>/snackonai-composer-<agent>:<tag>
  ```
- **Secrets baked in vs. injected at runtime:** confirm that the Telegram bot token, GitHub token, and LLM API keys are **not** baked into the image and are instead injected via Kubernetes Secrets (see Helm section below) — this should be true given the pattern used elsewhere in this repo (e.g. `hf-token` secret in `vllm-setup.md`), but worth explicitly verifying here since it's a common way secrets leak into image layers.

---

## Helm Deployment

`[CONFIRM — fill in per actual chart]`

The pipeline is deployed into the `snackonai` namespace. Document here once confirmed:

- **Chart location:** `[CONFIRM]` — e.g. `snackonai-composer/helm/` in the repo, or a chart published separately
- **Release name / namespace:**
  ```bash
  # [CONFIRM] — example shape:
  helm install snackonai ./helm/snackonai-composer \
    --namespace snackonai \
    --create-namespace \
    -f values.yaml
  ```
- **Key values exposed in `values.yaml`:** `[CONFIRM]` — likely candidates based on the pipeline's needs:
  - `vllm.endpoint` — pointing at `vllm-service.core-services.svc.cluster.local:8000`
  - `telegram.botTokenSecretRef` — secret containing the Telegram bot token
  - `github.tokenSecretRef` — secret containing the GitHub PAT used for commits
  - `llmBackend` — `local` / `large` / `claude`, matching the `LLM_BACKEND` env var above
  - `schedule` or `pollingInterval` — how often `composer-bot` checks for new topics
- **Resource requests/limits per agent:** `[CONFIRM]` — none of the agents should need a GPU directly (they call vLLM over HTTP), so this is likely CPU/memory only; worth confirming no agent pod is unintentionally requesting `nvidia.com/gpu` and starving the QQQ/vLLM workloads for GPU scheduling.

### Verification

```bash
# Check all 6 agent pods (or however the release is structured) are running
kubectl get pods -n snackonai

# Check composer-bot is polling Telegram successfully
kubectl logs -n snackonai -l app=composer-bot --tail=50

# Check most recent pipeline run's output landed in the repo
# (confirm this against the actual GitHub push step / commit history)
```

---

## How the Pipeline Was Integrated

`[CONFIRM — reconstruct this section from actual deployment history / commit log]`

Suggested outline to fill in:

1. **Namespace creation** — `snackonai` namespace added alongside `core-services`, `qqq-data`, `fine-tune` (see root `README.md` namespace table).
2. **Secrets provisioned** — Telegram bot token, GitHub PAT, and LLM backend API keys created as Kubernetes Secrets in the `snackonai` namespace (mirror the `hf-token` pattern from `vllm-setup.md`).
3. **Model dependency** — confirmed `vllm-service` in `core-services` was reachable cluster-wide before wiring agents to it (no AIBrix ModelAdapter currently registered for this specific use — agents hit the raw `vllm-service` ClusterIP directly rather than going through AIBrix routing; `[CONFIRM]` whether this is intentional or a gap to close).
4. **Agent pipeline evolution** — upgraded from a 3-agent pipeline (researcher → writer → Telegram) to the current 6-agent pipeline (added the MoE analyst and reflection-loop editor). `[CONFIRM]` date/commit of this upgrade and what specifically motivated the analyst/editor additions (likely: draft quality issues from the 3-agent version).
5. **Deployment method** — `[CONFIRM]` whether this was deployed via `kubectl apply` initially and later Helm-ized, or Helm from the start.

---

## Known Gaps / Follow-ups

- Together.ai API key not yet provisioned — blocks the dual-backend (`large` mode) rollout.
- `pipeline_runner.py` not yet updated to run twice per topic.
- Confirm whether agents should route through AIBrix (for quota/isolation) rather than hitting `vllm-service` directly, especially once the dual-backend work adds external API calls that AIBrix isn't positioned to manage the same way as in-cluster vLLM.
- This document's Docker/Helm sections need to be filled in against the actual `snackonai-composer` repo contents — right now they describe the expected shape based on how the rest of this cluster is set up, not verified specifics.
