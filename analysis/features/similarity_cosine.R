# Cosine Similarity Analysis
# Loads normalized features and finds similar players using cosine similarity
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
cat(sprintf("  Unique players: %s\n", format(n_distinct(feature_matrix$player_name), big.mark = ",")))

# ============================================================================
# 2. RUN SIMILARITY TESTS
# ============================================================================

# Run default test cases with all features
cat("\n")
results <- run_test_cases(
  data = feature_matrix,
  feature_cols = ALL_FEATURES,
  test_cases = DEFAULT_TEST_CASES,
  similarity_fn = cosine_similarity,
  top_n = 10
)

# ============================================================================
# 3. CUSTOM QUERIES (examples)
# ============================================================================

cat("\n", paste(rep("=", 60), collapse = ""), "\n", sep = "")
cat("CUSTOM SIMILARITY QUERIES\n")
cat(paste(rep("=", 60), collapse = ""), "\n", sep = "")

# Example: Find players similar to young Djokovic
cat("\n>>> Similar players to Novak Djokovic at age 21:\n")
result <- find_similar_players(
  feature_matrix,
  "Novak Djokovic", 21,
  ALL_FEATURES,
  similarity_fn = cosine_similarity,
  top_n = 10
)
if (!is.null(result) && nrow(result) > 0) {
  print(
    result %>%
      select(player_name, age, similarity, charting_matches,
             serve_pct, return_pct, net_approach_rate) %>%
      mutate(across(where(is.numeric), ~round(., 3)))
  )
}

# Example: Find players similar to Alcaraz using only baseline features
cat("\n>>> Similar players to Carlos Alcaraz (21) using BASELINE features only:\n")
result_baseline <- find_similar_players(
  feature_matrix,
  "Carlos Alcaraz", 21,
  BASELINE_FEATURES,
  similarity_fn = cosine_similarity,
  top_n = 10
)
if (!is.null(result_baseline) && nrow(result_baseline) > 0) {
  print(
    result_baseline %>%
      select(player_name, age, similarity, charting_matches,
             serve_pct, return_pct, net_approach_rate) %>%
      mutate(across(where(is.numeric), ~round(., 3)))
  )
}

# Example: Using Euclidean distance instead
cat("\n>>> Similar players to Roger Federer (28) using Euclidean distance:\n")
result_euclidean <- find_similar_players(
  feature_matrix,
  "Roger Federer", 28,
  ALL_FEATURES,
  similarity_fn = function(v1, v2) euclidean_to_similarity(euclidean_distance(v1, v2)),
  top_n = 10
)
if (!is.null(result_euclidean) && nrow(result_euclidean) > 0) {
  print(
    result_euclidean %>%
      select(player_name, age, similarity, charting_matches,
             serve_pct, return_pct, net_approach_rate) %>%
      mutate(across(where(is.numeric), ~round(., 3)))
  )
}

cat("\nDone!\n")
