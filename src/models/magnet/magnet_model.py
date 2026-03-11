"""
magnet_model.py — MagNet spectral GNN (numpy implementation).

The MagNet model uses the Magnetic Laplacian L^(q) as the convolution operator
in a 2-layer Chebyshev spectral GNN with no nonlinear activation functions.

    L^(q) = D - exp(i·2π·q·Θ) ⊙ A

where:
    D    diagonal degree matrix
    A    symmetric adjacency (edge weights ≥ 0.5, from GraphBuilder.get_graph)
    Θ    antisymmetric phase matrix (Θ[u,v] = +1 if u→v, -1 if v→u, 0 otherwise)
    q    charge parameter = 0.25 (fixed)
    ⊙    element-wise product

Architecture (K=2 Chebyshev filter, L=2 layers, hidden_dim=64, no activation):
    Z1 = [T̃₀X, T̃₁X, T̃₂X] · W1       (n × hidden_dim, complex)
    Z2 = [T̃₀Z1, T̃₁Z1, T̃₂Z1] · W2     (n × hidden_dim, complex)
    logit(i beats j) = Re[Z2[i]-Z2[j], Z2[j]-Z2[i]] · w + b
    p(i beats j) = σ(logit)

Training:
    Loss: cross-entropy with label smoothing ε = 0.19
    Optimizer: Adam, lr=0.003, weight_decay=1e-4
    Epochs: 150 (initial), +30 (quarterly fine-tune)

Reference: Clegg & Cartlidge (2025), arXiv:2510.20454, Section 4.2 and 4.4.
"""

import numpy as np
from typing import List, Optional, Tuple


# ============================================================================
# Hyperparameters
# ============================================================================

Q         = 0.25   # magnetic charge
HIDDEN    = 64     # hidden dimension per layer
K_CHEB    = 2      # Chebyshev filter order
N_LAYERS  = 2      # number of conv layers

LR        = 0.003
WD        = 1e-4   # weight decay (L2 regularization)
EPS_SMOOTH = 0.19  # label smoothing


# ============================================================================
# Magnetic Laplacian
# ============================================================================

def magnetic_laplacian(
    adj: np.ndarray, direction: np.ndarray, q: float = Q
) -> np.ndarray:
    """
    Compute the magnetic Laplacian L^(q) for a directed graph.

    Parameters
    ----------
    adj       : (n, n) symmetric float array, A[u,v] = edge weight (≥ 0.5 if edge exists)
    direction : (n, n) antisymmetric float array, Θ[u,v] ∈ {-1, 0, +1}
    q         : charge parameter (default 0.25)

    Returns
    -------
    L : (n, n) complex Hermitian matrix
    """
    n = adj.shape[0]
    # Degree matrix: row sums of A
    deg = adj.sum(axis=1)
    D = np.diag(deg).astype(complex)

    # Phase factor: exp(i·2π·q·Θ) ⊙ A
    phase = np.exp(1j * 2 * np.pi * q * direction) * adj
    return D - phase


def normalized_laplacian(L: np.ndarray) -> np.ndarray:
    """
    Normalize L so eigenvalues lie in [-1, 1] for Chebyshev recursion.
    L̃ = 2·L/λ_max - I
    """
    # Compute maximum eigenvalue (Hermitian so eigenvalues are real)
    eigvals = np.linalg.eigvalsh(L)
    lam_max = float(eigvals.max())
    if lam_max < 1e-12:
        return np.zeros_like(L)
    n = L.shape[0]
    return (2.0 / lam_max) * L - np.eye(n, dtype=complex)


def chebyshev_polynomials(L_norm: np.ndarray, K: int) -> List[np.ndarray]:
    """
    Compute Chebyshev polynomial matrices [T_0(L̃), T_1(L̃), ..., T_K(L̃)].
    T_0 = I, T_1 = L̃, T_{k+1} = 2·L̃·T_k - T_{k-1}.
    """
    n = L_norm.shape[0]
    Ts = [np.eye(n, dtype=complex)]   # T_0
    if K >= 1:
        Ts.append(L_norm.copy())       # T_1
    for k in range(2, K + 1):
        Tk = 2.0 * L_norm @ Ts[-1] - Ts[-2]
        Ts.append(Tk)
    return Ts  # list of K+1 complex (n×n) matrices


