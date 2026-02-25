=================================================================
                        REFEREE REPORT
              Tennis Match Simulator — Round 5
              Date: 2026-02-09
=================================================================

## Summary

This Round 5 report is a focused deep-dive on three areas requested by the author: (1) validation of the Elo approach, (2) edge analysis methodology, and (3) data leakage. A critical data leakage bug has been discovered that likely invalidates all reported backtest accuracy figures. The ATP match data uses `tourney_date` (tournament start date) as its date field, while the betting data uses actual match dates. This mismatch causes later-round tournament results to leak into Elo ratings when predicting earlier rounds. The existing leakage validation in `validate_elo_betting.R` does not catch this because it checks `tourney_date` against `tourney_date` — a tautological test.

**Overall Assessment:** The data leakage is a critical methodological flaw. The reported 68.6% Elo accuracy and the +9.9pp advantage over MC cannot be trusted until this is fixed and results are re-run.

---

## CRITICAL FINDING: Data Leakage via `tourney_date` Mismatch

### The Problem

Two data sources use different date semantics:

| Source | Date Column | Semantics | Example (Brisbane 2024) |
|--------|-------------|-----------|------------------------|
| ATP match data (Sackmann) | `tourney_date` | Tournament START date | All 31 matches → `2024-01-01` |
| Betting data (tennis-data.co.uk) | `Date` | Actual match date | R1: Dec 31/Jan 1, QF: Jan 3, F: Jan 4 |

The ATP data is parsed at `02_player_stats.R:68`:
```r
match_date = ymd(tourney_date)  # Tournament start date, NOT actual match date
```

The betting data is parsed at `05_betting_data.R:316`:
```r
match_date = as_date(match_date)  # Actual match date from tennis-data.co.uk
```

### The Leakage Mechanism

In `06_backtest.R:279-296`, the rolling Elo calculation uses:

```r
cutoff_date <- match_date  # From BETTING data (actual match date, e.g., Jan 3 for QF)
prior_matches <- historical_matches %>%
  filter(match_date < cutoff_date)  # ATP match_date = tourney_date (Jan 1 for ALL matches)
```

When predicting a quarterfinal on January 3:
- `cutoff_date = 2024-01-03` (from betting data)
- ATP filter: `tourney_date (2024-01-01) < 2024-01-03` → **TRUE for ALL tournament matches**
- Result: The **semifinal (Jan 3)** and **final (Jan 4)** results are included in the Elo training data

The Elo model literally knows who won the final before predicting the quarterfinal.

### Empirical Verification

Examined the raw data files:

- **ATP data** (`data/raw/tennis_atp/atp_matches_2024.csv`): Brisbane 2024 (tourney_id `2024-0339`) — all 31 matches share `tourney_date = 20240101`, including R1 through Final.
- **Betting data** (`data/raw/tennis_betting/2024.xlsx`): Brisbane matches have distinct dates from December 31 through January 7.

### Why the Existing Validation Didn't Catch This

The leakage check in `validate_elo_betting.R:46-62` is **tautological**:

```r
# This filters ATP data (where match_date = tourney_date)
prior_matches <- historical_matches %>% filter(match_date < test_date)

# This checks the Elo history (which inherits match_date = tourney_date from input)
in_history <- elo_before$history %>%
  filter(match_date >= test_date) %>%
  nrow()
```

The check verifies that no tournament STARTING on or after the test date is in the Elo history. It does NOT verify that no matches PLAYED on or after the test date are in the history. The test passes trivially because it's comparing tournament dates to tournament dates.

**A correct test would be:** For a specific match on a specific actual date, verify that no match from the same tournament's later rounds is in the Elo training set. This requires joining ATP matches with betting data to get actual match dates.

### Impact Severity

**CRITICAL.** This affects every prediction in the backtest:

| Tournament Type | Draw Size | Matches Affected | Max Date Gap |
|----------------|-----------|-------------------|-------------|
| Grand Slam | 128 | ~127 matches | 14 days |
| Masters 1000 | 56-96 | ~55-95 matches | 7-9 days |
| ATP 500 | 32 | ~31 matches | 6 days |
| ATP 250 | 32 | ~31 matches | 6 days |

