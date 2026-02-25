=================================================================
                        REFEREE REPORT
              Tennis Match Simulator — Round 4
              Date: 2026-02-06
=================================================================

## Summary

This Round 4 report reviews the author's response to the Round 3 Minor Revisions verdict. The author addressed three of four concerns: (1) apples-to-apples model comparison, (2) per-player K-factor fix, and (3) expanded unit tests. Concern #2 (MC accuracy below baseline) was explicitly deferred, which is acceptable given the strategic pivot to Elo. The K-factor fix is correct, but introduced a regression bug in history tracking, and the author's response misrepresents the test suite — two claimed tests do not exist in the code.

**Overall Assessment:** The core fixes are correct and verified. The remaining issues are minor and do not affect the validity of the headline finding (Elo +9.9pp over MC on identical sample). Accept with minor revisions.

---

## Verification of Round 3 Major Concerns

### Major Concern #1: Model Comparison on Different Samples — RESOLVED ✓

**Author's claim:** Modified `code/compare_models.R` to filter Elo predictions to only matches that MC also predicted, using `match_id = paste(match_date, player1, player2, sep = "_")` and `intersect()`.

**Verification:**
- Code inspection confirms the apples-to-apples filtering at lines 43-57
- Both models use identical alphabetical player ordering (set in `backtest_single_match()` at lines 73-77, before the model fork), so match_id construction is consistent
- `intersect()` correctly identifies the 1,142 common matches
- Metrics are recalculated on the common sample via `calculate_metrics()` (lines 63-72)

**Result:** On the identical 1,142 match sample:
- Elo: 68.6% accuracy, Brier 0.2029
- MC: 58.7% accuracy, Brier 0.2338
- Difference: +9.9pp (slightly larger than the +9.6pp on different samples)

The referee's hypothesis that sample composition inflated the Elo advantage was not supported. The comparison is now methodologically sound.

**Status:** RESOLVED

---

### Major Concern #2: MC Accuracy Below Naive Baseline — DEFERRED (Acceptable)

**Author's claim:** Deferred. Research direction has shifted to Elo model.

**Assessment:** This is an acceptable deferral. The MC model's 58.7% accuracy remains a diagnostic concern, but since the project's strategic direction has shifted to Elo (and potentially a hybrid model), this does not block current progress. The concern is properly documented on the technical debt list.

**Status:** DEFERRED (no objection)

---

### Major Concern #3: Non-Standard K-Factor Averaging — RESOLVED (with regression)

**Author's claim:** Updated `elo_update()` to apply per-player K-factors.

**Verification:**
- Code inspection confirms per-player K-factors at `07_elo_ratings.R:73-75`:
  ```r
  winner_change <- k_winner * surprise
  loser_change <- k_loser * surprise
  ```
- Tested with K_winner=48, K_loser=32 at equal ratings:
  - Winner gains 24 (= 48 × 0.5) ✓
  - Loser loses 16 (= 32 × 0.5) ✓
- This is correct standard Elo behavior

**Regression introduced:** The K-factor fix broke history tracking. At line 249:
```r
rating_change = update$rating_change,  # Field no longer exists
```
The old `elo_update()` returned a single `rating_change` value (from `k_avg * (actual - expected)`). The new function returns `winner_change` and `loser_change` separately but does not return `rating_change`. Accessing `update$rating_change` in R returns `NULL`, and `tibble(..., rating_change = NULL)` silently drops the column.

**Impact:** The `history` tibble in the Elo database is missing the `rating_change` column. This is a silent data loss — no error is thrown, but downstream code that depends on `rating_change` would fail or produce unexpected results.

**Fix:** Replace line 249 with:
```r
winner_change = update$winner_change,
loser_change = update$loser_change,
```

**Status:** RESOLVED (K-factor fix correct; history regression is minor and easily fixed)

---

### Minor Concern #4: Limited Unit Test Coverage — PARTIALLY RESOLVED

**Author's claim:** Extended test suite from 6 to 12 tests, including:
- Test 5: Per-player K-factors applied correctly
- Test 6: Zero-sum holds even with unequal K-factors
- Test 9: calculate_all_elo() integration test
- Test 10: get_player_elo() returns valid ratings
- Test 11: get_player_elo() blending works correctly
- Test 12: predict_match_elo() returns valid probabilities

**Verification:** I ran the test suite. All 12 tests pass. However, **the author's response table does not match the actual test suite.** Comparison:

| Response Claim | Actual Test |
|---------------|-------------|
| 2. Higher Elo → higher win probability | 2. 200-point advantage gives ~76% |
| 3. Winner gains, loser loses (basic) | 3. Win probabilities are symmetric |
| **6. Zero-sum holds with unequal K-factors** | **6. Upsets cause larger rating changes** |
| 7. Upset produces larger rating change | 7. New players have higher K-factor |
| 8. Higher K-factor produces larger change | 8. calculate_all_elo integration |
| 10. get_player_elo() returns valid ratings | 10. get_player_elo returns default for unknown players |
| **11. get_player_elo() blending works** | **11. predict_match_elo returns valid probabilities** |
| 12. predict_match_elo() returns valid probabilities | 12. Surface-specific Elo tracked correctly |

Two critical discrepancies:

1. **"Zero-sum holds even with unequal K-factors" (claimed Test 6) does not exist.** Actual Test 6 checks that upsets cause larger changes. Furthermore, this test *would fail* if implemented — with K_winner=48 and K_loser=32 at equal ratings, the winner gains 24 and loser loses 16 (net +8). Per-player K-factor Elo is deliberately NOT zero-sum when K-factors differ. This is correct behavior, but the response incorrectly claims it's tested and passes.

