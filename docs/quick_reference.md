# Tennis Simulator Quick Reference

## File Structure

```
r_analysis/simulator/
├── 01_mc_engine.R       # Point/game/set/match simulation
├── 02_player_stats.R    # Load ATP/WTA stats
├── 03_match_probability.R # Run Monte Carlo simulations
├── 04_similarity_adjustment.R # Style-based adjustments
├── 05_betting_data.R    # Load betting odds
└── 06_backtest.R        # Evaluate model performance
```

## Key Functions

### 01_mc_engine.R

| Function | Description | Key Parameters |
|----------|-------------|----------------|
| `simulate_point()` | Simulate one point | `server_stats`, `returner_stats` |
| `simulate_game()` | Simulate one service game | `server_stats`, `returner_stats` |
| `simulate_tiebreak()` | Simulate tiebreak | `p1_stats`, `p2_stats`, `to_points` |
| `simulate_set()` | Simulate one set | `p1_stats`, `p2_stats`, `first_server` |
| `simulate_match()` | Simulate complete match | `p1_stats`, `p2_stats`, `best_of` |
| `make_player_stats()` | Create stats object | `first_in_pct`, `first_won_pct`, etc. |

### 02_player_stats.R

| Function | Description | Key Parameters |
|----------|-------------|----------------|
| `load_atp_matches()` | Load match data | `year_from`, `year_to` |
| `load_player_stats()` | Build stats database | `tour`, `year_from`, `year_to` |
| `get_player_stats()` | Get single player stats | `player_name`, `surface`, `stats_db` |
| `calculate_player_stats()` | Aggregate player stats | `matches`, `by_surface` |

### 03_match_probability.R

| Function | Description | Key Parameters |
|----------|-------------|----------------|
| `simulate_match_probability()` | Run N simulations | `player1`, `player2`, `surface`, `n_sims` |
| `simulate_batch()` | Batch simulation | `matchups` dataframe |
| `validate_model()` | Test on historical data | `matches`, `stats_db` |

### 05_betting_data.R

| Function | Description | Key Parameters |
|----------|-------------|----------------|
| `load_betting_data()` | Load odds files | `data_dir`, `year_from`, `year_to` |
| `extract_best_odds()` | Get best available odds | `betting_data` |
| `standardize_player_names()` | Match names to ATP format | `betting_data`, `stats_db` |
| `odds_to_implied_prob()` | Convert odds to probability | `odds` |
| `remove_vig()` | Calculate fair odds | `odds1`, `odds2` |

### 06_backtest.R

| Function | Description | Key Parameters |
|----------|-------------|----------------|
| `backtest_period()` | Run full backtest | `start_date`, `end_date`, `model` |
| `simulate_betting()` | Simulate betting strategy | `predictions`, `edge_threshold` |
| `analyze_backtest()` | Calculate metrics | `predictions` |

## Player Stats Object

```r
list(
  player = "Jannik Sinner",
  surface = "Hard",
  source = "surface_specific",  # or "overall", "tour_average"
  matches = 45,
  first_in_pct = 0.62,     # 62% first serves in
  first_won_pct = 0.76,    # 76% points won on first serve
  second_won_pct = 0.54,   # 54% points won on second serve
  ace_pct = 0.09,          # 9% aces
  df_pct = 0.03,           # 3% double faults
  return_vs_first = 0.32,  # 32% return points won vs first serve
  return_vs_second = 0.52  # 52% return points won vs second serve
)
```

## Key Configuration Constants

### 02_player_stats.R
```r
MIN_SURFACE_MATCHES <- 20   # Matches needed for surface-specific stats
MIN_TOTAL_MATCHES <- 10     # Matches needed for any player stats
```

### 06_backtest.R
```r
EDGE_THRESHOLDS <- c(0.01, 0.03, 0.05, 0.10)  # Edge levels to test
KELLY_FRACTION <- 0.25      # Fractional Kelly (25%)
STARTING_BANKROLL <- 10000  # Starting bankroll for simulation
MAX_BET_FRACTION <- 0.05    # Max bet as % of bankroll
MIN_ODDS <- 1.10            # Minimum odds to bet
BACKTEST_N_SIMS <- 1000     # Simulations per match
```

## Probability Flow

```
Point Level:
  P(server wins) = P(1st in) × P(win|1st) + P(1st out) × P(win|2nd)

Where:
  P(win|1st) = first_won_pct (adjusted for returner skill)
  P(win|2nd) = second_won_pct (adjusted for returner skill)

  Adjustment = tour_avg_return - opponent_return_skill
```

## Edge Calculation

```r
model_prob = P(player wins) from simulation
implied_prob = 1 / decimal_odds
edge = model_prob - implied_prob

# Positive edge = model thinks player is undervalued by bookmaker
```

## Backtest Metrics

| Metric | Formula | Target |
|--------|---------|--------|
| Accuracy | % predicted favorites who won | > 65% |
| Brier Score | mean((prob - actual)²) | < 0.20 |
| ROI | profit / total_wagered | > 0% |
| CLV | avg(model_prob - closing_prob) | > 0% |

## Quick Start

```r
# 1. Load required files
source("r_analysis/simulator/06_backtest.R")

# 2. Run a backtest
results <- backtest_period(
  start_date = "2024-01-01",
  end_date = "2024-06-30",
  model = "base",
  tour = "ATP",
  n_sims = 1000
)

# 3. View results
results$analysis$accuracy        # Prediction accuracy
results$analysis$brier_score     # Brier score
results$analysis$betting_results # ROI at different thresholds
```

## Common Issues

| Issue | Cause | Solution |
|-------|-------|----------|
| "Using tour average for X" | Player name mismatch or insufficient data | Check name format, lower MIN_TOTAL_MATCHES |
| Low accuracy | Stats not representative | Use more recent data, add recency weighting |
| High variance in ROI | Small sample size | Run longer backtest, more simulations |
| Memory issues | Too many simulations | Reduce n_sims or batch processing |
