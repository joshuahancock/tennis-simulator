"""
intransitivity.py — Hodge decomposition and intransitive complexity metric I*.

Implements Eq. 3 from Clegg & Cartlidge (2025):

    I(A_uv) = [1 + ||A_uv − grad∘div(A_uv)||_F] / [1 + ||grad∘div(A_uv)||_F]

where A_uv is the logit-transformed advantage matrix for the subgraph of u, v,
and their common opponents.

Evidence-weighted version:

    I*(A_uv) = I(A_uv) · √(Σ_k α_{s,tk} · β_k · φ_k)

The √(Σ weights) term is the square root of the sum of weights in the dominance
score denominator for the pair (u, v) — an evidence budget that prevents noisy
sparse H2H records from triggering bets.

Reference: Hamilton et al. (2024) for the Hodge decomposition formulation;
adapted by Clegg & Cartlidge (2025).
"""

import numpy as np
from typing import Optional, Tuple


# ============================================================================
# Hodge decomposition
# ============================================================================

def hodge_gradient_component(A: np.ndarray) -> np.ndarray:
    """
    Compute the gradient component of the Hodge decomposition for the advantage
    matrix A (n × n, possibly with NaN for missing pairs).

    The gradient component G satisfies G[i,j] = φ[i] − φ[j], where φ is the
    solution to the graph Laplacian least-squares system:
        L·φ = b
        L[i,i] = Σ_{j≠i} w[i,j]   (degree)
        L[i,j] = -w[i,j]           (off-diagonal)
        b[i]   = Σ_j A[i,j] · w[i,j]

    Only edges (i,j) where both A[i,j] and A[j,i] are non-NaN are included
    (i.e., the pair has H2H history).

    Returns G : (n × n) antisymmetric gradient component.
    """
    n = A.shape[0]
    mask = ~np.isnan(A)  # True where edge exists

    # Build symmetric weight matrix (1 where edge in either direction)
    W = ((mask & mask.T) & ~np.eye(n, dtype=bool)).astype(float)

    if W.sum() == 0:
        return np.zeros((n, n), dtype=float)

    # Laplacian
    deg = W.sum(axis=1)
    L = np.diag(deg) - W

    # Flow vector (antisymmetric): use A directly.
    # When A is logit-transformed (as passed from base_intransitivity), it is
    # already antisymmetric and centred at 0 (logit(0.5) = 0).
    F = np.where(mask & mask.T, A, 0.0)

    # RHS: b[i] = Σ_j F[i,j] * W[i,j]  (divergence of the flow)
    b = (F * W).sum(axis=1)

    # Solve L·φ = b in least-squares sense (L is singular — add small regularisation)
    L_reg = L + 1e-10 * np.eye(n)
    phi, *_ = np.linalg.lstsq(L_reg, b, rcond=None)

    # Gradient component G[i,j] = φ[i] - φ[j] where edge exists
    G = np.zeros((n, n), dtype=float)
    for i in range(n):
        for j in range(n):
            if W[i, j] > 0:
                G[i, j] = phi[i] - phi[j]

    return G


def base_intransitivity(A: np.ndarray) -> float:
    """
    Compute I(A_uv) for a local advantage matrix A (n × n, NaN for missing pairs).

    Returns I ≥ 0.  Large when the subgraph is highly intransitive (much curl),
    small when mostly transitive (gradient explains most of the flow).
    """
    # Logit-transform the dominance scores:
    #   A[i,j] ∈ (0,1) → logit(A[i,j]) ∈ (-∞, +∞)
    # logit(0.5) = 0 (neutral), logit is antisymmetric: logit(p) = -logit(1-p)
    # Missing pairs remain NaN.
    with np.errstate(divide="ignore", invalid="ignore"):
        A_logit = np.where(
            ~np.isnan(A),
            np.log(np.clip(A, 1e-9, 1 - 1e-9) / (1 - np.clip(A, 1e-9, 1 - 1e-9))),
            np.nan,
        )

    G = hodge_gradient_component(A_logit)

    mask = ~np.isnan(A_logit)
    A_vals = np.where(mask & mask.T, A_logit, 0.0)

    curl = A_vals - G               # residual (curl) component
    norm_curl = np.linalg.norm(curl)
    norm_grad = np.linalg.norm(G)

    return (1.0 + norm_curl) / (1.0 + norm_grad)


# ============================================================================
# Evidence weight
# ============================================================================

def subgraph_evidence(
    Z: np.ndarray,
    nodes: list,
    u_idx: int = 0,
    v_idx: int = 1,
    formula: str = "subgraph_sum",
) -> float:
    """
    Return the evidence weight for I* scaling.

    formula options
    ---------------
    "subgraph_sum"  (default) √(Σ Z[i,j] over all distinct pairs in subgraph)
    "pair_only"     √(Z[u,v] + Z[v,u]) — direct pair evidence only
    "linear"        Σ Z[i,j] over all distinct pairs (no sqrt)

    NOTE: the paper formula states the evidence weight is √(Σ_k α·β·φ) and
    describes it as "the same sum as the dominance score denominator for (u,v)",
    suggesting "pair_only". However, "pair_only" produces I* values far too
    small for γ=2.55 to yield the paper's 22.5% bet rate. "subgraph_sum"
    reproduces the bet rate at γ=2.55. The correct interpretation is unresolved.
    """
    u_global = nodes[u_idx]
    v_global = nodes[v_idx]

    if formula == "pair_only":
        total = Z[u_global, v_global] + Z[v_global, u_global]
        return float(np.sqrt(max(total, 0.0)))
    elif formula == "linear":
        total = 0.0
        for a in range(len(nodes)):
            for b in range(a + 1, len(nodes)):
                total += Z[nodes[a], nodes[b]]
        return float(max(total, 0.0))
    elif formula == "subgraph_sum":
        total = 0.0
        for a in range(len(nodes)):
            for b in range(a + 1, len(nodes)):
                total += Z[nodes[a], nodes[b]]
        return float(np.sqrt(max(total, 0.0)))
    else:
        raise ValueError(f"Unknown evidence formula: {formula!r}. "
                         f"Expected 'subgraph_sum', 'pair_only', or 'linear'.")


