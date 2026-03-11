#!/usr/bin/env python3
"""
run_magnet.py — Walk-forward MagNet GNN evaluation.

Implements the walk-forward protocol from Clegg & Cartlidge (2025):
  - Training history: Jan 2014 – Aug 2019 (initial graph build)
  - Validation: Aug 29, 2019 – Nov 20, 2022 (not evaluated here)
  - Test:        Jan 1, 2023 – Jun 8, 2025  (reported metrics)

Walk-forward cycle (per surface/gender graph):
  1. Build graph from earliest 85% of history
  2. Train 150 epochs on 15% most recent matches
  3. Predict next tournament round
  4. Integrate outcomes into graph, advance window
  5. Every 38 snapshots: fine-tune +30 epochs

Usage:
    python scripts/run_magnet.py
    python scripts/run_magnet.py --surface Hard --gender M
    python scripts/run_magnet.py --test-only --surface Hard --gender M

Output:
    data/processed/magnet/predictions_{surface}_{gender}.csv
    data/processed/magnet/metrics_summary.csv
"""

import argparse
import sys
import time
from pathlib import Path

import numpy as np
import pandas as pd

# Allow importing from src/
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from src.models.magnet.graph_builder import (
    GraphBuilder, get_tournament_round_snapshots, SURFACES, GENDERS
)
from src.models.magnet.magnet_model import (
    MagNetModel, brier_score, accuracy, set_win_to_match_prob
)
from src.models.magnet.intransitivity import (
    compute_istar, kelly_fraction, should_bet, GAMMA_DEFAULT
)


# ============================================================================
# Config
# ============================================================================

MATCH_DATA_PATH  = ROOT / "data/processed/magnet/match_data.csv"
PLAYER_DATA_PATH = ROOT / "data/processed/magnet/player_data.csv"
OUT_DIR          = ROOT / "data/processed/magnet"

TRAIN_START = pd.Timestamp("2014-01-01")
TEST_START  = pd.Timestamp("2023-01-01")
TEST_END    = pd.Timestamp("2025-06-08")   # paper's exact cutoff

INITIAL_EPOCHS  = 150
FINETUNE_EPOCHS = 30
FINETUNE_EVERY  = 38  # snapshots between fine-tunes

SPLIT_RATIO = 0.85   # fraction of history used for graph structure; 15% for training signal


# ============================================================================
# Walk-forward evaluation for one surface/gender pair
# ============================================================================

