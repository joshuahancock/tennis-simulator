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

**Literature baseline discussion:**

Two papers are the key foundation for Section 1's framing:

*Van Ours (2025), Empirical Economics:* Football (EPL), 25 seasons, 10 clubs. Establishes
the mechanism: bookmakers face a trade-off between efficiency (using all information) and
consistency (setting internally coherent odds). They choose consistency. You cannot set
A→B, B→C, and C→A odds that are all individually rational without internal inconsistency,
so bookmakers suppress the cycle and price as if outcomes were transitive. 15 of 120
possible triads are statistically significant and persistently exploitable. This is the
*why* behind Clegg & Cartlidge's betting claim.

*Kovalchik (2016), JQAS:* The foundational benchmarking paper. Horse race across 11
models on 2014 ATP data. Establishes the accuracy ordering the field has measured itself
against ever since:
```
Bookmaker Consensus Model:  72%
FiveThirtyEight Elo:        70%
Regression (ranking only):  67–68%
Point-based:                64–67%
Bradley-Terry:              62–65%
```
No model beats the bookmaker. Within the paper, accuracy by tier:
- Grand Slams: 70–73% (easiest to predict)
- Masters 1000: 65–72%
- 250/500: 60–67% (hardest to predict)

Premium tier matches are *easier* to predict than 250s, consistent with intuition:
deeper historical data on both players, clearer form signals, and fewer lower-ranked
players (where all models are 10–20pp worse).

**Reconciliation note on 72% vs. 69%:**
Kovalchik's 72% BCM (2014, all ATP including 250s) vs. Clegg & Cartlidge's 69%
Pinnacle (2023–2025, premium only) cannot be cleanly compared:
- Since premium tier is *easier* to predict than 250s within Kovalchik's study,
  her 72% is pulled *down* by including 250s. Premium-only in 2014 would have
  been higher than 72%.
- A sharper market over a decade would push bookmaker-implied accuracy *up*, not
  down — so market improvement cannot explain a lower number in 2023–2025 either.
- The two numbers are from different eras, different player fields, different sample
  compositions. The 3pp difference is not a meaningful signal and should not be
  over-interpreted.

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

**Reproducibility analysis:**

*Clearly and precisely defined:*
- Dominance score formula — mathematical form is unambiguous
- Time decay functional form: exp(-λ·Δt), λ=0.38
- Edge direction rule: D > 0.5 → u→v, D < 0.5 → v→u, D = 0.5 → no edge, one edge per pair
- Number of graphs: 6 (3 surfaces × 2 genders)
- Node feature list: height, weight, DOB, handedness, surface in-degree, surface out-degree
- ℓ₂ normalization of node features
- Missing value imputation: gender-specific medians

*Partially specified — ranges given, exact values require TPE:*
- α matrix (surface transferability): range 0.01–0.45 for off-diagonal, diagonal fixed at
  1.0. Paper does not state whether the matrix is symmetric. Does clay→hard equal
  hard→clay? If symmetric: 3 free parameters. If asymmetric: 6. Not stated.
- Tournament prestige weights: range 0.69–0.94. Exact tier mapping not pinned down.
  Grand Slams are the reference level, but how Tour Finals are treated relative to
  Masters 1000 is recovered only through TPE optimization.

*Genuinely underspecified — requires implementation decisions:*
- **Concurrent tournaments**: ATP runs multiple tournaments simultaneously, but player
  pools at the premium tier are functionally disjoint — a player can only enter one
  tournament per week, so matches from concurrent events don't create leakage into each
  other's predictions. Proposed approach: use the higher-prestige tournament as the
  "conductor" that defines snapshot timing; consume completed matches from concurrent
  lower-prestige tournaments as they finish, even if those rounds are incomplete. The
  prestige hierarchy (Grand Slam > Masters 1000 > ATP 500) already encoded in φ resolves
  any ambiguity between two simultaneous premium events.

  Round-level snapshots are a modeling simplification for evaluation tractability, not
  a validity requirement. Within-round updates are not leakage — using a completed
  morning match to inform an afternoon prediction is sequentially updating on new
  evidence, exactly as Elo does match-by-match. The betting window stays open until
  match start, so mid-round prediction updates are operationally valid. The round-level
  design is the right choice for reproducible historical backtesting (avoids needing
  intra-day match timing data and simplifies evaluation), but in live deployment the
  correct approach is continuous updates: each completed match regenerates predictions
  for remaining unplayed matches in the round.