For a typical Grand Slam, approximately 75% of matches (R1+R2) would have severe leakage, with later rounds' results inflating or deflating the predicted players' Elo ratings.

**Why this disproportionately inflates Elo accuracy:**

1. Players who go deep in tournaments get MORE Elo points from those later matches
2. These inflated ratings are used to predict their earlier matches
3. Since these players DID win their earlier matches (to reach later rounds), the model's predictions are spuriously accurate
4. This creates a systematic positive correlation between prediction and outcome

**Why the MC model is less affected:**

The MC model also uses the same `prior_matches` filter for building `stats_db`. However, serve/return statistics are aggregated over many years (2015+). Adding a few extra matches from a tournament barely changes the overall averages. For Elo, by contrast, each match directly changes ratings with K=32, and the effect is cumulative.

**Conservative estimate of accuracy inflation:** If ~65% of matches have meaningful leakage, and the leakage inflates win probability estimates by 2-3% for the eventual winner, this could add 15-25 spuriously correct predictions out of 1,142, inflating accuracy by 1.3-2.2 percentage points. The actual inflation may be higher because the Elo model's responsiveness (K=32) amplifies the effect.

---

## Audit 1: Code Audit

### Findings

1. **CRITICAL: `tourney_date` used as `match_date` in ATP data (02_player_stats.R:68)**
   See detailed analysis above. This is the root cause of the data leakage.

2. **MAJOR: Leakage validation is tautological (validate_elo_betting.R:46-62)**
   The data leakage check compares `tourney_date` to `tourney_date`, which always passes. It does not compare against actual match dates. This gave false confidence that no leakage existed.

3. **MINOR: `compare_models.R` reports no statistical significance test**
   The +9.9pp accuracy difference (68.6% vs 58.7% on n=1,142) is reported without a confidence interval or McNemar test. While likely significant at this sample size, the claim should be formally tested — especially since the difference may be partially attributable to leakage.

4. **INFO: Rolling Elo rebuild is O(D × M) per prediction day**
   Each new match date triggers a full Elo recalculation from scratch. For H1 2024 (~180 unique dates, ~25,000 historical matches), this is computationally expensive. An incremental approach would improve performance without affecting results. Not a correctness issue.

5. **INFO: Bootstrap ROI CI is deterministic within a run**
   The bootstrap at `06_backtest.R:649` relies on the main `set.seed()` at line 197. Within a single backtest run, the CI is reproducible. Standalone calls to `bootstrap_roi_ci()` would not be reproducible.

### Missing Value Handling Assessment

Missing values in ATP match data are handled by filtering `w_svpt > 0` (line 79 of `02_player_stats.R`), which removes matches without serve statistics. This is appropriate. The `na.rm = TRUE` in aggregation functions (lines 213-226) handles any remaining NAs in individual stat columns. No concerns here.

---

## Audit 2: Cross-Language Replication

No changes from Round 4. Python replication covers MC engine only. No Elo replication exists.

Given the critical leakage finding, cross-language replication is secondary. The priority is fixing the date mismatch, not replicating results that are based on leaked data.

---

## Audit 3: Replication Readiness

### Replication Readiness Score: 7/10 (decreased from 8/10)

**Decrease rationale:** The discovery that the backtest's date handling produces systematically biased results means the reported results are not currently replicable in a meaningful sense — running the same code would produce the same (biased) numbers, but those numbers don't measure what they claim to measure.

### Updated Deficiencies

1. (**NEW**) Date alignment between ATP and betting data is broken — backtest results are unreliable
2. Master script (`code/run_analysis.R`) does not include `compare_models.R` or `validate_elo_betting.R`
3. In-text statistics in CLAUDE.md remain manually entered

---

## Audit 4: Output Automation

No changes from Round 4. Minor issues remain (mixed automation, manual in-text statistics). These are eclipsed by the leakage finding.

---

## Audit 5: Econometrics / Model Validation

### Elo Model Validation Assessment

**What is sound:**

1. **Formula implementation**: The standard Elo formula `E = 1 / (1 + 10^((Rb - Ra) / 400))` is correctly implemented. Per-player K-factors are correctly applied after the Round 3 fix.

