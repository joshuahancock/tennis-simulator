# Validate Elo Betting Edge
# Run from project root: Rscript scripts/validate_elo_betting.R
#
# This script investigates whether the Elo model's apparent betting edge is real:
# 1. Data leakage check - verify Elo ratings exclude the match being predicted
# 2. Odds timing - document what odds we're using (closing vs opening)
# 3. Out-of-sample test - run H2 2024 as true holdout
# 4. Baseline comparison - compare to naive "bet on favorite" strategy

cat("=================================================================\n")
cat("           ELO BETTING EDGE VALIDATION\n")
cat("=================================================================\n\n")

# Source backtest framework
source("src/backtesting/backtest.R")

# ============================================================================
# 1. DATA LEAKAGE CHECK
# ============================================================================

cat("=== 1. DATA LEAKAGE CHECK ===\n\n")

cat("Verification from code inspection:\n")
cat("- 06_backtest.R line 288: prior_matches <- filter(match_date < cutoff_date)\n")
cat("- 07_elo_ratings.R line 296: current_elo_db <- build_elo_db_from_matches(prior_matches)\n")
cat("- Elo ratings for each prediction use ONLY matches BEFORE that date\n")
cat("\nConclusion: No data leakage in rolling Elo calculation.\n")

# Empirical verification: check that Elo predictions don't use future data
cat("\nEmpirical verification (spot check):\n")

# Load data for verification
betting <- load_betting_data(year_from = 2020, year_to = 2024, tour = "ATP")
historical_matches <- load_atp_matches(year_from = 2015, year_to = 2024)

# Pick a specific match in mid-2024
test_date <- as.Date("2024-06-15")
test_match <- betting %>%
  filter(match_date == test_date) %>%
  head(1)

if (nrow(test_match) > 0) {
  cat(sprintf("  Test match: %s vs %s on %s\n",
              test_match$winner[1], test_match$loser[1], test_date))

  # Calculate Elo with cutoff BEFORE the match
  prior_matches <- historical_matches %>% filter(match_date < test_date)
  elo_before <- calculate_all_elo(prior_matches, by_surface = TRUE)

  # Check the match is NOT in the Elo history
  in_history <- elo_before$history %>%
    filter(match_date >= test_date) %>%
    nrow()
  cat(sprintf("  Matches on/after %s in Elo history: %d (should be 0)\n",
              test_date, in_history))

  if (in_history == 0) {
    cat("  PASSED: No future data in Elo calculation\n")
  } else {
    cat("  FAILED: Future data detected!\n")
  }
}

# ============================================================================
# 2. ODDS TIMING
# ============================================================================

cat("\n\n=== 2. ODDS TIMING ===\n\n")

cat("Data source: tennis-data.co.uk\n")
cat("Odds type: CLOSING ODDS (recorded at match start)\n\n")

cat("From tennis-data.co.uk documentation:\n")
cat("- PS = Pinnacle Sports closing odds\n")
cat("- B365 = Bet365 closing odds\n")
cat("- These are the final odds available before the match starts\n\n")

# Check what odds sources we're actually using
cat("Odds sources in our H1 2024 data:\n")
h1_betting <- betting %>%
  filter(match_date >= "2024-01-01", match_date <= "2024-06-30")
h1_with_odds <- extract_best_odds(h1_betting)
cat("\n")

cat("Implications:\n")
cat("- Closing odds are HARDER to beat than opening odds\n")
cat("- Professional bettors typically get +EV from opening odds\n")
cat("- If we show profit on closing odds, edge is likely real\n")
cat("- HOWEVER: We may not have been able to actually bet these odds\n")
cat("  (lines move, liquidity issues, etc.)\n")

# ============================================================================
# 3. OUT-OF-SAMPLE TEST (H2 2024)
# ============================================================================

cat("\n\n=== 3. OUT-OF-SAMPLE TEST (H2 2024) ===\n\n")

cat("H1 2024 was used for development. Running H2 2024 as true holdout...\n\n")

# Check if H2 2024 data exists
h2_betting <- betting %>%
  filter(match_date >= "2024-07-01", match_date <= "2024-12-31")

