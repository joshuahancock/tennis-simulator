"""
Referee 2 Replication Script: Monte Carlo Tennis Match Simulator
================================================================
Independent Python implementation of the R Monte Carlo engine in
r_analysis/simulator/01_mc_engine.R

This script replicates the core simulation logic to verify correctness
through cross-language comparison.

Author: Referee 2 (Independent Audit)
Date: 2026-02-04
"""

import random
from dataclasses import dataclass
from typing import Optional, List, Dict, Tuple
import numpy as np


# ============================================================================
# CONFIGURATION - Must match R code exactly
# ============================================================================

# Global toggle for opponent adjustment (matches R's USE_OPPONENT_ADJUSTMENT)
USE_OPPONENT_ADJUSTMENT = True

# Hardcoded tour averages from R code (01_mc_engine.R lines 45, 68)
# NOTE: These are hardcoded in R - potential issue flagged in audit
AVG_RETURN_VS_FIRST = 0.35
AVG_RETURN_VS_SECOND = 0.50


# ============================================================================
# DATA STRUCTURES
# ============================================================================

@dataclass
class PlayerStats:
    """Player statistics for simulation."""
    first_in_pct: float      # % of first serves in (0-1)
    first_won_pct: float     # % of first serve points won (0-1)
    second_won_pct: float    # % of second serve points won (0-1)
    ace_pct: float           # % of service points that are aces (0-1)
    df_pct: float            # % of service points that are double faults (0-1)
    return_vs_first: Optional[float] = None   # Return % vs first serve
    return_vs_second: Optional[float] = None  # Return % vs second serve


@dataclass
class PointResult:
    """Result of a single point."""
    winner: int          # 1 = server, 0 = returner
    point_type: str      # "ace", "double_fault", or "rally"
    serve: str           # "first" or "second"


@dataclass
class GameResult:
    """Result of a single game."""
    winner: int          # 1 = server, 0 = returner
    score: Tuple[int, int]  # (server_points, returner_points)


@dataclass
class TiebreakResult:
    """Result of a tiebreak."""
    winner: int          # 1 or 2
    score: Tuple[int, int]  # (p1_points, p2_points)


@dataclass
class SetResult:
    """Result of a set."""
    winner: int          # 1 or 2
    score: Tuple[int, int]  # (p1_games, p2_games)
    tiebreak: bool
    tiebreak_score: Optional[Tuple[int, int]] = None


@dataclass
class MatchResult:
    """Result of a complete match."""
    winner: int          # 1 or 2
    score: Tuple[int, int]  # (p1_sets, p2_sets)
    set_scores: List[Tuple[int, int]]
    score_string: str


# ============================================================================
# POINT SIMULATION
# ============================================================================

def simulate_point(
    server_stats: PlayerStats,
    returner_stats: Optional[PlayerStats] = None,
    use_adjustment: Optional[bool] = None
) -> PointResult:
    """
    Simulate a single point.

    Replicates R function: simulate_point() in 01_mc_engine.R lines 24-79

    Parameters
    ----------
    server_stats : PlayerStats
        Serving player's statistics
    returner_stats : PlayerStats, optional
        Returning player's statistics (for opponent adjustment)
    use_adjustment : bool, optional
        Whether to adjust serve win probability based on returner stats.
        If None, uses global USE_OPPONENT_ADJUSTMENT setting.

    Returns
    -------
    PointResult
        Result containing winner, point_type, and serve type
    """
    if use_adjustment is None:
        use_adjustment = USE_OPPONENT_ADJUSTMENT

    # First serve in?
    first_in = random.random() < server_stats.first_in_pct

    if first_in:
        # Check for ace on first serve
        # Ace rate is conditional on first serve being in
        # R code line 36: ace_rate_on_first <- server_stats$ace_pct / server_stats$first_in_pct
        ace_rate_on_first = server_stats.ace_pct / server_stats.first_in_pct
        if random.random() < ace_rate_on_first:
            return PointResult(winner=1, point_type="ace", serve="first")

        # Calculate win probability on first serve
        if (use_adjustment and
            returner_stats is not None and
            returner_stats.return_vs_first is not None):
            # R code lines 44-48:
            # adjustment <- avg_return_vs_first - returner_stats$return_vs_first
            # win_prob <- server_stats$first_won_pct + adjustment
            # win_prob <- pmax(0.3, pmin(0.95, win_prob))
            adjustment = AVG_RETURN_VS_FIRST - returner_stats.return_vs_first
            win_prob = server_stats.first_won_pct + adjustment
            win_prob = max(0.3, min(0.95, win_prob))  # Clamp to reasonable range
        else:
            win_prob = server_stats.first_won_pct

        server_wins = random.random() < win_prob
        return PointResult(
            winner=1 if server_wins else 0,
            point_type="rally",
            serve="first"
        )

    else:
        # Second serve
        # Check for double fault
        # R code line 60: df_rate_on_second <- server_stats$df_pct / (1 - server_stats$first_in_pct)
        df_rate_on_second = server_stats.df_pct / (1 - server_stats.first_in_pct)
        if random.random() < df_rate_on_second:
            return PointResult(winner=0, point_type="double_fault", serve="second")

        # Calculate win probability on second serve
        if (use_adjustment and
            returner_stats is not None and
            returner_stats.return_vs_second is not None):
            # R code lines 68-71
            adjustment = AVG_RETURN_VS_SECOND - returner_stats.return_vs_second
            win_prob = server_stats.second_won_pct + adjustment
            win_prob = max(0.2, min(0.85, win_prob))
        else:
            win_prob = server_stats.second_won_pct

        server_wins = random.random() < win_prob
        return PointResult(
            winner=1 if server_wins else 0,
            point_type="rally",
            serve="second"
        )