- **New players with no H2H history**: Dominance score denominator is zero for pairs that
  have never met. The natural resolution is no edge (D = 0.5 → no edge is already in
  the edge direction rule). This is the principled choice: the GNN's 4-hop receptive
  field was specifically designed to handle pairs with no direct H2H by propagating
  information through common opponents. If there is no signal within 4 hops, 50/50 is
  the most honest position — the graph has nothing to say. For truly isolated new
  players with sparse connections, predictions degrade gracefully to node features
  (height, weight, age, handedness), which is the best available prior. Constructing
  a synthetic edge from Elo would create a training/inference inconsistency (model
  was never trained with Elo-derived edges) and, where graph signal does exist, would
  bias the GNN toward transitive rankings — undermining the model's core purpose of
  capturing non-transitive structure.
- **Retired/incomplete matches**: Skip entirely. A retirement doesn't represent a
  competitive outcome — the scoreline at the point of retirement is arbitrary relative
  to who would have won. Including with f_g_i=1, f_g_j=0 treats every walkover as a
  maximally dominant win, inflating the winner's dominance score unfairly.

- **Edge update timing**: Recomputing from scratch at each snapshot is correct but
  expensive. Efficient incremental approach: store two running sums per (player pair,
  surface) — numerator N and denominator Z. At each snapshot advance of Δ days, both
  sums decay uniformly: N ← N·exp(-λ·Δ), Z ← Z·exp(-λ·Δ). When a new match arrives,
  add the new term with β=1: N ← N + α·φ·g_new, Z ← Z + α·φ. D = N/Z. Store as
  sparse matrices per surface (players × players × 2 values) — ~17MB for 600 players,
  trivially manageable. Full history never needs to be retained.

- **The D = 0.5 boundary**: Not a meaningful issue in practice. With continuous inputs
  (games proportions, exponential decay, continuous prestige weights) the probability
  of landing exactly on 0.5 is essentially zero. When it does occur, D = 0.5 → no edge
  means "no dominance asserted" rather than "evenly matched" — the graph treats a pair
  with a rich but perfectly balanced H2H history identically to two players who have
  never met, which is a mild semantic oddity. Accepted as a known downside of the
  design; vanishingly rare in practice.

*The single-edge compression — a meaningful design choice:*
The entire H2H history collapses to one directed edge. Federer beating Nadal once and
Federer beating Nadal 15 times both produce an edge in the same direction — weight
differs but sample size information is lost explicitly. Time decay softens this (a
single old win has a tiny denominator contribution) but trajectory information is gone:
whether dominance is increasing, decreasing, or reversed over time is not captured.

*The feedback loop — less complex than it sounds:*
Dynamic node features (in-degree, out-degree) are computed from the graph, which is
built from the dominance scores. But dominance scores are computed entirely independently
of the GNN. The GNN is a downstream consumer of the graph, not a modifier. The feedback
loop is one-directional: graph → features → GNN predictions. No circular dependency
during training.

*The six graphs are fully isolated at the GNN level:*
Cross-surface learning happens only at the edge construction stage via α. Once the clay
graph is built, the GNN operating on it sees only clay-specific edges — no direct
visibility into hard or grass graphs. The α parameter carries all cross-surface signal.
This is a significant architectural constraint.

*Overall reproducibility assessment:*
The GNN training (Phase 3) is the most straightforwardly specified part of the pipeline.
The graph construction (Phase 2) is where most friction lives. The mathematical form of
the dominance score is clean, but implementation details — concurrent tournament handling,
new player priors, retirement handling, exact snapshot timing — involve decisions the
paper leaves open. Different reasonable choices could produce materially different graphs
and therefore different model behavior, even with identical architecture and
hyperparameters. This is the part of the replication to be most cautious about.

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

**Brier score vs. wagering ROI — a tension in the loss function choice:**

Brier score rewards calibration uniformly across all predictions — a 65% prediction
should be right 65% of the time, and every match gets equal weight in the loss.
Label smoothing amplifies this by explicitly capping model confidence (ε = 0.19
replaces targets with 0.095/0.905, pulling all predictions toward 0.5).

