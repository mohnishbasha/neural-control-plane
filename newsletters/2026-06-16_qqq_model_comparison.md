# QQQ Model Comparison: 7B vs 3B — 2026-06-16

## The Setup
Two Qwen2.5-Instruct models were evaluated head-to-head on identical tasks. Both models used the same dataset and prompt configuration:

- **Dataset**: 36 QQQ trading days (filtered from 116 total after applying a ±1.19% threshold).
- **Prompt**: 10-day lookback with RSI, EMA, and MACD features, resulting in binary predictions of UP or DOWN.

Both models were deployed on single-node setups:
- **7B model**: Served on spark-720e.
- **3B model**: Served on spark-7229.

## The Headline Finding: A Tie in Accuracy, Completely Different Behavior

The two models achieved the same accuracy of 55.6% (20 out of 36 correct predictions). However, their underlying behaviors were markedly different.

### Data Table
| Metric | Qwen2.5-7B-Instruct | Qwen2.5-3B-Instruct |
|--------|---------------------|---------------------|
| Accuracy | 55.6% (20/36) | 55.6% (20/36) |
| Majority baseline | 52.8% | 52.8% |
| Edge over baseline | +2.8pp | +2.8pp |
| DOWN day accuracy | 64.7% (11/17) | **100% (17/17)** |
| UP day accuracy | **47.4% (9/19)** | 15.8% (3/19) |
| Mean latency | 0.67s | **0.33s** |
| p50 latency | 0.64s | 0.28s |
| p95 latency | 0.66s | 0.38s |

### Behavioral Analysis

#### 7B: Calibrated but slow
The 7B model makes genuinely balanced predictions. It identifies UP days 47.4% of the time and DOWN days 64.7% of the time. While it did miss some DOWN days (got 11 out of 17 correct), it attempted UP predictions and got 9 out of 19 right. This suggests that the 7B is trying to understand the market direction rather than defaulting to a safe regime.

#### 3B: Degenerate DOWN predictor, 2x faster
The 3B model is essentially a DOWN oracle. It predicted DOWN for almost every sample, getting 100% of the 17 DOWN days correct while identifying only 3 out of 19 UP days (15.8%). This results in the same 55.6% accuracy — but purely because there were more DOWN days in the sample. If the model were run on a bull-market period with more UP days, its performance would fall significantly below the majority baseline.

## The Production Question

### What the Tie Actually Means
The same accuracy number hides completely different underlying behaviors. The 3B's accuracy is dataset-dependent; it excels when the majority of the data points align with its prediction. In contrast, the 7B's accuracy is more robust and less dependent on the distribution of data points.

### The 2x Latency Advantage
The 3B model offers a significant latency advantage:
- **Mean latency**: 0.33s vs 0.67s.
- **p50 latency**: 0.28s vs 0.64s.
- **p95 latency**: 0.38s vs 0.66s.

At end-of-day (EOD) batch prediction, this difference might be negligible. However, in scenarios involving intraday signal generation with hundreds of instruments, the 3B's speed becomes a critical factor.

### When to Use 3B
If your system can detect market regimes (bull/bear) and only deploys the signal during bearish regimes, the 3B's 100% DOWN precision is actually useful. By leveraging the model's strength in predicting DOWN days, you can optimize your trading strategy for bear markets.

### The Degenerate Model Trap
The 3B serves as a cautionary tale about relying solely on eval metrics like overall accuracy. A model achieving high accuracy can still exhibit catastrophic failure if its predictions are degenerate. Always break down performance by label to ensure the model is not collapsing into a degenerate state.

### What a Production System Would Need
A robust production system should include the following components:
- **Per-label accuracy thresholds**: Ensure that the model meets specific accuracy requirements for each label.
- **Regime detection**: Implement mechanisms to detect market regimes and conditionally deploy signals.
- **Latency SLAs**: Define service-level agreements around response times to meet real-time requirements.
- **Cost-per-signal tradeoffs**: Evaluate the cost of each prediction to balance between accuracy and efficiency.

## Conclusion
In summary, while both models achieve the same accuracy, their behaviors and performance characteristics differ significantly. The 7B model provides a more balanced and robust approach, whereas the 3B model, though faster, is a degenerate predictor that performs well only under specific conditions. Founders and quant engineers must carefully consider these factors when deploying models in production environments.