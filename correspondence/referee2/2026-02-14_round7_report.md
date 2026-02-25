=================================================================
                        REFEREE REPORT
              Tennis Match Simulator — Round 7
              Date: 2026-02-14
=================================================================

## Summary

This Round 7 report evaluates the full arc of model development and edge hunting since the data leakage fix in Round 5. The author has completed an impressive volume of analysis: K-factor sensitivity, calibration, disagreement analysis, dual Elo, WElo, H2H hybrid, systematic edge search, matchup/fatigue features, clay Masters multi-year validation, and out-of-sample H2 2024 testing. The data integrity foundation is now solid and the diagnostic work is honest. However, the edge-hunting strategy exhibits a critical methodological pattern that must be addressed: **the search is broad but shallow, testing many dimensions without exhausting any single one**. More importantly, several high-value directions suggested by the academic literature remain completely unexplored, while the analysis has drifted toward post-hoc subsetting — the statistical equivalent of torturing the data until it confesses.

**Overall Assessment:** The project is at its most critical juncture. The infrastructure is sound, the diagnostics are honest, and several genuine signals have emerged (height in R vs R, "agree but less confident" subset, calibration curve shape). But the path from here requires a fundamental shift in methodology: from "scan many dimensions for positive ROI" to "identify a structural market inefficiency from theory, then test whether the data support it." The literature review provides multiple untapped blueprints for this approach.

---

## Audit 1: Code & Analysis Audit

### What Was Completed Since Round 6

| Script | Purpose | Status |
|--------|---------|--------|
| `k_factor_sensitivity.R` | K ∈ {24, 32, 48, 64} sensitivity | Complete |
| `find_betting_edge_subsets.R` | Systematic betting edge search | Complete |
| `find_elo_edge_subsets.R` | Elo accuracy subsets | Complete |
| `edge_hunting.R` | Structural pattern search | Complete |
| `edge_hunting_deep.R` | Player characteristics, clay Masters | Complete |
| `edge_hunting_creative.R` | First-round effects, scheduling | Complete |
| `matchup_fatigue_features.R` | Handedness, height, fatigue | Complete |
| `hybrid_elo_recency.R` | Dual long-term/short-term Elo | Complete |
| `hybrid_welo_ensemble.R` | Tournament-weighted Elo + serve stats | Complete |
| `hybrid_elo_h2h.R` | Head-to-head adjustment | Complete |
| `systematic_edge_search.R` | Multi-year pattern validation | Complete |
| `clay_masters_*.R` (4 scripts) | Clay Masters edge validation | Complete |
| `validate_edge_h2_2024.R` | Out-of-sample validation | Complete |
| `quick_h2_validation.R` | Quick H2 validation | Complete |

**Assessment:** This is a substantial body of work — 17 analysis scripts covering K-factor tuning, model variants, feature engineering, and out-of-sample validation. The author has taken the referee's prior recommendations seriously and addressed the long-standing K-factor concern.

### Finding 1: K-Factor Results Resolve the Outstanding Concern

From `model_analysis.md`:

| K | Accuracy | Brier Score |
|---|----------|-------------|
| 24 | 63.7% | 0.2162 |
| 32 | 63.8% | 0.2164 |
| 48 | 63.8% | 0.2179 |
| 64 | 64.2% | 0.2203 |

**Assessment:** K=64 gives the highest accuracy (+0.4pp) but worse calibration (+0.004 Brier). The author's conclusion is correct: K-factor adjustment alone doesn't solve the trajectory lag problem. The relationship between accuracy and calibration is the key insight here — higher K makes the model more decisive (correct direction more often) but less well-calibrated (worse probability estimates). This is a fundamental tension the author should name explicitly.

### Finding 2: Calibration Table — A Genuine Contribution

| Prediction Range | N | Predicted | Actual | Error |
|-----------------|---|-----------|--------|-------|
| 0-30% (underdogs) | 414 | 20.3% | 26.8% | +6.5pp |
| 40-60% (toss-ups) | 1,252 | 50.1% | 50.1% | ±0.5pp |
| 70-100% (favorites) | 873 | 76.9% | 70.7% | -6.2pp |

