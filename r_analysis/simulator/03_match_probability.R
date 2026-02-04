# Match Probability Calculator
# Run Monte Carlo simulations to estimate match win probabilities
#
# Usage:
#   source("r_analysis/simulator/03_match_probability.R")
#   result <- simulate_match_probability("Novak Djokovic", "Carlos Alcaraz",
#                                        surface = "Hard", best_of = 3)

library(tidyverse)

# Source required files
source("r_analysis/simulator/01_mc_engine.R")
source("r_analysis/simulator/02_player_stats.R")

# ============================================================================
# MATCH PROBABILITY SIMULATION
# ============================================================================

#' Simulate match probability between two players
#' @param player1 Player 1 name
#' @param player2 Player 2 name
#' @param surface Surface ("Hard", "Clay", "Grass")
#' @param best_of Number of sets (3 or 5)
#' @param n_sims Number of simulations to run
#' @param stats_db Optional pre-loaded stats database (speeds up repeated calls)
#' @param feature_db Optional feature database for similarity-based fallback
#' @param tour "ATP" or "WTA"
#' @param final_set_tb Final set tiebreak rule
#' @param verbose Whether to print progress
#' @param use_adjustment Whether to use opponent adjustment (NULL = use global setting)
#' @param require_player_data If TRUE, return NULL when either player lacks real data (uses tour_average)
#' @return List with win probabilities, confidence intervals, and score distribution. NULL if skipped.
simulate_match_probability <- function(player1, player2,
                                        surface = "Hard",
                                        best_of = 3,
                                        n_sims = 10000,
                                        stats_db = NULL,
                                        feature_db = NULL,
                                        tour = "ATP",
                                        final_set_tb = "normal",
                                        verbose = TRUE,
                                        use_adjustment = NULL,
                                        require_player_data = FALSE) {

  # Load stats database if not provided
  if (is.null(stats_db)) {
    if (verbose) cat("Loading player statistics...\n")
    stats_db <- load_player_stats(tour = tour)
  }

  # Get player stats
  if (verbose) cat(sprintf("Getting stats for %s vs %s on %s...\n",
                           player1, player2, surface))

  p1_stats <- get_player_stats(player1, surface = surface, stats_db = stats_db, feature_db = feature_db)
  p2_stats <- get_player_stats(player2, surface = surface, stats_db = stats_db, feature_db = feature_db)

  # Skip if either player lacks real data and require_player_data is TRUE
  if (require_player_data) {
    if (p1_stats$source == "tour_average" || p2_stats$source == "tour_average") {
      if (verbose) {
        cat(sprintf("  SKIPPED: Insufficient data (p1: %s, p2: %s)\n",
                    p1_stats$source, p2_stats$source))
      }
      return(list(
        skipped = TRUE,
        reason = "insufficient_data",
        p1_source = p1_stats$source,
        p2_source = p2_stats$source
      ))
    }
  }

  if (verbose) {
    cat(sprintf("  %s: serve=%.1f%%, 1st in=%.1f%%, 1st won=%.1f%%, return=%.1f%% (%s, %d matches)\n",
                player1,
                (p1_stats$first_in_pct * p1_stats$first_won_pct +
                   (1-p1_stats$first_in_pct) * p1_stats$second_won_pct) * 100,
                p1_stats$first_in_pct * 100,
                p1_stats$first_won_pct * 100,
                (p1_stats$return_vs_first + p1_stats$return_vs_second) / 2 * 100,
                p1_stats$source, p1_stats$matches))
    cat(sprintf("  %s: serve=%.1f%%, 1st in=%.1f%%, 1st won=%.1f%%, return=%.1f%% (%s, %d matches)\n",
                player2,
                (p2_stats$first_in_pct * p2_stats$first_won_pct +
                   (1-p2_stats$first_in_pct) * p2_stats$second_won_pct) * 100,
                p2_stats$first_in_pct * 100,
                p2_stats$first_won_pct * 100,
                (p2_stats$return_vs_first + p2_stats$return_vs_second) / 2 * 100,
                p2_stats$source, p2_stats$matches))
  }

  # Run simulations
  if (verbose) cat(sprintf("Running %s simulations...\n", format(n_sims, big.mark = ",")))

  results <- vector("list", n_sims)

  for (i in 1:n_sims) {
    results[[i]] <- simulate_match(p1_stats, p2_stats, best_of = best_of,
                                   final_set_tb = final_set_tb,
                                   use_adjustment = use_adjustment)
  }

  # Analyze results
  winners <- sapply(results, function(r) r$winner)
  scores <- sapply(results, function(r) r$score_string)

  p1_wins <- sum(winners == 1)
  p1_win_prob <- p1_wins / n_sims

  # Calculate confidence interval (Wilson score interval)
  ci <- prop_ci(p1_wins, n_sims, conf_level = 0.95)

  # Score distribution
  score_dist <- table(scores)
  score_dist <- sort(score_dist, decreasing = TRUE)
  score_df <- tibble(
    score = names(score_dist),
    count = as.integer(score_dist),
    pct = count / n_sims * 100
  )

  # Set score distribution
  set_scores <- sapply(results, function(r) paste(r$score[1], r$score[2], sep = "-"))
  set_dist <- table(set_scores)
  set_dist <- sort(set_dist, decreasing = TRUE)

  if (verbose) {
    cat(sprintf("\nResults:\n"))
    cat(sprintf("  %s win probability: %.1f%% (95%% CI: %.1f%% - %.1f%%)\n",
                player1, p1_win_prob * 100, ci$lower * 100, ci$upper * 100))
    cat(sprintf("  %s win probability: %.1f%%\n", player2, (1 - p1_win_prob) * 100))
    cat(sprintf("\nMost common scores:\n"))
    print(head(score_df, 10), n = 10)
  }

  return(list(
    player1 = player1,
    player2 = player2,
    surface = surface,
    best_of = best_of,
    n_sims = n_sims,
    p1_win_prob = p1_win_prob,
    p2_win_prob = 1 - p1_win_prob,
    ci_lower = ci$lower,
    ci_upper = ci$upper,
    p1_stats = p1_stats,
    p2_stats = p2_stats,
    score_distribution = score_df,
    set_distribution = set_dist,
    raw_results = results
  ))
}

