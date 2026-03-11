#!/usr/bin/env bash
# run_magnet_full.sh — Re-export player attributes then run all 6 MagNet graphs.
# Run this once the tennisexplorer scraper has finished.
#
# Usage: bash scripts/run_magnet_full.sh

set -e
cd "$(dirname "$0")/.."

echo "=== Step 1: Refresh player_data.csv with scraped attributes ==="
Rscript scripts/export_for_magnet.R

echo ""
echo "=== Step 2: Run MagNet on all 6 graphs (3 surfaces × 2 genders) ==="
python3 scripts/run_magnet.py --surface all --gender all

echo ""
echo "=== Done. Results in data/processed/magnet/ ==="
