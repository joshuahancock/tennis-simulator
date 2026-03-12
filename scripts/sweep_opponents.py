#!/usr/bin/env python3
"""
sweep_opponents.py — Sweep max_opponents for I* to find the value that
produces ~22.7% bet rate at γ = 2.55 (the paper's reported figure).

Runs the full walk-forward once per surface/gender graph, but at each test
prediction computes I* for every candidate max_opponents value simultaneously.
This avoids re-running the expensive walk-forward N times.

Usage:
    python scripts/sweep_opponents.py
    python scripts/sweep_opponents.py --surface Hard --gender M
"""

import argparse
import sys
import time
from pathlib import Path

import numpy as np
import pandas as pd

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from src.models.magnet.graph_builder import (
    GraphBuilder, get_tournament_round_snapshots, SURFACES, GENDERS,
)
from src.models.magnet.magnet_model import (
    MagNetModel, set_win_to_match_prob,
)
from src.models.magnet.intransitivity import (
    compute_istar, kelly_fraction, GAMMA_DEFAULT,
)
from scripts.run_magnet import (
    MATCH_DATA_PATH, PLAYER_DATA_PATH,
    TRAIN_START, VALIDATION_START, TEST_START, TEST_END,
    INITIAL_EPOCHS, FINETUNE_EPOCHS, FINETUNE_EVERY, SPLIT_RATIO,
    _build_pairs,
)

OPPONENT_CANDIDATES = [2, 3, 4, 5, 6, 8, 10, 13]
TARGET_BET_RATE     = 0.227   # paper's reported bet rate


def sweep_one_graph(
    surface: str,
    gender: str,
    matches: pd.DataFrame,
    player_data: pd.DataFrame,
) -> pd.DataFrame:
    """
    Walk-forward for one graph, storing istar for all candidate max_opponents.
    Returns a DataFrame with one row per test match and columns:
        istar_2, istar_3, ..., istar_13, kelly_i, kelly_j, p_match, label
    """
    tour = "ATP" if gender == "M" else "WTA"
    g_matches = matches[
        (matches["surface"] == surface) & (matches["tour"] == tour)
    ].copy()

    print(f"\n{'='*60}")
    print(f"  {surface} / {tour}  ({len(g_matches)} total matches)")
    print(f"{'='*60}")

    if len(g_matches) < 50:
        return pd.DataFrame()

    snapshots = get_tournament_round_snapshots(g_matches)
    snapshots = snapshots.sort_values("snapshot_date").reset_index(drop=True)

    builder = GraphBuilder(g_matches, player_data)
    model   = MagNetModel(n_features=6)

    records = []
    snapshot_count = 0
    trained_once = False

    for _, snap_row in snapshots.iterrows():
        snap_date = pd.Timestamp(snap_row["snapshot_date"])
        if snap_date < TRAIN_START:
            continue

        round_matches = g_matches[
            (g_matches["tournament"] == snap_row["tournament"]) &
            (g_matches["round"]      == snap_row["round"]) &
            (g_matches["match_date"].dt.year == int(snap_row["year"]))
        ]
        if round_matches.empty:
            continue

        round_start    = pd.Timestamp(round_matches["match_date"].min())
        pre_round_date = round_start - pd.Timedelta(days=1)
        builder.advance_to(pre_round_date)

        is_test = TEST_START <= snap_date <= TEST_END

        # Training logic (identical to run_magnet.py)
        consumed      = g_matches[g_matches["match_date"] < round_start]
        n_consumed    = len(consumed)
        n_train_signal = max(int(n_consumed * (1 - SPLIT_RATIO)), 10)
        train_signal  = consumed.tail(n_train_signal)

        should_train = (
            (not trained_once and snap_date >= VALIDATION_START) or
            (trained_once and snapshot_count % FINETUNE_EVERY == 0)
        )

        if should_train:
            adj, direction, X, players = builder.get_graph(surface, gender, pre_round_date)
            idx_map = {name: i for i, name in enumerate(players)}
            if len(players) < 5:
                builder.advance_to(snap_date)
                continue

            train_pairs, train_labels = _build_pairs(train_signal, idx_map, gender)
            if len(train_pairs) < 5:
                builder.advance_to(snap_date)
                continue

            model.set_graph(adj, direction)
            epochs = INITIAL_EPOCHS if not trained_once else FINETUNE_EPOCHS
            t0 = time.time()
            model.fit(X, train_pairs, train_labels, epochs=epochs, verbose=False)
            print(f"  [{snap_date.date()}] Trained {epochs} epochs "
                  f"on {len(train_pairs)} pairs in {time.time()-t0:.1f}s")
            trained_once = True

        if is_test and trained_once:
            adj, direction, X, players = builder.get_graph(surface, gender, pre_round_date)
            idx_map  = {name: i for i, name in enumerate(players)}
            Z2       = model.forward(X)
            D        = builder.get_dominance(gender, surface)
            Z_denom  = builder._Z[surface][gender]

            for _, mrow in round_matches.iterrows():
                pi, pj = mrow["player_i"], mrow["player_j"]
                if pi not in idx_map or pj not in idx_map:
                    continue

                ui, uj = idx_map[pi], idx_map[pj]

                p_set   = model.predict_prob(Z2, ui, uj)
                best_of = int(mrow["best_of"]) if not pd.isna(mrow["best_of"]) else 3
                p_match = float(set_win_to_match_prob(np.array([p_set]), best_of)[0])
                label   = 1.0 if str(mrow["winner"]) == "i" else 0.0

                odds_i = float(mrow["ps_odds_i"]) if not pd.isna(mrow.get("ps_odds_i", np.nan)) else np.nan
                odds_j = float(mrow["ps_odds_j"]) if not pd.isna(mrow.get("ps_odds_j", np.nan)) else np.nan
                kf_i   = kelly_fraction(p_match, odds_i)       if not np.isnan(odds_i) else np.nan
                kf_j   = kelly_fraction(1 - p_match, odds_j)   if not np.isnan(odds_j) else np.nan

                # I* for each candidate max_opponents value
                row = {
                    "surface": surface, "gender": gender,
                    "p_match": p_match, "label": label,
                    "odds_i": odds_i, "odds_j": odds_j,
                    "kf_i": kf_i, "kf_j": kf_j,
                }
                for mo in OPPONENT_CANDIDATES:
                    row[f"istar_{mo}"] = compute_istar(ui, uj, D, Z_denom, max_opponents=mo)

                records.append(row)

        builder.advance_to(snap_date)
        snapshot_count += 1

    return pd.DataFrame(records)


