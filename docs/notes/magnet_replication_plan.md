# MagNet Replication Plan

**Paper:** Clegg & Cartlidge (2025). "Graph Neural Networks for Tennis Match Prediction."
arXiv:2510.20454v1. https://arxiv.org/html/2510.20454v1

**Goal:** Reproduce the paper's MagNet GNN results on ATP and WTA data, then extend to
the betting simulation (intransitive complexity filter, Kelly staking, ROI evaluation).

**Status:** Planning. Sections 1–4.3 of paper read; sections 4.4+ pending.

---

## Target Results to Replicate

From the paper (test set: Jan 2023 – Jun 2025, premium tier):

| Model | ATP Accuracy | WTA Accuracy | ATP Brier | WTA Brier |
|-------|-------------|-------------|-----------|-----------|
| Standard Elo | 65.7% | 67.8% | 0.215 | 0.208 |
| Angelini WElo | 66.4% | 67.1% | 0.212 | 0.211 |
| MagNet | 65.7% | 67.0% | 0.215 | 0.207 |
| Pinnacle odds | 69.0% | 70.4% | 0.196 | 0.190 |

**Betting simulation target:** 3.26% ROI with Kelly staking over 1,903 bets, achieved
by filtering to matches with high intransitive complexity.

---

## Architecture Overview

The pipeline has four stages:

```
[R] Data preparation
        ↓
[Python] Graph construction (dominance scores → directed edges)
        ↓
[Python] MagNet training + walk-forward prediction
        ↓
[R] Evaluation + betting simulation
```

The R→Python handoff is a CSV export of match-level data. Python→R handoff is a CSV
of match-level predictions with predicted set-win probability and match-win probability.

---

## Phase 1: Data Preparation (R)

**Status:** Largely complete. Gaps noted below.

### 1a. Match data
- Source: tennis-data.co.uk (same as our Elo work)
- Scope: Jan 2014 – Jun 2025, ATP + WTA, premium tier (Grand Slam, tour finals,
  Masters 1000, ATP/WTA 500)
- We have: 17,644 ATP matches (2014–Nov 2025), ~16,000 WTA matches
- Filter to paper's end date (Jun 8, 2025) to match their N exactly
- Output: match-level CSV with date, players, surface, tournament tier, games won,
  Pinnacle odds

### 1b. Player attributes
- Source: paper uses tennisexplorer.com; **check Sackmann first**
  - `atp_players.csv` and `wta_players.csv` in Sackmann's tennis_atp/tennis_wta repos
    have: player_id, name, hand, dob, country, height
  - Weight may be missing — impute gender-specific median if so
  - Handedness encoding: R=0, L=1, U=unknown (impute median)
- Output: player-level CSV with height, weight (or imputed), dob, hand

### 1c. Temporal split
- Validation: Aug 29, 2019 – Nov 20, 2022 (hyperparameter tuning)
- Test: Jan 1, 2023 – Jun 8, 2025 (evaluation)
- Training history: Jan 1, 2014 – Aug 28, 2019 (initial graph construction)

### 1d. Export format for Python
```
match_data.csv:
  match_id, date, tournament, tier, surface, round, best_of,
  player_i, player_j, winner (i or j),
  games_i, games_j, sets_i, sets_j,
  ps_odds_i, ps_odds_j

player_data.csv:
  player_id, name, hand, dob, height_cm, weight_kg, gender
```

---

## Phase 2: Graph Construction (Python)

### 2a. Environment setup
```
python >= 3.10
torch >= 2.0
torch-geometric (includes MagNetConv)
numpy, pandas, scipy
```

### 2b. Dominance score computation

For each player pair (u, v) on surface s, at prediction time n:

```
D^s_n(u,v) = Σ_k [α(s, s_k) · β_k · φ_k · g_k(u,v)]
             ───────────────────────────────────────────
             Σ_k [α(s, s_k) · β_k · φ_k]
```

Where:
- `g_k(u,v)` = games won by u / total games in match k (WElo games proportion)
- `α(s, s_k)` = surface transferability: weight of match on surface s_k for target surface s
  - Same surface: α = 1.0
  - Cross-surface: optimized values in range 0.01–0.45 (paper, Section 4.4)
