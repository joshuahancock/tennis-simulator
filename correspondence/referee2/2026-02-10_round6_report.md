=================================================================
                        REFEREE REPORT
              Tennis Match Simulator — Round 6
              Date: 2026-02-10
=================================================================

## Summary

This Round 6 report evaluates two areas: (1) whether the critical data leakage identified in Round 5 has been fixed, and (2) the quality of the author's subsequent analysis of Elo model underperformance. The leakage fix is confirmed correct — the date alignment module properly resolves the `tourney_date` mismatch, and the backtest pipeline now filters historical matches by actual match dates. The Elo underperformance analysis is honest and diagnostically sound, correctly identifying career trajectory lag as the root cause of systematic misprediction. However, the analysis stops at diagnosis — none of the proposed remedies have been tested, and several previously flagged concerns (calibration reporting, K-factor sensitivity, formal model comparison tests) remain unaddressed.

**Overall Assessment:** The project has moved from a state of invalid results (Round 5) to a state of valid-but-limited results. The data integrity issue is resolved. The modeling question is now correctly framed: Elo outperforms MC by 4.8pp but underperforms the market by 6.4pp, and the analysis explains why. What's missing is the next step — testing whether any of the identified fixes close the gap.

---

## Audit Focus 1: Data Leakage Fix — CONFIRMED

### The Fix Is Correct

The date alignment module (`08_date_alignment.R`) properly resolves the `tourney_date` mismatch through a well-designed multi-strategy approach:

| Strategy | Method | Coverage |
|----------|--------|----------|
| Exact | ATP name → betting format, match on normalized names + tournament | 71.6% |
| Variant | Hyphenated/compound name variants (Auger-Aliassime, Mpetshi Perricard, etc.) | 18.0% |
| Inferred | Round-based day offset from tournament start date | 10.4% |
| **Total** | | **100%** |

### Why It Works

The backtest pipeline (`06_backtest.R:297-304`) now correctly uses `actual_match_date` for filtering:

```r
date_col <- if ("actual_match_date" %in% names(historical_matches))
  "actual_match_date" else "match_date"
prior_matches <- historical_matches %>%
  filter(.data[[date_col]] < cutoff_date)
```

Where `cutoff_date` comes from the betting data's actual match date. This means:
- A QF on January 3 now correctly excludes SF (Jan 3) and F (Jan 4) results
- The filter operates on actual calendar dates, not tournament start dates
- The leakage mechanism identified in Round 5 is eliminated

### Remaining Risk: Inferred Dates (10.4%)

The 10.4% of matches with inferred dates use `get_round_day_offset()`, which maps rounds to approximate day offsets by draw size. This is a reasonable heuristic, but introduces ±1-2 day imprecision. Importantly, these are primarily:

- United Cup matches (team competition, not in betting data)
- Davis Cup ties (not in betting data)
- Players not found in betting dataset (e.g., Christopher O'Connell)

Since these matches are not being predicted (they're only used as Elo training data), the imprecision has a minor effect on the Elo ratings of players who participated in these events. **This is an acceptable residual risk**, not a leakage concern.

### Defensive Measures Verified

1. **Cache-first loading** (`06_backtest.R:228-231`): Loads pre-aligned matches from `data/processed/atp_matches_aligned.rds` for speed and consistency.
2. **Runtime fallback** (`06_backtest.R:232-238`): If cache doesn't exist, runs alignment at runtime.
3. **Warning on no alignment** (`06_backtest.R:240-241`): Explicitly warns if neither cache nor runtime alignment is available.
4. **Validation function** (`validate_date_alignment()`): Checks for impossible dates and incorrect round ordering within tournaments.
5. **8 unit tests** covering name conversion, variants, normalization, and round offsets.

### Verdict on Leakage

**FIXED.** The data leakage is eliminated. The corrected results (Elo: 60.8%, MC: 56.0%) are trustworthy. The 7.8pp Elo inflation and 2.7pp MC inflation confirm the referee's Round 5 prediction that Elo would be disproportionately affected.

---

## Audit Focus 2: Elo Underperformance Analysis

### What Was Analyzed

The author produced two analysis scripts and two documentation files:

| File | Purpose |
|------|---------|
| `r_analysis/analysis/elo_market_disagreement_deep_dive.R` | Systematic comparison of Elo vs market predictions |
| `r_analysis/analysis/player_trajectory_analysis.R` | Career trajectory analysis for under/overrated players |
| `docs/notes/elo_market_disagreement_analysis.md` | Summary of disagreement findings |
| `docs/notes/model_analysis.md` | Broader model analysis (MC and Elo) |

### Finding 1: Agreement/Disagreement Split — Well Documented

| Scenario | N | Elo Accuracy | Market Accuracy |
|----------|---|--------------|-----------------|
| Agree (79%) | 1,182 | 68.1% | 68.1% |
| Disagree (21%) | 317 | 34.7% | 65.3% |

**Assessment:** This is a clean, well-structured finding. When the two signals agree, they're jointly informative (~68%). When they disagree, the market is right nearly twice as often. The disagreement accuracy of 34.7% is substantially below 50%, meaning Elo isn't just uninformative when it disagrees — it's actively anti-informative.

### Finding 2: Strong Favorite Analysis — Devastating but Honest

When Elo picks against strong market favorites (odds < 1.40):
- **N = 44 matches**
- **Elo correct: 7/44 (15.9%)**
- **Average probability gap: 34.8 percentage points**
- **Maximum gap: 62pp (Shelton vs Nishikori)**

**Assessment:** This is the strongest evidence in the analysis. An 84% loss rate against strong favorites means Elo's disagreements in this range are nearly pure noise. The specific match examples (with dates, odds, and outcomes) add credibility.

### Finding 3: Career Trajectory Diagnosis — Correct Root Cause

The analysis correctly identifies the mechanism:

1. **Rising players underrated**: Etcheverry (+26pp over 2 years), Struff (+16pp), Shelton (+6pp) — Elo hasn't caught up to their improvement
2. **Declining players overrated**: Mannarino (64% → 33%), Nishikori (former #4, now 34 and injury-prone) — Elo still reflects historical strength
3. **Accumulated rating capital**: The problem isn't that Elo doesn't update — it does (K=32). The problem is that hundreds of prior matches create inertia that a few recent results can't overcome.

**Assessment:** This is a correct diagnosis. It also explains why K=32 might be too low for tennis — a player can accumulate years of rating capital that takes many matches to reverse, while the market adjusts in real-time based on qualitative information (fitness, form, motivation).

### Finding 4: The Shelton vs Nishikori Case Study — Illustrative

- Market: 85% Shelton (odds 1.17)
- Elo: 23% Shelton (77% Nishikori)
- Reality: Shelton won
- Gap: 62 percentage points

**Assessment:** This is an excellent pedagogical example. It shows exactly how accumulated rating capital from a player's peak years creates a persistent overrating during decline. The market instantly processes "34-year-old returning from injury" while Elo still sees "former world #4 with accumulated wins."

---

## What the Analysis Gets Right

1. **Honest framing**: Neither model beats the market. No attempt to spin negative ROI as a success.
2. **Correct root cause**: Career trajectory lag, not random noise, explains Elo's systematic errors.
3. **Specific evidence**: Named players, specific matches, quantified gaps — not vague claims.
4. **Clean experimental design**: Agreement vs. disagreement split is a standard and appropriate way to diagnose model deficiencies.
5. **No premature optimization**: The author lists potential fixes but doesn't claim they'd work without testing.

---

## What the Analysis Is Missing

### 1. Calibration Analysis — Still Not Reported (Carried from Round 5)

The disagreement analysis shows *directional* accuracy (who wins), but not *probabilistic* calibration (do 70% predictions win 70% of the time?). These are different questions:

- A model can be directionally accurate but poorly calibrated (right winner, wrong probability)
- A model can be well-calibrated but directionally weak (good probabilities, close to 50/50)

The backtest framework already computes calibration bins (`06_backtest.R:469-496`). Running `calibration_summary()` for the Elo model and reporting the table would answer: Is Elo's problem that it picks the wrong winner, or that it assigns wrong probabilities to the right winner?

**This matters for the proposed fixes.** If Elo is directionally correct but miscalibrated, a simple probability transformation (e.g., Platt scaling) could help without changing the model. If it's directionally wrong (as the disagreement analysis suggests for 21% of matches), the model itself needs structural changes.

### 2. K-Factor Sensitivity — Still Untested (Carried from Rounds 3, 4, 5)

This has been flagged for three consecutive rounds. The trajectory analysis provides the strongest argument yet for testing higher K-factors: if the problem is accumulated rating capital creating inertia, a higher K-factor directly addresses this by giving more weight to recent results.

**Concrete recommendation:** Test K = 16, 24, 32 (current), 48, 64 on the clean H1 2024 data. Report accuracy, Brier score, and the disagreement rate against market favorites. This is a straightforward sensitivity analysis that could be completed in one backtest session.

### 3. No Formal Statistical Tests

The analysis reports percentages (34.7% vs 65.3%) without confidence intervals or hypothesis tests. With N=317 disagreements:

- A two-sided binomial test of Elo accuracy = 50% against the observed 34.7% would yield p < 0.0001
- A McNemar test comparing Elo vs. market accuracy across all 1,499 matches would formally quantify the model comparison

These tests don't change the conclusion — the difference is clearly significant — but they're standard practice and should be included.

### 4. Potential Fixes Are Untested

The analysis lists five potential fixes:
1. Higher K-factor
2. Time-decay on older matches
3. Form adjustment (recent results multiplier)
4. Refuse strong disagreements (defer to market)
5. Hybrid model (market prior + Elo adjustment)

None have been tested. Options 1-2 are quick to implement and test. Option 4 is trivially implementable (skip bets where Elo contradicts strong favorites). Option 5 is the most interesting but requires more design work.

### 5. When Does Elo Add Value?

The analysis identifies 7 matches where Elo was right against strong favorites, but doesn't investigate whether there's a pattern. If Elo's correct contrarian picks share a common feature (e.g., recent form data available, same surface, specific player profile), that would be more useful than the overall 16% hit rate suggests.

More broadly: does Elo add any information beyond the market? The 68.1% joint accuracy when they agree equals the market's standalone accuracy. This suggests Elo is informative only when it agrees — which means it provides zero incremental value over simply using market odds.

---

## Minor Concerns

1. **Calibration analysis not reported** (carried from Round 5). The backtest framework supports it. Running and reporting it would be minimal effort with high diagnostic value.

2. **K-factor sensitivity still absent** (carried from Rounds 3, 4, 5). The trajectory analysis makes the case for testing this more compelling than ever. Three rounds of flagging without action.

3. **No formal statistical tests** for the model comparison or the disagreement analysis. Standard practice for quantitative work.

4. **`model_analysis.md` mixes pre- and post-leakage numbers.** The document references 58.1% MC accuracy (line 58), which is a pre-leakage-fix number from a different backtest configuration. It should be clearly labeled or updated to reflect clean results.

5. **Elo scale factor (400) not validated for tennis** (carried from Round 5). Lower priority given the trajectory issue, but still an open question.

---

## Questions for Authors

1. **What is the plan for K-factor sensitivity testing?** This has been flagged for three consecutive rounds and the trajectory analysis makes it directly relevant. Is there a reason this hasn't been tested?

2. **Has `calibration_summary()` been run on the Elo results?** If so, what does the calibration table show? If not, this is a single function call that would provide significant diagnostic value.

3. **Is the goal still to find a betting edge, or has the project pivoted to understanding model behavior?** The honest conclusion that "neither model beats the market" is valuable, but it changes what the next steps should be. If the goal is academic understanding, the trajectory analysis is the right direction. If the goal is still profitability, the hybrid model (market prior + Elo adjustment) is the only plausible path.

---

## Verdict

[X] Accept with Minor Revisions

**Justification:** The critical data leakage from Round 5 has been properly fixed. The date alignment module is well-designed, thoroughly tested, and correctly integrated into the backtest pipeline. The corrected results (Elo: 60.8%, MC: 56.0%) are trustworthy.

The Elo underperformance analysis is honest, well-structured, and diagnostically correct. The career trajectory explanation is the right root cause. The finding that Elo is anti-informative when it disagrees with the market (34.7% accuracy on disagreements) is a genuine contribution to understanding model limitations.

The remaining minor concerns — calibration reporting, K-factor sensitivity, formal tests — are incremental improvements that don't affect the core conclusions. The project is in a sound methodological state.

---

## Recommendations

1. **Run calibration analysis** on clean Elo results using the existing `calibration_summary()` function. Report the predicted vs. actual win rate table.

2. **Test K-factor sensitivity** with K ∈ {16, 24, 32, 48, 64} on clean H1 2024 data. This directly addresses the trajectory lag problem and has been requested for three rounds.

3. **Add statistical tests**: Binomial test on disagreement accuracy, McNemar test for Elo vs. market overall comparison.

4. **Test at least one proposed fix**: The simplest is "refuse strong disagreements" — skip bets where Elo contradicts favorites with odds < 1.40. Report the impact on accuracy and ROI.

5. **Clarify `model_analysis.md`**: Label or update pre-leakage-fix numbers to avoid confusion with clean results.

=================================================================
                      END OF REFEREE REPORT
=================================================================
