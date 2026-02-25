# Backtesting Framework for Tennis Simulator
# Evaluate model performance against historical betting lines
#
# Usage:
#   source("src/backtesting/backtest.R")
#   results <- backtest_period("2022-01-01", "2023-12-31", model = "base")

library(tidyverse)
library(lubridate)

# Source required files
source("src/models/monte_carlo/mc_engine.R")
source("src/data/player_stats.R")
source("src/models/monte_carlo/match_probability.R")
source("src/models/monte_carlo/similarity.R")
source("src/data/betting_data.R")
source("src/models/elo/elo_ratings.R")
source("src/data/date_alignment.R")

# ============================================================================
# CONFIGURATION
# ============================================================================

# Random seed for reproducibility
# Using date format YYYYMMDD for the seed
RANDOM_SEED <- 20260204

# Default edge thresholds for betting
EDGE_THRESHOLDS <- c(0.01, 0.03, 0.05, 0.10)

# Kelly criterion fraction (fractional Kelly for risk management)
KELLY_FRACTION <- 0.25

# Starting bankroll for simulations
STARTING_BANKROLL <- 10000

# Maximum bet as fraction of bankroll
MAX_BET_FRACTION <- 0.05

# Minimum odds to bet (avoid very heavy favorites)
MIN_ODDS <- 1.10

# Number of simulations for probability estimation
BACKTEST_N_SIMS <- 1000

# ============================================================================
# BACKTESTING CORE
# ============================================================================

#' Run backtest for a single match
#' @param match_row Row from betting data
#' @param stats_db Stats database
#' @param feature_db Feature database (for similarity model)
#' @param elo_db Elo database (for elo model)
#' @param model Model type: "base", "elo", "historical", "style", or "combined"
#' @param n_sims Number of simulations
#' @param stats_date_cutoff Only use stats from before this date
#' @param use_adjustment Whether to use opponent adjustment (NULL = use global setting)
#' @param require_player_data If TRUE, skip matches where either player lacks real data
#' @return List with prediction results, or skipped status
backtest_single_match <- function(match_row, stats_db, feature_db = NULL,
                                   elo_db = NULL,
                                   model = "base", n_sims = BACKTEST_N_SIMS,
                                   stats_date_cutoff = NULL,
                                   use_adjustment = NULL,
                                   require_player_data = FALSE) {

  winner <- match_row$winner
  loser <- match_row$loser
  surface <- match_row$surface
  best_of <- if(!is.na(match_row$best_of)) match_row$best_of else 3

  # Use alphabetical ordering for proper calibration analysis
  # This ensures we're not always predicting the winner
  players_sorted <- sort(c(winner, loser))
  player1 <- players_sorted[1]
  player2 <- players_sorted[2]
  p1_is_winner <- (player1 == winner)

  # Simulate match probability with alphabetical ordering
  tryCatch({
    if (model == "base") {
      result <- simulate_match_probability(
        player1 = player1,
        player2 = player2,
        surface = surface,
        best_of = best_of,
        n_sims = n_sims,
        stats_db = stats_db,
        feature_db = feature_db,
        verbose = FALSE,
        use_adjustment = use_adjustment,
        require_player_data = require_player_data
      )

      # Handle skipped matches
      if (!is.null(result$skipped) && result$skipped) {
        return(list(
          success = FALSE,
          skipped = TRUE,
          reason = result$reason,
          p1_source = result$p1_source,
          p2_source = result$p2_source
        ))
      }
    } else if (model == "elo") {
      # Elo-based prediction (no Monte Carlo simulation)
      if (is.null(elo_db)) {
        return(list(success = FALSE, error = "elo_db required for model='elo'"))
      }

      elo_result <- predict_match_elo(
        player1 = player1,
        player2 = player2,
        surface = surface,
        elo_db = elo_db,
        use_surface_elo = TRUE
      )

      # Create a result structure compatible with MC output
      result <- list(
        p1_win_prob = elo_result$p1_win_prob,
        p1_stats = list(source = elo_result$p1_info$source),
        p2_stats = list(source = elo_result$p2_info$source),
        p1_elo = elo_result$p1_elo,
        p2_elo = elo_result$p2_elo,
        elo_diff = elo_result$elo_diff
      )
    } else {
      # Use similarity-adjusted model
      use_historical <- model %in% c("historical", "combined")
      use_style <- model %in% c("style", "combined")

      result <- simulate_match_probability_adjusted(
        player1 = player1,
        player2 = player2,
        surface = surface,
        best_of = best_of,
        n_sims = n_sims,
        stats_db = stats_db,
        feature_db = feature_db,
        use_historical = use_historical,
        use_style = use_style,
        verbose = FALSE
      )
    }

    # p1_win_prob is P(player1 wins) where player1 is alphabetically first
    p1_win_prob <- result$p1_win_prob

    return(list(
      success = TRUE,
      player1 = player1,
      player2 = player2,
      winner = winner,
      loser = loser,
      surface = surface,
      p1_is_winner = p1_is_winner,
      model_prob_p1 = p1_win_prob,
      model_prob_p2 = 1 - p1_win_prob,
      p1_source = result$p1_stats$source,
      p2_source = result$p2_stats$source
    ))

  }, error = function(e) {
    return(list(
      success = FALSE,
      error = e$message
    ))
  })
}

