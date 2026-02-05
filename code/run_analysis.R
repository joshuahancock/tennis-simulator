# Master Script: Tennis Match Simulator
# ======================================
# This script runs the complete analysis pipeline from raw data to final outputs.
#
# Usage:
#   Rscript code/run_analysis.R
#   # Or in R console:
#   source("code/run_analysis.R")
#
# Prerequisites:
#   1. Raw data in data/raw/ (ATP/WTA match data, betting data)
#   2. R packages installed (see code/README.md)
#
# Output:
#   - Backtest results saved to data/processed/
#   - Summary printed to console

# ============================================================================
# CONFIGURATION
# ============================================================================

# Set working directory to project root (if not already there)
if (!file.exists("CLAUDE.md")) {
  stop("Please run this script from the project root directory (tennis-simulator/)")
}

# Analysis parameters
BACKTEST_START_DATE <- "2024-01-01"
BACKTEST_END_DATE <- "2024-06-30"
TOUR <- "ATP"
N_SIMS <- 1000  # Simulations per match (increase for final results)
REQUIRE_PLAYER_DATA <- TRUE  # Skip matches where players lack sufficient data
RANDOM_SEED <- 20260204

# Output file
OUTPUT_FILE <- sprintf("data/processed/backtest_%s_%s_to_%s.rds",
                       tolower(TOUR),
                       gsub("-", "", BACKTEST_START_DATE),
                       gsub("-", "", BACKTEST_END_DATE))

# ============================================================================
# SETUP
# ============================================================================

cat("=" %>% rep(70) %>% paste(collapse = ""), "\n")
cat("TENNIS MATCH SIMULATOR - FULL ANALYSIS PIPELINE\n")
cat("=" %>% rep(70) %>% paste(collapse = ""), "\n\n")

cat(sprintf("Start date: %s\n", BACKTEST_START_DATE))
cat(sprintf("End date: %s\n", BACKTEST_END_DATE))
cat(sprintf("Tour: %s\n", TOUR))
cat(sprintf("Simulations per match: %d\n", N_SIMS))
cat(sprintf("Random seed: %d\n", RANDOM_SEED))
cat(sprintf("Output file: %s\n", OUTPUT_FILE))
cat("\n")

# Load required packages
cat("Loading packages...\n")
suppressPackageStartupMessages({
  library(tidyverse)
  library(lubridate)
})

# ============================================================================
# SOURCE SIMULATOR CODE
# ============================================================================

cat("Loading simulator code...\n")

# The main backtest script sources all dependencies
source("r_analysis/simulator/06_backtest.R")

cat("Simulator code loaded successfully.\n\n")

# ============================================================================
# RUN BACKTEST
# ============================================================================

cat("Starting backtest...\n\n")

start_time <- Sys.time()

results <- backtest_period(
  start_date = BACKTEST_START_DATE,
  end_date = BACKTEST_END_DATE,
  model = "base",
  tour = TOUR,
  n_sims = N_SIMS,
  require_player_data = REQUIRE_PLAYER_DATA,
  seed = RANDOM_SEED
)

end_time <- Sys.time()
elapsed <- difftime(end_time, start_time, units = "mins")

cat(sprintf("\nBacktest completed in %.1f minutes.\n", as.numeric(elapsed)))

# ============================================================================
# SAVE RESULTS
# ============================================================================

cat(sprintf("\nSaving results to %s...\n", OUTPUT_FILE))

# Add metadata to results
results$metadata <- list(
  script = "code/run_analysis.R",
  run_date = Sys.time(),
  elapsed_minutes = as.numeric(elapsed),
  r_version = R.version.string,
  seed = RANDOM_SEED
)

saveRDS(results, OUTPUT_FILE)
cat("Results saved.\n")

# ============================================================================
# SUMMARY
# ============================================================================

cat("\n")
cat("=" %>% rep(70) %>% paste(collapse = ""), "\n")
cat("SUMMARY\n")
cat("=" %>% rep(70) %>% paste(collapse = ""), "\n\n")

cat(sprintf("Matches analyzed: %d\n", results$n_matches))
cat(sprintf("Matches skipped (insufficient data): %d\n", results$n_skipped))
cat(sprintf("Errors: %d\n", results$n_errors))
cat(sprintf("Random seed: %d\n", results$seed))

cat(sprintf("\nAccuracy: %.1f%%\n", results$analysis$accuracy * 100))
cat(sprintf("Brier Score: %.4f\n", results$analysis$brier_score))
cat(sprintf("Log Loss: %.4f\n", results$analysis$log_loss))

cat("\nROI by edge threshold:\n")
for (threshold in names(results$analysis$betting_results)) {
  br <- results$analysis$betting_results[[threshold]]
  cat(sprintf("  %s%%: %+.1f%% ROI (%d bets, %.1f%% win rate)\n",
              as.numeric(threshold) * 100,
              br$roi * 100,
              br$n_bets,
              br$win_rate * 100))
}

cat("\n")
cat("=" %>% rep(70) %>% paste(collapse = ""), "\n")
cat("ANALYSIS COMPLETE\n")
cat("=" %>% rep(70) %>% paste(collapse = ""), "\n")
