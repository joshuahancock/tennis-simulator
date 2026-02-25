# Mahalanobis Distance Similarity Analysis
# Uses Mahalanobis distance which accounts for feature correlations
# Requires: Run 01_build_features.R first to generate the feature matrix

library(tidyverse)
library(MASS)  # for ginv (generalized inverse)
source("src/utils/utils.R")

# ============================================================================
# 1. LOAD PROCESSED DATA
# ============================================================================

cat("Loading processed feature data...\n")

feature_matrix <- read_csv("data/processed/charting_only_features_normalized.csv",
                           show_col_types = FALSE)

cat(sprintf("  Loaded %s player/age combinations\n", format(nrow(feature_matrix), big.mark = ",")))

# ============================================================================
# 2. COMPUTE COVARIANCE MATRIX
# ============================================================================

cat("\nComputing covariance matrix...\n")

# Get z-score columns
z_cols <- paste0(ALL_FEATURES, "_z")
z_cols <- intersect(z_cols, names(feature_matrix))

cat(sprintf("  Using %d features\n", length(z_cols)))

# Extract feature matrix (numeric only, no NAs)
feature_data <- feature_matrix %>%
  dplyr::select(all_of(z_cols)) %>%
  drop_na()

cat(sprintf("  Complete cases: %d\n", nrow(feature_data)))

# Compute covariance matrix
cov_matrix <- cov(feature_data)

# Check condition number (high = near-singular)
eigenvalues <- eigen(cov_matrix)$values
condition_number <- max(eigenvalues) / min(eigenvalues)
cat(sprintf("  Covariance matrix condition number: %.1f\n", condition_number))

# Use pseudo-inverse for numerical stability
cov_inv <- ginv(cov_matrix)

cat("  Computed inverse covariance matrix\n")

# ============================================================================
# 3. MAHALANOBIS DISTANCE FUNCTION
# ============================================================================

#' Compute Mahalanobis distance between two vectors
#' @param v1 First vector (z-scored features)
#' @param v2 Second vector (z-scored features)
#' @param cov_inv Inverse covariance matrix
#' @return Mahalanobis distance
mahalanobis_distance <- function(v1, v2, cov_inv) {
  if (any(is.na(v1)) || any(is.na(v2))) return(NA_real_)
  diff <- v1 - v2
  sqrt(as.numeric(t(diff) %*% cov_inv %*% diff))
}

#' Convert Mahalanobis distance to similarity (0 to 1 scale)
#' Uses same transformation as Euclidean: 1 / (1 + dist)
mahalanobis_to_similarity <- function(dist) {
  1 / (1 + dist)
}

#' Find similar players using Mahalanobis distance
find_similar_mahalanobis <- function(data, player_name_query, age_query,
                                      z_cols, cov_inv, top_n = 10,
                                      exclude_same_player = TRUE) {

  query_row <- data %>%
    filter(player_name == player_name_query, age == age_query)

  if (nrow(query_row) == 0) {
    warning(sprintf("Player '%s' at age %d not found", player_name_query, age_query))
    return(NULL)
  }

  query_vec <- as.numeric(query_row[1, z_cols])

  if (any(is.na(query_vec))) {
    warning("Query player has NA features")
    return(NULL)
  }

  # Compute distances for all players
  distances <- data %>%
    rowwise() %>%
    mutate(
      mahal_dist = mahalanobis_distance(query_vec, c_across(all_of(z_cols)), cov_inv),
      similarity = mahalanobis_to_similarity(mahal_dist)
    ) %>%
    ungroup()

  if (exclude_same_player) {
    distances <- distances %>%
      filter(player_name != player_name_query)
  }

  distances %>%
    filter(!is.na(similarity)) %>%
    arrange(desc(similarity)) %>%
    mutate(rank = row_number()) %>%
    head(top_n)
}

# ============================================================================
# 4. RUN SIMILARITY TESTS
# ============================================================================

cat("\n", paste(rep("=", 60), collapse = ""), "\n", sep = "")
cat("PLAYER SIMILARITY - MAHALANOBIS DISTANCE\n")
cat(paste(rep("=", 60), collapse = ""), "\n", sep = "")

for (tc in DEFAULT_TEST_CASES) {
  player <- tc[1]
  age <- as.integer(tc[2])

  cat(sprintf("\n>>> Similar players to %s at age %d:\n", player, age))

  result <- find_similar_mahalanobis(
    feature_matrix, player, age,
    z_cols, cov_inv, top_n = 10
  )

  if (!is.null(result) && nrow(result) > 0) {
    print(
      result %>%
        dplyr::select(player_name, age, similarity, mahal_dist, charting_matches,
               serve_pct, return_pct, net_approach_rate) %>%
        mutate(across(where(is.numeric), ~round(., 3)))
    )
  }
}

