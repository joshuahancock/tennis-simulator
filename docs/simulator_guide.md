# Tennis Match Simulator - Technical Guide

This document provides a detailed line-by-line explanation of how the Monte Carlo tennis simulator works. The system consists of six R scripts that work together to simulate tennis matches and backtest predictions against historical betting lines.

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [01_mc_engine.R - Core Simulation Engine](#01_mc_enginer---core-simulation-engine)
3. [02_player_stats.R - Player Statistics Loader](#02_player_statsr---player-statistics-loader)
4. [03_match_probability.R - Probability Calculator](#03_match_probabilityr---probability-calculator)
5. [04_similarity_adjustment.R - Similarity Enhancements](#04_similarity_adjustmentr---similarity-enhancements)
6. [05_betting_data.R - Betting Data Integration](#05_betting_datar---betting-data-integration)
7. [06_backtest.R - Backtesting Framework](#06_backtestr---backtesting-framework)
8. [Potential Improvements](#potential-improvements)

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                        06_backtest.R                            │
│              (Orchestrates everything, runs backtests)          │
└─────────────────────────────────────────────────────────────────┘
                                │
            ┌───────────────────┼───────────────────┐
            ▼                   ▼                   ▼
┌───────────────────┐ ┌─────────────────┐ ┌─────────────────────┐
│ 05_betting_data.R │ │03_match_prob.R  │ │04_similarity_adj.R  │
│(Load betting odds)│ │(Run simulations)│ │(Adjust for matchups)│
└───────────────────┘ └─────────────────┘ └─────────────────────┘
                              │                     │
                      ┌───────┴───────┐             │
                      ▼               ▼             │
            ┌─────────────────┐ ┌─────────────────┐ │
            │ 01_mc_engine.R  │ │02_player_stats.R│◄┘
            │(Point-by-point  │ │(Load ATP/WTA    │
            │ simulation)     │ │ match data)     │
            └─────────────────┘ └─────────────────┘
```

**Data Flow:**
1. `02_player_stats.R` loads ATP/WTA match data and calculates serve/return percentages
2. `01_mc_engine.R` simulates individual points, games, sets, and matches
3. `03_match_probability.R` runs thousands of simulations to estimate win probability
4. `04_similarity_adjustment.R` (optional) adjusts stats based on opponent playing style
5. `05_betting_data.R` loads historical betting odds from tennis-data.co.uk
6. `06_backtest.R` compares model predictions to betting lines and calculates ROI

---

## 01_mc_engine.R - Core Simulation Engine

This is the heart of the simulator. It implements tennis scoring rules and simulates matches point-by-point.

### Key Probability Model

The model uses these statistics to determine point outcomes:

| Statistic | Description | Typical ATP Value |
|-----------|-------------|-------------------|
| `first_in_pct` | % of first serves that land in | 60-65% |
| `first_won_pct` | % of points won when first serve is in | 70-78% |
| `second_won_pct` | % of points won on second serve | 48-55% |
| `ace_pct` | % of service points that are aces | 5-12% |
| `df_pct` | % of service points that are double faults | 2-4% |
| `return_vs_first` | % of points won returning first serve | 28-35% |
| `return_vs_second` | % of points won returning second serve | 45-55% |

### `simulate_point()` (Lines 18-67)

Simulates a single point. The logic flow is:

```
1. Roll random number to determine if first serve is IN
   └─► If IN (prob = first_in_pct):
       ├─► Check for ACE (prob = ace_pct / first_in_pct)
       │   └─► If ace: server wins immediately
       └─► Otherwise: rally on first serve
           └─► Server wins with prob = first_won_pct (adjusted by returner skill)

   └─► If OUT (prob = 1 - first_in_pct):
       ├─► Second serve always assumed in (simplified)
       ├─► Check for DOUBLE FAULT (prob = df_pct / (1 - first_in_pct))
       │   └─► If DF: returner wins immediately
       └─► Otherwise: rally on second serve
           └─► Server wins with prob = second_won_pct (adjusted by returner skill)
```

**Key insight on lines 25-26:** Ace rate is conditional. If a player has 8% aces overall and 62% first serves in, the ace rate *given* a first serve is in is `0.08 / 0.62 = 12.9%`.

**Returner adjustment (lines 32-40):** If the returner has stats, we adjust the server's win probability:
```r
adjustment <- avg_return_vs_first - returner_stats$return_vs_first
win_prob <- server_stats$first_won_pct + adjustment
```
This means: if the returner is *better* than average (higher return %), they pull down the server's win probability.

### `simulate_game()` (Lines 78-107)

Simulates a service game using standard tennis scoring:
- First to 4 points wins (0, 15, 30, 40, game)
- Must win by 2 (deuce/advantage rules)

```r
while (TRUE) {
  point_result <- simulate_point(server_stats, returner_stats)
  # Update score...

  # Check win conditions (lines 98-105)
  if (server_points >= 4 && server_points - returner_points >= 2) {
    return(winner = 1)  # Server holds
  }
  if (returner_points >= 4 && returner_points - server_points >= 2) {
    return(winner = 0)  # Break!
  }
}
```

### `simulate_tiebreak()` (Lines 115-166)

Implements tiebreak scoring rules:
- First to 7 points (or 10 for super tiebreak)
- Win by 2
- **Serve rotation**: P1 serves point 1, then alternate every 2 points

The serve rotation logic (lines 130-134):
```r
if (point_num == 0) {
  server_is_p1 <- TRUE
} else {
  # Pattern: point 1-2 P2 serves, 3-4 P1 serves, 5-6 P2 serves...
  server_is_p1 <- ((point_num - 1) %/% 2) %% 2 == 0
}
```

### `simulate_set()` (Lines 181-254)

Simulates a complete set:
- First to 6 games with 2-game lead, or
- Tiebreak at 6-6

Key logic for tiebreak triggering (lines 227-249):
```r
if (p1_games == 6 && p2_games == 6) {
  if (final_set_tb == "none") {
    # Advantage set - continue playing
    next
  }
  # Play tiebreak (7-point or 10-point super)
  tb_result <- simulate_tiebreak(...)
}
```

### `simulate_match()` (Lines 267-326)

Simulates a complete match:
- Best of 3 (need 2 sets) or best of 5 (need 3 sets)
- Tracks set scores and handles final set rules

**First server is random** (line 277): `first_server <- sample(1:2, 1)`

This is a simplification - in reality, the player who wins the coin toss chooses to serve or receive.

---

## 02_player_stats.R - Player Statistics Loader

Loads ATP/WTA match data and calculates serve/return statistics for each player.

### Data Source

Uses Jeff Sackmann's tennis data repository:
- Files: `data/raw/tennis_atp/atp_matches_YYYY.csv`
- Contains ~2,700 matches per year with detailed serve statistics

### `load_atp_matches()` (Lines 34-77)

Loads match files and standardizes surfaces:
```r
surface = case_when(
  str_to_lower(surface) %in% c("hard", "h") ~ "Hard",
  str_to_lower(surface) %in% c("clay", "c") ~ "Clay",
  str_to_lower(surface) %in% c("grass", "g") ~ "Grass",
  ...
)
```

**Important filter (line 73):** Only includes matches with serve stats:
```r
filter(!is.na(w_svpt), w_svpt > 0)
```

### `calculate_player_stats()` (Lines 134-243)

This is the core statistics calculation. It:

1. **Reshapes data** to have one row per player per match (lines 136-184):
   - Winner stats come from `w_*` columns
   - Loser stats come from `l_*` columns

2. **Calculates return stats** (lines 189-195):
   ```r
   return_pts_won = opp_serve_pts - opp_first_won - opp_second_won
   return_vs_first = opp_first_in - opp_first_won
   ```
   Return points won = opponent's serve points they *didn't* win.

3. **Aggregates by player** (and optionally surface) using `group_by()` (lines 200-240)

4. **Calculates percentages** (lines 224-239):
   ```r
   first_in_pct = total_first_in / total_serve_pts
   first_won_pct = total_first_won / total_first_in
   second_won_pct = total_second_won / (total_serve_pts - total_first_in)
   ```

### `get_player_stats()` (Lines 341-413)

Retrieves stats for a specific player with fallback logic:

```
1. Try to find player in database
2. If found with >= MIN_TOTAL_MATCHES (10):
   a. Try surface-specific stats if >= MIN_SURFACE_MATCHES (20)
   b. Fall back to overall stats
3. If not found or insufficient data:
   └─► Use tour average (with warning)
```

**This is why we see warnings like** "Using tour average for Wolf J.J."

### Configuration Constants (Lines 16-23)

```r
MIN_SURFACE_MATCHES <- 20   # Need 20+ matches for surface-specific stats
MIN_TOTAL_MATCHES <- 10     # Need 10+ total matches
STATS_YEARS_WINDOW <- 3     # (Not currently used - potential improvement)
```

---

## 03_match_probability.R - Probability Calculator

Runs Monte Carlo simulations to estimate match win probabilities.

### `simulate_match_probability()` (Lines 30-130)

Main function that:
1. Loads player stats
2. Runs N simulations (default: 10,000)
3. Returns win probability with confidence interval

**Core simulation loop (lines 76-79):**
```r
for (i in 1:n_sims) {
  results[[i]] <- simulate_match(p1_stats, p2_stats, best_of = best_of)
}
```

**Win probability calculation (lines 85-86):**
```r
p1_wins <- sum(winners == 1)
p1_win_prob <- p1_wins / n_sims
```

### `prop_ci()` - Wilson Score Interval (Lines 137-150)

Calculates confidence interval for the win probability using the Wilson score method:

```r
denominator <- 1 + z^2 / n
centre <- p + z^2 / (2 * n)
spread <- z * sqrt((p * (1 - p) + z^2 / (4 * n)) / n)
```

Wilson intervals are preferred over simple binomial CIs because they work better near 0 and 1.

With 10,000 simulations and a 60% win rate, the 95% CI is approximately ±1%.

### `validate_model()` (Lines 224-308)

Tests model calibration on historical matches:

**Brier Score (line 268):**
```r
brier_score <- mean((predictions$predicted_prob - predictions$actual)^2)
```
- 0 = perfect predictions
- 0.25 = random (50/50 every time)
- Lower is better

**Calibration** groups predictions into bins (0-10%, 10-20%, etc.) and checks if predicted probabilities match actual win rates.

---

## 04_similarity_adjustment.R - Similarity Enhancements

Two approaches to adjust predictions based on opponent playing style.

### Approach 1: Historical Matchup Weighting

**Concept:** How does Player A perform against players *similar* to Player B?

1. **Find similar players** using feature vectors (serve %, return %, net play, etc.)
2. **Get A's record** against those similar players
3. **Weight by similarity** and recency
4. **Adjust base stats** accordingly

`find_similar_to_player()` (Lines 71-108) uses cosine similarity on a feature matrix to find similar players.

`get_performance_vs_similar()` (Lines 116-207) calculates weighted serve statistics from A's matches against similar opponents.

`apply_historical_adjustment()` (Lines 214-243) blends base stats with historical performance:
```r
adjusted$first_won_pct <- base_stats$first_won_pct * (1 - weight) +
  vs_similar_stats$first_won_pct * weight
```

Default weight is 0.3 (30% historical, 70% base).

### Approach 2: Style-Based Adjustments

`classify_player_style()` (Lines 253-332) categorizes players based on z-scores:

| Style | Characteristics |
|-------|-----------------|
| `serve_and_volley` | Big server + net rusher |
| `power_baseliner` | Big server + stays back |
| `counterpuncher` | Elite returner + defensive |
| `aggressive_baseliner` | High winner % |
| `all_rounder` | Everything else |

`calculate_style_matchup()` (Lines 338-386) applies multipliers based on matchup theory:

```r
# Big server vs elite returner: server loses some edge
if (p1_style$serve_power == "big_server" &&
    p2_style$return_skill == "elite_returner") {
  p1_adj$serve_mult <- 0.95
}
```

**The multipliers are currently hardcoded** (e.g., 0.95, 0.92). These could be learned from data.

---

## 05_betting_data.R - Betting Data Integration

Loads historical odds from tennis-data.co.uk.

### Data Format

Files from tennis-data.co.uk contain:
- Match info: date, tournament, surface, round
- Players: winner, loser, rankings
- Odds from multiple bookmakers: Pinnacle (PS), Bet365 (B365), etc.

### `load_betting_data()` (Lines 135-220)

Supports multiple naming conventions:
- `2024.xlsx` (default from tennis-data.co.uk)
- `atp_2024.xlsx` (prefixed format)

Filters by year range and handles type coercion issues.

### `standardize_player_names()` (Lines 435-501)

**Critical for matching betting data to ATP stats.**

Betting data uses `"Sinner J."` format, but ATP data uses `"Jannik Sinner"`.

The matching algorithm:
1. Build lookup table from ATP names → betting-style names
2. For each betting name, try:
   - Exact match on `"LastName F."` format
   - Match without period: `"LastName F"`
   - Parse and match last name + initial
   - Try as-is (maybe already ATP format)
3. Return original if no match found

**Current matching rate: ~90%** - some edge cases still fail (multi-initial names like "Kwon S.W.", hyphenated names, etc.)

### `extract_best_odds()` (Lines 375-395)

Gets the best available odds for each match, preferring sharper books:
```r
PREFERRED_BOOKS <- c("PS", "B365", "EX", "LB", "CB", "SB")
```

Pinnacle (PS) is preferred because they're the sharpest bookmaker.

### Odds Utilities

`odds_to_implied_prob()`: Converts decimal odds to probability
```r
1.50 odds → 1/1.50 = 66.7% implied probability
```

`remove_vig()`: Calculates fair odds by removing bookmaker margin
```r
If odds are 1.80 / 2.10:
  Implied probs: 55.6% + 47.6% = 103.2%
  Vig: 3.2%
  Fair probs: 53.8% / 46.2%
```

---

## 06_backtest.R - Backtesting Framework

Orchestrates everything to evaluate model performance.

### `backtest_single_match()` (Lines 52-112)

For each match:
1. Get player stats
2. Run N simulations
3. Return predicted probability for winner

**Important:** We simulate `winner vs loser`, so `p1_win_prob` is the probability the *actual winner* wins. This should be > 50% for accurate predictions.

### `backtest_period()` (Lines 125-245)

Main backtesting function:
1. Load data (betting, stats, features)
2. Standardize player names
3. Filter to date range and matches with valid odds
4. Loop through matches, simulating each
5. Calculate edges and analyze results

**Edge calculation (lines 225-231):**
```r
edge_winner = model_prob_winner - implied_prob_winner
```
Positive edge = model thinks winner is more likely than bookmaker does.

### `simulate_betting()` (Lines 332-447)

Simulates two betting strategies:

**1. Flat Betting (lines 387-394):**
- Bet $100 on every opportunity with edge > threshold
- Calculate total profit and ROI

**2. Kelly Betting (lines 397-424):**
```r
# Kelly formula: f = (bp - q) / b
b <- bet$bet_odds - 1
p <- bet$bet_prob
q <- 1 - p
kelly <- (b * p - q) / b

# Apply fractional Kelly (25%) and max bet cap (5%)
stake_fraction <- min(kelly * kelly_fraction, MAX_BET_FRACTION)
```

Kelly betting sizes bets proportionally to edge. Fractional Kelly (25%) reduces variance.

### `analyze_backtest()` (Lines 254-304)

Calculates key metrics:

| Metric | What It Measures | Our Results |
|--------|------------------|-------------|
| Accuracy | % of winners correctly predicted (>50%) | 71.6% |
| Brier Score | Mean squared error of probabilities | 0.1903 |
| Log Loss | Cross-entropy loss | 0.5623 |
| ROI | (Profit / Total Wagered) × 100 | +33.8% at 3% edge |

### Calibration

The calibration table shows predicted vs actual win rates in each probability bin:

```
prob_bin  | n    | mean_predicted | actual_win_rate
(0.5,0.6] | 1090 | 0.550          | 1.000
(0.6,0.7] | 1073 | 0.649          | 1.000
```

**Note:** `actual_win_rate = 1.000` for all bins because we're always predicting the actual winner! This is a quirk of how the backtest is structured - we simulate `winner vs loser`, so the "actual" is always 1.

---

## Potential Improvements

Based on this analysis, here are areas to consider improving:

### 1. Point-Level Model

**Current limitation:** The model doesn't account for:
- Point importance (break point, set point, etc.)
- Momentum/streakiness
- Fatigue over long matches
- In-play dynamics

**Potential improvement:** Weight points differently or model pressure situations.

### 2. Player Stats

**Current limitations:**
- Uses all historical data equally (no recency weighting)
- `STATS_YEARS_WINDOW` is defined but not used
- No injury/form adjustments
- Surface-specific stats need 20 matches (may be too strict for grass)

**Potential improvements:**
- Exponential decay weighting for recent matches
- Reduce surface threshold or use Bayesian shrinkage
- Incorporate recent match results (form)

### 3. Serve vs Return Adjustment

**Current approach (lines 32-40 in mc_engine.R):**
```r
avg_return_vs_first <- 0.35  # Hardcoded tour average
adjustment <- avg_return_vs_first - returner_stats$return_vs_first
```

**Issue:** Uses hardcoded tour averages. Could be calculated dynamically.

### 4. Name Matching

**Current rate: ~90%** - losing 10% of player data.

**Edge cases not handled:**
- Multi-initial names: "Kwon S.W."
- Hyphenated names: "Auger-Aliassime F."
- Apostrophes: "O'Connell C."
- Accented characters

### 5. Style Adjustments

**Current approach:** Hardcoded multipliers (0.95, 0.92, etc.)

**Potential improvement:** Learn these from historical H2H data between style categories.

### 6. Calibration

**Issue:** Current calibration analysis always shows 100% actual win rate because we simulate winner vs loser.

**Fix:** Should simulate both directions and include losses in calibration:
- Predict P(player1 wins) for all matches
- Actual = 1 if player1 won, 0 if lost
- This gives true calibration

### 7. Missing Second Serve Model

**Current simplification (line 47 in mc_engine.R):** Second serve is assumed to always go in.

**Reality:** There's a small percentage of missed second serves that *aren't* double faults (let cords, etc.)

### 8. Tiebreak Strategy

**Current:** Uses same stats as regular games.

**Reality:** Some players perform differently in tiebreaks (pressure handling).

---

## Summary

The simulator works by:
1. Loading historical serve/return statistics for each player
2. Simulating matches point-by-point using those statistics
3. Running thousands of simulations to estimate win probability
4. Comparing predictions to betting lines to find edges
5. Evaluating profitability across different edge thresholds

The model achieves:
- **71.6% accuracy** predicting match winners
- **0.19 Brier score** (better than 0.25 random baseline)
- **+34% ROI** at 3% edge threshold (vs -3% for ranking baseline)

Key strengths:
- Uses actual serve/return data, not just rankings
- Surface-specific statistics
- Monte Carlo approach naturally handles match volatility

Key limitations:
- Doesn't model point importance or momentum
- No recency weighting on statistics
- Some player names fail to match (~10%)
- Hardcoded style adjustment multipliers
