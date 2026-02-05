=================================================================
                        REFEREE REPORT
              Tennis Match Simulator — Round 2
              Date: 2026-02-04
=================================================================

## Summary

This Round 2 report reviews the author's response to the Round 1 Major Revisions verdict. The author addressed all four major concerns: (1) reproducibility via random seeds, (2) dynamic tour averages replacing hardcoded values, (3) master script and documentation, and (4) bootstrap confidence intervals for ROI. I verified each fix through code inspection and execution. The work now meets the standard for acceptance with minor revisions.

**Overall Assessment:** The author has substantively addressed all major concerns. The remaining issues are minor and do not affect the validity of the core results.

---

## Verification of Round 1 Major Concerns

### Major Concern 1: No random seeds — RESOLVED ✓

**Author's claim:** Added `set.seed()` with documented seed (20260204) in `06_backtest.R`.

**Verification:**
- Confirmed `RANDOM_SEED <- 20260204` defined at line 24
- Confirmed `set.seed(seed)` called in `backtest_period()` at line 171
- Confirmed seed passed through to `compare_models_backtest()` at line 678

**Reproducibility test:**
```r
# Two runs with seed 42 produce identical results
set.seed(42)
wins1 <- replicate(10000, simulate_match(...)$winner)
p1_prob_run1 <- mean(wins1 == 1)  # 0.5683

set.seed(42)
wins2 <- replicate(10000, simulate_match(...)$winner)
p1_prob_run2 <- mean(wins2 == 1)  # 0.5683

identical(wins1, wins2)  # TRUE
```

**Status:** RESOLVED

---

### Major Concern 2: Hardcoded tour averages — RESOLVED ✓

**Author's claim:** Replaced hardcoded `0.35` and `0.50` with dynamically calculated values from `stats_db`.

**Verification:**
- `simulate_match_probability()` now extracts tour averages from `stats_db$tour_avg_surface` (surface-specific) or `stats_db$tour_avg_overall` (fallback) at lines 55-81
- Tour averages passed through entire call chain to `simulate_point()`
- `DEFAULT_TOUR_AVG_*` constants remain as fallback only when stats_db unavailable

**Execution test:**
```r
result <- simulate_match_probability("Novak Djokovic", "Carlos Alcaraz",
                                      surface = "Hard", stats_db = stats_db)
# Tour averages: return vs 1st=27.5%, return vs 2nd=49.3%
# (Calculated from actual match data, not hardcoded)
```

**Status:** RESOLVED

---

### Major Concern 3: No master script or replication instructions — RESOLVED ✓

**Author's claim:** Created `code/run_analysis.R`, `code/README.md`, and `code/setup_renv.R`.

**Verification:**
- `code/run_analysis.R`: 148-line master script with clear configuration section, proper seed handling, and summary output
- `code/README.md`: 149-line documentation covering prerequisites, installation, execution, troubleshooting
- `code/setup_renv.R`: 48-line script for dependency management setup

**Status:** RESOLVED

---

### Major Concern 4: ROI estimates lack uncertainty quantification — RESOLVED ✓

**Author's claim:** Added `bootstrap_roi_ci()` function with 95% confidence intervals.

**Verification:**
- `bootstrap_roi_ci()` function at lines 599-633 implements percentile bootstrap with 1000 resamples
- Returns lower/upper CI bounds and standard error
- Called from `simulate_betting()` at line 574
- Output includes ROI with CI: `ROI: +5.2% (95% CI: -2.1% to +12.3%)`

**Reproducibility test:**
```r
set.seed(123)
ci1 <- bootstrap_roi_ci(mock_bets)  # [-0.0868, 0.3714], SE=0.1135

set.seed(123)
ci2 <- bootstrap_roi_ci(mock_bets)  # [-0.0868, 0.3714], SE=0.1135

identical(ci1$lower, ci2$lower)  # TRUE
```

**Status:** RESOLVED

---

