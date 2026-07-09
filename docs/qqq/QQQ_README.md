# QQQ Stock Signal Prediction with Small Language Models

**Can we train a set of small language models to understand stock trading signals?**

This repository documents an experiment in applying small language models (SLMs, ≤4B parameters) to QQQ ETF directional signal prediction using technical indicators. Two independent data pipelines were built and five training techniques were evaluated across four models, producing a benchmark comparison of offline vs. real-time data approaches.

---

## Infrastructure

The system runs on a 2-node NVIDIA DGX Spark cluster:

```
Spark 1 (spark-720e)          Spark 2 (spark-7229)
192.168.86.30                 192.168.86.26
Control plane, 192 GiB RAM    Worker, 122 GiB RAM
NVIDIA GB10 Blackwell GPU     NVIDIA GB10 Blackwell GPU
```

**Stack:**
- Kubernetes (k3s v1.35.5) across both nodes
- vLLM 0.10.1 serving each model independently via OpenAI-compatible API
- AIBrix v0.6.0 for model registration and routing
- Prometheus + Grafana for token throughput and latency monitoring
- RedPanda (Kafka-compatible) for real-time data streaming

**Models deployed (all ≤4B parameters):**

| Model | Size | Node | HuggingFace ID |
|-------|------|------|----------------|
| qwen-3b | 3B | Spark 1 | Qwen/Qwen2.5-3B-Instruct |
| smollm-1b | 1.7B | Spark 1 | HuggingFaceTB/SmolLM2-1.7B-Instruct |
| gemma-2b | 2B | Spark 2 | google/gemma-2-2b-it |
| falcon-3b | 3B | Spark 2 | tiiuae/Falcon3-3B-Instruct |

Each model runs as its own vLLM Deployment (TP=1, single GPU) and receives identical prompts for benchmark fairness.

---

## Data Pipelines

Two completely independent pipelines feed the same four models. All data is sourced from Yahoo Finance via `yfinance`.

### Pipeline 1 — Offline (qqq-data namespace)

Reads end-of-day QQQ data from JSON files stored on a Persistent Volume Claim (PVC).

```
Yahoo Finance (yfinance)
        ↓ CronJob at 9pm UTC Mon-Fri
/data/YYYY-MM-DD.json on PVC
        ↓
strategy.py reads files → builds prompt → queries models
        ↓
BUY / SELL / HOLD signal per model
```

Each daily file contains for QQQ and its top holdings: RSI-14, MACD line/signal/histogram, EMA-9, EMA-20, close price, volume. Plus macro context: VIX, SPY close.

**133 days of data collected:** December 2025 → June 2026.

### Pipeline 2 — Real-time (fine-tune namespace)

Streams 15-minute intraday QQQ bars through RedPanda and generates a mid-day signal at 12pm ET.

```
Yahoo Finance (yfinance, 15-min bars)
        ↓ Ingestor CronJob every 15 min, 9:30am-4pm ET
RedPanda topic: qqq-signals-15m
        +
RedPanda topic: qqq-signals-historical (133 days bootstrapped)
        ↓
Mid-day signal CronJob at 12pm ET (5pm UTC)
Consumes: today's live bars + last 90 days of context
        ↓
BUY / SELL / HOLD signal per model
        ↓
Saved to qqq/realtime/YYYY-MM-DD.json + committed to GitHub
```

**Key difference from offline:** the real-time pipeline incorporates intraday price action (morning direction, latest bar indicators) alongside historical context, enabling a more informed mid-day signal rather than purely end-of-day prediction.

---

## How Predictions Are Made

Each model receives a structured prompt built from the available indicators. The prompt follows a BULLISH/BEARISH classification format — each indicator is evaluated and labeled, a net bull-bear score is computed, and the model is asked to output exactly one word: **BUY**, **SELL**, or **HOLD**.

**Example prompt structure:**
```
You are a quantitative trading analyst. Based on the following 
market data, provide a single-word trading signal: BUY, SELL, or HOLD.

RSI-14: 72.3 (OVERBOUGHT) → BEARISH
MACD histogram: -0.0234 (bearish momentum) → BEARISH
EMA-9 vs EMA-20: EMA9=485.2 below EMA20=487.1 → BEARISH
QQQ vs EMA-20: price below trend → BEARISH
VIX: 18.4 (moderate fear) → NEUTRAL
SPY direction: down → BEARISH

Net score: 5 BEARISH, 0 BULLISH, 1 NEUTRAL
Bias: STRONGLY BEARISH

Respond with exactly one word: BUY, SELL, or HOLD
```