For wagering ROI this is the wrong objective. Kelly staking sizes bets proportionally
to estimated edge: f ≈ (p_model - p_implied) / (1 - p_implied). Revenue comes almost
entirely from the subset of matches where the model significantly disagrees with the
market — the other 80% of matches contribute nothing. A Brier-optimal model
calibrated equally across all matches is not the same as a model that is *right*
specifically in high-edge situations.

The ideal betting loss function would weight training examples by market edge
magnitude — focus the model on getting high-disagreement matches right rather than
low-disagreement ones. But this requires market odds at training time and creates
design problems (leakage; also, you're training the model to predict its own
disagreement with the market).

**The ε = 0.19 problem specifically:** The intransitive matches where structural
insight should be most confident are exactly the matches where label smoothing is
suppressing the signal. If a non-transitive triad creates a genuine directional
conviction, ε = 0.19 actively prevents the model from expressing it. This could
suppress Kelly bet sizes precisely where the model's structural advantage is
strongest.

**The paper's implicit solution:** Decouple the objectives. Train globally for
calibration (Brier + label smoothing), then apply the intransitivity filter at
inference to select matches where structural signal is strongest. This is reasonable —
a well-calibrated model produces more trustworthy edge estimates than an overfit one —
but ε = 0.19 may be overcorrecting in the other direction.

**Extension to explore:** Test with smaller or no label smoothing (ε = 0 or ε ≤
0.05) and evaluate whether ROI on the intransitive subset improves, even if global
Brier worsens. The hypothesis: sharper predictions in intransitive matches → larger
Kelly bet sizes → better ROI on the filtered subset, at the cost of worse global
calibration. Worth testing after the baseline replication is established.

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

**Parsing "38 snapshots ≈ quarter year":** The operative unit is tournament rounds, not
calendar time. At the premium tier, approximately 150 rounds occur per calendar year
(~12–15 premium events × 7 rounds each, for both ATP and WTA combined per surface
graph). 150 ÷ 4 ≈ 38 rounds per quarter. The "quarter year" label is a consequence of
counting rounds, not a trigger — they don't retrain at the start of each calendar quarter
or at each Grand Slam. The Grand Slam interpretation fails: four Slams per year × 7 rounds
each = 28 rounds, not 38, and they are unevenly spaced across the year.

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

**Walk-forward design questions:**

*Does 150 epochs on sparse data + quarterly +30 updates converge to the same place
as training from scratch on a dense graph?* The initial 150 epochs are run on a
relatively sparse 2014–2019 graph. Subsequent +30 epoch increments are cheap updates
layered on top of weights initialized from that sparse state. Gradient descent on a
non-convex loss doesn't guarantee that incremental fine-tuning converges to the same
solution as a fresh full training run — the initial sparse training could lock in
inductive biases that quarterly updates never fully escape. The authors presumably
tested this during hyperparameter optimization, but it warrants independent verification.

*Why ramp up at all rather than starting fully loaded?* Starting predictions in Aug
2019 rather than, say, Jan 2022 extends the evaluation window (more validation data
for hyperparameter tuning, larger test set for the betting simulation). The tradeoff
is that early predictions are made on a sparser graph. Whether early sparse-graph
predictions are materially worse than later dense-graph predictions is not broken out
in the paper — if they are, the headline accuracy and Brier figures understate steady-
state model performance.

*Observable in replication:* Both questions can be answered directly when we have
the model running:
1. Track accuracy and Brier by snapshot number across the test period. Flat or
   gently improving → fine-tuning is working. Strong improvement over time → initial
   sparse training is a drag that updates don't fully correct.
2. "Fresh retrain at test period start" variant: freeze graph state as of Jan 2023,
   train from random initialization for 150 epochs on most recent 15%, compare against
   the paper's incrementally updated model on the same test matches. If fresh retrain
   wins, the walk-forward fine-tuning design is more about computational convenience
   than accuracy.

---

## Section 4.4: Parameter Optimization

**Method:** TPE (Tree-structured Parzen Estimator) via Optuna. 300 trials over the
validation period (predictions from Aug 29, 2019 – Nov 20, 2022). Multi-objective:
minimize Brier score for ATP and WTA *separately*, then select Pareto-optimal solution
with favorable trade-off between men's and women's performance. This is principled —
avoids the risk of tuning only on men's and overfitting the α/φ values to ATP dynamics
that don't generalize to WTA.

