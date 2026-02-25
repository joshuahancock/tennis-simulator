# Overview of Newton & Keller (2005) — *“Probability of Winning at Tennis I. Theory and Data”*

**Citation (informal):** Newton, P. K., & Keller, J. B. (2005). *Probability of Winning at Tennis I. Theory and Data.*  
**PDF:** https://www.cis.upenn.edu/~bhusnur4/cit592_fall2013/NeKe2005.pdf

---

## 1) Purpose and core idea

Newton & Keller (2005) develops a **probability model** for tennis outcomes that propagates from:

> **point → game → set → match → tournament**

The central assumption is that points are **independent and identically distributed (iid)** given each player’s probability of winning a point on serve. Each player has a fixed serve-point win probability:

- `pA`: probability Player A wins a point **on A’s serve**
- `pB`: probability Player B wins a point **on B’s serve**

Under these assumptions, the paper derives formulas (or efficient recursions) for the probability a player wins a game, set, match, and tournament bracket.

---

## 2) Modeling assumptions

### 2.1 iid points
- Each point outcome is a Bernoulli trial.
- Conditional on server identity, the probability of the server winning the point is constant.

### 2.2 Stationary serve probabilities
- `pA` and `pB` do not change with:
  - score,
  - “pressure” situations,
  - momentum,
  - fatigue,
  - ball changes,
  - etc.

### 2.3 Correct tennis scoring rules
The model is built for standard tennis scoring:
- games are “win by 2 points” (including deuce/advantage),
- sets are “win by 2 games,” often with tiebreak at 6–6 (depending on the variant considered),
- matches are best-of-3 or best-of-5 sets,
- tournaments are knockout brackets.

---

## 3) Main theoretical results

### 3.1 Game-winning probability
Given a server’s point-win probability `p` for that game:
- They compute the probability the server wins a **standard advantage game**.
- Key mathematical feature: deuce introduces an infinite continuation possibility, handled via series or recursion.

**Simulator takeaway:** you can compute the exact probability of holding serve from `p`, and use it to sanity-check a point-level Monte Carlo.

---

### 3.2 Set-winning probability (with/without tiebreak)
Using game win probabilities on each player’s serve, they compute the probability a player wins a **set**.

#### Notable finding: set win probability does *not* depend on who serves first
Under the iid model and standard alternation of service, Newton & Keller show that:

> **The probability of winning a set is independent of which player serves first.**

This is a surprising but clean result that follows from the symmetry of service alternation under their assumptions.

**Simulator takeaway:** if your simulation produces a meaningful “served-first advantage” under iid assumptions, something is wrong in the scoring/serve-rotation logic.

---

### 3.3 Match-winning probability (best-of-3 and best-of-5)
Once you can compute set-win probabilities, match-win probabilities follow by enumerating ways to win the required number of sets first:
- Best-of-3: win 2 sets before opponent
- Best-of-5: win 3 sets before opponent

As a consequence of the set result, **match win probability also does not depend on who serves first** (in the iid framework).

**Simulator takeaway:** you can validate your Monte Carlo match engine against closed-form / recursion results.

---

### 3.4 Tournament-winning probability (knockout brackets)
They extend the framework to a full tournament:
- Given a bracket and head-to-head parameters (or player-level `p` values),
- compute each player’s probability of winning the tournament.

They apply this to real draws (e.g., 2002 Wimbledon and 2002 US Open) and compare predicted tournament win probabilities to realized outcomes.

**Simulator takeaway:** this is a direct blueprint for tournament Monte Carlo:
- estimate matchup win probabilities,
- simulate bracket repeatedly,
- compare with analytical propagation where feasible.

---

## 4) Empirical validation (“Theory and Data”)

### 4.1 Parameter estimation from match stats
The authors estimate players’ serve-point probabilities from professional match data:
- e.g., points won on serve / total serve points (or comparable statistics).

They then:
- plug these values into the model,
- produce match/tournament outcome probabilities,
- and evaluate how well predictions align with observed results.

### 4.2 Findings
- The iid serve-probability model (with `pA`, `pB`) performs **surprisingly well** at explaining outcomes for elite matches and tournament progression.
- This supports the model as a **strong baseline** even if it ignores psychology and dynamics.

---

## 5) Discussion of non-iid reality and extensions

Newton & Keller acknowledge that real tennis can violate iid assumptions:
- momentum-like effects,
- pressure effects (break points, set points),
- changing performance over the match,
- etc.

They note that more complex models could allow `p` to vary with:
- score state,
- time,
- previous points,
- or latent “form” variables.

But their contribution is a clean baseline that is:
- mathematically tractable,
- interpretable,
- empirically competitive.

---

## 6) Practical advice for a Monte Carlo tennis simulator (R)

### 6.1 Use the paper as your correctness oracle
If your simulator is point-based (iid):
- simulated match win probability should converge to the theoretical probability derived by recursion/formulas.

### 6.2 Start with the simplest robust inputs
Baseline simulator:
- per player: `pServe` (and optionally `pReturn`, implied by opponent serve)

Upgrade path:
- split into first/second serve,
- add surface-specific `pServe`,
- allow match-to-match random variation in `pServe` (“form”),
- optionally introduce context-dependent `p` for pressure points.

### 6.3 Keep the hierarchy explicit
Implement simulation with clean functions:
- `simulate_point(server)`
- `simulate_game(server)`
- `simulate_set(first_server)`
- `simulate_match(first_server)`
- `simulate_tournament(bracket)`

This mirrors the model structure and makes validation and extension straightforward.

---

## 7) Key contributions (why it matters)

- Provides a unified, point-based framework for predicting:
  - games, sets, matches, and full tournaments.
- Demonstrates a counterintuitive but important fairness property:
  - **serving first does not change set/match win probability** (under iid).
- Shows that a minimal model using only serve-point probabilities can be highly predictive at the professional level.
- Serves as a baseline for later work that improves:
  - parameter estimation (ratings, hierarchical Bayes),
  - and/or relaxes iid assumptions (context, momentum).

---