**This is one of the most important tables in the entire project.** It says: Elo systematically overestimates the gap between favorites and underdogs. Favorites win less often than Elo predicts; underdogs win more often. The midrange is well-calibrated.

**Why this matters for betting:** This calibration curve has a direct, actionable implication. If Elo says a player has an 80% chance but the true probability is closer to 72%, then the market (at ~67% baseline accuracy) may be *closer to reality* for strong favorites. But for underdogs — if Elo says 25% and reality is 32% — the underdog is worth more than Elo thinks.

**This is a potential edge mechanism the author has not explicitly exploited.** More on this below.

### Finding 3: The "Agree But Less Confident" Signal

From `model_analysis.md`:
- Filter: Elo agrees with market, but Elo is 0-5pp less confident
- N = 256 matches, Win rate = 72.3%, ROI = +6.4%, p = 0.041
- Best sub-segment: Odds 1.7-2.0 → +16.6% ROI (N=49)

**Assessment:** This is the most promising signal in the project. When Elo agrees with the market's pick but assigns a *lower* probability, it suggests the market may be slightly overpricing the favorite. The logic is structurally sound: Elo provides an independent signal that says "yes, this player should win, but the market is too confident." This is a classic contrarian-confirmation pattern.

**However:** p = 0.041 on a single test period (H1 2024) with 256 matches is suggestive but not conclusive. N=49 for the best sub-segment is far too small. The critical question: **does this hold in H2 2024 and across 2021-2023?**

### Finding 4: Height in R vs R Matches

From `matchup_fatigue_analysis.md`:
- R vs R, winner taller by >3cm: +1.75% ROI, 2,390 matches, 3/4 years positive
- Does NOT work in L vs R matchups

**Assessment:** This is an interesting feature but requires careful interpretation. "Winner taller" is an ex-post label — you know the winner after the match. The relevant betting question is: **when Elo picks the taller player in R vs R, what is the ROI?** The analysis as presented uses winner height, not predicted winner height. This distinction matters enormously for a betting strategy. If this hasn't been computed with the Elo pick as the frame (bet on Elo's pick when that player is taller in R vs R), the signal may be weaker or nonexistent.

### Finding 5: Clay Masters — Interesting but Fragile

Multiple scripts devoted to validating a Clay Masters edge. The N per year is ~50 matches, which means year-to-year variance will be enormous. The fact that 4 separate scripts were written for this suggests the author was chasing a signal that kept requiring more validation — often a sign of overfitting to noise.

---

## Audit 2: Methodological Assessment — The Edge-Hunting Strategy

### The Current Approach: Scan → Find → Validate → Repeat

The analysis scripts reveal a pattern:
1. Compute Elo predictions for a large set of matches
2. Slice by every available dimension (surface, tournament level, round, odds range, agreement, confidence, handedness, height, fatigue, scheduling, season, day of week)
3. Find subsets with positive ROI
4. Attempt to validate on other time periods
5. Move on to the next dimension when validation fails

**This is a valid exploratory approach, but it has a critical statistical weakness:** with enough dimensions and subsets, positive ROI will appear by chance. The analysis has tested dozens of subsets. Even at p < 0.05, you'd expect ~5% false positives. Without a multiple testing correction (Bonferroni, Holm, or FDR), the p = 0.041 on the "agree but less confident" subset is not clearly distinguishable from noise.

### What's Missing: Theory-Driven Edge Identification

The literature review (`literature-review-2006-to-present.md`) provides a rich set of structural reasons why a model might systematically beat the market. But the edge-hunting analysis doesn't connect back to these mechanisms. Instead of asking "where does Elo happen to have positive ROI?", the analysis should ask:

**"What does Elo know that the market might underweight, and what does the market know that Elo can't capture?"**

The calibration table answers this partially: Elo overestimates favorites and underestimates underdogs. This is a **structural bias**, not a random pattern. It suggests a specific edge hypothesis:

