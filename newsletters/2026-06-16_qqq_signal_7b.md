### QQQ AI Signal Report — 2026-06-16

#### The Experiment

In an effort to assess the viability of large language models (LLMs) in predicting the Nasdaq-100 ETF (QQQ) daily direction, we conducted a comprehensive experiment using Qwen/Qwen2.5-7B-Instruct. The model was prompted with 10 days of historical price/volume data, technical indicators such as RSI, EMA-9/20, MACD, and macroeconomic context to predict whether QQQ would close UP or DOWN. The lookback window was set at 10 trading days, and predictions were classified based on a threshold of ±1.19% movement, excluding days with minor fluctuations as noise. Over a period of 36 evaluated trading days from December 2025 to June 2026, the model’s performance was rigorously analyzed.

#### The Verdict

Can LLMs beat naive baselines on intraday equity direction? The answer, based on our experiment, is a qualified yes. The LLM achieved a 55.6% accuracy rate, outperforming the majority baseline (always-predict-UP strategy) by 2.8 percentage points. This slight edge might seem modest, but it’s worth noting that the majority baseline itself is a simple heuristic. While the LLM’s performance is promising, it falls short of being a reliable signal for trading decisions.

#### The Asymmetry

One of the most intriguing findings from our experiment is the model's asymmetric performance on UP versus DOWN days. The model showed a higher accuracy in predicting DOWN days (64.7%) compared to UP days (47.4%). This bias towards bearish predictions reveals how LLMs may systematically underestimate bullish market regimes. Such asymmetry could have significant implications for traders relying on these models for decision-making, especially during periods of market optimism.

#### The Latency Tradeoff

In terms of inference latency, the model performed relatively well, with a mean inference time of 0.67 seconds and a 95th percentile of 0.66 seconds. However, this latency is crucial when considering real-time trading systems. Comparing this to high-frequency trading (HFT), which operates on sub-millisecond timescales, the 0.7-second latency makes the LLM less suitable for ultra-fast trading strategies. For end-of-day (EOD) signals or weekly rebalancing, the latency is less of an issue, but it still represents a tradeoff between model accuracy and practical application.

#### Builder Takeaway

For engineers and founders building AI-powered quant systems, this evaluation offers several key insights. First, while LLMs can provide a small edge over naive baselines, their performance is not yet robust enough to be a primary signal in trading decisions. Second, the model's bias towards bearish predictions suggests that developers should be cautious about over-relying on LLMs for bullish market regimes. Third, the latency of 0.7 seconds is a critical consideration, especially in fast-moving markets. Developers should consider how to integrate LLMs into systems that can handle such latency, possibly through hybrid approaches that combine LLM predictions with faster, more specialized models.

In conclusion, the experiment highlights both the potential and the limitations of LLMs in predicting equity direction. While the 55.6% accuracy is encouraging, the model’s bias and latency are important factors to consider. For now, LLMs should be seen as a valuable supplementary tool rather than a standalone solution for quantitative trading.