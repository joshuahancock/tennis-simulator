# Tennis Simulator Session Notes

Working notes, findings, and analysis from development sessions.

---

## 2026-01-23 - Understanding the Similarity Integration

### Codebase Overview

The simulator consists of 6 main R scripts:

1. **01_mc_engine.R** - Point-by-point simulation
   - `simulate_point()`: Core probability calculation
   - Uses hardcoded tour averages (0.35, 0.50) for opponent adjustment

2. **02_player_stats.R** - Player statistics loader
   - `get_player_stats()`: Falls back to tour average when insufficient data
   - Prints warning: "Using tour average for [player] (insufficient data)"
   - Thresholds: MIN_SURFACE_MATCHES=20, MIN_TOTAL_MATCHES=20 (updated from 10)

3. **03_match_probability.R** - Monte Carlo probability estimation

4. **04_similarity_adjustment.R** - Similarity-based adjustments (partially implemented)
   - `get_expected_return_stats()`: Calculates return stats from similar players
   - `find_similar_to_player()`: Finds similar players using cosine similarity
   - Style classification and historical matchup weighting

5. **05_betting_data.R** - Betting odds integration

6. **06_backtest.R** - Backtesting framework

### The Problem We're Solving

**Current behavior:**
When a player has insufficient match data (< 10 total or < 20 on surface):
- `get_player_stats()` returns tour averages
- `simulate_point()` uses hardcoded 0.35/0.50 for opponent adjustment

This means for lesser-known players, we're using generic averages that don't reflect their playing style.

**Proposed solution:**
When falling back from player-specific stats, instead of using generic tour averages:
1. Find players similar to the one we're looking up (using charting features)
2. Calculate weighted average stats from those similar players
3. Use those stats as a more informed baseline

### Key Code Locations

Tour average fallback in `02_player_stats.R` lines 383-405:
```r
if (nrow(player_overall) == 0 || player_overall$matches[1] < min_total_matches) {
  cat(sprintf("  Warning: Using tour average for %s (insufficient data)\n", player_name))
  # Returns tour_avg_surface or tour_avg_overall
}
```

Hardcoded averages in `01_mc_engine.R` lines 45 and 68:
```r
avg_return_vs_first <- 0.35  # Tour average return % vs first serve
avg_return_vs_second <- 0.50  # Tour average return % vs second serve
```

### Questions to Consider

1. **Threshold selection**: How many similar players? (currently TOP_N_SIMILAR=20)
2. **Similarity threshold**: Minimum similarity score? (currently 0.7)
3. **Weighting method**: Simple average vs similarity-weighted average?
4. **Fallback chain**: What if no similar players found? Still use tour avg?
5. **Performance**: Pre-compute for backtest efficiency?

### Backtest Results Summary (H1 2024)

| Metric | With Adjustment | Without Adjustment |
|--------|-----------------|-------------------|
| Accuracy | 58.3% | 56.3% |
| Brier Score | 0.2362 | 0.2507 |
| Log Loss | 0.6645 | 0.6977 |

ROI at 10% edge: -15.5% (with) vs -10.6% (without)

Key insight: The adjustment helps calibration but hurts ROI at high confidence levels.

### Player Stats Threshold Logic (Clarified)

The `get_player_stats()` function uses a **cascading fallback**, not "AND":

```
Step 1: Does player have >= 10 total matches?
   │
   ├─ NO  → Use TOUR AVERAGE (prints warning)
   │        Returns source = "tour_average"
   │
   └─ YES → Step 2: Does player have >= 20 matches on this surface?
               │
               ├─ YES → Use SURFACE-SPECIFIC stats
               │        Returns source = "surface_specific"
               │
               └─ NO  → Use OVERALL stats (all surfaces combined)
                        Returns source = "overall"
```

Example: Player with 50 hard court matches and 8 grass matches, asking for grass stats:
- Pass 10-match threshold (58 total) ✓
- Fail 20-grass threshold ✗
- Result: Use their OVERALL stats (from all 58 matches), not tour average

The "tour average" fallback only triggers for truly unknown players (< 10 total matches).

### Concerns About the Adjustment Formula

Current formula in `simulate_point()`:
```r
avg_return_vs_first <- 0.35  # Hardcoded baseline
adjustment <- avg_return_vs_first - returner_stats$return_vs_first
win_prob <- server_stats$first_won_pct + adjustment
```

**Issues identified:**

1. **Too severe?** If returner is 5% better than average, server loses a full 5 percentage points. But the point still has to play out - being a good returner means getting the ball back, not automatically winning.

2. **No interaction effect**: The formula treats a +5% returner the same whether facing an 80% big server or 65% weak server. Intuitively, elite returners should matter more against weak servers.

3. **Additive vs multiplicative**: Tennis outcomes are probably more like skill ratios than skill differences. A Bradley-Terry style model might be more principled:
   ```r
   P(server wins) = server_skill / (server_skill + returner_skill)
   ```

**Decision**: Focus on similarity fallback for low-data players first. Revisit adjustment formula later - it's a bigger change with more risk.

### Scope for Current Implementation (COMPLETED)

**Completed**: Replace tour average fallback with similarity-based stats when player has < 20 matches

**Out of scope (for now)**:
- Changing the hardcoded 0.35/0.50 baseline in adjustment formula
- Reworking the adjustment formula to be multiplicative

### Design Decisions for Similarity Implementation

| Question | Decision |
|----------|----------|
| How many similar players? | Top 10 |
| Weighting method | Similarity-weighted average |
| Fallback if no similar players? | Hardcoded tour averages |