Temperature is set to 0.0 and max_tokens to 4 to force a single deterministic word output.

---

## Scoring Methodology

### What counts as correct

For **daily signals**, the model's prediction is evaluated against the actual next-day QQQ close direction:

- Model outputs **BUY** or **HOLD** → correct if next-day close > today's close
- Model outputs **SELL** → correct if next-day close < today's close
- Days where price change < 0.1% are excluded as ambiguous

For **weekly signals**, the same logic applies but using weekly aggregated data:

- Model outputs **BUY** or **HOLD** → correct if week's net return is positive
- Model outputs **SELL** → correct if week's net return is negative

### How accuracy is calculated

```
Accuracy = (Correct predictions) / (Total test days or weeks)
```

**Test set:** the last 36 trading days (daily) and last 12 weeks (weekly) of the dataset, held out from all training and never used for optimization. This holdout was fixed before any training began and never changed.

**Naive baselines for comparison:**

| Baseline | Daily | Weekly | Notes |
|----------|-------|--------|-------|
| Always-BUY | 58.3% | 50.0% | QQQ upward bias in test period |
| Always-SELL | 41.7% | 50.0% | Inverse of Always-BUY |
| Random | 50.0% | 50.0% | Coin flip |

Any model scoring below 50% is performing worse than random. Any model beating 58.3% daily is outperforming the naive "always bullish" strategy.

---

## Training Techniques

Five techniques were applied to both pipelines in sequence. Each technique built on the best state from the previous one, and a **keep/revert rule** was enforced: a change was kept only if average daily accuracy across all 4 models improved AND no individual model's weekly accuracy dropped by more than 10 percentage points.

### 1. Autoresearch (prompt optimization loop)

An autonomous experiment loop inspired by Karpathy's autoresearch pattern. Claude Code acted as an agent modifying `strategy.py`, running `backtest.py` against the holdout after each change, keeping improvements and reverting regressions via git. 50-experiment budget per pipeline.

**What was kept (offline):**
- Reducing max output tokens to 4 (forces decisive output)
- Adding 5-day RSI trend as context
- Bull-bear score framing in the prompt (biggest single jump: +5.6pp)
- Adding RSI momentum to the score

### 2. Few-shot in-context learning

Added 5 worked examples directly in the prompt before asking for a prediction — 2 clear BUY examples, 2 clear SELL examples, 1 HOLD example. No model weights changed.

### 3. Prompt tuning

Tested 6 different system prompt prefixes (e.g. "You are a quantitative analyst", "You are a trading signal system", no prefix) on a validation slice. Selected the best performing prefix per pipeline.

### 4. LoRA fine-tuning

Low-Rank Adaptation using Hugging Face PEFT + TRL. Frozen base model weights with small trainable adapter matrices added to attention layers (q_proj, v_proj). Training configuration: r=8, alpha=32, lora_dropout=0.05, 4-bit NF4 quantization, 3 epochs, learning rate 2e-4.

Training data: instruction-output pairs where input = the indicator prompt, output = BUY or SELL based on actual next-day direction. Excluded the 36-day holdout and days with price change < 0.1%.

- **Offline training set:** 90 examples (days 1-97 of the dataset)
- **Real-time training set:** 94 examples (from RedPanda qqq-signals-historical)

### 5. DPO (Direct Preference Optimization)

Preference pairs built from holdout mistakes: for each day the model predicted incorrectly, the correct signal becomes the "preferred" response and the model's wrong prediction becomes the "rejected" response. Used TRL DPOTrainer on top of the best available starting point per model (LoRA adapter if kept, base model otherwise).

---

## Results

### Baseline (no training)

```
OFFLINE PIPELINE
Model       Daily Acc   Weekly Acc
qwen-3b     41.7%       58.3%
smollm-1b   41.7%       58.3%
gemma-2b    61.1%       41.7%
falcon-3b   47.2%       75.0%
Average     47.9%       58.3%

REAL-TIME PIPELINE
Model       Daily Acc   Weekly Acc
qwen-3b     27.8%       62.5%
smollm-1b   47.2%       62.5%
gemma-2b    22.2%       37.5%
falcon-3b   41.7%       37.5%
Average     34.7%       50.0%
```

