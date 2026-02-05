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
| Match statistics | Jeff Sackmann's tennis_atp repository | 2020-2025 |
| Betting odds | tennis-data.co.uk | 2024 (H1 for current backtests) |
| Player features | Tennis charting project | ~303 players with detailed features |

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
| 2026-01-24 | Raised MIN_TOTAL_MATCHES from 10 to 20 | Threshold analysis showed ~4pp ROI improvement with minimal accuracy loss |
| 2026-01-24 | Added `require_player_data` flag | Tour average matches are noise; filtering improves ROI ~5pp |
| 2026-01-23 | Implemented similarity-weighted stats fallback | More informed baseline than generic tour averages when player has <20 matches |
| -- | Additive returner adjustment formula | `win_prob = server_stat + (avg - returner_stat)`. May be too severe - revisit later. |

---

## Dropped Analyses

Things tried but abandoned (so Claude doesn't suggest them again):

- **Cross-language replication (Python/Stata)**: Not yet attempted. This is a PRIORITY for Referee 2 audit.
- **Style-based adjustments (04_similarity_adjustment.R)**: Hardcoded multipliers didn't improve results. Needs data-driven approach.

---

## Key Files

| Purpose | File |
|---------|------|
| Main simulation engine | `r_analysis/simulator/01_mc_engine.R` |
| Player statistics loader | `r_analysis/simulator/02_player_stats.R` |
| Monte Carlo probability | `r_analysis/simulator/03_match_probability.R` |
| Similarity adjustments | `r_analysis/simulator/04_similarity_adjustment.R` |
| Betting data integration | `r_analysis/simulator/05_betting_data.R` |
| Backtesting framework | `r_analysis/simulator/06_backtest.R` |
| Shared utilities | `r_analysis/utils.R` |
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

- Matches with valid serve statistics only (`w_svpt > 0`)
- Players with >= 20 total matches (MIN_TOTAL_MATCHES)
- Surface-specific stats require >= 20 matches on that surface
- Betting odds must be available from preferred bookmakers

---

## Configuration Constants

```r
# 02_player_stats.R
MIN_SURFACE_MATCHES <- 20   # Matches needed for surface-specific stats
MIN_TOTAL_MATCHES <- 20     # Matches needed for any player stats
SIMILARITY_TOP_N <- 10      # Similar players for weighted fallback

# 06_backtest.R
EDGE_THRESHOLDS <- c(0.01, 0.03, 0.05, 0.10)
KELLY_FRACTION <- 0.25
STARTING_BANKROLL <- 10000
MAX_BET_FRACTION <- 0.05
MIN_ODDS <- 1.10
BACKTEST_N_SIMS <- 1000
```

---

## Current Status

**Phase**: Estimation / Validation

**Current performance (H1 2024, real data only):**
- Accuracy: 58.9%
- Brier Score: 0.2336
- ROI at 5% edge: -5.1%
- Market baseline: 67.2%

**Next priorities:**
1. Name matching improvement (many players fail lookup due to format mismatch)
2. Revisit additive adjustment formula (may be too severe)
3. Cross-language replication (Python) for Referee 2 audit

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
code/replication/
├── referee2_replicate_mc_engine.py
├── referee2_replicate_mc_engine.do
└── ...
```

**Current Status:** Accepted with Minor Revisions (Round 2 complete)

**Critical Rule:** Referee 2 NEVER modifies author code. It only reads, runs, and creates its own replication scripts in `code/replication/`. Only the author (you) modifies your own code in response to referee concerns.

---

## Known Issues / Technical Debt

1. **Hardcoded tour averages** in `01_mc_engine.R` lines 45, 68: `avg_return_vs_first <- 0.35`, `avg_return_vs_second <- 0.50`. Should be calculated dynamically.

2. **Name matching ~90%** - Edge cases not handled: multi-initial names ("Kwon S.W."), hyphenated names ("Auger-Aliassime F."), apostrophes ("O'Connell C.").

3. **Calibration analysis misleading** - Always shows 100% actual win rate because we simulate winner vs loser. Should simulate both directions.

4. **Second serve always assumed in** - Small % of missed second serves that aren't double faults are ignored.

5. **No tiebreak-specific stats** - Uses same stats as regular games.

---

## Notes for Claude

- The main R scripts are in `r_analysis/simulator/`, NOT in `src/` (Python scaffolding only)
- Session notes are in `docs/notes/session_notes.md` - update after significant work
- Code changes go in `docs/notes/changelog.md`
- When running backtests, use `require_player_data = TRUE` to filter out tour average matches
- Tour average fallback is the enemy of accurate predictions - avoid matches that use it
