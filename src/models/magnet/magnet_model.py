"""
magnet_model.py — MagNet spectral GNN (PyTorch implementation).

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
    logit(i beats j) = [Re(Z2[i]−Z2[j]), Im(Z2[i]−Z2[j])] · w + b
    p(i beats j) = σ(logit)

Training:
    Loss: cross-entropy with label smoothing ε = 0.19
    Optimizer: Adam, lr=0.003, weight_decay=1e-4
    Epochs: 150 (initial), +30 (quarterly fine-tune)

Reference: Clegg & Cartlidge (2025), arXiv:2510.20454, Section 4.2 and 4.4.
"""

import numpy as np
import torch
import torch.nn as nn
import torch.optim as optim
from typing import List, Optional


# ============================================================================
# Hyperparameters
# ============================================================================

Q          = 0.25   # magnetic charge
HIDDEN     = 64     # hidden dimension per layer
K_CHEB     = 2      # Chebyshev filter order
LR         = 0.003
WD         = 1e-4   # weight decay (L2 regularisation)
EPS_SMOOTH = 0.19   # label smoothing


# ============================================================================
# Magnetic Laplacian helpers
# ============================================================================

def magnetic_laplacian(
    adj: np.ndarray, direction: np.ndarray, q: float = Q
) -> torch.Tensor:
    """
    Compute the magnetic Laplacian L^(q) = D − exp(i·2π·q·Θ) ⊙ A.

    Returns a complex Hermitian (n×n) torch.Tensor (CPU, complex64).
    """
    phase = 2.0 * np.pi * q * direction          # (n, n) float
    real  = np.diag(adj.sum(axis=1)) - np.cos(phase) * adj
    imag  = -np.sin(phase) * adj
    return torch.complex(
        torch.tensor(real, dtype=torch.float32),
        torch.tensor(imag, dtype=torch.float32),
    )


def normalized_laplacian(L: torch.Tensor) -> torch.Tensor:
    """
    L̃ = 2·L / λ_max − I, scaling eigenvalues to [−1, 1].
    Uses torch.linalg.eigvalsh (exact, valid for Hermitian matrices).
    """
    n = L.shape[0]
    lam_max = torch.linalg.eigvalsh(L).max().item()
    if lam_max < 1e-12:
        return torch.zeros(n, n, dtype=torch.complex64)
    return (2.0 / lam_max) * L - torch.eye(n, dtype=torch.complex64)


def chebyshev_polynomials(L_norm: torch.Tensor, K: int) -> List[torch.Tensor]:
    """
    [T_0(L̃), …, T_K(L̃)]  where  T_0=I, T_1=L̃, T_{k+1}=2L̃T_k − T_{k-1}.
    Stored as plain tensors (not nn.Parameters); no gradient tracking needed.
    """
    n = L_norm.shape[0]
    Ts = [torch.eye(n, dtype=torch.complex64)]
    if K >= 1:
        Ts.append(L_norm.clone())
    for _ in range(2, K + 1):
        Ts.append(2.0 * L_norm @ Ts[-1] - Ts[-2])
    return Ts


# ============================================================================
# MagNet Model
# ============================================================================