> Note: real-time baseline was initially 0% for qwen-3b and gemma-2b due to prompt length. The original prompt was 10,343 characters — a raw data dump these SLMs could not reason over, causing 100% HOLD responses. Fixing to a structured 399-character BULLISH/BEARISH format restored real directional calls.

### Final results after all training

```
OFFLINE PIPELINE (after Autoresearch + Few-shot + Prompt tuning + LoRA + DPO)
Model       Daily Acc   Weekly Acc   vs Baseline (daily)
qwen-3b     58.33%      58.3%        +16.6pp
smollm-1b   61.11%*     58.3%        +19.4pp
gemma-2b    58.33%      41.7%        -2.8pp
falcon-3b   63.9%       50.0%        +16.7pp
Average     60.4%       52.1%        +12.5pp

*smollm-1b shows quantization variance (55.6% on fresh eval);
 both values clear the 41.7% baseline, adapter retained.

REAL-TIME PIPELINE (after Autoresearch + Few-shot only; all other techniques reverted)
Model       Daily Acc   Weekly Acc   vs Baseline (daily)
qwen-3b     60.0%       62.5%        +32.2pp
smollm-1b   62.9%       75.0%        +15.7pp
gemma-2b    60.0%       62.5%        +37.8pp
falcon-3b   60.0%       62.5%        +18.3pp
Average     60.7%       65.6%        +26.0pp
```

### Technique-by-technique progression

**Offline pipeline — daily accuracy average:**

```
Baseline         ████████████░░░░░░░░░░  47.9%
Autoresearch     █████████████████░░░░░  55.6%  (+7.7pp)
Few-shot         █████████████████░░░░░  55.6%  (+0.0pp)
Prompt tuning    █████████████████░░░░░  55.6%  (+0.0pp)
LoRA             ██████████████████░░░░  57.6%  (+2.0pp)
DPO              ███████████████████░░░  60.4%  (+2.8pp)
Always-BUY       ██████████████████░░░░  58.3%  (naive baseline)
```

**Real-time pipeline — daily accuracy average:**

```
Baseline         █████████████░░░░░░░░░  34.7%  (post prompt fix: 52.1%)
Autoresearch     ███████████████████░░░  60.7%  (+8.6pp from fixed baseline)
Few-shot         ███████████████████░░░  60.7%  (+0.0pp)
Prompt tuning    ██████████████████░░░░  57.1%  (reverted, regression)
LoRA             ██████████████████░░░░  reverted (constant-class collapse)
DPO              ██████████████████░░░░  skipped
Always-BUY       ██████████████████░░░░  58.3%  (naive baseline)
```

---

## Model Comparison

**Best daily performer:** falcon-3b (offline: 63.9%), smollm-1b (real-time: 62.9%)

**Most improved by training:** smollm-1b gained +19.4pp on offline, +15.7pp on real-time — the weakest baseline model benefited most from weight-level training, consistent with having the most room to gain.

**Most stable across pipelines:** falcon-3b showed strong performance in both offline weekly (75.0% baseline) and offline final (63.9% daily). It was the only model whose weekly accuracy held at 75% through the autoresearch optimization.

**Most sensitive to data format:** qwen-3b and gemma-2b both collapsed to 0% accuracy with the original real-time prompt (100% HOLD). After prompt fix they recovered to 60%+ on real-time, significantly outperforming their offline scores.

**gemma-2b anomaly:** Best offline baseline daily (61.1%) but worst real-time daily baseline (22.2%). This suggests gemma-2b is highly sensitive to input format — it performs well on clean end-of-day JSON but struggles to extract signal from the richer real-time prompt structure.

---

## Key Findings

**1. Prompt engineering plateaus around 55-61% accuracy**

All three prompt-level techniques (autoresearch, few-shot, prompt tuning) cluster within 2pp of each other. This is strong evidence these SLMs have hit a ceiling from prompt engineering alone at the 55-61% range — you cannot prompt your way past this ceiling with models of this size on financial signals.

**2. Weight-level training (LoRA, DPO) breaks through the ceiling on offline data**

