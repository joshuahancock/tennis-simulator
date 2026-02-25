# Elo Rating System for Tennis Simulator
# Calculates surface-specific Elo ratings from match history
#
# Usage:
#   source("src/models/elo/elo_ratings.R")
#   elo_db <- calculate_all_elo(matches)
#   prob <- predict_match_elo("Novak Djokovic", "Carlos Alcaraz", "Hard", elo_db)

library(tidyverse)
library(lubridate)

# ============================================================================
# CONFIGURATION
# ============================================================================

# Default Elo rating for new players
DEFAULT_ELO <- 1500

# K-factor for established players (controls rating volatility)
K_FACTOR_DEFAULT <- 32

# Higher K-factor for provisional players (faster convergence)
K_FACTOR_PROVISIONAL <- 48

# Matches required before player is no longer provisional
MIN_MATCHES_FOR_RATING <- 5

# Matches on surface needed for full surface-specific weighting
MIN_SURFACE_MATCHES_FOR_ELO <- 10

# Surfaces to track separately
ELO_SURFACES <- c("Hard", "Clay", "Grass")

# ============================================================================
# CORE ELO FUNCTIONS
# ============================================================================

#' Calculate expected win probability from Elo ratings
#'
#' Uses standard Elo formula: E = 1 / (1 + 10^((Rb - Ra) / 400))
#'
#' @param elo_a Player A's Elo rating
#' @param elo_b Player B's Elo rating
#' @return Expected probability that player A beats player B
#' @examples
#' elo_expected_prob(1500, 1500)  # Returns 0.5
#' elo_expected_prob(1600, 1400)  # Returns ~0.76
elo_expected_prob <- function(elo_a, elo_b) {
  1 / (1 + 10^((elo_b - elo_a) / 400))
}

#' Update Elo ratings after a match
#'
#' Each player's rating is updated using their own K-factor.
#' Update magnitude depends on K-factor and how unexpected the result was.
#'
#' @param elo_winner Winner's Elo rating before match
#' @param elo_loser Loser's Elo rating before match
#' @param k_winner K-factor for winner (default: K_FACTOR_DEFAULT)
#' @param k_loser K-factor for loser (default: K_FACTOR_DEFAULT)
#' @return List with new_winner_elo, new_loser_elo, winner_change, loser_change
elo_update <- function(elo_winner, elo_loser,
                       k_winner = K_FACTOR_DEFAULT,
                       k_loser = K_FACTOR_DEFAULT) {
  # Expected probability winner would win
  expected <- elo_expected_prob(elo_winner, elo_loser)

  # Surprise factor: how unexpected was the result?
  # If expected = 0.8, surprise = 0.2 (expected win)
  # If expected = 0.3, surprise = 0.7 (upset)
  surprise <- 1.0 - expected

  # Each player uses their own K-factor (standard Elo)
  winner_change <- k_winner * surprise
  loser_change <- k_loser * surprise

  list(
    new_winner_elo = elo_winner + winner_change,
    new_loser_elo = elo_loser - loser_change,
    winner_change = winner_change,
    loser_change = loser_change,
    expected_prob = expected
  )
}

#' Get K-factor based on number of matches played
#'
#' Players with fewer matches use higher K-factor for faster convergence
#'
#' @param matches_played Number of matches the player has played
#' @return Appropriate K-factor
get_k_factor <- function(matches_played) {
  if (matches_played < MIN_MATCHES_FOR_RATING) {
    K_FACTOR_PROVISIONAL
  } else {
    K_FACTOR_DEFAULT
  }
}

# ============================================================================
# ELO DATABASE BUILDER
# ============================================================================

