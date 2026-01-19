# Spot Checks for Player Similarity - CHARTING DATA ONLY
# Run this after modifying features in 01_player_similarity.R
# Sources the main script and runs sanity check comparisons

# Source the main similarity script (loads data, builds functions)
cat("Running main similarity script...\n\n")
source("r_analysis/01_player_similarity.R")

cat("\n")
cat(rep("=", 70), "\n", sep = "")
cat("SPOT CHECKS - PLAYER SIMILARITY SANITY TESTS\n")
cat(rep("=", 70), "\n", sep = "")

# Helper function to display comparison with context
show_comparison <- function(player, player_age, n = 8) {
  cat("\n", rep("-", 70), "\n", sep = "")
  cat(sprintf(">>> %s at age %d <<<\n", player, player_age))

  # Get target player's stats
  target <- feature_matrix_norm %>%
    filter(player_name == player, age == player_age)

  if (nrow(target) > 0) {
    cat(sprintf("    Serve: %.1f%% | Return: %.1f%% | Rank: %.1f",
                target$serve_pct * 100, target$return_pct * 100, target$avg_ranking))
    if (!is.na(target$winner_pct)) {
      cat(sprintf(" | Winner%%: %.1f%% | NetAppr: %.1f%%",
                  target$winner_pct * 100, target$net_approach_rate * 100))
    }
    cat("\n")
  }

  cat(rep("-", 70), "\n", sep = "")

  result <- find_similar_players(player, player_age, top_n = n)
  if (!is.null(result) && nrow(result) > 0) {
    print(result %>% mutate(across(where(is.numeric), ~round(., 3))))
  } else {
    cat("No results found\n")
  }
}

# ============================================================================
# SPOT CHECK CATEGORIES
# ============================================================================

cat("\n\n### MODERN ERA - BIG 3 + NEXT GEN ###\n")
show_comparison("Jannik Sinner", 23)
show_comparison("Carlos Alcaraz", 21)
show_comparison("Novak Djokovic", 28)
show_comparison("Rafael Nadal", 22)
show_comparison("Roger Federer", 28)

cat("\n\n### AGING LEGENDS - LATE CAREER ###\n")
show_comparison("Roger Federer", 36)
show_comparison("Rafael Nadal", 35)
show_comparison("Novak Djokovic", 35)

cat("\n\n### SERVE-AND-VOLLEY ERA ###\n")
show_comparison("Pete Sampras", 26)
show_comparison("Stefan Edberg", 26)
show_comparison("Boris Becker", 24)

cat("\n\n### BASELINE GRINDERS ###\n")
show_comparison("Andre Agassi", 29)
show_comparison("David Ferrer", 30)
show_comparison("Andy Murray", 29)

cat("\n\n### YOUNG BREAKOUTS ###\n")
show_comparison("Rafael Nadal", 19)
show_comparison("Boris Becker", 18)
show_comparison("Carlos Alcaraz", 19)

cat("\n\n", rep("=", 70), "\n", sep = "")
cat("SPOT CHECKS COMPLETE\n")
cat(rep("=", 70), "\n", sep = "")

# Summary stats
cat("\nSummary:\n")
cat(sprintf("  Total player/age combinations: %d\n", nrow(feature_matrix_norm)))
cat(sprintf("  With charting features: %d\n", sum(!is.na(feature_matrix_norm$winner_pct))))
cat(sprintf("  Features used: %d\n", length(available_features)))