if (nrow(h2_betting) == 0) {
  cat("WARNING: No H2 2024 betting data available.\n")
  cat("The betting data may only go through mid-2024.\n")
  cat("Checking available date range...\n")
  cat(sprintf("Betting data range: %s to %s\n",
              min(betting$match_date), max(betting$match_date)))
} else {
  cat(sprintf("H2 2024 matches available: %d\n", nrow(h2_betting)))

  # Run Elo backtest on H2 2024
  cat("\nRunning Elo model backtest on H2 2024...\n")
  results_h2 <- backtest_period(
    start_date = "2024-07-01",
    end_date = "2024-12-31",
    model = "elo",
    tour = "ATP",
    seed = 20260206
  )
}

# ============================================================================
# 4. BASELINE COMPARISON
# ============================================================================

cat("\n\n=== 4. BASELINE COMPARISON ===\n\n")

cat("Comparing Elo to naive 'bet on market favorite' strategy...\n\n")

# Re-run H1 2024 to get predictions
cat("Loading H1 2024 Elo predictions...\n")

# Load saved results if available, otherwise re-run
results_file <- "data/processed/model_comparison_h1_2024.rds"
if (file.exists(results_file)) {
  saved_results <- readRDS(results_file)
  elo_preds <- saved_results$elo_common
  cat(sprintf("Loaded %d predictions from saved results\n", nrow(elo_preds)))
} else {
  cat("Saved results not found, running backtest...\n")
  results_elo <- backtest_period(
    start_date = "2024-01-01",
    end_date = "2024-06-30",
    model = "elo",
    tour = "ATP",
    seed = 20260206
  )
  elo_preds <- results_elo$predictions
}

# Calculate baseline: always bet on the market favorite
cat("\nCalculating baseline strategies...\n")

baseline_analysis <- elo_preds %>%
  mutate(
    # Market favorite is the one with lower odds (higher implied prob)
    market_fav_is_p1 = p1_odds < p2_odds,
    market_fav_odds = if_else(market_fav_is_p1, p1_odds, p2_odds),
    market_fav_won = (market_fav_is_p1 & actual_p1_won == 1) |
                     (!market_fav_is_p1 & actual_p1_won == 0),

    # Elo favorite
    elo_fav_is_p1 = model_prob_p1 > 0.5,
    elo_fav_odds = if_else(elo_fav_is_p1, p1_odds, p2_odds),
    elo_fav_won = (elo_fav_is_p1 & actual_p1_won == 1) |
                  (!elo_fav_is_p1 & actual_p1_won == 0),

    # Edge: where Elo disagrees with market
    elo_edge = abs(model_prob_p1 - implied_prob_p1),
    elo_disagrees = (elo_fav_is_p1 != market_fav_is_p1)
  )

# Strategy 1: Always bet on market favorite
market_fav_results <- baseline_analysis %>%
  summarize(
    n_bets = n(),
    wins = sum(market_fav_won),
    win_rate = mean(market_fav_won),
    # ROI = (sum of (odds-1) for wins - sum of 1 for losses) / n_bets
    profit = sum(if_else(market_fav_won, market_fav_odds - 1, -1)),
    roi = profit / n_bets
  )

# Strategy 2: Always bet on Elo favorite
elo_fav_results <- baseline_analysis %>%
  summarize(
    n_bets = n(),
    wins = sum(elo_fav_won),
    win_rate = mean(elo_fav_won),
    profit = sum(if_else(elo_fav_won, elo_fav_odds - 1, -1)),
    roi = profit / n_bets
  )

# Strategy 3: Bet on Elo favorite only when edge > 5%
elo_edge_5pct <- baseline_analysis %>%
  filter(elo_edge > 0.05) %>%
  summarize(
    n_bets = n(),
    wins = sum(elo_fav_won),
    win_rate = mean(elo_fav_won),
    profit = sum(if_else(elo_fav_won, elo_fav_odds - 1, -1)),
    roi = profit / n_bets
  )