> **Hypothesis:** The market is efficient on average but inherits some of Elo's overconfidence on favorites (because many bettors use rating-based models). Betting on underdogs where Elo's calibration-corrected probability exceeds the market-implied probability should yield positive ROI.

This is testable, theory-grounded, and doesn't require slicing the data into small subsets.

---

## Audit 3: Untapped Directions from the Literature

The literature review identifies several model upgrades that map directly to exploitable edges. None have been implemented:

### 3.1 Weighted Elo (Angelini et al. 2022) — Partially Implemented

The `hybrid_welo_ensemble.R` script implements tournament-level K-factors (G=48, M=40, A=32, else=24). This is a crude version of WElo. The actual Angelini paper incorporates **scoreline information** into updates — a 6-0, 6-1 win should update Elo more than a 7-6, 7-6 win. This is not implemented.

**Why it matters for edges:** Scoreline-weighted updates would make Elo more responsive to *quality* of wins, not just binary outcomes. A player who has been grinding out tiebreakers is probably weaker than one who has been dominating. This directly addresses the trajectory lag problem.

**The data to implement this is already in the dataset** (`w_sets_won`, `l_sets_won`, and implied from match scores). This is a high-ROI implementation.

### 3.2 Ingram's Bayesian Point-Based Model — Not Attempted

The literature review identifies this as "the most direct modern upgrade of Newton-Keller" and the project's MC engine is literally a Newton-Keller implementation. The key insight: instead of using raw serve/return percentages (which the MC model does), estimate **latent serve and return skills** with surface effects and time evolution.

**Why it matters:** The MC model uses career averages of first-in%, first-won%, second-won%. These are noisy and don't evolve. Ingram's approach would:
- Separate serve skill from return skill (currently lumped)
- Allow skills to evolve over time (currently static)
- Incorporate surface effects at the point level (currently only at Elo level)
- Provide posterior uncertainty (currently point estimates only)

This could substantially improve the MC model's 56% accuracy, which is currently not competitive.

### 3.3 Gorgi, Koopman, Lit (2018) — Dynamic Time-Varying Abilities

A state-space model where player abilities change over time with surface specificity. This is essentially what the "dual Elo" script attempts with long-term/short-term Elo, but done properly with a statistical framework rather than ad-hoc parameter choices.

### 3.4 Platt Scaling / Calibration Correction — Not Attempted

The calibration table shows a systematic, predictable bias. This is the lowest-hanging fruit in the entire project. A simple logistic regression mapping:

```r
calibrated_prob <- plogis(a + b * qlogis(elo_prob))
```

fitted on training data would correct the overconfidence pattern. If `b < 1`, it compresses extreme probabilities toward 50% — exactly what the calibration table suggests is needed.

**This requires approximately 5 lines of R code and could immediately improve every betting signal.**

### 3.5 Point-Context Features — Rally Length, Serve Direction

The MC engine simulates points as iid draws. The literature shows that point-win probability varies substantially by:
- Rally length (Prieto-Lage 2023): Short-rally players have different profiles than grinders
- Serve direction (Tea & Swartz 2022): Players have predictable patterns that opponents exploit

These features wouldn't improve Elo (which is match-level), but could substantially improve the MC model, which is currently the weaker of the two models.

---

## Audit 4: What "Finding a Consistent Edge in One Spot" Actually Requires

The stated goal is not to beat the market everywhere but to find one reliable niche. The analysis has explored many niches. Here is a structured assessment of the most promising ones:

### Tier 1: Structurally Sound, Needs Validation

| Signal | Mechanism | In-Sample | Out-of-Sample | Action Needed |
|--------|-----------|-----------|---------------|---------------|
| Agree + less confident | Market overprices favorites when Elo is skeptical | +6.4% ROI (N=256, p=0.041) | Unknown | Multi-year validation |
| Calibration correction | Elo overestimates favorites → underdog value | Implied by calibration table | Not tested | Implement Platt scaling, test betting strategy |

### Tier 2: Interesting Signal, Statistical Fragility

