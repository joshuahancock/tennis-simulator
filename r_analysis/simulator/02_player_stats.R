# Player Statistics Loader for Tennis Simulator
# Loads and processes player serve/return statistics by surface
#
# Usage:
#   source("r_analysis/simulator/02_player_stats.R")
#   stats <- load_player_stats()
#   p_stats <- get_player_stats("Novak Djokovic", surface = "Hard", stats_db = stats)

library(tidyverse)
library(lubridate)

# Source utility functions for similarity calculations
source("r_analysis/utils.R")

# ============================================================================
# CONFIGURATION
# ============================================================================

# Minimum matches required for surface-specific stats
MIN_SURFACE_MATCHES <- 20

# Minimum total matches required for any stats (default, can be overridden)
MIN_TOTAL_MATCHES <- 20

# Years to include for calculating current stats
STATS_YEARS_WINDOW <- 3

# Similarity-based fallback configuration
SIMILARITY_TOP_N <- 10

# ============================================================================
# DATA LOADING
# ============================================================================

#' Load ATP match data for calculating player statistics
#' @param data_dir Path to tennis_atp directory
#' @param year_from First year to include (default: 2015)
#' @param year_to Last year to include (default: current year)
#' @return Dataframe with all ATP matches and serve/return stats
load_atp_matches <- function(data_dir = "data/raw/tennis_atp",
                              year_from = 2015, year_to = NULL) {
  if (is.null(year_to)) {
    year_to <- year(Sys.Date())
  }

  pattern <- "atp_matches_\\d{4}\\.csv"
  files <- list.files(data_dir, pattern = pattern, full.names = TRUE)

  # Filter to years in range
  years_in_files <- as.integer(gsub(".*atp_matches_(\\d{4})\\.csv", "\\1", files))
  files <- files[years_in_files >= year_from & years_in_files <= year_to]

  if (length(files) == 0) {
    stop("No ATP match files found for specified year range")
  }

  cat(sprintf("Loading %d ATP match files (%d-%d)...\n",
              length(files), year_from, year_to))

  matches <- map_dfr(files, function(f) {
    read_csv(f, show_col_types = FALSE) %>%
      mutate(file_year = as.integer(gsub(".*atp_matches_(\\d{4})\\.csv", "\\1", f)))
  })

  # Parse date and standardize surface
  matches <- matches %>%
    mutate(
      match_date = ymd(tourney_date),
      match_year = year(match_date),
      surface = case_when(
        str_to_lower(surface) %in% c("hard", "h") ~ "Hard",
        str_to_lower(surface) %in% c("clay", "c") ~ "Clay",
        str_to_lower(surface) %in% c("grass", "g") ~ "Grass",
        str_to_lower(surface) %in% c("carpet") ~ "Carpet",
        TRUE ~ "Other"
      )
    ) %>%
    # Remove matches without serve stats
    filter(!is.na(w_svpt), w_svpt > 0)

  cat(sprintf("  Loaded %s matches\n", format(nrow(matches), big.mark = ",")))
  return(matches)
}

#' Load WTA match data for calculating player statistics
#' @param data_dir Path to tennis_wta directory
#' @param year_from First year to include
#' @param year_to Last year to include
#' @return Dataframe with all WTA matches and serve/return stats
load_wta_matches <- function(data_dir = "data/raw/tennis_wta",
                              year_from = 2015, year_to = NULL) {
  if (is.null(year_to)) {
    year_to <- year(Sys.Date())
  }

  pattern <- "wta_matches_\\d{4}\\.csv"
  files <- list.files(data_dir, pattern = pattern, full.names = TRUE)

  years_in_files <- as.integer(gsub(".*wta_matches_(\\d{4})\\.csv", "\\1", files))
  files <- files[years_in_files >= year_from & years_in_files <= year_to]

  if (length(files) == 0) {
    stop("No WTA match files found for specified year range")
  }

  cat(sprintf("Loading %d WTA match files (%d-%d)...\n",
              length(files), year_from, year_to))

  matches <- map_dfr(files, function(f) {
    read_csv(f, show_col_types = FALSE) %>%
      mutate(file_year = as.integer(gsub(".*wta_matches_(\\d{4})\\.csv", "\\1", f)))
  })

  matches <- matches %>%
    mutate(
      match_date = ymd(tourney_date),
      match_year = year(match_date),
      surface = case_when(
        str_to_lower(surface) %in% c("hard", "h") ~ "Hard",
        str_to_lower(surface) %in% c("clay", "c") ~ "Clay",
        str_to_lower(surface) %in% c("grass", "g") ~ "Grass",
        str_to_lower(surface) %in% c("carpet") ~ "Carpet",
        TRUE ~ "Other"
      )
    ) %>%
    filter(!is.na(w_svpt), w_svpt > 0)

  cat(sprintf("  Loaded %s matches\n", format(nrow(matches), big.mark = ",")))
  return(matches)
}