#' Calculate Elo ratings for all players from match history
#'
#' Processes matches chronologically and updates ratings after each match.
#' Optionally calculates surface-specific ratings.
#'
#' @param matches Dataframe with columns: match_date, winner_name, loser_name, surface
#' @param by_surface Whether to calculate surface-specific ratings (default: TRUE)
#' @param cutoff_date Only use matches before this date (for backtesting)
#' @param verbose Print progress messages (default: FALSE)
#' @return List with overall, surface, and history tibbles
calculate_all_elo <- function(matches, by_surface = TRUE, cutoff_date = NULL,
                               verbose = FALSE) {
  # Filter to cutoff date if specified
  if (!is.null(cutoff_date)) {
    matches <- matches %>% filter(match_date < cutoff_date)
  }

  if (nrow(matches) == 0) {
    return(list(
      overall = tibble(
        player = character(),
        elo = numeric(),
        matches = integer(),
        wins = integer(),
        is_provisional = logical()
      ),
      surface = tibble(
        player = character(),
        surface = character(),
        elo = numeric(),
        matches = integer(),
        wins = integer(),
        is_provisional = logical()
      ),
      history = tibble()
    ))
  }

  # Sort matches by date
  matches <- matches %>% arrange(match_date)

  # Initialize rating storage
  # Overall ratings
  overall_elo <- list()      # player -> current elo
  overall_matches <- list()  # player -> match count
  overall_wins <- list()     # player -> win count

  # Surface-specific ratings
  surface_elo <- list()      # surface -> list(player -> elo)
  surface_matches <- list()  # surface -> list(player -> count)
  surface_wins <- list()     # surface -> list(player -> wins)

  for (surf in ELO_SURFACES) {
    surface_elo[[surf]] <- list()
    surface_matches[[surf]] <- list()
    surface_wins[[surf]] <- list()
  }

  # History tracking
  history_records <- vector("list", nrow(matches))

  if (verbose) {
    cat(sprintf("Processing %s matches for Elo calculation...\n",
                format(nrow(matches), big.mark = ",")))
  }

  # Process each match chronologically
  for (i in seq_len(nrow(matches))) {
    match <- matches[i, ]
    winner <- match$winner_name
    loser <- match$loser_name
    surface <- match$surface

    # Initialize players if new (overall)
    if (is.null(overall_elo[[winner]])) {
      overall_elo[[winner]] <- DEFAULT_ELO
      overall_matches[[winner]] <- 0
      overall_wins[[winner]] <- 0
    }
    if (is.null(overall_elo[[loser]])) {
      overall_elo[[loser]] <- DEFAULT_ELO
      overall_matches[[loser]] <- 0
      overall_wins[[loser]] <- 0
    }

    # Get K-factors based on experience
    k_winner <- get_k_factor(overall_matches[[winner]])
    k_loser <- get_k_factor(overall_matches[[loser]])

    # Store pre-match ratings
    winner_elo_before <- overall_elo[[winner]]
    loser_elo_before <- overall_elo[[loser]]

    # Update overall Elo
    update <- elo_update(winner_elo_before, loser_elo_before, k_winner, k_loser)
    overall_elo[[winner]] <- update$new_winner_elo
    overall_elo[[loser]] <- update$new_loser_elo
    overall_matches[[winner]] <- overall_matches[[winner]] + 1
    overall_matches[[loser]] <- overall_matches[[loser]] + 1
    overall_wins[[winner]] <- overall_wins[[winner]] + 1

    # Update surface-specific Elo if valid surface
    if (by_surface && surface %in% ELO_SURFACES) {
      # Initialize surface ratings if new
      if (is.null(surface_elo[[surface]][[winner]])) {
        surface_elo[[surface]][[winner]] <- DEFAULT_ELO
        surface_matches[[surface]][[winner]] <- 0
        surface_wins[[surface]][[winner]] <- 0
      }
      if (is.null(surface_elo[[surface]][[loser]])) {
        surface_elo[[surface]][[loser]] <- DEFAULT_ELO
        surface_matches[[surface]][[loser]] <- 0
        surface_wins[[surface]][[loser]] <- 0
      }

      # Get surface-specific K-factors
      k_winner_surf <- get_k_factor(surface_matches[[surface]][[winner]])
      k_loser_surf <- get_k_factor(surface_matches[[surface]][[loser]])

      # Update surface Elo
      surf_update <- elo_update(
        surface_elo[[surface]][[winner]],
        surface_elo[[surface]][[loser]],
        k_winner_surf,
        k_loser_surf
      )
      surface_elo[[surface]][[winner]] <- surf_update$new_winner_elo
      surface_elo[[surface]][[loser]] <- surf_update$new_loser_elo
      surface_matches[[surface]][[winner]] <- surface_matches[[surface]][[winner]] + 1
      surface_matches[[surface]][[loser]] <- surface_matches[[surface]][[loser]] + 1
      surface_wins[[surface]][[winner]] <- surface_wins[[surface]][[winner]] + 1
    }

    # Record history
    history_records[[i]] <- tibble(
      match_date = match$match_date,
      winner = winner,
      loser = loser,
      surface = surface,
      winner_elo_before = winner_elo_before,
      loser_elo_before = loser_elo_before,
      winner_elo_after = update$new_winner_elo,
      loser_elo_after = update$new_loser_elo,
      winner_change = update$winner_change,
      loser_change = update$loser_change,
      expected_prob = update$expected_prob
    )

    # Progress update
    if (verbose && i %% 10000 == 0) {
      cat(sprintf("  Processed %s matches...\n", format(i, big.mark = ",")))
    }
  }

  # Convert lists to tibbles
  overall_df <- tibble(
    player = names(overall_elo),
    elo = as.numeric(unlist(overall_elo)),
    matches = as.integer(unlist(overall_matches)),
    wins = as.integer(unlist(overall_wins))
  ) %>%
    mutate(is_provisional = matches < MIN_MATCHES_FOR_RATING) %>%
    arrange(desc(elo))

  # Surface tibble
  surface_rows <- list()
  for (surf in ELO_SURFACES) {
    if (length(surface_elo[[surf]]) > 0) {
      surface_rows[[surf]] <- tibble(
        player = names(surface_elo[[surf]]),
        surface = surf,
        elo = as.numeric(unlist(surface_elo[[surf]])),
        matches = as.integer(unlist(surface_matches[[surf]])),
        wins = as.integer(unlist(surface_wins[[surf]]))
      ) %>%
        mutate(is_provisional = matches < MIN_MATCHES_FOR_RATING)
    }
  }
  surface_df <- bind_rows(surface_rows) %>%
    arrange(surface, desc(elo))

  # History tibble
  history_df <- bind_rows(history_records)

  if (verbose) {
    cat(sprintf("Elo calculation complete: %d players, %d matches\n",
                nrow(overall_df), nrow(history_df)))
  }

  list(
    overall = overall_df,
    surface = surface_df,
    history = history_df
  )
}