def run_one_graph(
    surface: str,
    gender: str,
    matches: pd.DataFrame,
    player_data: pd.DataFrame,
    test_only: bool = False,
    verbose: bool = True,
) -> pd.DataFrame:
    """
    Full walk-forward evaluation for one (surface, gender) graph.

    Returns a DataFrame of predictions for test-period matches.
    """
    tour = "ATP" if gender == "M" else "WTA"
    g_matches = matches[
        (matches["surface"] == surface) & (matches["tour"] == tour)
    ].copy()

    if verbose:
        print(f"\n{'='*60}")
        print(f"  {surface} / {tour}  ({len(g_matches)} total matches)")
        print(f"{'='*60}")

    if len(g_matches) < 50:
        print(f"  Insufficient matches — skipping.")
        return pd.DataFrame()

    # All tournament-round snapshots for this surface/gender, sorted chronologically
    snapshots = get_tournament_round_snapshots(g_matches)
    snapshots = snapshots.sort_values("snapshot_date").reset_index(drop=True)

    if verbose:
        print(f"  {len(snapshots)} tournament-round snapshots")

    # Build graph incrementally up to test start
    builder = GraphBuilder(g_matches, player_data)
    model   = MagNetModel(n_features=6)

    predictions = []   # accumulated test-period predictions
    snapshot_count = 0
    trained_once = False

    for snap_idx, snap_row in snapshots.iterrows():
        snap_date = pd.Timestamp(snap_row["snapshot_date"])

        if snap_date < TRAIN_START:
            continue

        # Matches in this specific (tournament, year, round) — the ones to predict
        round_matches = g_matches[
            (g_matches["tournament"] == snap_row["tournament"]) &
            (g_matches["round"]      == snap_row["round"]) &
            (g_matches["match_date"].dt.year == int(snap_row["year"]))
        ]
        if round_matches.empty:
            continue

        round_start = pd.Timestamp(round_matches["match_date"].min())

        # CRITICAL: advance graph only up to the day BEFORE this round starts.
        # This prevents the current round's results from leaking into predictions.
        pre_round_date = round_start - pd.Timedelta(days=1)
        builder.advance_to(pre_round_date)

        # Only evaluate/predict in the test period
        is_test = snap_date >= TEST_START and snap_date <= TEST_END

        # ---- Determine if we should (re)train ----
        # Training signal: most recent 15% of pre-round history (no leakage)
        consumed = g_matches[g_matches["match_date"] < round_start]
        n_consumed = len(consumed)
        n_train_signal = max(int(n_consumed * (1 - SPLIT_RATIO)), 10)
        train_signal = consumed.tail(n_train_signal)

        should_train = (
            (not trained_once and snap_date >= TEST_START - pd.Timedelta(days=365)) or
            (trained_once and snapshot_count % FINETUNE_EVERY == 0)
        )

        if should_train:
            adj, direction, X, players = builder.get_graph(surface, gender, pre_round_date)
            idx_map = {name: i for i, name in enumerate(players)}
            n_players = len(players)

            if n_players < 5:
                # Advance past this round before continuing
                builder.advance_to(snap_date)
                continue

            # Build training pairs from the 15% signal window
            train_pairs, train_labels = _build_pairs(train_signal, idx_map, gender)

            if len(train_pairs) < 5:
                builder.advance_to(snap_date)
                continue

            model.set_graph(adj, direction)
            epochs = INITIAL_EPOCHS if not trained_once else FINETUNE_EPOCHS
            model.reset_adam()

            t0 = time.time()
            model.train(X, train_pairs, train_labels, epochs=epochs, verbose=False)
            elapsed = time.time() - t0

            if verbose:
                print(f"  [{snap_date.date()}] Trained {epochs} epochs "
                      f"on {len(train_pairs)} pairs "
                      f"({n_players} players) in {elapsed:.1f}s")
            trained_once = True

        # ---- Predict this round's matches (graph does NOT include current round) ----
        if is_test and trained_once:
            adj, direction, X, players = builder.get_graph(surface, gender, pre_round_date)
            idx_map = {name: i for i, name in enumerate(players)}

            Z2 = model.forward(X)
            D  = builder.get_dominance(gender, surface)
            Z_denom = builder._Z[surface][gender]

            for _, mrow in round_matches.iterrows():
                pi = mrow["player_i"]
                pj = mrow["player_j"]

                if pi not in idx_map or pj not in idx_map:
                    continue  # player not in graph (rare)

                ui = idx_map[pi]
                uj = idx_map[pj]

                # P(player_i beats player_j)
                p_set = model.predict_prob(Z2, ui, uj)
                best_of = int(mrow["best_of"]) if not pd.isna(mrow["best_of"]) else 3
                p_match = float(set_win_to_match_prob(np.array([p_set]), best_of)[0])

                actual_winner = str(mrow["winner"])  # "i" or "j"
                label = 1.0 if actual_winner == "i" else 0.0

                # Odds (player_i perspective)
                odds_i = float(mrow["ps_odds_i"]) if not pd.isna(mrow.get("ps_odds_i", np.nan)) else np.nan
                odds_j = float(mrow["ps_odds_j"]) if not pd.isna(mrow.get("ps_odds_j", np.nan)) else np.nan

                # Intransitivity
                istar = compute_istar(ui, uj, D, Z_denom)

                # Kelly
                kf_i = kelly_fraction(p_match, odds_i) if not np.isnan(odds_i) else np.nan
                kf_j = kelly_fraction(1 - p_match, odds_j) if not np.isnan(odds_j) else np.nan

                # Which side to bet (if any)?
                bet_side = None
                if not np.isnan(odds_i) and should_bet(istar, p_match, odds_i):
                    bet_side = "i"
                elif not np.isnan(odds_j) and should_bet(istar, 1 - p_match, odds_j):
                    bet_side = "j"

                predictions.append({
                    "match_date":  mrow["match_date"],
                    "tournament":  mrow["tournament"],
                    "surface":     surface,
                    "gender":      gender,
                    "round":       mrow["round"],
                    "best_of":     best_of,
                    "player_i":    pi,
                    "player_j":    pj,
                    "actual_winner": actual_winner,
                    "p_set":       round(float(p_set), 6),
                    "p_match":     round(p_match, 6),
                    "label":       label,
                    "odds_i":      odds_i,
                    "odds_j":      odds_j,
                    "istar":       round(istar, 4),
                    "kelly_i":     round(kf_i, 6) if not np.isnan(kf_i) else np.nan,
                    "kelly_j":     round(kf_j, 6) if not np.isnan(kf_j) else np.nan,
                    "bet_side":    bet_side,
                })

        # Advance graph past this round so next snapshot has this round's results
        builder.advance_to(snap_date)
        snapshot_count += 1

    pred_df = pd.DataFrame(predictions)
    if not pred_df.empty:
        _print_metrics(pred_df, surface, gender)
    return pred_df


# ============================================================================
# Helpers
# ============================================================================

def _build_pairs(
    match_df: pd.DataFrame,
    idx_map: dict,
    gender: str,
) -> tuple:
    """
    Convert match rows to (pairs, labels) for training.
    Label = 1 if player_i won, 0 if player_j won.
    """
    pairs  = []
    labels = []
    for _, row in match_df.iterrows():
        pi = row["player_i"]
        pj = row["player_j"]
        if pi not in idx_map or pj not in idx_map:
            continue
        pairs.append([idx_map[pi], idx_map[pj]])
        labels.append(1.0 if row["winner"] == "i" else 0.0)
    if not pairs:
        return np.zeros((0, 2), dtype=int), np.zeros(0)
    return np.array(pairs, dtype=int), np.array(labels, dtype=float)