# ============================================================================
# STATISTICS CALCULATION
# ============================================================================

#' Calculate player serve/return statistics from match data
#' @param matches Match dataframe from load_atp_matches or load_wta_matches
#' @param by_surface Whether to calculate surface-specific stats
#' @return Dataframe with player statistics
calculate_player_stats <- function(matches, by_surface = TRUE) {
  # Reshape to have one row per player per match (both winner and loser)
  winner_stats <- matches %>%
    select(
      match_id = tourney_id,
      match_date,
      match_year,
      surface,
      player = winner_name,
      opponent = loser_name,
      # Serve stats
      serve_pts = w_svpt,
      first_in = w_1stIn,
      first_won = w_1stWon,
      second_won = w_2ndWon,
      aces = w_ace,
      dfs = w_df,
      # Return stats (opponent's serve)
      opp_serve_pts = l_svpt,
      opp_first_in = l_1stIn,
      opp_first_won = l_1stWon,
      opp_second_won = l_2ndWon
    ) %>%
    mutate(
      won = TRUE,
      match_row = paste(match_id, match_date, sep = "_")
    )

  loser_stats <- matches %>%
    select(
      match_id = tourney_id,
      match_date,
      match_year,
      surface,
      player = loser_name,
      opponent = winner_name,
      serve_pts = l_svpt,
      first_in = l_1stIn,
      first_won = l_1stWon,
      second_won = l_2ndWon,
      aces = l_ace,
      dfs = l_df,
      opp_serve_pts = w_svpt,
      opp_first_in = w_1stIn,
      opp_first_won = w_1stWon,
      opp_second_won = w_2ndWon
    ) %>%
    mutate(
      won = FALSE,
      match_row = paste(match_id, match_date, sep = "_")
    )

  all_stats <- bind_rows(winner_stats, loser_stats)

  # Calculate return points won (opponent's serve points - opponent's serve points won)
  all_stats <- all_stats %>%
    mutate(
      return_pts = opp_serve_pts,
      return_pts_won = opp_serve_pts - opp_first_won - opp_second_won,
      return_vs_first = opp_first_in - opp_first_won,
      return_vs_second = (opp_serve_pts - opp_first_in) - opp_second_won
    )

  # Aggregate by player (and optionally surface)
  group_cols <- if(by_surface) c("player", "surface") else c("player")

  player_stats <- all_stats %>%
    group_by(across(all_of(group_cols))) %>%
    summarize(
      matches = n(),
      wins = sum(won),

      # Serve totals
      total_serve_pts = sum(serve_pts, na.rm = TRUE),
      total_first_in = sum(first_in, na.rm = TRUE),
      total_first_won = sum(first_won, na.rm = TRUE),
      total_second_won = sum(second_won, na.rm = TRUE),
      total_aces = sum(aces, na.rm = TRUE),
      total_dfs = sum(dfs, na.rm = TRUE),

      # Return totals
      total_return_pts = sum(return_pts, na.rm = TRUE),
      total_return_won = sum(return_pts_won, na.rm = TRUE),
      total_return_vs_first = sum(return_vs_first, na.rm = TRUE),
      total_opp_first_in = sum(opp_first_in, na.rm = TRUE),
      total_return_vs_second = sum(return_vs_second, na.rm = TRUE),
      total_opp_second = sum(opp_serve_pts - opp_first_in, na.rm = TRUE),

      .groups = "drop"
    ) %>%
    mutate(
      # Serve percentages
      first_in_pct = total_first_in / total_serve_pts,
      first_won_pct = total_first_won / total_first_in,
      second_won_pct = total_second_won / (total_serve_pts - total_first_in),
      ace_pct = total_aces / total_serve_pts,
      df_pct = total_dfs / total_serve_pts,
      serve_pct = (total_first_won + total_second_won) / total_serve_pts,

      # Return percentages
      return_pct = total_return_won / total_return_pts,
      return_vs_first_pct = total_return_vs_first / total_opp_first_in,
      return_vs_second_pct = total_return_vs_second / total_opp_second,

      # Win rate
      win_rate = wins / matches
    )

  return(player_stats)
}