#' Build Elo database from pre-filtered matches (for backtesting)
#'
#' Convenience wrapper around calculate_all_elo for backtest integration
#'
#' @param matches Pre-filtered match dataframe
#' @param verbose Print progress (default: FALSE)
#' @return Elo database list
build_elo_db_from_matches <- function(matches, verbose = FALSE) {
  calculate_all_elo(matches, by_surface = TRUE, cutoff_date = NULL, verbose = verbose)
}

# ============================================================================
# PLAYER ELO LOOKUP
# ============================================================================

#' Get a player's effective Elo for a specific surface
#'
#' Returns a weighted blend of surface-specific and overall Elo.
#' Weight increases as player accumulates more matches on the surface.
#'
#' @param player_name Player name
#' @param surface Surface ("Hard", "Clay", "Grass") or NULL for overall
#' @param elo_db Elo database from calculate_all_elo()
#' @return List with elo, surface_elo, overall_elo, weight, matches, is_provisional
get_player_elo <- function(player_name, surface = NULL, elo_db) {
  # Get overall Elo
  overall_row <- elo_db$overall %>% filter(player == player_name)

  if (nrow(overall_row) == 0) {
    # Unknown player - return default
    return(list(
      player = player_name,
      elo = DEFAULT_ELO,
      surface_elo = DEFAULT_ELO,
      overall_elo = DEFAULT_ELO,
      weight = 0,
      matches = 0,
      surface_matches = 0,
      is_provisional = TRUE,
      source = "default"
    ))
  }

  overall_elo <- overall_row$elo[1]
  overall_matches <- overall_row$matches[1]
  is_provisional <- overall_row$is_provisional[1]

  # If no surface specified, return overall
  if (is.null(surface) || !(surface %in% ELO_SURFACES)) {
    return(list(
      player = player_name,
      elo = overall_elo,
      surface_elo = NA,
      overall_elo = overall_elo,
      weight = 0,
      matches = overall_matches,
      surface_matches = 0,
      is_provisional = is_provisional,
      source = "overall"
    ))
  }

  # Get surface-specific Elo
  surface_row <- elo_db$surface %>%
    filter(player == player_name, surface == !!surface)

  if (nrow(surface_row) == 0) {
    # No surface data - use overall
    return(list(
      player = player_name,
      elo = overall_elo,
      surface_elo = DEFAULT_ELO,
      overall_elo = overall_elo,
      weight = 0,
      matches = overall_matches,
      surface_matches = 0,
      is_provisional = is_provisional,
      source = "overall"
    ))
  }

  surface_elo <- surface_row$elo[1]
  surface_matches <- surface_row$matches[1]

  # Calculate weight: full surface weight at MIN_SURFACE_MATCHES_FOR_ELO matches
  weight <- min(1, surface_matches / MIN_SURFACE_MATCHES_FOR_ELO)

  # Blend surface and overall
  effective_elo <- weight * surface_elo + (1 - weight) * overall_elo

  list(
    player = player_name,
    elo = effective_elo,
    surface_elo = surface_elo,
    overall_elo = overall_elo,
    weight = weight,
    matches = overall_matches,
    surface_matches = surface_matches,
    is_provisional = is_provisional,
    source = if (weight >= 1) "surface" else if (weight > 0) "blended" else "overall"
  )
}

