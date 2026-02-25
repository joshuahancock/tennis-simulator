# Similarity-Based Probability Adjustments
# Two approaches for enhancing match predictions using player similarity:
# 1. Historical Matchup Weighting: How does player A perform vs players similar to B?
# 2. Style-Adjusted Probabilities: Adjust serve/return based on opponent profiles
#
# Usage:
#   source("src/models/monte_carlo/similarity.R")
#   adjusted <- get_similarity_adjusted_stats(player_a, player_b, stats_db, feature_db)

library(tidyverse)

# Source required files
source("src/utils/utils.R")
source("src/data/player_stats.R")

# ============================================================================
# CONFIGURATION
# ============================================================================

# Minimum similarity score to consider a player as "similar"
SIMILARITY_THRESHOLD <- 0.7

# Number of similar players to use
TOP_N_SIMILAR <- 20

# Minimum matches against similar players for adjustment
MIN_VS_SIMILAR_MATCHES <- 5

# Weight for similarity adjustment (0 = no adjustment, 1 = full adjustment)
SIMILARITY_WEIGHT <- 0.3

# ============================================================================
# SIMILARITY-BASED TOUR AVERAGES
# ============================================================================

#' Calculate expected return stats for a player based on similar players
#'
#' Instead of using hardcoded tour averages (0.35 for return vs 1st, 0.50 for return vs 2nd),
#' we calculate the average return stats for players similar to the given player.
#' This provides a more informed baseline for the opponent adjustment.
#'
#' @param player_name Player name to find similar players for
#' @param stats_db Stats database from load_player_stats()
#' @param feature_db Feature database from load_feature_matrix()
#' @param surface Surface to filter for (optional)
#' @param top_n Number of similar players to consider
#' @param similarity_threshold Minimum similarity score
#' @return List with expected return stats for this player type
get_expected_return_stats <- function(player_name, stats_db, feature_db,
                                       surface = NULL, top_n = TOP_N_SIMILAR,
                                       similarity_threshold = SIMILARITY_THRESHOLD) {

  # Default tour averages (fallback)
  default_result <- list(
    expected_return_vs_first = 0.35,
    expected_return_vs_second = 0.50,
    source = "tour_average",
    n_similar = 0
  )

  # If no feature database, return defaults
  if (is.null(feature_db)) {
    return(default_result)
  }

  # Find players similar to this player
  similar <- find_similar_to_player(player_name, feature_db,
                                     top_n = top_n,
                                     similarity_threshold = similarity_threshold)

  if (is.null(similar) || nrow(similar) == 0) {
    return(default_result)
  }

  # Get return stats for similar players from stats_db
  similar_names <- similar$player_name

  # Get surface-specific or overall stats
  if (!is.null(surface) && !is.null(stats_db$player_stats_surface)) {
    player_stats <- stats_db$player_stats_surface %>%
      filter(player_name %in% similar_names, surface == !!surface)
  } else if (!is.null(stats_db$player_stats_overall)) {
    player_stats <- stats_db$player_stats_overall %>%
      filter(player_name %in% similar_names)
  } else {
    return(default_result)
  }

  if (nrow(player_stats) == 0) {
    return(default_result)
  }

  # Join with similarity scores for weighting
  player_stats <- player_stats %>%
    left_join(similar %>% select(player_name, similarity), by = "player_name") %>%
    filter(!is.na(similarity))

  if (nrow(player_stats) == 0) {
    return(default_result)
  }

  # Calculate weighted average return stats
  total_weight <- sum(player_stats$similarity, na.rm = TRUE)

  weighted_return_vs_first <- sum(
    player_stats$return_vs_first * player_stats$similarity,
    na.rm = TRUE
  ) / total_weight

  weighted_return_vs_second <- sum(
    player_stats$return_vs_second * player_stats$similarity,
    na.rm = TRUE
  ) / total_weight

  # Validate and clamp values
  if (is.na(weighted_return_vs_first) || is.nan(weighted_return_vs_first)) {
    weighted_return_vs_first <- 0.35
  }
  if (is.na(weighted_return_vs_second) || is.nan(weighted_return_vs_second)) {
    weighted_return_vs_second <- 0.50
  }

  # Clamp to reasonable ranges
  weighted_return_vs_first <- pmax(0.20, pmin(0.50, weighted_return_vs_first))
  weighted_return_vs_second <- pmax(0.35, pmin(0.65, weighted_return_vs_second))

  return(list(
    expected_return_vs_first = weighted_return_vs_first,
    expected_return_vs_second = weighted_return_vs_second,
    source = "similarity_cohort",
    n_similar = nrow(player_stats)
  ))
}

