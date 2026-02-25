# Test script for Elo rating system
# Run from project root: Rscript tests/test_elo.R

cat("=== Testing Elo Rating System ===\n\n")

# Source the Elo module
source("src/models/elo/elo_ratings.R")

# Run unit tests
cat("1. Running unit tests...\n")
test_elo()

# Load some real match data and calculate Elo
cat("\n2. Loading ATP match data...\n")
source("src/data/player_stats.R")
matches <- load_atp_matches(year_from = 2020, year_to = 2024)

cat("\n3. Calculating Elo ratings...\n")
elo_db <- calculate_all_elo(matches, by_surface = TRUE, verbose = TRUE)

# Print summary
print_elo_summary(elo_db)

# Test prediction
cat("\n4. Testing match prediction...\n")
test_matchup <- predict_match_elo("Novak Djokovic", "Carlos Alcaraz", "Hard", elo_db)
cat(sprintf("  Djokovic vs Alcaraz (Hard):\n"))
cat(sprintf("    Djokovic Elo: %.0f (source: %s)\n", test_matchup$p1_elo, test_matchup$p1_info$source))
cat(sprintf("    Alcaraz Elo: %.0f (source: %s)\n", test_matchup$p2_elo, test_matchup$p2_info$source))
cat(sprintf("    Djokovic win prob: %.1f%%\n", test_matchup$p1_win_prob * 100))

# Test surface-specific ratings
cat("\n5. Comparing surface-specific Elo for Nadal...\n")
nadal_hard <- get_player_elo("Rafael Nadal", "Hard", elo_db)
nadal_clay <- get_player_elo("Rafael Nadal", "Clay", elo_db)
nadal_grass <- get_player_elo("Rafael Nadal", "Grass", elo_db)

cat(sprintf("  Nadal Hard Elo: %.0f (%d matches, source: %s)\n",
            nadal_hard$elo, nadal_hard$surface_matches, nadal_hard$source))
cat(sprintf("  Nadal Clay Elo: %.0f (%d matches, source: %s)\n",
            nadal_clay$elo, nadal_clay$surface_matches, nadal_clay$source))
cat(sprintf("  Nadal Grass Elo: %.0f (%d matches, source: %s)\n",
            nadal_grass$elo, nadal_grass$surface_matches, nadal_grass$source))

cat("\n=== Elo Test Complete ===\n")
