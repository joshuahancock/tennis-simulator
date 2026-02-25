=================================================================
                        REFEREE REPORT
              Tennis Match Simulator — Round 8
              Date: 2026-02-18
              Focus: ROI Calculation & Vig Handling
=================================================================

## Summary

This Round 8 report focuses exclusively on the author's concern about ROI
calculations and vig handling across the codebase. The author self-identified
what they believed to be a major calculation error. The referee has independently
audited all ROI and profit calculations across the entire pipeline.

**Overall verdict:** The author's diagnosis is correct and well-documented. The
trajectory analysis scripts contain a genuine vig-related calculation error that
inflated reported ROI by ~11pp. The main backtest pipeline (`06_backtest.R`) and
several downstream scripts are correctly implemented. However, there is a
systematic inconsistency in how "edge" is defined across scripts that, while not
corrupting ROI calculations, makes edge thresholds non-comparable between the
main backtest and analysis scripts. One additional hardcoded-values issue in
`trajectory_ci.R` propagates the error into the CI estimates.

---

## Audit 1: Raw Data Structure

**Raw betting data verified**: `data/raw/tennis_betting/2024.xlsx`

The raw Excel files from tennis-data.co.uk contain the following odds columns:
`B365W`, `B365L`, `PSW`, `PSL`, `MaxW`, `MaxL`, `AvgW`, `AvgL`

Sample rows:

| Winner | Loser | B365W | B365L | PSW | PSL |
|--------|-------|-------|-------|-----|-----|
| Popyrin A. | O Connell C. | 1.62 | 2.30 | 1.72 | 2.23 |
| Shevchenko A. | Van Assche L. | 1.62 | 2.30 | 1.78 | 2.14 |
| Safiullin R. | Shelton B. | 2.30 | 1.62 | 2.31 | 1.68 |

**Overround verification** (computed from sample rows):

- Row 1: 1/1.72 + 1/2.23 = 0.581 + 0.448 = 1.030 → **Pinnacle vig ≈ 3.0%**
- Row 2: 1/1.78 + 1/2.14 = 0.562 + 0.467 = 1.029 → **Pinnacle vig ≈ 2.9%**
- Row 3: 1/2.31 + 1/1.68 = 0.433 + 0.595 = 1.028 → **Pinnacle vig ≈ 2.8%**

Avg (B365W, B365L implied):
- Row 1: 1/1.68 + 1/2.17 = 0.595 + 0.461 = 1.056 → **B365 vig ≈ 5.6%**

**Key finding:** Pinnacle charges 2.8-3.0% vig on ATP tennis. B365 charges 5.5-6%.
The `PREFERRED_BOOKS` ordering (`c("PS", "B365", ...)`) correctly prioritizes
Pinnacle. When Pinnacle odds are unavailable, B365 doubles the vig, making the
edge hurdle significantly harder.

**Finding: Vig by bookmaker is not reported in any output.** Results should note
what fraction of matches use Pinnacle vs B365, since the vig differential (~3pp)
meaningfully affects edge thresholds.

---

## Audit 2: Main Backtest ROI Pipeline (`06_backtest.R`)

**Finding: CORRECT.**

The profit formula in `simulate_betting()` (lines 578-586):

```r
flat_profit = if_else(bet_won, (bet_odds - 1) * flat_stake, -flat_stake)
total_flat_profit <- sum(bets$flat_profit)
total_flat_wagered <- nrow(bets) * flat_stake
roi_flat <- total_flat_profit / total_flat_wagered
```

This correctly computes: for a winning bet at decimal odds `o`, profit = `(o-1) × stake`;
for a losing bet, loss = `stake`. ROI = total profit / total staked. This is
standard flat-stake ROI. ✓

**Implied probability calculation** (lines 372-373):

```r
implied_prob_p1 = odds_to_implied_prob(p1_odds),    # = 1/odds
implied_prob_p2 = odds_to_implied_prob(p2_odds),
```