#' Run backtest over a date range
#' @param start_date Start date (string or Date)
#' @param end_date End date (string or Date)
#' @param model Model type: "base", "elo", "historical", "style", or "combined"
#' @param tour "ATP" or "WTA"
#' @param betting_data Pre-loaded betting data (optional)
#' @param historical_matches Pre-loaded historical matches for stats calculation (optional)
#' @param feature_db Pre-loaded feature database (optional)
#' @param n_sims Simulations per match
#' @param progress_interval Print progress every N matches
#' @param stats_lookback_years How many years of history to use for stats (NULL = all)
#' @param use_adjustment Whether to use opponent adjustment (NULL = use global setting)
#' @param require_player_data If TRUE, skip matches where either player lacks real data
#' @return List with detailed results
backtest_period <- function(start_date, end_date, model = "base",
                            tour = "ATP", betting_data = NULL,
                            historical_matches = NULL, feature_db = NULL,
                            n_sims = BACKTEST_N_SIMS,
                            progress_interval = 50,
                            stats_lookback_years = NULL,
                            use_adjustment = NULL,
                            require_player_data = FALSE,
                            seed = RANDOM_SEED) {

  # Set random seed for reproducibility
  set.seed(seed)
  cat(sprintf("Random seed set to: %d\n", seed))

  start_date <- as_date(start_date)
  end_date <- as_date(end_date)

  # Determine adjustment setting for display
  adj_setting <- if (is.null(use_adjustment)) "global" else if (use_adjustment) "ON" else "OFF"
  data_req <- if (require_player_data) "REQUIRED" else "optional"

  cat(sprintf("\n=== BACKTESTING: %s to %s ===\n", start_date, end_date))
  cat(sprintf("Model: %s | Tour: %s | Sims/match: %d | Adjustment: %s\n", model, tour, n_sims, adj_setting))
  cat(sprintf("Player data: %s\n", data_req))
  cat("Using rolling stats calculation (no data leakage)\n\n")

  # Load betting data if not provided
  if (is.null(betting_data)) {
    cat("Loading betting data...\n")
    betting_data <- load_betting_data(tour = tour)
    if (is.null(betting_data)) {
      stop("No betting data available. Run download_betting_data() first.")
    }
    betting_data <- extract_best_odds(betting_data)
  }

  # Load historical matches for stats calculation if not provided
  if (is.null(historical_matches)) {
    cat("Loading historical matches for stats calculation...\n")
    if (str_to_upper(tour) == "ATP") {
      # Try to load pre-computed aligned matches first (fastest)
      cache_file <- "data/processed/atp_matches_aligned.rds"
      if (file.exists(cache_file)) {
        historical_matches <- readRDS(cache_file)
        cat("  Loaded pre-aligned matches from cache (no leakage)\n")
      } else if (exists("load_atp_matches_aligned")) {
        # Fall back to runtime alignment (slower)
        historical_matches <- load_atp_matches_aligned(
          year_from = 2015, year_to = year(end_date),
          betting_data = betting_data, verbose = FALSE
        )
        cat("  Using runtime date alignment (fixing tourney_date leakage)\n")
      } else {
        historical_matches <- load_atp_matches(year_from = 2015, year_to = year(end_date))
        warning("Date alignment not available - results may have data leakage")
      }
    } else {
      historical_matches <- load_wta_matches(year_from = 2015, year_to = year(end_date))
    }
  }

  # Build a full stats_db just for name standardization
  # (This doesn't cause leakage - it's just for matching names)
  cat("Building name mapping...\n")
  full_stats_db <- build_stats_db_from_matches(historical_matches, verbose = FALSE)

  # Standardize player names in betting data to match ATP format
  betting_data <- standardize_player_names(betting_data, full_stats_db)

  # Load feature database for similarity-based fallback (used by all models)
  if (is.null(feature_db)) {
    cat("Loading feature database for similarity fallback...\n")
    feature_db <- load_feature_matrix()
  }

  # Filter matches to date range
  matches <- betting_data %>%
    filter(
      match_date >= start_date,
      match_date <= end_date,
      !is.na(best_winner_odds),
      !is.na(best_loser_odds),
      best_winner_odds >= MIN_ODDS,
      best_loser_odds >= MIN_ODDS
    ) %>%
    arrange(match_date)

  n_matches <- nrow(matches)
  unique_dates <- unique(matches$match_date)
  cat(sprintf("Found %d matches across %d unique dates\n\n", n_matches, length(unique_dates)))

  if (n_matches == 0) {
    return(NULL)
  }

  # Run backtests with rolling stats calculation
  results <- vector("list", n_matches)
  errors <- 0
  skipped <- 0
  current_stats_db <- NULL
  current_elo_db <- NULL
  current_stats_date <- NULL

  for (i in 1:n_matches) {
    match_row <- matches[i, ]
    match_date <- match_row$match_date

    # Rebuild stats_db if date changed (cache for same-day matches)
    if (is.null(current_stats_date) || match_date != current_stats_date) {
      # Filter historical matches to BEFORE this match date
      # Use actual_match_date if available (from date alignment), otherwise fall back to match_date
      cutoff_date <- match_date
      date_col <- if ("actual_match_date" %in% names(historical_matches)) "actual_match_date" else "match_date"

      if (!is.null(stats_lookback_years)) {
        earliest_date <- cutoff_date - years(stats_lookback_years)
        prior_matches <- historical_matches %>%
          filter(.data[[date_col]] >= earliest_date, .data[[date_col]] < cutoff_date)
      } else {
        prior_matches <- historical_matches %>%
          filter(.data[[date_col]] < cutoff_date)
      }

      # Build stats from prior matches only
      current_stats_db <- build_stats_db_from_matches(prior_matches, verbose = FALSE)

      # Build Elo database if using Elo model
      if (model == "elo") {
        current_elo_db <- build_elo_db_from_matches(prior_matches, verbose = FALSE)
      }

      current_stats_date <- match_date

      if (i == 1 || i %% progress_interval == 0) {
        cat(sprintf("  [%s] Processing match %d/%d (%.0f%%) - stats from %d prior matches\n",
                    match_date, i, n_matches, i/n_matches*100, nrow(prior_matches)))
      }
    } else if (i %% progress_interval == 0) {
      cat(sprintf("  [%s] Processing match %d/%d (%.0f%%)...\n",
                  match_date, i, n_matches, i/n_matches*100))
    }

    # Skip if no prior matches available for stats
    if (is.null(current_stats_db)) {
      errors <- errors + 1
      next
    }

    bt_result <- backtest_single_match(
      match_row, current_stats_db, feature_db,
      elo_db = current_elo_db,
      model = model, n_sims = n_sims,
      use_adjustment = use_adjustment,
      require_player_data = require_player_data
    )

    if (bt_result$success) {
      # Determine odds for player1 and player2 (alphabetically ordered)
      if (bt_result$p1_is_winner) {
        p1_odds <- match_row$best_winner_odds
        p2_odds <- match_row$best_loser_odds
      } else {
        p1_odds <- match_row$best_loser_odds
        p2_odds <- match_row$best_winner_odds
      }

      results[[i]] <- tibble(
        match_date = match_row$match_date,
        tournament = match_row$tournament,
        round = match_row$round,
        surface = match_row$surface,
        # Alphabetically ordered players for calibration
        player1 = bt_result$player1,
        player2 = bt_result$player2,
        # Original winner/loser for reference
        winner = match_row$winner,
        loser = match_row$loser,
        # Odds mapped to alphabetical ordering
        p1_odds = p1_odds,
        p2_odds = p2_odds,
        odds_source = match_row$odds_source,
        # Model predictions (alphabetical ordering)
        model_prob_p1 = bt_result$model_prob_p1,
        model_prob_p2 = bt_result$model_prob_p2,
        # Implied probabilities (alphabetical ordering)
        implied_prob_p1 = odds_to_implied_prob(p1_odds),
        implied_prob_p2 = odds_to_implied_prob(p2_odds),
        # Actual outcome: 1 if player1 won, 0 if player2 won
        actual_p1_won = as.integer(bt_result$p1_is_winner),
        p1_source = bt_result$p1_source,
        p2_source = bt_result$p2_source
      )
    } else if (!is.null(bt_result$skipped) && bt_result$skipped) {
      skipped <- skipped + 1
    } else {
      errors <- errors + 1
    }
  }

  n_success <- n_matches - errors - skipped
  cat(sprintf("\nCompleted: %d successes, %d skipped (insufficient data), %d errors\n",
              n_success, skipped, errors))

  # Combine results
  results_df <- bind_rows(results)

  # Calculate edges and prediction correctness
  results_df <- results_df %>%
    mutate(
      # Edge for betting on player1 or player2
      edge_p1 = model_prob_p1 - implied_prob_p1,
      edge_p2 = model_prob_p2 - implied_prob_p2,
      # Did we correctly predict the winner?
      predicted_p1_wins = model_prob_p1 > 0.5,
      correct_prediction = predicted_p1_wins == (actual_p1_won == 1)
    )

  # Analyze results
  analysis <- analyze_backtest(results_df)

  return(list(
    model = model,
    start_date = start_date,
    end_date = end_date,
    n_matches = nrow(results_df),
    n_skipped = skipped,
    n_errors = errors,
    require_player_data = require_player_data,
    seed = seed,
    predictions = results_df,
    analysis = analysis
  ))
}

