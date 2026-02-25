=================================================================
                        REFEREE REPORT
              Tennis Match Simulator — Round 3
              Date: 2026-02-05
=================================================================

## Summary

This Round 3 report reviews the newly introduced Elo rating system (`07_elo_ratings.R`), its integration into the backtesting framework (`06_backtest.R`), and the model comparison script (`code/compare_models.R`) that produced the headline finding: surface-specific Elo outperforms Monte Carlo by 9.6 percentage points in accuracy (68.2% vs 58.7%). The Elo implementation is clean and largely correct, but the model comparison has a methodological flaw that likely inflates the reported accuracy gap, and the Elo update function uses a non-standard K-factor averaging approach.

**Overall Assessment:** The Elo model is a sound addition. However, the comparison to the MC model is not apples-to-apples, and the MC model's accuracy (58.7%) is below the naive baseline, suggesting the opponent adjustment is actively harming predictions. Both issues must be addressed before the headline finding can be stated with confidence.

---

## Verification of Round 2 Minor Concerns

### Minor Concern 1: renv.lock not generated — RESOLVED ✓

**Verification:** `renv.lock` is now present in the project root. Confirmed via `renv::init()` and full dependency lockfile (commit `2d037c7`).

**Status:** RESOLVED

---

### Minor Concern 2: Name matching at ~90% — UNCHANGED

No changes. Acknowledged by author as a known limitation.

**Status:** UNCHANGED (acceptable)

---

### Minor Concern 3: In-text statistics in CLAUDE.md — PARTIALLY RESOLVED

CLAUDE.md has been updated with model comparison results. However, values still appear manually entered rather than pulled from saved results programmatically.

**Status:** PARTIALLY RESOLVED

---

## Audit 1: Code Audit

### Findings

1. **MAJOR: K-factor averaging is non-standard (07_elo_ratings.R:73)**

   ```r
   k_avg <- (k_winner + k_loser) / 2
   change <- k_avg * (actual - expected)
   ```

   Standard Elo implementations use each player's own K-factor independently:
   - Winner: `elo_winner + k_winner * (1 - expected)`
   - Loser: `elo_loser - k_loser * (1 - expected)`

   By averaging K-factors, two problems arise:

   a) **Provisional players converge too slowly.** When a provisional player (K=48) faces an established player (K=32), both use K=40. The provisional player's learning rate is muted by 17% (40 vs 48).

   b) **Zero-sum property breaks when K-factors differ.** The unit test at line 520 passes because equal ratings produce equal K-factors. But with K_winner=48 and K_loser=32 (expected=0.5), both gain/lose 20 points (K_avg=40). Under standard Elo, the winner would gain 24 and the loser would lose 16 — still zero-sum, but with appropriate per-player volatility.

2. **MINOR: Surface Elo initialized at DEFAULT_ELO, not overall Elo (07_elo_ratings.R:206-210)**

   ```r
   if (is.null(surface_elo[[surface]][[winner]])) {
     surface_elo[[surface]][[winner]] <- DEFAULT_ELO
   ```

   A player with overall Elo of 1800 who plays their first clay match starts at 1500 on clay. The blending in `get_player_elo()` (line 382-385) mitigates this at prediction time, but the surface Elo history itself has an artificially depressed starting point that requires extra matches to converge.

3. **MINOR: No Elo decay / recency weighting**

   Players who haven't competed recently retain their Elo indefinitely. Already acknowledged on the CLAUDE.md roadmap.

4. **INFO: Unit tests present but limited (07_elo_ratings.R:500-538)**

   Six tests cover basic Elo properties (symmetry, zero-sum, upset magnitude, K-factor variation). Missing coverage:
   - `calculate_all_elo()` — no integration test
   - `get_player_elo()` — blending logic untested
   - `predict_match_elo()` — surface-specific prediction untested
   - Zero-sum test only uses equal ratings, masking the K-factor averaging bug