#' Pre-compute expected return stats for all players in a matchup
#'
#' This function is designed to be called once before simulating a match,
#' so we don't have to call find_similar_players on every point.
#'
#' @param p1_name Player 1 name
#' @param p2_name Player 2 name
#' @param stats_db Stats database
#' @param feature_db Feature database
#' @param surface Surface
#' @return List with expected return stats for both players
get_matchup_expected_returns <- function(p1_name, p2_name, stats_db, feature_db,
                                          surface = NULL) {
  p1_expected <- get_expected_return_stats(p1_name, stats_db, feature_db, surface)
  p2_expected <- get_expected_return_stats(p2_name, stats_db, feature_db, surface)

  return(list(
    p1 = p1_expected,
    p2 = p2_expected
  ))
}

# ============================================================================
# FEATURE DATA LOADING
# ============================================================================

#' Load player feature matrix for similarity calculations
#' @param feature_file Path to normalized features CSV
#' @return Dataframe with player features
load_feature_matrix <- function(feature_file = "data/processed/charting_only_features_normalized.csv") {
  if (!file.exists(feature_file)) {
    warning("Feature file not found: ", feature_file)
    return(NULL)
  }

  cat("Loading player feature matrix...\n")

  features <- read_csv(feature_file, show_col_types = FALSE)

  # Get most recent stats for each player
  features_current <- features %>%
    group_by(player_name) %>%
    filter(match_year == max(match_year)) %>%
    slice(1) %>%
    ungroup()

  cat(sprintf("  Loaded features for %d players\n", nrow(features_current)))
  return(features_current)
}

# ============================================================================
# APPROACH 1: HISTORICAL MATCHUP WEIGHTING
# ============================================================================

#' Find players similar to a given player
#' @param target_player Player name to find matches for
#' @param feature_db Feature database from load_feature_matrix()
#' @param feature_cols Which features to use for similarity
#' @param top_n Number of similar players to return
#' @param similarity_threshold Minimum similarity score
#' @return Dataframe of similar players with scores
find_similar_to_player <- function(target_player, feature_db,
                                    feature_cols = ALL_FEATURES,
                                    top_n = TOP_N_SIMILAR,
                                    similarity_threshold = SIMILARITY_THRESHOLD) {

  target_row <- feature_db %>%
    filter(player_name == target_player)

  if (nrow(target_row) == 0) {
    warning(sprintf("Player '%s' not found in feature database", target_player))
    return(NULL)
  }

  # Get the age for the most recent season
  target_age <- target_row$age[1]

  # Use the existing find_similar_players function
  similar <- find_similar_players(
    data = feature_db,
    player_name_query = target_player,
    age_query = target_age,
    feature_cols = feature_cols,
    similarity_fn = cosine_similarity,
    top_n = top_n * 2,  # Get more, then filter by threshold
    exclude_same_player = TRUE
  )

  if (is.null(similar) || nrow(similar) == 0) {
    return(NULL)
  }

  # Filter by threshold and limit
  similar <- similar %>%
    filter(similarity >= similarity_threshold) %>%
    head(top_n)

  return(similar)
}