# ============================================================================
# ANALYSIS FUNCTIONS
# ============================================================================

#' Analyze backtest results
#' @param predictions Predictions dataframe from backtest_period
#' @return List with analysis metrics
analyze_backtest <- function(predictions) {
  cat("\n=== BACKTEST ANALYSIS ===\n\n")

  # Overall prediction accuracy
  accuracy <- mean(predictions$correct_prediction)
  cat(sprintf("Prediction Accuracy: %.1f%%\n", accuracy * 100))

  # Brier score: measures calibration
  # Compare predicted P(player1 wins) to actual outcome (1 if p1 won, 0 if p2 won)
  brier <- mean((predictions$model_prob_p1 - predictions$actual_p1_won)^2)
  cat(sprintf("Brier Score: %.4f (lower is better, 0.25 = random)\n", brier))

  # Log loss
  eps <- 1e-15
  log_loss <- -mean(
    predictions$actual_p1_won * log(pmax(predictions$model_prob_p1, eps)) +
    (1 - predictions$actual_p1_won) * log(pmax(predictions$model_prob_p2, eps))
  )
  cat(sprintf("Log Loss: %.4f\n", log_loss))

  # Calibration
  calibration <- calculate_calibration(predictions)
  cat("\nCalibration (predicted vs actual):\n")
  print(calibration)

  # Betting analysis at different thresholds
  cat("\n\n=== BETTING SIMULATION ===\n")

  betting_results <- list()

  for (threshold in EDGE_THRESHOLDS) {
    result <- simulate_betting(predictions, edge_threshold = threshold)
    betting_results[[as.character(threshold)]] <- result

    cat(sprintf("\nEdge Threshold: %.0f%%\n", threshold * 100))
    cat(sprintf("  Bets: %d (%.1f%% of matches)\n",
                result$n_bets, result$n_bets / nrow(predictions) * 100))
    cat(sprintf("  Win Rate: %.1f%%\n", result$win_rate * 100))
    cat(sprintf("  ROI: %+.1f%% (95%% CI: %+.1f%% to %+.1f%%)\n",
                result$roi * 100, result$roi_ci_lower * 100, result$roi_ci_upper * 100))
    cat(sprintf("  Profit (flat stake): $%.2f\n", result$profit_flat))
    cat(sprintf("  Final Bankroll (Kelly): $%.2f\n", result$final_bankroll_kelly))
  }

  # CLV analysis (Closing Line Value)
  clv <- calculate_clv(predictions)

  return(list(
    accuracy = accuracy,
    brier_score = brier,
    log_loss = log_loss,
    calibration = calibration,
    betting_results = betting_results,
    clv = clv
  ))
}