5. **INFO: Elo integration in backtest is clean (06_backtest.R:105-127)**

   The Elo path creates a result structure compatible with MC output. The `source` field correctly maps Elo source labels ("surface", "blended", "overall", "default") rather than MC source labels. Since `require_player_data` is not set for Elo runs, the Elo model always produces a prediction.

6. **INFO: Rolling Elo rebuild is correct but expensive (06_backtest.R:294-296)**

   For each new match date, the entire Elo history is recomputed from scratch. This is O(D * M) where D is unique dates and M is total historical matches. Correct but slow. An incremental approach would improve performance without affecting results.

---

## Audit 2: Cross-Language Replication (Update)

No changes from Round 2. The Python replication (`code/replication/referee2_replicate_mc_engine.py`) covers the MC engine only. No cross-language replication of the Elo model has been created.

**Recommendation:** A Python Elo replication would be straightforward (standard algorithm) and would verify the K-factor behavior documented in Audit 1, Finding 1.

---

## Audit 3: Replication Readiness (Update)

### Replication Readiness Score: 8/10 (improved from 7/10)

| Criterion | Round 2 | Round 3 | Notes |
|-----------|---------|---------|-------|
| Folder structure | ✓ | ✓ | No change |
| Relative paths | ✓ | ✓ | No change |
| Variable naming | ✓ | ✓ | No change |
| Dataset naming | ✓ | ✓ | No change |
| Script naming | ✓ | ✓ | No change |
| Master script | ✓ | ✓ | No change |
| README in /code | ✓ | ✓ | No change |
| Dependencies documented | Partial | ✓ | **Fixed**: `renv.lock` now generated |
| Random seeds | ✓ | ✓ | No change |

### Remaining Deficiency

- **Model comparison script not integrated into master pipeline**: `code/compare_models.R` exists as a standalone script but is not called from `code/run_analysis.R`.

---

## Audit 4: Output Automation (Update)

No changes from Round 2. Minor issues remain:

- Tables: Mixed (results saved to RDS, but no publication-ready table generation)
- Figures: Not automated (plot functions exist but not called in pipeline)
- In-text statistics: Manual (CLAUDE.md values not pulled from saved results)

These are low priority given the core methodology questions.

---

## Audit 5: Econometrics

### Identification Assessment

The Elo model's prediction source is well-understood: historical win/loss records estimate relative player strength, with surface-specific adjustments via blended ratings. This is a standard, well-validated approach in sports prediction literature. The identification is clean — Elo ratings are a sufficient statistic for win probability under the model's assumptions.

### Specification Issues

1. **MAJOR: Model comparison on different samples (code/compare_models.R:11-30)**

   ```r
   # Elo model — no require_player_data flag
   results_elo <- backtest_period(
     ..., model = "elo", ...
   )

   # MC model — require_player_data = TRUE
   results_mc <- backtest_period(
     ..., model = "base", require_player_data = TRUE, ...
   )
   ```

   The Elo model runs on **all** matches with valid betting odds. The MC model runs only on matches where **both** players have >= 20 matches of real serve/return data. From the Round 1 author response, approximately 20% of matches (298/1,499) used tour average fallback.

   The accuracy/Brier comparisons (68.2% vs 58.7%) are therefore confounded by sample composition. The Elo model is evaluated on a larger, more representative sample; the MC model is evaluated on a smaller, filtered subset.

2. **MAJOR: MC model accuracy (58.7%) is below the naive baseline**

   A "pick the betting favorite" baseline on ATP data typically achieves 65-67% accuracy. The MC model at 58.7% is substantially below this, suggesting the opponent adjustment formula (`01_mc_engine.R:62-63`) is actively harming predictions rather than improving them.

   This was flagged in the Round 1 report as "Minor Concern 3: Additive adjustment may be too aggressive." The 58.7% accuracy figure elevates this to a major concern. Running `use_adjustment = FALSE` would isolate whether the adjustment formula is the source of underperformance.

