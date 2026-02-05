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
source("code/setup_renv.R")
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
Rscript code/run_analysis.R
```

Or in R:

```r
setwd("path/to/tennis-simulator")
source("code/run_analysis.R")
```

### Configuration

Edit `code/run_analysis.R` to change:

- `BACKTEST_START_DATE` / `BACKTEST_END_DATE` - Date range to analyze
- `TOUR` - "ATP" or "WTA"
- `N_SIMS` - Simulations per match (1000 for quick runs, 10000 for final)
- `RANDOM_SEED` - Seed for reproducibility (default: 20260204)

### Output

Results are saved to `data/processed/backtest_[tour]_[dates].rds`

## Code Structure

```
r_analysis/simulator/
├── 01_mc_engine.R           # Core Monte Carlo simulation
├── 02_player_stats.R        # Player statistics calculation
├── 03_match_probability.R   # Win probability estimation
├── 04_similarity_adjustment.R # Style-based adjustments
├── 05_betting_data.R        # Betting odds integration
└── 06_backtest.R            # Backtesting framework

code/
├── run_analysis.R           # Master script (run this)
├── README.md                # This file
└── replication/             # Cross-language replication scripts
```

## Execution Order

The scripts are designed to be sourced in order via `06_backtest.R`:

1. `01_mc_engine.R` - Defines point/game/set/match simulation
2. `02_player_stats.R` - Loads and calculates player statistics
3. `03_match_probability.R` - Runs Monte Carlo simulations
4. `04_similarity_adjustment.R` - Optional style adjustments
5. `05_betting_data.R` - Loads betting odds
6. `06_backtest.R` - Orchestrates backtesting (sources 01-05)

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