2. **Surface blending logic**: The linear interpolation `weight = min(1, surface_matches / MIN_SURFACE_MATCHES_FOR_ELO)` is a reasonable approach for combining surface-specific and overall Elo. Unit tests verify blending behavior at 0%, 50%, and 100% weight.

3. **Alphabetical player ordering**: The backtest correctly uses alphabetical ordering (`06_backtest.R:73-77`) to avoid the calibration bias where predictions are always for the winner. This was a previous fix that remains correct.

4. **Unit test coverage**: 14 tests cover core formula, update mechanics (including asymmetric K-factors), and integration scenarios. Coverage is adequate for the Elo module in isolation.

**What is problematic:**

1. **CRITICAL: All accuracy/Brier/log-loss metrics are compromised by the tourney_date leakage.** The reported 68.6% accuracy may be artificially inflated. The +9.9pp gap over MC may be partially or wholly explained by differential leakage impact (Elo is more sensitive to leaked matches than MC because of per-match rating updates).

2. **No calibration analysis for Elo model reported.** The backtest framework computes calibration bins (`06_backtest.R:469-496`), but no Elo-specific calibration has been published. Calibration is critical for the edge analysis — if the Elo model is directionally correct but poorly calibrated, the edge calculations are meaningless.

3. **Elo scale factor (400) not validated for tennis.** The 400 divisor was designed for chess. Tennis has substantially higher match variance (service breaks, best-of-3 vs best-of-5). Some tennis Elo implementations use different scaling. If the scale is wrong, predicted probabilities are poorly calibrated even if rankings are correct.

4. **K=32 sensitivity analysis still absent.** Flagged in Rounds 3 and 4. K=32 is high for tennis — FIDE uses K=10-40 for chess, and tennis has more variance. The choice remains unjustified.

### Edge Analysis Assessment

**What is methodologically correct:**

1. **Edge calculation**: `edge = model_prob - implied_prob` where `implied_prob = 1/odds` is correct for evaluating betting value. The vig is included in the implied probability, which is appropriate — a bettor must overcome the vig to profit.

2. **Kelly criterion implementation**: The fractional Kelly (`06_backtest.R:578-584`) correctly computes `f = (bp - q) / b` with a 0.25 fraction and 5% max bet cap. This is standard.

3. **Bootstrap CI for ROI**: Percentile bootstrap with 1,000 resamples is appropriate for non-normal returns distributions.

4. **Baseline comparisons** (`validate_elo_betting.R`): The four strategies (market favorite, Elo favorite, Elo with 5% edge, Elo contrarian) provide useful benchmarks.

**What is problematic:**

1. **Edge analysis inherits the leakage bias.** Since model probabilities are inflated/deflated by leaked future data, edge calculations are unreliable. An artificially high win probability for the actual winner translates to a larger spurious edge when the winner is an underdog.

2. **No out-of-sample evidence.** The `validate_elo_betting.R` script checks for H2 2024 holdout data (`lines 96-122`) but notes `"The betting data may only go through mid-2024."` Without out-of-sample results, there is no evidence the model generalizes beyond the development period.

3. **Closing vs. opening odds ambiguity.** The script notes at line 71: `"Odds type: CLOSING ODDS (recorded at match start)"`. This is stated as fact without verification from the data source. Tennis-data.co.uk documentation should be cited. If these are actually opening odds, the edge is harder to capture in practice.

4. **The edge validation script has not been run.** The script saves results to `data/processed/elo_betting_validation.rds`, but there is no evidence the results were run or analyzed. The code exists but the outputs are not part of the correspondence record.

---

## Major Concerns

1. **CRITICAL — Data leakage via `tourney_date` / actual match date mismatch**: The ATP match data uses tournament start dates (`tourney_date`) as `match_date`. The betting data uses actual match dates. When the backtest filters historical matches using the actual match date as cutoff, it includes ALL matches from tournaments that started before the cutoff — including matches from later rounds that haven't been played yet. This systematically inflates Elo accuracy because players who advance deep in tournaments get rating boosts from those future matches, and those boosts are used to predict their earlier matches (which they did in fact win). The existing validation check (`validate_elo_betting.R:46-62`) is tautological and does not detect this issue.

