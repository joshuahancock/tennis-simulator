# Future Research Questions

Open questions and research directions identified during the project. Not prioritized — just a running log to avoid losing ideas.

---

## Betting Market Structure

### Opening line data gap
We currently have no source for historical tennis opening lines. Tennis-data.co.uk provides only a single closing (or near-closing) odds snapshot per match (`PSW`/`PSL`, `B365W`/`B365L`, etc.). There is no clean, licensed, publicly available source for Pinnacle or Bet365 tennis opening lines.

**Why it matters:** Closing Line Value (CLV) — whether your model's prediction is closer to the opening or the closing line — is the strongest available indicator of genuine model edge, independent of short-run outcomes. A model that consistently beats CLV has real signal; one that doesn't is finding noise. Without opening lines, we cannot compute CLV.

**Possible workarounds (all imperfect):**
- Oddsportal historical archives (scraping, against ToS, messy data)
- The Odds API (commercial, limited pre-2022 tennis history)
- Betfair Exchange pre-match movement (requires paid historical data product)
- B365 vs. Pinnacle closing spread as a noise proxy (weak — both are closing prices)

**Status:** Blocked by data availability. Flag as a known limitation; revisit if a clean source emerges.

---

## Graph-Based Models

### Non-transitive triads in tennis betting markets
Van Ours (2025) documents persistent non-transitive triads in EPL football outcomes and shows bookmakers systematically misprice them (bookmakers set cardinally transitive odds). Bozóki et al. (2016) and Temesi et al. (2024) establish that non-transitive patterns exist in ATP and WTA match outcomes respectively. The open question is whether **bookmakers misprice non-transitive triads in tennis** and whether a van Ours-style betting strategy would have been profitable.

**Key methodological challenges vs. football:**
- Sparsity: tennis head-to-head records are much thinner than EPL round-robin schedules
- Non-stationarity: player quality trajectories make long-run triad analysis harder
- Surface heterogeneity: a triad may be non-transitive on clay but transitive on hard
- Selection bias: matchups only observed when both players enter and advance in the same draw

**Possible approach:** Restrict to top 20-30 players, longer time windows, surface-stratified analysis, use surprise wins (actual minus odds-implied) rather than raw win balances to absorb quality variation.

**Connection to MagNet:** This would provide empirical motivation for graph-based models — if non-transitive triads are economically exploitable and bookmakers systematically ignore them, GNNs that capture directed cycle structure have a principled edge over Elo/Bradley-Terry.

---

## Model Architecture

### ATP 250 events as a separate modeling target
Currently excluded from both training and evaluation. The hypothesis is that edges may be easier to find in 250s due to shallower fields and less efficient markets. Needs a solid premium-tier baseline first before extending down.

### Calibration improvements for Angelini WElo
Angelini WElo improves directional accuracy vs. Standard Elo (+0.3-0.5pp) but degrades Brier score. Games-proportion scaling compresses extreme ratings, hurting calibration even while improving accuracy. Worth investigating Platt scaling or isotonic regression as post-hoc calibration layers.

### Injury information and line movement
Our model is a structural/historical baseline and cannot incorporate injury information. The theoretically sound approach (CLV framework using opening vs. closing line movement as an information-arrival proxy) is blocked by the opening line data gap above. Post-hoc analysis of strong model-market disagreements is feasible but only diagnostic, not actionable in real-time.
