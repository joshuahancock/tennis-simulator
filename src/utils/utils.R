# Shared Utility Functions for Tennis Similarity Analysis
# Source this file in other scripts: source("src/utils/utils.R")

library(tidyverse)

# ============================================================================
# NORMALIZATION
# ============================================================================

#' Z-score normalize specified columns in a dataframe
#' @param df Dataframe to normalize
#' @param cols Vector of column names to normalize
#' @return Dataframe with additional _z columns for each normalized feature
normalize_features <- function(df, cols) {
  df_normalized <- df
  for (col in cols) {
    if (col %in% names(df)) {
      col_mean <- mean(df[[col]], na.rm = TRUE)
      col_sd <- sd(df[[col]], na.rm = TRUE)
      if (!is.na(col_sd) && col_sd > 0) {
        df_normalized[[paste0(col, "_z")]] <- (df[[col]] - col_mean) / col_sd
      }
    }
  }
  df_normalized
}

# ============================================================================
# SIMILARITY FUNCTIONS
# ============================================================================

#' Compute cosine similarity between two vectors
#' @param v1 First vector
#' @param v2 Second vector
#' @return Cosine similarity (0 to 1), or NA if vectors have NAs or zero norm
cosine_similarity <- function(v1, v2) {
  if (any(is.na(v1)) || any(is.na(v2))) return(NA_real_)

  dot_product <- sum(v1 * v2)
  norm1 <- sqrt(sum(v1^2))
  norm2 <- sqrt(sum(v2^2))

  if (norm1 == 0 || norm2 == 0) return(NA_real_)

  dot_product / (norm1 * norm2)
}

#' Compute Euclidean distance between two vectors
#' @param v1 First vector
#' @param v2 Second vector
#' @return Euclidean distance, or NA if vectors have NAs
euclidean_distance <- function(v1, v2) {
  if (any(is.na(v1)) || any(is.na(v2))) return(NA_real_)
  sqrt(sum((v1 - v2)^2))
}

#' Convert Euclidean distance to similarity (0 to 1 scale)
#' @param dist Euclidean distance
#' @return Similarity score (1 = identical, approaches 0 as distance increases)
euclidean_to_similarity <- function(dist) {
  1 / (1 + dist)
}

# ============================================================================
# PLAYER SIMILARITY SEARCH
# ============================================================================

#' Find players most similar to a query player
#' @param data Dataframe with normalized features (must have player_name, age columns)
#' @param player_name_query Name of player to find matches for
#' @param age_query Age of player to find matches for
#' @param feature_cols Vector of feature column names (without _z suffix)
#' @param similarity_fn Function to compute similarity (default: cosine_similarity)
#' @param top_n Number of similar players to return
#' @param exclude_same_player Whether to exclude the query player from results
#' @return Dataframe of similar players with similarity scores
find_similar_players <- function(data, player_name_query, age_query,
                                  feature_cols,
                                  similarity_fn = cosine_similarity,
                                  top_n = 10,
                                  exclude_same_player = TRUE) {

  # Get z-score columns for the specified features
  z_cols <- paste0(feature_cols, "_z")
  z_cols <- intersect(z_cols, names(data))

  if (length(z_cols) == 0) {
    warning("No matching z-score columns found!")
    return(NULL)
  }

  query_row <- data %>%
    filter(player_name == player_name_query, age == age_query)

  if (nrow(query_row) == 0) {
    warning(sprintf("Player '%s' at age %d not found", player_name_query, age_query))
    return(NULL)
  }

  query_vec <- as.numeric(query_row[1, z_cols])

  similarities <- data %>%
    rowwise() %>%
    mutate(
      similarity = similarity_fn(query_vec, c_across(all_of(z_cols)))
    ) %>%
    ungroup()

  if (exclude_same_player) {
    similarities <- similarities %>%
      filter(player_name != player_name_query)
  }

  similarities %>%
    filter(!is.na(similarity)) %>%
    arrange(desc(similarity)) %>%
    mutate(rank = row_number()) %>%
    head(top_n)
}

# ============================================================================
# FEATURE SET DEFINITIONS
# ============================================================================

