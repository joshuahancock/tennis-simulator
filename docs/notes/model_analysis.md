# Tennis Simulator Model Analysis

**Last Updated:** 2026-02-15
**Data:** H1 2024, clean (no data leakage)

## Current Models Overview

| Model | Accuracy | Brier Score | vs Market |
|-------|----------|-------------|-----------|
| **Market Favorite** | 67.2% | — | baseline |
| **Elo (surface-specific)** | 60.8% | 0.2331 | -6.4pp |
| **Monte Carlo** | 56.0% | 0.2451 | -11.2pp |

Neither model beats the market on overall accuracy. However, **subsets with positive betting edge exist**.

---

## Monte Carlo Model: How It Works

### The Core Probability: P(Server Wins Point)

```
P(server wins) ≈ first_in% × first_won% + (1 - first_in%) × second_won%
```

### The Adjustment Formula

```r
avg_return_vs_first <- 0.35  # Hardcoded tour average
adjustment <- avg_return_vs_first - returner_stats$return_vs_first
win_prob <- server_stats$first_won_pct + adjustment
```

### MC Model Problems

1. **Double-counting** - Opposition quality baked into stats, then adjusted again
2. **Hardcoded tour averages** - Don't vary by surface/era/level
3. **No matchup-specific info** - Same formula for all player types
4. **Stats too stable** - Career averages miss current form

---

## Elo Model: How It Works

Standard Elo formula with surface-specific ratings:

```r
P(A beats B) = 1 / (1 + 10^((elo_B - elo_A) / 400))
```

Configuration: K=32, surface blend with overall rating

### Elo Model Problems

1. **Trajectory lag** - Accumulated rating capital creates inertia
2. **Over-confident on favorites** - Calibration error up to 9.6pp
3. **Anti-informative when disagreeing** - 34.7% accuracy on disagreements

---

## Key Finding: When Models Disagree with Market

### Elo vs Market Disagreements (N=317, 21% of matches)

| Scenario | Elo Accuracy | Market Accuracy |
|----------|--------------|-----------------|
| Agree | 67.8% | 67.8% |
| **Disagree** | **34.7%** | **65.3%** |

**Statistical test:** Elo accuracy on disagreements is significantly below 50% (p < 0.001). When Elo disagrees with market, it's not just uninformative—it's *anti-informative*.

### Against Strong Favorites (<1.40 odds)

When Elo picks against strong market favorites:
- **N = 44 matches**
- **Elo accuracy: 15.9%**
- **Average probability gap: 35pp**

---

## Calibration Analysis

| Prediction Range | N | Predicted | Actual | Error |
|-----------------|---|-----------|--------|-------|
| 0-30% (underdogs) | 414 | 20.3% | 26.8% | +6.5pp under-confident |
| 40-60% (toss-ups) | 1,252 | 50.1% | 50.1% | ±0.5pp well-calibrated |
| 70-100% (favorites) | 873 | 76.9% | 70.7% | -6.2pp over-confident |

**Pattern:** Elo systematically overrates favorites and underrates underdogs.

---

## Betting Edge: Multi-Year Validation

### "Agree But Less Confident" Signal — DOES NOT REPLICATE

**Original finding (single period):** +6.4% ROI seemed promising.

**Multi-year validation (H1 2021-2024):**

| Period | N | Win Rate | ROI |
|--------|---|----------|-----|
| H1 2021 | 151 | 72.2% | -4.0% |
| H1 2022 | 181 | 68.5% | -3.9% |
| H1 2023 | 197 | 67.0% | -6.7% |
| H1 2024 | 191 | 68.6% | -4.4% |
| **Pooled** | **720** | **68.9%** | **-4.8%** |

**Result: 0/4 years positive. Pooled p-value = 0.72. Signal is spurious.**

### Out-of-Sample: H2 2024

| Metric | Value |
|--------|-------|
| N | 107 matches |
| Win rate | 72.9% |
| ROI | +2.6% |
| p-value | 0.23 |

H2 2024 shows marginal positive ROI but not statistically significant.

### Platt Scaling Results

Calibration correction confirms Elo overconfidence (b = 0.75 < 1):

| Metric | Raw Elo | Platt-Scaled | Improvement |
|--------|---------|--------------|-------------|
| Brier | 0.2259 | 0.2244 | 0.7% |
| Log Loss | 0.6434 | 0.6390 | 0.7% |
| Accuracy | 62.7% | 63.0% | +0.3pp |
| ROI | -4.19% | -2.76% | +1.4pp |

