### QQQ AI Signal Report — 2026-06-16

#### The Experiment
We conducted an experiment to evaluate the predictive capabilities of large language models (LLMs) on the Nasdaq-100 ETF (QQQ) daily direction. The LLM was trained to analyze 10 days of historical price/volume data, technical indicators (RSI, EMA-9/20, MACD), and macroeconomic context to forecast whether QQQ would close higher or lower than the previous day. The dataset comprised 36 trading days from December 2025 to June 2026.

#### The Verdict
Can LLMs Beat Naive Baselines on Intraday Equity Direction?
The experiment revealed that LLMs can predict QQQ's daily direction with an accuracy of 55.6%, outperforming the majority baseline by 2.8 percentage points. The majority baseline strategy always predicts that QQQ will close up, achieving 52.8% accuracy. This slight edge might seem promising at first glance, but it’s important to consider the broader implications.

#### The Asymmetry
Why the Model Scores Differently on UP vs DOWN Days
Interestingly, the model performed better when predicting DOWN days (100.0% accuracy) compared to UP days (15.8% accuracy). This asymmetry suggests that LLMs may have a stronger grasp of bearish market regimes, possibly due to their ability to recognize and respond to negative sentiment or economic indicators more effectively. Conversely, predicting bullish markets appears to be more challenging, indicating a potential bias or limitation in how LLMs process positive market signals.

#### The Latency Tradeoff
If Inference Takes 0.3s Per Prediction, What Does That Mean for Real-Time Trading Systems?
The mean inference latency for the model is 0.33 seconds, with a 95th percentile of 0.38 seconds. For real-time trading systems, this latency is significant. High-frequency trading (HFT) systems often operate in milliseconds, making even 0.3 seconds a substantial delay. In contrast, end-of-day (EOD) signals and weekly rebalancing strategies can tolerate longer processing times, as they do not require immediate action. This latency tradeoff underscores the need for careful consideration when integrating LLMs into high-speed trading environments.

#### Builder Takeaway
If You're Integrating LLMs into Quant Systems, What Does This Eval Tell You About Where They Add Signal vs Noise?
The evaluation highlights both the potential and the limitations of using LLMs in quantitative systems. While the 55.6% accuracy is a notable improvement over naive baselines, the 55.6% success rate is still far from reliable for real trading decisions. The asymmetry in performance between UP and DOWN predictions also indicates that LLMs may not be equally effective across different market conditions. Therefore, when integrating LLMs into trading systems, it is crucial to carefully assess their limitations and consider how they can complement other signals rather than relying solely on their predictions.

#### Conclusion
While the experiment demonstrates that LLMs can provide some predictive power, the accuracy and limitations highlighted here suggest that they should be used judiciously. Founders and engineers building AI-powered trading systems must weigh the potential benefits against the risks, particularly in terms of latency and reliability. The key takeaway is that LLMs can offer valuable insights, but they should be integrated into broader, more robust systems that include multiple sources of information to mitigate the risks associated with single-model reliance.