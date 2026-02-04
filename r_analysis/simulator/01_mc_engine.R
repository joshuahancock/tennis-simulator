# Tennis Match Monte Carlo Simulation Engine
# Core simulation functions: point → game → set → match
#
# Usage:
#   source("r_analysis/simulator/01_mc_engine.R")
#   result <- simulate_match(player1_stats, player2_stats, best_of = 3)

# ============================================================================
# POINT SIMULATION
# ============================================================================

# Global configuration for opponent adjustment
# Set to FALSE to disable the opponent-based adjustment (uses raw serve stats only)
USE_OPPONENT_ADJUSTMENT <- TRUE

#' Simulate a single point
#' @param server_stats List with serve statistics (first_in_pct, first_won_pct,
#'                     second_won_pct, ace_pct, df_pct)
#' @param returner_stats List with return statistics (return_vs_first, return_vs_second)
#'                       If NULL, uses server stats only
#' @param use_adjustment Whether to adjust serve win probability based on returner stats.
#'                       If NULL, uses global USE_OPPONENT_ADJUSTMENT setting.
#' @return List with winner (1 = server, 0 = returner), point_type, and details
simulate_point <- function(server_stats, returner_stats = NULL, use_adjustment = NULL) {
  # Determine whether to use adjustment
  if (is.null(use_adjustment)) {
    use_adjustment <- USE_OPPONENT_ADJUSTMENT
  }

  # First serve in?
  first_in <- runif(1) < server_stats$first_in_pct

  if (first_in) {
    # Check for ace on first serve
    # Ace rate is conditional on first serve being in
    ace_rate_on_first <- server_stats$ace_pct / server_stats$first_in_pct
    if (runif(1) < ace_rate_on_first) {
      return(list(winner = 1, point_type = "ace", serve = "first"))
    }

    # Calculate win probability on first serve
    if (use_adjustment && !is.null(returner_stats) && !is.null(returner_stats$return_vs_first)) {
      # Adjust server's first serve win % based on returner's return ability
      # Server wins at: server_first_won - (avg_return_vs_first - returner_return_vs_first)
      avg_return_vs_first <- 0.35  # Tour average return % vs first serve
      adjustment <- avg_return_vs_first - returner_stats$return_vs_first
      win_prob <- server_stats$first_won_pct + adjustment
      win_prob <- pmax(0.3, pmin(0.95, win_prob))  # Clamp to reasonable range
    } else {
      # No adjustment - use raw serve stats
      win_prob <- server_stats$first_won_pct
    }

    server_wins <- runif(1) < win_prob
    return(list(winner = as.integer(server_wins), point_type = "rally", serve = "first"))

  } else {
    # Second serve
    # Check for double fault
    df_rate_on_second <- server_stats$df_pct / (1 - server_stats$first_in_pct)
    if (runif(1) < df_rate_on_second) {
      return(list(winner = 0, point_type = "double_fault", serve = "second"))
    }

    # Calculate win probability on second serve
    if (use_adjustment && !is.null(returner_stats) && !is.null(returner_stats$return_vs_second)) {
      # Adjust based on returner's return ability
      avg_return_vs_second <- 0.50  # Tour average return % vs second serve
      adjustment <- avg_return_vs_second - returner_stats$return_vs_second
      win_prob <- server_stats$second_won_pct + adjustment
      win_prob <- pmax(0.2, pmin(0.85, win_prob))
    } else {
      # No adjustment - use raw serve stats
      win_prob <- server_stats$second_won_pct
    }

    server_wins <- runif(1) < win_prob
    return(list(winner = as.integer(server_wins), point_type = "rally", serve = "second"))
  }
}

# ============================================================================
# GAME SIMULATION
# ============================================================================