2. **MAJOR — Leakage validation provides false assurance**: The `validate_elo_betting.R` data leakage check compares `tourney_date` to `tourney_date`, verifying only that the filter on tournament start dates works correctly. It does not test whether matches played after the cutoff date are excluded. This passed and was reported as "PASSED: No future data in Elo calculation" (line 58), providing false confidence that the backtest was clean.

3. **MAJOR — All reported metrics are unreliable**: The 68.6% Elo accuracy, 0.2029 Brier score, +9.9pp advantage over MC, and all ROI/edge figures from `compare_models.R` and `validate_elo_betting.R` are computed on leaked data. These numbers cannot be stated as findings until the date alignment is fixed and the backtest is re-run.

## Minor Concerns

1. **No statistical significance test for model comparison**: The +9.9pp accuracy difference is reported without a confidence interval or formal test (e.g., McNemar's test). This should be added once clean results are available.

2. **Elo calibration not reported**: No calibration analysis has been published for the Elo model. Calibration is a prerequisite for meaningful edge analysis.

3. **K=32 and scale factor 400 not validated for tennis**: Both parameters are chess conventions adopted without justification or sensitivity analysis. These are inherited from FIDE and may not be appropriate for tennis's higher match variance.

4. **Out-of-sample test not completed**: H2 2024 holdout was planned but appears blocked by data availability. No out-of-sample results exist.

5. **Edge validation results not documented**: `validate_elo_betting.R` exists as a script but its outputs have not been reported in any correspondence round. The code may or may not have been run.

## Questions for Authors

1. **Date alignment fix**: The most direct fix is to use the `match_num` column from the Sackmann data (which provides within-tournament ordering by round) combined with the tournament's `tourney_date` to infer approximate actual match dates. Alternatively, the betting data's actual dates can be joined back to ATP match records by player names and tournament. Which approach does the author prefer?

2. **Impact quantification**: Before fixing, can the author quantify the leakage impact by running the Elo backtest with a CONSERVATIVE cutoff — e.g., `match_date < (cutoff_date - days(14))` — to ensure no same-tournament leakage? The accuracy drop from this conservative approach would bound the leakage inflation.

3. **Has `validate_elo_betting.R` been run?** If so, what were the ROI results? If not, why was the script created but not executed?

---

## Verdict

[X] Major Revisions

**Justification:** The `tourney_date` data leakage is a critical methodological flaw that invalidates all reported backtest results. The Elo model's 68.6% accuracy, its +9.9pp advantage over MC, and all edge/ROI analysis are computed on data where the model has access to future match outcomes from the same tournament. The existing leakage validation provides false assurance by testing the wrong thing. This must be fixed and all results re-run before any performance claims can be made.

This is not a code quality issue — the Elo implementation itself is correct. The bug is in how historical match dates are defined, creating a systematic information advantage that the model exploits unknowingly. Once fixed, the Elo model may well outperform MC, but the magnitude of the advantage is currently unknown.

---

## Recommendations

Priority order:

1. **Fix the date alignment (CRITICAL)**: Replace `tourney_date` with actual match dates in the ATP data pipeline. Options:
   - **Preferred**: Join ATP matches with betting data on player names + tournament to inherit actual dates
   - **Alternative**: Use the `round` column from ATP data to infer approximate dates (R1 = tourney_date, R2 = tourney_date + 1, etc.)
   - **Stopgap**: Use a conservative buffer (e.g., `cutoff_date - days(14)`) to ensure no same-tournament leakage, at the cost of excluding some legitimate prior data

2. **Fix the leakage validation (CRITICAL)**: Replace the tautological check with a test that verifies no match from the same tournament's later rounds appears in the Elo training set. This requires actual match dates.

3. **Re-run all backtests with corrected dates**: Once dates are fixed, regenerate accuracy, Brier, log loss, ROI, and edge figures. Update CLAUDE.md with corrected results.

4. **Quantify leakage impact**: Compare accuracy before and after the fix to understand how much the leakage inflated results.

5. **Report Elo calibration**: Once clean results exist, publish a calibration table (predicted vs. actual win rates by probability bin).

6. **Add McNemar test for model comparison**: Formally test whether the Elo-MC accuracy difference is statistically significant.

7. **K-factor sensitivity**: Test K=16, 20, 24, 32, 40 on clean data.

=================================================================
                      END OF REFEREE REPORT
=================================================================