Platt scaling provides modest improvement but does not create positive edge.

### Interpretation

The original +6.4% ROI finding was likely a statistical artifact from:
1. Single-period testing without out-of-sample validation
2. Multiple testing across many subsets (50+)
3. Possible data differences (pre- vs post-leakage fix)

---

## K-Factor Sensitivity

| K | Accuracy | Brier Score |
|---|----------|-------------|
| 24 | 63.7% | 0.2162 |
| 32 | 63.8% | 0.2164 |
| 48 | 63.8% | 0.2179 |
| 64 | 64.2% | 0.2203 |

Higher K improves accuracy slightly but worsens calibration (Brier). The trajectory lag problem is not fully solved by K-factor adjustment alone.

---

## Statistical Tests Summary

| Test | Result | p-value |
|------|--------|---------|
| Elo accuracy on disagreements = 50% | Reject (34.7% << 50%) | < 0.001 |
| Elo vs Market accuracy (McNemar) | Market significantly better | < 0.001 |
| Betting edge in positive subset | Edge exists | 0.041 |

---

## Matchup & Feature Analysis

### Height Differential (R vs R only)

| Height | N | Accuracy | ROI |
|--------|---|----------|-----|
| Winner taller >3cm | 2,390 | 68.9% | +1.75% |
| Similar height | 1,930 | 62.8% | -0.94% |
| Winner shorter >3cm | 1,897 | 52.5% | -12.02% |

**CAUTION:** This uses ex-post winner height, not Elo pick height.
When reframed as "Elo pick is taller", ROI becomes **negative** (-2.6% to -4.8%).

### Fatigue/Scheduling

Market prices fatigue efficiently. No edge found.

### Handedness

L vs R matchups show consistent negative ROI (-6.72%). Elo underperforms.

---

## Recommendations

### Do Not

1. Bet when Elo disagrees with market (especially vs strong favorites)
2. Trust "agree but less confident" signal (does not replicate)
3. Use height or fatigue as betting filters (either priced in or hindsight bias)
4. Bet L vs R matchups (consistent Elo underperformance)

### Do

1. Apply Platt scaling to reduce overconfidence (+1.4pp ROI improvement)
2. Test any signal across multiple years before deployment
3. Apply multiple testing correction to all subset analyses

---

## Completed Analysis (2026-02-15)

| Task | Result |
|------|--------|
| Multi-year validation of "agree but less confident" | **Spurious** - 0/4 years positive, pooled ROI -4.8% |
| Scoreline-weighted Elo (Angelini et al.) | **No improvement** - ROI -0.64pp worse |
| Prospective paper trade H2 2024 | **Negative** - ROI -4.37%, 879 bets |
| Multiple testing correction | **0 tests** survive Bonferroni out of 35 |

---

## Calibration-Based Edge Analysis (2026-02-16)

### Strategy: Bet Underdogs Where Calibrated Prob > Market Prob

Using Platt-scaled Elo probabilities to identify underpriced underdogs.

### 2021-2024 Results by Odds Range (Edge 0-10%)

| Odds Range | N | Win Rate | Breakeven | ROI | Years Positive |
|------------|---|----------|-----------|-----|----------------|
| 1.0-2.0 | 112 | 31.2% | 50.5% | +13.4% | 2/4 |
| **2.0-2.5** | **1205** | **47.1%** | **44.4%** | **+5.16%** | **3/4** |
| 2.5-3.0 | 559 | 35.8% | 36.6% | -3.54% | 2/4 |
| 3.0-4.0 | 445 | 29.7% | 29.3% | -0.18% | 1/4 |
| 4.0+ | 608 | 15.5% | 12.7% | -11.15% | 1/4 |

The 2.0-2.5 range looked most promising: large N, positive ROI, consistent across years.

### True Out-of-Sample: 2025

| Odds Range | N | ROI (2021-2024) | ROI (2025 OOS) |
|------------|---|-----------------|----------------|
| 2.0-2.5 | 272 | +5.16% | **-2.29%** |
| 3.0-4.0 | 129 | -0.18% | **+23.67%** |
| 4.0+ | 98 | -11.15% | **+24.24%** |

**Pattern reversal:** Strategies that worked in training failed in OOS, and vice versa.

### Market Calibration Drift Analysis