#' Calculate tour-average statistics (for filling missing data)
#' @param matches Match dataframe
#' @param by_surface Whether to calculate surface-specific averages
#' @return Dataframe with tour average stats
calculate_tour_averages <- function(matches, by_surface = TRUE) {
  group_cols <- if(by_surface) c("surface") else c()

  if (length(group_cols) == 0) {
    tour_avg <- matches %>%
      summarize(
        total_serve_pts = sum(w_svpt, na.rm = TRUE) + sum(l_svpt, na.rm = TRUE),
        total_first_in = sum(w_1stIn, na.rm = TRUE) + sum(l_1stIn, na.rm = TRUE),
        total_first_won = sum(w_1stWon, na.rm = TRUE) + sum(l_1stWon, na.rm = TRUE),
        total_second_won = sum(w_2ndWon, na.rm = TRUE) + sum(l_2ndWon, na.rm = TRUE),
        total_aces = sum(w_ace, na.rm = TRUE) + sum(l_ace, na.rm = TRUE),
        total_dfs = sum(w_df, na.rm = TRUE) + sum(l_df, na.rm = TRUE)
      )
  } else {
    tour_avg <- matches %>%
      group_by(across(all_of(group_cols))) %>%
      summarize(
        total_serve_pts = sum(w_svpt, na.rm = TRUE) + sum(l_svpt, na.rm = TRUE),
        total_first_in = sum(w_1stIn, na.rm = TRUE) + sum(l_1stIn, na.rm = TRUE),
        total_first_won = sum(w_1stWon, na.rm = TRUE) + sum(l_1stWon, na.rm = TRUE),
        total_second_won = sum(w_2ndWon, na.rm = TRUE) + sum(l_2ndWon, na.rm = TRUE),
        total_aces = sum(w_ace, na.rm = TRUE) + sum(l_ace, na.rm = TRUE),
        total_dfs = sum(w_df, na.rm = TRUE) + sum(l_df, na.rm = TRUE),
        .groups = "drop"
      )
  }

  tour_avg %>%
    mutate(
      first_in_pct = total_first_in / total_serve_pts,
      first_won_pct = total_first_won / total_first_in,
      second_won_pct = total_second_won / (total_serve_pts - total_first_in),
      ace_pct = total_aces / total_serve_pts,
      df_pct = total_dfs / total_serve_pts,
      serve_pct = (total_first_won + total_second_won) / total_serve_pts,
      return_pct = 1 - serve_pct,  # Average return = 1 - average serve
      return_vs_first_pct = 1 - first_won_pct,
      return_vs_second_pct = 1 - second_won_pct
    )
}

# ============================================================================
# STATS DATABASE
# ============================================================================

#' Build complete player statistics database
#' @param tour "ATP" or "WTA"
#' @param year_from First year to include
#' @param year_to Last year to include
#' @return List with player_stats, player_stats_overall, and tour_averages
load_player_stats <- function(tour = "ATP", year_from = 2015, year_to = NULL) {
  # Load matches
  if (str_to_upper(tour) == "ATP") {
    matches <- load_atp_matches(year_from = year_from, year_to = year_to)
  } else {
    matches <- load_wta_matches(year_from = year_from, year_to = year_to)
  }

  cat("Calculating player statistics...\n")

  # Calculate by-surface stats
  player_stats_surface <- calculate_player_stats(matches, by_surface = TRUE)

  # Calculate overall stats (for fallback)
  player_stats_overall <- calculate_player_stats(matches, by_surface = FALSE)

  # Calculate tour averages
  tour_avg_surface <- calculate_tour_averages(matches, by_surface = TRUE)
  tour_avg_overall <- calculate_tour_averages(matches, by_surface = FALSE)

  cat(sprintf("  Players with stats: %d\n", n_distinct(player_stats_overall$player)))
  cat(sprintf("  Surface breakdowns: Hard=%d, Clay=%d, Grass=%d\n",
              sum(player_stats_surface$surface == "Hard"),
              sum(player_stats_surface$surface == "Clay"),
              sum(player_stats_surface$surface == "Grass")))

  return(list(
    matches = matches,
    player_stats_surface = player_stats_surface,
    player_stats_overall = player_stats_overall,
    tour_avg_surface = tour_avg_surface,
    tour_avg_overall = tour_avg_overall
  ))
}

