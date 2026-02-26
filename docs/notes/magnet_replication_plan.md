# MagNet Replication Plan

**Paper:** Clegg & Cartlidge (2025). "Graph Neural Networks for Tennis Match Prediction."
arXiv:2510.20454v1. https://arxiv.org/html/2510.20454v1

**Goal:** Reproduce the paper's MagNet GNN results on ATP and WTA data, then extend to
the betting simulation (intransitive complexity filter, Kelly staking, ROI evaluation).

**Status:** Planning. Sections 1–4 of paper read; sections 5+ pending.

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

**Open question:** Exact α matrix values (9 values: 3×3 surface pairs) and exact φ
values per tier are not fully specified in the paper — ranges only. Will need to either
re-optimize via TPE or use reasonable defaults and document the deviation.

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

### 3d. Hyperparameter optimization (if needed)

Paper uses TPE (Tree-structured Parzen Estimator) over 300 trials, selecting Pareto-
optimal solution across men's and women's Brier scores. This is expensive. Strategy:

1. **First pass:** use their reported optimal values directly
2. **Only re-optimize if** results diverge meaningfully from paper's reported numbers
3. If re-optimizing, use Optuna (Python TPE library) — 300 trials × 6 graphs ≈ 1,800 training runs

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
| Surface transferability α matrix | Partially specified | Paper gives range 0.01–0.45; exact values unclear |
| Tournament prestige φ values | Partially specified | Range 0.69–0.94; exact tier mapping unclear |
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