Question: Are longshots genuinely winning more often, independent of our model?

| Year | 4.0+ Win Rate | Breakeven | Excess | ROI |
|------|---------------|-----------|--------|-----|
| 2021 | 15.7% | 12.9% | +2.8pp | -10.9% |
| 2022 | 14.3% | 13.5% | +0.7pp | -16.4% |
| 2023 | 14.4% | 12.7% | +1.7pp | -19.9% |
| 2024 | 14.0% | 12.4% | +1.7pp | -13.1% |
| 2025 | **17.2%** | 12.1% | **+5.0pp** | **+1.5%** |

**Trend test:** p=0.60. Year-to-year variation is random noise.

**2025 vs 2021-2024 comparison:** p=0.12. Not statistically significant.

### Interpretation

1. The 2.0-2.5 strategy showed promise in-sample but failed in true OOS
2. High-odds strategies that failed in training randomly succeeded in 2025
3. Raw market data shows 2025 longshot outperformance, but not statistically significant
4. Year-to-year variance is substantial (~20pp ROI swings within same strategy)
5. 5-year sample may be insufficient to distinguish signal from noise

### Key Files

- `r_analysis/analysis/calibration_edge_deep.R` - Main edge analysis
- `r_analysis/analysis/test_2025_oos.R` - 2025 out-of-sample test
- `r_analysis/analysis/high_odds_validation.R` - High odds validation
- `r_analysis/analysis/market_calibration_drift.R` - Raw market calibration

---

## Trajectory Analysis (2026-02-18)

### Hypothesis

Elo ratings have "trajectory lag" - they take time to adjust to rapid skill changes. Players who are falling (winning less than Elo predicts) may be mispriced.

### Trajectory Calculation

For each match, calculate Elo pick's trajectory over last 10 matches:
```
trajectory = (actual_wins - expected_wins) / n_matches
```

Negative trajectory = player winning less than Elo expected = "falling"

### Initial Results (CONTAINED CALCULATION ERROR)

Initial analysis appeared to show a +10.7% ROI edge betting against falling Elo picks. However, this was due to using **vig-removed "fair" odds** instead of actual betting odds.

**The error:**
```r
# Wrong: derived "fair" odds ~2.5% higher than actual
mkt_prob_w <- (1/PSW) / (1/PSW + 1/PSL)  # Removes vig
elo_opp_odds <- 1 / (1 - mkt_prob_w)      # Fair odds, not actual

# Correct: use actual betting odds
elo_opp_odds <- PSL  # What you actually get paid
```

### Corrected Results (Actual Betting Odds)

**Strategy:** Bet against Elo pick when trajectory < -20%, opponent odds 3.0-5.0

| Year | N | Win Rate | Breakeven | ROI |
|------|---|----------|-----------|-----|
| 2021 | 75 | 26.7% | 26.7% | -3.9% |
| 2022 | 76 | 23.7% | 26.7% | -14.7% |
| 2023 | 101 | 30.7% | 26.7% | +13.0% |
| 2024 | 48 | 27.1% | 26.7% | -2.4% |
| **Total** | **300** | **27.3%** | **26.7%** | **-0.7%** |

**95% CI for ROI:** [-19.3%, +17.9%]

### Comparison: Error vs Corrected

| Metric | With Error | Corrected |
|--------|------------|-----------|
| ROI | +10.7% | **-0.7%** |
| Years positive | 4/4 | 1/4 |

### Conclusion

**No edge exists.** The apparent +10.7% ROI was almost entirely due to the ~2.5% odds inflation from the calculation error. After correction, ROI is essentially zero.

### Key Files

- `r_analysis/analysis/trajectory_analysis.R` - Main trajectory analysis
- `r_analysis/analysis/trajectory_contrarian.R` - Contrarian strategy deep dive
- `docs/notes/trajectory_analysis_summary.md` - Detailed summary of error and correction

---

## Future Directions

1. ~~**Player trajectory detection**~~ ✓ Completed - found contrarian signal

2. **Ingram-style Bayesian MC model** - Separate serve/return skills with time evolution. More sophisticated than simple Elo.

3. **Point-level features** - Rally length, serve direction patterns. Would require charting data.

4. **Live betting** - Different market dynamics might offer opportunities not present in pre-match odds.

5. **Longer time series** - 2021-2025 is only 5 years. Extending to 2015-2025 would provide more statistical power to detect edges.