#' Get player's historical performance against similar opponents
#' @param player Player name
#' @param similar_opponents Dataframe from find_similar_to_player()
#' @param stats_db Stats database from load_player_stats()
#' @param surface Surface to filter for (optional)
#' @return List with performance stats vs similar opponents
get_performance_vs_similar <- function(player, similar_opponents, stats_db,
                                        surface = NULL) {
  if (is.null(similar_opponents) || nrow(similar_opponents) == 0) {
    return(NULL)
  }

  matches <- stats_db$matches

  # Filter to matches involving our player
  player_matches <- matches %>%
    filter(winner_name == player | loser_name == player)

  if (!is.null(surface)) {
    player_matches <- player_matches %>% filter(surface == !!surface)
  }

  # Find matches against similar opponents
  similar_names <- similar_opponents$player_name

  vs_similar <- player_matches %>%
    filter(
      (winner_name == player & loser_name %in% similar_names) |
        (loser_name == player & winner_name %in% similar_names)
    ) %>%
    mutate(
      opponent = if_else(winner_name == player, loser_name, winner_name),
      won = winner_name == player
    )

  if (nrow(vs_similar) == 0) {
    return(NULL)
  }

  # Join with similarity scores
  vs_similar <- vs_similar %>%
    left_join(
      similar_opponents %>% select(player_name, similarity),
      by = c("opponent" = "player_name")
    )

  # Calculate weighted stats
  # Weight each match by opponent similarity
  total_weight <- sum(vs_similar$similarity, na.rm = TRUE)

  # Serve stats when playing against similar opponents
  serve_stats <- vs_similar %>%
    mutate(
      is_winner = winner_name == player,
      serve_pts = if_else(is_winner, w_svpt, l_svpt),
      first_in = if_else(is_winner, w_1stIn, l_1stIn),
      first_won = if_else(is_winner, w_1stWon, l_1stWon),
      second_won = if_else(is_winner, w_2ndWon, l_2ndWon),
      aces = if_else(is_winner, w_ace, l_ace),
      dfs = if_else(is_winner, w_df, l_df)
    )

  weighted_serve <- serve_stats %>%
    summarize(
      n_matches = n(),
      wins = sum(won),
      win_rate = mean(won),
      # Weighted totals
      w_serve_pts = sum(serve_pts * similarity, na.rm = TRUE) / total_weight,
      w_first_in = sum(first_in * similarity, na.rm = TRUE) / total_weight,
      w_first_won = sum(first_won * similarity, na.rm = TRUE) / total_weight,
      w_second_won = sum(second_won * similarity, na.rm = TRUE) / total_weight,
      w_aces = sum(aces * similarity, na.rm = TRUE) / total_weight,
      w_dfs = sum(dfs * similarity, na.rm = TRUE) / total_weight,
      # Actual totals (unweighted)
      total_serve_pts = sum(serve_pts, na.rm = TRUE),
      total_first_in = sum(first_in, na.rm = TRUE),
      total_first_won = sum(first_won, na.rm = TRUE),
      total_second_won = sum(second_won, na.rm = TRUE),
      total_aces = sum(aces, na.rm = TRUE),
      total_dfs = sum(dfs, na.rm = TRUE)
    )

  # Calculate percentages
  results <- list(
    n_matches = weighted_serve$n_matches,
    wins = weighted_serve$wins,
    win_rate = weighted_serve$win_rate,
    first_in_pct = weighted_serve$total_first_in / weighted_serve$total_serve_pts,
    first_won_pct = weighted_serve$total_first_won / weighted_serve$total_first_in,
    second_won_pct = weighted_serve$total_second_won /
      (weighted_serve$total_serve_pts - weighted_serve$total_first_in),
    ace_pct = weighted_serve$total_aces / weighted_serve$total_serve_pts,
    df_pct = weighted_serve$total_dfs / weighted_serve$total_serve_pts
  )

  return(results)
}

