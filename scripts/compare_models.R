# Compare Elo vs MC model performance
# Run from project root: Rscript scripts/compare_models.R
#
# IMPORTANT: This script runs both models on the IDENTICAL match set
# to ensure an apples-to-apples comparison.

cat("=== Model Comparison: Elo vs Monte Carlo ===\n\n")

# Source backtest framework (which sources everything else)
source("src/backtesting/backtest.R")

# Run MC model backtest first (to identify which matches have sufficient data)
cat("Running MC (base) model backtest (H1 2024)...\n")
cat("Using require_player_data=TRUE to filter to matches with real data\n\n")
results_mc <- backtest_period(
  start_date = "2024-01-01",
  end_date = "2024-06-30",
  model = "base",
  tour = "ATP",
  require_player_data = TRUE,
  seed = 20260204
)

cat("\n\n")

# Run Elo model backtest (on all matches)
cat("Running Elo model backtest (H1 2024)...\n")
results_elo_full <- backtest_period(
  start_date = "2024-01-01",
  end_date = "2024-06-30",
  model = "elo",
  tour = "ATP",
  seed = 20260204
)

# ============================================================================
# APPLES-TO-APPLES COMPARISON
# Filter Elo predictions to only matches that MC also predicted
# ============================================================================

cat("\n\n=== CREATING APPLES-TO-APPLES COMPARISON ===\n\n")

# Get the match identifiers from MC predictions
mc_matches <- results_mc$predictions %>%
  mutate(match_id = paste(match_date, player1, player2, sep = "_"))

elo_matches <- results_elo_full$predictions %>%
  mutate(match_id = paste(match_date, player1, player2, sep = "_"))

# Filter Elo to only common matches
common_match_ids <- intersect(mc_matches$match_id, elo_matches$match_id)
cat(sprintf("MC matches: %d\n", nrow(mc_matches)))
cat(sprintf("Elo matches (full): %d\n", nrow(elo_matches)))
cat(sprintf("Common matches: %d\n", length(common_match_ids)))

elo_common <- elo_matches %>%
  filter(match_id %in% common_match_ids)

mc_common <- mc_matches %>%
  filter(match_id %in% common_match_ids)

# Recalculate metrics on common sample
calculate_metrics <- function(predictions, name) {
  accuracy <- mean(predictions$correct_prediction)
  brier <- mean((predictions$model_prob_p1 - predictions$actual_p1_won)^2)
  eps <- 1e-15
  log_loss <- -mean(
    predictions$actual_p1_won * log(pmax(predictions$model_prob_p1, eps)) +
    (1 - predictions$actual_p1_won) * log(pmax(1 - predictions$model_prob_p1, eps))
  )
  list(name = name, n = nrow(predictions), accuracy = accuracy, brier = brier, log_loss = log_loss)
}

elo_metrics <- calculate_metrics(elo_common, "Elo")
mc_metrics <- calculate_metrics(mc_common, "MC")

# ============================================================================
# RESULTS
# ============================================================================

cat("\n=== MODEL COMPARISON SUMMARY (SAME SAMPLE) ===\n\n")
cat(sprintf("Sample size: %d matches (identical for both models)\n\n", length(common_match_ids)))

cat("Elo Model:\n")
cat(sprintf("  Accuracy: %.1f%%\n", elo_metrics$accuracy * 100))
cat(sprintf("  Brier Score: %.4f\n", elo_metrics$brier))
cat(sprintf("  Log Loss: %.4f\n", elo_metrics$log_loss))

cat("\nMonte Carlo Model:\n")
cat(sprintf("  Accuracy: %.1f%%\n", mc_metrics$accuracy * 100))
cat(sprintf("  Brier Score: %.4f\n", mc_metrics$brier))
cat(sprintf("  Log Loss: %.4f\n", mc_metrics$log_loss))

cat("\nDifference (Elo - MC):\n")
cat(sprintf("  Accuracy: %+.1f pp\n", (elo_metrics$accuracy - mc_metrics$accuracy) * 100))
cat(sprintf("  Brier Score: %+.4f (negative = Elo better)\n", elo_metrics$brier - mc_metrics$brier))
cat(sprintf("  Log Loss: %+.4f (negative = Elo better)\n", elo_metrics$log_loss - mc_metrics$log_loss))

# Also report Elo on full sample for reference
cat("\n=== ELO ON FULL SAMPLE (for reference) ===\n")
cat(sprintf("Matches: %d\n", results_elo_full$n_matches))
cat(sprintf("Accuracy: %.1f%%\n", results_elo_full$analysis$accuracy * 100))
cat(sprintf("Brier Score: %.4f\n", results_elo_full$analysis$brier))

# Save results
saveRDS(list(
  elo_full = results_elo_full,
  mc = results_mc,
  elo_common = elo_common,
  mc_common = mc_common,
  elo_metrics = elo_metrics,
  mc_metrics = mc_metrics,
  common_match_ids = common_match_ids
), "data/processed/model_comparison_h1_2024.rds")

cat("\nResults saved to data/processed/model_comparison_h1_2024.rds\n")