#' Simulate a single game
#' @param server_stats Serving player's statistics
#' @param returner_stats Returning player's statistics
#' @param log_points Whether to log individual points
#' @param use_adjustment Whether to use opponent adjustment (NULL = use global setting)
#' @return List with winner (1 = server, 0 = returner), score, and optionally points log
simulate_game <- function(server_stats, returner_stats = NULL, log_points = FALSE,
                          use_adjustment = NULL) {
  # Points: 0, 15, 30, 40, AD
  server_points <- 0
  returner_points <- 0
  points_log <- list()

  while (TRUE) {
    point_result <- simulate_point(server_stats, returner_stats, use_adjustment)

    if (log_points) {
      points_log <- append(points_log, list(point_result))
    }

    if (point_result$winner == 1) {
      server_points <- server_points + 1
    } else {
      returner_points <- returner_points + 1
    }

    # Check for game won
    if (server_points >= 4 && server_points - returner_points >= 2) {
      return(list(winner = 1, score = c(server_points, returner_points),
                  points = if(log_points) points_log else NULL))
    }
    if (returner_points >= 4 && returner_points - server_points >= 2) {
      return(list(winner = 0, score = c(server_points, returner_points),
                  points = if(log_points) points_log else NULL))
    }
  }
}

#' Simulate a tiebreak
#' @param p1_stats Player 1 statistics (serves first)
#' @param p2_stats Player 2 statistics
#' @param to_points Points needed to win (7 for normal tiebreak, 10 for super tiebreak)
#' @param log_points Whether to log individual points
#' @param use_adjustment Whether to use opponent adjustment (NULL = use global setting)
#' @return List with winner (1 or 2), score, and optionally points log
simulate_tiebreak <- function(p1_stats, p2_stats, to_points = 7, log_points = FALSE,
                              use_adjustment = NULL) {
  p1_points <- 0
  p2_points <- 0
  points_log <- list()

  # Point counter for serve rotation
  # P1 serves first point, then players alternate every 2 points
  point_num <- 0

  while (TRUE) {
    # Determine server based on point number
    # Point 0: P1 serves
    # Points 1-2: P2 serves
    # Points 3-4: P1 serves
    # etc.
    if (point_num == 0) {
      server_is_p1 <- TRUE
    } else {
      server_is_p1 <- ((point_num - 1) %/% 2) %% 2 == 0
    }

    if (server_is_p1) {
      point_result <- simulate_point(p1_stats, p2_stats, use_adjustment)
      point_winner <- if(point_result$winner == 1) 1 else 2
    } else {
      point_result <- simulate_point(p2_stats, p1_stats, use_adjustment)
      point_winner <- if(point_result$winner == 1) 2 else 1
    }

    if (log_points) {
      points_log <- append(points_log, list(c(point_result, server = if(server_is_p1) 1 else 2)))
    }

    if (point_winner == 1) {
      p1_points <- p1_points + 1
    } else {
      p2_points <- p2_points + 1
    }

    point_num <- point_num + 1

    # Check for tiebreak won (must win by 2)
    if (p1_points >= to_points && p1_points - p2_points >= 2) {
      return(list(winner = 1, score = c(p1_points, p2_points),
                  points = if(log_points) points_log else NULL))
    }
    if (p2_points >= to_points && p2_points - p1_points >= 2) {
      return(list(winner = 2, score = c(p1_points, p2_points),
                  points = if(log_points) points_log else NULL))
    }
  }
}

# ============================================================================
# SET SIMULATION
# ============================================================================