#' Build stats database from pre-filtered matches
#' Used for backtesting with date cutoffs to prevent data leakage
#' @param matches Pre-filtered match dataframe
#' @param verbose Whether to print progress messages
#' @return List with same structure as load_player_stats()
build_stats_db_from_matches <- function(matches, verbose = FALSE) {
  if (nrow(matches) == 0) {
    return(NULL)
  }

  if (verbose) {
    cat(sprintf("Building stats from %d matches...\n", nrow(matches)))
  }

  # Calculate by-surface stats

player_stats_surface <- calculate_player_stats(matches, by_surface = TRUE)

  # Calculate overall stats (for fallback)
  player_stats_overall <- calculate_player_stats(matches, by_surface = FALSE)

  # Calculate tour averages
  tour_avg_surface <- calculate_tour_averages(matches, by_surface = TRUE)
  tour_avg_overall <- calculate_tour_averages(matches, by_surface = FALSE)

  return(list(
    matches = matches,
    player_stats_surface = player_stats_surface,
    player_stats_overall = player_stats_overall,
    tour_avg_surface = tour_avg_surface,
    tour_avg_overall = tour_avg_overall
  ))
}

# ============================================================================
# SIMILARITY-BASED STATS LOOKUP
# ============================================================================

#' Get similarity-weighted stats for a player with insufficient data
#'
#' When a player has < MIN_TOTAL_MATCHES, this function finds similar players
#' from the charting feature database and calculates weighted average stats.
#'
#' @param player_name Player name to find similar players for
#' @param surface Surface for stats (or NULL for overall)
#' @param stats_db Stats database from load_player_stats()
#' @param feature_db Feature database with normalized player features
#' @param top_n Number of similar players to use
#' @return List with similarity-weighted stats, or NULL if not possible
get_similarity_weighted_stats <- function(player_name, surface = NULL, stats_db,
                                           feature_db, top_n = SIMILARITY_TOP_N) {

  # Check if player exists in feature database
  player_features <- feature_db %>%
    filter(player_name == !!player_name)

  if (nrow(player_features) == 0) {
    return(NULL)  # Player not in charting data
  }

  # Get most recent age for this player
  player_row <- player_features %>%
    filter(match_year == max(match_year)) %>%
    slice(1)

  player_age <- player_row$age

  # Find similar players using cosine similarity
  similar <- find_similar_players(
    data = feature_db,
    player_name_query = player_name,
    age_query = player_age,
    feature_cols = ALL_FEATURES,
    similarity_fn = cosine_similarity,
    top_n = top_n,
    exclude_same_player = TRUE
  )

  if (is.null(similar) || nrow(similar) == 0) {
    return(NULL)  # No similar players found
  }

  # Get stats for each similar player from stats_db
  similar_stats <- list()

  for (i in 1:nrow(similar)) {
    sim_player <- similar$player_name[i]
    sim_score <- similar$similarity[i]

    # Try surface-specific first, then overall
    if (!is.null(surface)) {
      player_surface <- stats_db$player_stats_surface %>%
        filter(player == sim_player, surface == !!surface)

      if (nrow(player_surface) > 0 && player_surface$matches[1] >= 5) {
        similar_stats[[i]] <- list(
          similarity = sim_score,
          first_in_pct = player_surface$first_in_pct,
          first_won_pct = player_surface$first_won_pct,
          second_won_pct = player_surface$second_won_pct,
          ace_pct = player_surface$ace_pct,
          df_pct = player_surface$df_pct,
          return_vs_first = player_surface$return_vs_first_pct,
          return_vs_second = player_surface$return_vs_second_pct
        )
        next
      }
    }

    # Fall back to overall stats
    player_overall <- stats_db$player_stats_overall %>%
      filter(player == sim_player)

    if (nrow(player_overall) > 0 && player_overall$matches[1] >= 5) {
      similar_stats[[i]] <- list(
        similarity = sim_score,
        first_in_pct = player_overall$first_in_pct,
        first_won_pct = player_overall$first_won_pct,
        second_won_pct = player_overall$second_won_pct,
        ace_pct = player_overall$ace_pct,
        df_pct = player_overall$df_pct,
        return_vs_first = player_overall$return_vs_first_pct,
        return_vs_second = player_overall$return_vs_second_pct
      )
    }
  }

  # Filter out NULL entries (similar players without stats)
  similar_stats <- Filter(Negate(is.null), similar_stats)

  if (length(similar_stats) == 0) {
    return(NULL)  # No similar players had usable stats
  }

  # Calculate similarity-weighted averages
  total_weight <- sum(sapply(similar_stats, function(x) x$similarity))

  weighted_avg <- function(stat_name) {
    sum(sapply(similar_stats, function(x) x[[stat_name]] * x$similarity)) / total_weight
  }

  return(list(
    player = player_name,
    surface = surface,
    source = "similarity_weighted",
    matches = 0,
    n_similar = length(similar_stats),
    first_in_pct = weighted_avg("first_in_pct"),
    first_won_pct = weighted_avg("first_won_pct"),
    second_won_pct = weighted_avg("second_won_pct"),
    ace_pct = weighted_avg("ace_pct"),
    df_pct = weighted_avg("df_pct"),
    return_vs_first = weighted_avg("return_vs_first"),
    return_vs_second = weighted_avg("return_vs_second")
  ))
}