#' Wilson score confidence interval for proportion
#' @param successes Number of successes
#' @param trials Number of trials
#' @param conf_level Confidence level (default 0.95)
#' @return List with lower and upper bounds
prop_ci <- function(successes, trials, conf_level = 0.95) {
  n <- trials
  p <- successes / n
  z <- qnorm(1 - (1 - conf_level) / 2)

  denominator <- 1 + z^2 / n
  centre <- p + z^2 / (2 * n)
  spread <- z * sqrt((p * (1 - p) + z^2 / (4 * n)) / n)

  list(
    lower = (centre - spread) / denominator,
    upper = (centre + spread) / denominator
  )
}

# ============================================================================
# BATCH SIMULATION
# ============================================================================

#' Simulate match probabilities for multiple matches
#' @param matchups Dataframe with columns: player1, player2, surface, best_of
#' @param n_sims Number of simulations per match
#' @param stats_db Optional pre-loaded stats database
#' @param tour "ATP" or "WTA"
#' @param parallel Whether to use parallel processing
#' @return Dataframe with match probabilities
simulate_batch <- function(matchups, n_sims = 10000, stats_db = NULL,
                           tour = "ATP", parallel = FALSE) {

  if (is.null(stats_db)) {
    cat("Loading player statistics...\n")
    stats_db <- load_player_stats(tour = tour)
  }

  n_matches <- nrow(matchups)
  cat(sprintf("Simulating %d matches with %s sims each...\n",
              n_matches, format(n_sims, big.mark = ",")))

  results <- vector("list", n_matches)

  for (i in 1:n_matches) {
    if (i %% 10 == 0) cat(sprintf("  Match %d/%d\n", i, n_matches))

    row <- matchups[i, ]
    surface <- if("surface" %in% names(row)) row$surface else "Hard"
    best_of <- if("best_of" %in% names(row)) row$best_of else 3

    result <- simulate_match_probability(
      player1 = row$player1,
      player2 = row$player2,
      surface = surface,
      best_of = best_of,
      n_sims = n_sims,
      stats_db = stats_db,
      tour = tour,
      verbose = FALSE
    )

    results[[i]] <- tibble(
      player1 = row$player1,
      player2 = row$player2,
      surface = surface,
      best_of = best_of,
      p1_win_prob = result$p1_win_prob,
      p2_win_prob = result$p2_win_prob,
      ci_lower = result$ci_lower,
      ci_upper = result$ci_upper,
      p1_source = result$p1_stats$source,
      p2_source = result$p2_stats$source,
      p1_matches = result$p1_stats$matches,
      p2_matches = result$p2_stats$matches
    )
  }

  bind_rows(results)
}

# ============================================================================
# MODEL VALIDATION
# ============================================================================