# ============================================================================
# MATCH PREDICTION
# ============================================================================

#' Predict match outcome using Elo ratings
#'
#' @param player1 Player 1 name
#' @param player2 Player 2 name
#' @param surface Surface ("Hard", "Clay", "Grass") or NULL
#' @param elo_db Elo database from calculate_all_elo()
#' @param use_surface_elo Whether to use surface-specific Elo (default: TRUE)
#' @return List with p1_win_prob, elo_diff, p1_elo, p2_elo, p1_info, p2_info
predict_match_elo <- function(player1, player2, surface = NULL, elo_db,
                               use_surface_elo = TRUE) {
  # Get player Elos
  if (use_surface_elo && !is.null(surface)) {
    p1_info <- get_player_elo(player1, surface, elo_db)
    p2_info <- get_player_elo(player2, surface, elo_db)
  } else {
    p1_info <- get_player_elo(player1, NULL, elo_db)
    p2_info <- get_player_elo(player2, NULL, elo_db)
  }

  p1_elo <- p1_info$elo
  p2_elo <- p2_info$elo

  # Calculate win probability
  p1_win_prob <- elo_expected_prob(p1_elo, p2_elo)

  list(
    p1_win_prob = p1_win_prob,
    p2_win_prob = 1 - p1_win_prob,
    elo_diff = p1_elo - p2_elo,
    p1_elo = p1_elo,
    p2_elo = p2_elo,
    p1_info = p1_info,
    p2_info = p2_info,
    surface = surface
  )
}

# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================

#' Get top N players by Elo rating
#'
#' @param elo_db Elo database
#' @param n Number of players to return (default: 20)
#' @param surface Optional surface filter
#' @return Tibble with top players
get_top_players <- function(elo_db, n = 20, surface = NULL) {
  if (is.null(surface)) {
    elo_db$overall %>%
      filter(!is_provisional) %>%
      head(n)
  } else {
    elo_db$surface %>%
      filter(surface == !!surface, !is_provisional) %>%
      arrange(desc(elo)) %>%
      head(n)
  }
}

#' Print Elo database summary
#'
#' @param elo_db Elo database
print_elo_summary <- function(elo_db) {
  cat("\n=== ELO DATABASE SUMMARY ===\n\n")

  cat("Overall ratings:\n")
  cat(sprintf("  Total players: %d\n", nrow(elo_db$overall)))
  cat(sprintf("  Provisional: %d\n", sum(elo_db$overall$is_provisional)))
  cat(sprintf("  Established: %d\n", sum(!elo_db$overall$is_provisional)))
  cat(sprintf("  Rating range: %.0f - %.0f\n",
              min(elo_db$overall$elo), max(elo_db$overall$elo)))

  cat("\nSurface-specific ratings:\n")
  for (surf in ELO_SURFACES) {
    surf_data <- elo_db$surface %>% filter(surface == surf)
    if (nrow(surf_data) > 0) {
      cat(sprintf("  %s: %d players (%.0f - %.0f)\n",
                  surf, nrow(surf_data), min(surf_data$elo), max(surf_data$elo)))
    }
  }

  cat("\nTop 10 overall:\n")
  top10 <- get_top_players(elo_db, 10)
  for (i in 1:min(10, nrow(top10))) {
    cat(sprintf("  %2d. %s (%.0f, %d matches)\n",
                i, top10$player[i], top10$elo[i], top10$matches[i]))
  }

  cat("\n")
}

