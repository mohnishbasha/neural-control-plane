# QQQ Trading Signal Pipeline Integration

## Overview

This document covers how the QQQ research work — model serving, offline pipeline, real-time pipeline, and training/eval integration — is wired into the cluster infrastructure described in the rest of `docs/`. It complements the paper-facing methodology (evaluation metric, training techniques, results) with the *systems* side: which models run where, how they were installed, and how the offline/real-time pipelines feed them.

---

## Models

Four small instruction-tuned models are served, one per model, split across the two Sparks:

| Model | HuggingFace ID | Node | Namespace | Notes |
|---|---|---|---|---|
| qwen-3b | `Qwen/Qwen2.5-3B-Instruct` | spark-720e (Spark 1) | `core-services` | Also backs `vllm-service`, shared with snackonai |
| smollm-1b | `HuggingFaceTB/SmolLM2-1.7B-Instruct` | spark-720e (Spark 1) | `core-services` | |
| gemma-2b | `google/gemma-2-2b-it` | spark-7229 (Spark 2) | `core-services` | |
| falcon-3b | `tiiuae/Falcon3-3B-Instruct` | spark-7229 (Spark 2) | `core-services` | |

Two models were tried and dropped:
- `phi-mini` — dropped due to GPU memory constraints.
- `Qwen2.5-7B-Instruct` — the original single large model from the tensor-parallel KubeRay setup; deleted to free GPU memory once the pivot to 4 independent small models happened.

All four expose an OpenAI-compatible `/v1/chat/completions` endpoint. This is a deliberate departure from the tensor-parallel single-model KubeRay/RayCluster setup documented in `docs/kuberay-setup.md` and `docs/vllm-setup.md` — see the note in the root `README.md` for why. **Each of the four models here runs as an independent, single-GPU vLLM deployment**, not a Ray-coordinated multi-node cluster; two models share Spark 1's GPU and two share Spark 2's GPU.