#' Validate model against historical match outcomes
#' @param matches Dataframe with historical matches (winner_name, loser_name, surface)
#' @param n_sims Simulations per match
#' @param stats_db Pre-loaded stats database
#' @param tour "ATP" or "WTA"
#' @return List with validation metrics
validate_model <- function(matches, n_sims = 1000, stats_db = NULL, tour = "ATP") {

  if (is.null(stats_db)) {
    stats_db <- load_player_stats(tour = tour)
  }

  n_matches <- nrow(matches)
  cat(sprintf("Validating on %d matches...\n", n_matches))

  results <- vector("list", n_matches)

  for (i in 1:n_matches) {
    if (i %% 100 == 0) cat(sprintf("  Match %d/%d\n", i, n_matches))

    row <- matches[i, ]

    tryCatch({
      sim_result <- simulate_match_probability(
        player1 = row$winner_name,
        player2 = row$loser_name,
        surface = row$surface,
        best_of = if("best_of" %in% names(row)) row$best_of else 3,
        n_sims = n_sims,
        stats_db = stats_db,
        tour = tour,
        verbose = FALSE
      )

      results[[i]] <- tibble(
        winner = row$winner_name,
        loser = row$loser_name,
        surface = row$surface,
        predicted_prob = sim_result$p1_win_prob,  # P(winner wins)
        actual = 1  # Winner always won
      )
    }, error = function(e) {
      results[[i]] <- NULL
    })
  }

  results_df <- bind_rows(results)

  # Calculate metrics
  # Brier score: mean squared error of probability predictions
  brier_score <- mean((results_df$predicted_prob - results_df$actual)^2)

  # Log loss
  eps <- 1e-15  # Avoid log(0)
  log_loss <- -mean(results_df$actual * log(pmax(results_df$predicted_prob, eps)) +
                      (1 - results_df$actual) * log(pmax(1 - results_df$predicted_prob, eps)))

  # Calibration: bin predictions and compare to actual win rates
  results_df <- results_df %>%
    mutate(prob_bin = cut(predicted_prob, breaks = seq(0, 1, 0.1), include.lowest = TRUE))

  calibration <- results_df %>%
    group_by(prob_bin) %>%
    summarize(
      n = n(),
      mean_pred = mean(predicted_prob),
      actual_rate = mean(actual),
      .groups = "drop"
    )

  # Accuracy at various thresholds
  accuracy_50 <- mean(results_df$predicted_prob > 0.5)  # Correctly predicted winner

  cat(sprintf("\nValidation Results:\n"))
  cat(sprintf("  Matches validated: %d\n", nrow(results_df)))
  cat(sprintf("  Brier Score: %.4f (lower is better, 0.25 = random)\n", brier_score))
  cat(sprintf("  Log Loss: %.4f\n", log_loss))
  cat(sprintf("  Accuracy (predicted favorite won): %.1f%%\n", accuracy_50 * 100))

  cat("\nCalibration (predicted vs actual):\n")
  print(calibration)

  return(list(
    n_matches = nrow(results_df),
    brier_score = brier_score,
    log_loss = log_loss,
    accuracy = accuracy_50,
    calibration = calibration,
    predictions = results_df
  ))
}

#' Create calibration plot
#' @param validation_result Result from validate_model()
#' @return ggplot object
plot_calibration <- function(validation_result) {
  cal <- validation_result$calibration

  ggplot(cal, aes(x = mean_pred, y = actual_rate)) +
    geom_abline(slope = 1, intercept = 0, linetype = "dashed", color = "gray50") +
    geom_point(aes(size = n), color = "steelblue") +
    geom_line(color = "steelblue") +
    scale_x_continuous(limits = c(0, 1), labels = scales::percent) +
    scale_y_continuous(limits = c(0, 1), labels = scales::percent) +
    labs(
      title = "Model Calibration",
      subtitle = sprintf("Brier Score: %.4f", validation_result$brier_score),
      x = "Predicted Win Probability",
      y = "Actual Win Rate",
      size = "N Matches"
    ) +
    theme_minimal()
}

# ============================================================================
# IMPLIED ODDS CONVERSION
# ============================================================================

#' Convert probability to decimal odds
#' @param prob Probability (0-1)
#' @return Decimal odds
prob_to_odds <- function(prob) {
  1 / prob
}

#' Convert decimal odds to probability
#' @param odds Decimal odds
#' @return Probability (0-1)
odds_to_prob <- function(odds) {
  1 / odds
}

#' Calculate edge (model prob - implied prob from odds)
#' @param model_prob Model's predicted probability
#' @param odds Decimal odds offered
#' @return Edge (positive = value bet)
calculate_edge <- function(model_prob, odds) {
  implied_prob <- odds_to_prob(odds)
  model_prob - implied_prob
}

#' Convert American odds to decimal
#' @param american American odds (e.g., -150 or +200)
#' @return Decimal odds
american_to_decimal <- function(american) {
  if (american > 0) {
    1 + american / 100
  } else {
    1 + 100 / abs(american)
  }
}

# ============================================================================
# QUICK TEST
# ============================================================================

if (FALSE) {  # Set to TRUE to run test
  # Simulate a single match
  result <- simulate_match_probability(
    "Novak Djokovic", "Carlos Alcaraz",
    surface = "Hard",
    best_of = 3,
    n_sims = 10000
  )

  # Compare surfaces
  cat("\n\nComparing surfaces for Nadal vs Djokovic:\n")
  for (s in c("Hard", "Clay", "Grass")) {
    r <- simulate_match_probability(
      "Rafael Nadal", "Novak Djokovic",
      surface = s, best_of = 3, n_sims = 5000, verbose = FALSE
    )
    cat(sprintf("  %s: Nadal %.1f%% - Djokovic %.1f%%\n",
                s, r$p1_win_prob * 100, r$p2_win_prob * 100))
  }
}
