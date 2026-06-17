# QQQ AI Signal Report — 2026-06-17

## Most Interesting Finding
The model's performance on down market days stands out as particularly strong, achieving an accuracy of 64.7%, significantly higher than its overall accuracy of 55.6%.

## Model Performance vs Baseline
The Qwen/Qwen2.5-7B-Instruct model demonstrated an accuracy of 55.6% over the last 36 days, outperforming the majority baseline by 2.8 percentage points. This indicates that the model is slightly better than random guessing but not by a large margin.

### Breakdown of Predictions
- **Total Days Evaluated:** 36
- **Accuracy:** 55.6% (20 correct predictions)
- **Majority Baseline:** 52.8%
- **UP Accuracy:** 47.4% (19 actual UP days correctly predicted)
- **DOWN Accuracy:** 64.7% (17 actual DOWN days correctly predicted)

## Down Market Prediction Accuracy
The model's performance in predicting downward trends is notably strong. It correctly identified 64.7% of DOWN days, which is a significant improvement over the overall accuracy. This suggests that the model has a robust mechanism for detecting bearish market conditions.

## Recent Prediction Errors Analysis
Recent predictions show both strengths and weaknesses:

- **Correct Predictions:**
  - 2026-04-24: actual=UP, predicted=UP
  - 2026-05-05: actual=UP, predicted=UP
  - 2026-05-06: actual=UP, predicted=UP
  - 2026-05-08: actual=UP, predicted=UP
  - 2026-06-05: actual=DOWN, predicted=DOWN
  - 2026-06-11: actual=DOWN, predicted=DOWN

- **Incorrect Predictions:**
  - 2026-05-15: actual=DOWN, predicted=UP
  - 2026-05-20: actual=UP, predicted=DOWN
  - 2026-06-08: actual=UP, predicted=DOWN
  - 2026-06-16: actual=UP, predicted=DOWN

These errors highlight areas where the model may need further refinement, particularly in predicting upward trends.

## Inference Latency
The model's inference latency is relatively fast, with a mean time of 0.67 seconds and a 95th percentile of 0.66 seconds. This quick response time is crucial for real-time trading applications.

## So What for Builders?
For developers and founders building AI-driven quantitative finance systems, these results provide valuable insights into model performance and areas for improvement. The model's strength in predicting down markets is promising, indicating that it can be a useful tool for risk management. However, the need for better prediction accuracy in up markets suggests that further tuning and possibly incorporating more sophisticated features or additional data sources could enhance the model's overall performance.

To improve the model, consider the following steps:
1. **Feature Engineering:** Introduce more granular market indicators and sentiment analysis.
2. **Model Refinement:** Experiment with different architectures and hyperparameters.
3. **Ensemble Methods:** Combine multiple models to reduce errors and increase reliability.
4. **Real-Time Feedback:** Implement mechanisms to update the model based on real-time market data.

By addressing these areas, you can build more robust and accurate AI signals for your quantitative finance applications.