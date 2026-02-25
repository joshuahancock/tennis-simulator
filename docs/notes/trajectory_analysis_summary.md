# Trajectory Analysis Summary

**Date:** 2026-02-18
**Status:** No actionable edge found (calculation error corrected)

---

## Hypothesis

Elo ratings have "trajectory lag" — they take time to adjust to rapid skill changes. Players who are "falling" (winning less than Elo predicts) may be mispriced. Betting against falling Elo picks could capture this adjustment gap.

## Methodology

**Trajectory calculation:** For each match, calculate Elo pick's trajectory over last 10 matches:
```
trajectory = (actual_wins - expected_wins) / n_matches
```

Negative trajectory = player winning less than Elo expected = "falling"

**Strategy tested:** Bet on the opponent of the Elo pick when:
- Elo pick's trajectory < -20% (falling)
- Opponent odds between 3.0 and 5.0

---

## Initial Results (Contained Error)

Using vig-removed "fair" odds, the strategy appeared promising:

| Period | N | Win Rate | ROI | Years Positive |
|--------|---|----------|-----|----------------|
| 2021 | 79 | 29.1% | +5.2% | — |
| 2022 | 69 | 29.0% | +9.2% | — |
| 2023 | 73 | 34.2% | +24.8% | — |
| 2024 | 51 | 27.5% | +1.0% | — |
| **In-sample** | **272** | **30.1%** | **+10.7%** | **4/4** |
| **2025 OOS** | **99** | **31.3%** | **+21.0%** | — |

This appeared to be the first strategy showing positive ROI both in-sample and out-of-sample.

---

## The Error

The odds used in the initial calculation were **vig-removed "fair" odds**, not actual betting odds:

```r
# What was done (incorrect):
mkt_prob_w <- (1/PSW) / (1/PSW + 1/PSL)  # Removes vig via normalization
elo_opp_odds <- 1 / (1 - mkt_prob_w)      # Derives "fair" odds (~2.5% too high)

# What should have been done:
elo_opp_odds <- PSL  # Use actual betting odds directly
```

**The problem:** By normalizing probabilities to remove the bookmaker's vig, then converting back to odds, the calculation produced "fair" odds approximately 2.5% higher than actual betting odds. This artificially inflated the apparent ROI.

**Why this matters:** The bookmaker's vig is already embedded in PSW/PSL. If Pinnacle offers 3.50 on the underdog, you get paid 3.50 if they win. The vig isn't subtracted after — it's already reflected in that 3.50 being lower than the "true" fair odds.

---

## Corrected Results (Actual Betting Odds)

Using actual Pinnacle odds (PSW/PSL):

| Period | N | Win Rate | Breakeven | ROI |
|--------|---|----------|-----------|-----|
| 2021 | 75 | 26.7% | 26.7% | -3.9% |
| 2022 | 76 | 23.7% | 26.7% | -14.7% |
| 2023 | 101 | 30.7% | 26.7% | +13.0% |
| 2024 | 48 | 27.1% | 26.7% | -2.4% |
| **In-sample** | **300** | **27.3%** | **26.7%** | **-0.7%** |

**95% CI for ROI:** [-19.3%, +17.9%]

---

## Comparison: Error vs Corrected

| Metric | With Error | Corrected |
|--------|------------|-----------|
| Avg odds used | 3.76 (fair) | 3.74 (actual) |
| Win rate | 30.2% | 27.3% |
| **ROI** | **+10.7%** | **-0.7%** |
| Years positive | 4/4 | 1/4 |
| Conclusion | Promising edge | No edge |

The apparent +10.7% ROI was almost entirely attributable to the ~2.5% odds inflation from the calculation error.

---

## Key Takeaways

1. **Always use actual betting odds** (PSW/PSL directly) when calculating ROI, not derived "fair" odds

2. **The vig is already priced in** — Pinnacle's odds of 3.50 means you get paid 3.50, not 3.50 minus some fee

3. **Small calculation errors compound** — A 2.5% odds inflation turned a -0.7% ROI into an apparent +10.7% edge

4. **Trajectory signal does not provide edge** — After correction, the strategy shows essentially zero ROI with high variance

---

## Files Created

| File | Purpose |
|------|---------|
| `r_analysis/analysis/trajectory_analysis.R` | Main trajectory calculation |
| `r_analysis/analysis/trajectory_contrarian.R` | Contrarian strategy deep dive |
| `r_analysis/analysis/trajectory_best_subset.R` | Best subset validation |
| `r_analysis/analysis/trajectory_ci.R` | Confidence interval calculations |

---

## Recommendation

The trajectory-based contrarian strategy does not provide a betting edge. The initial positive results were due to a calculation error that inflated odds by approximately 2.5%.

Future analyses should:
- Use actual betting odds (PSW/PSL) directly
- Avoid normalizing probabilities and then converting back to odds
- Verify that breakeven calculations match what would actually be paid out
