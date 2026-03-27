# Tennis Simulator Changelog

This file tracks all code changes made to the simulator.

---

## 2026-03-26 — Round 12 Referee Fixes (commit 38d2427)

**`src/models/magnet/graph_builder.py`**
- Fixed `in_degree = out_degree` placeholder bug. `_build_node_features`
  now receives the `direction` matrix (antisymmetric ±1) and computes:
  `out_degree = (direction > 0).sum(axis=1)` (edges where player dominates),
  `in_degree = (direction < 0).sum(axis=1)` (edges where player is dominated).
  Working-tree fix was applied 2026-03-12; this commit makes it permanent.
- Promoted `no_player_attrs` from externally injected `_no_player_attrs`
  attribute to a proper constructor parameter `no_player_attrs: bool = False`.

**`src/models/magnet/intransitivity.py`**
- `subgraph_evidence`: replaced silent `else: # "subgraph_sum"` fallthrough
  with explicit `elif formula == "subgraph_sum"` + `else: raise ValueError(...)`.

**`scripts/run_magnet.py`**
- Updated `GraphBuilder(...)` call to pass `no_player_attrs=no_player_attrs`
  at construction rather than injecting it post-hoc.

---

## 2026-03-12 — Round 9 Response: Trajectory Script Fixes

**`analysis/trajectory/trajectory_analysis.R`**
- Added PSW and PSL columns to the saved results tibble so downstream
  scripts can access actual Pinnacle odds.
- Fixed stale source path: `src/backtesting/07_elo_ratings.R` →
  `src/models/elo/elo_ratings.R` (post-reorganisation path).
- Fixed stale data path: `data/raw/tennis_betting/%d.xlsx` →
  `data/raw/tennis_betting/atp/%d.xlsx`.

**`analysis/trajectory/trajectory_contrarian.R`**
- Fixed fair-odds bug: replaced `1/(1 - mkt_prob_w)` with actual Pinnacle
  odds `PSL`/`PSW` in both in-sample and OOS sections.
- Rewritten as a proper chronological walk-forward over 2014–2026 ATP
  betting data (30,001 matches). Per-player sliding window (last 10 matches)
  for O(1) trajectory lookup. Burn-in 2014; bets from 2015-01-01.

---

## 2026-01-23 - Session Start

### Context
Resumed work on integrating player similarity into the simulator. Previous session ran a comparison backtest showing:
- Model with adjustment: 58.3% accuracy, Brier 0.2362
- Model without adjustment: 56.3% accuracy, Brier 0.2507
- Both underperform market baseline of 67.2%

### Current Task
Replace hardcoded tour averages (0.35, 0.50) with similarity-based averages when player-specific stats are unavailable.

### Changes Made

**02_player_stats.R:**
- Added `source("r_analysis/utils.R")` for similarity functions
- Added `SIMILARITY_TOP_N <- 10` configuration constant
- Added `get_similarity_weighted_stats()` function (lines 378-495):
  - Finds player in feature database
  - Gets top 10 similar players using cosine similarity
  - Looks up stats for similar players in stats_db
  - Calculates similarity-weighted average of their stats
  - Returns stats with `source = "similarity_weighted"`
- Modified `get_player_stats()`:
  - Added optional `feature_db` parameter
  - When player has < 10 matches, tries similarity fallback before tour average
  - Prints "Using similarity-weighted stats for X (N similar players)" when successful

**03_match_probability.R:**
- Added `feature_db = NULL` parameter to `simulate_match_probability()`
- Passes `feature_db` through to `get_player_stats()` calls

**06_backtest.R:**
- Changed feature_db loading to always load (not just for non-base models)
- Passes `feature_db` to `simulate_match_probability()` in base model branch

## 2026-01-24 - Skip Insufficient Data Matches

**03_match_probability.R:**
- Added `require_player_data` parameter to `simulate_match_probability()`
- When TRUE and either player uses tour_average, returns `list(skipped=TRUE, reason="insufficient_data")`

**06_backtest.R:**
- Added `require_player_data` parameter to `backtest_period()` and `backtest_single_match()`
- Added `skipped` counter to track matches skipped due to insufficient data
- Updated completion message and return value to include skipped count

**02_player_stats.R:**
- Changed `MIN_TOTAL_MATCHES` default from 10 to 20 (based on threshold analysis showing improved ROI)

---

## 2026-02-04 - Referee 2 Response (Round 1)

### Context
Referee 2 audit completed with verdict "Major Revisions". Addressed all major concerns except cross-language verification (delegated back to Referee 2).

### Changes Made

**01_mc_engine.R:**
- Added `DEFAULT_TOUR_AVG_RETURN_VS_FIRST` and `DEFAULT_TOUR_AVG_RETURN_VS_SECOND` constants
- Updated `simulate_point()` to accept `tour_avg_return_vs_first` and `tour_avg_return_vs_second` parameters
- Updated `simulate_game()`, `simulate_tiebreak()`, `simulate_set()`, `simulate_match()` to pass tour averages through call chain
- Removed hardcoded 0.35 and 0.50 values - now calculated from stats_db or passed explicitly

**03_match_probability.R:**
- Added `tour_avg_return_vs_first` and `tour_avg_return_vs_second` parameters
- Calculates tour averages from `stats_db$tour_avg_surface` or `stats_db$tour_avg_overall` if not provided
- Passes tour averages to `simulate_match()`
- Returns tour averages used in result object

**06_backtest.R:**
- Added `RANDOM_SEED <- 20260204` configuration constant
- Added `seed` parameter to `backtest_period()` with default from RANDOM_SEED
- Added `set.seed(seed)` call at start of `backtest_period()` for reproducibility
- Added `seed` to return value for documentation
- Added `bootstrap_roi_ci()` function for ROI confidence intervals (1000 bootstrap samples)
- Updated `simulate_betting()` to include `roi_ci_lower` and `roi_ci_upper` in output
- Updated `analyze_backtest()` output to show ROI with 95% CI
- Updated `compare_models_backtest()` to accept and pass `seed` parameter

**New files created:**
- `code/run_analysis.R` - Master script to run full pipeline
- `code/README.md` - Replication instructions
- `code/setup_renv.R` - Script to initialize renv dependency management

### Referee 2 Concerns Addressed

| Concern | Status | Notes |
|---------|--------|-------|
| No random seeds | FIXED | Added `set.seed()` with configurable seed |
| Hardcoded tour averages | FIXED | Now calculated from stats_db |
| No master script | FIXED | Created `code/run_analysis.R` |
| ROI without confidence intervals | FIXED | Added bootstrap CIs |
| No renv.lock | PARTIAL | Created setup script; user must run it |
| No code/README.md | FIXED | Created with full instructions |
| Python-R verification | DELEGATED | Referee 2 will verify with fixed seeds |

---