**Final architecture (selected from Pareto front):**
```
Chebyshev filter order K = 2
Layers = 2         →  4-hop receptive field (K × L = 2 × 2 = 4)
Hidden units = 64
Activation function = None  (linear combination layers only)
```
The "no activation function" result is notable — the model reduces to learned linear
combinations of the magnetic Laplacian-transformed features. Nonlinear activations were
available and tried (search space included True/False) but didn't help.

**Graph construction parameters (optimized):**
```
Time decay rate:  λ = 0.38   (searched over 0.0–0.5)
```

Tournament prestige optimal values (from Table 3):
```
Grand Slams:        φ = 1.0  (normalized reference)
Tour Finals:        φ = 0.94 (search bound [0.9, 1.1]; optimal stayed below Grand Slams)
Masters/WTA 1000:   φ = 0.85 (search bound [0.8, 1.0])
ATP/WTA 500:        φ = 0.69 (search bound [0.2, 0.8])
```
The Tour Finals search bound of [0.9, 1.1] allowed it to exceed Grand Slams, but the
optimal value (0.94) did not. Grand Slams remain the highest-prestige tier.

Surface transferability α matrix (from Table 3, fully asymmetric):
```
αh,g = 0.37   (grass matches → hard graph)
αh,c = 0.01   (clay matches → hard graph)
αc,g = 0.09   (grass matches → clay graph)
αc,h = 0.07   (hard matches → clay graph)
αg,c = 0.05   (clay matches → grass graph)
αg,h = 0.45   (hard matches → grass graph)
```
The matrix is confirmed asymmetric (αh,g ≠ αg,h). The pattern is striking: hard and
grass transfer strongly to each other in both directions (0.37 and 0.45). Clay is
almost informationally isolated — clay matches barely inform the hard graph (0.01) or
grass graph (0.05), and cross-surface transfers into clay are also low (0.07 from hard,
0.09 from grass). This is consistent with clay being a fundamentally different surface
(slower, higher bounce, different player archetypes) where cross-surface form is a
weak signal.

**Training parameters (optimized):**
```
Label smoothing: ε = 0.19  (searched over 0.00–0.20)
```
Optimal ε = 0.19 is at the near-boundary of the search range (max was 0.20). This
suggests the TPE pushed aggressively toward the upper limit — if the bound had been
wider, it might have selected higher. Possible interpretation: outcomes in competitive
premium-tier matches are genuinely very uncertain, and the model benefits from being
prevented from strong convictions almost everywhere.

**Key observations:**

1. *No activation function* reduces MagNet to a linear spectral filter over the magnetic
   Laplacian. The expressive power comes entirely from the complex-valued graph structure
   (directional phase encoding), not from nonlinear feature transformations. This is a
   clean, interpretable architectural choice.

2. *ε near the search boundary* raises the question of whether the search range was
   constraining the optimal. Practically: for replication, use 0.19. For extensions
   (Milestone 7), the label smoothing sensitivity test should include ε = 0.25 as well
   as 0.05 and 0.00 to understand the full curve.

3. *Tour Finals weighting:* The search bound [0.9, 1.1] allowed Tour Finals to exceed
   Grand Slams, but the optimal (0.94) did not go there. Prestige ordering in the
   optimal solution: Grand Slams (1.0) > Tour Finals (0.94) > Masters/WTA1000 (0.85) >
   ATP/WTA500 (0.69). Intuitive and consistent with field size and competitive depth.

4. *Clay isolation is the most interpretable finding in the α matrix.* αh,c = 0.01
   means clay matches are nearly worthless for constructing the hard-court graph — the
   TPE found that cross-surface transfer from clay is essentially noise. Hard ↔ grass
   transfer (0.37 and 0.45) is much stronger, consistent with both being fast surfaces
   where serve-heavy play dominates.

5. *Pareto selection from multi-objective optimization* means ATP and WTA hyperparameters
   are jointly constrained. A single α matrix and single φ schedule applies to both tours'
   six graphs. This is a strong assumption — optimal surface transferability for ATP may
   differ from WTA — but it halves the parameter count and reduces overfitting risk.

6. *No replication gap on α or φ:* All values are stated in Table 3. The full
   parameter set is recoverable directly from the paper without running TPE.

---

## Section 5: Results and Betting Simulation

### 5a. General Predictive Performance