class MagNetModel(nn.Module):
    """
    Two-layer Chebyshev MagNet GNN implemented in PyTorch.

    Using PyTorch's autograd eliminates the hand-rolled complex backprop
    from the previous numpy implementation.

    Public API (matches the previous numpy version):
        model.set_graph(adj, direction)
        model.forward(X)         → complex (n, hidden) tensor
        model.predict_prob(Z2, i, j)  → float
        model.fit(X, pairs, labels, epochs, ...)
        model.reset_adam()       → no-op (kept for call-site compatibility)
    """

    def __init__(
        self,
        n_features: int = 6,
        hidden_dim: int = HIDDEN,
        k_cheb: int = K_CHEB,
        q: float = Q,
    ):
        super().__init__()
        self.n_features = n_features
        self.hidden_dim = hidden_dim
        self.k_cheb = k_cheb
        self.q = q

        in1 = (k_cheb + 1) * n_features
        in2 = (k_cheb + 1) * hidden_dim

        # Complex weight matrices — Glorot-style init: scale by sqrt(2/fan_in)
        self.W1 = nn.Parameter(self._complex_init(in1, hidden_dim))
        self.W2 = nn.Parameter(self._complex_init(in2, hidden_dim))

        # Real output head
        self.w = nn.Parameter(torch.zeros(2 * hidden_dim, dtype=torch.float32))
        self.b = nn.Parameter(torch.zeros(1, dtype=torch.float32))

        # Chebyshev matrices (set by set_graph, not learnable)
        self._Ts: List[torch.Tensor] = []

    @staticmethod
    def _complex_init(fan_in: int, fan_out: int) -> torch.Tensor:
        scale = np.sqrt(2.0 / fan_in)
        real = torch.randn(fan_in, fan_out) * scale
        imag = torch.randn(fan_in, fan_out) * scale
        return torch.complex(real, imag)

    # ------------------------------------------------------------------
    # Graph setup
    # ------------------------------------------------------------------

    def set_graph(self, adj: np.ndarray, direction: np.ndarray) -> None:
        """Precompute Chebyshev polynomial matrices for this graph snapshot."""
        L      = magnetic_laplacian(adj, direction, self.q)
        L_norm = normalized_laplacian(L)
        self._Ts = chebyshev_polynomials(L_norm, self.k_cheb)

    # ------------------------------------------------------------------
    # Forward pass
    # ------------------------------------------------------------------

    def forward(self, X: np.ndarray) -> torch.Tensor:
        """
        X : (n, n_features) real numpy array
        Returns Z2 : (n, hidden_dim) complex tensor
        """
        assert self._Ts, "Call set_graph() before forward()."
        Xc = torch.tensor(X, dtype=torch.complex64)
        Z1 = torch.cat([T @ Xc for T in self._Ts], dim=1) @ self.W1
        Z2 = torch.cat([T @ Z1 for T in self._Ts], dim=1) @ self.W2
        return Z2

    # ------------------------------------------------------------------
    # Prediction
    # ------------------------------------------------------------------

    def predict_prob(self, Z2: torch.Tensor, i: int, j: int) -> float:
        """P(player i beats player j) from pre-computed embeddings Z2."""
        with torch.no_grad():
            diff = Z2[i] - Z2[j]
            feat = torch.cat([diff.real, diff.imag])
            return torch.sigmoid(feat @ self.w + self.b).item()

    # ------------------------------------------------------------------
    # Training
    # ------------------------------------------------------------------

    def fit(
        self,
        X: np.ndarray,
        train_pairs: np.ndarray,
        train_labels: np.ndarray,
        epochs: int = 150,
        eps: float = EPS_SMOOTH,
        lr: float = LR,
        wd: float = WD,
        verbose: bool = False,
    ) -> None:
        """
        Train with Adam and label-smoothed cross-entropy.

        A fresh Adam instance is created each call, which is equivalent to
        calling reset_adam() before training in the previous implementation.
        """
        optimizer = optim.Adam(self.parameters(), lr=lr, weight_decay=wd)

        pairs_t  = torch.tensor(train_pairs, dtype=torch.long)
        labels_t = torch.tensor(train_labels, dtype=torch.float32)
        # Label smoothing: matches numpy version exactly: (1−ε)·y + ε/2
        labels_s = (1.0 - eps) * labels_t + eps / 2.0

        self.train()
        for epoch in range(epochs):
            optimizer.zero_grad()

            Z2   = self.forward(X)
            diff = Z2[pairs_t[:, 0]] - Z2[pairs_t[:, 1]]   # (m, H) complex
            feat = torch.cat([diff.real, diff.imag], dim=1) # (m, 2H) real
            probs = torch.sigmoid(feat @ self.w + self.b)   # (m,)

            loss = -torch.mean(
                labels_s * torch.log(probs + 1e-9) +
                (1.0 - labels_s) * torch.log(1.0 - probs + 1e-9)
            )

            loss.backward()
            optimizer.step()

            if verbose and (epoch % 50 == 0 or epoch == epochs - 1):
                print(f"  Epoch {epoch:4d}  loss={loss.item():.4f}")

        self.eval()

    def reset_adam(self) -> None:
        """No-op: optimizer created fresh in fit(). Kept for call-site compatibility."""
        pass


# ============================================================================
# Utilities
# ============================================================================

def brier_score(probs: np.ndarray, labels: np.ndarray) -> float:
    return float(np.mean((probs - labels) ** 2))


def accuracy(probs: np.ndarray, labels: np.ndarray) -> float:
    return float(np.mean((probs >= 0.5).astype(float) == labels))


def set_win_to_match_prob(p_set: np.ndarray, best_of: int) -> np.ndarray:
    """
    Convert set-win probability p̂ to match-win probability (i.i.d. sets).
    Best-of-3: p̂²(3 − 2p̂)    Best-of-5: p̂³(10 − 15p̂ + 6p̂²)
    """
    p = np.asarray(p_set, dtype=float)
    if best_of == 5:
        return p ** 3 * (10 - 15 * p + 6 * p ** 2)
    return p ** 2 * (3 - 2 * p)