# ============================================================================
# PLAYER STATS RETRIEVAL
# ============================================================================

#' Get player statistics for simulation
#' @param player_name Player name
#' @param surface Surface ("Hard", "Clay", "Grass", or NULL for overall)
#' @param stats_db Stats database from load_player_stats()
#' @param feature_db Optional feature database for similarity-based fallback
#' @param min_surface_matches Minimum matches to use surface-specific stats
#' @param min_total_matches Minimum matches to use player stats (else use tour avg)
#' @return List of player statistics for simulation
get_player_stats <- function(player_name, surface = NULL, stats_db,
                              feature_db = NULL,
                              min_surface_matches = MIN_SURFACE_MATCHES,
                              min_total_matches = MIN_TOTAL_MATCHES) {

  # Try to find player in database
  player_overall <- stats_db$player_stats_overall %>%
    filter(player == player_name)

  if (nrow(player_overall) == 0 || player_overall$matches[1] < min_total_matches) {
    # Player not found or insufficient data
    # Try similarity-based stats first if feature_db is provided
    if (!is.null(feature_db)) {
      sim_stats <- get_similarity_weighted_stats(player_name, surface, stats_db, feature_db)
      if (!is.null(sim_stats)) {
        cat(sprintf("  Using similarity-weighted stats for %s (%d similar players)\n",
                    player_name, sim_stats$n_similar))
        return(sim_stats)
      }
    }

    # Fall back to tour average
    cat(sprintf("  Warning: Using tour average for %s (insufficient data)\n", player_name))

    if (!is.null(surface) && surface %in% stats_db$tour_avg_surface$surface) {
      avg <- stats_db$tour_avg_surface %>% filter(surface == !!surface)
    } else {
      avg <- stats_db$tour_avg_overall
    }

    return(list(
      player = player_name,
      surface = surface,
      source = "tour_average",
      matches = 0,
      first_in_pct = avg$first_in_pct,
      first_won_pct = avg$first_won_pct,
      second_won_pct = avg$second_won_pct,
      ace_pct = avg$ace_pct,
      df_pct = avg$df_pct,
      return_vs_first = avg$return_vs_first_pct,
      return_vs_second = avg$return_vs_second_pct
    ))
  }

  # Check for surface-specific stats
  if (!is.null(surface)) {
    player_surface <- stats_db$player_stats_surface %>%
      filter(player == player_name, surface == !!surface)

    if (nrow(player_surface) > 0 && player_surface$matches[1] >= min_surface_matches) {
      # Use surface-specific stats
      ps <- player_surface
      return(list(
        player = player_name,
        surface = surface,
        source = "surface_specific",
        matches = ps$matches,
        first_in_pct = ps$first_in_pct,
        first_won_pct = ps$first_won_pct,
        second_won_pct = ps$second_won_pct,
        ace_pct = ps$ace_pct,
        df_pct = ps$df_pct,
        return_vs_first = ps$return_vs_first_pct,
        return_vs_second = ps$return_vs_second_pct
      ))
    }
  }

  # Fall back to overall stats
  po <- player_overall
  return(list(
    player = player_name,
    surface = surface,
    source = "overall",
    matches = po$matches,
    first_in_pct = po$first_in_pct,
    first_won_pct = po$first_won_pct,
    second_won_pct = po$second_won_pct,
    ace_pct = po$ace_pct,
    df_pct = po$df_pct,
    return_vs_first = po$return_vs_first_pct,
    return_vs_second = po$return_vs_second_pct
  ))
}