# ============================================================================
# 5. COMPARE WITH COSINE SIMILARITY
# ============================================================================

cat("\n", paste(rep("=", 60), collapse = ""), "\n", sep = "")
cat("COMPARISON: MAHALANOBIS vs COSINE\n")
cat(paste(rep("=", 60), collapse = ""), "\n", sep = "")

compare_methods <- function(data, player_name, player_age, z_cols, cov_inv, top_n = 10) {

  cat(sprintf("\n>>> %s at age %d:\n", player_name, player_age))

  # Get Mahalanobis results
  mahal_result <- find_similar_mahalanobis(
    data, player_name, player_age, z_cols, cov_inv, top_n
  ) %>%
    dplyr::select(player_name, age, mahal_sim = similarity) %>%
    mutate(mahal_rank = row_number())

  # Get cosine results
  cosine_result <- find_similar_players(
    data, player_name, player_age,
    ALL_FEATURES, similarity_fn = cosine_similarity, top_n = top_n
  ) %>%
    dplyr::select(player_name, age, cosine_sim = similarity) %>%
    mutate(cosine_rank = row_number())

  # Combine
  comparison <- mahal_result %>%
    full_join(cosine_result, by = c("player_name", "age")) %>%
    arrange(mahal_rank) %>%
    mutate(
      rank_diff = cosine_rank - mahal_rank,
      rank_diff_str = case_when(
        is.na(cosine_rank) ~ "(not in cosine top N)",
        is.na(mahal_rank) ~ "(not in mahal top N)",
        rank_diff > 0 ~ sprintf("+%d", rank_diff),
        rank_diff < 0 ~ sprintf("%d", rank_diff),
        TRUE ~ "="
      )
    )

  cat(sprintf("%-25s %4s  %6s %4s  %6s %4s  %s\n",
              "Player", "Age", "Mahal", "Rank", "Cosine", "Rank", "Diff"))
  cat(paste(rep("-", 70), collapse = ""), "\n")

  for (i in 1:min(top_n, nrow(comparison))) {
    row <- comparison[i, ]
    mahal_str <- ifelse(is.na(row$mahal_sim), "  -  ", sprintf("%.3f", row$mahal_sim))
    cosine_str <- ifelse(is.na(row$cosine_sim), "  -  ", sprintf("%.3f", row$cosine_sim))
    mahal_rank_str <- ifelse(is.na(row$mahal_rank), " - ", sprintf("%3d", row$mahal_rank))
    cosine_rank_str <- ifelse(is.na(row$cosine_rank), " - ", sprintf("%3d", row$cosine_rank))

    cat(sprintf("%-25s %4d  %s %s  %s %s  %s\n",
                substr(row$player_name, 1, 25),
                row$age,
                mahal_str, mahal_rank_str,
                cosine_str, cosine_rank_str,
                row$rank_diff_str))
  }

  invisible(comparison)
}

comparisons <- list()
for (tc in DEFAULT_TEST_CASES) {
  player <- tc[1]
  age <- as.integer(tc[2])
  comparisons[[paste(player, age, sep = "_")]] <- compare_methods(
    feature_matrix, player, age, z_cols, cov_inv, top_n = 10
  )
}

# ============================================================================
# 6. ANALYZE FEATURE CORRELATIONS
# ============================================================================

cat("\n", paste(rep("=", 60), collapse = ""), "\n", sep = "")
cat("TOP FEATURE CORRELATIONS\n")
cat("(These are de-emphasized by Mahalanobis vs Euclidean/Cosine)\n")
cat(paste(rep("=", 60), collapse = ""), "\n", sep = "")

# Get correlation matrix
cor_matrix <- cor(feature_data)

# Extract upper triangle (excluding diagonal)
cor_pairs <- data.frame()
for (i in 1:(ncol(cor_matrix) - 1)) {
  for (j in (i + 1):ncol(cor_matrix)) {
    cor_pairs <- rbind(cor_pairs, data.frame(
      feature1 = colnames(cor_matrix)[i],
      feature2 = colnames(cor_matrix)[j],
      correlation = cor_matrix[i, j]
    ))
  }
}

# Show top positive correlations
cat("\nHighest positive correlations:\n")
top_pos <- cor_pairs %>%
  arrange(desc(correlation)) %>%
  head(15) %>%
  mutate(
    feature1 = gsub("_z$", "", feature1),
    feature2 = gsub("_z$", "", feature2)
  )
print(top_pos, row.names = FALSE)

# Show top negative correlations
cat("\nHighest negative correlations:\n")
top_neg <- cor_pairs %>%
  arrange(correlation) %>%
  head(15) %>%
  mutate(
    feature1 = gsub("_z$", "", feature1),
    feature2 = gsub("_z$", "", feature2)
  )
print(top_neg, row.names = FALSE)

cat("\nDone!\n")
