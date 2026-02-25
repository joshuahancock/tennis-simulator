# Tennis Modeling Literature Review (Open-Access, 2006–Present)
**Scope:** ATP + WTA; match-level + point-by-point; open-access PDFs / full-text where possible.  
**Purpose:** Inform a **simple Monte Carlo tennis simulator in R**, starting from Newton & Keller (2005) and extending with post-2005 best practices.

---

## 0) Executive summary (what changed after Newton & Keller 2005)

Newton & Keller (2005) popularized a clean hierarchy: **point → game → set → match**, driven by each player’s **probability of winning a point on serve** under an iid assumption.  [oai_citation:0‡Computer and Information Science](https://www.cis.upenn.edu/~bhusnur4/cit592_fall2013/NeKe2005.pdf?utm_source=chatgpt.com)

Post-2005 progress splits into two themes:

1) **Better parameter estimation** (the bigger win):
   - Instead of setting serve-point probability from recent match stats, estimate **latent serve and return skills**, allow **surface effects**, and let skills **evolve over time** (Bayesian hierarchical / dynamic models).  [oai_citation:1‡martiningram.github.io](https://martiningram.github.io/papers/bayes_point_based.pdf?utm_source=chatgpt.com)  
   - Practical alternatives: **Elo / Weighted Elo** and dynamic paired-comparison models, often strong baselines for ATP and WTA forecasting.  [oai_citation:2‡cris.unibo.it](https://cris.unibo.it/bitstream/11585/821483/2/Weighted%20ELO%20rating%20predictions%20in%20tennis.pdf?utm_source=chatgpt.com)

2) **Richer point-by-point / tactical modeling** (especially 2020+):
   - Use point context (serve direction, rally length, etc.) to model **point win probability as a function of features**, not just a constant p-on-serve.  [oai_citation:3‡PLOS](https://journals.plos.org/plosone/article/file?id=10.1371%2Fjournal.pone.0286076&type=printable&utm_source=chatgpt.com)  
   - Emerging tracking/spatial approaches (Hawk-Eye/publicized tracking) address *where* points are won/lost.  [oai_citation:4‡arXiv](https://arxiv.org/abs/2202.00583?utm_source=chatgpt.com)

**Recommended “simple but strong” architecture for your Monte Carlo simulator:**
- Keep Newton–Keller style scoring simulation (it’s correct, interpretable, extensible).  [oai_citation:5‡Computer and Information Science](https://www.cis.upenn.edu/~bhusnur4/cit592_fall2013/NeKe2005.pdf?utm_source=chatgpt.com)  
- Upgrade the inputs:
  - Start with Elo/WElo to estimate matchup strength (match-level).  [oai_citation:6‡cris.unibo.it](https://cris.unibo.it/bitstream/11585/821483/2/Weighted%20ELO%20rating%20predictions%20in%20tennis.pdf?utm_source=chatgpt.com)  
  - Then add serve/return decomposition with time + surface (hierarchical Bayes / dynamic).  [oai_citation:7‡martiningram.github.io](https://martiningram.github.io/papers/bayes_point_based.pdf?utm_source=chatgpt.com)  
- Optionally add point-level features (serve direction, rally length bins, etc.) if you want realism beyond iid points.  [oai_citation:8‡Simon Fraser University](https://www.sfu.ca/~tswartz/papers/tennis1.pdf?utm_source=chatgpt.com)

---

## 1) Data sources you can use today (open + widely used)

### 1.1 Match-level results (ATP + WTA)
- Jeff Sackmann: **ATP match results & stats**  [oai_citation:9‡GitHub](https://github.com/JeffSackmann/tennis_atp?utm_source=chatgpt.com)  
- Jeff Sackmann: **WTA match results & stats**  [oai_citation:10‡GitHub](https://github.com/JeffSackmann/tennis_wta?utm_source=chatgpt.com)  

### 1.2 Point-by-point (sequence) data
- Jeff Sackmann: **tennis_pointbypoint** (sequential point-by-point)  [oai_citation:11‡GitHub](https://github.com/JeffSackmann/tennis_pointbypoint?utm_source=chatgpt.com)  
- Jeff Sackmann: **tennis_slam_pointbypoint** (Grand Slams since ~2011)  [oai_citation:12‡GitHub](https://github.com/JeffSackmann/tennis_slam_pointbypoint?utm_source=chatgpt.com)  

### 1.3 Crowdsourced shot/point charting + derived datasets
- Tennis Abstract / Match Charting Project context (why point-by-point matters; examples and glossary)  [oai_citation:13‡tennisabstract.com](https://www.tennisabstract.com/blog/2017/01/04/new-at-tennis-abstract-point-by-point-stats/?utm_source=chatgpt.com)  
- “Shot-level” derived dataset documentation (built from Match Charting Project)  [oai_citation:14‡data.scorenetwork.org](https://data.scorenetwork.org/tennis/tennis-shot-level-data.html?utm_source=chatgpt.com)  

**Simulator impact:** these sources enable three levels of modeling:
1) match-only (Elo/BT/regression),
2) point-iid (serve/return latent skill → fixed p’s),
3) point-context (p varies by serve direction / rally length / pressure states).

---

## 2) A taxonomy of post-2005 tennis models (what they do, what you can steal)

### A) Point-based hierarchical scoring models (Newton–Keller lineage)
**Idea:** If you know each player’s probability of winning a point on serve (or return), you can compute/simulate games/sets/matches.

- Newton & Keller (2005) remains the canonical starting point.  [oai_citation:15‡Computer and Information Science](https://www.cis.upenn.edu/~bhusnur4/cit592_fall2013/NeKe2005.pdf?utm_source=chatgpt.com)  
- O’Malley (2008) provides formulas and statistical framing for win probabilities under iid points (helpful for validation and sensitivity work). *(Open full text availability varies; commonly circulated.)  [oai_citation:16‡Scribd](https://www.scribd.com/document/353021617/Probability-Formulas-and-Statistical-Analysis-in-Tennis?utm_source=chatgpt.com)*  

**How it improves Monte Carlo:**
- Use exact recursion/formulas as a correctness check for your Monte Carlo engine.
- Focus effort on estimating the serve/return point probabilities.

### B) Hierarchical Markov + common-opponent / shrinkage estimation
**Problem:** Head-to-head is sparse; raw serve-point% is noisy.  
**Solution:** estimate player strength using a large network of opponents.

- Knottenbelt et al. (2012) proposes a **common-opponent hierarchical Markov model** for pre-match prediction.  [oai_citation:17‡ScienceDirect](https://www.sciencedirect.com/science/article/pii/S0898122112002106?utm_source=chatgpt.com)  
- Related academic theses extend hierarchical Markov thinking (useful engineering detail, though not always “canonical” literature).  [oai_citation:18‡Imperial College Documentation](https://www.doc.ic.ac.uk/teaching/distinguished-projects/2012/a.madurska%20.pdf?utm_source=chatgpt.com)  

**Monte Carlo lift:**
- Replace ad-hoc `pServe` with **estimated latent parameters** that generalize to unseen matchups.

### C) Bayesian hierarchical point-based models (serve + return skills evolving over time)
This is the most direct modern upgrade of Newton–Keller, and it stays compatible with Monte Carlo.

- Ingram (paper PDF) proposes a **point-based Bayesian hierarchical model** with:
  - separate **serve and return skill** per player,
  - **surface effects**,
  - **Gaussian random walk** evolution over time,
  - and demonstrated improvements vs older point-based models.  [oai_citation:19‡martiningram.github.io](https://martiningram.github.io/papers/bayes_point_based.pdf?utm_source=chatgpt.com)

**Monte Carlo lift (high):**
- Use posterior draws of player skills to sample match-to-match variability.
- Your sim becomes both predictive and generative (scoreline distributions, uncertainty).

### D) Match-level ratings models (Elo / Weighted Elo / dynamic ability)
Often best raw predictive performance with minimal complexity.

- Angelini et al. (2022) “Weighted Elo” (open PDF via Unibo) incorporates scoreline information into updates.  [oai_citation:20‡cris.unibo.it](https://cris.unibo.it/bitstream/11585/821483/2/Weighted%20ELO%20rating%20predictions%20in%20tennis.pdf?utm_source=chatgpt.com)  
- Vaughan Williams (2020/2021 open PDF) compares odds, rankings, Elo, surface-Elo, and composites for men and women; useful calibration insight for ATP vs WTA differences.  [oai_citation:21‡irep.ntu.ac.uk](https://irep.ntu.ac.uk/id/eprint/42038/1/1400774_Vaughan_Williams.pdf?utm_source=chatgpt.com)  
- Gorgi, Koopman, Lit (2018 open PDF) proposes a **high-dimensional dynamic model** with time-varying player abilities by surface (state-space style).  [oai_citation:22‡papers.tinbergen.nl](https://papers.tinbergen.nl/18009.pdf?utm_source=chatgpt.com)  
- De Angelis & Fontana (2024 SSRN PDF) uses Elo-based tournament simulations for ATP+WTA slams, directly relevant to Monte Carlo tournament simulation design.  [oai_citation:23‡SSRN](https://papers.ssrn.com/sol3/Delivery.cfm/5027380.pdf?abstractid=5027380&mirid=1&utm_source=chatgpt.com)  

**Monte Carlo lift (medium to high):**
- Use Elo/WElo to parameterize matchup strength and then:
  - either simulate match outcomes directly, or
  - convert Elo difference into `pServe`/`pReturn` inputs (hybrid approach).

### E) Benchmarking & “which model wins?”
- Kovalchik (2016 open PDF) benchmarks many approaches and is a key reference for model evaluation methodology and baselines.  [oai_citation:24‡VU Research](https://vuir.vu.edu.au/34652/1/jqas-2015-0059.pdf?utm_source=chatgpt.com)  
- Bunker et al. (2023 open PDF) compares Elo variants and machine learning under a structured prediction framework.  [oai_citation:25‡ResearchGate](https://www.researchgate.net/profile/Rory-Bunker/publication/369595199_A_Comparative_Evaluation_of_Elo_Ratings-_and_Machine_Learning-based_Methods_for_Tennis_Match_Result_Prediction/links/64240d62a1b72772e435fbaa/A-Comparative-Evaluation-of-Elo-Ratings-and-Machine-Learning-based-Methods-for-Tennis-Match-Result-Prediction.pdf?utm_source=chatgpt.com)  

**Monte Carlo lift:**
- Use their evaluation metrics (log loss / Brier / calibration) to validate simulator outputs.

### F) Point-by-point feature models (rally length, serve direction, tactics)
These answer: “which point contexts matter?” and let you move beyond iid points.

- Prieto-Lage et al. (2023 PLOS ONE PDF) models **probability of winning a point** in elite men’s tennis based on key variables (including rally length and surface).  [oai_citation:26‡PLOS](https://journals.plos.org/plosone/article/file?id=10.1371%2Fjournal.pone.0286076&type=printable&utm_source=chatgpt.com)  
- Tea & Swartz (2022 PDF) models **serve direction decisions** with Bayesian hierarchical methods using Roland Garros data and highlights differences between men’s and women’s patterns.  [oai_citation:27‡Simon Fraser University](https://www.sfu.ca/~tswartz/papers/tennis1.pdf?utm_source=chatgpt.com)  
- Fitzpatrick et al. (2024 full text) analyzes Hawk-Eye ball-tracking for serving/returning strategies at Wimbledon (tactical/spatial insight).  [oai_citation:28‡Taylor & Francis Online](https://www.tandfonline.com/doi/full/10.1080/24748668.2023.2291238?utm_source=chatgpt.com)  
- Kovalchik & Albert (2022 arXiv) models return impact location patterns using Bayesian mixture modeling on tracking-derived data.  [oai_citation:29‡arXiv](https://arxiv.org/abs/2202.00583?utm_source=chatgpt.com)  

**Monte Carlo lift (selective):**
- Add a small number of point-context states:
  - first vs second serve,
  - rally length bins,
  - serve direction (T/body/wide),
  - pressure states (break points) if you can derive reliably.
- Let `p(point win)` be `logit^-1( player_skill_terms + context_terms )`, then simulate.

### G) Momentum / non-iid point processes (optional; be careful)
Momentum work is abundant; quality varies. Prefer studies with transparent definitions and validation.

- PLOS ONE (2024) proposes a “momentum chain” style quantification example (open article).  [oai_citation:30‡PLOS](https://journals.plos.org/plosone/article?id=10.1371%2Fjournal.pone.0316542&utm_source=chatgpt.com)  
- Scientific Reports (2024) applies ML to momentum prediction; relevant for feature ideas but treat as an add-on, not the core of a simulator.  [oai_citation:31‡Nature](https://www.nature.com/articles/s41598-024-69876-5?utm_source=chatgpt.com)  

**Monte Carlo lift (risky but sometimes valuable):**
- Implement momentum as a **latent modifier** to point probabilities (small effect size, strong regularization).
- Validate out-of-sample: momentum models can overfit narrative patterns.

---

## 3) Annotated bibliography (open-access core set, post-2005)

Below are papers I recommend as your “backbone reading list” because they (a) are open-access full text / PDF, and (b) map directly to simulator design.

### 3.1 Foundational evaluation & point-based Bayesian upgrade
1) **Kovalchik (2016)** — *Searching for the GOAT of tennis win prediction* (open PDF).  
   - Contribution: systematic benchmark across model families; establishes realistic accuracy ceilings and evaluation methodology.  [oai_citation:32‡VU Research](https://vuir.vu.edu.au/34652/1/jqas-2015-0059.pdf?utm_source=chatgpt.com)  
   - Use: choose baselines, metrics, and sanity checks for your simulator.

2) **Ingram (Bayesian point-based)** — *A point-based Bayesian hierarchical model…* (open PDF).  
   - Contribution: modern point-based model with evolving serve/return skills, surface effects; improves point-based performance.  [oai_citation:33‡martiningram.github.io](https://martiningram.github.io/papers/bayes_point_based.pdf?utm_source=chatgpt.com)  
   - Use: blueprint for estimating matchup point probabilities with uncertainty and time dynamics.

### 3.2 Ratings and tournament simulation (ATP + WTA)
3) **Angelini et al. (2022)** — *Weighted Elo rating for tennis match predictions* (open PDF via Unibo).  
   - Contribution: modifies Elo updates using scoreline info; reports ROI and performance.  [oai_citation:34‡cris.unibo.it](https://cris.unibo.it/bitstream/11585/821483/2/Weighted%20ELO%20rating%20predictions%20in%20tennis.pdf?utm_source=chatgpt.com)  
   - Use: strong match-level engine; can feed Monte Carlo tournament sim.

4) **Vaughan Williams (2020/2021)** — *How well do Elo-based ratings predict professional tennis matches?* (open PDF).  
   - Contribution: compares odds vs rankings vs Elo variants; includes men + women; discusses calibration and weighting.  [oai_citation:35‡irep.ntu.ac.uk](https://irep.ntu.ac.uk/id/eprint/42038/1/1400774_Vaughan_Williams.pdf?utm_source=chatgpt.com)  
   - Use: ATP/WTA differences; how to calibrate probability outputs (important for sims).

5) **De Angelis & Fontana (2024)** — *Monte Carlo meets Wimbledon: Elo-based simulations…* (open SSRN PDF).  
   - Contribution: directly about Monte Carlo tournament simulation using Elo for ATP+WTA slams.  [oai_citation:36‡SSRN](https://papers.ssrn.com/sol3/Delivery.cfm/5027380.pdf?abstractid=5027380&mirid=1&utm_source=chatgpt.com)  
   - Use: practical pipeline for simulating full brackets and comparing to odds.

6) **Gorgi, Koopman, Lit (2018)** — *Analysis and forecasting… high-dimensional dynamic model* (open PDF).  
   - Contribution: dynamic (time-varying) surface-specific abilities; scalable likelihood-based approach.  [oai_citation:37‡papers.tinbergen.nl](https://papers.tinbergen.nl/18009.pdf?utm_source=chatgpt.com)  
   - Use: inspiration if you want a state-space skill evolution model rather than Elo.

### 3.3 Point-by-point feature and tactical models
7) **Tea & Swartz (2022)** — *Serve decisions using Bayesian hierarchical models* (open PDF).  
   - Contribution: models intended serve direction; highlights men vs women differences; leverages public match data.  [oai_citation:38‡Simon Fraser University](https://www.sfu.ca/~tswartz/papers/tennis1.pdf?utm_source=chatgpt.com)  
   - Use: if your simulator models serve direction, this guides priors and feature structure.

8) **Prieto-Lage et al. (2023)** — *Probability of winning a point in elite men’s tennis* (PLOS ONE PDF).  
   - Contribution: interpretable point-level effects (rally length, surface, etc.) tied to point-win probability.  [oai_citation:39‡PLOS](https://journals.plos.org/plosone/article/file?id=10.1371%2Fjournal.pone.0286076&type=printable&utm_source=chatgpt.com)  
   - Use: which simple context bins are worth including; informs non-iid point modeling.

9) **Fitzpatrick et al. (2024)** — *Hawk-Eye ball-tracking serving/returning strategies* (full text).  
   - Contribution: tactical/spatial insights using Hawk-Eye tracking at Wimbledon.  [oai_citation:40‡Taylor & Francis Online](https://www.tandfonline.com/doi/full/10.1080/24748668.2023.2291238?utm_source=chatgpt.com)  
   - Use: conceptual guidance if you later expand to shot placement / spatial simulation.

10) **Kovalchik & Albert (2022)** — *Serve return impact patterns* (arXiv).  
   - Contribution: Bayesian latent style allocation for return impact locations using tracking-derived data.  [oai_citation:41‡arXiv](https://arxiv.org/abs/2202.00583?utm_source=chatgpt.com)  
   - Use: pathway to “style” variables (players cluster into return styles) that can influence point simulation.

### 3.4 Benchmarking Elo vs ML
11) **Bunker et al. (2023)** — comparative evaluation of Elo and ML (open PDF).  
   - Contribution: structured experimental framework; practical insight into when ML helps beyond Elo.  [oai_citation:42‡ResearchGate](https://www.researchgate.net/profile/Rory-Bunker/publication/369595199_A_Comparative_Evaluation_of_Elo_Ratings-_and_Machine_Learning-based_Methods_for_Tennis_Match_Result_Prediction/links/64240d62a1b72772e435fbaa/A-Comparative-Evaluation-of-Elo-Ratings-and-Machine-Learning-based-Methods-for-Tennis-Match-Result-Prediction.pdf?utm_source=chatgpt.com)  
   - Use: decide whether to stay with rating/hierarchical models or add ML.

---

## 4) How to turn this literature into a better Monte Carlo simulator (practical design)

### 4.1 Define your simulator’s “state granularity”
Pick the simplest state that answers your questions:

**Level 1 (match-only):** simulate match outcomes from a win-probability model (Elo/BT).  
- Best for tournament simulation (brackets) and season forecasting.
- Fastest; doesn’t generate realistic scores without extra work.

**Level 2 (point-iid):** simulate points with constant `pServe` for each server (Newton–Keller style).  
- Generates realistic score distributions (sets, tiebreaks, breaks).
- Requires good estimation of `pServe` for each matchup.

**Level 3 (point-context):** simulate with `pServe` varying by context: first/second serve, rally bin, serve direction, pressure.  
- Most realistic but needs point-by-point data and more assumptions.

**Recommended starting point (high ROI):** Level 2 with Level 3 “small add-ons.”

---

## 4.2 A baseline pipeline (do this first)

### Step A — Estimate player strength (ATP + WTA)
Start with Elo/WElo as your “skill backbone.”
- Weighted Elo paper + tools: see WElo literature; the CRAN `welo` package documents practical options.  [oai_citation:43‡cris.unibo.it](https://cris.unibo.it/bitstream/11585/821483/2/Weighted%20ELO%20rating%20predictions%20in%20tennis.pdf?utm_source=chatgpt.com)

**Output:** per player (and optionally per surface) rating `R`.

### Step B — Convert rating difference into point parameters
You need a mapping: `(R_A - R_B) → pServe_A, pServe_B`.

Two workable approaches:

1) **Direct calibration from history:**
   - Fit a regression on historical matches to predict:
     - hold% and break% (or point-win-on-serve%) using rating difference + surface + era.
   - Then convert hold% to point-win-on-serve% using the standard tennis game formulas (or simulation inversion).

2) **Serve/return latent skills (preferred):**
   - Follow Ingram-style structure:
     - each player has serve skill and return skill; matchups combine them.
   - Ratings can initialize priors or act as covariates.  [oai_citation:44‡martiningram.github.io](https://martiningram.github.io/papers/bayes_point_based.pdf?utm_source=chatgpt.com)

**Output:** `pServe(A vs B)`, `pServe(B vs A)` (and optionally first/second serve split).

### Step C — Simulate points → games → sets → match
Use Newton–Keller scoring mechanics as the engine.  [oai_citation:45‡Computer and Information Science](https://www.cis.upenn.edu/~bhusnur4/cit592_fall2013/NeKe2005.pdf?utm_source=chatgpt.com)  
- Validate by checking that Monte Carlo converges to known analytic results for fixed `pServe`.

---

## 4.3 An “incremental realism” roadmap (add these in order)

### Upgrade 1: Surface effects (easy, big payoff)
- Use surface-specific Elo or explicit surface terms in your point-parameter model.  [oai_citation:46‡irep.ntu.ac.uk](https://irep.ntu.ac.uk/id/eprint/42038/1/1400774_Vaughan_Williams.pdf?utm_source=chatgpt.com)

### Upgrade 2: Time dynamics / form (easy to moderate)
- Use recency weighting (Elo naturally does this), or dynamic random-walk skills (Ingram; Gorgi et al.).  [oai_citation:47‡martiningram.github.io](https://martiningram.github.io/papers/bayes_point_based.pdf?utm_source=chatgpt.com)

### Upgrade 3: First vs second serve split (moderate, big realism)
- Maintain `p1Serve` and `p2Serve` as separate parameters per player matchup.
- Can be learned from match stats when available; point-by-point enables richer estimation.

### Upgrade 4: Point-context bins (moderate, choose 1–2)
If you have point-by-point:
- Rally length bin effects: Prieto-Lage shows strong differences by rally length and surface.  [oai_citation:48‡PLOS](https://journals.plos.org/plosone/article/file?id=10.1371%2Fjournal.pone.0286076&type=printable&utm_source=chatgpt.com)  
- Serve direction tendencies: Tea & Swartz provides a Bayesian approach and highlights gender differences.  [oai_citation:49‡Simon Fraser University](https://www.sfu.ca/~tswartz/papers/tennis1.pdf?utm_source=chatgpt.com)  

Implementation tip: keep the model small:
- `logit(pWinPoint) = base + serveSkill(server) - returnSkill(receiver) + surface + (firstServe?) + (rallyBin?) + interactions(optional)`

### Upgrade 5 (optional): Momentum as a latent modifier (high caution)
If you choose to:
- Use a 2–3 state latent process that adds a small delta to `logit(p)`.
- Validate heavily; many “momentum” papers are not robust predictors.  [oai_citation:50‡PLOS](https://journals.plos.org/plosone/article?id=10.1371%2Fjournal.pone.0316542&utm_source=chatgpt.com)

---

## 5) Practical guidance for ATP vs WTA modeling (what the literature implies)

1) **Different serve dominance regimes**
- WTA often has lower hold% and different serve/return patterns, which affects:
  - break frequency,
  - set length distribution,
  - and calibration of Elo-to-probability mappings.
- Vaughan Williams shows performance differences and calibration behavior by tour.  [oai_citation:51‡irep.ntu.ac.uk](https://irep.ntu.ac.uk/id/eprint/42038/1/1400774_Vaughan_Williams.pdf?utm_source=chatgpt.com)  
- Tea & Swartz explicitly compares tendencies between men’s and women’s serve direction behavior (useful if you model direction).  [oai_citation:52‡Simon Fraser University](https://www.sfu.ca/~tswartz/papers/tennis1.pdf?utm_source=chatgpt.com)  

2) **Surface effects may differ by tour**
- Use surface-specific terms rather than assuming ATP effects transfer to WTA.

---

## 6) Suggested “minimum viable literature-backed simulator” (MVLS)

If your goal is a credible simulator quickly:

### MVLS v1 (1–2 weeks of work)
- Data: Sackmann match results for ATP+WTA.  [oai_citation:53‡GitHub](https://github.com/JeffSackmann/tennis_atp?utm_source=chatgpt.com)  
- Model: surface-specific Elo or WElo.  [oai_citation:54‡cris.unibo.it](https://cris.unibo.it/bitstream/11585/821483/2/Weighted%20ELO%20rating%20predictions%20in%20tennis.pdf?utm_source=chatgpt.com)  
- Simulation: match-only tournament Monte Carlo (brackets) + calibration checks.
- Reference implementation pattern: De Angelis & Fontana tournament simulation framing.  [oai_citation:55‡SSRN](https://papers.ssrn.com/sol3/Delivery.cfm/5027380.pdf?abstractid=5027380&mirid=1&utm_source=chatgpt.com)  

### MVLS v2 (2–6 additional weeks)
- Add point-iid scoring engine (Newton–Keller).
- Calibrate `pServe` from Elo + surface + player random effects (or a lightweight Bayesian model).
- Reference: Ingram for serve/return evolution and uncertainty.  [oai_citation:56‡martiningram.github.io](https://martiningram.github.io/papers/bayes_point_based.pdf?utm_source=chatgpt.com)  

### MVLS v3 (later, if desired)
- Add 1–2 point-context bins from point-by-point datasets.
- Reference: Prieto-Lage for rally-length effects; Tea & Swartz for serve direction modeling.  [oai_citation:57‡PLOS](https://journals.plos.org/plosone/article/file?id=10.1371%2Fjournal.pone.0286076&type=printable&utm_source=chatgpt.com)  

---

## 7) What I did *not* include (by design)
- Paywalled-only journal articles without an open PDF.
- Low-quality “momentum” or “80% accuracy” claims without reproducible open methods/data (common in this space).
- Pure coaching/biomechanics studies unless they directly affect point-win probability modeling.

---

## Appendix A — Quick “starter reading order” (if you want the best ROI first)
1) Newton & Keller (2005) — scoring hierarchy baseline  [oai_citation:58‡Computer and Information Science](https://www.cis.upenn.edu/~bhusnur4/cit592_fall2013/NeKe2005.pdf?utm_source=chatgpt.com)  
2) Kovalchik (2016) — model benchmarking mindset  [oai_citation:59‡VU Research](https://vuir.vu.edu.au/34652/1/jqas-2015-0059.pdf?utm_source=chatgpt.com)  
3) Ingram — Bayesian serve/return evolution  [oai_citation:60‡martiningram.github.io](https://martiningram.github.io/papers/bayes_point_based.pdf?utm_source=chatgpt.com)  
4) Vaughan Williams — ATP vs WTA calibration and Elo comparisons  [oai_citation:61‡irep.ntu.ac.uk](https://irep.ntu.ac.uk/id/eprint/42038/1/1400774_Vaughan_Williams.pdf?utm_source=chatgpt.com)  
5) Angelini (WElo) + De Angelis & Fontana — Elo-based simulation pipeline  [oai_citation:62‡cris.unibo.it](https://cris.unibo.it/bitstream/11585/821483/2/Weighted%20ELO%20rating%20predictions%20in%20tennis.pdf?utm_source=chatgpt.com)  
6) Tea & Swartz + Prieto-Lage — point-context features worth modeling  [oai_citation:63‡Simon Fraser University](https://www.sfu.ca/~tswartz/papers/tennis1.pdf?utm_source=chatgpt.com)  

---