`[CONFIRM]`: exact deployment manifests for these 4 models — whether each is its own `Deployment` + `Service` pair (likely, given they're independent single-node vLLM instances rather than a RayCluster), and how GPU memory is partitioned between the two co-located models on each Spark (e.g. `--gpu-memory-utilization` set lower than the `0.85` default used in the single-model KubeRay setup, to leave room for the second model).

### How the models were installed

`[CONFIRM — reconstruct against actual manifests/commit history]`

Suggested shape, following the same pattern as `vllm-setup.md` but per-model rather than tensor-parallel:

```bash
# Per model, roughly:
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: <model-name>          # e.g. qwen-3b
  namespace: core-services
spec:
  template:
    spec:
      nodeSelector:
        kubernetes.io/hostname: <spark-hostname>
      containers:
      - name: vllm
        image: nvcr.io/nvidia/vllm:25.09-py3
        args:
        - python3 -m vllm.entrypoints.openai.api_server
        - --model <hf-model-id>
        - --host 0.0.0.0
        - --port 8000
        - --gpu-memory-utilization <fraction, confirm>
        env:
        - name: HF_TOKEN
          valueFrom:
            secretKeyRef:
              name: hf-token
              key: token
        resources:
          limits:
            nvidia.com/gpu: "1"     # [CONFIRM] whether GPU is shared/fractional
EOF
```

`[CONFIRM]`: whether GPU sharing between the two co-located models per node uses MIG (see the future-work MIG config in `docs/cluster-setup.md`), time-slicing, or simply two processes sharing the GPU via `--gpu-memory-utilization` fractions without formal isolation.

### AIBrix registration

`[CONFIRM]` whether these four models are registered as AIBrix `ModelAdapter` resources (per the pattern in `docs/aibrix-setup.md`) for routing/quota purposes, or whether the QQQ pipeline scripts hit each model's `ClusterIP` service directly. Given `vllm-service` in `core-services` is described elsewhere as pointing specifically at qwen-3b (also used by snackonai), it's worth confirming whether the other three models (smollm-1b, gemma-2b, falcon-3b) have their own equivalent `Service` objects with a documented naming convention — this doc currently assumes yes but the exact service names need filling in.

---

## Pipeline Architecture

Two independent pipelines feed the same four models against the same 36-day holdout evaluation set, differing in data recency and granularity.

```
OFFLINE PIPELINE (qqq-data namespace)
──────────────────────────────────────
yfinance (EOD data)
   └─▶ CronJob, 9pm UTC weekdays → JSON on PVC
          └─▶ ~/qqq-autoresearch/
                 (baseline → autoresearch → few-shot → prompt tuning → LoRA → DPO)
                 └─▶ 4 shared vLLM models — see below

REAL-TIME PIPELINE (fine-tune namespace)
──────────────────────────────────────
Yahoo Finance (15-min bars)
   └─▶ Ingestor CronJob, every 15 min during market hours
          └─▶ RedPanda (qqq-signals-15m, qqq-signals-historical)
                 └─▶ Mid-day signal CronJob, 12pm ET
                        └─▶ ~/fine-tune/, ~/lora-workspace/ (same 5 techniques)
                               └─▶ 4 shared vLLM models — see below

SHARED MODEL BACKEND (core-services namespace)
──────────────────────────────────────
qwen-3b · smollm-1b · gemma-2b · falcon-3b
   └─▶ Evaluation: 36-day holdout, directional hit-rate
          └─▶ GitHub: neural-control-plane/qqq/benchmarks/
```

Both pipelines run independently — offline pulling end-of-day data, real-time streaming 15-minute bars through RedPanda — and converge on the same four shared vLLM models, the same 36-day holdout evaluation, and the same GitHub output destination.

### Offline pipeline (`qqq-data` namespace)

- 133 days of historical data (Dec 2025 → Jun 2026), sourced end-of-day.
- Ingestion: CronJob running `yfinance` pulls at 9pm UTC on weekdays.
- Scripts and pipeline code: `~/qqq-autoresearch/` on Spark 1.

### Real-time pipeline (`fine-tune` namespace)

- RedPanda broker: `redpanda-0.redpanda.fine-tune.svc.cluster.local:9093`
- Topics: `qqq-signals-historical` (133-day bootstrap), `qqq-signals-15m` (live)
- Ingestor CronJob schedule: `*/15 14-20 * * 1-5` (every 15 min, 14:00–20:00 UTC, weekdays — market hours in ET)
- Mid-day signal CronJob schedule: `0 17 * * 1-5` (12pm ET) — this job was failing for 5 days due to null `close` values on market holidays plus a wrong SSH key path; both root causes were fixed.
- Scripts: `~/fine-tune/` and `~/lora-workspace/` on Spark 1.
- Prompt length matters here: the original real-time prompt (10,343 chars) caused 100% `HOLD` degenerate outputs from all four models; fixing it to a 399-char structured `BULLISH`/`BEARISH` format restored real directional predictions. This is documented as a paper finding, not just an infra fix — see the QQQ paper draft for the write-up.

Both pipelines share: the same 4 models, the same 36-day holdout, and the same downstream training scripts pattern (baseline → autoresearch → few-shot → prompt tuning → LoRA → DPO). See the paper draft for the evaluation methodology (`eval_holdout()` in `dpo_train_and_eval.py`) and full results tables — this doc covers the systems/deployment side only.

---

## Training Artifacts

| Artifact | Location |
|---|---|
| LoRA adapter — smollm-1b (offline, kept) | `~/lora-workspace/adapters/smollm-1b-offline/` |
| LoRA adapter — falcon-3b (offline, kept) | `~/lora-workspace/adapters/falcon-3b-offline/` |
| Real-time LoRA adapters | All reverted — not retained (see paper draft: real-time LoRA collapsed to constant-output on both the 60-example and 94-example attempts) |
| DPO training/eval script | `dpo_train_and_eval.py` (offline pipeline; `eval_holdout()` at line ~105 is the scoring function referenced in the paper) |

`[CONFIRM]`: exact filesystem path for `dpo_train_and_eval.py` (presumably under `~/qqq-autoresearch/` or `~/lora-workspace/` — worth pinning down for reproducibility), and whether DPO adapters (offline: qwen-3b, smollm-1b, gemma-2b kept per the accuracy rule, falcon-3b reverted; real-time: all 4 reverted) are saved anywhere or only exist as run artifacts from the training session.

---

## Output / GitHub Integration

Predictions, benchmark results, and research output are committed to:

```
github.com/mohnishbasha/neural-control-plane
  └── qqq/benchmarks/    — benchmark result tables, findings docs
                            (e.g. realtime-lora-collapse-finding.md)
```

`[CONFIRM]`: whether this commit happens automatically at the end of a training/eval run (e.g. via a script step) or is a manual step after reviewing results — worth documenting given the DPO session findings showed the importance of manually inspecting row-level predictions before trusting an aggregate "kept" result.

---

## Known Gaps / Follow-ups

- GPU-sharing mechanism between co-located model pairs (qwen-3b + smollm-1b on Spark 1; gemma-2b + falcon-3b on Spark 2) isn't documented anywhere yet — needs confirming whether it's MIG, time-slicing, or unmanaged.
- AIBrix `ModelAdapter` registration status for the 3 non-qwen models is unconfirmed.
- Real-time daily holdout N doesn't cleanly resolve against the accuracy fractions reported in early benchmark tables (flagged separately during the paper-results reconciliation) — worth pinning down the exact holdout row count for the real-time pipeline here as the systems source of truth.
- Data-volume finding from the DPO/LoRA sessions (9-10 DPO pairs, ~90-130 SFT examples were both far too few) implies a future pipeline change — e.g. pooling across additional tickers — that would touch this doc's ingestion section if implemented.
