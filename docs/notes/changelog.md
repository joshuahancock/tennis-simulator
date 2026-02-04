# Tennis Simulator Changelog

This file tracks all code changes made to the simulator.

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
