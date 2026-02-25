# K-Factor Sensitivity Analysis
# Test K = 24, 32 (current), 48, 64 on clean H1 2024 data
# Addresses referee concern raised in Rounds 3, 4, 5, 6

library(tidyverse)

# Load pre-aligned historical matches
hist_matches <- readRDS("data/processed/atp_matches_aligned.rds")

# Load the clean Elo backtest to get the matches we're comparing against
elo_clean <- readRDS("data/processed/backtest_elo_h1_2024_clean.rds")
baseline_accuracy <- elo_clean$analysis$accuracy
baseline_brier <- elo_clean$analysis$brier_score

cat("=== K-FACTOR SENSITIVITY ANALYSIS ===\n")
cat("Testing K = 24, 32 (current), 48, 64\n")
cat(sprintf("Baseline (K=32): Accuracy %.1f%%, Brier %.4f\n\n",
            100 * baseline_accuracy, baseline_brier))

# K-factors to test
k_factors <- c(24, 32, 48, 64)

results <- list()

for (k in k_factors) {
  cat(sprintf("\n--- Testing K = %d ---\n", k))

  # Get matches before 2024 for training
 training_matches <- hist_matches %>%
    filter(match_date < as.Date("2024-01-01")) %>%
    filter(!is.na(winner_name), !is.na(loser_name), !is.na(surface)) %>%
    arrange(match_date)

  cat(sprintf("Training on %d matches (pre-2024)\n", nrow(training_matches)))

  # Initialize Elo ratings
  elo_ratings <- list()

  # Process training matches
  for (i in 1:nrow(training_matches)) {
    match <- training_matches[i, ]
    winner <- match$winner_name
    loser <- match$loser_name

    # Get current ratings (default 1500)
    winner_elo <- elo_ratings[[winner]]
    if (is.null(winner_elo)) winner_elo <- 1500
    loser_elo <- elo_ratings[[loser]]
    if (is.null(loser_elo)) loser_elo <- 1500

    # Calculate expected and update
    expected_winner <- 1 / (1 + 10^((loser_elo - winner_elo) / 400))

    # Use the test K-factor
    elo_ratings[[winner]] <- winner_elo + k * (1 - expected_winner)
    elo_ratings[[loser]] <- loser_elo + k * (0 - (1 - expected_winner))
  }

  cat(sprintf("Trained Elo ratings for %d players\n", length(elo_ratings)))

  # Now predict H1 2024 matches with rolling updates
  test_matches <- hist_matches %>%
    filter(match_date >= as.Date("2024-01-01"),
           match_date <= as.Date("2024-06-30")) %>%
    filter(!is.na(winner_name), !is.na(loser_name)) %>%
    arrange(match_date)

  cat(sprintf("Testing on %d matches (H1 2024)\n", nrow(test_matches)))

  predictions <- vector("list", nrow(test_matches))

  for (i in 1:nrow(test_matches)) {
    match <- test_matches[i, ]
    winner <- match$winner_name
    loser <- match$loser_name

    # Get current Elo ratings
    winner_elo <- elo_ratings[[winner]]
    if (is.null(winner_elo)) winner_elo <- 1500
    loser_elo <- elo_ratings[[loser]]
    if (is.null(loser_elo)) loser_elo <- 1500

    # Elo prediction
    elo_prob_winner <- 1 / (1 + 10^((loser_elo - winner_elo) / 400))

    # Record prediction
    predictions[[i]] <- list(
      match_date = match$match_date,
      winner = winner,
      loser = loser,
      winner_elo = winner_elo,
      loser_elo = loser_elo,
      elo_prob_winner = elo_prob_winner,
      elo_correct = elo_prob_winner > 0.5
    )

    # Update Elo with this match result (rolling)
    expected_winner <- elo_prob_winner
    elo_ratings[[winner]] <- winner_elo + k * (1 - expected_winner)
    elo_ratings[[loser]] <- loser_elo + k * (0 - (1 - expected_winner))
  }

  # Convert to dataframe
  predictions_df <- bind_rows(lapply(predictions, as_tibble))

  # Calculate metrics
  accuracy <- mean(predictions_df$elo_correct)
  # Brier: (predicted - actual)^2 where actual = 1 for winner
  brier_score <- mean((predictions_df$elo_prob_winner - 1)^2)

  cat(sprintf("Accuracy: %.1f%%\n", 100 * accuracy))
  cat(sprintf("Brier Score: %.4f\n", brier_score))

  results[[as.character(k)]] <- list(
    k = k,
    accuracy = accuracy,
    brier = brier_score,
    n_matches = nrow(predictions_df),
    predictions = predictions_df
  )
}

cat("\n\n=== SUMMARY: K-FACTOR SENSITIVITY ===\n\n")

summary_df <- tibble(
  K = k_factors,
  Accuracy = sapply(k_factors, function(x) sprintf("%.1f%%", 100 * results[[as.character(x)]]$accuracy)),
  Brier = sapply(k_factors, function(x) sprintf("%.4f", results[[as.character(x)]]$brier)),
  N = sapply(k_factors, function(x) results[[as.character(x)]]$n_matches)
)

print(summary_df)

cat("\n=== INTERPRETATION ===\n")
cat("Lower K = more stable ratings, slower to react to recent form\n")
cat("Higher K = more volatile ratings, faster to react to recent form\n\n")

# Compare to baseline
cat("Comparison to baseline (K=32 from clean backtest):\n")
cat(sprintf("  Baseline accuracy: %.1f%%\n", 100 * baseline_accuracy))
cat(sprintf("  Baseline Brier: %.4f\n", baseline_brier))

# Save results
saveRDS(results, "data/processed/k_factor_sensitivity_results.rds")
cat("\nSaved detailed results to data/processed/k_factor_sensitivity_results.rds\n")