def _print_metrics(pred_df: pd.DataFrame, surface: str, gender: str) -> None:
    n = len(pred_df)
    if n == 0:
        return
    probs  = pred_df["p_match"].values
    labels = pred_df["label"].values
    acc    = accuracy(probs, labels)
    bs     = brier_score(probs, labels)

    bets = pred_df[pred_df["bet_side"].notna()]
    print(f"\n  [{surface}/{gender}] Test predictions: {n} matches")
    print(f"    Accuracy:    {acc:.3f}")
    print(f"    Brier score: {bs:.4f}")

    if not bets.empty:
        roi = _compute_roi(bets)
        print(f"    Bets placed: {len(bets)}  (γ={GAMMA_DEFAULT})")
        print(f"    Kelly ROI:   {roi:.2%}")


def _compute_roi(bets: pd.DataFrame) -> float:
    """
    'Reset to 1' Kelly ROI: each bet stakes kelly_fraction × 1 unit.
    ROI = total_profit / total_staked.
    """
    profits = []
    stakes  = []
    for _, row in bets.iterrows():
        side = row["bet_side"]
        if side == "i":
            kf   = row["kelly_i"]
            odds = row["odds_i"]
            won  = (row["actual_winner"] == "i")
        else:
            kf   = row["kelly_j"]
            odds = row["odds_j"]
            won  = (row["actual_winner"] == "j")

        if pd.isna(kf) or pd.isna(odds) or kf <= 0:
            continue

        stake = kf  # stake = kelly fraction × 1 unit
        profit = stake * (odds - 1) if won else -stake
        profits.append(profit)
        stakes.append(stake)

    if not stakes:
        return 0.0
    return sum(profits) / sum(stakes)


# ============================================================================
# Entry point
# ============================================================================

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--surface", choices=SURFACES + ["all"], default="all")
    parser.add_argument("--gender",  choices=GENDERS + ["all"], default="all")
    parser.add_argument("--test-only", action="store_true",
                        help="Skip validation period, start predictions at TEST_START")
    parser.add_argument("--verbose",   action="store_true", default=True)
    args = parser.parse_args()

    if not MATCH_DATA_PATH.exists():
        print(f"ERROR: {MATCH_DATA_PATH} not found. Run scripts/export_for_magnet.R first.")
        sys.exit(1)

    print("Loading data...")
    matches     = pd.read_csv(MATCH_DATA_PATH, parse_dates=["match_date"])
    player_data = pd.read_csv(PLAYER_DATA_PATH)
    print(f"  {len(matches)} matches, {len(player_data)} players")

    surfaces = SURFACES if args.surface == "all" else [args.surface]
    genders  = GENDERS  if args.gender  == "all" else [
        "M" if args.gender == "M" else "F"
    ]

    all_preds = []
    for surface in surfaces:
        for gender in genders:
            pred_df = run_one_graph(
                surface, gender, matches, player_data,
                test_only=args.test_only,
                verbose=args.verbose,
            )
            if not pred_df.empty:
                all_preds.append(pred_df)
                out_path = OUT_DIR / f"predictions_{surface}_{gender}.csv"
                pred_df.to_csv(out_path, index=False)
                print(f"  Saved: {out_path}")

    if all_preds:
        combined = pd.concat(all_preds, ignore_index=True)
        out_all = OUT_DIR / "predictions_all.csv"
        combined.to_csv(out_all, index=False)
        print(f"\nCombined: {out_all}  ({len(combined)} rows)")

        # Summary table
        print("\n=== Summary ===")
        summary_rows = []
        for g in ["M", "F"]:
            for s in surfaces:
                sub = combined[(combined["surface"] == s) & (combined["gender"] == g)]
                if sub.empty:
                    continue
                acc = accuracy(sub["p_match"].values, sub["label"].values)
                bs  = brier_score(sub["p_match"].values, sub["label"].values)
                bets = sub[sub["bet_side"].notna()]
                roi = _compute_roi(bets) if not bets.empty else np.nan
                summary_rows.append({
                    "gender": g, "surface": s,
                    "n": len(sub), "accuracy": round(acc, 3),
                    "brier": round(bs, 4), "n_bets": len(bets),
                    "kelly_roi": round(roi, 4) if not np.isnan(roi) else np.nan,
                })
        summary_df = pd.DataFrame(summary_rows)
        print(summary_df.to_string(index=False))
        summary_df.to_csv(OUT_DIR / "metrics_summary.csv", index=False)

    print("\nDone.")


if __name__ == "__main__":
    main()
