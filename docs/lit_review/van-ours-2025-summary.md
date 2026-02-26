# van Ours (2025) — Non-transitive patterns in sports match outcomes: a profitable anomaly

**Full citation:** van Ours, J.C. (2025). Non-transitive patterns in sports match outcomes: a profitable anomaly. *Empirical Economics*, 69, 4057–4087. https://doi.org/10.1007/s00181-025-02838-6

**Sport:** Football (English Premier League). **Not tennis.**

---

## 1. Research Questions

Three related questions:

1. Do persistent non-transitive patterns exist in match outcomes among triads of EPL clubs?
2. Do bookmakers incorporate non-transitive patterns when setting odds?
3. Could a simple non-transitive betting strategy have generated consistent profits in hindsight?

The paper is not searching for an optimal betting strategy. Its primary contribution is to the literature on **sports betting market efficiency** — specifically whether bookmakers use all available information when setting odds.

---

## 2. What is Non-Transitivity?

In sports, transitivity is the natural assumption: if team i tends to beat team j, and team j tends to beat team k, then team i should tend to beat team k. Non-transitivity is the violation of this — a rock-paper-scissors cycle where i beats j, j beats k, and k beats i.

Non-transitivity in match outcomes creates a tension for bookmakers between two goals:

- **Efficiency**: using all historical information, including non-transitive patterns, to set accurate prices
- **Consistency**: setting internally coherent/transitive odds across all pairings

The paper argues bookmakers resolve this tension by prioritizing consistency — and that this is the source of the exploitable anomaly.

Prior literature had documented non-transitivity in sports outcomes:
- **Bozóki et al. (2016)**: non-transitive triads among male tennis players (ATP)
- **Temesi et al. (2024)**: non-transitive triads among female tennis players (WTA)
- **van Ours (2024)**: non-transitivity among the top three Dutch football clubs (Feyenoord, PSV, Ajax)

---

## 3. Data

- 25 seasons of EPL football: 2000/01 through 2024/25
- 46 clubs played in the EPL during this period; analysis restricted to the **10 clubs present for at least 22 seasons** (Arsenal, Aston Villa, Chelsea, Everton, Liverpool, Man City, Man United, Newcastle, Tottenham, West Ham)
- 2,090 matches between these 10 clubs over the sample period
- Bookmaker odds: used to compute implied win probabilities and bookmaker margin (B365 odds)
- Includes seasons played behind closed doors (2019/20, 2020/21) due to Covid-19

---

## 4. Key Concepts and Measures

**Balance of wins** between pair (i, j): the number of wins for i against j minus the number of wins for j against i, over all their matches in the sample.

**Expected wins**: implied by bookmaker odds. The expected win probability for the home team in a match with home odds O^h, draw odds O^d, and away odds O^a is:

$$W_{ij}^e = \frac{1/O_{ij}^h}{1/O_{ij}^h + 1/O_{ij}^d + 1/O_{ij}^a} = \frac{1}{O_{ij}^h \cdot (1 + B_{ij})}$$

where B_ij is the bookmaker margin (sum of inverse odds minus one).

**Surprise wins**: actual wins minus expected wins based on odds. A persistent positive balance of surprise wins against a specific opponent means the bookmaker systematically underestimated the probability of winning against that opponent.

**Betting profit** on a £1 bet on team i to beat j:
$$P_{ij} = W_{ij} \cdot (O_{ij} - 1) - (1 - W_{ij}) = W_{ij} \cdot O_{ij} - 1$$

For non-transitive betting on the full triad (betting on i vs j, j vs k, and k vs i):
$$P_{ijk} = S_{ij} \cdot O_{ij} + S_{jk} \cdot O_{jk} + S_{ki} \cdot O_{ki} - \frac{B_{ij}}{1+B_{ij}} - \frac{B_{jk}}{1+B_{jk}} - \frac{B_{ki}}{1+B_{ki}}$$

where S is the average surprise win and O is the average odds.

---

## 5. Empirical Findings

### 5.1 Non-transitive triads in actual wins

With 10 clubs there are 10!/(7!·3!) = 120 unique triads (each unique triad appears twice with opposite signs, so 240 directed triads, of which 120 are unique in terms of magnitude). The paper finds **15 statistically significant non-transitive triads** in actual win balances at the 5% level (one-sided t-test on seasonal averages).

Selected examples (average seasonal balance of wins, with standard errors):

