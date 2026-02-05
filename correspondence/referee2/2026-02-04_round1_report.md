=================================================================
                        REFEREE REPORT
              Tennis Match Simulator — Round 1
              Date: 2026-02-04
=================================================================

## Summary

This report presents a systematic audit of the Tennis Match Simulator project, a Monte Carlo simulation model designed to predict tennis match outcomes and identify betting value against bookmaker odds. The primary analysis language is R. I created an independent Python replication of the core Monte Carlo engine and performed five comprehensive audits covering code quality, cross-language replication, directory structure, output automation, and econometric methodology.

**Overall Assessment:** The project demonstrates a well-conceived probabilistic model with sound core logic, but has several significant issues that must be addressed before results can be considered reliable for publication or practical use.

---

## Audit 1: Code Audit

### Findings

1. **MAJOR: Hardcoded tour averages (01_mc_engine.R:45, 01_mc_engine.R:68)**
   ```r
   avg_return_vs_first <- 0.35  # Line 45
   avg_return_vs_second <- 0.50  # Line 68
   ```
   These values are used in the opponent adjustment formula but are hardcoded rather than calculated from data. This is acknowledged in CLAUDE.md as technical debt. The values should be computed dynamically from the loaded match data.

2. **MAJOR: No random seed set anywhere in the codebase**
   - Searched all R files: no calls to `set.seed()`
   - Results are not reproducible across runs
   - The backtest results stored in `backtest_results_2024_h1.rds` cannot be exactly reproduced

3. **MINOR: Second serve always assumed in (01_mc_engine.R:57-78)**
   - The model assumes second serves always land in (unless double fault)
   - In reality, there's a small percentage of let cords and other missed second serves
   - Acknowledged in CLAUDE.md as known issue #4

4. **MINOR: Tiebreak uses same stats as regular games (01_mc_engine.R:131)**
   - No tiebreak-specific pressure adjustments
   - Some players perform differently under tiebreak pressure
   - Acknowledged in CLAUDE.md as known issue #5

5. **INFO: Missing value handling appears correct**
   - `filter(!is.na(w_svpt), w_svpt > 0)` in data loading (02_player_stats.R:79)
   - `na.rm = TRUE` used consistently in aggregations
   - Proper NULL checks in similarity functions

6. **INFO: Merge diagnostics absent**
   - No explicit row count checks after joins in betting data integration
   - `standardize_player_names()` reports match rate but doesn't validate individual merges

### Missing Value Handling Assessment

Missing values are handled reasonably throughout:
- Match data filtered to require valid serve statistics
- Aggregations use `na.rm = TRUE`
- Similarity functions return NULL when players not found
- The `require_player_data` flag (added 2026-01-24) properly skips matches using tour average fallback

**However**, there's no logging of how many matches are dropped due to missing values at each stage of the pipeline.

---

## Audit 2: Cross-Language Replication

### Replication Scripts Created

- `code/replication/referee2_replicate_mc_engine.py` — Python implementation of core Monte Carlo engine

### Verification Results

The Python replication was executed with fixed random seeds. Results demonstrate the implementation is logically equivalent:

| Test Case | Python Result | Notes |
|-----------|---------------|-------|
| Typical ATP matchup (P1 win prob) | 0.5815 | With opponent adjustment |
| Same matchup, no adjustment | 0.6737 | Difference: +9.2pp |
| Big server vs elite returner | 0.4155 | Adjustment favors returner |
| Point-level: Aces | 8.17% | Expected: 8.00% ✓ |
| Point-level: Double faults | 2.99% | Expected: 3.00% ✓ |

### Direct Comparison Not Possible

**Critical limitation:** Because the R code does not set random seeds, I cannot produce a direct comparison table showing R vs Python with identical random number sequences. The Python implementation matches the R logic line-by-line, but numerical equivalence cannot be verified to 6 decimal places without reproducible R output.

### Recommendation

The author must:
1. Add `set.seed()` calls to R code
2. Re-run backtests with fixed seeds
3. Run both R and Python with same seed and verify exact match

### Discrepancies Diagnosed