**Overall results (test period Jan 2023 – Jun 2025, N=8,375 matches):**

| Model | Accuracy | Brier |
|-------|----------|-------|
| Standard Elo | 65.7% | 0.215 |
| Angelini WElo | 66.4% | 0.212 |
| Bradley-Terry | — | — |
| MagNet | 65.7% | 0.215 |
| Pinnacle | 69.0% | 0.196 |

MagNet matches Standard Elo exactly on both metrics. WElo is the best non-bookmaker
model. No model beats Pinnacle. This is consistent with the framing from Section 1:
MagNet's contribution is not overall accuracy but structural identification of a
specific subset of mispriced matches.

**Surface/gender breakdown (Table 4):** Columns are Model (MagNet), Elo, WElo, BT, PS.
Underlined values = best non-PS performance per row.

| Gender | Surface | N | MagNet Acc | MagNet Brier | Elo Acc | Elo Brier | WElo Acc | WElo Brier | BT Acc | BT Brier | PS Acc | PS Brier |
|--------|---------|---|-----------|-------------|---------|-----------|----------|------------|--------|----------|--------|----------|
| Men | Clay | 1375 | 0.651 | 0.218 | 0.636 | 0.223 | 0.644 | 0.219 | 0.633 | 0.217 | 0.703 | 0.193 |
| Men | Grass | 374 | 0.674 | **0.195** | 0.693 | 0.201 | **0.709** | 0.197 | 0.655 | 0.207 | 0.722 | 0.176 |
| Men | Hard | 2401 | 0.658 | 0.213 | 0.663 | 0.214 | **0.669** | **0.212** | 0.653 | 0.217 | 0.688 | 0.197 |
| Women | Clay | 1218 | 0.662 | 0.217 | 0.671 | 0.212 | **0.672** | **0.210** | 0.656 | 0.215 | 0.702 | 0.193 |
| Women | Grass | 356 | 0.666 | 0.208 | 0.691 | 0.203 | **0.697** | **0.200** | 0.697 | 0.211 | 0.691 | 0.193 |
| Women | Hard | 2651 | 0.652 | 0.217 | 0.650 | 0.216 | **0.657** | **0.213** | 0.641 | 0.220 | 0.674 | 0.201 |
| Both | All | 8375 | 0.657 | 0.215 | 0.658 | 0.215 | **0.664** | **0.212** | 0.648 | 0.217 | 0.690 | 0.196 |