#' Calculate calibration metrics
#' @param predictions Predictions dataframe
#' @return Calibration summary
calculate_calibration <- function(predictions) {
  # For proper calibration, we look at all predictions (for both p1 and p2)
  # by creating a long-form dataset
  calibration_data <- bind_rows(
    # Predictions for player1
    predictions %>%
      select(model_prob = model_prob_p1, actual = actual_p1_won),
    # Predictions for player2 (flip the actual outcome)
    predictions %>%
      select(model_prob = model_prob_p2) %>%
      mutate(actual = 1 - predictions$actual_p1_won)
  )

  calibration_data %>%
    mutate(prob_bin = cut(model_prob,
                          breaks = seq(0, 1, 0.1),
                          include.lowest = TRUE)) %>%
    group_by(prob_bin) %>%
    summarize(
      n = n(),
      mean_predicted = mean(model_prob),
      actual_win_rate = mean(actual),
      .groups = "drop"
    ) %>%
    mutate(
      calibration_error = abs(mean_predicted - actual_win_rate)
    )
}

#' Simulate betting strategy
#' @param predictions Predictions dataframe
#' @param edge_threshold Minimum edge to bet
#' @param kelly_fraction Fraction of Kelly to use
#' @param starting_bankroll Initial bankroll
#' @return List with betting performance metrics
simulate_betting <- function(predictions, edge_threshold = 0.03,
                              kelly_fraction = KELLY_FRACTION,
                              starting_bankroll = STARTING_BANKROLL) {

  # Identify betting opportunities
  # Can bet on player1 or player2 depending on where edge exists
  bets <- predictions %>%
    mutate(
      # Determine which side to bet
      bet_on_p1 = edge_p1 >= edge_threshold,
      bet_on_p2 = edge_p2 >= edge_threshold,
      should_bet = bet_on_p1 | bet_on_p2,

      # Get bet details
      bet_side = case_when(
        bet_on_p1 & !bet_on_p2 ~ "p1",
        bet_on_p2 & !bet_on_p1 ~ "p2",
        bet_on_p1 & bet_on_p2 ~ if_else(edge_p1 > edge_p2, "p1", "p2"),
        TRUE ~ NA_character_
      ),
      bet_odds = case_when(
        bet_side == "p1" ~ p1_odds,
        bet_side == "p2" ~ p2_odds,
        TRUE ~ NA_real_
      ),
      bet_prob = case_when(
        bet_side == "p1" ~ model_prob_p1,
        bet_side == "p2" ~ model_prob_p2,
        TRUE ~ NA_real_
      ),
      bet_edge = case_when(
        bet_side == "p1" ~ edge_p1,
        bet_side == "p2" ~ edge_p2,
        TRUE ~ NA_real_
      ),
      # Determine if bet won based on actual outcome
      bet_won = case_when(
        bet_side == "p1" ~ actual_p1_won == 1,
        bet_side == "p2" ~ actual_p1_won == 0,
        TRUE ~ NA
      )
    ) %>%
    filter(should_bet)

  if (nrow(bets) == 0) {
    return(list(
      n_bets = 0,
      win_rate = NA,
      roi = NA,
      profit_flat = 0,
      final_bankroll_kelly = starting_bankroll
    ))
  }

  # Flat betting simulation (1 unit per bet)
  flat_stake <- 100
  bets <- bets %>%
    mutate(
      flat_profit = if_else(bet_won, (bet_odds - 1) * flat_stake, -flat_stake)
    )

  total_flat_profit <- sum(bets$flat_profit)
  total_flat_wagered <- nrow(bets) * flat_stake
  roi_flat <- total_flat_profit / total_flat_wagered

  # Kelly betting simulation
  bankroll <- starting_bankroll
  bankroll_history <- numeric(nrow(bets))

  for (i in 1:nrow(bets)) {
    bet <- bets[i, ]

    # Kelly formula: f = (bp - q) / b
    # where b = decimal odds - 1, p = probability, q = 1 - p
    b <- bet$bet_odds - 1
    p <- bet$bet_prob
    q <- 1 - p
    kelly <- (b * p - q) / b

    # Apply fractional Kelly and max bet constraint
    stake_fraction <- min(kelly * kelly_fraction, MAX_BET_FRACTION)
    stake_fraction <- max(stake_fraction, 0)  # No negative bets

    stake <- bankroll * stake_fraction

    if (bet$bet_won) {
      bankroll <- bankroll + stake * (bet$bet_odds - 1)
    } else {
      bankroll <- bankroll - stake
    }

    bankroll_history[i] <- bankroll
  }

  # Calculate max drawdown
  peak <- starting_bankroll
  max_drawdown <- 0
  for (br in bankroll_history) {
    peak <- max(peak, br)
    drawdown <- (peak - br) / peak
    max_drawdown <- max(max_drawdown, drawdown)
  }

  # Calculate bootstrap CI for ROI
  roi_ci <- bootstrap_roi_ci(bets, n_bootstrap = 1000)

  return(list(
    n_bets = nrow(bets),
    win_rate = mean(bets$bet_won),
    avg_edge = mean(bets$bet_edge),
    avg_odds = mean(bets$bet_odds),
    roi = roi_flat,
    roi_ci_lower = roi_ci$lower,
    roi_ci_upper = roi_ci$upper,
    profit_flat = total_flat_profit,
    final_bankroll_kelly = bankroll,
    kelly_roi = (bankroll - starting_bankroll) / starting_bankroll,
    max_drawdown = max_drawdown,
    bankroll_history = bankroll_history,
    bets = bets
  ))
}