#' Simulate a set
#' @param p1_stats Player 1 statistics
#' @param p2_stats Player 2 statistics
#' @param first_server Who serves first (1 or 2)
#' @param tiebreak_at What game score triggers tiebreak (6 = normal, 12 = final set no-TB)
#' @param final_set_tb Type of final set tiebreak: "normal" (7-point at 6-6),
#'                     "super" (10-point at 6-6), or "none" (advantage set)
#' @param log_games Whether to log individual games
#' @param use_adjustment Whether to use opponent adjustment (NULL = use global setting)
#' @return List with winner (1 or 2), score, and optionally games log
simulate_set <- function(p1_stats, p2_stats, first_server = 1,
                         tiebreak_at = 6, final_set_tb = "normal",
                         log_games = FALSE, use_adjustment = NULL) {
  p1_games <- 0
  p2_games <- 0
  games_log <- list()

  current_server <- first_server

  while (TRUE) {
    # Play a game
    if (current_server == 1) {
      game_result <- simulate_game(p1_stats, p2_stats, log_points = FALSE,
                                   use_adjustment = use_adjustment)
      game_winner <- if(game_result$winner == 1) 1 else 2
    } else {
      game_result <- simulate_game(p2_stats, p1_stats, log_points = FALSE,
                                   use_adjustment = use_adjustment)
      game_winner <- if(game_result$winner == 1) 2 else 1
    }

    if (log_games) {
      games_log <- append(games_log, list(list(
        server = current_server,
        winner = game_winner,
        score_before = c(p1_games, p2_games)
      )))
    }

    if (game_winner == 1) {
      p1_games <- p1_games + 1
    } else {
      p2_games <- p2_games + 1
    }

    # Check for set won (6+ games, lead of 2)
    if (p1_games >= 6 && p1_games - p2_games >= 2) {
      return(list(winner = 1, score = c(p1_games, p2_games),
                  games = if(log_games) games_log else NULL,
                  tiebreak = FALSE))
    }
    if (p2_games >= 6 && p2_games - p1_games >= 2) {
      return(list(winner = 2, score = c(p1_games, p2_games),
                  games = if(log_games) games_log else NULL,
                  tiebreak = FALSE))
    }

    # Check for tiebreak
    if (p1_games == tiebreak_at && p2_games == tiebreak_at) {
      if (final_set_tb == "none") {
        # No tiebreak - continue playing (advantage set)
        current_server <- if(current_server == 1) 2 else 1
        next
      }

      tb_points <- if(final_set_tb == "super") 10 else 7
      tb_result <- simulate_tiebreak(p1_stats, p2_stats, to_points = tb_points,
                                     log_points = FALSE, use_adjustment = use_adjustment)

      if (tb_result$winner == 1) {
        p1_games <- p1_games + 1
      } else {
        p2_games <- p2_games + 1
      }

      return(list(winner = tb_result$winner,
                  score = c(p1_games, p2_games),
                  games = if(log_games) games_log else NULL,
                  tiebreak = TRUE,
                  tiebreak_score = tb_result$score))
    }

    # Alternate server
    current_server <- if(current_server == 1) 2 else 1
  }
}

# ============================================================================
# MATCH SIMULATION
# ============================================================================

#' Simulate a complete match
#' @param p1_stats Player 1 statistics
#' @param p2_stats Player 2 statistics
#' @param best_of Number of sets (3 or 5)
#' @param final_set_tb Final set tiebreak rule: "normal", "super", or "none"
#' @param log_sets Whether to log individual sets
#' @param use_adjustment Whether to use opponent adjustment (NULL = use global setting)
#' @return List with winner (1 or 2), score, set scores, and optionally sets log
simulate_match <- function(p1_stats, p2_stats, best_of = 3,
                           final_set_tb = "normal", log_sets = FALSE,
                           use_adjustment = NULL) {
  sets_to_win <- (best_of + 1) / 2  # 2 for best_of=3, 3 for best_of=5

  p1_sets <- 0
  p2_sets <- 0
  set_scores <- list()
  sets_log <- list()

  # Randomly determine first server
  first_server <- sample(1:2, 1)
  current_server <- first_server

  while (p1_sets < sets_to_win && p2_sets < sets_to_win) {
    set_num <- p1_sets + p2_sets + 1
    is_final_set <- (p1_sets == sets_to_win - 1 && p2_sets == sets_to_win - 1)

    set_result <- simulate_set(
      p1_stats, p2_stats,
      first_server = current_server,
      tiebreak_at = 6,
      final_set_tb = if(is_final_set) final_set_tb else "normal",
      log_games = FALSE,
      use_adjustment = use_adjustment
    )

    if (log_sets) {
      sets_log <- append(sets_log, list(set_result))
    }

    set_scores <- append(set_scores, list(set_result$score))

    if (set_result$winner == 1) {
      p1_sets <- p1_sets + 1
    } else {
      p2_sets <- p2_sets + 1
    }

    # Server for next set: whoever didn't serve last game of previous set
    # (In tiebreak, players alternate, so whoever served more serves first next set)
    # Simplified: alternate who serves first in each set
    total_games <- set_result$score[1] + set_result$score[2]
    if (total_games %% 2 == 1) {
      current_server <- if(current_server == 1) 2 else 1
    }
  }

  winner <- if(p1_sets > p2_sets) 1 else 2

  # Format score string
  score_str <- paste(sapply(set_scores, function(s) paste(s[1], s[2], sep = "-")),
                     collapse = " ")

  return(list(
    winner = winner,
    score = c(p1_sets, p2_sets),
    set_scores = set_scores,
    score_string = score_str,
    sets = if(log_sets) sets_log else NULL
  ))
}

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