# ============================================================================
# I* computation
# ============================================================================

def compute_istar(
    u: int,
    v: int,
    D: np.ndarray,
    Z: np.ndarray,
    max_opponents: int = 2,
    evidence_formula: str = "subgraph_sum",
    h2h_require_both: bool = False,
    opponent_selection: str = "top_z_sum",
) -> float:
    """
    Compute I*(A_{u,v}) for match (u, v).

    Parameters
    ----------
    u, v               : player indices
    D                  : (n, n) dominance matrix — D[u,v] ∈ (0,1) or NaN if no H2H
    Z                  : (n, n) denominator weight matrix
    max_opponents      : max common opponents in subgraph (default 2)
    evidence_formula   : "subgraph_sum" | "pair_only" | "linear" (see subgraph_evidence)
    h2h_require_both   : if True, a player k is a common opponent only when D[u,k]
                         and D[k,u] are BOTH non-NaN (and same for v); default False
                         uses one-directional (either direction suffices)
    opponent_selection : "top_z_sum" — rank by Z[u,k]+Z[v,k] (default)
                         "top_z_min" — rank by min(Z[u,k], Z[v,k]) (bottleneck)

    Returns
    -------
    I* ≥ 0 (0 if pair has no H2H history)
    """
    # No H2H history → I* = 0
    if np.isnan(D[u, v]) and np.isnan(D[v, u]):
        return 0.0

    # Find common opponents
    if h2h_require_both:
        has_uv = ~np.isnan(D[u, :]) & ~np.isnan(D[:, u])
        has_vu = ~np.isnan(D[v, :]) & ~np.isnan(D[:, v])
    else:
        has_uv = ~np.isnan(D[u, :]) | ~np.isnan(D[:, u])
        has_vu = ~np.isnan(D[v, :]) | ~np.isnan(D[:, v])

    common = np.where(has_uv & has_vu)[0]
    common = common[common != u]
    common = common[common != v]

    # Limit subgraph size
    if len(common) > max_opponents:
        if opponent_selection == "top_z_min":
            scores = np.minimum(Z[u, common], Z[v, common])
        else:  # "top_z_sum"
            scores = Z[u, common] + Z[v, common]
        common = common[np.argsort(-scores)[:max_opponents]]

    # Build local node set: [u, v] + common opponents
    nodes = np.array([u, v] + sorted(common.tolist()))
    local_n = len(nodes)

    # Build local advantage matrix (NaN for missing pairs)
    A_local = np.full((local_n, local_n), np.nan)
    for gi, ni in enumerate(nodes):
        for gj, nj in enumerate(nodes):
            if gi == gj:
                continue
            d = D[ni, nj]
            if not np.isnan(d):
                A_local[gi, gj] = d

    I  = base_intransitivity(A_local)
    ev = subgraph_evidence(Z, nodes.tolist(), u_idx=0, v_idx=1,
                           formula=evidence_formula)

    return I * ev


# ============================================================================
# Batch computation for a match list
# ============================================================================

def compute_istar_batch(
    match_indices: np.ndarray,
    D: np.ndarray,
    Z: np.ndarray,
    max_opponents: int = 2,
    evidence_formula: str = "subgraph_sum",
    h2h_require_both: bool = False,
    opponent_selection: str = "top_z_sum",
) -> np.ndarray:
    """
    Compute I* for a batch of matches.

    Parameters
    ----------
    match_indices : (m, 2) int array of (i, j) player index pairs
    D, Z          : dominance and evidence matrices from GraphBuilder

    Returns
    -------
    istar : (m,) float array
    """
    m = len(match_indices)
    istar = np.zeros(m, dtype=float)
    for k, (u, v) in enumerate(match_indices):
        istar[k] = compute_istar(int(u), int(v), D, Z, max_opponents,
                                 evidence_formula, h2h_require_both,
                                 opponent_selection)
    return istar


# ============================================================================
# Betting filter
# ============================================================================

GAMMA_DEFAULT = 2.55   # optimal threshold from validation (Table 3)


def kelly_fraction(p_model: float, decimal_odds: float) -> float:
    """
    Kelly fraction: f* = (p · o - 1) / (o - 1)
    Returns 0 if negative edge.
    """
    if decimal_odds <= 1.0:
        return 0.0
    f = (p_model * decimal_odds - 1.0) / (decimal_odds - 1.0)
    return max(0.0, float(f))


def should_bet(
    istar: float,
    p_model: float,
    decimal_odds: float,
    gamma: float = GAMMA_DEFAULT,
) -> bool:
    """
    Returns True if this match passes both the intransitivity filter AND has
    a positive Kelly fraction (positive expected edge).
    """
    return istar >= gamma and kelly_fraction(p_model, decimal_odds) > 0