#' Bootstrap confidence interval for ROI
#' @param bets Dataframe with bet outcomes (must have bet_won, bet_odds columns)
#' @param n_bootstrap Number of bootstrap samples
#' @param conf_level Confidence level (default 0.95)
#' @param flat_stake Stake per bet for ROI calculation
#' @return List with lower and upper CI bounds
bootstrap_roi_ci <- function(bets, n_bootstrap = 1000, conf_level = 0.95,
                              flat_stake = 100) {
  if (nrow(bets) == 0) {
    return(list(lower = NA, upper = NA))
  }

  # Function to calculate ROI from a sample
  calc_roi <- function(sample_bets) {
    profits <- ifelse(sample_bets$bet_won,
                      (sample_bets$bet_odds - 1) * flat_stake,
                      -flat_stake)
    sum(profits) / (nrow(sample_bets) * flat_stake)
  }

  # Bootstrap resampling
  n <- nrow(bets)
  roi_samples <- numeric(n_bootstrap)

  for (i in 1:n_bootstrap) {
    # Sample with replacement
    sample_indices <- sample(1:n, n, replace = TRUE)
    sample_bets <- bets[sample_indices, ]
    roi_samples[i] <- calc_roi(sample_bets)
  }

  # Calculate percentile CI
  alpha <- 1 - conf_level
  lower <- quantile(roi_samples, alpha / 2)
  upper <- quantile(roi_samples, 1 - alpha / 2)

  return(list(
    lower = as.numeric(lower),
    upper = as.numeric(upper),
    se = sd(roi_samples)
  ))
}