| Triad | i vs j | j vs k | k vs i | Sum | N seasons |
|-------|--------|--------|--------|-----|-----------|
| Man City–Newcastle–Tottenham | 1.14 | 1.56 | 0.63 | 3.42 | 22 |
| Aston Villa–Chelsea–Man United | 0.60 | 0.60 | 0.65 | 1.22 | 22 |
| Aston Villa–Everton–Newcastle | 0.33 | 0.44 | 0.56 | 1.00 | 22 |

The average balance of actual wins in the non-transitive triads ranges from 0.68 to 1.32 per season. Man City and Newcastle appear in seven triads each; Arsenal is not present in any non-transitive triad.

### 5.2 Non-transitivity in surprise wins

Separately, 12 non-transitive triads in **surprise wins** were identified (Table 3b). These are not the same 15 triads — the surprise win triads are the more conservative test because they control for quality differences captured by the bookmaker odds. Crucially, only three of the 12 surprise win triads have any pair with a negative surprise balance, so they are not artifacts of one strong pair dominating.

### 5.3 Bookmakers do not account for non-transitivity

The analysis of expected win balances (based on bookmaker odds) shows that the bookmaker-implied win balance for a triad sums to approximately zero — i.e., the odds are set transitively. Yet the actual win balances sum to significantly positive values. This is the direct evidence that bookmakers ignore non-transitive patterns when pricing matches.

### 5.4 Profitability of non-transitive betting

For the 12 triads with fully positive surprise win balances, Table 4 reports the average annual profit from betting 1 unit on each of the three "non-transitive" legs every season:

- 11 of 12 triads produced positive average profits
- 4 triads were statistically significant at 5–10% (one-sided)
- **Man City–Newcastle–Tottenham**: average annual profit of 3.42 units on 6 units staked — a ~57% return margin
- If bookmaker margins were zero, 7 of 12 triads would be significantly profitable

### 5.5 Non-transitive tetrads and pentads

The paper also identifies:
- **Two non-transitive tetrads** (4-club cycles): Man City–Man United–Newcastle–Tottenham and Aston Villa–Everton–Newcastle–Tottenham
- **One non-transitive pentad** (5-club cycle): Aston Villa–Everton–Newcastle–Tottenham–Man City

The tetrad Man City–Man United–Newcastle–Tottenham generated average profits of 3.22 units per season; adding Man City to the second tetrad to form a pentad produced 4.56 units per season.

---

## 6. Interpretation and Conclusions

**Why do bookmakers not account for non-transitivity?** The paper argues bookmakers face a genuine trade-off: incorporating non-transitive patterns would require setting odds that are internally inconsistent (if i is favored over j and j over k, the odds must imply i is favored over k). This inconsistency would be visible and commercially problematic. Rational bookmakers therefore prioritize consistent odds, leaving non-transitive mispricing on the table.

**Why don't bettors exploit it?** The non-transitive patterns were not obvious ex ante — there were seasons where they did not materialize and bettors would have lost money. It is only in hindsight, over 22+ seasons, that the patterns are significant. The strategy requires knowing which triads are non-transitive (look-ahead bias if done naively) and tolerating substantial year-to-year variance.

**Market efficiency conclusion**: The finding that a rule-based non-transitive betting strategy could have been profitable in hindsight indicates EPL betting markets are not fully efficient in the weak-form sense.

---

## 7. Relevance to Tennis / Our Project

This paper is cited by Clegg & Cartlidge (2025) as prior work establishing non-transitive outcome patterns as a systematic and economically exploitable phenomenon in sports. The connection to graph-based models (MagNet) is that:

- **Elo and Bradley-Terry force transitivity** by construction — they reduce all pairwise relationships to a single scalar rating per player
- **GNNs can capture non-transitive structure** because directed edges encode pairwise outcomes without imposing a global ranking

The football→tennis extension would be methodologically non-trivial (sparsity of head-to-head records, player turnover, surface heterogeneity) but represents a genuine research gap: the bookmaker mispricing angle has not been explored for tennis despite non-transitivity in tennis outcomes being established by Bozóki et al. (2016) and Temesi et al. (2024).

---

## 8. Papers to Track Down

- **Bozóki, S. et al. (2016)**: Documents non-transitivity among male ATP players. Likely the methodological anchor for any tennis extension.
- **Temesi, J. et al. (2024)**: Documents non-transitivity among WTA players.
- **van Ours, J.C. (2024)**: Earlier paper on non-transitivity among Feyenoord, PSV, Ajax in Dutch football — precursor to this paper.