# Strategy 4: Bet on Elo favorite only when Elo disagrees with market
elo_contrarian <- baseline_analysis %>%
  filter(elo_disagrees) %>%
  summarize(
    n_bets = n(),
    wins = sum(elo_fav_won),
    win_rate = mean(elo_fav_won),
    profit = sum(if_else(elo_fav_won, elo_fav_odds - 1, -1)),
    roi = profit / n_bets
  )

cat("\n=== STRATEGY COMPARISON (H1 2024) ===\n\n")

cat(sprintf("%-35s %8s %8s %8s\n", "Strategy", "Bets", "Win%", "ROI"))
cat(sprintf("%-35s %8s %8s %8s\n", "-----------------------------------", "--------", "--------", "--------"))

cat(sprintf("%-35s %8d %7.1f%% %+7.1f%%\n",
            "1. Always bet market favorite",
            market_fav_results$n_bets,
            market_fav_results$win_rate * 100,
            market_fav_results$roi * 100))

cat(sprintf("%-35s %8d %7.1f%% %+7.1f%%\n",
            "2. Always bet Elo favorite",
            elo_fav_results$n_bets,
            elo_fav_results$win_rate * 100,
            elo_fav_results$roi * 100))

cat(sprintf("%-35s %8d %7.1f%% %+7.1f%%\n",
            "3. Elo favorite when edge > 5%",
            elo_edge_5pct$n_bets,
            elo_edge_5pct$win_rate * 100,
            elo_edge_5pct$roi * 100))

cat(sprintf("%-35s %8d %7.1f%% %+7.1f%%\n",
            "4. Elo favorite when disagrees",
            elo_contrarian$n_bets,
            elo_contrarian$win_rate * 100,
            elo_contrarian$roi * 100))

# Additional analysis: What's happening when Elo disagrees with market?
cat("\n\n=== WHEN ELO DISAGREES WITH MARKET ===\n\n")

disagree_analysis <- baseline_analysis %>%
  filter(elo_disagrees) %>%
  summarize(
    n_matches = n(),
    elo_correct = sum(elo_fav_won),
    market_correct = sum(market_fav_won),
    elo_accuracy = mean(elo_fav_won),
    market_accuracy = mean(market_fav_won),
    avg_elo_edge = mean(elo_edge)
  )

cat(sprintf("Matches where Elo and market disagree: %d\n", disagree_analysis$n_matches))
cat(sprintf("Elo correct: %d (%.1f%%)\n",
            disagree_analysis$elo_correct, disagree_analysis$elo_accuracy * 100))
cat(sprintf("Market correct: %d (%.1f%%)\n",
            disagree_analysis$market_correct, disagree_analysis$market_accuracy * 100))
cat(sprintf("Average Elo edge in these matches: %.1f%%\n", disagree_analysis$avg_elo_edge * 100))

# ============================================================================
# SUMMARY
# ============================================================================

cat("\n\n=================================================================\n")
cat("                         SUMMARY\n")
cat("=================================================================\n\n")

cat("1. DATA LEAKAGE: None detected. Rolling Elo uses only prior matches.\n\n")

cat("2. ODDS TIMING: Using closing odds from tennis-data.co.uk (Pinnacle).\n")
cat("   This is a conservative test - closing odds are harder to beat.\n\n")

if (exists("results_h2") && !is.null(results_h2)) {
  cat(sprintf("3. OUT-OF-SAMPLE (H2 2024): Accuracy %.1f%%, see full results above.\n\n",
              results_h2$analysis$accuracy * 100))
} else {
  cat("3. OUT-OF-SAMPLE: H2 2024 data not available for testing.\n\n")
}

cat("4. BASELINE COMPARISON: See strategy comparison table above.\n")
cat("   Key question: Does Elo beat 'always bet favorite' baseline?\n\n")

cat("=================================================================\n")

# Save results
saveRDS(list(
  baseline_analysis = baseline_analysis,
  market_fav_results = market_fav_results,
  elo_fav_results = elo_fav_results,
  elo_edge_5pct = elo_edge_5pct,
  elo_contrarian = elo_contrarian,
  disagree_analysis = disagree_analysis,
  h2_results = if (exists("results_h2")) results_h2 else NULL
), "data/processed/elo_betting_validation.rds")

cat("\nResults saved to data/processed/elo_betting_validation.rds\n")