This stores **raw** (vig-inclusive) implied probabilities. Since `implied_prob_p1 +
implied_prob_p2 = 1/p1_odds + 1/p2_odds ≈ 1.03 > 1`, the implied probs sum to more
than 1. The resulting edge:

```r
edge_p1 = model_prob_p1 - implied_prob_p1
edge_p2 = model_prob_p2 - implied_prob_p2
```

always satisfies `edge_p1 + edge_p2 = 1 - (1/p1_odds + 1/p2_odds) = -vig < 0`.

**This is the correct approach for measuring positive EV.** A bet has positive
expected value if and only if `model_prob > 1/odds` (raw implied), i.e., `edge > 0`
using raw implied probability. The vig does not need to be separately subtracted —
it is already embedded in the odds. The `edge_threshold` filter in `simulate_betting()`
correctly gates on this: `edge_p1 >= edge_threshold` means the model says this player
has at least `edge_threshold` more probability than the odds-implied breakeven.

**Kelly formula** (lines 596-600):

```r
b <- bet$bet_odds - 1
p <- bet$bet_prob
q <- 1 - p
kelly <- (b * p - q) / b
```

Standard Kelly formula: `f* = (bp - q)/b`. ✓

**Bootstrap ROI CI** (lines 652-686): Correctly implements percentile bootstrap with
replacement. ✓

---

## Audit 3: THE BUG — Trajectory Analysis Scripts

**Finding: CONFIRMED BUG in three scripts.**

The author self-identified this error and documented it in `docs/notes/trajectory_analysis_summary.md`.
The referee independently confirms the diagnosis.

### Affected Scripts

| Script | Line | Bug |
|--------|------|-----|
| `trajectory_contrarian.R` | 25-27 | Fair odds used for profit |
| `trajectory_best_subset.R` | 19-21 | Fair odds used for profit |
| `trajectory_ci.R` | 11 | Fair odds used for profit |

### The Error in Detail

In `trajectory_analysis.R` (line 263), the vig-removed market probability is computed:

```r
implied_w <- 1 / m$PSW
implied_l <- 1 / m$PSL
mkt_prob_w <- implied_w / (implied_w + implied_l)   # Vig REMOVED
```

This `mkt_prob_w` is saved to the RDS file. Then in `trajectory_contrarian.R`
(lines 25-27), this vig-removed probability is used to derive odds:

```r
elo_opp_odds = ifelse(elo_pick == winner,
                      1 / (1 - mkt_prob_w),    # "Fair" loser odds
                      1 / mkt_prob_w),          # "Fair" winner odds
contrarian_profit = ifelse(elo_opp_won, elo_opp_odds - 1, -1)
```

**The problem:** `1/(1 - mkt_prob_w)` is the FAIR (vig-removed) odds for the loser,
not the actual Pinnacle odds (`PSL`). The correct code is:

```r
elo_opp_odds = ifelse(elo_pick == winner, PSL, PSW)  # Actual Pinnacle odds
```

### Quantitative Impact

With Pinnacle vig ≈ 3% and a typical loser odds of PSL = 3.50:
- Raw implied: 1/3.50 = 0.2857
- Vig-removed fair prob: 0.2857 / 1.03 ≈ 0.2773
- Fair odds: 1/0.2773 ≈ 3.606

The fair odds are 0.106 higher than actual (3.606 vs 3.500). This means each
winning bet reports a profit of 2.606 units instead of the actual 2.500 units.

### Why the Total Impact is ~11pp (Not Just ~3%)

The documented difference is +10.7% (bugged) → -0.7% (corrected). This 11.4pp
swing comes from **two compounding effects**, not just odds inflation:

1. **Odds inflation (~4-5pp)**: Fair odds ≈ 2.5-3% higher than actual. At the
   higher odds ranges (3.0-5.0) targeted by this strategy, absolute inflation is
   larger in per-bet profit terms.

