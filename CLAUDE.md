# Tennis Match Simulator - Project Context

> This file provides persistent context for Claude across sessions. Read it at the start of every session.

---

## Communication Guidelines

- Refer to the user as **Josh Hancock**
- Primary language: R (with Python scaffolding planned)

---

## Estimation Philosophy

**Design before results.** During estimation and analysis:

- Do NOT express concern or excitement about point estimates
- Do NOT interpret results as "good" or "bad" until the design is intentional
- Focus entirely on whether the specification is correct
- Results are meaningless until we're confident the "experiment" is designed on purpose
- Objectivity means being attached to getting the design right, not to any particular finding

---

## Project Overview

A probabilistic tennis match simulator that predicts match outcomes and compares predictions against historical betting lines. The model uses serve and return statistics from ATP/WTA match data to simulate matches point-by-point using Monte Carlo methods.

### Research Question

Can a point-by-point Monte Carlo simulation model, using serve/return statistics, generate profitable betting edges compared to bookmaker odds?

### Data Sources

| Data | Source | Time Period |
|------|--------|-------------|
| Match statistics | Jeff Sackmann's tennis_atp repository | 2014–2024 (no 2025 file yet as of 2026-02-25) |
| ATP betting odds | tennis-data.co.uk (`data/raw/tennis_betting/atp/`) | 2014–2026 |
| WTA betting odds | tennis-data.co.uk (`data/raw/tennis_betting/wta/`) | 2014–2026 |
| Player features | Tennis charting project | ~303 players with detailed features |

**Tournament tier filter (applied to all training and evaluation):**
- ATP: `Series` column — `"Grand Slam"`, `"Masters 1000"`, `"Masters Cup"`, `"ATP500"`; 250s excluded
- WTA: `Tier` column — `"Grand Slam"`, `"WTA1000"`, `"WTA500"`, `"Tour Championships"`, `"Premier"` (pre-2021 only; see note)
- **WTA tier note:** tennis-data.co.uk uses `"Premier"` for all pre-2021 Premier sub-tiers (Mandatory=1000, 5=500, and lower Premier) under one label. Post-2021 is clean (`WTA1000`/`WTA500`). Evaluate accuracy on 2021+ only.
- 250-level events (`"International"`, `"WTA250"`) are excluded from both tours

### Identification Strategy

The model's "edge" comes from:
1. Using actual serve/return percentages rather than Elo/rankings
2. Surface-specific statistics (minimum 20 matches on surface)
3. Similarity-weighted fallback for players with insufficient data
4. Monte Carlo simulation (10,000 iterations) to capture match volatility

---

## Key Decisions Made

| Date | Decision | Rationale |
|------|----------|-----------|
| 2026-02-26 | Added WTA data; both tours now supported | Paper (Tamber et al. 2025) uses ATP + WTA. WTA files use `Tier` not `Series`; handled in loader. Pre-2021 `"Premier"` tier is mixed-level |
| 2026-02-26 | Fixed Angelini WElo formula bug | Original code replaced binary outcome with games proportion; correct formula scales the standard update by games proportion: `K*(1-p)*f_g` |
| 2026-02-25 | **Training and evaluation restricted to premium tier only (both tours)** | Aligns with paper (Tamber et al. 2025). 250s excluded — separate roadmap item |
| 2026-02-25 | Switched to tennis-data.co.uk as primary data source for Elo/MagNet | Paper uses this source (confirmed from arxiv). Covers 2014–2026 for both tours; Sackmann still used for MC (needs serve/return stats) |
| 2026-02-09 | Fixed critical data leakage via date alignment | ATP data used `tourney_date` (tournament start) while betting used actual match dates, causing same-tournament future results to leak into Elo training |
| 2026-02-05 | Implemented surface-specific Elo ratings | Literature review recommended Elo as skill backbone; previous backtests showed +9.6pp accuracy vs MC (now invalidated by leakage fix) |
| 2026-01-24 | Raised MIN_TOTAL_MATCHES from 10 to 20 | Threshold analysis showed ~4pp ROI improvement with minimal accuracy loss |
| 2026-01-24 | Added `require_player_data` flag | Tour average matches are noise; filtering improves ROI ~5pp |
| 2026-01-23 | Implemented similarity-weighted stats fallback | More informed baseline than generic tour averages when player has <20 matches |
| -- | Additive returner adjustment formula | `win_prob = server_stat + (avg - returner_stat)`. May be too severe - revisit later. |

---

## Dropped Analyses