#' Calculate Closing Line Value
#' @param predictions Predictions dataframe
#' @return CLV metrics
calculate_clv <- function(predictions) {
  # CLV = how our predictions compare to closing lines
  # If we consistently beat the closing line, we have an edge

  # Here we use opening odds (what we have) as a proxy
  # True CLV would require closing line data

  # Create long-form data with predictions for both players
  clv_data <- bind_rows(
    predictions %>%
      select(model_prob = model_prob_p1, implied_prob = implied_prob_p1, edge = edge_p1),
    predictions %>%
      select(model_prob = model_prob_p2, implied_prob = implied_prob_p2, edge = edge_p2)
  )

  clv_data %>%
    summarize(
      avg_model_prob = mean(model_prob),
      avg_implied_prob = mean(implied_prob),
      avg_edge = mean(edge),
      pct_positive_edge = mean(edge > 0) * 100,
      pct_strong_edge = mean(edge > 0.03) * 100
    )
}

# ============================================================================
# COMPARISON FUNCTIONS
# ============================================================================

#' Compare multiple models on same matches
#' @param start_date Start date
#' @param end_date End date
#' @param models Vector of model names
#' @param tour Tour
#' @param n_sims Simulations per match
#' @return Comparison summary
compare_models_backtest <- function(start_date, end_date,
                                     models = c("base", "historical", "style", "combined"),
                                     tour = "ATP", n_sims = BACKTEST_N_SIMS,
                                     seed = RANDOM_SEED) {

  cat("\n=== MODEL COMPARISON BACKTEST ===\n\n")
  cat(sprintf("Random seed: %d\n\n", seed))

  # Load data once
  betting_data <- load_betting_data(tour = tour)
  if (is.null(betting_data)) {
    stop("No betting data available")
  }
  betting_data <- extract_best_odds(betting_data)

  stats_db <- load_player_stats(tour = tour)
  feature_db <- load_feature_matrix()

  results <- list()

  for (model in models) {
    cat(sprintf("\n--- Running %s model ---\n", str_to_upper(model)))

    bt <- backtest_period(
      start_date, end_date,
      model = model,
      tour = tour,
      betting_data = betting_data,
      stats_db = stats_db,
      feature_db = feature_db,
      n_sims = n_sims,
      seed = seed
    )

    results[[model]] <- bt
  }

  # Summary comparison
  cat("\n\n=== MODEL COMPARISON SUMMARY ===\n\n")

  summary_df <- map_dfr(names(results), function(m) {
    r <- results[[m]]
    tibble(
      model = m,
      accuracy = r$analysis$accuracy,
      brier = r$analysis$brier_score,
      roi_3pct = r$analysis$betting_results[["0.03"]]$roi,
      roi_5pct = r$analysis$betting_results[["0.05"]]$roi,
      n_bets_3pct = r$analysis$betting_results[["0.03"]]$n_bets,
      win_rate_3pct = r$analysis$betting_results[["0.03"]]$win_rate
    )
  })

  print(summary_df %>%
          mutate(across(where(is.numeric), ~round(., 4))))

  return(list(
    models = results,
    summary = summary_df
  ))
}