- `β_k` = time decay: exp(-λ · Δt_k) where λ=0.38, Δt_k = days since match k
- `φ_k` = tournament prestige: values 0.69–0.94 by tier (Grand Slam highest)

**Edge direction rule:**
- D > 0.5 → directed edge u → v, weight = D
- D < 0.5 → directed edge v → u, weight = 1 - D
- D = 0.5 → no edge
- Each pair contributes at most one directed edge

**Note on α and φ values:** The paper reports ranges (α: 0.01–0.45, φ: 0.69–0.94)
rather than exact values. These are tuned as part of the standard TPE hyperparameter
optimization (Phase 3d) — not a gap, just part of the search. The diagonal of α is
fixed at 1.0 (same-surface matches always fully informative); the 3 off-diagonal values
(hard↔clay, hard↔grass, clay↔grass) are free parameters. If the matrix is asymmetric
(clay→hard may differ from hard→clay), that's 6 free parameters.

### 2c. Node features

Per player per surface graph, ℓ₂-normalized:
- height_cm (static)
- weight_kg (static)
- age at prediction time = (prediction_date - dob) / 365.25 (dynamic)
- is_lefthanded: 0/1 (static)
- surface_in_degree: number of distinct players who have a directed edge pointing TO this player
- surface_out_degree: number of distinct players this player has a directed edge TO

### 2d. Temporal graph snapshots

The graph is rebuilt at each **tournament round** snapshot:
1. At prediction time for a given round, include all matches before that round
2. One snapshot = one set of predictions for all matches in that round
3. Retrain model every ~38 snapshots (approximately quarterly)

This is more granular than our Elo walk-forward (which is match-by-match) but coarser
than rebuilding at every single match.

---

## Phase 3: MagNet Training (Python)

### 3a. MagNet architecture (PyTorch Geometric)

```python
from torch_geometric.nn import MagNetConv

# Reported optimal hyperparameters (Section 4.4):
q = 0.25          # directional sensitivity (fixed at max)
K = 2             # Chebyshev filter order
hidden = 64       # hidden units
layers = 2        # GNN layers → 4-hop receptive field
dropout = 0.3
lr = 0.003
weight_decay = 1e-4
label_smoothing = 0.19  # cross-entropy loss parameter
```

### 3b. Training procedure

Walk-forward:
1. Build initial graph from Jan 2014 – Aug 2019 (earliest 85% of history at validation start)
2. Train on most recent 15% of edges as labeled examples
3. Predict next tournament round snapshot
4. Observe true outcomes, update graph
5. Retrain every ~38 snapshots
6. Advance training window

**Loss:** Cross-entropy with label smoothing = 0.19 (reduces overconfidence)

### 3c. Output

MagNet outputs a **set-win probability** p̂(u,v). Convert to match probability:

- Best-of-3: P̂₃ = p̂² + 2p̂²(1-p̂) = p̂²(3 - 2p̂)
- Best-of-5: P̂₅ = p̂³ + 3p̂³(1-p̂) + 6p̂³(1-p̂)²

(Assumes sets are i.i.d. — same independence assumption as standard point-based models)

### 3d. Hyperparameter optimization

TPE is a first-class part of the replication, not a fallback. We will need to re-optimize
whenever we change the model, extend the data window, or test variants (e.g., label
smoothing sensitivity, walk-forward design). Set it up properly from the start so it
can be invoked at will.