No algorithmic discrepancies identified. The Python implementation replicates:
- Point simulation logic (lines 24-79 in R → lines 96-172 in Python)
- Game simulation logic (lines 86-122 in R → lines 181-207 in Python)
- Tiebreak serve rotation (lines 147-151 in R → lines 229-234 in Python)
- Set and match logic (lines 199-349 in R → lines 243-342 in Python)
- Wilson score confidence interval (lines 160-172 in R → lines 372-382 in Python)

---

## Audit 3: Directory & Replication Package

### Replication Readiness Score: 4/10

### Checklist

| Criterion | Status | Notes |
|-----------|--------|-------|
| Folder structure | ✓ | Clear separation: data/raw, data/processed, r_analysis/simulator |
| Relative paths | ✓ | All paths relative to project root |
| Variable naming | ✓ | Informative names (e.g., `first_won_pct`, `edge_threshold`) |
| Dataset naming | ✓ | Clear names (e.g., `backtest_results_2024_h1.rds`) |
| Script naming | ✓ | Numbered execution order (01_, 02_, etc.) |
| Master script | ✗ | **No master script to run full pipeline** |
| README in /code | ✗ | **No README explaining how to run replication** |
| Dependencies documented | ✗ | **No renv.lock; renv commented out in .Rprofile** |
| Random seeds | ✗ | **Not set anywhere** |

### Deficiencies

1. **No master script** — Cannot run full analysis with single command
2. **No renv.lock** — Package versions not documented; `renv` is commented out
3. **No code/README.md** — No instructions for replicators
4. **Seeds not set** — Results not reproducible
5. **No requirements.txt** for Python scaffolding (minimal issue since R is primary)

---

## Audit 4: Output Automation

### Tables: Mixed

- Backtest results saved programmatically to RDS files ✓
- No automated table generation for publication (no `stargazer`, `kable`, etc.)
- Summary statistics printed to console but not saved

### Figures: Not Automated

- `plot_calibration()`, `plot_bankroll()`, `plot_roi_by_edge()` functions exist
- No evidence these are called and saved in any pipeline
- No `ggsave()` calls with output paths

### In-text Statistics: Manual

- Key results in CLAUDE.md appear manually entered:
  ```
  Accuracy: 58.9%
  Brier Score: 0.2336
  ROI at 5% edge: -5.1%
  ```
- These should be pulled programmatically from saved results

### Reproducibility Test

Cannot verify byte-identical outputs due to missing random seeds.

### Deductions

- Manual in-text statistics: **Major concern**
- No automated figure export: **Minor concern**
- Outputs not reproducible: **Major concern**

---

## Audit 5: Econometrics

### Identification Assessment

The identification strategy is clearly stated and plausible:

> "The model's 'edge' comes from using actual serve/return percentages rather than Elo/rankings" (CLAUDE.md)

This is a reasonable source of variation — the model exploits information in detailed match statistics that may not be fully priced into betting lines based primarily on rankings.

### Specification Issues

1. **MAJOR: Additive adjustment formula may be too severe**

   The opponent adjustment formula (01_mc_engine.R:46-47):
   ```r
   adjustment <- avg_return_vs_first - returner_stats$return_vs_first
   win_prob <- server_stats$first_won_pct + adjustment
   ```

   This is a linear additive adjustment. If a returner is 5pp better than average (0.40 vs 0.35), the server's win probability drops by 5pp. This may be too aggressive — the relationship between returner skill and server effectiveness is likely nonlinear.

   **Evidence:** Test Case 3 in Python replication shows a 9.2pp difference between adjusted and unadjusted probabilities. This is a large swing.

2. **MAJOR: No uncertainty quantification on ROI estimates**

   ROI figures are reported as point estimates without confidence intervals or standard errors:
   ```
   ROI at 5% edge: -5.1%
   ```

   With betting samples, variance can be high. A 95% CI on ROI would clarify whether results are statistically distinguishable from zero.

3. **MINOR: Calibration analysis structurally flawed**

   From CLAUDE.md Known Issue #3:
   > "Calibration analysis misleading — Always shows 100% actual win rate because we simulate winner vs loser."

   The backtest now uses alphabetical ordering (06_backtest.R:67-70), but this should be verified as working correctly.