| Signal | Mechanism | In-Sample | Issue |
|--------|-----------|-----------|-------|
| Height in R vs R | Taller = serve advantage, market underweights | +1.75% ROI (N=2,390) | Uses ex-post winner, not predicted winner |
| Clay Masters | Surface specialists underpriced? | +13.5% ROI (N=53) | N too small, 4 scripts chasing it |
| Heavy favorites (<1.20) | Market too conservative on very heavy favorites | +2.0% ROI | Very low margins, vig kills it |

### Tier 3: Dead Ends (Correctly Identified)

| Signal | Finding | Conclusion |
|--------|---------|------------|
| Fatigue/scheduling | Market prices it efficiently | Correctly abandoned |
| L vs R matchups | Consistent negative ROI | Elo can't capture handedness edge |
| Elo disagreements | Anti-informative (34.7%) | Never bet against market favorites |
| Combined features | High variance across years | Not reliable |

### Recommendation: Pursue Tier 1 Signals with Rigor

The "agree but less confident" signal has the strongest theoretical grounding:
1. It's a contrarian-confirmation pattern (well-established in financial literature)
2. It has a plausible mechanism (market inherits model overconfidence on favorites)
3. It had positive ROI in H1 2024 (albeit marginal significance)
4. It connects directly to the calibration finding

The **single most important next step** is:
1. Implement Platt scaling on the calibration curve
2. Recalculate the "agree but less confident" signal using calibrated probabilities
3. Test across 2021-2024 H1 periods (4 independent tests)
4. Apply Holm-Bonferroni correction across all subset tests
5. If the signal survives: define a clean, prospective betting rule and paper-trade H2 2024

---

## Audit 5: Statistical Rigor

### 5.1 Multiple Testing Problem — Not Addressed

The project has tested at minimum the following subsets for positive ROI:
- 4 K-factor values
- 4+ edge thresholds
- Agreement/disagreement split
- 5+ confidence buckets
- 4 tournament levels
- 3 surfaces
- 3 round stages
- 4+ odds ranges
- 3 handedness matchups
- 3 height differentials
- 4 rest period buckets
- Match load buckets
- Combined features
- Clay Masters specifically
- Multiple sub-segments within each

Conservative estimate: **50+ subset tests**. At α = 0.05, you'd expect ~2.5 false positives. The reported p = 0.041 for the best signal does not survive even Bonferroni correction (adjusted threshold: 0.05/50 = 0.001).

**This does not mean the signal is false.** It means the statistical evidence from a single period is insufficient to distinguish it from chance. Multi-year validation is the correct response, not tighter p-values from the same data.

### 5.2 Formal Model Comparison — Now Available

From `model_analysis.md`:
- McNemar test: Market significantly better than Elo (p < 0.001)
- Binomial test: Elo disagreement accuracy = 34.7% ≠ 50% (p < 0.001)
- Betting edge in positive subset: p = 0.041

These are good. Add:
- DeLong test for AUC comparison (Elo vs market as probability forecasters)
- Brier skill score relative to market baseline (not just absolute Brier)
- Calibration test (Hosmer-Lemeshow or reliability diagram with confidence bands)

### 5.3 Out-of-Sample Discipline

The `validate_edge_h2_2024.R` and `quick_h2_validation.R` scripts show good awareness of the need for out-of-sample testing. But the results from these scripts are not reported in `model_analysis.md`. **What happened?** If the signals didn't hold out-of-sample, that's an important finding that should be documented. If they did hold, it should be prominently reported.

---

## Major Concerns

None. The project has no major methodological flaws remaining. The data integrity is sound, the analysis is honest, and the limitations are acknowledged.

---

## Minor Concerns

1. **Multiple testing correction absent.** The 50+ subset tests require formal correction. The "agree but less confident" p = 0.041 should be presented alongside the number of tests conducted so the reader can assess significance properly.

2. **Platt scaling not implemented.** The calibration table is the strongest signal in the project and the simplest to exploit. Implementing `calibrated_prob = plogis(a + b * qlogis(elo_prob))` with cross-validated parameters would immediately improve all downstream betting signals.