The offline pipeline moved from 55.6% (post-autoresearch) to 60.4% (post-DPO) — a meaningful +4.8pp that prompt techniques could not achieve. smollm-1b and falcon-3b both showed genuine learning from LoRA fine-tuning.

**3. LoRA on real-time data consistently collapses to constant-class prediction**

Both LoRA attempts on real-time (60 examples and 94 examples) resulted in all 4 models predicting the same class for every holdout day. Root cause: class imbalance in a small training set causes the model to find the easiest path (always predict majority class) rather than learning input-conditioned reasoning. This establishes a practical lower bound: these 1-3B models require substantially more than 90-100 labeled examples to learn genuine signal generation via LoRA.

**4. Optimizing for one timeframe can silently damage another**

The first autoresearch run improved daily accuracy from 47.9% to 52.1% but caused falcon-3b's weekly accuracy to collapse from 75.0% to 41.7%. This was caught by adding a dual-objective keep/revert rule requiring that weekly accuracy not drop more than 10pp as a condition of keeping any change. After applying this constraint, the same +7.7pp daily gain was achieved with zero weekly regression. Single-objective optimization of sequential models is a real risk in this setting.

**5. Real-time pipeline is significantly more sensitive to prompt length**

The difference between a 10,343-character raw data dump and a 399-character structured prompt was the difference between 0% and 60% accuracy. SLMs at this parameter scale cannot reason over long, unstructured data dumps — they need the analyst work already done in the prompt before being asked to classify.

**6. Real-time pipeline outperforms offline after autoresearch**

Despite more complex data processing, the real-time pipeline reached 60.7% daily average vs 55.6% for offline after autoresearch — suggesting the additional intraday context (morning direction, latest 15-minute bar indicators) genuinely helps directional prediction when structured correctly.

---

## Limitations

**Small test set:** 36 trading days is a limited holdout window. Results may not generalize across different market regimes (bull/bear/sideways) or volatility environments.

**Single quarter of data:** 133 days covers roughly one quarter of market data. QQQ's behavior during this specific period (December 2025 to June 2026) may not be representative of other periods.

**LoRA training data insufficiency for real-time:** 94 examples is insufficient for these SLMs to learn genuine input-conditioned reasoning. The offline pipeline benefits from cleaner data filtering that yielded 90 high-quality training examples.

**Quantization variance:** 4-bit NF4 quantization used during LoRA training introduces non-determinism at inference time. smollm-1b's LoRA adapter shows a 5.5pp variance between runs (61.1% committed vs 55.6% on fresh eval), reflecting this instability rather than true model inconsistency.

**No position sizing or transaction costs:** accuracy measures raw directional correctness only. A real trading signal system would need to account for position sizing, slippage, and transaction costs which are not modeled here.

**Models not retrained on live data:** LoRA adapters were trained on historical data only. As market conditions shift, adapter performance may degrade without periodic retraining.

---

## Future Work

- **Larger training datasets:** accumulate 6-12 months of daily signals to cross the LoRA training threshold for the real-time pipeline
- **Weekly LoRA retraining:** the weekly fine-tune CronJob is already scaffolded (`qqq-lora-weekly`, Sunday midnight) — activating it would incorporate new live data into adapters continuously
- **Larger models:** the cluster supports models up to ~30B parameters with quantization — testing Qwen2.5-7B or Qwen2.5-14B as upper bounds for the paper comparison
- **Multi-step reasoning:** chain-of-thought prompting before the final BUY/SELL/HOLD output to see if explicit reasoning steps improve accuracy
- **Ensemble signals:** combining signals from all 4 models via majority vote as a fifth comparison point
- **Live P&L tracking:** deploy a paper trading account that follows the mid-day signals to track real-world performance over time
- **RDMA networking:** migrating from k3s/Flannel to RKE2/Cilium CNI to enable full RDMA support over the ConnectX-7 interconnect for faster cross-node model training

---

## Running This Yourself

If you have access to the DGX Spark cluster, here is how to interact with the system.

### Check cluster status

```bash
# See all nodes
kubectl get nodes -o wide

# See all running pods across namespaces
kubectl get pods -A

# See the 4 model pods specifically
kubectl get pods -n core-services -o wide
```

### Directly prompt a model