**Implementation:**
- Library: Optuna (Python) with TPE sampler
- Objective: multi-objective — minimize Brier score for ATP and WTA separately
- Selection: Pareto-optimal solution with favorable ATP/WTA trade-off
- Trials: 300 (paper's number; can reduce for quick exploratory runs)
- Search space (from Table 3):
  ```python
  # Architecture
  K        ∈ {1, 2, 3}
  layers   ∈ {1, 2, 3}
  hidden   ∈ {32, 64, 128}
  use_act  ∈ {True, False}
  epsilon  ∈ [0.00, 0.20]   # label smoothing

  # Graph construction
  lambda_  ∈ [0.0, 0.5]    # time decay
  alpha_hg ∈ [0.0, 0.5]    # surface transferability (6 off-diagonal entries)
  alpha_hc ∈ [0.0, 0.5]
  alpha_cg ∈ [0.0, 0.5]
  alpha_ch ∈ [0.0, 0.5]
  alpha_gc ∈ [0.0, 0.5]
  alpha_gh ∈ [0.0, 0.5]
  phi_1000   ∈ [0.8, 1.0]  # tournament prestige
  phi_finals ∈ [0.9, 1.1]
  phi_500    ∈ [0.2, 0.8]
  ```
- Validation window: Aug 29, 2019 – Nov 20, 2022 (same as paper)

**Paper's reported optimal values (Table 3) — use as starting point and sanity check:**
```
K=2, layers=2, hidden=64, activation=False, ε=0.19
λ=0.38
α: h,g=0.37  h,c=0.01  c,g=0.09  c,h=0.07  g,c=0.05  g,h=0.45
φ: 1000=0.85  Finals=0.94  500=0.69
```

**When to re-optimize:**
- Baseline replication (verify we recover values close to paper's)
- Extended data window (post-Jun 2025 data changes graph density)
- Label smoothing sensitivity tests (Milestone 7) — fix architecture, re-optimize α/φ/λ
- Any structural change to graph construction or training procedure

---

## Phase 4: Evaluation (R)

Import Python-generated predictions CSV back into R for evaluation alongside our Elo baselines.

### 4a. Standard evaluation

Match paper's reported metrics:
- Accuracy (% correct)
- Brier score
- Log-loss

By: overall, per surface, per gender, per year

### 4b. Betting simulation

This is the paper's main result. Requires understanding Section 5 (not yet read).

Known from Section 1:
- Filter to matches with "high intransitive complexity"
- Kelly staking with some fraction
- 1,903 bets, 3.26% ROI against Pinnacle closing lines

**Open questions (to be resolved when we read Section 5):**
- How is "intransitive complexity" operationalized/measured?
- What Kelly fraction?
- Is there a minimum edge threshold?
- How are ties/incomplete matches handled?

---

## Known Gaps and Open Questions

| Item | Status | Notes |
|------|--------|-------|
| Player weight data | Unknown | Sackmann may not have weight; may need imputation |
| Surface transferability α matrix | Not a gap | Tuned via TPE jointly with other hyperparameters |
| Tournament prestige φ values | Not a gap | Tuned via TPE; range 0.69–0.94 gives search bounds |
| Intransitive complexity metric | Unread | Defined in Section 5 |
| Betting simulation details | Unread | Defined in Section 5 |
| Exact validation/test split dates | Specified | Aug 29 2019 / Jan 1 2023 / Jun 8 2025 |
| PyTorch Geometric MagNetConv API | Not yet checked | May need version-specific implementation |

---

## Milestones

### Milestone 1: Data pipeline complete
- [ ] Verify Sackmann player attribute coverage (hand, dob, height)
- [ ] Build `match_data.csv` and `player_data.csv` exports from R
- [ ] Confirm ATP match count matches paper (~16,663 at Jun 2025 cutoff)

### Milestone 2: Graph construction validated
- [ ] Python environment with PyTorch Geometric installed
- [ ] Dominance score computation implemented and spot-checked
- [ ] Six surface graphs constructed (ATP: hard/clay/grass, WTA: hard/clay/grass)
- [ ] Node features assembled and normalized

### Milestone 3: MagNet baseline
- [ ] Walk-forward training loop implemented
- [ ] Predictions generated for test period (Jan 2023 – Jun 2025)
- [ ] Accuracy and Brier evaluated against paper's reported numbers
- [ ] If > 1pp gap: investigate; if within 1pp: accept

### Milestone 4: Betting simulation
- [ ] Read and implement Section 5 (intransitive complexity filter)
- [ ] Kelly staking simulation
- [ ] ROI comparison to paper's 3.26%

### Milestone 6: Walk-forward training diagnostics
- [ ] Track accuracy and Brier by snapshot number across test period (Jan 2023 – Jun 2025)
      — flat/improving → fine-tuning working; strong improvement → initial sparse training
      locked in suboptimal weights that quarterly updates don't fully escape
- [ ] "Fresh retrain at test period start" variant: freeze graph at Jan 2023, train from
      random initialization for 150 epochs, compare vs. paper's incrementally updated model
      on identical test matches
- [ ] If fresh retrain wins materially: walk-forward fine-tuning is a computational
      convenience, not an accuracy-optimal design

### Milestone 7: Label smoothing sensitivity (ROI extension)
- [ ] Retrain with reduced label smoothing (ε = 0.05) and no smoothing (ε = 0)
- [ ] Compare ROI on intransitive subset: does sharper confidence → larger Kelly bets → better ROI?
- [ ] Compare global Brier score tradeoff vs. ROI gain
- [ ] Hypothesis: ε = 0.19 suppresses model confidence exactly in high-signal intransitive matches;
      lower ε should improve betting ROI at the cost of worse global calibration

### Milestone 8: Tighter intransitivity filter (bet volume reduction)
The paper's γ = 2.55 threshold produces ~1,903 bets over 2.5 years (~760/year, ~15/week).
This volume is not operationally sustainable — placing 15 bets per week requires access
to a sharp book that accepts tennis action, which is geographically restricted in many
US states. The goal here is to find a tighter threshold that preserves or improves ROI
while reducing bet volume to something actionable (target: ≤2–3 bets/week, ~100–150/year).

- [ ] Plot ROI and bet count as a function of γ across a range (e.g., γ ∈ [2.0, 5.0])
      using the test period — identify the ROI/volume trade-off curve
- [ ] Identify a "high conviction" threshold where ROI is meaningfully higher even if
      total profit in absolute terms is lower
- [ ] Check whether the tighter filter skews toward particular surfaces, genders, or
      tournament tiers — a filter that concentrates on one surface may be overfitting
- [ ] Re-run γ optimization on validation set with bet volume as an explicit constraint
      (e.g., maximize ROI subject to ≤ N bets/year)
- [ ] Note: tightening γ post-hoc on the test set is data snooping; the volume-constrained
      optimization must be done on validation only

### Milestone 9: Alternative betting filters

The MathSport paper used a favourite-only Kelly filter (bet only when p̂ > 0.5) and
achieved 7.66% ROI on 1,074 bets. The arXiv paper replaced this with an intransitivity
filter (I* ≥ 2.55) and achieved 3.26% ROI on 1,903 bets. The "optimized" filter
produced lower ROI than the unoptimized one. This warrants a systematic comparison
of filter approaches on the same model and test period.

- [ ] Replicate MathSport favourite-Kelly filter on the arXiv paper's model and test
      period — does the simpler filter outperform the intransitivity filter on identical
      predictions?
- [ ] Combine filters: intransitivity I* ≥ γ AND favourite (p̂ > 0.5) — the MathSport
      paper's calibration concerns motivated favourites-only; if the arXiv model is
      better calibrated (ε = 0.19 label smoothing), does the combination add value or
      just reduce volume?
- [ ] Surface-specific filters: MathSport paper showed clay ROI ≈ 0% and grass/hard
      ROI > 10%. Test whether filtering to grass and hard only (dropping clay entirely)
      improves ROI in the arXiv paper as it did in the MathSport paper.
- [ ] Edge threshold filter: bet only when |p̂ − p_implied| exceeds some minimum —
      distinct from intransitivity filter, focuses on raw model-market disagreement
      regardless of graph structure.
- [ ] All filter comparisons must use validation-set-only threshold selection; test-set
      ROI curves are for reporting only, not selection.

### Milestone 5: WTA extension
- [ ] Run full pipeline for WTA
- [ ] Joint evaluation (ATP + WTA combined)

---

## Files

| File | Purpose |
|------|---------|
| `src/data/tennis_data_loader.R` | Match data loading (exists) |
| `scripts/export_for_magnet.R` | Export CSVs for Python (to build) |
| `src/models/magnet/graph_construction.py` | Dominance score + graph building (to build) |
| `src/models/magnet/train.py` | MagNet training loop (to build) |
| `src/models/magnet/predict.py` | Walk-forward prediction (to build) |
| `analysis/model_variants/magnet_evaluation.R` | Import predictions + evaluate (to build) |
