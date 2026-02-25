# Matchup & Fatigue Feature Analysis

**Date:** 2026-02-14
**Dataset:** 8,411 matches (2021-2024)
**Baseline ROI:** Market favorite -3.18%, Elo -4.03%

---

## Summary

This analysis tested whether handedness matchups, height differentials, and fatigue/scheduling factors reveal betting edges when combined with Elo predictions. The key finding is that **height differential in R vs R matchups** is the only consistent positive signal.

---

## 1. Handedness Matchup Analysis

### Overall by Matchup Type

| Matchup Type | N | Elo Accuracy | Elo ROI |
|--------------|---|--------------|---------|
| L vs L | 151 | 61.6% | +0.36% |
| L vs R | 2,033 | 59.5% | -6.72% |
| R vs R | 6,227 | 62.0% | -3.25% |

### L vs R Breakdown

| Condition | N | Elo Accuracy | Elo ROI |
|-----------|---|--------------|---------|
| Lefty is market favorite | 909 | 56.9% | -9.50% |
| Righty is market favorite | 1,124 | 61.6% | -4.47% |

### L vs R by Year

| Year | N | ROI |
|------|---|-----|
| 2021 | 457 | -9.11% |
| 2022 | 527 | -6.49% |
| 2023 | 516 | -3.46% |
| 2024 | 533 | -8.04% |

**Insight:** Elo consistently underperforms in L vs R matchups, especially when the lefty is favored. This suggests Elo may not properly capture the strategic advantage lefties have (opponents see fewer left-handed players, so have less experience).

---

## 2. Height Differential Analysis

### Overall

| Height Bucket | N | Elo Accuracy | Elo ROI |
|---------------|---|--------------|---------|
| Winner taller (>3cm) | 3,223 | 68.3% | **+1.18%** |
| Similar height (±3cm) | 2,608 | 61.8% | -2.59% |
| Winner shorter (>3cm) | 2,569 | 52.3% | -12.05% |

### Height by Handedness Matchup

| Matchup | Height | N | Accuracy | ROI |
|---------|--------|---|----------|-----|
| L vs L | Winner taller | 55 | 65.5% | +2.67% |
| L vs L | Similar height | 39 | 79.5% | +27.51%* |
| L vs L | Winner shorter | 57 | 45.6% | -20.46% |
| **L vs R** | Winner taller | 778 | 66.5% | **-0.71%** |
| L vs R | Similar height | 639 | 57.9% | -9.41% |
| L vs R | Winner shorter | 615 | 52.4% | -11.38% |
| **R vs R** | Winner taller | 2,390 | 68.9% | **+1.75%** |
| R vs R | Similar height | 1,930 | 62.8% | -0.94% |
| R vs R | Winner shorter | 1,897 | 52.5% | -12.02% |

*Small sample (39 matches)

### R vs R Winner Taller by Year

| Year | N | ROI |
|------|---|-----|
| 2021 | 616 | **+3.74%** |
| 2022 | 603 | **+2.15%** |
| 2023 | 602 | -3.84% |
| 2024 | 569 | **+5.10%** |

**3 of 4 years positive**

### L vs R - Is the Lefty Taller?

| Condition | N | Accuracy | ROI |
|-----------|---|----------|-----|
| Lefty shorter | 858 | 61.7% | -3.52% |
| Lefty taller | 535 | 57.9% | -8.46% |
| Similar height | 639 | 57.9% | -9.41% |

**Insight:** The height edge **only works in R vs R matchups** (+1.75% ROI, 3/4 years positive). In L vs R matchups, height provides no edge - even when the winner is taller, ROI is negative. When a lefty is taller, Elo actually performs worse (-8.46%), suggesting the market may overvalue tall lefties.

---

## 3. Fatigue/Scheduling Analysis

### By Winner's Days Since Last Match

| Rest Period | N | Elo Accuracy | Elo ROI |
|-------------|---|--------------|---------|
| 0-2 days (back-to-back) | 3,344 | 59.3% | -8.15% |
| 3-7 days (same week) | 1,786 | 63.6% | -3.69% |
| **8-14 days (week off)** | 1,359 | **66.9%** | **+0.30%** |
| 15+ days (extended rest) | 1,847 | 59.2% | -0.33% |