#' Create player stats object from common inputs
#' @param first_in_pct Percentage of first serves in (0-1)
#' @param first_won_pct Percentage of first serve points won (0-1)
#' @param second_won_pct Percentage of second serve points won (0-1)
#' @param ace_pct Percentage of service points that are aces (0-1)
#' @param df_pct Percentage of service points that are double faults (0-1)
#' @param return_vs_first Return points won vs first serve (0-1), optional
#' @param return_vs_second Return points won vs second serve (0-1), optional
#' @return List of player statistics
make_player_stats <- function(first_in_pct, first_won_pct, second_won_pct,
                               ace_pct, df_pct,
                               return_vs_first = NULL, return_vs_second = NULL) {
  list(
    first_in_pct = first_in_pct,
    first_won_pct = first_won_pct,
    second_won_pct = second_won_pct,
    ace_pct = ace_pct,
    df_pct = df_pct,
    return_vs_first = return_vs_first,
    return_vs_second = return_vs_second
  )
}

#' Calculate derived serve stats
#' @param serve_pts Total serve points
#' @param first_in First serves in
#' @param first_won First serve points won
#' @param second_won Second serve points won
#' @param aces Number of aces
#' @param dfs Number of double faults
#' @return List of derived percentages
calculate_serve_stats <- function(serve_pts, first_in, first_won, second_won, aces, dfs) {
  second_serves <- serve_pts - first_in

  list(
    first_in_pct = first_in / serve_pts,
    first_won_pct = first_won / first_in,
    second_won_pct = if(second_serves > 0) second_won / second_serves else 0.5,
    ace_pct = aces / serve_pts,
    df_pct = dfs / serve_pts
  )
}

# ============================================================================
# QUICK TEST
# ============================================================================

if (FALSE) {  # Set to TRUE to run test
  # Example: Simulate a match between two players
  # Stats roughly based on typical ATP players

  player1 <- make_player_stats(
    first_in_pct = 0.62,
    first_won_pct = 0.75,
    second_won_pct = 0.52,
    ace_pct = 0.08,
    df_pct = 0.03,
    return_vs_first = 0.30,
    return_vs_second = 0.50
  )

  player2 <- make_player_stats(
    first_in_pct = 0.65,
    first_won_pct = 0.72,
    second_won_pct = 0.50,
    ace_pct = 0.05,
    df_pct = 0.04,
    return_vs_first = 0.32,
    return_vs_second = 0.52
  )

  # Simulate one match
  result <- simulate_match(player1, player2, best_of = 3)
  cat(sprintf("Winner: Player %d\n", result$winner))
  cat(sprintf("Score: %s\n", result$score_string))

  # Simulate many matches to estimate win probability
  n_sims <- 1000
  wins <- replicate(n_sims, simulate_match(player1, player2, best_of = 3)$winner)
  cat(sprintf("\nPlayer 1 win probability: %.1f%%\n", mean(wins == 1) * 100))
}
