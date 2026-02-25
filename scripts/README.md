# Tennis Simulator - Replication Instructions

This document explains how to reproduce the analysis from raw data.

## Prerequisites

### R Version

R >= 4.0.0 required.

### R Packages

Install required packages:

```r
install.packages(c(
  "tidyverse",    # Data manipulation and visualization
  "lubridate",    # Date handling
  "readxl"        # Reading Excel files (for betting data)
))
```

Or restore the exact package versions using renv (recommended):

```r
# If renv.lock exists:
install.packages("renv")
renv::restore()

# If setting up for the first time:
source("scripts/setup_renv.R")
```

### Data

The following data must be present:

1. **ATP/WTA Match Data** (from Jeff Sackmann's GitHub repos)
   - Location: `data/raw/tennis_atp/` and `data/raw/tennis_wta/`
   - Files: `atp_matches_YYYY.csv` for years 2015-2024

2. **Betting Data** (from tennis-data.co.uk)
   - Location: `data/raw/betting/`
   - Files: `YYYY.xlsx` for years you want to backtest

3. **Charting Features** (optional, for similarity-based adjustments)
   - Location: `data/processed/charting_only_features.csv`

## Running the Analysis

### Quick Start

From the project root directory:

```bash
Rscript scripts/run_analysis.R
```

Or in R:

```r
setwd("path/to/tennis-simulator")
source("scripts/run_analysis.R")
```

### Configuration

Edit `scripts/run_analysis.R` to change:

- `BACKTEST_START_DATE` / `BACKTEST_END_DATE` - Date range to analyze
- `TOUR` - "ATP" or "WTA"
- `N_SIMS` - Simulations per match (1000 for quick runs, 10000 for final)
- `RANDOM_SEED` - Seed for reproducibility (default: 20260204)

### Output

Results are saved to `data/processed/backtest_[tour]_[dates].rds`

## Code Structure

```
src/
├── data/
│   ├── player_stats.R       # Player statistics calculation
│   ├── betting_data.R       # Betting odds integration
│   └── date_alignment.R     # Date alignment (leakage fix)
├── models/
│   ├── monte_carlo/
│   │   ├── mc_engine.R          # Core Monte Carlo simulation
│   │   ├── match_probability.R  # Win probability estimation
│   │   └── similarity.R         # Style-based adjustments
│   └── elo/
│       └── elo_ratings.R    # Elo rating system
├── backtesting/
│   └── backtest.R           # Backtesting framework (sources all above)
└── utils/
    └── utils.R              # Shared utilities

scripts/
├── run_analysis.R           # Master script (run this)
├── compare_models.R         # Elo vs MC comparison
├── validate_elo_betting.R   # Edge validation
└── README.md                # This file

correspondence/referee2/replication/  # Referee 2's cross-language scripts
```

## Execution Order

`src/backtesting/backtest.R` sources all dependencies in correct order:

1. `src/models/monte_carlo/mc_engine.R` - Point/game/set/match simulation
2. `src/data/player_stats.R` - Player statistics
3. `src/models/monte_carlo/match_probability.R` - Win probability
4. `src/models/monte_carlo/similarity.R` - Style adjustments
5. `src/data/betting_data.R` - Betting odds
6. `src/models/elo/elo_ratings.R` - Elo ratings
7. `src/data/date_alignment.R` - Date alignment

## Reproducibility

Results are reproducible given:

1. **Same random seed** - Set via `seed` parameter (default: 20260204)
2. **Same data files** - Match data and betting odds must be identical
3. **Same R version and packages** - Use `renv::restore()` for exact versions

To verify reproducibility:

```r
# Run twice with same seed
result1 <- backtest_period("2024-01-01", "2024-06-30", seed = 20260204)
result2 <- backtest_period("2024-01-01", "2024-06-30", seed = 20260204)

# Results should be identical
all.equal(result1$predictions$model_prob_p1, result2$predictions$model_prob_p1)
# [1] TRUE
```

## Key Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `MIN_TOTAL_MATCHES` | 20 | Minimum matches for player stats |
| `MIN_SURFACE_MATCHES` | 20 | Minimum matches for surface-specific stats |
| `BACKTEST_N_SIMS` | 1000 | Simulations per match in backtest |
| `RANDOM_SEED` | 20260204 | Random seed for reproducibility |

## Troubleshooting

**"Using tour average for [player]"**
- Player has insufficient match data (<20 matches)
- Use `require_player_data = TRUE` to skip these matches

**Different results across runs**
- Ensure `seed` parameter is set
- Check that data files haven't changed

**Memory issues**
- Reduce `n_sims` parameter
- Process in smaller date ranges