3. **MINOR: K-factor of 32 is on the high side for tennis**

   K=32 is standard for chess (FIDE uses 10-40 depending on rating), but tennis has higher match variance than chess. Some tennis Elo implementations use K=20-24 for established players. The choice of K=32 should be justified or explored via sensitivity analysis.

4. **MINOR: No home/away or travel adjustment in Elo**

   Elo treats all matches on a surface as equivalent regardless of tournament location, altitude, or fatigue. This is a common omission and acceptable for a first implementation.

---

## Major Concerns

1. **Model comparison on different samples**: The headline finding (Elo +9.6pp over MC) is produced by evaluating the models on different match sets. The Elo model sees all matches; the MC model sees only matches with sufficient player data. Both models must be evaluated on the identical set of matches before any accuracy difference can be attributed to model quality rather than sample composition.

2. **MC accuracy below naive baseline**: The 58.7% MC accuracy is below what a "pick the favorite" strategy achieves (~65-67%). This suggests the opponent adjustment formula is introducing systematic prediction errors. The adjustment was flagged in Round 1 as potentially too aggressive (9pp swing in testing), and the backtest results now confirm this concern empirically.

3. **Non-standard K-factor averaging**: The `elo_update()` function averages K-factors instead of applying each player's K-factor independently. This slows convergence for provisional players and breaks the zero-sum property when K-factors differ.

## Minor Concerns

1. **Surface Elo initialized at 1500**: Should be initialized from the player's overall Elo at the time of first surface match.

2. **No Elo decay**: Already acknowledged on roadmap.

3. **Limited unit test coverage**: Integration tests for `calculate_all_elo()`, `get_player_elo()`, and `predict_match_elo()` are missing. The zero-sum test should be extended to unequal K-factors.

4. **K=32 not justified**: Should be explored via sensitivity analysis or justified against tennis-specific literature.

5. **No cross-language Elo replication**: The Python replication covers only the MC engine.

## Questions for Authors

1. What is the MC model accuracy with `use_adjustment = FALSE`? If it's closer to 65%, the opponent adjustment formula is the primary source of underperformance, not the point-by-point simulation approach.

2. What is the Elo model accuracy when restricted to the same match sample as the MC model (i.e., only matches where both players have >= 20 matches of real data)? This is the true apples-to-apples comparison.

3. Was K=32 chosen by convention, or was there a sensitivity analysis? What happens at K=20 and K=24?

4. Has the hybrid model (Elo for skill estimation, MC for score distribution) been explored? Elo provides well-calibrated win probabilities, but the MC model's value-add is score-level predictions that Elo cannot produce.

---

## Verdict

[X] Minor Revisions

**Justification:** The Elo implementation is fundamentally sound and well-structured. However, the model comparison — which is the basis for the project's current strategic direction — has a methodological flaw (different sample composition) that must be corrected before the +9.6pp finding can be stated with confidence. The K-factor averaging issue is a correctness bug that should be fixed but is unlikely to materially change the headline findings. The MC accuracy question (below naive baseline) is an important diagnostic that should inform whether the MC model has a fixable problem or a fundamental limitation.

---

## Recommendations

Priority order:

1. **Fix the model comparison**: Run both models on the identical match set. Report accuracy, Brier score, and log loss on the common sample.

2. **Diagnose MC underperformance**: Run `backtest_period(..., model = "base", use_adjustment = FALSE, ...)` to isolate the effect of the opponent adjustment formula.

3. **Fix K-factor averaging**: Update `elo_update()` to use per-player K-factors.

4. **Extend unit tests**: Add a zero-sum test with unequal K-factors, and integration tests for the full Elo pipeline.

5. **Optional — K-factor sensitivity**: Test K=20, 24, 32, 40 and report accuracy/Brier at each.

6. **Optional — Surface Elo initialization**: Initialize from overall Elo instead of DEFAULT_ELO.

=================================================================
                      END OF REFEREE REPORT
=================================================================
