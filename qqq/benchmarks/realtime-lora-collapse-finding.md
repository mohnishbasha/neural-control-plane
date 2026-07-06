# Realtime LoRA fine-tuning: training-data-insufficiency finding

## Summary

Four separate realtime LoRA fine-tuning attempts across all 4 models
(qwen-3b, smollm-1b, gemma-2b, falcon-3b) were run, varying prompt format,
dataset size, and epoch count. **All 16 individual training runs (4
models x 4 experiments) were reverted** -- none beat their per-model
baseline. All 4 adapters are marked **reverted**; no realtime LoRA
adapter is currently kept.

## Experiments

| Run | Data source | Train examples | Prompt format | Epochs | Result |
|---|---|---|---|---|---|
| Original retry | RedPanda, date-range holdout | 94 | `strategy.py build_daily_prompt()` | 3 | all reverted, ~60.7% avg (near baseline) |
| build_prompt() retry | RedPanda, last-36-holdout, skip <0.1% moves | 89 | `midday_signal.py build_prompt()` | 3 | all reverted, 40.6-53.1% (well below baseline) |
| build_daily_prompt() isolation | same data as above | 89 | `strategy.py build_daily_prompt()` | 3 | all reverted, exactly 50.0% for all 4 |
| More examples / fewer epochs | RedPanda, last-36-holdout, no skip threshold | 102 | `strategy.py build_daily_prompt()` | 1 | all reverted, 43.3-56.7% |

## Root cause: constant-class collapse, not prompt format

Inspecting actual per-row predictions (not just aggregate accuracy) shows
that in nearly every one of the 16 runs, the fine-tuned model **predicts
the same class (all BUY, or all SELL) for every single holdout example**,
regardless of that example's input data. The reported accuracy numbers are
just the base rate of whichever class the model collapsed to, matching
the holdout's actual class balance almost exactly (e.g. a holdout that is
15 UP / 15 DOWN produces exactly 50.00% for an always-BUY policy).

Swapping prompt format changed *which* constant class the model collapsed
to, not whether it collapsed -- ruling out prompt format as the cause.
Increasing training examples (~94 -> 102) and cutting epochs (3 -> 1)
reduced collapse severity for qwen-3b (56.67%, and its holdout predictions
showed some real per-example variation for the first time) but did not
fix it for the other 3 models.

## Conclusion

LoRA fine-tuning (r=8, alpha=32, q_proj/v_proj, 4-bit nf4) on ~90-100
labeled examples is not enough signal for these small models (1-3B params)
to learn genuine input-conditioned next-day-direction reasoning. Instead,
gradient descent finds the trivial degenerate solution: shift the output
distribution toward whichever label was more common in the (small, noisy)
training set. This is a **training data insufficiency** problem, not a
prompt engineering or hyperparameter problem.

## Recommendation

Do not continue realtime LoRA SFT attempts without a materially larger
labeled dataset (likely several hundred+ examples, vs. the ~90-130
currently available from the RedPanda historical topic). DPO on top of
these collapsed adapters would not help either, since DPO fine-tunes
*preferences between two behaviors* -- it cannot manufacture directional
signal that was never learned in the first place.