Things tried but abandoned (so Claude doesn't suggest them again):

- **Cross-language replication (Python/Stata)**: Not yet attempted. This is a PRIORITY for Referee 2 audit.
- **Style-based adjustments (src/models/monte_carlo/similarity.R)**: Hardcoded multipliers didn't improve results. Needs data-driven approach.

---

## Directory Structure

Code is organized by pipeline stage (not language). All paths relative to project root.

```
src/
├── data/           # Shared data loading & processing
├── models/
│   ├── monte_carlo/   # MC simulation engine
│   ├── elo/           # Elo rating system
│   └── [new_model]/   # Future models go here
├── backtesting/    # Shared backtesting framework
└── utils/          # Shared utilities

analysis/           # Research analyses (not pipeline)
├── calibration/    edge/    model_variants/
├── validation/     trajectory/    features/

scripts/            # Top-level runners (run_analysis.R, compare_models.R, etc.)
tests/              # Unit tests
```

## Key Files

| Purpose | File |
|---------|------|
| Main simulation engine | `src/models/monte_carlo/mc_engine.R` |
| Player statistics loader | `src/data/player_stats.R` |
| Monte Carlo probability | `src/models/monte_carlo/match_probability.R` |
| Similarity adjustments | `src/models/monte_carlo/similarity.R` |
| Betting data integration | `src/data/betting_data.R` |
| Backtesting framework | `src/backtesting/backtest.R` |
| Elo rating system | `src/models/elo/elo_ratings.R` |
| Date alignment | `src/data/date_alignment.R` |
| Shared utilities | `src/utils/utils.R` |
| Technical documentation | `docs/simulator_guide.md` |
| Quick reference | `docs/quick_reference.md` |

---

## Variable Definitions

| Variable | Definition | Source |
|----------|------------|--------|
| `first_in_pct` | % of first serves landing in | ATP match data |
| `first_won_pct` | % of points won when first serve in | ATP match data |
| `second_won_pct` | % of points won on second serve | ATP match data |
| `ace_pct` | % of service points that are aces | ATP match data |
| `df_pct` | % of service points that are double faults | ATP match data |
| `return_vs_first` | % of return points won vs first serve | Calculated |
| `return_vs_second` | % of return points won vs second serve | Calculated |
| `edge` | `model_prob - implied_prob` | Calculated at backtest |

---

## Sample Restrictions

- **Tournament tier: premium only for both tours** (see Data Sources for tier label details)
  - ATP: Grand Slam, Masters 1000, Masters Cup, ATP500
  - WTA: Grand Slam, WTA1000, WTA500, Tour Championships, Premier (pre-2021 training only)
- Matches with valid serve statistics only (`w_svpt > 0`) — MC model only
- Players with >= 20 total matches (MIN_TOTAL_MATCHES) — MC model only
- Surface-specific stats require >= 20 matches on that surface — MC model only
- Betting odds must be available from preferred bookmakers

**Note on 250s:** Excluded from both training and evaluation on both tours. Separate roadmap item.

---

## Configuration Constants

```r
# src/data/player_stats.R
MIN_SURFACE_MATCHES <- 20   # Matches needed for surface-specific stats
MIN_TOTAL_MATCHES <- 20     # Matches needed for any player stats
SIMILARITY_TOP_N <- 10      # Similar players for weighted fallback

# src/backtesting/backtest.R
EDGE_THRESHOLDS <- c(0.01, 0.03, 0.05, 0.10)
KELLY_FRACTION <- 0.25
STARTING_BANKROLL <- 10000
MAX_BET_FRACTION <- 0.05
MIN_ODDS <- 1.10
BACKTEST_N_SIMS <- 1000

# src/models/elo/elo_ratings.R
DEFAULT_ELO <- 1500              # Starting Elo for new players
K_FACTOR_DEFAULT <- 32           # K-factor for established players
K_FACTOR_PROVISIONAL <- 48       # K-factor for new players (<5 matches)
MIN_MATCHES_FOR_RATING <- 5      # Matches before player is non-provisional
MIN_SURFACE_MATCHES_FOR_ELO <- 10  # Matches for full surface-specific weight
ELO_SURFACES <- c("Hard", "Clay", "Grass")
```

---

## Current Status

**Phase**: Data Leakage Fix / Re-validation

**CRITICAL FIX (2026-02-09):** Discovered and fixed data leakage via `tourney_date` mismatch. All previous results were inflated because:
- ATP data used tournament START date for all matches
- Betting data used actual match dates
- Later-round results leaked into Elo training for earlier-round predictions

**Date alignment module (`src/data/date_alignment.R`) achieves:**
- 90.4% exact/variant date matches with betting data
- 9.6% inferred dates (United Cup, Davis Cup not in betting data)

**Previous results (INVALIDATED by leakage):**

| Model | Accuracy | Brier Score | Log Loss | Status |
|-------|----------|-------------|----------|--------|
| Elo (surface-specific) | 68.6% | 0.2029 | 0.5913 | ❌ INVALID |
| Monte Carlo (base) | 58.7% | 0.2338 | 0.6601 | ❌ INVALID |

**Corrected results (H1 2024, full 2015+ history with cached alignment):**

| Model | Accuracy | Brier Score | Log Loss | Status |
|-------|----------|-------------|----------|--------|
| **Elo (surface-specific)** | **60.8%** | **0.2331** | **0.6585** | ✓ CLEAN |
| Monte Carlo (base) | 56.0% | 0.2451 | 0.6846 | ✓ CLEAN |
| **Elo advantage** | **+4.8pp** | **-0.012** | **-0.026** | |

**Leakage impact analysis:**

| Model | Old (Leaky) | New (Clean) | Inflation |
|-------|-------------|-------------|-----------|
| Elo | 68.6% | 60.8% | -7.8pp |
| MC | 58.7% | 56.0% | -2.7pp |

**Key insights:**
1. Elo still outperforms MC, but gap is 4.8pp (not 9.9pp as previously reported)
2. Leakage inflated Elo more than MC (as referee predicted) because Elo is more sensitive to per-match rating updates
3. Neither model beats the market (~67% accuracy) - no genuine betting edge exists
4. ROI is negative at all thresholds for both models

**Paper scope:** Tamber et al. (2025) uses both ATP and WTA, treats them as separate prediction tasks. 16,663 ATP matches + 16,447 WTA matches (Jan 2014 – Jun 2025). Results reported separately by gender and surface, plus combined.

**Current Elo baseline results (2023–2025 test, premium tier, Kovalchik K, `analysis/model_variants/angelini_elo.R`):**

| Tour | Model | Accuracy | Brier |
|------|-------|----------|-------|
| ATP | Standard Elo (surface) | 65.0% | 0.2195 |
| ATP | Angelini WElo | 65.3% | 0.2164 |
| WTA | Standard Elo (surface) | 63.7% | 0.2224 |
| WTA | Angelini WElo | 64.3% | 0.2193 |

**K-factor comparison (fixed K=32 vs Kovalchik K=250/(N+5)^0.4):**

| Tour | K method | Std Acc | Ang Acc | BS_Std | BS_Ang |
|------|----------|---------|---------|--------|--------|
| ATP | fixed | 64.6% | 64.8% | 0.2162 | 0.2169 |
| ATP | kovalchik | 65.0% | 65.3% | 0.2195 | **0.2164** |
| WTA | fixed | 63.8% | 64.0% | 0.2197 | 0.2198 |
| WTA | kovalchik | 63.7% | 64.3% | 0.2224 | **0.2193** |

Kovalchik K is now the default (`K_METHOD <- "kovalchik"` in angelini_elo.R), matching the paper.

**Paper baselines (combined ATP+WTA, 2023–Jun 2025):**

| Model | Accuracy | Brier |
|-------|----------|-------|
| Standard Elo | 65.8% | 0.215 |
| Angelini WElo | 66.4% | 0.212 |
| MagNet GNN | 65.7% | 0.215 (ATP); 0.207 (WTA) |
| Pinnacle odds | 69.0% | 0.196 |

**Remaining gap (~0.7–1pp vs paper):** Kovalchik K closed ~0.4pp of the ~1pp ATP accuracy gap. Remaining gap likely reflects training data composition differences (paper trains jointly on ATP+WTA, longer pre-2023 history) or surface blending details. Not worth further investigation — gap is within noise for this comparison.

**WElo formula fix (2026-02-26):** Previous implementation incorrectly replaced binary outcome with games proportion (`K*(games_prop - p)`). Correct formula per official `welo` R package source: `K*(1 - p)*games_prop` — scales standard update, never gives winner a negative update.

**Next priorities:**
1. Implement MagNet GNN replication
2. Obtain 2025 ATP match data (Sackmann hasn't published yet)

---

## Referee 2 Correspondence

This project uses the Referee 2 audit protocol. Correspondence is stored at:

```
correspondence/referee2/
├── YYYY-MM-DD_round1_report.md      # Referee 2's detailed written report
├── YYYY-MM-DD_round1_deck.pdf       # Referee 2's visual presentation of findings
├── YYYY-MM-DD_round1_response.md    # Author's revision response
└── ...
```

Replication scripts created by Referee 2 are stored at:
```
correspondence/referee2/replication/
├── referee2_replicate_mc_engine.py
├── referee2_replicate_mc_engine.do
└── ...
```

**Current Status:** Accepted with Minor Revisions (Round 2 complete)

**Critical Rule:** Referee 2 NEVER modifies author code. It only reads, runs, and creates its own replication scripts in `correspondence/referee2/replication/`. Only the author (you) modifies your own code in response to referee concerns.

---

## Known Issues / Technical Debt

1. **Hardcoded tour averages** in `src/models/monte_carlo/mc_engine.R` lines 45, 68: `avg_return_vs_first <- 0.35`, `avg_return_vs_second <- 0.50`. Should be calculated dynamically.

2. **Name matching ~90%** - Edge cases not handled: multi-initial names ("Kwon S.W."), hyphenated names ("Auger-Aliassime F."), apostrophes ("O'Connell C.").

3. **Calibration analysis misleading** - Always shows 100% actual win rate because we simulate winner vs loser. Should simulate both directions.

4. **Second serve always assumed in** - Small % of missed second serves that aren't double faults are ignored.

5. **No tiebreak-specific stats** - Uses same stats as regular games.

---

## Notes for Claude

- Core pipeline code is in `src/` (by stage), analysis scripts in `analysis/` (by theme), runners in `scripts/`, tests in `tests/`
- Session notes are in `docs/notes/session_notes.md` - update after significant work
- Code changes go in `docs/notes/changelog.md`
- When running backtests, use `require_player_data = TRUE` to filter out tour average matches
- Tour average fallback is the enemy of accurate predictions - avoid matches that use it