# ============================================================================
# MagNet Model
# ============================================================================

class MagNetModel:
    """
    Two-layer Chebyshev MagNet GNN — numpy implementation.

    Since no activation functions are used (as per TPE optimum in the paper),
    the model is a linear spectral filter. All complex arithmetic is handled
    natively by numpy.

    Parameters
    ----------
    n_features : int
        Dimension of input node features (default 6: height, weight, age, hand,
        out-degree, in-degree).
    hidden_dim : int
        Hidden units per layer (default 64).
    k_cheb : int
        Chebyshev filter order (default 2).
    n_layers : int
        Number of conv layers (default 2).
    q : float
        Magnetic charge (default 0.25).
    seed : int
        RNG seed for reproducible weight initialization.
    """

    def __init__(
        self,
        n_features: int = 6,
        hidden_dim: int = HIDDEN,
        k_cheb: int = K_CHEB,
        n_layers: int = N_LAYERS,
        q: float = Q,
        seed: int = 42,
    ):
        self.n_features = n_features
        self.hidden_dim = hidden_dim
        self.k_cheb = k_cheb
        self.n_layers = n_layers
        self.q = q
        rng = np.random.default_rng(seed)

        # Layer 1: input (k_cheb+1) × n_features → hidden_dim
        # Complex weights (real + imaginary parts stored together)
        in1 = (k_cheb + 1) * n_features
        self.W1 = (rng.standard_normal((in1, hidden_dim)) +
                   1j * rng.standard_normal((in1, hidden_dim))) * np.sqrt(2.0 / in1)

        # Layer 2: (k_cheb+1) × hidden_dim → hidden_dim
        in2 = (k_cheb + 1) * hidden_dim
        self.W2 = (rng.standard_normal((in2, hidden_dim)) +
                   1j * rng.standard_normal((in2, hidden_dim))) * np.sqrt(2.0 / in2)

        # Prediction head: [Re(delta), Im(delta)] → scalar
        # Input dim = 2 * hidden_dim (real and imag parts of Z2[i] - Z2[j])
        self.w = rng.standard_normal(2 * hidden_dim) * 0.01
        self.b = 0.0

        # Adam state (for all parameters flattened)
        self._init_adam()

        # Cache for the Chebyshev matrices (recomputed when graph changes)
        self._Ts: Optional[List[np.ndarray]] = None
        self._graph_hash: Optional[int] = None

    # ------------------------------------------------------------------
    # Graph setup
    # ------------------------------------------------------------------

    def set_graph(self, adj: np.ndarray, direction: np.ndarray) -> None:
        """Precompute magnetic Laplacian and Chebyshev polynomials for this graph."""
        L = magnetic_laplacian(adj, direction, self.q)
        L_norm = normalized_laplacian(L)
        self._Ts = chebyshev_polynomials(L_norm, self.k_cheb)

    # ------------------------------------------------------------------
    # Forward pass
    # ------------------------------------------------------------------

    def _conv_layer(self, X: np.ndarray, W: np.ndarray) -> np.ndarray:
        """
        Single ChebConv layer (no activation).
        Concatenates T_k @ X for k = 0..K, then multiplies by W.
        """
        assert self._Ts is not None, "Call set_graph() before forward pass."
        # Stack: (n, (K+1)*d_in) — concatenate along feature axis
        blocks = [T @ X for T in self._Ts]
        stacked = np.concatenate(blocks, axis=1)  # (n, (K+1)*d_in)
        return stacked @ W                        # (n, d_out), complex

    def forward(self, X: np.ndarray) -> np.ndarray:
        """
        Forward pass.
        X : (n, n_features) real float array
        Returns Z2 : (n, hidden_dim) complex array
        """
        X_c = X.astype(complex)
        Z1 = self._conv_layer(X_c, self.W1)   # (n, hidden_dim), complex
        Z2 = self._conv_layer(Z1, self.W2)     # (n, hidden_dim), complex
        return Z2

    def predict_prob(self, Z2: np.ndarray, i: int, j: int) -> float:
        """P(player i beats player j) given node embeddings Z2."""
        delta = Z2[i] - Z2[j]
        feat = np.concatenate([delta.real, delta.imag])  # (2*hidden_dim,)
        logit = float(feat @ self.w) + self.b
        return _sigmoid(logit)

    def predict_batch(
        self, Z2: np.ndarray, pairs: np.ndarray
    ) -> np.ndarray:
        """
        Predict for multiple pairs.
        pairs : (m, 2) int array of (i, j) indices.
        Returns probabilities (m,) that player i beats player j.
        """
        deltas = Z2[pairs[:, 0]] - Z2[pairs[:, 1]]  # (m, hidden_dim) complex
        feats = np.concatenate([deltas.real, deltas.imag], axis=1)  # (m, 2*H)
        logits = feats @ self.w + self.b  # (m,)
        return _sigmoid(logits)

    # ------------------------------------------------------------------
    # Training
    # ------------------------------------------------------------------

    def train(
        self,
        X: np.ndarray,
        train_pairs: np.ndarray,
        train_labels: np.ndarray,
        epochs: int = 150,
        eps: float = EPS_SMOOTH,
        lr: float = LR,
        wd: float = WD,
        verbose: bool = False,
    ) -> List[float]:
        """
        Train the model using Adam.

        Parameters
        ----------
        X            : (n, n_features) node feature matrix
        train_pairs  : (m, 2) int pairs — (player_i_index, player_j_index)
        train_labels : (m,) float in {0,1} — 1 if player_i wins
        epochs       : number of gradient steps
        eps          : label smoothing coefficient
        lr, wd       : Adam learning rate and weight decay

        Returns
        -------
        losses : list of per-epoch training loss
        """
        losses = []
        for epoch in range(epochs):
            # Forward pass (recomputes Z2 each epoch — necessary because W1, W2 change)
            Z2 = self.forward(X)

            # Predict
            probs = self.predict_batch(Z2, train_pairs)
            probs = np.clip(probs, 1e-7, 1 - 1e-7)

            # Label-smoothed targets
            y_smooth = (1 - eps) * train_labels + eps / 2.0

            # Cross-entropy loss (scalar)
            loss = -np.mean(
                y_smooth * np.log(probs) + (1 - y_smooth) * np.log(1 - probs)
            )
            losses.append(float(loss))

            if verbose and (epoch % 50 == 0 or epoch == epochs - 1):
                print(f"  Epoch {epoch:4d}  loss={loss:.4f}")

            # Backprop — compute gradients via finite differences for simplicity
            # (analytical gradient available but complex; finite diff is accurate here
            # given the small parameter count)
            grads = self._compute_gradients(X, Z2, train_pairs, y_smooth, probs)
            self._adam_step(grads, lr, wd)

        return losses

    def _compute_gradients(
        self,
        X: np.ndarray,
        Z2: np.ndarray,
        pairs: np.ndarray,
        y_smooth: np.ndarray,
        probs: np.ndarray,
    ) -> dict:
        """
        Compute gradients via backpropagation.

        Notation:
            e = probs - y_smooth   (m,)  — per-match residual
        """
        m = len(pairs)
        i_idx = pairs[:, 0]
        j_idx = pairs[:, 1]

        # ---- Prediction head gradients ----
        deltas = Z2[i_idx] - Z2[j_idx]          # (m, H) complex
        feats  = np.concatenate([deltas.real, deltas.imag], axis=1)  # (m, 2H)

        e = (probs - y_smooth) / m               # (m,) — averaged residual

        dL_dw = feats.T @ e                      # (2H,)
        dL_db = float(e.sum())

        # Gradient flowing back to Z2 (real domain, then split re/im)
        H = self.hidden_dim
        dL_dfeats = np.outer(e, self.w)          # (m, 2H)
        dL_ddelta_re = dL_dfeats[:, :H]          # (m, H)
        dL_ddelta_im = dL_dfeats[:, H:]          # (m, H)
        dL_ddelta = dL_ddelta_re + 1j * dL_ddelta_im  # (m, H) complex

        # Aggregate to per-node Z2 gradient
        dL_dZ2 = np.zeros_like(Z2)               # (n, H) complex
        np.add.at(dL_dZ2, i_idx, dL_ddelta)
        np.add.at(dL_dZ2, j_idx, -dL_ddelta)

        # ---- W2 gradient ----
        # Z2 = stacked2 @ W2
        # dL/dW2 = stacked2.H @ dL/dZ2
        X_c = X.astype(complex)
        Z1 = self._conv_layer(X_c, self.W1)
        stacked2 = np.concatenate([T @ Z1 for T in self._Ts], axis=1)  # (n, (K+1)*H)
        dL_dW2 = stacked2.conj().T @ dL_dZ2                              # ((K+1)H, H)

        # Gradient through W2 into stacked2
        dL_dstacked2 = dL_dZ2 @ self.W2.conj().T  # (n, (K+1)*H)

        # Gradient into Z1 from each T_k block
        dL_dZ1 = np.zeros_like(Z1)  # (n, H)
        for k, T in enumerate(self._Ts):
            block = dL_dstacked2[:, k * H:(k + 1) * H]  # (n, H)
            dL_dZ1 += T.conj().T @ block                 # (n, H)

        # ---- W1 gradient ----
        stacked1 = np.concatenate([T @ X_c for T in self._Ts], axis=1)  # (n, (K+1)*d)
        dL_dW1 = stacked1.conj().T @ dL_dZ1                              # ((K+1)*d, H)

        return {
            "W1": dL_dW1,
            "W2": dL_dW2,
            "w":  dL_dw,
            "b":  dL_db,
        }

    # ------------------------------------------------------------------
    # Adam optimizer
    # ------------------------------------------------------------------

    def _init_adam(self):
        self._t = 0
        self._m = {"W1": np.zeros_like(self.W1),
                   "W2": np.zeros_like(self.W2),
                   "w":  np.zeros_like(self.w),
                   "b":  0.0}
        self._v = {"W1": np.zeros_like(self.W1),
                   "W2": np.zeros_like(self.W2),
                   "w":  np.zeros_like(self.w),
                   "b":  0.0}

    def _adam_step(self, grads: dict, lr: float, wd: float,
                   beta1: float = 0.9, beta2: float = 0.999, eps: float = 1e-8):
        self._t += 1
        t = self._t
        for key in ["W1", "W2", "w", "b"]:
            g = grads[key]
            param = getattr(self, key)
            # Weight decay on param (not on gradient)
            g = g + wd * param
            self._m[key] = beta1 * self._m[key] + (1 - beta1) * g
            g_sq = (g * np.conj(g)).real if np.iscomplexobj(g) else g * g
            self._v[key] = beta2 * self._v[key] + (1 - beta2) * g_sq
            m_hat = self._m[key] / (1 - beta1 ** t)
            v_hat = self._v[key] / (1 - beta2 ** t)
            update = lr * m_hat / (np.sqrt(v_hat) + eps)
            if key == "b":
                self.b = float(param) - float(update.real)
            else:
                setattr(self, key, param - update)

    def reset_adam(self):
        """Reset Adam state (use when starting fresh training on new graph snapshot)."""
        self._init_adam()


# ============================================================================
# Utilities
# ============================================================================

def _sigmoid(x):
    return np.where(x >= 0,
                    1.0 / (1.0 + np.exp(-x)),
                    np.exp(x) / (1.0 + np.exp(x)))


def brier_score(probs: np.ndarray, labels: np.ndarray) -> float:
    return float(np.mean((probs - labels) ** 2))


def accuracy(probs: np.ndarray, labels: np.ndarray) -> float:
    return float(np.mean((probs >= 0.5).astype(float) == labels))


def set_win_to_match_prob(p_set: np.ndarray, best_of: int) -> np.ndarray:
    """
    Convert set-win probability p̂ to match-win probability using closed-form
    binomial (i.i.d. sets assumption).

    Best-of-3: P̂₃ = p̂²(3 − 2p̂)
    Best-of-5: P̂₅ = p̂³(10 − 15p̂ + 6p̂²)
    """
    p = np.asarray(p_set, dtype=float)
    if best_of == 3:
        return p ** 2 * (3 - 2 * p)
    elif best_of == 5:
        return p ** 3 * (10 - 15 * p + 6 * p ** 2)
    else:
        return p  # fallback: no conversion