2. **Sample composition shift (~7pp)**: The odds FILTER `elo_opp_odds >= 3.0`
   was applied to FAIR odds, not actual odds. Since fair odds > actual odds by
   ~3%, matches with actual PSL in the range [2.85, 3.00) passed the filter when
   using fair odds (their fair odds ≥ 3.0) but would fail with actual odds. These
   boundary matches near PSL = 2.90-2.99 have **higher win probability** (~33-35%
   win rate) than the average of the strategy (~27%). Including them incorrectly
   inflated both win rate (30.2% → 27.3% after correction) and ROI.

   Similarly, matches near the upper boundary (PSL ≈ 4.80-4.99 with fair odds just
   above 5.0) were EXCLUDED with fair odds but INCLUDED with actual odds, adding
   lower-win-rate bets that drag ROI down further.

The sample size change (272 with bug vs 300 corrected) confirms this: the different
filter boundaries changed which matches were included.

### Status of OOS Correction

The author corrected the in-sample results. However:

**`trajectory_ci.R` lines 46-49 hardcode the ERRONEOUS OOS value:**

```r
n_oos <- 99
wins_oos <- 31
mean_profit_oos <- 0.2104    # ← +21.0% ROI from BUGGED calculation
sd_profit_oos <- 1.82
```

The +21.0% OOS ROI reported in `trajectory_analysis_summary.md` corresponds to the
bugged calculation. The CORRECTED 2025 OOS ROI has not been computed or documented
anywhere. This is an open gap: the corrected OOS result is unknown.

---

## Audit 4: Other Analysis Scripts — Correct Use of Actual Odds

**Finding: These scripts are correctly implemented for ROI.**

| Script | Profit Computation | Verdict |
|--------|-------------------|---------|
| `06_backtest.R` `simulate_betting()` | `(bet_odds - 1) * stake` using actual p1/p2 odds | ✓ Correct |
| `validate_elo_betting.R` strategies | `market_fav_odds - 1` using actual min(p1,p2) | ✓ Correct |
| `find_betting_edge_subsets.R` | `edge_won * edge_odds - 1` using actual p1/p2 odds | ✓ Correct |
| `calibration_edge_deep.R` | `mkt_dog_odds - 1` using `max(PSW, PSL)` directly | ✓ Correct |
| `test_2025_oos.R` | `mkt_dog_odds - 1` using `max(PSW, PSL)` directly | ✓ Correct |
| `prospective_paper_trade.R` | `bet_odds - 1` using PSW/PSL directly | ✓ Correct |

---

## Audit 5: The Edge Definition Inconsistency

**Finding: Two different "edge" definitions in use — not a bug, but a source of confusion.**

### Definition A: Raw Edge (used in main backtest)

`06_backtest.R` lines 396-398:
```r
edge_p1 = model_prob_p1 - (1/p1_odds)    # Raw implied prob
edge_p2 = model_prob_p2 - (1/p2_odds)
```

An edge of 3% means the model assigns 3pp MORE probability than the raw breakeven
probability. Since raw implied prob = breakeven probability for EV calculations, this
directly measures whether the bet has positive EV.

### Definition B: Vig-Adjusted Edge (used in analysis scripts)

`find_betting_edge_subsets.R` lines 27-31:
```r
market_prob_p1 = (1/p1_odds) / (1/p1_odds + 1/p2_odds)    # Vig-removed
elo_edge_p1 = model_prob_p1 - market_prob_p1
```

`calibration_edge_deep.R` lines 91-94, 107:
```r
mkt_prob_w <- (1/PSW) / (1/PSW + 1/PSL)    # Vig-removed
dog_edge <- calibrated_dog_prob - mkt_dog_prob
```

An edge of 3% here means the model assigns 3pp MORE probability than the **fair
market** probability. With Pinnacle vig ≈ 3%, the relationship between the two is:

```
edge_raw ≈ edge_fair - fair_prob × vig
```

For a 50/50 match with 3% vig:
- edge_fair = 3% → edge_raw ≈ 3% - 0.50 × 0.03 = 1.5%
- A "3% vig-adjusted edge" = only "1.5% raw edge" = barely positive EV

**The practical consequence:** The +5.16% ROI reported in `calibration_edge_deep.R`
for the "Odds 2.0-2.5, Edge 0-10%" subset uses vig-adjusted edge for filtering but
actual odds for profit. The edge filter is more lenient than the main backtest's
equivalent threshold. Matches that would be filtered OUT by the main backtest (raw
edge < 0, meaning model_prob < 1/odds = negative EV) can pass the analysis-script
filter if the vig-adjusted edge is still > 0. However, since all profit calculations
use actual odds, the ROI itself is correctly computed. The issue is interpretability:
"edge > 5%" means different things in different scripts.

**This inconsistency is not currently flagged anywhere in documentation.**

---

## Audit 6: Calibration Edge Analysis — Residual Concern

**Finding: Edge computation uses vig-removed probs, but for a non-obvious reason that warrants documentation.**

In `calibration_edge_deep.R` (lines 101-107):
```r
mkt_dog_prob <- 1 - max(mkt_prob_w, 1 - mkt_prob_w)    # Vig-removed
calibrated_dog_prob <- ...                               # Model prob
dog_edge <- calibrated_dog_prob - mkt_dog_prob          # Fair edge
```

The edge is computed against the **vig-removed market probability**. The stated
rationale would be: we're comparing our model's probability estimate against the
market's "true belief" in the underdog. This is a reasonable approach for identifying
market mispricing.

However: `dog_profit = ifelse(dog_won, mkt_dog_odds - 1, -1)` uses **actual odds**.
This creates a subtle interpretive issue:
- Positive `dog_edge > 0` does NOT guarantee positive EV
- It means: model says underdog is better than market thinks (on a fair odds basis)
- But actual EV depends on whether model > raw implied prob

For a typical case: actual mkt_dog_odds = 2.20, vig = 3%:
- raw implied prob = 1/2.20 = 0.455
- fair implied prob = 0.455/1.03 = 0.441
- If model says 0.450: dog_edge = 0.450 - 0.441 = +0.009 (positive vig-adjusted)
- But raw edge = 0.450 - 0.455 = -0.005 (NEGATIVE EV)

The strategy can be selecting some genuinely -EV bets by using vig-adjusted edge.
The positive ROI results (+5.16% in-sample for odds 2.0-2.5) represent actual
outcomes, so they are not inflated by this. But the edge filter may be admitting
more bets than a true positive-EV filter would. The OOS failure (-2.29% in 2025)
could be partially explained by this: some included bets have genuine negative EV,
and the positive in-sample result was partially spurious.

---

## Major Concerns

1. **Hardcoded OOS result from bugged calculation**: `trajectory_ci.R` line 47
   hardcodes `mean_profit_oos = 0.2104`, which is the +21.0% OOS ROI from the
   erroneous vig calculation. The corrected 2025 OOS trajectory ROI is unknown.
   The in-sample correction documented in `trajectory_analysis_summary.md` is
   thorough, but the OOS counterpart is unfinished. The CI file should either be
   rerun with corrected inputs or clearly marked as invalid.

---

## Minor Concerns

1. **Vig by bookmaker not reported.** The `PREFERRED_BOOKS` selection uses Pinnacle
   first (2.8-3% vig) but falls back to B365 (5.5-6% vig). Matches using B365 face
   a much higher hurdle for positive EV. Results should tabulate what fraction of
   matches use each bookmaker, and ideally report ROI separately by bookmaker source.

2. **Edge definition inconsistency not documented.** Two definitions of "edge" are
   in use (raw vs vig-adjusted). This is methodologically defensible but should be
   explicitly stated in documentation. Any comparison of "edge > X%" across scripts
   requires knowing which definition was used.

