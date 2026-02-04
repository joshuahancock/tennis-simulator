# Tennis Simulator Model Analysis

## Current Model: How It Works

### The Core Probability: P(Server Wins Point)

The entire model rests on estimating **one probability**: the chance the server wins a point. Here's the exact formula from `simulate_point()`:

```
P(server wins point) =
    P(1st serve in) × P(win | 1st in) +
    P(1st serve out) × [P(double fault) × 0 + P(2nd in) × P(win | 2nd in)]
```

Which simplifies to:
```
P(server wins) ≈ first_in% × first_won% + (1 - first_in%) × second_won%
```

### Where the Numbers Come From

| Statistic | Source | Problem |
|-----------|--------|---------|
| `first_in_pct` | Player's historical 1st serve % | Averaged across all opponents |
| `first_won_pct` | Player's historical 1st serve points won % | Averaged across all opponents |
| `second_won_pct` | Player's historical 2nd serve points won % | Averaged across all opponents |
| `return_vs_first` | Player's return points won vs 1st serve | Used to adjust opponent's serve |
| `return_vs_second` | Player's return points won vs 2nd serve | Used to adjust opponent's serve |

### The Adjustment Formula

When the server faces a returner, we adjust like this (from `01_mc_engine.R` lines 32-38):

```r
avg_return_vs_first <- 0.35  # Hardcoded tour average
adjustment <- avg_return_vs_first - returner_stats$return_vs_first
win_prob <- server_stats$first_won_pct + adjustment
```

**Example:**
- Server's `first_won_pct` = 75%
- Returner's `return_vs_first` = 40% (good returner)
- Tour average = 35%
- Adjustment = 35% - 40% = -5%
- Adjusted win prob = 75% - 5% = 70%

---

## Backtest Results (H1 2024, No Data Leakage)

### Accuracy Comparison

| Method | Accuracy |
|--------|----------|
| Market Favorite | **67.2%** |
| Monte Carlo Model | 58.1% |
| Random Coin Flip | 50.0% |

The model is **9.1 percentage points worse** than just picking the market favorite.

### When Model Disagrees with Market

| Scenario | Matches | Model Accuracy | Market Accuracy |
|----------|---------|----------------|-----------------|
| Model agrees with market | 1,072 (71.5%) | 67.7% | 67.7% |
| Model picks underdog | 427 (28.5%) | **34.0%** | **66.0%** |

When the model disagrees and picks an underdog, it's right only 34% of the time.

### ROI by Edge Threshold

| Edge Threshold | ROI |
|----------------|-----|
| 1% | -8.7% |
| 3% | -10.6% |
| 5% | -12.7% |
| 10% | **-14.4%** |

Higher confidence = worse performance. The model's "edge" is anti-correlated with real edge.

---

## The Fundamental Problems

### 1. Double-Counting / Circular Logic

The server's `first_won_pct` of 75% was calculated against a mix of opponents. Some were good returners, some were bad. **The opposition quality is already baked into the stat.**

When we then adjust for the specific opponent's return ability, we're partially double-counting. If the server always played weak returners, their 75% is inflated, and our adjustment doesn't fully account for this.

### 2. Hardcoded Tour Averages

```r
avg_return_vs_first <- 0.35  # Hardcoded
avg_return_vs_second <- 0.50  # Hardcoded
```

These are fixed constants, but tour averages vary by:
- Surface (return is easier on clay)
- Era (return has improved over time)
- Level (Slams vs. 250s have different player quality)

### 3. No Matchup-Specific Information

The model treats every matchup the same way:
- Big server vs. big server? Same formula.
- Big server vs. elite returner? Same formula.
- Grinder vs. grinder? Same formula.

The only differentiation is through the simple adjustment, which doesn't capture:
- Playing styles
- Head-to-head history
- Surface-specific matchup dynamics

### 4. Stats Are Too Stable / Historical

We use career (or multi-year) averages. But:
- Current form matters more than 3-year averages
- Injury recovery, aging, confidence swings aren't captured
- The market prices in recent form; we don't

---

## Potential Improvements

### Option A: Simpler Model (Remove the Noise)

**Hypothesis:** Our adjustment formula is adding noise, not signal.

**Solution:** Use raw serve/return percentages without the adjustment, or use a simpler combination:

```r
# Instead of complex adjustment, just use:
p_server_wins_point <- server_overall_serve_pct

# Or combine directly:
p_server_wins_point <- (server_serve_pct + (1 - returner_return_pct)) / 2
```

### Option B: Use Market-Implied Probabilities as Anchor

**Hypothesis:** The market is already efficient for the "base case."

**Solution:** Only predict when we have specific information the market doesn't:
- Head-to-head history
- Recent form (last 2-4 weeks)
- Known injuries/fatigue
- Surface-specialist vs. non-specialist

### Option C: Fix the Adjustment Formula

**Hypothesis:** The adjustment formula is wrong, not the idea.

**Solution:** Use opponent-adjusted statistics:
- Calculate each player's serve% against opponents of different return quality
- Use regression to separate "true skill" from "opponent quality"
- This is more complex but statistically correct

### Option D: Bradley-Terry or Elo Model

**Hypothesis:** Point-by-point simulation is overkill.

**Solution:** Use a simpler model:
```r
# Bradley-Terry:
P(A beats B) = rating_A / (rating_A + rating_B)

# Elo:
P(A beats B) = 1 / (1 + 10^((elo_B - elo_A) / 400))
```

These models are simpler, well-understood, and often perform as well as complex models.

---

## Recommendation

Start with **Option A** (simplify) to establish a better baseline, then try **Option D** (Elo/Bradley-Terry) as a comparison.

The point-by-point simulation is elegant but may be adding complexity without adding accuracy. A simple Elo model with surface adjustments might perform better.

---

## Key Insight

The model's problem isn't that it's "random" - it's that **when it deviates from the market consensus, it's systematically wrong**. This suggests the serve/return adjustment formula is introducing bias, not correcting for it.

A model that simply agreed with the market favorite would achieve 67.2% accuracy. Our model achieves 58.1% by sometimes overriding that consensus with bad underdog picks.
