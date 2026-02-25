# Literature Review: Improving Elo Models for Tennis Prediction

**Date:** 2026-02-23
**Purpose:** Survey approaches to enhance Elo-based tennis prediction models

---

## Executive Summary

The literature identifies several promising directions for improving basic Elo:

1. **Bayesian extensions** (Glicko, TrueSkill) — model rating uncertainty explicitly
2. **Weighted Elo** — incorporate margin of victory/scoreline information
3. **Point-based hierarchical models** — separate serve and return skills with time evolution
4. **Surface-specific ratings** — maintain separate Elo by court type
5. **Hybrid ML approaches** — use Elo as a feature in larger models
6. **Graph neural networks** — capture intransitive matchup relationships

The most actionable near-term improvements appear to be:
- Implementing Glicko-2 (adds rating uncertainty)
- Implementing Weighted Elo (adds margin of victory)
- Adopting the Ingram point-based model (separates serve/return skills)

---

## 1. Bayesian Rating Systems

### 1.1 Glicko and Glicko-2

**Source:** [A study of forecasting tennis matches via the Glicko model (PLOS One, 2022)](https://journals.plos.org/plosone/article?id=10.1371/journal.pone.0266838)

The Glicko system (Glickman, 1995) extends Elo with three key innovations:

1. **Rating Deviation (RD):** A standard deviation parameter capturing uncertainty about a player's true skill. Players who haven't competed recently have higher RD.

2. **Time decay:** RD increases over time between matches, reflecting growing uncertainty about inactive players.

3. **Opponent-adjusted updates:** Rating changes account for both the opponent's rating AND their uncertainty.

**Glicko-2** adds a third parameter, **volatility (σ)**, measuring how much a player's rating tends to fluctuate. High-volatility players are more unpredictable.

**Key finding:** "Glicko models have a small edge over other models" because "the Glicko model follows a Bayesian approach and parameters should be updated according to time sequence."

**Implementation:** Available via the `PlayerRatings` R package or Python `glicko2` library.

### 1.2 TrueSkill

**Source:** [TrueSkill: A Bayesian Skill Rating System (Microsoft Research)](https://www.microsoft.com/en-us/research/publication/trueskilltm-a-bayesian-skill-rating-system/)

Microsoft's TrueSkill uses factor graphs and expectation propagation for Bayesian inference:

- Models skill as a Gaussian distribution (mean μ, std dev σ)
- Updates via message passing on factor graphs
- Handles multiplayer and team scenarios naturally
- **TrueSkill 2** (2018) incorporates additional signals: player experience, individual statistics, quitting behavior

**Relevance to tennis:** The core Bayesian framework could be adapted, though TrueSkill was designed for team games. The uncertainty modeling and principled update rules are the key takeaways.

---

## 2. Weighted Elo (WElo)

**Source:** [Angelini & Candila, "Weighted Elo rating for tennis match predictions" (European Journal of Operational Research, 2022)](https://www.sciencedirect.com/science/article/abs/pii/S0377221721003234)

### Core Innovation

Standard Elo treats all wins equally. WElo weights updates by the **margin of victory**:

```
Weight = f(games_won_winner, games_won_loser)
```

A 6-0, 6-0 victory produces a larger rating change than a 7-6, 7-6 victory.

### Implementation

The `welo` R package ([CRAN](https://cran.r-project.org/web/packages/welo/index.html)) provides:

- Games-based or sets-based weighting
- Constant or proportional K-factors
- Grand Slam weighting (higher importance)
- Surface-specific weighting
- Built-in betting simulation functions

### Performance

"The WElo method outperforms all competing methods" across 60,000+ ATP/WTA matches, including standard Elo, bookmaker odds, and other forecasting methods.

**Key insight:** WElo captures "momentum" — recent dominant performances signal continued strong form better than narrow wins.

---

## 3. Point-Based Bayesian Hierarchical Model

**Source:** [Ingram, "A point-based Bayesian hierarchical model to predict the outcome of tennis matches" (JQAS, 2019)](https://martiningram.github.io/papers/bayes_point_based.pdf)

### Model Structure

Instead of modeling match outcomes directly, this approach models the **probability of winning a point on serve**:

```
logit(P_serve) = serve_skill[player] - return_skill[opponent] + surface_effect + tournament_intercept
```

Each player has:
- **Serve skill** (time-varying)
- **Return skill** (time-varying)
- **Surface adjustments** (clay, grass, hard)

### Time Evolution

Skills follow **Gaussian random walks**:
```
skill[t] ~ Normal(skill[t-1], σ_walk)
```

This allows gradual skill changes without requiring explicit "form" variables.

### Key Findings

- Best servers: Karlovic, Raonic, Isner, Federer
- Best returners: Djokovic, Murray, Nadal, Ferrer
- Model outperforms standard Elo and logistic regression baselines
- Provides full posterior distributions for uncertainty quantification

### Implementation

Code available: [GitHub - martiningram/tennis_bayes_point_based](https://github.com/martiningram/tennis_bayes_point_based)

Uses Stan for Bayesian inference.

---

## 4. Dynamic/Adaptive Elo

**Source:** [Ingram, "Tracking the depth and skill of ATP tennis with an adaptive Elo rating"](https://martiningram.github.io/elo-dynamic/)

### Core Innovation

Instead of fixed K-factor, estimate **time-varying K**:

- Higher K → more volatile ratings → less competitive era
- Lower K → more stable ratings → deeper field

### Key Findings

| Era | Estimated K | Interpretation |
|-----|-------------|----------------|
| 1980s | ~31 | Less depth, more volatility |
| 2010s | ~23 | Greater depth, harder to rise |

This explains why modern top players (Djokovic, Federer, Nadal) maintain dominance longer — the competitive field is deeper, making it harder for challengers to accumulate rating points.

### Implementation

Requires Bayesian estimation (Stan model provided) with random walk priors on K and initial player skill.

---

## 5. Surface-Specific Elo

**Source:** [TenElos - Live Tennis Elo Ratings](https://tenelos.com/) and [Berkeley Sports Analytics](https://sportsanalytics.studentorg.berkeley.edu/articles/elo-system-tennis.html)

### Approach

Maintain **four separate Elo ratings** per player:
1. Overall
2. Hard court
3. Clay court
4. Grass court

For predictions, blend:
```
effective_elo = 0.70 × overall + 0.30 × surface_specific
```

### Surface Skill Transfer

Some implementations model how skills transfer between surfaces:
- Clay ↔ Hard: moderate transfer
- Clay ↔ Grass: low transfer
- Hard ↔ Grass: moderate transfer

### Performance

"When tested on matches from 1980-2024, the model correctly predicts approximately 67% of match outcomes on the ATP Tour."

---

## 6. Hybrid Elo + Machine Learning

**Source:** [Bunker et al., "A comparative evaluation of Elo ratings and machine learning methods" (2024)](https://journals.sagepub.com/doi/10.1177/17543371231212235)

### Approach

Use Elo ratings as **features** in larger ML models:

| Model | Features | Accuracy |
|-------|----------|----------|
| Neural Network | Elo + age + surface | 67% |
| SVM | Elo + ranking | 65% |
| Random Forest | Elo + historical stats | 61-66% |
| Logistic Regression | Elo only | 63% |

### Key Finding

"The highest impact on model predictions is provided by ELO rankings" — Elo has the highest odds ratio in logistic models, meaning it's the most predictive single feature.

### Statistical Enhanced Learning (2025)

**Source:** [arXiv:2502.01613](https://arxiv.org/html/2502.01613v2)

Recent work combining Elo with age variables achieves **82% accuracy** on Grand Slam predictions using Random Forest with:
- Elo rating difference
- Age.30 (distance from optimal age 30)
- ATP points difference
- Ranking difference

---

## 7. Graph Neural Networks

**Source:** [Clegg & Cartlidge, "Intransitive Player Dominance and Market Inefficiency" (arXiv, 2025)](https://arxiv.org/html/2510.20454v1)

### The Intransitivity Problem

Elo assumes transitivity: if A > B and B > C, then A > C. But tennis has intransitive matchups due to playing styles:
- Big servers struggle against elite returners
- Counterpunchers trouble aggressive baseliners
- Specific head-to-head dynamics

### Graph Neural Network Approach

1. Build **temporal directed graphs** with players as nodes, matches as weighted edges
2. Edge weights reflect: time decay, surface transferability, tournament prestige, games won ratio
3. Apply **MagNet** (spectral graph convolution with magnetic Laplacian) to preserve directional/cyclic relationships

### Performance

| Model | Accuracy | Brier |
|-------|----------|-------|
| MagNet (GNN) | 65.7% | 0.215 |
| Weighted Elo | 66.5% | 0.212 |
| Bookmaker odds | 69.0% | 0.196 |

**Critical finding:** In high-intransitivity matchups, the GNN's performance gap vs bookmakers "narrowed by 68.3%." A betting simulation achieved **3.26% ROI** targeting these matches.

### Implication

Standard Elo cannot capture intransitive relationships. Graph-based methods or matchup-specific adjustments may exploit market inefficiencies in stylistically complex matchups.

---

## 8. Comparison of Methods

| Method | Complexity | Typical Accuracy | Betting Edge? | Implementation |
|--------|------------|------------------|---------------|----------------|
| Standard Elo | Low | 63-65% | No | Simple formula |
| Surface Elo | Low | 65-67% | Marginal | 4 parallel Elos |
| Glicko-2 | Medium | 65-67% | Unknown | R/Python packages |
| Weighted Elo | Medium | 66-68% | Claimed +ROI | `welo` R package |
| Dynamic K Elo | Medium | 65-67% | Unknown | Stan model |
| Point-based Bayesian | High | 67-69% | Unknown | Stan, custom code |
| Hybrid ML | High | 67-70% | Marginal | sklearn, etc. |
| Graph NN | High | 65-67% | +3.26% ROI* | PyTorch Geometric |

*On high-intransitivity matches only

---

## 9. Recommendations for This Project

### Near-Term (Low Effort, Moderate Impact)

1. **Implement Weighted Elo**
   - Use the `welo` R package directly
   - Weight by games won ratio
   - Compare to current standard Elo

2. **Add Glicko-2 uncertainty**
   - Track rating deviation (RD) per player
   - Use RD to identify "uncertain" matchups where model should be less confident

### Medium-Term (Moderate Effort, Higher Impact)

3. **Implement Ingram's point-based model**
   - Separate serve and return skills
   - Add surface-specific adjustments
   - Model skill evolution over time
   - Provides richer information than single Elo number

4. **Surface-specific Elo with proper blending**
   - Current implementation exists but may need tuning
   - Test different blend ratios (70/30, 80/20, etc.)

### Long-Term (High Effort, Potentially High Impact)

5. **Identify intransitive matchups**
   - Compute "intransitivity score" for each match
   - Focus model on these harder-to-price matches
   - The GNN paper suggests 3.26% ROI is achievable here

6. **Hybrid Elo + ML model**
   - Use Elo (overall + surface) as base features
   - Add: age, recent form, head-to-head, serve stats
   - Train logistic/gradient boosting model
   - Risk: overfitting; need rigorous OOS validation

---

## 10. Key Papers to Read

1. **Angelini & Candila (2022)** — Weighted Elo methodology and profitability
   [ScienceDirect](https://www.sciencedirect.com/science/article/abs/pii/S0377221721003234)

2. **Ingram (2019)** — Point-based Bayesian hierarchical model
   [PDF](https://martiningram.github.io/papers/bayes_point_based.pdf)

3. **Clegg & Cartlidge (2025)** — Graph neural networks and intransitivity
   [arXiv](https://arxiv.org/html/2510.20454v1)

4. **Glickman (1995)** — Original Glicko paper
   [PDF](http://www.glicko.net/glicko/glicko.pdf)

5. **Kovalchik (2016)** — "Searching for the GOAT of tennis win prediction"
   [JQAS](https://www.degruyter.com/document/doi/10.1515/jqas-2015-0059/html)

---

## Sources

- [Bunker et al. (2024) - Elo vs ML comparison](https://journals.sagepub.com/doi/10.1177/17543371231212235)
- [Glicko model study (PLOS One)](https://journals.plos.org/plosone/article?id=10.1371/journal.pone.0266838)
- [Weighted Elo paper (ScienceDirect)](https://www.sciencedirect.com/science/article/abs/pii/S0377221721003234)
- [welo R package (CRAN)](https://cran.r-project.org/web/packages/welo/index.html)
- [Ingram point-based model (JQAS)](https://martiningram.github.io/papers/bayes_point_based.pdf)
- [Ingram dynamic Elo blog](https://martiningram.github.io/elo-dynamic/)
- [Graph NN intransitivity paper (arXiv)](https://arxiv.org/html/2510.20454v1)
- [Statistical enhanced learning (arXiv 2025)](https://arxiv.org/html/2502.01613v2)
- [TrueSkill (Microsoft Research)](https://www.microsoft.com/en-us/research/publication/trueskilltm-a-bayesian-skill-rating-system/)
- [TenElos surface ratings](https://tenelos.com/)
- [Berkeley Elo analysis](https://sportsanalytics.studentorg.berkeley.edu/articles/elo-system-tennis.html)