### By Favorite's Rest Advantage

| Condition | N | Elo Accuracy | Elo ROI |
|-----------|---|--------------|---------|
| Favorite NOT more rested | 5,544 | 61.6% | -3.02% |
| Favorite IS more rested | 2,792 | 61.1% | -6.20% |

### By Winner's Match Load (Last 30 Days)

| Load | N | Elo Accuracy | Elo ROI |
|------|---|--------------|---------|
| 0 matches (fresh) | 847 | 55.3% | -0.37% |
| 1-3 matches | 3,344 | 58.5% | -4.09% |
| 4-6 matches | 2,763 | 63.6% | -4.83% |
| 7+ matches (heavy load) | 1,382 | **68.0%** | -4.87% |

**Insight:** Counterintuitively, when the favorite has a rest advantage, ROI is *worse* (-6.20% vs -3.02%). The market already prices in fatigue factors. Heavy match load correlates with high accuracy (68%) but the odds reflect this, resulting in negative ROI.

---

## 4. Combined Feature Analysis

### Winner Taller + Well-Rested (8-14 days)

| Condition | N | Elo Accuracy | Elo ROI |
|-----------|---|--------------|---------|
| Neither favorable | 4,350 | 55.9% | -8.78% |
| **Taller only** | 2,656 | **67.7%** | **+1.24%** |
| Rested only | 808 | 63.9% | -0.06% |
| Both favorable | 555 | 71.4% | +0.85% |

### "Both Favorable" by Year

| Year | N | ROI |
|------|---|-----|
| 2021 | 113 | +11.07% |
| 2022 | 124 | +10.82% |
| 2023 | 142 | -16.26% |
| 2024 | 176 | +1.06% |

**High variance - not reliable**

---

## Key Findings

1. **Height in R vs R is the most consistent signal**
   - +1.75% ROI across 2,390 matches
   - 3 of 4 years positive (2021, 2022, 2024)
   - Does NOT work in L vs R matchups

2. **L vs R matchups are problematic for Elo**
   - Consistent -6.72% ROI across all years
   - Lefty favorites perform worst (-9.50% ROI)
   - Height provides no edge in these matchups

3. **Fatigue factors are already priced in**
   - Rest advantage for favorite = worse ROI
   - Heavy match load = high accuracy but negative ROI
   - Market efficiently incorporates scheduling information

4. **Combined features show high variance**
   - "Both favorable" swings from +11% to -16% by year
   - Single-factor edges are more stable

---

## Recommendations

### Actionable Strategies

1. **R vs R + Elo picks taller player (>3cm)**
   - Expected ROI: ~+1.75%
   - Sample: ~600 bets/year
   - Consistency: 3/4 years positive
   - Implementation: Filter Elo bets to R vs R where Elo pick is 3+ cm taller

2. **Avoid L vs R matchups entirely**
   - Consistent negative ROI regardless of other factors
   - Consider excluding from betting universe

3. **Do not use fatigue as a betting filter**
   - Market prices this information efficiently
   - No edge from rest/scheduling factors

### Further Investigation

1. **Why does Elo underperform on lefties?**
   - Consider handedness-adjusted Elo
   - Test if lefties have systematically different Elo trajectories

2. **Height as proxy for playing style**
   - Taller players tend to be serve-dominant
   - Could integrate serve stats more directly

3. **Combine with heavy favorites edge**
   - From systematic search: <1.20 odds shows +2.0% ROI
   - Test: Heavy favorite + R vs R + taller

---

## Technical Notes

- Analysis script: `r_analysis/analysis/matchup_fatigue_features.R`
- Output data: `data/processed/matchup_fatigue_predictions.rds`
- Bug fixed: Date comparison in fatigue calculation (was comparing column to itself)
- Handedness data coverage: 996 players (12.9% lefties)
- Height data coverage: 99.9% of matches
- Fatigue data coverage: 99.1% of matches
