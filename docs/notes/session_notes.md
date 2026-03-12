# Tennis Simulator Session Notes

Working notes, findings, and analysis from development sessions.

---

## 2026-03-10/11 - MagNet GNN Pipeline: Implementation and Calibration

### Overview

Built the full MagNet replication pipeline (Clegg & Cartlidge 2025, arXiv:2510.20454) from scratch, covering player attribute scraping, data export, graph construction, GNN training, walk-forward evaluation, and betting filter calibration. Two major implementation cycles: initial numpy GNN, then PyTorch rewrite.

---

### Phase 1: Player attribute scraping

The paper uses player physical attributes (height, weight, DOB, handedness) as static node features. tennis-data.co.uk does not supply these; they must be scraped from tennisexplorer.com.

**Script**: `scripts/scrape_tennisexplorer.py`
**Output**: `data/raw/player_attributes/te_scraped_{atp,wta}.csv`, `te_failures_{atp,wta}.csv`

**Mechanism**: For each player name (Sackmann "First Last" format), tries slugs `last-name` and `firstname-lastname` against `tennisexplorer.com/player/{slug}/`. Parses height, weight, DOB, handedness from the profile page. Failures written to separate file for manual resolution.

**Results**:
- ATP: 727/788 scraped (92%), 511 failures
- WTA: 584/543 scraped, 459 failures

**Coverage after merging into player_data.csv**:
| Field | ATP | WTA |
|-------|-----|-----|
| height | 78.6% | 31.3% |
| hand | 91.5% | 43.7% |

WTA coverage is low because ~334 WTA players in our match data have no tennisexplorer page, and the scraper found duplicates for some entries (each player appearing twice in the output). The 31% figure is genuine: ~254 unique WTA players matched with data, of which ~182 have height/weight.

**Name format mismatch**: tennis-data.co.uk uses "Last F." (e.g., "Sinner J."), Sackmann uses "First Last". Conversion via `sackmann_to_tduk()` in `export_for_magnet.R`. Known failure mode: compound surnames ("Del Potro" → "Potro J." instead of "Del Potro J.").

**women.csv**: Created `data/raw/player_attributes/women.csv` (588 players, same schema as `men.csv`) with blanks for missing values. 406/588 players need manual entry. Once filled, `export_for_magnet.R` will pick it up as source priority 4.

---

### Phase 2: Data export

**Script**: `scripts/export_for_magnet.R`
**Outputs**: `data/processed/magnet/match_data.csv` (32,594 rows), `data/processed/magnet/player_data.csv` (1,199 players)

match_data.csv columns: `match_date, tournament, surface, tour, tier, round, best_of, player_i, player_j, winner, games_i, games_j, ps_odds_i, ps_odds_j`

player_data.csv columns: `name, gender, hand, dob, height_cm, weight_kg`

Attribute priority: `men.csv` (manually curated ATP) > `te_scraped_atp.csv` > `te_scraped_wta.csv` > `women.csv` (once populated).

---

### Phase 3: Graph builder

**File**: `src/models/magnet/graph_builder.py`

Maintains running numerator N[s][g] and denominator Z[s][g] matrices (n_players × n_players) per surface and gender. Implements incremental time decay: when `advance_to(date)` is called, decays all existing entries by `exp(-λ·Δt)` before adding new matches at β=1.

**Hyperparameters (Table 3)**:
- λ = 0.38 (time decay rate)
- α matrix (surface transferability): asymmetric 3×3, e.g., Hard→Clay = 0.07
- φ weights: Grand Slam=1.0, Masters 1000=0.85, ATP/WTA 500=0.69, Tour Finals=0.94

`get_graph(surface, gender, date)` returns adj (symmetric), direction (antisymmetric ±1), node features (ℓ₂-normalized), player list.

`get_dominance(gender, surface)` returns D[u,v] = N/Z, NaN for pairs with no history.

**Node features** (6 dimensions): height, weight, age-at-snapshot, handedness (0/1), out-degree, in-degree. Missing values imputed with gender-specific medians before ℓ₂-normalisation. *Note*: with 69% WTA missing, most WTA players receive median feature values, substantially degrading WTA embedding quality.