**Implementation flow:**
1. Player has < 10 matches in ATP data
2. Try to find them in charting feature database
3. If found, find top 10 similar players (using `find_similar_to_player`)
4. Look up those players' stats in stats_db
5. Calculate similarity-weighted average of their stats
6. If not found in feature_db OR no similar players have stats → fall back to tour average

**Changes needed:**
- Modify `get_player_stats()` in `02_player_stats.R` to accept optional `feature_db` parameter
- Add similarity lookup logic before tour average fallback
- Return with `source = "similarity_weighted"` when using similar players

### Backtest Results with Similarity (H1 2024)

**Overall results:**
- Accuracy: 58.2%, Brier: 0.2362, Log Loss: 0.6651
- Similarity used in only 41 of ~3,000 player lookups (1.4%)
- Limited impact due to small overlap between charting data (303 players) and low-data ATP players

**Filtered to real data only (no tour average):**

| Metric | All Matches | Real Data Only | Tour Avg Matches |
|--------|-------------|----------------|------------------|
| Count | 1,499 | 1,201 (80%) | 298 (20%) |
| Accuracy | 58.2% | 58.9% | 55.4% |
| Brier | 0.2362 | 0.2336 | 0.2467 (near random) |

| Edge | All Matches | Real Data Only |
|------|-------------|----------------|
| 1% | -8.8% | -4.5% |
| 3% | -9.8% | -5.1% |
| 5% | -10.7% | -5.1% |
| 10% | -13.2% | -7.8% |

**Key insight:** Tour average matches are noise. Filtering them improves ROI by ~5 percentage points.

### Skip Matches with Insufficient Data (COMPLETED)

For a betting model, there's no reason to simulate matches where a player has insufficient data. No informational edge = no bet.

**Implemented:** Added `require_player_data` parameter to `simulate_match_probability()` and `backtest_period()`. When TRUE, matches where either player uses tour_average are skipped and reported separately.

### Minimum Match Threshold Analysis (COMPLETED)

Tested different MIN_TOTAL_MATCHES values on H1 2024 data:

| Min Matches | N Matches | Accuracy | Brier | ROI@5% |
|-------------|-----------|----------|-------|--------|
| 5 | 1,259 | 58.8% | 0.2344 | -7.4% |
| 10 | 1,223 | 58.8% | 0.2338 | -6.0% |
| 15 | 1,195 | 58.9% | 0.2334 | -4.7% |
| 20 | 1,162 | 58.6% | 0.2338 | -4.3% |
| 25 | 1,125 | 58.6% | 0.2344 | -3.8% |
| 30 | 1,104 | 58.9% | 0.2340 | -4.2% |
| 40 | 1,078 | 58.7% | 0.2343 | -3.6% |
| 50 | 1,000 | 59.5% | 0.2336 | -4.3% |

**Key findings:**
1. Accuracy is fairly flat across all thresholds (58.6% - 59.5%)
2. Brier score is also stable (0.2334 - 0.2344)
3. **ROI improves significantly with higher thresholds** - from -7.4% at 5 matches to -3.6% at 40 matches
4. Best ROI (-3.6%) at 40 matches, but loses ~180 matches vs threshold of 10

**Recommendation:** Consider increasing MIN_TOTAL_MATCHES from 10 to 20-25:
- Minimal accuracy loss
- ~4 percentage point ROI improvement
- Still retains ~75% of matches

**Future investigation:** Consider separate thresholds for serve stats vs return stats (return might be noisier)

---

## Session Summary - 2026-01-29

### What Was Completed

1. **Similarity-weighted stats fallback** - When a player has < 20 matches, the model now:
   - Looks for them in the charting feature database (303 players)
   - Finds top 10 similar players using cosine similarity
   - Uses similarity-weighted average of their stats
   - Falls back to tour average only if not in charting data

2. **Skip insufficient data matches** - Added `require_player_data` parameter:
   - When TRUE, matches where either player uses tour_average are skipped
   - Backtest now reports skipped count separately from errors

3. **Raised minimum threshold** - Changed `MIN_TOTAL_MATCHES` from 10 to 20:
   - Based on analysis showing ~2% ROI improvement with minimal accuracy loss

### Current Model Performance (H1 2024, real data only)

- Accuracy: 58.9%
- Brier Score: 0.2336
- ROI at 5% edge: -5.1%
- Market baseline: 67.2%

### Next Steps (Priority Order)

1. **Improve name matching** - Many players fail similarity lookup due to name format mismatch between betting data ("Auger-Aliassime F.") and charting data ("Felix Auger Aliassime"). Fixing this could significantly increase similarity usage beyond the current 1.4%.

2. **Revisit adjustment formula** - The additive adjustment may be too severe. Consider:
   - Multiplicative approach (skill ratios instead of skill differences)
   - Bradley-Terry style model
   - Interaction effects (returner impact varies by server strength)

3. **The model still underperforms market** - 58.9% vs 67.2%. Fundamental question: is the point-by-point simulation adding value, or would a simpler Elo model perform better?

### Key Files Modified This Session

- `r_analysis/simulator/02_player_stats.R` - similarity fallback, threshold change
- `r_analysis/simulator/03_match_probability.R` - require_player_data flag
- `r_analysis/simulator/06_backtest.R` - skip handling, feature_db loading

### Saved Data

- `data/processed/backtest_h1_2024_with_similarity.rds` - Full backtest results with similarity

---