# All available features (49 total)
ALL_FEATURES <- c(
  # Physical/context (from ATP)
  "height", "age", "years_on_tour", "career_matches", "avg_ranking",

  # Serve style (from charting)
  "serve_pct", "first_in_pct", "first_won_pct", "ace_pct", "df_pct",

  # Return (from charting)
  "return_pct",

  # Play style (from charting)
  "winner_pct", "fh_winner_ratio", "winners_per_shot", "ue_per_shot",

  # Net play - overall
  "net_approach_rate", "net_win_pct", "net_winner_pct",
  "net_forced_error_pct", "passed_at_net_pct",

  # Net play - serve & volley
  "snv_rate", "snv_success_pct", "snv_winner_pct",

  # Net play - approach shots (all)
  "approach_rate", "approach_success_pct", "approach_winner_pct",

  # Net play - mid-rally approaches only (excludes serve+1)
  "rally_approach_rate", "rally_approach_success_pct", "rally_approach_winner_pct",

  # Rally length - point distribution
  "rally_short_pct", "rally_med_pct", "rally_medlong_pct", "rally_long_pct",

  # Rally length - win rates
  "rally_short_win_pct", "rally_med_win_pct",
  "rally_medlong_win_pct", "rally_long_win_pct",

  # Groundstroke patterns - shot selection
  "fh_groundstroke_pct", "dropshot_rate", "slice_rate", "lob_rate",

  # Groundstroke patterns - direction
  "fh_inside_out_rate", "fh_dtl_rate", "bh_dtl_rate", "overall_dtl_rate",

  # Court position / aggression - return depth
  "deep_return_pct", "very_deep_return_pct", "shallow_return_pct",

  # Court position / aggression - return outcomes
  "return_winner_rate", "return_in_play_rate",

  # Pressure performance
  "bp_conversion_rate", "bp_save_rate"
)

# Baseline features (original 17)
BASELINE_FEATURES <- c(
  "height", "age", "years_on_tour", "career_matches", "avg_ranking",
  "serve_pct", "first_in_pct", "first_won_pct", "ace_pct", "df_pct",
  "return_pct",
  "winner_pct", "fh_winner_ratio", "winners_per_shot", "ue_per_shot",
  "net_approach_rate", "net_win_pct"
)

# Net play features (29)
NET_PLAY_FEATURES <- c(
  BASELINE_FEATURES,
  "net_winner_pct", "net_forced_error_pct", "passed_at_net_pct",
  "snv_rate", "snv_success_pct", "snv_winner_pct",
  "approach_rate", "approach_success_pct", "approach_winner_pct",
  "rally_approach_rate", "rally_approach_success_pct", "rally_approach_winner_pct"
)

# Rally features (34)
RALLY_FEATURES <- c(
  NET_PLAY_FEATURES,
  "rally_short_pct", "rally_med_pct", "rally_medlong_pct", "rally_long_pct",
  "rally_short_win_pct", "rally_med_win_pct",
  "rally_medlong_win_pct", "rally_long_win_pct"
)

# Groundstroke features (42)
GROUNDSTROKE_FEATURES <- c(
  RALLY_FEATURES,
  "fh_groundstroke_pct", "dropshot_rate", "slice_rate", "lob_rate",
  "fh_inside_out_rate", "fh_dtl_rate", "bh_dtl_rate", "overall_dtl_rate"
)

# ============================================================================
# TEST CASES
# ============================================================================

# Standard test cases for comparing similarity results
DEFAULT_TEST_CASES <- list(
  c("Pete Sampras", 26),
  c("Rafael Nadal", 28),
  c("Roger Federer", 30),
  c("Carlos Alcaraz", 21),
  c("Andre Agassi", 29),
  c("Patrick Rafter", 26)
)

#' Run similarity test cases and print results
#' @param data Normalized feature matrix
#' @param feature_cols Features to use for similarity
#' @param test_cases List of c(player_name, age) vectors
#' @param similarity_fn Similarity function to use
#' @param top_n Number of results per player
run_test_cases <- function(data, feature_cols,
                           test_cases = DEFAULT_TEST_CASES,
                           similarity_fn = cosine_similarity,
                           top_n = 10) {

  cat("\n", paste(rep("=", 60), collapse = ""), "\n", sep = "")
  cat("PLAYER SIMILARITY RESULTS\n")
  cat(sprintf("Features: %d\n", length(feature_cols)))
  cat(paste(rep("=", 60), collapse = ""), "\n", sep = "")

  results_list <- list()

  for (tc in test_cases) {
    player <- tc[1]
    age <- as.integer(tc[2])

    cat(sprintf("\n>>> Similar players to %s at age %d:\n", player, age))

    result <- find_similar_players(
      data, player, age, feature_cols,
      similarity_fn = similarity_fn,
      top_n = top_n
    )

    if (!is.null(result) && nrow(result) > 0) {
      print(
        result %>%
          select(player_name, age, similarity, charting_matches,
                 serve_pct, return_pct, net_approach_rate) %>%
          mutate(across(where(is.numeric), ~round(., 3)))
      )
      results_list[[paste(player, age, sep = "_")]] <- result
    }
  }

  invisible(results_list)
}
