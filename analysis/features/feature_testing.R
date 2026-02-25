# Feature Testing Script
# Compare player similarity results before/after adding features
# Use this to spot-check how new features affect similarity rankings
# Requires: Run 01_build_features.R first to generate the feature matrix

library(tidyverse)
source("src/utils/utils.R")

# ============================================================================
# 1. LOAD PROCESSED DATA
# ============================================================================

cat("Loading processed feature data...\n")

feature_matrix <- read_csv("data/processed/charting_only_features_normalized.csv",
                           show_col_types = FALSE)

cat(sprintf("  Loaded %s player/age combinations\n", format(nrow(feature_matrix), big.mark = ",")))

# ============================================================================
# 2. COMPARISON FUNCTION
# ============================================================================

compare_feature_sets <- function(data, player_name, player_age,
                                  features_before, features_after,
                                  top_n = 10,
                                  label_before = "Before",
                                  label_after = "After") {

  cat(sprintf("\n%s\n", paste(rep("=", 70), collapse = "")))
  cat(sprintf("COMPARING: %s at age %d\n", player_name, player_age))
  cat(sprintf("%s\n", paste(rep("=", 70), collapse = "")))

  # Get results with both feature sets
  results_before <- find_similar_players(
    data, player_name, player_age, features_before,
    similarity_fn = cosine_similarity,
    top_n = top_n
  )

  results_after <- find_similar_players(
    data, player_name, player_age, features_after,
    similarity_fn = cosine_similarity,
    top_n = top_n
  )

  if (is.null(results_before) || is.null(results_after)) {
    return(NULL)
  }

  # Create comparison table
  comparison <- results_after %>%
    select(player_name, age, similarity) %>%
    mutate(rank_after = row_number()) %>%
    rename(sim_after = similarity) %>%
    left_join(
      results_before %>%
        select(player_name, age, similarity) %>%
        mutate(rank_before = row_number()) %>%
        rename(sim_before = similarity),
      by = c("player_name", "age")
    ) %>%
    mutate(
      rank_change = rank_before - rank_after,
      rank_change_str = case_when(
        is.na(rank_before) ~ "(NEW)",
        rank_change > 0 ~ sprintf("+%d", rank_change),
        rank_change < 0 ~ sprintf("%d", rank_change),
        TRUE ~ "="
      )
    )

  # Players who dropped out
  dropped <- results_before %>%
    select(player_name, age, similarity, rank) %>%
    anti_join(results_after %>% select(player_name, age), by = c("player_name", "age"))

  # Print results
  cat(sprintf("\nFeatures %s: %d | Features %s: %d\n",
              label_before, length(features_before),
              label_after, length(features_after)))

  cat(sprintf("\nTop %d similar players (%s):\n", top_n, label_after))
  cat(sprintf("%-25s %4s  %6s  %6s  %s\n",
              "Player", "Age", "SimNew", "SimOld", "Rank Δ"))
  cat(paste(rep("-", 55), collapse = ""), "\n")

  for (i in 1:nrow(comparison)) {
    row <- comparison[i, ]
    sim_before_str <- ifelse(is.na(row$sim_before), "  -   ",
                              sprintf("%.3f", row$sim_before))
    cat(sprintf("%-25s %4d  %.3f  %s  %s\n",
                substr(row$player_name, 1, 25),
                row$age,
                row$sim_after,
                sim_before_str,
                row$rank_change_str))
  }

  if (nrow(dropped) > 0) {
    cat(sprintf("\nDropped from top %d:\n", top_n))
    for (i in 1:nrow(dropped)) {
      row <- dropped[i, ]
      cat(sprintf("  - %s (age %d) was rank %d\n",
                  row$player_name, row$age, row$rank))
    }
  }

  invisible(list(before = results_before, after = results_after,
                 comparison = comparison, dropped = dropped))
}

# ============================================================================
# 3. RUN SPOT CHECKS
# ============================================================================

cat("\n")
cat(paste(rep("#", 70), collapse = ""), "\n")
cat("# FEATURE COMPARISON: Groundstroke vs All Features\n")
cat(paste(rep("#", 70), collapse = ""), "\n")

results_list <- list()

for (tc in DEFAULT_TEST_CASES) {
  player <- tc[1]
  age <- as.integer(tc[2])

  result <- compare_feature_sets(
    feature_matrix,
    player, age,
    GROUNDSTROKE_FEATURES,
    ALL_FEATURES,
    top_n = 10,
    label_before = "Groundstroke",
    label_after = "All"
  )

  if (!is.null(result)) {
    results_list[[paste(player, age, sep = "_")]] <- result
  }
}

# ============================================================================
# 4. SUMMARY STATISTICS
# ============================================================================

cat("\n")
cat(paste(rep("=", 70), collapse = ""), "\n")
cat("SUMMARY\n")
cat(paste(rep("=", 70), collapse = ""), "\n")

total_new <- 0
total_dropped <- 0
total_rank_changes <- 0

for (name in names(results_list)) {
  r <- results_list[[name]]

  # Get new entries (in expanded but not in baseline top N)
  new_entries <- r$comparison %>%
    filter(is.na(rank_before)) %>%
    mutate(player_age = sprintf("%s (%d)", player_name, age)) %>%
    pull(player_age)

  # Get dropped entries
  dropped_entries <- r$dropped %>%
    mutate(player_age = sprintf("%s (%d)", player_name, age)) %>%
    pull(player_age)

  rank_changes <- sum(abs(r$comparison$rank_change), na.rm = TRUE)

  total_new <- total_new + length(new_entries)
  total_dropped <- total_dropped + length(dropped_entries)
  total_rank_changes <- total_rank_changes + rank_changes

  cat(sprintf("\n%s:\n", name))
  cat(sprintf("  Rank movement: %d\n", rank_changes))

  if (length(new_entries) > 0) {
    cat(sprintf("  NEW: %s\n", paste(new_entries, collapse = ", ")))
  } else {
    cat("  NEW: (none)\n")
  }

  if (length(dropped_entries) > 0) {
    cat(sprintf("  OUT: %s\n", paste(dropped_entries, collapse = ", ")))
  } else {
    cat("  OUT: (none)\n")
  }
}

cat(sprintf("\n%s\n", paste(rep("-", 70), collapse = "")))
cat(sprintf("TOTAL: %d new entries, %d dropped, %d rank movement\n",
            total_new, total_dropped, total_rank_changes))

cat("\nDone!\n")