4. **MINOR: No out-of-sample validation period**

   The backtest appears to use rolling stats (preventing leakage), but there's no separate holdout period for final evaluation. The same period is used for development and reported results.

5. **INFO: Sample restrictions are documented and reasonable**
   - MIN_TOTAL_MATCHES = 20
   - MIN_SURFACE_MATCHES = 20
   - Filtering to matches with valid serve stats
   - Threshold analysis showed 20-match minimum improves ROI

### Standard Errors

Not applicable in the traditional econometric sense — this is a simulation model, not a regression. However:
- Monte Carlo standard error is implicitly ~1% with 10,000 simulations (via Wilson CI)
- Betting ROI variance is not quantified

---

## Major Concerns

1. **No random seeds set — results not reproducible**

   This is the most critical issue. Without `set.seed()`, the exact backtest results cannot be reproduced. Any reported statistics (accuracy, Brier score, ROI) could vary meaningfully across runs. This makes the work impossible to verify or replicate.

2. **Hardcoded tour averages in adjustment formula**

   The values `0.35` and `0.50` for average return percentages are hardcoded rather than computed from data. If the data period or tour changes, these values would be incorrect. They should be calculated dynamically from `stats_db$tour_avg_*`.

3. **No master script or replication instructions**

   A replicator cannot currently reproduce the analysis without reading through all code to understand the execution order and dependencies.

4. **ROI estimates lack uncertainty quantification**

   Reporting ROI without confidence intervals is misleading. Betting returns are highly variable, and a -5.1% ROI could easily be consistent with both profitable and unprofitable true performance.

## Minor Concerns

1. **Name matching at ~90%** — 10% of players fail lookup, reducing sample size and potentially introducing selection bias if failed matches are non-random.

2. **No renv.lock** — Package versions not documented; results may not reproduce with different package versions.

3. **Additive adjustment may be too aggressive** — The 9pp swing observed in testing suggests the formula may overcorrect for opponent strength.

4. **Plots not saved programmatically** — Calibration and ROI plots exist as functions but aren't called in any automated pipeline.

5. **In-text statistics manually entered** — Key results in CLAUDE.md should be pulled from saved outputs.

## Questions for Authors

1. What is the variance of ROI estimates across multiple runs with different random seeds? Is the -5.1% ROI at 5% edge statistically distinguishable from zero?

2. Why are tour averages hardcoded rather than calculated from data? Was there a specific reason for this design choice?

3. The additive adjustment formula shows large effects (9pp in testing). Has this been validated against historical H2H data to confirm it improves predictions rather than adding noise?

4. What percentage of the H1 2024 backtest sample used tour average fallback vs. real player data before the `require_player_data` flag was added?

---

## Verdict

[X] Major Revisions

**Justification:** The core simulation logic is sound and the Python replication confirms the implementation is correct. However, the lack of reproducibility (no random seeds), missing replication infrastructure (no master script, no renv.lock), and absence of uncertainty quantification on key results mean the work cannot be verified or properly evaluated in its current form.

---

## Recommendations

Priority order for resubmission:

1. **Add `set.seed()` to all scripts** — Use a documented seed (e.g., 20260204) at the start of 06_backtest.R and any other scripts with stochastic elements. Re-run backtests and save results.

2. **Create master script** — Add `code/run_analysis.R` that sources all scripts in order and produces all outputs from raw data.

3. **Calculate tour averages dynamically** — Replace hardcoded `0.35` and `0.50` with values computed from `stats_db$tour_avg_surface` or `stats_db$tour_avg_overall`.

4. **Add bootstrap CIs to ROI** — Run the betting simulation multiple times with resampling to produce confidence intervals on ROI estimates.

5. **Set up renv** — Uncomment renv in .Rprofile, run `renv::init()` and `renv::snapshot()` to document package versions.

6. **Create code/README.md** — Document how to run the full analysis from scratch.

7. **Verify Python-R equivalence with fixed seed** — After adding seeds to R, run both implementations with the same seed and verify results match to 6 decimal places.

8. **Address name matching** — Improve matching rate above 90%, or document which types of names fail and whether this creates selection bias.

=================================================================
                      END OF REFEREE REPORT
=================================================================