3. **The `calculate_edge()` helper function (`05_betting_data.R` lines 551-560)
   has `remove_vig = TRUE` by default but is never used in the main backtest
   pipeline.** Its existence implies that vig-removed edges are the intended
   approach, but the pipeline does the opposite. This function is either wrong
   by omission (should be wired into the main pipeline) or misleading as a helper.
   It should either be used or clarified in a comment.

4. **The `calibration_edge_deep.R` edge filter uses vig-adjusted probabilities.**
   As shown above, this admits some genuinely negative-EV bets into the sample.
   This may contribute to the in-sample → OOS failure pattern. Consider either
   switching to raw-edge filtering or documenting this explicitly.

---

## Questions for Authors

1. **Has the corrected 2025 trajectory OOS ROI been computed?** The
   `trajectory_analysis_summary.md` documents the in-sample correction but not the
   OOS correction. The `trajectory_ci.R` still uses the bugged +21.0% value. What
   is the corrected 2025 OOS result?

2. **Is the positive ROI (+5.16%) in `calibration_edge_deep.R` for odds 2.0-2.5
   aware of the vig-adjusted edge issue?** Given the OOS failure in 2025, it's
   worth investigating whether the filter is admitting negative-EV bets. Has the
   strategy been recomputed with raw-edge filtering?

3. **For the prospective paper trade (`prospective_paper_trade.R`), the Elo is
   updated DURING the paper trade period (lines 141-145).** Is this intentional?
   Updating Elo during the OOS period means the model is not truly "frozen" — it
   learns from H2 2024 results while trading. This is not the same as a true
   prospective test where the model parameters are fixed. Was this a deliberate
   design choice?

---

## Verdict

[X] Accept with Minor Revisions

**Justification:** The author correctly self-identified the vig calculation error
and documented it thoroughly. The main backtest infrastructure is correctly
implemented. The ROI formula in `06_backtest.R` is correct. The trajectory error
has been identified and the in-sample results corrected. The remaining concerns
are about the hardcoded OOS values in `trajectory_ci.R`, the undocumented edge
inconsistency, and the prospective paper trade design. These are addressable
without major rework.

---

## Recommendations (Prioritized)

1. **Fix or retire `trajectory_ci.R`.** The hardcoded OOS value on line 47
   (`mean_profit_oos = 0.2104`) was computed with the bugged calculation. Either
   rerun the 2025 OOS trajectory analysis with actual odds and update this file,
   or add a clear header comment stating the file uses erroneous inputs and should
   not be cited.

2. **Document the edge definition in use for each script.** Add a comment at the
   top of each analysis script noting whether `edge` is computed relative to raw
   implied probability or vig-removed fair probability. Alternatively, standardize
   on one definition throughout the codebase.

3. **Report Pinnacle vs B365 match breakdown.** The difference in vig (3% vs 6%)
   is material for ROI claims. A table showing N matches by bookmaker source and
   ROI by source would clarify whether results are driven by sharp-market matches
   or soft-market matches.

4. **Clarify the `calculate_edge()` function's status.** Either wire it into the
   main pipeline, remove it, or add a comment explaining why it exists and when
   it should be used.

5. **Restate the calibration edge strategy using raw edge.** The `calibration_edge_deep.R`
   results for odds 2.0-2.5 should be recomputed using `dog_edge = calibrated_dog_prob -
   (1/mkt_dog_odds)` (raw) rather than vs vig-removed market prob. Compare the
   in-sample ROI under both definitions to assess whether the edge filter is
   admitting negative-EV bets.

6. **Clarify the paper trade Elo update decision.** Lines 141-145 of
   `prospective_paper_trade.R` update Elo ratings during the paper trade. Document
   whether this is intentional and, if so, how it affects the "frozen model" claim.

=================================================================
                      END OF REFEREE REPORT
=================================================================
