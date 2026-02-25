=================================================================
                     AUTHOR RESPONSE
           Tennis Match Simulator — Round 4
           Date: 2026-02-06
=================================================================

## Summary of Changes

This response addresses the three minor concerns raised in the Round 4 report. All issues have been resolved.

| Concern | Status |
|---------|--------|
| #1: History tracking regression | **RESOLVED** |
| #2: Test documentation mismatch | **RESOLVED** |
| #3: Test auto-run guard | **RESOLVED** |

---

## Minor Concern #1: History Tracking Regression — RESOLVED

### Issue

At `07_elo_ratings.R:247`, the code referenced `update$rating_change` which no longer exists after the K-factor fix. The field was silently dropped from the history tibble.

### Fix

Replaced the single `rating_change` field with the two new fields returned by `elo_update()`:

```r
# OLD (line 247)
rating_change = update$rating_change,

# NEW (lines 247-248)
winner_change = update$winner_change,
loser_change = update$loser_change,
```

### Verification

Added Test 10 to explicitly verify history tracking:

```r
# Test 10: History tracking includes winner/loser changes
stopifnot("winner_change" %in% names(elo_db$history))
stopifnot("loser_change" %in% names(elo_db$history))
stopifnot(all(elo_db$history$winner_change > 0))
stopifnot(all(elo_db$history$loser_change > 0))
```

---

## Minor Concern #2: Test Documentation Mismatch — RESOLVED

### Issue

The Round 3 response claimed two tests that did not exist:
1. "Zero-sum holds even with unequal K-factors" — incorrect; per-player Elo is deliberately NOT zero-sum when K-factors differ
2. "get_player_elo() blending works" — did not exist in the code

### Fix

Rewrote and expanded the test suite from 12 to 14 tests with accurate descriptions:

**Test 6 (new):** Explicitly verifies that asymmetric K-factors produce the correct NON-zero-sum result. This documents the intentional behavior:

```r
# Test 6: Asymmetric K-factors produce correct non-zero-sum result
# This is CORRECT behavior: with different K-factors, the system is NOT zero-sum
# Net change = winner_change - loser_change = 24 - 16 = +8 (rating inflation)
# This allows provisional players to converge faster
net_change <- update_unequal$winner_change - update_unequal$loser_change
stopifnot(abs(net_change - 8) < 0.001)  # Expected: 24 - 16 = 8
cat("  Test 6 PASSED: Asymmetric K-factors produce correct non-zero-sum (+8)\n")
```

**Test 12 (rewritten):** Properly tests blending with both full-weight and partial-weight scenarios:

```r
# Test 12: get_player_elo blending works correctly
# Full weight case: 15 surface matches >= MIN_SURFACE_MATCHES_FOR_ELO (10)
blender_info <- get_player_elo("Blender", "Hard", blend_db)
stopifnot(blender_info$weight == 1)
stopifnot(blender_info$source == "surface")

# Partial weight case: 5 surface matches = 50% blend
partial_info <- get_player_elo("Partial", "Clay", partial_db)
stopifnot(partial_info$weight == 0.5)  # 5 / 10 = 0.5
stopifnot(partial_info$source == "blended")
expected_blend <- 0.5 * partial_info$surface_elo + 0.5 * partial_info$overall_elo
stopifnot(abs(partial_info$elo - expected_blend) < 0.001)
```

### Complete Test Suite (14 tests)

| # | Category | Description |
|---|----------|-------------|
| 1 | Core Formula | Equal ratings give 50% win probability |
| 2 | Core Formula | 200-point advantage gives ~76% win probability |
| 3 | Core Formula | Win probabilities are symmetric |
| 4 | Elo Update | Zero-sum with equal K-factors |
| 5 | Elo Update | Per-player K-factors applied correctly (48 vs 32) |
| 6 | Elo Update | **Asymmetric K-factors produce correct non-zero-sum (+8)** |
| 7 | Elo Update | Upsets cause larger rating changes |
| 8 | Elo Update | New players have higher K-factor (48 vs 32) |
| 9 | Integration | calculate_all_elo produces correct rankings |
| 10 | Integration | **History tracks winner_change and loser_change** |
| 11 | Integration | get_player_elo returns default for unknown players |
| 12 | Integration | **get_player_elo blending works correctly** |
| 13 | Integration | predict_match_elo returns valid probabilities |
| 14 | Integration | Surface-specific Elo tracked correctly |

---

## Minor Concern #3: Test Auto-Run Guard — RESOLVED

### Issue

The `if (FALSE) { test_elo() }` guard prevented tests from running when the file was sourced. The verification command in the Round 3 response would not actually execute the tests.

### Fix

Replaced with idiomatic R pattern that auto-runs tests when the script is executed directly (not sourced):

```r
# OLD
if (FALSE) {
  test_elo()
}

# NEW
if (sys.nframe() == 0) {
  test_elo()
}
```

Updated documentation comment:

```r
# ============================================================================
# UNIT TESTS
# Run with: Rscript -e "source('r_analysis/simulator/07_elo_ratings.R'); test_elo()"
# ============================================================================
```

---

## Responses to Referee Questions

### Q1: Is the history tibble used anywhere downstream?

The history tibble is currently used only for debugging and inspection (e.g., `print_elo_summary()`). It is not used in predictions or backtesting. The silent column drop would not have affected any reported results, but the fix ensures the data structure is complete for future use.

### Q2: Was the response's test table generated from the code or written from memory?

Written from memory, which was the source of the error. This response's test table was generated directly from the code output to ensure accuracy.

---

## Verification

All 14 tests pass:

```bash
$ Rscript -e "source('r_analysis/simulator/07_elo_ratings.R'); test_elo()"

=== Running Elo Unit Tests ===

--- Core Elo Formula Tests (1-3) ---
  Test 1 PASSED: Equal ratings give 50% win probability
  Test 2 PASSED: 200-point advantage gives ~76% win probability
  Test 3 PASSED: Win probabilities are symmetric

--- Elo Update Tests (4-8) ---
  Test 4 PASSED: Zero-sum with equal K-factors
  Test 5 PASSED: Per-player K-factors applied correctly (48 vs 32)
  Test 6 PASSED: Asymmetric K-factors produce correct non-zero-sum (+8)
  Test 7 PASSED: Upsets cause larger rating changes
  Test 8 PASSED: New players have higher K-factor (48 vs 32)

--- Integration Tests (9-14) ---
  Test 9 PASSED: calculate_all_elo produces correct rankings
  Test 10 PASSED: History tracks winner_change and loser_change
  Test 11 PASSED: get_player_elo returns default for unknown players
  Test 12 PASSED: get_player_elo blending works correctly
  Test 13 PASSED: predict_match_elo returns valid probabilities
  Test 14 PASSED: Surface-specific Elo tracked correctly

=== All 14 tests passed ===
```

---

## Files Modified

| File | Change |
|------|--------|
| `r_analysis/simulator/07_elo_ratings.R` | Fixed history tracking (lines 247-248); expanded tests from 12 to 14; fixed auto-run guard |

=================================================================
                    END OF AUTHOR RESPONSE
=================================================================
