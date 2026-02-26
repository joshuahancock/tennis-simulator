# MagNet Paper Reading Notes

**Paper:** Clegg & Cartlidge (2025). "Graph Neural Networks for Tennis Match Prediction."
arXiv:2510.20454v1. https://arxiv.org/html/2510.20454v1

Notes compiled section by section as read. Analytical observations, open questions,
and implementation flags captured as we go.

---

## Section 1: Introduction

**Core bet the paper makes:** Intransitivity (A beats B, B beats C, C beats A) is a
real, persistent feature of tennis outcomes that standard models systematically ignore —
and bookmakers misprice it. GNNs can learn from directed cycles; Elo/Bradley-Terry
cannot (they force a strict linear hierarchy).

**Opening hook:** Nadal–Federer–Davydenko cycle. Three world-class players forming a
rock-paper-scissors relationship that any Elo-based model would misrepresent.

**Headline results:**
- Overall: 65.7% accuracy, Brier 0.215 — matches Elo and bookmaker-implied accuracy
- **The real claim:** filtering to matches with high intransitive complexity yields
  3.26% ROI with Kelly staking over 1,903 bets against Pinnacle

**Key framing observation:** This is not a "we beat Elo" paper. Overall performance is
comparable to Elo. The contribution is identifying a *specific structural feature*
(intransitivity) that markets underprice, and building a model that captures it.
If the intransitivity filter doesn't hold out-of-sample, the paper falls apart.

**Literature search:** 66 distinct search queries combining 6 GNN terms × 11 tennis
prediction terms — came up empty on GNN + pre-match tennis prediction. Novelty claim
is defensible.

---

## Section 2: Background

**Point-based models:** Simulate tennis point-by-point using serve/return probabilities.
Our MC model is in this category. Doesn't capture head-to-head history or intransitive
structure.

**Pairwise comparison models (Elo family):** Kovalchik's survey found Bookmaker
Consensus Model at 72%, specialized Elo at 70% — both well above everything else.
Angelini WElo improves on basic Elo by scaling updates by games proportion.

**Prior graph methods (none using GNNs for match prediction):**
- Radicchi (PageRank for player ranking, not match prediction)
- Dingle et al. (PageRank as predictor, 67.0% ATP accuracy)
- Aparício et al. (surface-specific colored networks, orbit-score rankings — no match
  prediction)
- Bayram et al. (graph centrality as ML features, SVM+ at 66%)
- **Arcagni et al. (eigenvector centrality in logit model, Brier 0.194 on ATP
  2016–2020)** — strongest prior graph result; better than standard Elo's 0.206 in
  that study. Paper doesn't dwell on this but it's a meaningful benchmark.

**MagNet:** Uses magnetic Laplacian — complex Hermitian matrix whose eigenvalue
spectrum encodes directed cycle information. Parameter q controls directional
sensitivity; optimal q approaches 0.25 when directional cycles matter.

**Van Ours connection:** Explicitly cited — bookmakers set cardinally transitive odds,
so intransitive matchups are systematically mispriced. This is the market inefficiency
argument that motivates the betting experiment.

---

## Section 3: Data