# ============================================================================
# GAME SIMULATION
# ============================================================================

def simulate_game(
    server_stats: PlayerStats,
    returner_stats: Optional[PlayerStats] = None,
    use_adjustment: Optional[bool] = None
) -> GameResult:
    """
    Simulate a single game.

    Replicates R function: simulate_game() in 01_mc_engine.R lines 86-122

    Tennis scoring: first to 4 points, win by 2 (deuce/advantage rules).
    """
    server_points = 0
    returner_points = 0

    while True:
        point_result = simulate_point(server_stats, returner_stats, use_adjustment)

        if point_result.winner == 1:
            server_points += 1
        else:
            returner_points += 1

        # Check for game won (R code lines 113-120)
        if server_points >= 4 and server_points - returner_points >= 2:
            return GameResult(winner=1, score=(server_points, returner_points))
        if returner_points >= 4 and returner_points - server_points >= 2:
            return GameResult(winner=0, score=(server_points, returner_points))


# ============================================================================
# TIEBREAK SIMULATION
# ============================================================================

def simulate_tiebreak(
    p1_stats: PlayerStats,
    p2_stats: PlayerStats,
    to_points: int = 7,
    use_adjustment: Optional[bool] = None
) -> TiebreakResult:
    """
    Simulate a tiebreak.

    Replicates R function: simulate_tiebreak() in 01_mc_engine.R lines 124-183

    Serve rotation: P1 serves first point, then alternate every 2 points.
    """
    p1_points = 0
    p2_points = 0
    point_num = 0

    while True:
        # Determine server based on point number
        # R code lines 147-151:
        # if (point_num == 0) server_is_p1 <- TRUE
        # else server_is_p1 <- ((point_num - 1) %/% 2) %% 2 == 0
        if point_num == 0:
            server_is_p1 = True
        else:
            server_is_p1 = ((point_num - 1) // 2) % 2 == 0

        if server_is_p1:
            point_result = simulate_point(p1_stats, p2_stats, use_adjustment)
            point_winner = 1 if point_result.winner == 1 else 2
        else:
            point_result = simulate_point(p2_stats, p1_stats, use_adjustment)
            point_winner = 2 if point_result.winner == 1 else 1

        if point_winner == 1:
            p1_points += 1
        else:
            p2_points += 1

        point_num += 1

        # Check for tiebreak won (must win by 2)
        # R code lines 174-181
        if p1_points >= to_points and p1_points - p2_points >= 2:
            return TiebreakResult(winner=1, score=(p1_points, p2_points))
        if p2_points >= to_points and p2_points - p1_points >= 2:
            return TiebreakResult(winner=2, score=(p1_points, p2_points))


# ============================================================================
# SET SIMULATION
# ============================================================================

def simulate_set(
    p1_stats: PlayerStats,
    p2_stats: PlayerStats,
    first_server: int = 1,
    tiebreak_at: int = 6,
    final_set_tb: str = "normal",
    use_adjustment: Optional[bool] = None
) -> SetResult:
    """
    Simulate a set.

    Replicates R function: simulate_set() in 01_mc_engine.R lines 199-274

    Parameters
    ----------
    final_set_tb : str
        "normal" (7-point at 6-6), "super" (10-point at 6-6), or "none" (advantage set)
    """
    p1_games = 0
    p2_games = 0
    current_server = first_server

    while True:
        # Play a game
        if current_server == 1:
            game_result = simulate_game(p1_stats, p2_stats, use_adjustment)
            game_winner = 1 if game_result.winner == 1 else 2
        else:
            game_result = simulate_game(p2_stats, p1_stats, use_adjustment)
            game_winner = 2 if game_result.winner == 1 else 1

        if game_winner == 1:
            p1_games += 1
        else:
            p2_games += 1

        # Check for set won (6+ games, lead of 2)
        # R code lines 235-244
        if p1_games >= 6 and p1_games - p2_games >= 2:
            return SetResult(
                winner=1,
                score=(p1_games, p2_games),
                tiebreak=False
            )
        if p2_games >= 6 and p2_games - p1_games >= 2:
            return SetResult(
                winner=2,
                score=(p1_games, p2_games),
                tiebreak=False
            )

        # Check for tiebreak
        # R code lines 247-269
        if p1_games == tiebreak_at and p2_games == tiebreak_at:
            if final_set_tb == "none":
                # No tiebreak - continue playing (advantage set)
                current_server = 2 if current_server == 1 else 1
                continue

            tb_points = 10 if final_set_tb == "super" else 7
            tb_result = simulate_tiebreak(p1_stats, p2_stats, tb_points, use_adjustment)

            if tb_result.winner == 1:
                p1_games += 1
            else:
                p2_games += 1

            return SetResult(
                winner=tb_result.winner,
                score=(p1_games, p2_games),
                tiebreak=True,
                tiebreak_score=tb_result.score
            )

        # Alternate server
        current_server = 2 if current_server == 1 else 1


# ============================================================================
# MATCH SIMULATION
# ============================================================================

def simulate_match(
    p1_stats: PlayerStats,
    p2_stats: PlayerStats,
    best_of: int = 3,
    final_set_tb: str = "normal",
    use_adjustment: Optional[bool] = None
) -> MatchResult:
    """
    Simulate a complete match.

    Replicates R function: simulate_match() in 01_mc_engine.R lines 288-349
    """
    sets_to_win = (best_of + 1) // 2  # 2 for best_of=3, 3 for best_of=5

    p1_sets = 0
    p2_sets = 0
    set_scores = []

    # Randomly determine first server (R code line 299)
    first_server = random.choice([1, 2])
    current_server = first_server

    while p1_sets < sets_to_win and p2_sets < sets_to_win:
        is_final_set = (p1_sets == sets_to_win - 1 and p2_sets == sets_to_win - 1)

        set_result = simulate_set(
            p1_stats, p2_stats,
            first_server=current_server,
            tiebreak_at=6,
            final_set_tb=final_set_tb if is_final_set else "normal",
            use_adjustment=use_adjustment
        )

        set_scores.append(set_result.score)

        if set_result.winner == 1:
            p1_sets += 1
        else:
            p2_sets += 1

        # Server for next set (R code lines 330-333)
        total_games = set_result.score[0] + set_result.score[1]
        if total_games % 2 == 1:
            current_server = 2 if current_server == 1 else 1

    winner = 1 if p1_sets > p2_sets else 2

    # Format score string
    score_str = " ".join(f"{s[0]}-{s[1]}" for s in set_scores)

    return MatchResult(
        winner=winner,
        score=(p1_sets, p2_sets),
        set_scores=set_scores,
        score_string=score_str
    )


# ============================================================================
# MONTE CARLO PROBABILITY ESTIMATION
# ============================================================================

def estimate_win_probability(
    p1_stats: PlayerStats,
    p2_stats: PlayerStats,
    n_sims: int = 10000,
    best_of: int = 3,
    final_set_tb: str = "normal",
    use_adjustment: Optional[bool] = None,
    seed: Optional[int] = None
) -> Dict:
    """
    Estimate match win probability via Monte Carlo simulation.

    Replicates the core loop in R's simulate_match_probability()
    from 03_match_probability.R lines 98-102
    """
    if seed is not None:
        random.seed(seed)
        np.random.seed(seed)

    p1_wins = 0
    for _ in range(n_sims):
        result = simulate_match(p1_stats, p2_stats, best_of, final_set_tb, use_adjustment)
        if result.winner == 1:
            p1_wins += 1

    p1_win_prob = p1_wins / n_sims

    # Wilson score confidence interval (replicates prop_ci in R)
    # R code from 03_match_probability.R lines 160-172
    from scipy import stats
    z = stats.norm.ppf(0.975)  # 95% CI
    n = n_sims
    p = p1_win_prob

    denominator = 1 + z**2 / n
    centre = p + z**2 / (2 * n)
    spread = z * np.sqrt((p * (1 - p) + z**2 / (4 * n)) / n)

    ci_lower = (centre - spread) / denominator
    ci_upper = (centre + spread) / denominator

    return {
        "p1_win_prob": p1_win_prob,
        "p2_win_prob": 1 - p1_win_prob,
        "ci_lower": ci_lower,
        "ci_upper": ci_upper,
        "n_sims": n_sims
    }


# ============================================================================
# VERIFICATION TESTS
# ============================================================================

def run_verification_tests():
    """
    Run verification tests comparing Python output to expected R output.

    These tests use fixed seeds to ensure reproducibility.
    """
    print("=" * 70)
    print("REFEREE 2: Cross-Language Replication Verification")
    print("Python implementation of r_analysis/simulator/01_mc_engine.R")
    print("=" * 70)

    # Test Case 1: Typical ATP player stats
    print("\n--- Test Case 1: Typical ATP matchup ---")

    player1 = PlayerStats(
        first_in_pct=0.62,
        first_won_pct=0.75,
        second_won_pct=0.52,
        ace_pct=0.08,
        df_pct=0.03,
        return_vs_first=0.30,
        return_vs_second=0.50
    )

    player2 = PlayerStats(
        first_in_pct=0.65,
        first_won_pct=0.72,
        second_won_pct=0.50,
        ace_pct=0.05,
        df_pct=0.04,
        return_vs_first=0.32,
        return_vs_second=0.52
    )

    # Run with fixed seed for reproducibility
    result = estimate_win_probability(
        player1, player2,
        n_sims=10000,
        best_of=3,
        use_adjustment=True,
        seed=42
    )

    print(f"Player 1 stats: 1st in={player1.first_in_pct:.0%}, "
          f"1st won={player1.first_won_pct:.0%}, "
          f"2nd won={player1.second_won_pct:.0%}")
    print(f"Player 2 stats: 1st in={player2.first_in_pct:.0%}, "
          f"1st won={player2.first_won_pct:.0%}, "
          f"2nd won={player2.second_won_pct:.0%}")
    print(f"\nPlayer 1 win probability: {result['p1_win_prob']:.4f}")
    print(f"95% CI: [{result['ci_lower']:.4f}, {result['ci_upper']:.4f}]")
    print(f"N simulations: {result['n_sims']}")

    # Test Case 2: Big server vs good returner
    print("\n--- Test Case 2: Big server vs elite returner ---")

    big_server = PlayerStats(
        first_in_pct=0.58,
        first_won_pct=0.82,
        second_won_pct=0.58,
        ace_pct=0.15,
        df_pct=0.05,
        return_vs_first=0.25,
        return_vs_second=0.45
    )

    elite_returner = PlayerStats(
        first_in_pct=0.68,
        first_won_pct=0.70,
        second_won_pct=0.48,
        ace_pct=0.04,
        df_pct=0.02,
        return_vs_first=0.38,
        return_vs_second=0.56
    )

    result2 = estimate_win_probability(
        big_server, elite_returner,
        n_sims=10000,
        best_of=3,
        use_adjustment=True,
        seed=42
    )

    print(f"Big server win probability: {result2['p1_win_prob']:.4f}")
    print(f"95% CI: [{result2['ci_lower']:.4f}, {result2['ci_upper']:.4f}]")

    # Test Case 3: No opponent adjustment
    print("\n--- Test Case 3: Same matchup, NO opponent adjustment ---")

    result3 = estimate_win_probability(
        player1, player2,
        n_sims=10000,
        best_of=3,
        use_adjustment=False,
        seed=42
    )

    print(f"Player 1 win probability (no adj): {result3['p1_win_prob']:.4f}")
    print(f"Difference from adjusted: {result3['p1_win_prob'] - result['p1_win_prob']:.4f}")

    # Test single point simulation for debugging
    print("\n--- Point-level verification ---")
    random.seed(123)
    point_results = {"ace": 0, "double_fault": 0, "rally_first": 0, "rally_second": 0}
    for _ in range(10000):
        pt = simulate_point(player1, player2, use_adjustment=True)
        if pt.point_type == "ace":
            point_results["ace"] += 1
        elif pt.point_type == "double_fault":
            point_results["double_fault"] += 1
        elif pt.serve == "first":
            point_results["rally_first"] += 1
        else:
            point_results["rally_second"] += 1

    total_points = sum(point_results.values())
    print(f"Aces: {point_results['ace']/total_points:.2%} "
          f"(expected ~{player1.ace_pct:.2%})")
    print(f"Double faults: {point_results['double_fault']/total_points:.2%} "
          f"(expected ~{player1.df_pct:.2%})")

    print("\n" + "=" * 70)
    print("Verification complete. Compare these results to R output.")
    print("=" * 70)


if __name__ == "__main__":
    run_verification_tests()