#' Apply historical matchup adjustment to player stats
#' @param base_stats Base player stats (from get_player_stats)
#' @param vs_similar_stats Stats vs similar opponents (from get_performance_vs_similar)
#' @param weight How much to weight the adjustment (0-1)
#' @return Adjusted player stats
apply_historical_adjustment <- function(base_stats, vs_similar_stats,
                                         weight = SIMILARITY_WEIGHT) {
  if (is.null(vs_similar_stats) || vs_similar_stats$n_matches < MIN_VS_SIMILAR_MATCHES) {
    return(base_stats)  # Not enough data, return unchanged
  }

  adjusted <- base_stats

  # Blend base stats with performance vs similar opponents
  adjusted$first_in_pct <- base_stats$first_in_pct * (1 - weight) +
    vs_similar_stats$first_in_pct * weight

  adjusted$first_won_pct <- base_stats$first_won_pct * (1 - weight) +
    vs_similar_stats$first_won_pct * weight

  adjusted$second_won_pct <- base_stats$second_won_pct * (1 - weight) +
    vs_similar_stats$second_won_pct * weight

  adjusted$ace_pct <- base_stats$ace_pct * (1 - weight) +
    vs_similar_stats$ace_pct * weight

  adjusted$df_pct <- base_stats$df_pct * (1 - weight) +
    vs_similar_stats$df_pct * weight

  adjusted$source <- "historical_adjusted"
  adjusted$adjustment_matches <- vs_similar_stats$n_matches
  adjusted$adjustment_win_rate <- vs_similar_stats$win_rate

  return(adjusted)
}

# ============================================================================
# APPROACH 2: STYLE-ADJUSTED PROBABILITIES
# ============================================================================

#' Classify player's playing style based on features
#' @param player_name Player name
#' @param feature_db Feature database
#' @return List with style classification
classify_player_style <- function(player_name, feature_db) {
  player_row <- feature_db %>%
    filter(player_name == !!player_name)

  if (nrow(player_row) == 0) {
    return(list(
      style = "unknown",
      serve_power = NA,
      return_skill = NA,
      net_tendency = NA,
      aggression = NA
    ))
  }

  # Get z-scores for key metrics
  serve_z <- player_row$serve_pct_z
  return_z <- player_row$return_pct_z
  ace_z <- player_row$ace_pct_z
  net_z <- player_row$net_approach_rate_z
  winner_z <- player_row$winner_pct_z

  # Classify serve power
  serve_power <- case_when(
    is.na(ace_z) ~ "average",
    ace_z > 1.0 ~ "big_server",
    ace_z > 0.3 ~ "good_server",
    ace_z < -0.5 ~ "weak_server",
    TRUE ~ "average_server"
  )

  # Classify return skill
  return_skill <- case_when(
    is.na(return_z) ~ "average",
    return_z > 1.0 ~ "elite_returner",
    return_z > 0.3 ~ "good_returner",
    return_z < -0.5 ~ "weak_returner",
    TRUE ~ "average_returner"
  )

  # Classify net tendency
  net_tendency <- case_when(
    is.na(net_z) ~ "average",
    net_z > 1.5 ~ "serve_volleyer",
    net_z > 0.5 ~ "net_rusher",
    net_z < -0.5 ~ "baseliner",
    TRUE ~ "all_courter"
  )

  # Classify aggression
  aggression <- case_when(
    is.na(winner_z) ~ "average",
    winner_z > 1.0 ~ "aggressive",
    winner_z > 0.3 ~ "offensive",
    winner_z < -0.5 ~ "defensive",
    TRUE ~ "balanced"
  )

  # Overall style
  style <- case_when(
    serve_power == "big_server" & net_tendency %in% c("serve_volleyer", "net_rusher") ~ "serve_and_volley",
    serve_power == "big_server" ~ "power_baseliner",
    return_skill == "elite_returner" & aggression == "defensive" ~ "counterpuncher",
    aggression %in% c("aggressive", "offensive") ~ "aggressive_baseliner",
    TRUE ~ "all_rounder"
  )

  return(list(
    player = player_name,
    style = style,
    serve_power = serve_power,
    return_skill = return_skill,
    net_tendency = net_tendency,
    aggression = aggression,
    serve_z = serve_z,
    return_z = return_z,
    ace_z = ace_z,
    net_z = net_z,
    winner_z = winner_z
  ))
}

