# Deep Dive: Elo vs Market Disagreements

**Date:** 2026-02-10
**Data:** H1 2024, 1,499 matches with clean (no-leakage) Elo predictions

## Executive Summary

When Elo and market agree (79% of matches), both achieve 68% accuracy. When they disagree (21%), **Elo is wrong 65% of the time**. The market consistently has information that Elo lacks, particularly about **player trajectories** - rising vs declining players.

**Key finding:** When Elo picks against strong market favorites (<1.40 odds), it is wrong 84% of the time with an average probability disagreement of **35 percentage points**.

---

## Finding 1: Agreement vs Disagreement

| Scenario | N | Elo Accuracy | Market Accuracy |
|----------|---|--------------|-----------------|
| **Agree** | 1,182 | 68.1% | 68.1% |
| **Disagree** | 317 | 34.7% | 65.3% |

When they agree, they're both right about 2/3 of the time. When they disagree, bet the market.

---

## Finding 2: Strong Favorites - The Magnitude of Error

When Elo picks against market favorites:

| Market Favorite Odds | N | Elo Accuracy | Market Accuracy | Avg Gap |
|---------------------|---|--------------|-----------------|---------|
| Heavy (<1.20) | 6 | 16.7% | 83.3% | 50pp |
| Strong (1.20-1.40) | 38 | 15.8% | 84.2% | 33pp |
| Moderate (1.40-1.60) | 80 | 32.5% | 67.5% | — |
| Slight (1.60+) | 193 | 39.9% | 60.1% | — |

**Extreme case:** Shelton vs Nishikori at French Open
- Market: 85% Shelton (odds 1.17)
- Elo: 23% Shelton
- **Gap: 62 percentage points**
- Result: Shelton won

---

## Finding 3: Career Trajectories Explain Everything

### Players Elo UNDERRATES (Rising)

| Player | 2022 | 2023 | 2024 | Trajectory |
|--------|------|------|------|------------|
| Etcheverry | 18% | 52% | 52% | +26pp |
| Struff | 24% | 54% | 59% | +16pp |
| Shelton | 50% | 51% | 62% | +6pp |

These players improved significantly, but Elo still reflects their weaker historical performance.

### Players Elo OVERRATES (Declining)

| Player | 2022 | 2023 | 2024 | Trajectory |
|--------|------|------|------|------------|
| Mannarino | 51% | 64% | 33% | Collapse |
| Cachin | 45% | 42% | 12% | -21pp |
| Nishikori | 59%* | 67%* | 44% | Injury return |

*Limited matches

**Mannarino:** Had a great 2023 (64%), building up high Elo, then collapsed to 33% in 2024. The market saw this in real-time; Elo still reflected 2023 form.

---

## Finding 4: The Specific Matches

### Top 10 Worst Elo Errors (vs Strong Favorites)

| Date | Market Fav | Mkt Prob | Elo Prob | Gap | Winner |
|------|-----------|----------|----------|-----|--------|
| 2024-05-30 | Ben Shelton | 85% | 23% | 62pp | Shelton |
| 2024-06-11 | Struff | 85% | 30% | 54pp | Struff |
| 2024-06-19 | Struff | 83% | 30% | 53pp | Struff |
| 2024-05-28 | Navone | 84% | 38% | 46pp | Navone |
| 2024-06-17 | Dimitrov | 83% | 37% | 45pp | Dimitrov |
| 2024-04-13 | Sinner | 78% | 33% | 44pp | Tsitsipas* |
| 2024-05-27 | Zverev | 76% | 34% | 42pp | Zverev |
| 2024-01-16 | Michelsen | 84% | 42% | 42pp | Michelsen |
| 2024-05-27 | Auger-Aliassime | 83% | 42% | 42pp | FAA |
| 2024-05-20 | Etcheverry | 91% | 50% | 41pp | Etcheverry |

*One of 7 cases where Elo was correct

### The 7 Times Elo Was Right Against Strong Favorites

| Date | Elo Pick | vs Market Fav | Market Odds |
|------|----------|---------------|-------------|
| 2024-05-27 | Kwon S.W. | Emil Ruusuvuori | 1.16 |
| 2024-02-08 | Zhang Zh. | Auger-Aliassime | 1.27 |
| 2024-04-13 | Tsitsipas | Jannik Sinner | 1.29 |
| 2024-06-18 | Arnaldi | Ugo Humbert | 1.35 |
| 2024-02-27 | Cobolli | Auger-Aliassime | 1.37 |
| 2024-05-25 | Mpetshi | Etcheverry | 1.38 |
| 2024-02-09 | Coria | Etcheverry | 1.39 |

Only 7/44 (16%) when contradicting strong favorites.

---

## Root Cause Analysis

### It's Not About Recency Weighting - It's About Lag

Elo DOES update with each match. The problem is **inertia from accumulated rating capital**.

Example: Kei Nishikori
- Former world #4 (peak 2014-2016)
- Accumulated thousands of Elo points over career
- Injury-plagued since 2019, minimal matches
- Elo at French Open 2024: Still high from historical greatness
- Reality: 34 years old, coming back from injury, rusty

The market knows Nishikori is a shell of his former self. Elo still sees "former world #4."

### What the Market Knows That Elo Doesn't

1. **Current form trajectory** - Last 30-60 days of results
2. **Physical condition** - Injuries, fitness, age effects
3. **Qualitative assessment** - "He looks slow," "lost his serve speed"
4. **Career stage** - Young players expected to improve, veterans to decline
5. **Tournament motivation** - Who's peaking for Slams vs. phoning in 250s

---

## Quantitative Summary

| Metric | Value |
|--------|-------|
| Total disagreements | 317 (21% of matches) |
| Elo accuracy when disagreeing | 34.7% |
| Market accuracy when disagreeing | 65.3% |
| Strong favorite disagreements (<1.40) | 44 |
| Elo accuracy vs strong favorites | 15.9% |
| Average probability gap | 34.8pp |
| Maximum probability gap | 62pp (Shelton vs Nishikori) |

---

## Implications for Model Design

1. **Never bet Elo against strong favorites** - 84% loss rate at <1.40 odds
2. **Elo + Market agreement is the strongest signal** - 68% accuracy
3. **Elo disagreements are anti-signals** - Consider betting the market when Elo disagrees

### Potential Fixes (Not Yet Tested)

1. **Higher K-factor** - Make ratings more volatile (K=48 or K=64 instead of K=32)
2. **Time-decay** - Older matches count less (e.g., matches >2 years weighted 50%)
3. **Form adjustment** - Multiply Elo probability by recent form factor
4. **Refuse strong disagreements** - If Elo prob <30% for <1.40 favorite, defer to market
5. **Hybrid model** - Use market odds as prior, Elo as adjustment

---

## Files Created

- `r_analysis/analysis/elo_market_disagreement_deep_dive.R` - Disagreement analysis
- `r_analysis/analysis/player_trajectory_analysis.R` - Career trajectory analysis
- `data/processed/elo_market_disagreements.rds` - Disagreement data for further analysis
