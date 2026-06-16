# QQQ AI Signal Report — 2026-06-16

## Key Findings

### Most Counterintuitive Finding
Despite the overall accuracy of 55.6%, the model performed poorly in predicting downward trends, with only 64.7% accuracy compared to 47.4% for upward trends. This suggests that the model is more adept at identifying bullish signals rather than bearish ones.

## Model Performance Breakdown

### Overall Accuracy
- **Accuracy:** 55.6% (20 out of 36 days)
- **Majority Baseline Accuracy:** 52.8%
- **Edge Over Majority Baseline:** +2.8 percentage points

### Performance on Specific Trends
- **UP Accuracy:** 47.4% (19 actual UP days correctly predicted)
- **DOWN Accuracy:** 64.7% (17 actual DOWN days correctly predicted)

## Recent Predictions

| Date       | Actual    | Predicted | Result |
|------------|-----------|-----------|--------|
| 2026-04-24 | UP        | UP        | ✓      |
| 2026-05-05 | UP        | UP        | ✓      |
| 2026-05-06 | UP        | UP        | ✓      |
| 2026-05-08 | UP        | UP        | ✓      |
| 2026-05-15 | DOWN      | UP        | ✗      |
| 2026-05-20 | UP        | DOWN      | ✗      |
| 2026-06-05 | DOWN      | DOWN      | ✓      |
| 2026-06-08 | UP        | DOWN      | ✗      |
| 2026-06-11 | DOWN      | DOWN      | ✓      |
| 2026-06-16 | UP        | DOWN      | ✗      |

## Latency Analysis

- **Mean Inference Latency:** 0.67 seconds
- **P95 Inference Latency:** 0.66 seconds

## So What for Builders

The model shows promise in predicting upward trends but struggles with downward trends. This imbalance could be due to the dataset skew towards bull markets or the nature of the features used. For builders, this indicates the need for a more nuanced approach to feature engineering and potentially a reevaluation of the training data distribution.

To improve the model, consider:
1. **Balancing the Dataset:** Ensure that both up and down market conditions are equally represented.
2. **Feature Engineering:** Incorporate more granular and relevant features that capture the nuances of market downturns.
3. **Model Tuning:** Experiment with different architectures and hyperparameters to better capture the complexities of bearish signals.

By addressing these areas, you can enhance the robustness of your AI models and make them more reliable for both up and down market conditions.