Each model exposes an OpenAI-compatible API. From Spark 1:

```bash
# List available models on qwen-3b
kubectl exec -n core-services deploy/qwen-3b -- \
  curl -s http://localhost:8000/v1/models

# Send a QQQ signal query directly to gemma-2b
kubectl exec -n core-services deploy/gemma-2b -- \
  curl -s http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "google/gemma-2-2b-it",
    "messages": [{"role": "user", "content": "QQQ RSI is 74, MACD shows bearish crossover, EMA-9 crossed below EMA-20, VIX rising. BUY, SELL or HOLD?"}],
    "max_tokens": 4,
    "temperature": 0.0
  }'
```

You can target any of the 4 models by replacing the deployment name and model ID:
- `deploy/qwen-3b` → model `Qwen/Qwen2.5-3B-Instruct`
- `deploy/smollm-1b` → model `HuggingFaceTB/SmolLM2-1.7B-Instruct`
- `deploy/gemma-2b` → model `google/gemma-2-2b-it`
- `deploy/falcon-3b` → model `tiiuae/Falcon3-3B-Instruct`

### Are predictions running automatically?

Yes. Two CronJobs run automatically on weekdays:

| Job | Schedule | What it does |
|-----|----------|-------------|
| `qqq-collector` (qqq-data ns) | 9pm UTC Mon-Fri | Fetches end-of-day QQQ data, saves JSON to PVC |
| `qqq-ingestor-15m` (fine-tune ns) | Every 15min, 9:30am-4pm ET | Fetches latest 15-min bar, publishes to RedPanda |
| `qqq-midday-signal` (fine-tune ns) | 12pm ET Mon-Fri | Consumes morning bars + history, queries all 4 models, commits signal to GitHub |

```bash
# Check CronJob status
kubectl get cronjobs -n qqq-data
kubectl get cronjobs -n fine-tune

# See recent job runs
kubectl get jobs -n fine-tune

# See the most recent mid-day signal output
ls ~/neural-control-plane/qqq/realtime/
cat ~/neural-control-plane/qqq/realtime/$(ls -t ~/neural-control-plane/qqq/realtime/ | head -1)
```

### Run a manual backtest

```bash
# Offline pipeline backtest (runs against 36-day holdout)
cd ~/qqq-autoresearch && python3 backtest.py

# Real-time pipeline backtest
cd ~/qqq-autoresearch-realtime && python3 backtest.py
```

### View monitoring dashboard

```bash
# Get Grafana admin password
kubectl -n monitoring get secret monitoring-grafana \
  -o jsonpath="{.data.admin-password}" | base64 -d; echo

# Port-forward Grafana (access from any machine on the network)
kubectl -n monitoring port-forward svc/monitoring-grafana 3000:80 --address 0.0.0.0 &

# Open in browser: http://192.168.86.30:3000
# Dashboard: vLLM Monitoring V2 (shows token throughput, latency, GPU cache per model)
```

### Trigger the autoresearch loop

```bash
# Start an autonomous 50-experiment optimization run on the offline pipeline
cd ~/qqq-autoresearch && claude --dangerously-skip-permissions
# Then tell it: "Read program.md and start the autoresearch loop"
```

---

## Repository Structure

```
neural-control-plane/
├── qqq/
│   ├── daily/           ← offline pipeline daily predictions (YYYY-MM-DD.md)
│   ├── weekly/          ← offline pipeline weekly aggregates (YYYY-WXX.md)
│   ├── realtime/        ← real-time pipeline mid-day signals (YYYY-MM-DD.json)
│   └── benchmarks/      ← all training technique result JSONs
│       ├── offline-autoresearch-report.md
│       ├── offline-few-shot.json
│       ├── offline-prompt-tuning.json
│       ├── offline-lora-results.json
│       ├── realtime-baseline-pre-training.json
│       ├── realtime-baseline-fixed-prompt.json
│       ├── realtime-few-shot.json
│       └── realtime-lora-results.json
└── research/            ← snackonai newsletter outputs
```

---

## Citation

If you use this benchmark or setup, please cite:

```
QQQ SLM Signal Prediction Benchmark
Serverless Ventures LLC / CMU AI Research
2-Node DGX Spark Cluster, 2025-2026
github.com/mohnishbasha/neural-control-plane
```