def summarise(df: pd.DataFrame, surface: str, gender: str) -> pd.DataFrame:
    """
    For each max_opponents candidate, count matches where:
        istar >= gamma  AND  positive Kelly on at least one side
    Report bet count, bet rate, and Kelly ROI.
    """
    # Matches with odds on at least one side
    has_odds = ~df["odds_i"].isna() | ~df["odds_j"].isna()
    eligible = df[has_odds]

    rows = []
    for mo in OPPONENT_CANDIDATES:
        col = f"istar_{mo}"
        above_gamma = eligible[col] >= GAMMA_DEFAULT

        # Which side to bet (same logic as run_magnet.py)
        bet_i = ~eligible["odds_i"].isna() & above_gamma & (eligible["kf_i"].fillna(0) > 0)
        bet_j = ~eligible["odds_j"].isna() & above_gamma & (eligible["kf_j"].fillna(0) > 0)
        # If both qualify, we bet on i (same as runner)
        bet_mask = bet_i | (bet_j & ~bet_i)

        n_bets    = bet_mask.sum()
        bet_rate  = n_bets / len(eligible) if len(eligible) > 0 else 0.0

        # Kelly ROI
        profits, stakes = [], []
        for idx in eligible[bet_mask].index:
            r = eligible.loc[idx]
            if bet_i.loc[idx]:
                kf, odds, won = r["kf_i"], r["odds_i"], (r["label"] == 1.0)
            else:
                kf, odds, won = r["kf_j"], r["odds_j"], (r["label"] == 0.0)
            if pd.isna(kf) or pd.isna(odds) or kf <= 0:
                continue
            profits.append(kf * (odds - 1) if won else -kf)
            stakes.append(kf)
        roi = sum(profits) / sum(stakes) if stakes else np.nan

        rows.append({
            "surface": surface, "gender": gender,
            "max_opponents": mo,
            "n_bets": n_bets,
            "bet_rate": round(bet_rate, 4),
            "kelly_roi": round(roi, 4) if not np.isnan(roi) else np.nan,
        })

    return pd.DataFrame(rows)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--surface", choices=SURFACES + ["all"], default="all")
    parser.add_argument("--gender",  choices=GENDERS + ["all"],  default="all")
    args = parser.parse_args()

    print("Loading data...")
    matches     = pd.read_csv(MATCH_DATA_PATH, parse_dates=["match_date"])
    player_data = pd.read_csv(PLAYER_DATA_PATH)
    print(f"  {len(matches)} matches, {len(player_data)} players")
    print(f"\nSweeping max_opponents: {OPPONENT_CANDIDATES}")
    print(f"Target bet rate: {TARGET_BET_RATE:.1%}  (γ={GAMMA_DEFAULT})")

    surfaces = SURFACES if args.surface == "all" else [args.surface]
    genders  = GENDERS  if args.gender  == "all" else [
        "M" if args.gender == "M" else "F"
    ]

    all_summaries = []
    for surface in surfaces:
        for gender in genders:
            df = sweep_one_graph(surface, gender, matches, player_data)
            if df.empty:
                continue
            summary = summarise(df, surface, gender)
            all_summaries.append(summary)

            print(f"\n  Sweep results — {surface}/{gender}:")
            print(summary.to_string(index=False))

    if all_summaries:
        combined = pd.concat(all_summaries, ignore_index=True)
        # Aggregate across all graphs
        agg = (
            combined.groupby("max_opponents")[["n_bets"]]
            .sum()
            .reset_index()
        )
        total_eligible = sum(
            len(pd.read_csv(ROOT / f"data/processed/magnet/predictions_{s}_{g}.csv"))
            for s in surfaces for g in genders
            if (ROOT / f"data/processed/magnet/predictions_{s}_{g}.csv").exists()
        )
        agg["bet_rate"] = (agg["n_bets"] / total_eligible).round(4)
        agg["target"]   = TARGET_BET_RATE

        print(f"\n{'='*50}")
        print("  Aggregate bet rate across all graphs:")
        print(agg.to_string(index=False))
        print(f"\n  Paper target: {TARGET_BET_RATE:.1%}")

        out = ROOT / "data/processed/magnet/sweep_opponents.csv"
        combined.to_csv(out, index=False)
        print(f"\n  Full results: {out}")


if __name__ == "__main__":
    main()