Key observations from Table 4:
- MagNet is not the best non-PS model on any accuracy cell — WElo wins on most.
  MagNet's only best-non-PS result is Brier on men's grass (0.195 vs. WElo's 0.197).
- MagNet is weakest on men's clay accuracy (65.1%) — notable given clay is the most
  intransitivity-rich surface where the graph model might be expected to have an edge.
- WElo is the consistently dominant non-PS model: best or tied-best on 5 of 6
  surface/gender accuracy cells and 5 of 6 Brier cells.
- BT is weakest overall (64.8%).
- Women's grass is the only cell where PS (69.1%) doesn't clearly dominate accuracy —
  WElo (69.7%) matches or beats it, though PS still wins Brier (0.193 vs. 0.200).

**Calibration:** Paper reports strong calibration via calibration curves with recursive
binning — predicted probabilities closely match observed outcome frequencies. Supports
downstream use of raw model probabilities for Kelly sizing.

---

### 5b. Betting Simulation

**Intransitive complexity metric:**

The paper adapts Hamilton et al. (2024)'s evidence-weighted intransitivity measure.
Two components:

Base intransitivity (Hodge decomposition):
```
I(A_uv) = [1 + ||A_uv - grad∘div(A_uv)||_F] / [1 + ||grad∘div(A_uv)||_F]
```
Hodge decomposition separates a directed graph into its gradient (transitive/rankable)
component and its curl (cyclic/intransitive) component. The numerator captures how much
of the adjacency matrix cannot be explained by a transitive ranking; the denominator
normalizes by the transitive component. I(A_uv) = 1 when perfectly transitive; larger
when more cyclic structure is present.

Evidence-weighted version:
```
I*(A_uv) = I(A_uv) · √(Σ_k α_{s,tk} · β_k · φ_k)
```
The square root term is the total evidence weight accumulated for the player pair —
the same weights used in the dominance score denominator. This prevents high
intransitivity from sparse/noisy H2H records from driving bet selection.
High I* requires both genuine cyclic structure AND sufficient match evidence.

The advantage matrix uses logit-transformed dominance scores within common opponent
neighborhoods — comparing each player's dominance scores against the set of opponents
they have both faced.

**Bet filtering:**
- Threshold γ = 2.55 (optimized on validation period)
- Bet only on matches where I*(A_uv) ≥ γ

**Kelly staking formula:**
```
f* = (p̂ · o - 1) / (o - 1)
```
where p̂ = model match probability, o = decimal odds. Bankroll reset to 1 before
each bet (bets treated as independent).

**Results (test period):**

| Strategy | Threshold | Bets | ROI | Sharpe |
|----------|-----------|------|-----|--------|
| Kelly staking | γ = 2.55 | 1,903 | **3.26%** | 0.61 |
| Unit staking | γ = 2.55 | 2,063 | 1.14% | 0.48 |

Kelly outperforms unit staking — the model's confidence is informative, not just its
direction. 1,903 Kelly bets vs. 2,063 unit bets: Kelly's bankroll-reset rule eliminates
some matches where the edge is present but the Kelly fraction would be negative (i.e.,
the model favors the underdog at a price below fair value).

**Key observations:**

1. *Hodge decomposition is well-established.* It's not a novel metric invented for this
   paper — it's a principled algebraic decomposition of a weighted directed graph into
   its transitive and cyclic parts. The paper adapts it from Hamilton et al. (2024) for
   tennis. Straightforward to implement in Python (scipy or networkx).

2. *Evidence weighting is the critical design choice.* Without the √(Σ weights) term,
   high intransitivity from two or three noisy old matches would trigger bets. The
   evidence weight ensures the intransitivity is meaningfully supported.

3. *γ = 2.55 is tuned on the validation set.* This is a free parameter. The threshold
   selection process (how many candidate γ values were tested, whether ROI or Sharpe
   was the selection criterion) is not stated clearly. This is a potential overfitting
   surface — with enough threshold values tested, a 3.26% ROI on the test set could
   partially reflect multiple testing. Worth examining sensitivity of ROI to γ in
   a ±0.5 band around 2.55.

4. *Bankroll reset to 1 before each bet* is an unusual convention. Standard Kelly
   analysis compounds the bankroll — each win increases stake size for the next bet.
   Resetting to 1 makes each bet independent and keeps the simulation tractable, but
   understates the compounding upside (and downside) of sequential Kelly staking.

5. *Sharpe of 0.61* is modest. For comparison, equity markets target ~0.5 annualized;
   0.61 over 2.5 years of betting is not exceptional. The ROI figure (3.26%) is more
   compelling than the Sharpe.

6. *Open question:* The betting simulation appears to use a single combined threshold γ
   across all surfaces and genders. Whether surface-specific thresholds were considered
   is not stated — clay's lower α transferability values might produce systematically
   different intransitivity distributions than hard or grass.

7. *3.26% ROI is meaningful but thin.* Against Pinnacle (~2% margin), beating the
   closing line by 3.26% on the filtered subset implies ~5% edge above fair value —
   real signal against the sharpest book in the world. Professional sports bettors
   typically target 3–7% ROI, so 3.26% is at the low end of that range, not trivially
   weak. However, the confidence interval is wide (Sharpe 0.61 over 2.5 years), the
   true edge could plausibly be anywhere from ~0% to ~6%, and the γ overfitting concern
   is real. Unit staking at 1.14% is genuinely weak — most of the headline number
   depends on Kelly sizing being correct.

8. *Bet volume is operationally unsustainable at γ = 2.55.* ~1,903 bets over 2.5
   years = ~760/year = ~15/week. Placing 15 tennis bets per week requires reliable
   access to a sharp book accepting tennis action, which is geographically restricted
   in many US jurisdictions. A tighter threshold trades volume for conviction — the
   ROI/volume tradeoff curve (Milestone 8) is the key diagnostic. The right target is
   ≤2–3 high-conviction bets per week (~100–150/year). Key constraints: (a) threshold
   must be selected on validation only — choosing γ by inspecting the test-period ROI
   curve is data snooping; (b) a tighter filter that concentrates on one surface or
   tier may reflect overfitting rather than genuine signal and should be checked.