#' Calculate style matchup adjustment factors
#' @param p1_style Style classification for player 1
#' @param p2_style Style classification for player 2
#' @return List with adjustment factors for each player
calculate_style_matchup <- function(p1_style, p2_style) {
  # Default: no adjustment
  p1_adj <- list(serve_mult = 1.0, return_mult = 1.0)
  p2_adj <- list(serve_mult = 1.0, return_mult = 1.0)

  # Big server vs elite returner: server's effectiveness reduced
  if (p1_style$serve_power == "big_server" && p2_style$return_skill == "elite_returner") {
    p1_adj$serve_mult <- 0.95  # Server loses some advantage
  }
  if (p2_style$serve_power == "big_server" && p1_style$return_skill == "elite_returner") {
    p2_adj$serve_mult <- 0.95
  }

  # Weak server vs good returner: server struggles more
  if (p1_style$serve_power == "weak_server" && p2_style$return_skill %in% c("elite_returner", "good_returner")) {
    p1_adj$serve_mult <- 0.92
  }
  if (p2_style$serve_power == "weak_server" && p1_style$return_skill %in% c("elite_returner", "good_returner")) {
    p2_adj$serve_mult <- 0.92
  }

  # Aggressive baseliner vs counterpuncher: variable effect
  if (p1_style$style == "aggressive_baseliner" && p2_style$style == "counterpuncher") {
    # Aggressive player may make more errors against counterpuncher
    p1_adj$serve_mult <- 0.98
    p1_adj$return_mult <- 0.97
  }
  if (p2_style$style == "aggressive_baseliner" && p1_style$style == "counterpuncher") {
    p2_adj$serve_mult <- 0.98
    p2_adj$return_mult <- 0.97
  }

  # Net rusher vs good passing shot player (proxy: defensive/counterpuncher)
  if (p1_style$net_tendency %in% c("serve_volleyer", "net_rusher") &&
      p2_style$style == "counterpuncher") {
    p1_adj$serve_mult <- 0.96  # Net game less effective vs good passers
  }
  if (p2_style$net_tendency %in% c("serve_volleyer", "net_rusher") &&
      p1_style$style == "counterpuncher") {
    p2_adj$serve_mult <- 0.96
  }

  return(list(
    p1_adjustment = p1_adj,
    p2_adjustment = p2_adj,
    p1_style = p1_style,
    p2_style = p2_style
  ))
}

#' Apply style-based adjustment to player stats
#' @param stats Player stats
#' @param adjustment Adjustment factors from calculate_style_matchup
#' @return Adjusted stats
apply_style_adjustment <- function(stats, adjustment) {
  adjusted <- stats

  # Apply serve multiplier to first and second serve win percentages
  adjusted$first_won_pct <- stats$first_won_pct * adjustment$serve_mult
  adjusted$second_won_pct <- stats$second_won_pct * adjustment$serve_mult

  # Clamp to valid range

  adjusted$first_won_pct <- pmax(0.4, pmin(0.9, adjusted$first_won_pct))
  adjusted$second_won_pct <- pmax(0.3, pmin(0.7, adjusted$second_won_pct))

  adjusted$source <- paste0(stats$source, "_style_adjusted")

  return(adjusted)
}

# ============================================================================
# COMBINED ADJUSTMENT
# ============================================================================