3. **Out-of-sample results not documented.** The H2 2024 validation scripts exist but results aren't in `model_analysis.md`. These are crucial for assessing whether any signal is genuine.

4. **Height analysis uses ex-post winner.** The "winner taller by >3cm = +1.75% ROI" is computed relative to who actually won, not who Elo predicted would win. The relevant betting question is different and should be computed separately.

5. **MC model abandoned too early.** The MC model at 56% accuracy is substantially below Elo (60.8%) and market (67.2%). But the literature review identifies specific upgrades (Ingram's Bayesian approach, serve/return skill decomposition) that could close this gap. The MC engine is architecturally sound — it's the parameter estimation that's weak.

6. **WElo implementation is incomplete.** Scoreline-weighted updates (the core Angelini insight) are not implemented — only tournament-level K-factors, which is a coarser version of the same idea.

7. **Dual Elo (recency) results not reported.** `hybrid_elo_recency.R` implements a promising long-term/short-term Elo blend, but its results aren't documented in `model_analysis.md`.

8. **No prospective betting simulation.** The project has backtested many strategies but never defined a single clean rule and paper-traded it forward. A proper out-of-sample test would freeze the strategy (with all parameters) at the end of H1 2024 and simulate paper trading through H2 2024 without any retrospective adjustment.

---

## Questions for Authors

1. **What were the out-of-sample results?** The H2 2024 validation scripts exist but results aren't in the documentation. Did the "agree but less confident" signal hold? Did the clay Masters signal hold? Reporting negative results is as important as positive ones.

2. **Has Platt scaling been considered?** The calibration table directly implies a simple correction. Has this been tested? If not, why not?

3. **Is the goal still a betting edge, or has it shifted to model comparison?** The project now has two clear contributions: (a) honest documentation of what Elo can and can't do in tennis, and (b) the calibration/disagreement analysis. If the goal is still a betting edge, the calibration correction + "agree but less confident" pathway is the most promising. If the goal is academic contribution, the current diagnostics are already valuable.

4. **Why hasn't the MC model been improved using the literature's recommendations?** The literature review explicitly recommends Ingram-style Bayesian serve/return estimation. The MC engine is already built to accept serve/return parameters. The missing piece is better parameter estimation, not a better simulation engine.

---

## Verdict

[X] Accept with Minor Revisions

**Justification:** The project has reached a mature state. The data integrity is solid. The diagnostic analysis is honest and thorough. The edge-hunting work is extensive, and the author correctly identifies which signals are fragile. The remaining concerns are about completing the analysis (documenting out-of-sample results, implementing calibration correction, applying multiple testing corrections) rather than about fixing fundamental flaws.

The project would benefit most from depth over breadth at this stage: pick the single most promising signal ("agree but less confident" + calibration correction), implement it rigorously with proper statistical framework, and test it prospectively.

---

## Recommendations (Prioritized)

1. **Implement Platt scaling.** Fit `calibrated_prob = plogis(a + b * qlogis(elo_prob))` using cross-validated parameters on 2021-2023 data. Report calibration improvement on H1 2024.

2. **Document all out-of-sample results.** Report the H2 2024 validation findings in `model_analysis.md`, whether positive or negative.

3. **Multi-year validation of "agree but less confident."** Test the signal across H1 2021, 2022, 2023, 2024. Report whether the +6.4% ROI is consistent or driven by one period.

4. **Apply multiple testing correction.** Report the number of subset tests conducted alongside any p-values. Consider Holm-Bonferroni or FDR correction.

5. **Implement scoreline-weighted Elo.** Modify the update function to weight by margin of victory (sets won, or use game scores if available). This directly addresses trajectory lag and is well-supported by Angelini et al.

6. **Define a prospective betting rule.** Freeze all parameters at end of H1 2024. Paper-trade H2 2024 with zero adjustments. Report the result as the definitive edge test.

7. **Consider Ingram-style upgrade for MC model.** The MC engine is sound but the parameter inputs are weak. Bayesian estimation of latent serve/return skills with time evolution would be the highest-impact improvement to the MC model specifically.

=================================================================
                      END OF REFEREE REPORT
=================================================================