# ============================================================================
# UNIT TESTS
# Run with: Rscript -e "source('src/models/elo/elo_ratings.R'); test_elo()"
# ============================================================================

test_elo <- function() {
  cat("=== Running Elo Unit Tests ===\n\n")

  cat("--- Core Elo Formula Tests (1-3) ---\n")

  # Test 1: Equal ratings = 50% probability
  prob <- elo_expected_prob(1500, 1500)
  stopifnot(abs(prob - 0.5) < 0.001)
  cat("  Test 1 PASSED: Equal ratings give 50% win probability\n")

  # Test 2: 200-point advantage = ~76% probability
  prob <- elo_expected_prob(1600, 1400)
  stopifnot(abs(prob - 0.76) < 0.01)
  cat("  Test 2 PASSED: 200-point advantage gives ~76% win probability\n")

  # Test 3: Probability is symmetric
  prob_a <- elo_expected_prob(1600, 1400)
  prob_b <- elo_expected_prob(1400, 1600)
  stopifnot(abs(prob_a + prob_b - 1.0) < 0.001)
  cat("  Test 3 PASSED: Win probabilities are symmetric\n")

  cat("\n--- Elo Update Tests (4-8) ---\n")

  # Test 4: Update is zero-sum with equal K-factors
  update <- elo_update(1500, 1500, k_winner = 32, k_loser = 32)
  change_sum <- (update$new_winner_elo - 1500) + (update$new_loser_elo - 1500)
  stopifnot(abs(change_sum) < 0.001)
  cat("  Test 4 PASSED: Zero-sum with equal K-factors\n")

  # Test 5: Per-player K-factors applied correctly
  # Provisional (K=48) beats established (K=32), both at 1500
  update_unequal <- elo_update(1500, 1500, k_winner = 48, k_loser = 32)
  # Expected = 0.5, so surprise = 0.5
  # Winner should gain 48 * 0.5 = 24
  # Loser should lose 32 * 0.5 = 16
  stopifnot(abs(update_unequal$winner_change - 24) < 0.001)
  stopifnot(abs(update_unequal$loser_change - 16) < 0.001)
  stopifnot(abs(update_unequal$new_winner_elo - 1524) < 0.001)
  stopifnot(abs(update_unequal$new_loser_elo - 1484) < 0.001)
  cat("  Test 5 PASSED: Per-player K-factors applied correctly (48 vs 32)\n")

  # Test 6: Asymmetric K-factors produce correct non-zero-sum result
  # This is CORRECT behavior: with different K-factors, the system is NOT zero-sum
  # Net change = winner_change - loser_change = 24 - 16 = +8 (rating inflation)
  # This allows provisional players to converge faster
  net_change <- update_unequal$winner_change - update_unequal$loser_change
  stopifnot(abs(net_change - 8) < 0.001)  # Expected: 24 - 16 = 8
  cat("  Test 6 PASSED: Asymmetric K-factors produce correct non-zero-sum (+8)\n")

  # Test 7: Upset causes larger rating change
  update_expected <- elo_update(1600, 1400)  # Favorite wins
  update_upset <- elo_update(1400, 1600)     # Underdog wins
  stopifnot(update_upset$winner_change > update_expected$winner_change)
  cat("  Test 7 PASSED: Upsets cause larger rating changes\n")

  # Test 8: K-factor varies by experience
  k_new <- get_k_factor(2)
  k_exp <- get_k_factor(100)
  stopifnot(k_new > k_exp)
  stopifnot(k_new == K_FACTOR_PROVISIONAL)
  stopifnot(k_exp == K_FACTOR_DEFAULT)
  cat("  Test 8 PASSED: New players have higher K-factor (48 vs 32)\n")

  cat("\n--- Integration Tests (9-14) ---\n")

  # Test 9: calculate_all_elo on minimal data
  test_matches <- tibble(
    match_date = as.Date(c("2024-01-01", "2024-01-02", "2024-01-03")),
    winner_name = c("Player A", "Player B", "Player A"),
    loser_name = c("Player B", "Player C", "Player C"),
    surface = c("Hard", "Hard", "Clay")
  )
  elo_db <- calculate_all_elo(test_matches, by_surface = TRUE)

  stopifnot(nrow(elo_db$overall) == 3)
  stopifnot("Player A" %in% elo_db$overall$player)
  stopifnot("Player B" %in% elo_db$overall$player)
  stopifnot("Player C" %in% elo_db$overall$player)

  # Player A: 2 wins, 0 losses -> highest Elo
  # Player C: 0 wins, 2 losses -> lowest Elo
  a_elo <- elo_db$overall$elo[elo_db$overall$player == "Player A"]
  c_elo <- elo_db$overall$elo[elo_db$overall$player == "Player C"]
  stopifnot(a_elo > c_elo)
  cat("  Test 9 PASSED: calculate_all_elo produces correct rankings\n")

  # Test 10: History tracking includes winner/loser changes
  stopifnot("winner_change" %in% names(elo_db$history))
  stopifnot("loser_change" %in% names(elo_db$history))
  stopifnot(all(elo_db$history$winner_change > 0))
  stopifnot(all(elo_db$history$loser_change > 0))
  cat("  Test 10 PASSED: History tracks winner_change and loser_change\n")

  # Test 11: get_player_elo returns default for unknown player
  unknown <- get_player_elo("Unknown Player", "Hard", elo_db)
  stopifnot(unknown$elo == DEFAULT_ELO)
  stopifnot(unknown$source == "default")
  stopifnot(unknown$is_provisional == TRUE)
  cat("  Test 11 PASSED: get_player_elo returns default for unknown players\n")

  # Test 12: get_player_elo blending works correctly
  # Create a player with known surface and overall Elo for blending test
  blend_matches <- tibble(
    match_date = as.Date("2024-01-01") + 0:14,
    winner_name = c(rep("Blender", 10), rep("Opponent", 5)),
    loser_name = c(rep("Opponent", 10), rep("Blender", 5)),
    surface = rep("Hard", 15)
  )
  blend_db <- calculate_all_elo(blend_matches, by_surface = TRUE)

  # Blender: 10 wins, 5 losses on Hard (10 surface matches = full weight)
  blender_info <- get_player_elo("Blender", "Hard", blend_db)
  stopifnot(blender_info$surface_matches == 15)
  stopifnot(blender_info$weight == 1)  # 15 >= MIN_SURFACE_MATCHES_FOR_ELO (10)
  stopifnot(blender_info$source == "surface")
  stopifnot(abs(blender_info$elo - blender_info$surface_elo) < 0.001)

  # Test partial blending: player with fewer surface matches
  partial_matches <- tibble(
    match_date = as.Date("2024-01-01") + 0:7,
    winner_name = c(rep("Partial", 5), rep("Other", 3)),
    loser_name = c(rep("Other", 5), rep("Partial", 3)),
    surface = c(rep("Clay", 5), rep("Hard", 3))  # Only 5 Clay matches
  )
  partial_db <- calculate_all_elo(partial_matches, by_surface = TRUE)
  partial_info <- get_player_elo("Partial", "Clay", partial_db)
  stopifnot(partial_info$surface_matches == 5)
  stopifnot(partial_info$weight == 0.5)  # 5 / 10 = 0.5
  stopifnot(partial_info$source == "blended")
  # Verify blended Elo is between surface and overall
  expected_blend <- 0.5 * partial_info$surface_elo + 0.5 * partial_info$overall_elo
  stopifnot(abs(partial_info$elo - expected_blend) < 0.001)
  cat("  Test 12 PASSED: get_player_elo blending works correctly\n")

  # Test 13: predict_match_elo returns valid probabilities
  pred <- predict_match_elo("Player A", "Player C", "Hard", elo_db)
  stopifnot(pred$p1_win_prob > 0 && pred$p1_win_prob < 1)
  stopifnot(abs(pred$p1_win_prob + pred$p2_win_prob - 1) < 0.001)
  stopifnot(pred$p1_win_prob > 0.5)  # A should be favored over C
  cat("  Test 13 PASSED: predict_match_elo returns valid probabilities\n")

  # Test 14: Surface-specific Elo tracked correctly
  hard_players <- elo_db$surface %>% filter(surface == "Hard")
  clay_players <- elo_db$surface %>% filter(surface == "Clay")
  stopifnot(nrow(hard_players) >= 2)  # A, B, C played on hard
  stopifnot(nrow(clay_players) >= 2)  # A, C played on clay
  cat("  Test 14 PASSED: Surface-specific Elo tracked correctly\n")

  cat("\n=== All 14 tests passed ===\n")
}

# Auto-run tests when script is executed directly (not sourced)
if (sys.nframe() == 0) {
  test_elo()
}