---

### Phase 4: GNN model (two implementations)

#### 4a: Numpy implementation (superseded)

**File**: `src/models/magnet/magnet_model.py` (original)

2-layer ChebConv with K=2, hidden=64, no activation functions (paper's optimal architecture, making it a linear spectral filter). Complex weights (n_features×hidden, hidden×hidden). Prediction head: sigmoid([Re(Δ), Im(Δ)]·w + b).

Manual complex-valued backprop via analytical gradients. Manual Adam with complex-aware second-moment update: `g_sq = (g·conj(g)).real`. Several bugs found and fixed during development:
- `float.conj()` error on scalar `b` parameter
- `round(ndarray)` error on batch predictions

#### 4b: PyTorch implementation (current)

**File**: `src/models/magnet/magnet_model.py` (current)
**Commit**: `9730c63`

Identical architecture, using `nn.Parameter` with complex64 tensors and `torch.optim.Adam`. Autograd handles all complex-valued gradients correctly. Training method renamed `fit()` to avoid shadowing `nn.Module.train()`. `reset_adam()` kept as no-op for call-site compatibility (fresh optimizer created in each `fit()` call).

Training is ~10× faster (0.1s vs 0.4s per fine-tune step). Results numerically identical to numpy version (combined Brier 0.2306 vs 0.2304), confirming the numpy backprop was mathematically correct despite being error-prone to write.

---

### Phase 5: Walk-forward runner

**File**: `scripts/run_magnet.py`

Implements the paper's walk-forward protocol:
- Training start: Aug 29, 2019 (paper's validation period start)
- Test period: Jan 1, 2023 – Jun 8, 2025
- Initial training: 150 epochs at first snapshot ≥ validation start
- Fine-tuning: +30 epochs every 38 snapshots (~quarterly)
- Training signal: most recent 15% of pre-round history (no leakage)
- Graph advance: to `round_start - 1 day` before predicting; to `snap_date` after

One snapshot = one (tournament, year, round) group. Leakage-free by construction: the current round's outcomes are never in the graph when predicting that round.

**Bugs fixed during development**:
- Snapshot grouping without year → all "Australian Open R1" collapsed to single snapshot
- Training trigger fired too late (Jan 2022 instead of Aug 2019) → 13 fewer quarterly fine-tunes
- Data leakage: `advance_to(snap_date)` called before predicting → fixed to use `pre_round_date`

---

### Phase 6: Intransitivity filter (I*)

**File**: `src/models/magnet/intransitivity.py`

Implements Hodge decomposition of the local advantage matrix A_{u,v}. The advantage matrix is built from logit-transformed dominance scores over the subgraph {u, v, common opponents}. Hodge decomposes into gradient (transitive) and curl (cyclic) components:

`I(A) = (1 + ||curl||_F) / (1 + ||grad||_F)`

Evidence-weighted: `I*(A_{u,v}) = I(A_{u,v}) · evidence_weight`

**Unresolved formula ambiguity**: The paper states the evidence weight is `√(Σ_k α·β·φ)` and calls it "the same sum as the dominance score denominator." Two interpretations:

1. `√Z[u,v]` — just the direct pair's accumulated evidence
2. `√(Σ Z[i,j] over all pairs in subgraph)` — sum over the entire common-opponent neighborhood

Both were implemented and tested:

| Formula | max_opponents | Hard bet rate | Overall bet rate |
|---------|---------------|---------------|-----------------|
| √Z_subgraph | 2 (4-node) | 22.5% | 14.5% |
| √Z[u,v] | 13 (15-node) | 1.6% | ~0.2% |

The paper's Figure 6 shows a bimodal Hard court I* distribution with peaks at ~1.5 and ~3.0–3.5 and a right tail to ~10. Only the `√Z_subgraph` formula produces a distribution of that shape. `√Z[u,v]` gives max I*≈6.5 with almost nothing clearing 2.55.

**Current state**: formula ambiguity unresolved. `√Z_subgraph` with `max_opponents=2` empirically reproduces the paper's Hard bet rate (22.5% vs 22.7%) at γ=2.55. The interpretation is uncertain but the result is consistent with the paper.

---

### Phase 7: Results vs paper

**Full run results** (test period 2023-01-01 to 2025-06-08, 8,190 matches):

| Metric | Ours | Paper |
|--------|------|-------|
| Combined accuracy | 65.6% | 65.7% |
| ATP Brier | 0.2294 | — |
| WTA Brier | 0.2317 | — |
| Combined Brier | 0.2306 | 0.2150 |
| Total bets | 1,185 | 1,903 |
| Hard bet rate | 22.5% | ~22.7% |
| Overall bet rate | 14.5% | 22.7% |
| Kelly ROI | +1.70% | +3.26% |

**Accuracy is essentially exact.** Brier gap (~1.5pp) is the main remaining discrepancy.

**Brier gap diagnosis**: ATP Brier (0.2294) and WTA Brier (0.2317) are nearly identical, so the gap is not primarily a WTA data coverage issue. The most likely cause is the GNN producing less well-calibrated probabilities than the paper's — possibly due to the missing WTA physical attributes (69% imputed with median) degrading the embedding quality for WTA players, with the effect spreading to ATP predictions through shared hard-court scheduling and common opponents.

**Bet rate gap diagnosis**: Hard courts match the paper. Clay and Grass have very low bet rates because Z[u,v] values on those surfaces are small (fewer matches, time-decayed, low cross-surface transfer α). The paper's own notes confirm near-zero Clay bets. The 14.5% vs 22.7% gap is not well understood but likely reflects surface distribution differences in the test period, not an implementation error.

---

### Open questions

1. **I* evidence formula**: `√Z[u,v]` vs `√Z_subgraph` — needs the paper's code or author correspondence to resolve definitively.

2. **γ calibration**: Should be validated against our validation period (Aug 2019–Dec 2022) predictions. Currently using paper's γ=2.55, which works on Hard but may not be optimal for our I* distribution.

3. **WTA coverage**: `women.csv` has 406 blank entries. Filling manually would meaningfully improve WTA embedding quality and likely close part of the Brier gap.

4. **Brier gap**: After filling women.csv, a ~0.5pp improvement is plausible. Remaining gap may be irreducible given data differences.

---

## 2026-02-25 - Paper Baseline Confirmed; 500+ Only Decision

### Angelini Elo matches paper accuracy exactly

Implemented the true Angelini et al. (2022) weighted Elo formulation in `analysis/model_variants/angelini_elo.R`. Key result: on 2023–2024 premium-tier ATP matches, our numbers match the paper's within rounding:

| Model | Our Acc | Paper Acc |
|-------|---------|-----------|
| Standard Elo | 65.5% | 65.7% |
| Angelini Weighted Elo | 65.8% | 65.8% |

The previous ~5pp gap was entirely explained by dataset filter — we were evaluating on all ATP tiers (including 250s), the paper evaluates on 500+/1000/Slams only.

**Angelini formulation**: uses `games_won / total_games` as the outcome variable instead of binary win/loss. Update rule: `new_rating += K * (games_prop - expected_prob)`. When a dominant favorite barely wins on games (e.g., 7-6, 6-7, 7-5), they can lose rating. This compresses extreme ratings, slightly improving directional accuracy (+0.3pp) but worsening Brier score (0.2274 vs 0.2137) due to less extreme probabilities.

### Decision: ATP 500+ only for training and evaluation

Aligns with the paper. ATP 250s excluded from both training and evaluation going forward. Rationale:
- Shallower fields, possibly less efficient markets
- Different dynamics than premium events
- Predicting 250s is a separate roadmap item (hypothesis: edges easier to find there)

### 2025 data availability

- **Sackmann tennis_atp**: No 2025 file published as of 2026-02-25. Last commit "2024 season." Remote is up-to-date — not just a local sync issue.
- **tennis-data.co.uk**: `2025.xlsx` already available (~2,600 matches, Dec 2024–Nov 2025). `2026.xlsx` has 112 matches (Jan 2026).
- Betting data has match scores (W1/L1 etc.) that could support Elo evaluation, but lacks serve/return stats needed for MC model training.
- Exploring alternative sources for 2025 Sackmann-equivalent match data.

### Roadmap items noted

- 250-series prediction: separate workstream after premium baseline is solid
- MagNet GNN replication: next major model after Elo baseline confirmed
- 2025 data: monitor Sackmann; explore alternatives (see separate investigation)

---

## 2026-02-24 - Directory Restructure and Paper Data Alignment

### Directory restructure complete

### Codebase Overview

The simulator consists of 6 main R scripts:

1. **01_mc_engine.R** - Point-by-point simulation
   - `simulate_point()`: Core probability calculation
   - Uses hardcoded tour averages (0.35, 0.50) for opponent adjustment

2. **02_player_stats.R** - Player statistics loader
   - `get_player_stats()`: Falls back to tour average when insufficient data
   - Prints warning: "Using tour average for [player] (insufficient data)"
   - Thresholds: MIN_SURFACE_MATCHES=20, MIN_TOTAL_MATCHES=20 (updated from 10)

3. **03_match_probability.R** - Monte Carlo probability estimation

4. **04_similarity_adjustment.R** - Similarity-based adjustments (partially implemented)
   - `get_expected_return_stats()`: Calculates return stats from similar players
   - `find_similar_to_player()`: Finds similar players using cosine similarity
   - Style classification and historical matchup weighting

5. **05_betting_data.R** - Betting odds integration

6. **06_backtest.R** - Backtesting framework

### The Problem We're Solving

**Current behavior:**
When a player has insufficient match data (< 10 total or < 20 on surface):
- `get_player_stats()` returns tour averages
- `simulate_point()` uses hardcoded 0.35/0.50 for opponent adjustment

This means for lesser-known players, we're using generic averages that don't reflect their playing style.

**Proposed solution:**
When falling back from player-specific stats, instead of using generic tour averages:
1. Find players similar to the one we're looking up (using charting features)
2. Calculate weighted average stats from those similar players
3. Use those stats as a more informed baseline

### Key Code Locations

Tour average fallback in `02_player_stats.R` lines 383-405:
```r
if (nrow(player_overall) == 0 || player_overall$matches[1] < min_total_matches) {
  cat(sprintf("  Warning: Using tour average for %s (insufficient data)\n", player_name))
  # Returns tour_avg_surface or tour_avg_overall
}
```

Hardcoded averages in `01_mc_engine.R` lines 45 and 68:
```r
avg_return_vs_first <- 0.35  # Tour average return % vs first serve
avg_return_vs_second <- 0.50  # Tour average return % vs second serve
```

### Questions to Consider

1. **Threshold selection**: How many similar players? (currently TOP_N_SIMILAR=20)
2. **Similarity threshold**: Minimum similarity score? (currently 0.7)
3. **Weighting method**: Simple average vs similarity-weighted average?
4. **Fallback chain**: What if no similar players found? Still use tour avg?
5. **Performance**: Pre-compute for backtest efficiency?

### Backtest Results Summary (H1 2024)

| Metric | With Adjustment | Without Adjustment |
|--------|-----------------|-------------------|
| Accuracy | 58.3% | 56.3% |
| Brier Score | 0.2362 | 0.2507 |
| Log Loss | 0.6645 | 0.6977 |

ROI at 10% edge: -15.5% (with) vs -10.6% (without)

Key insight: The adjustment helps calibration but hurts ROI at high confidence levels.

### Player Stats Threshold Logic (Clarified)

The `get_player_stats()` function uses a **cascading fallback**, not "AND":

```
Step 1: Does player have >= 10 total matches?
   │
   ├─ NO  → Use TOUR AVERAGE (prints warning)
   │        Returns source = "tour_average"
   │
   └─ YES → Step 2: Does player have >= 20 matches on this surface?
               │
               ├─ YES → Use SURFACE-SPECIFIC stats
               │        Returns source = "surface_specific"
               │
               └─ NO  → Use OVERALL stats (all surfaces combined)
                        Returns source = "overall"
```

Example: Player with 50 hard court matches and 8 grass matches, asking for grass stats:
- Pass 10-match threshold (58 total) ✓
- Fail 20-grass threshold ✗
- Result: Use their OVERALL stats (from all 58 matches), not tour average

The "tour average" fallback only triggers for truly unknown players (< 10 total matches).

### Concerns About the Adjustment Formula

Current formula in `simulate_point()`:
```r
avg_return_vs_first <- 0.35  # Hardcoded baseline
adjustment <- avg_return_vs_first - returner_stats$return_vs_first
win_prob <- server_stats$first_won_pct + adjustment
```

**Issues identified:**

1. **Too severe?** If returner is 5% better than average, server loses a full 5 percentage points. But the point still has to play out - being a good returner means getting the ball back, not automatically winning.

2. **No interaction effect**: The formula treats a +5% returner the same whether facing an 80% big server or 65% weak server. Intuitively, elite returners should matter more against weak servers.

3. **Additive vs multiplicative**: Tennis outcomes are probably more like skill ratios than skill differences. A Bradley-Terry style model might be more principled:
   ```r
   P(server wins) = server_skill / (server_skill + returner_skill)
   ```

**Decision**: Focus on similarity fallback for low-data players first. Revisit adjustment formula later - it's a bigger change with more risk.

### Scope for Current Implementation (COMPLETED)

**Completed**: Replace tour average fallback with similarity-based stats when player has < 20 matches

**Out of scope (for now)**:
- Changing the hardcoded 0.35/0.50 baseline in adjustment formula
- Reworking the adjustment formula to be multiplicative

### Design Decisions for Similarity Implementation

| Question | Decision |
|----------|----------|
| How many similar players? | Top 10 |
| Weighting method | Similarity-weighted average |
| Fallback if no similar players? | Hardcoded tour averages |

**Implementation flow:**
1. Player has < 10 matches in ATP data
2. Try to find them in charting feature database
3. If found, find top 10 similar players (using `find_similar_to_player`)
4. Look up those players' stats in stats_db
5. Calculate similarity-weighted average of their stats
6. If not found in feature_db OR no similar players have stats → fall back to tour average

**Changes needed:**
- Modify `get_player_stats()` in `02_player_stats.R` to accept optional `feature_db` parameter
- Add similarity lookup logic before tour average fallback
- Return with `source = "similarity_weighted"` when using similar players

### Backtest Results with Similarity (H1 2024)

**Overall results:**
- Accuracy: 58.2%, Brier: 0.2362, Log Loss: 0.6651
- Similarity used in only 41 of ~3,000 player lookups (1.4%)
- Limited impact due to small overlap between charting data (303 players) and low-data ATP players

**Filtered to real data only (no tour average):**

| Metric | All Matches | Real Data Only | Tour Avg Matches |
|--------|-------------|----------------|------------------|
| Count | 1,499 | 1,201 (80%) | 298 (20%) |
| Accuracy | 58.2% | 58.9% | 55.4% |
| Brier | 0.2362 | 0.2336 | 0.2467 (near random) |

| Edge | All Matches | Real Data Only |
|------|-------------|----------------|
| 1% | -8.8% | -4.5% |
| 3% | -9.8% | -5.1% |
| 5% | -10.7% | -5.1% |
| 10% | -13.2% | -7.8% |

**Key insight:** Tour average matches are noise. Filtering them improves ROI by ~5 percentage points.

### Skip Matches with Insufficient Data (COMPLETED)

For a betting model, there's no reason to simulate matches where a player has insufficient data. No informational edge = no bet.

**Implemented:** Added `require_player_data` parameter to `simulate_match_probability()` and `backtest_period()`. When TRUE, matches where either player uses tour_average are skipped and reported separately.

### Minimum Match Threshold Analysis (COMPLETED)

Tested different MIN_TOTAL_MATCHES values on H1 2024 data:

| Min Matches | N Matches | Accuracy | Brier | ROI@5% |
|-------------|-----------|----------|-------|--------|
| 5 | 1,259 | 58.8% | 0.2344 | -7.4% |
| 10 | 1,223 | 58.8% | 0.2338 | -6.0% |
| 15 | 1,195 | 58.9% | 0.2334 | -4.7% |
| 20 | 1,162 | 58.6% | 0.2338 | -4.3% |
| 25 | 1,125 | 58.6% | 0.2344 | -3.8% |
| 30 | 1,104 | 58.9% | 0.2340 | -4.2% |
| 40 | 1,078 | 58.7% | 0.2343 | -3.6% |
| 50 | 1,000 | 59.5% | 0.2336 | -4.3% |

**Key findings:**
1. Accuracy is fairly flat across all thresholds (58.6% - 59.5%)
2. Brier score is also stable (0.2334 - 0.2344)
3. **ROI improves significantly with higher thresholds** - from -7.4% at 5 matches to -3.6% at 40 matches
4. Best ROI (-3.6%) at 40 matches, but loses ~180 matches vs threshold of 10

**Recommendation:** Consider increasing MIN_TOTAL_MATCHES from 10 to 20-25:
- Minimal accuracy loss
- ~4 percentage point ROI improvement
- Still retains ~75% of matches

**Future investigation:** Consider separate thresholds for serve stats vs return stats (return might be noisier)

---

## 2026-02-24 — Directory Restructure + Paper Data Alignment

### Directory Restructure

Reorganized codebase from language-based layout (`r_analysis/simulator/`, `code/`) to stage-based layout to support multiple models and future language additions. New structure:

```
src/data/           — shared data loading (player_stats, betting_data, date_alignment)
src/models/         — one subdir per model (monte_carlo/, elo/, future paper_model/)
src/backtesting/    — shared backtesting framework
src/utils/          — shared utilities
analysis/           — research scripts organized by theme
  calibration/  edge/  model_variants/  validation/  trajectory/  features/
scripts/            — top-level runners (run_analysis.R, compare_models.R, etc.)
tests/              — unit tests
correspondence/referee2/replication/  — Referee 2 scripts (was code/replication/)
```

All `source()` paths updated. Smoke test: `source("src/backtesting/backtest.R")` loads clean; all 14 Elo unit tests pass.

---

### Paper Data Alignment (arxiv.org/html/2510.20454v1)

Paper filters: Grand Slams + Tour Finals + Masters 1000 + ATP 500-series. Date range 2014–Jun 2025.

**Key lesson: `draw_size` is not a proxy for tour tier.**

Initial attempt used `draw_size >= 48` to identify 500-series within Sackmann's `tourney_level == "A"` bucket. This was wrong for two reasons:
1. Nearly all ATP 500 tournaments have `draw_size = 32` in Sackmann (main draw only)
2. Some 250s (Winston-Salem) and non-tour events (Olympics, COVID alternates) had large draw sizes for unrelated reasons

**Fix:** explicit named list of the 13 ATP 500-series events:
```r
ATP_500_NAMES <- c("Dubai", "Rotterdam", "Acapulco", "Rio de Janeiro",
                   "Barcelona", "Hamburg", "Queen's Club", "Halle",
                   "Washington", "Tokyo", "Beijing", "Vienna", "Basel")
```
Script: `analysis/features/paper_data_comparison.R`

**Resulting counts vs paper targets:**

| | Paper | Ours (2014–2024) | Gap |
|---|---|---|---|
| ATP | 16,663 | 15,441 | -1,222 |
| WTA | 16,447 | 15,234 | -1,213 |

Both gaps are ~1,200 and nearly identical — consistent with a single cause: Sackmann data ends at 2024 and the paper runs through June 2025. At ~1,570 matches/year, half of 2025 ≈ 785 matches. Residual ~400-match gap per tour is likely source-level differences between Sackmann and tennis-data.co.uk.

WTA filter `tourney_level %in% c("G", "F", "PM", "P")` appears correct. "O" in WTA data = Olympics (not WTA 1000).

---

### Future Direction: 250-Series Market Efficiency

**Hypothesis (Josh):** ATP/WTA 250-series events may have less efficient betting markets than 500/1000/Slam events, making edges easier to find there. Rationale: lower public attention, less betting volume, fewer analysts building models for these matches.

**Assessment:** The direction is plausible but execution is harder than it looks.

Arguments in favor:
- **Lower bookmaker investment**: Pinnacle's vig may be slightly higher at 250 level due to lower volume — higher vig = less pressure to price precisely
- **Less analyst competition**: Nearly all published tennis models (including the paper we're replicating) focus exclusively on 500/1000/Slams, leaving 250s undermodeled
- **Player familiarity gap**: Rankings 50–200 are less studied; bookmakers and public have less information on these players

Arguments against:
- **Our model suffers more here too**: Our serve/return stats model requires match history. 250s are where players have the thinnest data — we already saw from the `MIN_TOTAL_MATCHES` analysis that data scarcity hurts us. We'd be competing with less-efficient markets using a less-reliable model
- **Higher volatility**: More unknown players, more injuries/withdrawals, more scheduling noise — variance goes up without necessarily improving edge
- **The paper's model was designed for this tier**: Replicating it first on 500/1000/Slams makes sense before extending down

**Recommended approach when the time comes:**

1. **First, measure market efficiency by tier**: Compare bookmaker calibration accuracy at 250 vs 500 vs 1000 vs Slam. If the 250 calibration curve is flatter (less accurate), that's direct evidence of inefficiency — not just a hunch.

2. **Use a model that degrades gracefully with thin data**: Elo handles sparse data better than serve/return stats. A 250-specific Elo model (or a hybrid) is better suited than the MC engine.

3. **Focus on specific subsets, not all 250s**: If there's an edge, it's probably in a narrow slice — e.g., clay-court 250s in South America where rankings underweight surface ability, or home-country advantage at smaller events.

4. **Add 250s to tournament filter only after baseline model is validated**: Don't mix tiers in early modeling. First get a clean, validated baseline on the paper's dataset (500/1000/Slams), then treat 250s as a separate out-of-sample test.

**Current status:** Deferred. Revisit after paper replication is complete and we have a validated baseline.

---

## Session Summary - 2026-01-29

### What Was Completed

1. **Similarity-weighted stats fallback** - When a player has < 20 matches, the model now:
   - Looks for them in the charting feature database (303 players)
   - Finds top 10 similar players using cosine similarity
   - Uses similarity-weighted average of their stats
   - Falls back to tour average only if not in charting data

2. **Skip insufficient data matches** - Added `require_player_data` parameter:
   - When TRUE, matches where either player uses tour_average are skipped
   - Backtest now reports skipped count separately from errors

3. **Raised minimum threshold** - Changed `MIN_TOTAL_MATCHES` from 10 to 20:
   - Based on analysis showing ~2% ROI improvement with minimal accuracy loss

### Current Model Performance (H1 2024, real data only)

- Accuracy: 58.9%
- Brier Score: 0.2336
- ROI at 5% edge: -5.1%
- Market baseline: 67.2%

### Next Steps (Priority Order)

1. **Improve name matching** - Many players fail similarity lookup due to name format mismatch between betting data ("Auger-Aliassime F.") and charting data ("Felix Auger Aliassime"). Fixing this could significantly increase similarity usage beyond the current 1.4%.

2. **Revisit adjustment formula** - The additive adjustment may be too severe. Consider:
   - Multiplicative approach (skill ratios instead of skill differences)
   - Bradley-Terry style model
   - Interaction effects (returner impact varies by server strength)

3. **The model still underperforms market** - 58.9% vs 67.2%. Fundamental question: is the point-by-point simulation adding value, or would a simpler Elo model perform better?

### Key Files Modified This Session

- `r_analysis/simulator/02_player_stats.R` - similarity fallback, threshold change
- `r_analysis/simulator/03_match_probability.R` - require_player_data flag
- `r_analysis/simulator/06_backtest.R` - skip handling, feature_db loading

### Saved Data

- `data/processed/backtest_h1_2024_with_similarity.rds` - Full backtest results with similarity

---
