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


All four expose an OpenAI-compatible `/v1/chat/completions` endpoint. This is a deliberate departure from the tensor-parallel single-model KubeRay/RayCluster setup documented in `docs/kuberay-setup.md` and `docs/vllm-setup.md` — see the note in the root `README.md` for why. **Each of the four models here runs as an independent, single-GPU vLLM deployment**, not a Ray-coordinated multi-node cluster; two models share Spark 1's GPU and two share Spark 2's GPU.

### AIBrix registration

These four models are registered as AIBrix `ModelAdapter` resources (per the pattern in `docs/aibrix-setup.md`) for routing/quota purposes.

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

Both pipelines share: the same 4 models, the same 36-day holdout, and the same downstream training scripts pattern (baseline → autoresearch → few-shot → prompt tuning → LoRA → DPO). See the paper draft for the evaluation methodology (`eval_holdout()` in `dpo_train_and_eval.py`) and full results tables — this doc covers the systems/deployment side only.

---

## Training Methods

Before training, we had baseline tests - the four base instruction-tuned models (qwen-3b, smollm-1b, gemma-2b, falcon-3b) are prompted with no additional training or optimization, just the raw market-context prompt and greedy decoding. This establishes the floor each subsequent technique needs to beat, and is compared against a naive Always-BUY baseline and random chance.

From here, the models were trained with the following methods:

Autoresearch — An automated prompt-optimization process iterates on the prompt wording and structure to improve directional accuracy, without touching model weights. This was the only technique that produced a consistent, real gain across both pipelines (offline and real-time), making it the strongest single lever in the whole study.

Few-shot — Worked examples of correct BUY/SELL/HOLD calls are added directly into the prompt to give the model concrete patterns to follow. Results were flat relative to baseline on both pipelines, suggesting that showing examples doesn't meaningfully help these small models reason better about trading signals.
Prompt tuning — Manual, hand-adjusted refinements to prompt phrasing and structure, distinct from the automated autoresearch pass. This caused a regression on the real-time pipeline (which was reverted per the dual-objective keep/revert rule) and was flat on the offline pipeline, reinforcing that these models had already hit a prompt-level ceiling.

LoRA — Low-rank adapters are fine-tuned on top of the base model weights using labeled offline examples (~90-130 per model). This produced modest real gains on the offline pipeline (notably smollm-1b and falcon-3b), but collapsed to constant-output prediction on the real-time pipeline, where too few labeled examples (60-94) were available for the model to learn genuine input-conditioned behavior rather than just the majority class.

DPO — Direct Preference Optimization trains the model (starting from base weights or, where available, the kept LoRA adapter) on preference pairs indicating which prediction was better. With only 2-10 pairs per model, this was the most data-starved technique in the study — several "kept" results were later found, on row-level inspection, to be constant-output collapses that happened to match the holdout's class balance rather than real learned signal, and all real-time DPO runs were reverted outright.

---

## Output / GitHub Integration

Predictions, benchmark results, and research output are committed to:

```
github.com/mohnishbasha/neural-control-plane
  └── qqq/benchmarks/    — benchmark result tables, findings docs
                            (e.g. realtime-lora-collapse-finding.md)
```

---

## Known Gap

- Data-volume finding from the DPO/LoRA sessions (9-10 DPO pairs, ~90-130 SFT examples were both far too few) implies a future pipeline change — e.g. pooling across additional tickers — that would touch this doc's ingestion section if implemented.