# ============================================================================
# PLOTTING
# ============================================================================

#' Plot calibration
#' @param backtest_result Result from backtest_period
#' @return ggplot object
plot_calibration <- function(backtest_result) {
  cal <- backtest_result$analysis$calibration

  ggplot(cal, aes(x = mean_predicted, y = actual_win_rate)) +
    geom_abline(slope = 1, intercept = 0, linetype = "dashed", color = "gray50") +
    geom_point(aes(size = n), color = "steelblue") +
    geom_line(color = "steelblue") +
    scale_x_continuous(limits = c(0, 1), labels = scales::percent) +
    scale_y_continuous(limits = c(0, 1), labels = scales::percent) +
    labs(
      title = sprintf("Model Calibration (%s)", backtest_result$model),
      subtitle = sprintf("Brier Score: %.4f | Accuracy: %.1f%%",
                         backtest_result$analysis$brier_score,
                         backtest_result$analysis$accuracy * 100),
      x = "Predicted Win Probability",
      y = "Actual Win Rate",
      size = "N Matches"
    ) +
    theme_minimal()
}

#' Plot bankroll history
#' @param betting_result Result from simulate_betting
#' @param starting_bankroll Initial bankroll
#' @return ggplot object
plot_bankroll <- function(betting_result, starting_bankroll = STARTING_BANKROLL) {
  if (is.null(betting_result$bankroll_history) ||
      length(betting_result$bankroll_history) == 0) {
    return(NULL)
  }

  df <- tibble(
    bet_num = 1:length(betting_result$bankroll_history),
    bankroll = betting_result$bankroll_history
  )

  ggplot(df, aes(x = bet_num, y = bankroll)) +
    geom_line(color = "steelblue") +
    geom_hline(yintercept = starting_bankroll, linetype = "dashed", color = "gray50") +
    scale_y_continuous(labels = scales::dollar) +
    labs(
      title = "Bankroll Over Time (Kelly Betting)",
      subtitle = sprintf("Final: $%.2f | ROI: %+.1f%% | Max Drawdown: %.1f%%",
                         betting_result$final_bankroll_kelly,
                         betting_result$kelly_roi * 100,
                         betting_result$max_drawdown * 100),
      x = "Bet Number",
      y = "Bankroll"
    ) +
    theme_minimal()
}