#' Search for player names (fuzzy matching)
#' @param query Search string
#' @param stats_db Stats database
#' @param max_results Maximum results to return
#' @return Vector of matching player names
search_player <- function(query, stats_db, max_results = 10) {
  players <- unique(stats_db$player_stats_overall$player)
  query_lower <- str_to_lower(query)

  # First try exact match
  exact <- players[str_to_lower(players) == query_lower]
  if (length(exact) > 0) return(exact)

  # Then try starts with
  starts <- players[str_starts(str_to_lower(players), query_lower)]
  if (length(starts) > 0) return(head(starts, max_results))

  # Then try contains
  contains <- players[str_detect(str_to_lower(players), fixed(query_lower))]
  return(head(contains, max_results))
}

# ============================================================================
# CHARTING DATA INTEGRATION
# ============================================================================

#' Load player stats from charting feature matrix
#' @param feature_file Path to normalized features CSV
#' @return Dataframe with player statistics from charting data
load_charting_stats <- function(feature_file = "data/processed/charting_only_features_normalized.csv") {
  if (!file.exists(feature_file)) {
    warning("Charting features file not found: ", feature_file)
    return(NULL)
  }

  cat("Loading charting-based statistics...\n")

  features <- read_csv(feature_file, show_col_types = FALSE)

  # Get most recent stats for each player
  charting_stats <- features %>%
    group_by(player_name) %>%
    filter(match_year == max(match_year)) %>%
    ungroup() %>%
    select(
      player = player_name,
      charting_year = match_year,
      charting_matches,
      # Serve stats
      serve_pct,
      first_in_pct,
      first_won_pct,
      ace_pct,
      df_pct,
      # Return stats
      return_pct,
      # Additional useful features
      net_approach_rate,
      net_win_pct,
      winner_pct
    ) %>%
    mutate(
      # Derive second serve won % from overall serve % and first serve stats
      # serve_pct = first_in_pct * first_won_pct + (1 - first_in_pct) * second_won_pct
      # Solving for second_won_pct:
      second_won_pct = (serve_pct - first_in_pct * first_won_pct) / (1 - first_in_pct),
      # Derive return vs first/second (approximations)
      return_vs_first_pct = return_pct * 0.7,  # Return vs first is harder
      return_vs_second_pct = return_pct * 1.3   # Return vs second is easier
    )

  cat(sprintf("  Loaded charting stats for %d players\n", nrow(charting_stats)))
  return(charting_stats)
}

# ============================================================================
# QUICK TEST
# ============================================================================

if (FALSE) {  # Set to TRUE to run test
  # Load ATP stats
  stats <- load_player_stats(tour = "ATP", year_from = 2020)

  # Get stats for specific player
  djokovic_hard <- get_player_stats("Novak Djokovic", surface = "Hard", stats_db = stats)
  djokovic_clay <- get_player_stats("Novak Djokovic", surface = "Clay", stats_db = stats)

  cat("\nDjokovic on Hard:\n")
  print(djokovic_hard)

  cat("\nDjokovic on Clay:\n")
  print(djokovic_clay)

  # Search for players
  cat("\nSearching for 'alcaraz':\n")
  print(search_player("alcaraz", stats))
}