## Audit 2: Cross-Language Replication (Update)

### Comparison Results

With seeds now implemented, I can verify that R produces reproducible results. Exact R-Python comparison remains impossible due to different RNG algorithms, but Monte Carlo estimates converge:

| Test Case | R (seed=42) | Python (seed=42) | Difference |
|-----------|-------------|------------------|------------|
| Typical ATP matchup (P1 win) | 0.5683 | 0.5815 | 0.0132 |
| Expected MC error (n=10000) | - | - | ~0.010 |

The 1.3pp difference is within expected Monte Carlo sampling error (2σ ≈ 0.02 for n=10,000). The implementations are statistically equivalent.

### Python Replication Updated

The Python replication script (`code/replication/referee2_replicate_mc_engine.py`) has been updated to accept tour averages as parameters, matching the R implementation:

```python
def estimate_win_probability(
    ...,
    tour_avg_return_vs_first: Optional[float] = None,
    tour_avg_return_vs_second: Optional[float] = None
) -> Dict:
```

Test Case 4 now demonstrates the difference between default and actual ATP averages:
- Default averages (35%/50%): P1 win prob = 0.5815
- Actual ATP Hard (27.5%/49.3%): P1 win prob = 0.5861
- Difference: 0.46pp

---

## Audit 3: Replication Readiness (Update)

### Replication Readiness Score: 7/10 (improved from 4/10)

| Criterion | Round 1 | Round 2 | Notes |
|-----------|---------|---------|-------|
| Folder structure | ✓ | ✓ | No change |
| Relative paths | ✓ | ✓ | No change |
| Variable naming | ✓ | ✓ | No change |
| Dataset naming | ✓ | ✓ | No change |
| Script naming | ✓ | ✓ | No change |
| Master script | ✗ | ✓ | **Fixed**: `code/run_analysis.R` |
| README in /code | ✗ | ✓ | **Fixed**: `code/README.md` |
| Dependencies documented | ✗ | Partial | `setup_renv.R` exists but `renv.lock` not yet generated |
| Random seeds | ✗ | ✓ | **Fixed** |

### Remaining Deficiency

- **renv.lock not yet created**: The setup script exists but hasn't been run. Package versions remain undocumented. Run `source("code/setup_renv.R")` to complete.

---

## Audit 4: Output Automation (Update)

No changes from Round 1. Minor issues remain:

- Tables: Mixed (results saved to RDS, but no publication-ready table generation)
- Figures: Not automated (plot functions exist but not called in pipeline)
- In-text statistics: Manual (CLAUDE.md values not pulled from saved results)

These are low priority given the core reproducibility fixes.

---

## Audit 5: Econometrics (Update)

No changes to the core methodology. Previous minor concerns remain but do not affect validity:

- Additive adjustment formula: Author justified as design choice (acceptable)
- No out-of-sample holdout: Rolling stats provide some protection against leakage

---

## Minor Concerns (Remaining)

1. **renv.lock not generated**: Run `source("code/setup_renv.R")` to complete dependency documentation.

2. **Name matching at ~90%**: Acknowledged by author. Selection bias risk is documented.

3. **In-text statistics in CLAUDE.md**: Update with values from saved results for consistency.

---

## Questions for Authors

None. All Round 1 questions were adequately addressed.

---

## Verdict

[X] Accept with Minor Revisions

**Justification:** All four major concerns from Round 1 have been substantively addressed and verified. The code now produces reproducible results, uses data-driven tour averages, includes proper documentation, and quantifies uncertainty in ROI estimates. The remaining issues (renv.lock generation, Python script update) are minor and can be addressed without re-review.

---

## Recommendations for Final Acceptance

1. **Run `source("code/setup_renv.R")`** to generate `renv.lock` and complete dependency documentation.

2. **Optional**: Update CLAUDE.md statistics from saved backtest results for consistency.

=================================================================
                      END OF REFEREE REPORT
=================================================================