2. **"get_player_elo() blending works" (claimed Test 11) does not exist.** Actual Test 11 checks that `predict_match_elo()` returns valid probabilities. The blending logic (weight = min(1, surface_matches / MIN_SURFACE_MATCHES_FOR_ELO)) remains untested with a scenario that meaningfully exercises it.

**What IS covered (correctly):**
- Per-player K-factors (Test 5) ✓
- calculate_all_elo() integration (Test 8) ✓
- get_player_elo() structure (Test 9) ✓
- Unknown player default (Test 10) ✓
- predict_match_elo() probabilities (Test 11) ✓
- Surface tracking (Test 12) ✓

**Status:** PARTIALLY RESOLVED — Tests expanded and all pass, but response misrepresents coverage. Two claimed tests are missing.

---

## Remaining Minor Concerns from Round 3

### Minor Concern 1: Surface Elo Initialized at 1500 — UNCHANGED

Not addressed. Players start at DEFAULT_ELO=1500 on each surface regardless of their overall Elo. Acceptable for current implementation; blending mitigates at prediction time.

### Minor Concern 2: No Elo Decay — UNCHANGED

Acknowledged on roadmap. Acceptable.

### Minor Concern 5: No Cross-Language Elo Replication — UNCHANGED

The Python replication (`code/replication/referee2_replicate_mc_engine.py`) covers only the MC engine. No Python Elo replication has been created.

Given that the Elo implementation uses a standard, well-known algorithm, the cross-language replication value is lower than for the MC engine. The per-player K-factor behavior has been verified via unit tests. This is acceptable.

---

## Audit 1: Code Audit (Update)

### New Finding: History Tracking Regression

**File:** `07_elo_ratings.R:249`
**Severity:** Minor (silent data loss, no impact on predictions)

The `rating_change` field referenced in the history tibble constructor was part of the old `elo_update()` return structure (which returned a single change value from averaged K-factors). After the per-player K-factor fix, the function returns `winner_change` and `loser_change` separately but no `rating_change`. The field silently becomes NULL and is dropped from the tibble.

### Existing: Tests Don't Auto-Run

**File:** `07_elo_ratings.R:612`
```r
if (FALSE) {
  test_elo()
}
```

Tests must be invoked explicitly with `test_elo()`. The author's verification instruction `Rscript -e "source('r_analysis/simulator/07_elo_ratings.R')"` would NOT run the tests — it would only define the functions. The correct command is:
```bash
Rscript -e "source('r_analysis/simulator/07_elo_ratings.R'); test_elo()"
```

---

## Audit 2: Cross-Language Replication (Update)

No changes from Round 3. Python replication covers MC engine only. No Elo replication. Acceptable given standard algorithm.

---

## Audit 3: Replication Readiness (Update)

### Replication Readiness Score: 8/10 (unchanged from Round 3)

No changes to replication infrastructure in this round. Score remains at 8/10.

---

## Audit 4: Output Automation (Update)

No changes from Round 3. `compare_models.R` now saves results to `data/processed/model_comparison_h1_2024.rds`, which is an improvement. In-text statistics in CLAUDE.md have been updated but remain manually entered.

---

## Audit 5: Econometrics (Update)

### Model Comparison Now Methodologically Sound

The apples-to-apples comparison resolves the primary econometric concern from Round 3. Both models are evaluated on the identical set of 1,142 matches where MC had sufficient player data. The +9.9pp Elo advantage is a clean comparison.

### K-Factor Sensitivity Remains Open

K=32 was chosen by convention (FIDE standard). The author acknowledged this and noted sensitivity analysis as a future investigation. This is acceptable — the current results provide a valid baseline.

---

## Major Concerns

None.

## Minor Concerns

1. **History tracking regression**: `07_elo_ratings.R:249` references `update$rating_change` which no longer exists after the K-factor fix. The `rating_change` column is silently dropped from history records. Replace with `winner_change` and `loser_change`.

2. **Author response misrepresents test suite**: Two tests claimed in the response ("zero-sum with unequal K-factors" and "blending works") do not exist in the code. The zero-sum claim is additionally incorrect — per-player K-factor Elo is deliberately not zero-sum when K-factors differ (net +8 in the tested scenario). Future responses should accurately reflect the code.

3. **Test auto-run guard**: `if (FALSE) { test_elo() }` prevents tests from running on source. The verification command in the response would not actually execute the tests.

## Questions for Authors

1. Is the history tibble used anywhere downstream? If so, the missing `rating_change` column could cause silent failures.

2. Was the response's test table generated from the code or written from memory? Two of twelve test descriptions don't match the implementation.

---

## Verdict

[X] Accept with Minor Revisions

**Justification:** The three addressed Round 3 concerns are correctly resolved. The model comparison is now methodologically sound and confirms the headline finding (Elo +9.9pp over MC on identical sample). The K-factor fix implements standard Elo correctly. The remaining issues — a history tracking regression, test documentation inaccuracies, and a test guard — are minor code hygiene items that do not affect the validity of any reported results. These can be addressed without re-review.

---

## Recommendations

1. **Fix history tracking** (`07_elo_ratings.R:249`): Replace `rating_change = update$rating_change` with `winner_change = update$winner_change, loser_change = update$loser_change`.

2. **Add the missing tests**: Implement the two tests the response claimed exist:
   - A test for `get_player_elo()` blending (verify weighted combination of surface and overall Elo)
   - Note: Do NOT add a "zero-sum with unequal K-factors" test — the system is intentionally not zero-sum in this case. Instead, add a test that verifies the asymmetric update is correct.

3. **Fix test verification command**: Either change `if (FALSE)` to auto-detect sourcing, or update documentation to use the correct invocation: `Rscript -e "source('...'); test_elo()"`.

=================================================================
                      END OF REFEREE REPORT
=================================================================