#' Plot ROI by edge threshold
#' @param backtest_result Result from backtest_period
#' @return ggplot object
plot_roi_by_edge <- function(backtest_result) {
  df <- map_dfr(names(backtest_result$analysis$betting_results), function(threshold) {
    r <- backtest_result$analysis$betting_results[[threshold]]
    tibble(
      threshold = as.numeric(threshold) * 100,
      roi = r$roi * 100,
      n_bets = r$n_bets,
      win_rate = r$win_rate * 100
    )
  })

  ggplot(df, aes(x = threshold, y = roi)) +
    geom_hline(yintercept = 0, linetype = "dashed", color = "gray50") +
    geom_line(color = "steelblue", size = 1) +
    geom_point(aes(size = n_bets), color = "steelblue") +
    scale_x_continuous(labels = function(x) paste0(x, "%")) +
    scale_y_continuous(labels = function(x) paste0(x, "%")) +
    labs(
      title = "ROI by Edge Threshold",
      subtitle = sprintf("Model: %s", backtest_result$model),
      x = "Minimum Edge Threshold",
      y = "Return on Investment",
      size = "N Bets"
    ) +
    theme_minimal()
}

# ============================================================================
# QUICK TEST
# ============================================================================

if (FALSE) {  # Set to TRUE to run test
  # Run a quick backtest
  results <- backtest_period(
    start_date = "2023-01-01",
    end_date = "2023-06-30",
    model = "base",
    tour = "ATP",
    n_sims = 500  # Lower for quick test
  )

  # Plot results
  print(plot_calibration(results))
  print(plot_roi_by_edge(results))

  # Compare models
  comparison <- compare_models_backtest(
    start_date = "2023-01-01",
    end_date = "2023-06-30",
    models = c("base", "combined"),
    n_sims = 500
  )
}