**Sources:**
- Match data: tennis-data.co.uk (same as ours), Jan 2014 – Jun 2025
- Player attributes: tennisexplorer.com — height, weight, DOB, handedness
  (check Sackmann's atp_players.csv first before scraping)
- Odds: Pinnacle Sports (same rationale as ours — sharp book, low margin)

**Scope:** Grand Slams, tour finals, Masters 1000, ATP/WTA 500. Same filter as us.

**Final dataset:**
- ATP: 16,663 matches, 598 players
- WTA: 16,447 matches, 567 players
- We have 17,644 ATP matches (to Nov 2025); filtering to Jun 8, 2025 should align

**Temporal split:**
- Validation: Aug 29, 2019 – Nov 20, 2022 (hyperparameter tuning)
- Test: Jan 1, 2023 – Jun 8, 2025 (evaluation)
- Training history pre-validation: Jan 2014 – Aug 2019 (5.5 years before first prediction)

---

## Section 4.1: Graph Representation

**Structure:** Six directed graphs total — one per gender per surface (ATP: hard/clay/
grass, WTA: hard/clay/grass). Players are nodes, match history becomes edges.

**Node features (ℓ₂-normalized):**
- Static: height, weight, date of birth, handedness
- Dynamic: surface-specific in-degree and out-degree (updated as graph evolves)
  — these create a feedback loop: graph structure informs node features which feed
  into convolutions

**Dominance score formula:**
```
D^s(u,v) = Σ_k [α(s,s_k) · β_k · φ_k · g_k(u,v)]
           ──────────────────────────────────────────
           Σ_k [α(s,s_k) · β_k · φ_k]
```
- g_k(u,v) = winner_games / total_games in match k (same games proportion as WElo)
- α(s,s_k) = surface transferability weight (tuned via TPE; range 0.01–0.45)
- β_k = time decay: exp(-λ·Δt), λ=0.38
- φ_k = tournament prestige weight (tuned via TPE; range 0.69–0.94)

**Edge direction rule:**
- D > 0.5 → u→v (u dominates), weight = D
- D < 0.5 → v→u, weight = 1-D
- D = 0.5 → no edge
- Each pair contributes at most one directed edge

**Key observations:**
1. The dominance score is a richer version of Elo — incorporates time decay, surface
   transferability, and prestige simultaneously rather than separately or not at all.
2. Surface transferability explicitly parameterizes cross-surface information transfer
   rather than ignoring surface (overall Elo) or siloing it (surface-specific Elo stores).
   Our welo package comparison showed surface siloing hurts ~0.7pp vs. overall Elo —
   this approach is potentially the right middle ground.
3. One edge per pair is a strong compression — the entire H2H history collapses to a
   single directed edge with a scalar weight. Loses trajectory information.
4. α and φ are tuned as hyperparameters via TPE jointly with architecture parameters.
   Not a replication gap — just part of the optimization.

---

## Section 4.2: MagNet Architecture

**Framing:** Directional edge prediction — given the graph, predict which direction a
new edge between u and v should point. Direction probability = set-win probability.

**The magnetic Laplacian:**
```
L^(q) = D - exp(i·2π·q·Θ) ⊙ A
```
where Θ is an antisymmetric phase matrix encoding edge direction. Parameter q:
- q = 0: phases cancel → standard symmetric Laplacian → direction ignored
- q = 0.25: imaginary components fully encode direction → maximum sensitivity
Fixed at q = 0.25 — not tuned. This is a design commitment to maximum directional
signal, not a hedge.

**Practical implication:** Network operates in complex number space. Node embeddings
have real and imaginary parts. PyTorch Geometric's MagNetConv handles this, but
requires PyTorch with stable complex tensor support (properly available ~v1.9+).
Check version compatibility before starting implementation.

**Architecture (optimized values):**
```
Chebyshev filter order K = 2
Layers = 2  →  4-hop receptive field
Hidden units = 64
Dropout = 0.3
```
4-hop receptive field: model can see players up to 4 steps away in the H2H graph.
Deep intransitive cycles (A→B→C→D→A) are visible to the model.

**Training:**
```
Optimizer:      Adam
Learning rate:  0.003
Weight decay:   1e-4
Loss:           Cross-entropy with label smoothing ε = 0.19
```

**Label smoothing:** Replaces hard targets (0,1) with soft targets (ε/2, 1-ε/2).
Prevents overconfidence; directly improves Brier score. Only applicable to
cross-entropy loss — if we train with Brier score directly as the loss function,
overconfidence is penalized automatically and label smoothing is unnecessary.
ε = 0.19 is higher than the standard default of 0.10 — suggests tennis outcomes
are uncertain enough that aggressive calibration was beneficial.

**Set → match probability conversion (assuming i.i.d. sets):**
- Best-of-3: P̂₃ = p̂²(3 − 2p̂)
- Best-of-5: P̂₅ = p̂³(10 − 15p̂ + 6p̂²)
Full derivation in paper's Appendix A. Simpler than our MC model — closed-form
binomial, no point-by-point simulation.

---

## Section 4.3: Walk-Forward Validation

**The 85/15 split — most important subtlety in the paper:**
This is NOT a standard train/test split. At each snapshot:
- 85% oldest matches → form the graph structure (historical dominance edges)
- 15% most recent matches → labeled training edges (GNN learns to predict their direction)

The training signal is: *given the full historical graph, predict which way these
recent edges should point.* The GNN learns from the graph neighborhood structure,
not just raw head-to-head records.

**The cycle:**
1. Build graph from earliest 85% of historical matches
2. Train 150 epochs: predict direction of 15% most recent edges
3. Predict next tournament round snapshot
4. Observe true outcomes → integrate into graph
5. Advance 15% window forward
6. Every 38 snapshots (~quarterly): retrain +30 epochs
7. Repeat

One snapshot = one tournament round. 38 snapshots ≈ one quarter.

**Data splits:**
| Period | Purpose | Dates |
|--------|---------|-------|
| Training history | Initial graph | Jan 2014 – Aug 2019 |
| Validation | Hyperparameter tuning | Aug 29, 2019 – Nov 20, 2022 |
| Test | Final evaluation | Jan 1, 2023 – Jun 8, 2025 |

**Compute:** Under 10 seconds per training cycle on RTX 2070 Super (consumer GPU).
GPU required — CPU-only would be 5–20× slower. Not a cluster job.

**Key observations:**
1. The 85/15 split is the least intuitive part of the paper. Needs careful implementation
   to avoid leakage within a tournament round.
2. Rolling window (not expanding) — the 15% advances forward. Time decay handles the
   decreasing relevance of old matches.
3. +30 epochs quarterly is lightweight fine-tuning, not full retraining. Model adapts
   gradually rather than relearning from scratch.
4. Snapshot at tournament round level bakes in leakage prevention by design — no
   within-round future information used.
5. The "validation period" starts Aug 2019, not Jan 2014. Five and a half years of
   history are consumed before the first prediction is made.

---

## Section 4.4: Parameter Optimization

**Setup:** 300 Optuna trials, TPE algorithm, bi-objective optimization over men's and women's
Brier scores simultaneously, selecting the Pareto-optimal solution. Validation period:
Jan 2014 – Nov 2022 history, predictions Aug 2019 – Nov 2022.

**GNN architecture hyperparameters (search space → optimal):**
```
Chebyshev filter order K:  {1, 2, 3}     → 2
Hidden units:              {32, 64, 128}  → 64
Network layers L:          {1, 2, 3}      → 2
Label smoothing ε:         [0.0, 0.2]     → 0.19
Time decay λ:              [0.0, 0.5]     → 0.38
```

**Surface transferability α (cross-surface weights, optimized per pair):**
- Hard ↔ Grass: **0.45** (highest transfer of all cross-surface pairs)
- Other pairs: within [0.01, 0.45]
- Diagonal (same surface): 1.0 (fixed, not tuned)
- Hard–Grass transfer being highest is counterintuitive — might reflect that grass
  specialists often come from the hard-court baseline game, while clay has more
  distinctly different biomechanics (topspin, sliding, patience)

**Tournament prestige φ (tuned ranges by tier):**
```
Grand Slams:        normalized to 1.0 (reference level, not free parameter)
Masters 1000:       [0.80, 1.00]
ATP/WTA 500:        [0.20, 0.80]
Tour Finals:        [0.90, 1.10]  ← can exceed Grand Slams
```
The Tour Finals range [0.9, 1.1] is the most interesting — the ATP/WTA Finals feature
only the top 8 players (round-robin format, high quality), so the model learns to weight
those results at least as heavily as Grand Slams. Makes sense: a Tour Finals win over a
top-8 player is arguably more informative about skill at that level than a Grand Slam
win over a qualifier.

**Key observations:**
1. The optimal architecture (K=2, L=2, h=64) is comfortably in the middle of each
   search space — not at the boundary, suggesting the optimization genuinely found a
   sweet spot rather than hitting a range limit.
2. Label smoothing ε=0.19 at the upper boundary of the search range [0.0, 0.2] suggests
   the algorithm wanted to push further. If we re-optimize, could try [0.0, 0.3].
3. λ=0.38 means a match from one year ago gets exp(-0.38·365) ≈ 1.5e-60 weight —
   effectively zero. Time decay is very aggressive. A match from 60 days ago gets
   exp(-0.38·60) ≈ 0.10. So only ~3 months of history carries substantial weight.
   This is much more aggressive than most Elo time-decay implementations.
4. Bi-objective optimization ensures the model doesn't overfit to ATP at the expense
   of WTA, which is the right design choice for a general-purpose model.
5. The TPE Pareto-optimal selection is the standard Optuna approach. Not esoteric — but
   running 300 trials × 6 graphs is a non-trivial compute budget if we need to re-do it.

---

## Section 5: General Predictive Performance

**Test set:** Jan 1, 2023 – Jun 8, 2025 (8,375 total matches, both genders combined)

**Overall results (premium tier):**
| Model           | ATP Accuracy | WTA Accuracy | ATP Brier | WTA Brier |
|-----------------|-------------|-------------|-----------|-----------|
| Standard Elo    | 65.7%        | 67.8%        | 0.215     | 0.208     |
| Angelini WElo   | 66.4%        | 67.1%        | 0.212     | 0.211     |
| MagNet          | 65.7%        | 67.0%        | 0.215     | 0.207     |
| Pinnacle odds   | 69.0%        | 70.4%        | 0.196     | 0.190     |

**By gender and surface (highlights):**
- Highest accuracy: men's grass (67.4%)
- Lowest accuracy: women's hard (65.2%)
- Calibration: strong, no systematic over/underconfidence reported

**Overall interpretation:**
MagNet does NOT beat Elo on overall accuracy or Brier. This is by design — the paper's
contribution is not "better overall model" but "better at a specific structural problem
(intransitivity) that the market mislabels." This section is almost disappointingly
unremarkable on its own.

One thing to note: MagNet (0.207) barely edges WElo (0.211) on WTA Brier but not on
WTA accuracy (67.0% vs 67.1%). These are within noise. Nothing to write home about
until we get to the intransitivity analysis.

---

## Section 6: Intransitivity Analysis and Betting Simulation

### 6.1: Evidence-Weighted Intransitivity Metric

**The intransitivity measure I*(A_uv):**
This is an adapted version of Hamilton et al.'s measure, scaled by accumulated evidence:
```
I*(A_uv) = I(A_uv) · √[Σ_k α(s, s_k) · β_k · φ_k]
```
Where the sum under the square root is the total accumulated weight for the matchup
(same weighting scheme as the dominance score formula). This is elegant:
- `I(A_uv)`: raw graph-theoretic intransitivity of the matchup (directionality from
  the magnetic Laplacian's spectrum)
- `√[Σ weights]`: evidence base — how much historical context the intransitivity
  score is based on. A cycle with 10 well-documented matches is more trustworthy
  than a cycle inferred from 2 old, low-prestige matches.
- The product penalizes intransitivity claims with weak evidence and rewards
  well-documented structural mismatches

**Distribution findings:**
- WTA mean I* = 3.02 vs ATP mean I* = 2.71 (WTA is 11.5% more intransitive overall)
- Plausible: WTA has higher variance in serve/return patterns, more style mismatches,
  and arguably less linear dominance hierarchies than ATP
- This is worth its own research question — why is WTA more intransitive?

### 6.2: Model Performance vs. Intransitivity

**Key finding:** As intransitivity increases, MagNet's disadvantage vs. Pinnacle narrows.
- Low-evidence matchups: MagNet–Pinnacle Brier gap = +0.023
- High-intransitivity matchups: MagNet–Pinnacle Brier gap = +0.007
- Gap narrows by 68.3%

**Interpretation:** MagNet gets relatively better (vs. bookmaker) as intransitivity
increases. Bookmakers price cardinally transitive odds (Van Ours 2025) — so in high-
intransitivity situations, the market is structurally wrong and MagNet captures the
correct direction better. This is the core theoretical mechanism of the whole paper.

Note: even at peak intransitivity, MagNet still has a *positive* Brier gap vs. Pinnacle
(MagNet is still worse overall), just a much smaller one. The model never beats the
market on Brier — it just closes the gap significantly in the subset that matters for
betting.

### 6.3: Betting Simulation

**Threshold selection:**
- Optimal threshold: I*(A_uv) ≥ 2.55 (identified on validation data — this is the
  critical detail; the threshold is in-sample to the validation period)
- Bets placed: **1,903 out of 7,705 test matches** (24.7% of test matches selected)

**Kelly staking results (MagNet, I* ≥ 2.55):**
```
ROI:          3.26%   (p = 0.005, statistically significant)
Sharpe Ratio: 0.61    (moderate)
```

**Unit staking results:**
```
ROI: 1.14%  (positive but weaker)
```

**Comparison models at same threshold:**
```
Weighted Elo:  -5.54% Kelly ROI  (negative — WElo LOSES at this filter)
MagNet (all):  -5.49% Kelly ROI  (no filter — negative, as expected)
```

**Shape of the relationship (intransitivity vs. profitability):**
- I* = 0 (no prior H2H): negative ROI — no information to exploit
- I* around 2.55: sweet spot, peak positive ROI
- Very high I* (extreme): turns negative again — bookmakers are efficient for
  highly-analyzed matchups (lots of H2H history = lots of public attention)
- Inverted-U relationship between intransitivity and profitability

**Key observations:**
1. The 3.26% ROI at p=0.005 over 1,903 bets is a meaningful result, but the threshold
   I* ≥ 2.55 was tuned on validation data — classic out-of-sample concern. The test
   period is genuinely out-of-sample (Jan 2023+), but threshold leakage from the
   validation period is real.
2. Weighted Elo at the same filter loses money (-5.54%). This is the paper's strongest
   claim: the profitability is specific to the MagNet structure (directional cycle
   detection), not to the filter alone. Any model run through this filter doesn't profit.
3. Sharpe 0.61 is acceptable for a betting strategy, not extraordinary. Persistent edges
   above 1.0 Sharpe are rare; 0.61 is in the "exploitable if transaction costs are low"
   range.
4. The 24.7% selection rate (1,903 / 7,705) means the strategy sits out ~75% of matches.
   This is important for replication: our match universe must include the same scope
   as the paper's (premium tier, both genders).
5. The inverted-U finding (extreme I* turns negative) suggests market efficiency returns
   at the tails — the most "interesting" matchups in graph terms are also the most
   publicly scrutinized. The edge lives in the middle: complex enough to trip up the
   bookmaker's transitive pricing model, but not so analyzed that sharp money corrects it.
6. This is still a relatively short test window (2.5 years). Real robustness check would
   need a second independent test window.