#' Get similarity-adjusted stats for a matchup
#' @param player_a Player A name
#' @param player_b Player B name (opponent)
#' @param stats_db Stats database from load_player_stats()
#' @param feature_db Feature database from load_feature_matrix()
#' @param surface Surface for stats
#' @param use_historical Whether to use historical matchup adjustment
#' @param use_style Whether to use style-based adjustment
#' @return Adjusted player stats
get_similarity_adjusted_stats <- function(player_a, player_b,
                                           stats_db, feature_db,
                                           surface = "Hard",
                                           use_historical = TRUE,
                                           use_style = TRUE) {

  # Get base stats
  base_stats <- get_player_stats(player_a, surface = surface, stats_db = stats_db)

  adjusted <- base_stats

  # Approach 1: Historical matchup adjustment
  if (use_historical && !is.null(feature_db)) {
    # Find players similar to opponent
    similar_to_b <- find_similar_to_player(player_b, feature_db)

    if (!is.null(similar_to_b) && nrow(similar_to_b) > 0) {
      # Get A's performance vs those similar players
      vs_similar <- get_performance_vs_similar(player_a, similar_to_b, stats_db, surface)

      # Apply adjustment
      adjusted <- apply_historical_adjustment(adjusted, vs_similar)
    }
  }

  # Approach 2: Style-based adjustment
  if (use_style && !is.null(feature_db)) {
    a_style <- classify_player_style(player_a, feature_db)
    b_style <- classify_player_style(player_b, feature_db)

    if (a_style$style != "unknown" && b_style$style != "unknown") {
      matchup <- calculate_style_matchup(a_style, b_style)
      adjusted <- apply_style_adjustment(adjusted, matchup$p1_adjustment)
      adjusted$opponent_style <- b_style$style
      adjusted$player_style <- a_style$style
    }
  }

  return(adjusted)
}

# ============================================================================
# ENHANCED MATCH SIMULATION
# ============================================================================

#' Simulate match with similarity adjustments
#' @param player1 Player 1 name
#' @param player2 Player 2 name
#' @param surface Surface
#' @param best_of Number of sets
#' @param n_sims Number of simulations
#' @param stats_db Stats database
#' @param feature_db Feature database
#' @param use_historical Use historical matchup adjustment
#' @param use_style Use style-based adjustment
#' @param verbose Print progress
#' @return Match probability result
simulate_match_probability_adjusted <- function(player1, player2,
                                                 surface = "Hard",
                                                 best_of = 3,
                                                 n_sims = 10000,
                                                 stats_db = NULL,
                                                 feature_db = NULL,
                                                 use_historical = TRUE,
                                                 use_style = TRUE,
                                                 verbose = TRUE) {

  # Load data if not provided
  if (is.null(stats_db)) {
    stats_db <- load_player_stats()
  }
  if (is.null(feature_db)) {
    feature_db <- load_feature_matrix()
  }

  if (verbose) {
    cat(sprintf("Getting similarity-adjusted stats for %s vs %s on %s...\n",
                player1, player2, surface))
  }

  # Get adjusted stats for both players
  p1_stats <- get_similarity_adjusted_stats(
    player1, player2, stats_db, feature_db, surface,
    use_historical, use_style
  )

  p2_stats <- get_similarity_adjusted_stats(
    player2, player1, stats_db, feature_db, surface,
    use_historical, use_style
  )

  if (verbose) {
    cat(sprintf("  %s: 1st won=%.1f%%, 2nd won=%.1f%% (source: %s)\n",
                player1, p1_stats$first_won_pct * 100, p1_stats$second_won_pct * 100,
                p1_stats$source))
    cat(sprintf("  %s: 1st won=%.1f%%, 2nd won=%.1f%% (source: %s)\n",
                player2, p2_stats$first_won_pct * 100, p2_stats$second_won_pct * 100,
                p2_stats$source))
  }

  # Run simulations
  source("src/models/monte_carlo/mc_engine.R")

  if (verbose) cat(sprintf("Running %s simulations...\n", format(n_sims, big.mark = ",")))

  results <- vector("list", n_sims)
  for (i in 1:n_sims) {
    results[[i]] <- simulate_match(p1_stats, p2_stats, best_of = best_of)
  }

  # Analyze results
  winners <- sapply(results, function(r) r$winner)
  scores <- sapply(results, function(r) r$score_string)

  p1_wins <- sum(winners == 1)
  p1_win_prob <- p1_wins / n_sims

  # Confidence interval
  ci <- prop_ci(p1_wins, n_sims, conf_level = 0.95)

  if (verbose) {
    cat(sprintf("\nResults (similarity-adjusted):\n"))
    cat(sprintf("  %s win probability: %.1f%% (95%% CI: %.1f%% - %.1f%%)\n",
                player1, p1_win_prob * 100, ci$lower * 100, ci$upper * 100))
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
    model = "similarity_adjusted",
    use_historical = use_historical,
    use_style = use_style
  ))
}

# Helper function (if not already available)
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
# MODEL COMPARISON
# ============================================================================

#' Compare base model vs similarity-adjusted model
#' @param player1 Player 1 name
#' @param player2 Player 2 name
#' @param surface Surface
#' @param best_of Number of sets
#' @param n_sims Simulations per model
#' @param stats_db Stats database
#' @param feature_db Feature database
#' @return Comparison results
compare_models <- function(player1, player2, surface = "Hard",
                           best_of = 3, n_sims = 10000,
                           stats_db = NULL, feature_db = NULL) {

  if (is.null(stats_db)) stats_db <- load_player_stats()
  if (is.null(feature_db)) feature_db <- load_feature_matrix()

  cat(sprintf("\n=== Comparing Models: %s vs %s on %s ===\n\n", player1, player2, surface))

  # Base model
  cat("1. BASE MODEL (no adjustments)\n")
  base <- simulate_match_probability_adjusted(
    player1, player2, surface, best_of, n_sims,
    stats_db, feature_db,
    use_historical = FALSE, use_style = FALSE, verbose = FALSE
  )
  cat(sprintf("   %s win: %.1f%%\n\n", player1, base$p1_win_prob * 100))

  # Historical only
  cat("2. HISTORICAL MATCHUP MODEL\n")
  historical <- simulate_match_probability_adjusted(
    player1, player2, surface, best_of, n_sims,
    stats_db, feature_db,
    use_historical = TRUE, use_style = FALSE, verbose = FALSE
  )
  cat(sprintf("   %s win: %.1f%% (diff: %+.1f%%)\n\n",
              player1, historical$p1_win_prob * 100,
              (historical$p1_win_prob - base$p1_win_prob) * 100))

  # Style only
  cat("3. STYLE MATCHUP MODEL\n")
  style <- simulate_match_probability_adjusted(
    player1, player2, surface, best_of, n_sims,
    stats_db, feature_db,
    use_historical = FALSE, use_style = TRUE, verbose = FALSE
  )
  cat(sprintf("   %s win: %.1f%% (diff: %+.1f%%)\n\n",
              player1, style$p1_win_prob * 100,
              (style$p1_win_prob - base$p1_win_prob) * 100))

  # Combined
  cat("4. COMBINED MODEL (historical + style)\n")
  combined <- simulate_match_probability_adjusted(
    player1, player2, surface, best_of, n_sims,
    stats_db, feature_db,
    use_historical = TRUE, use_style = TRUE, verbose = FALSE
  )
  cat(sprintf("   %s win: %.1f%% (diff: %+.1f%%)\n\n",
              player1, combined$p1_win_prob * 100,
              (combined$p1_win_prob - base$p1_win_prob) * 100))

  # Player styles
  p1_style <- classify_player_style(player1, feature_db)
  p2_style <- classify_player_style(player2, feature_db)
  cat(sprintf("Player styles: %s (%s) vs %s (%s)\n",
              player1, p1_style$style, player2, p2_style$style))

  return(list(
    base = base,
    historical = historical,
    style = style,
    combined = combined,
    p1_style = p1_style,
    p2_style = p2_style
  ))
}

# ============================================================================
# QUICK TEST
# ============================================================================

if (FALSE) {  # Set to TRUE to run test
  # Load data
  stats_db <- load_player_stats()
  feature_db <- load_feature_matrix()

  # Compare models for a classic matchup
  comparison <- compare_models(
    "Rafael Nadal", "Novak Djokovic",
    surface = "Clay",
    n_sims = 5000,
    stats_db = stats_db,
    feature_db = feature_db
  )

  # Test style classification
  cat("\n\nPlayer Styles:\n")
  for (player in c("Roger Federer", "Rafael Nadal", "Novak Djokovic", "Carlos Alcaraz")) {
    style <- classify_player_style(player, feature_db)
    cat(sprintf("  %s: %s (serve: %s, return: %s)\n",
                player, style$style, style$serve_power, style$return_skill))
  }
}
