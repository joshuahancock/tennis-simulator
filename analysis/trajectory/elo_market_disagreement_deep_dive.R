# Deep dive: What does the market know that Elo doesn't?
# Focus on matches where Elo picks against strong market favorites

library(tidyverse)

# Load clean backtest results
elo_results <- readRDS("data/processed/backtest_elo_h1_2024_clean.rds")

# Extract match-level predictions
matches <- elo_results$predictions

# Identify disagreements
matches <- matches %>%
  mutate(
    # Market's pick (lower odds = favorite)
    market_fav = ifelse(p1_odds < p2_odds, player1, player2),
    market_fav_odds = pmin(p1_odds, p2_odds),
    market_fav_prob = ifelse(p1_odds < p2_odds, implied_prob_p1, implied_prob_p2),
    market_dog = ifelse(p1_odds > p2_odds, player1, player2),

    # Elo's pick (higher model_prob)
    elo_pick = ifelse(model_prob_p1 > 0.5, player1, player2),
    elo_pick_prob = pmax(model_prob_p1, model_prob_p2),

    # Did they disagree? (Elo picked the underdog)
    disagree = (elo_pick != market_fav),

    # Who actually won?
    actual_winner = winner,

    # Who was right?
    elo_correct = (elo_pick == actual_winner),
    market_correct = (market_fav == actual_winner)
  )

cat("=== OVERALL DISAGREEMENT STATS ===\n\n")
cat(sprintf("Total matches: %d\n", nrow(matches)))
cat(sprintf("Agreements: %d (%.1f%%)\n", sum(!matches$disagree), 100 * mean(!matches$disagree)))
cat(sprintf("Disagreements: %d (%.1f%%)\n", sum(matches$disagree), 100 * mean(matches$disagree)))

# Focus on disagreements
disagree_matches <- matches %>% filter(disagree)

cat(sprintf("\nWhen they disagree (N=%d):\n", nrow(disagree_matches)))
cat(sprintf("  Elo correct: %.1f%%\n", 100 * mean(disagree_matches$elo_correct)))
cat(sprintf("  Market correct: %.1f%%\n", 100 * mean(disagree_matches$market_correct)))

cat("\n=== BY MARKET FAVORITE STRENGTH ===\n\n")

# Bucket by market odds
disagree_matches <- disagree_matches %>%
  mutate(
    market_strength = case_when(
      market_fav_odds < 1.20 ~ "Heavy (<1.20)",
      market_fav_odds < 1.40 ~ "Strong (1.20-1.40)",
      market_fav_odds < 1.60 ~ "Moderate (1.40-1.60)",
      TRUE ~ "Slight (1.60+)"
    ),
    market_strength = factor(market_strength, levels = c(
      "Heavy (<1.20)", "Strong (1.20-1.40)", "Moderate (1.40-1.60)", "Slight (1.60+)"
    ))
  )

disagree_matches %>%
  group_by(market_strength) %>%
  summarise(
    n = n(),
    elo_accuracy = sprintf("%.1f%%", 100 * mean(elo_correct)),
    market_accuracy = sprintf("%.1f%%", 100 * mean(market_correct)),
    avg_market_odds = round(mean(market_fav_odds), 2),
    avg_elo_conf = sprintf("%.1f%%", 100 * mean(elo_pick_prob)),
    .groups = "drop"
  ) %>%
  print()

cat("\n=== STRONG MARKET FAVORITES: THE SPECIFIC MATCHES ===\n")
cat("(Where Elo picked against favorites with odds < 1.40)\n\n")

strong_fav <- disagree_matches %>%
  filter(market_fav_odds < 1.40) %>%
  arrange(market_fav_odds) %>%
  select(
    date = match_date, tournament, surface, round,
    market_fav, elo_pick, actual_winner,
    market_odds = market_fav_odds, elo_conf = elo_pick_prob,
    elo_correct
  )

print(strong_fav, n = 50)

cat("\n=== WHO DOES ELO WRONGLY PICK AGAINST? ===\n")
cat("(Market favorites Elo picked against, who then won)\n\n")

# Players Elo wrongly picked against (they were market favorites AND won)
elo_wrong_against <- strong_fav %>%
  filter(!elo_correct) %>%
  count(market_fav, name = "times_elo_wrong") %>%
  arrange(desc(times_elo_wrong))

print(elo_wrong_against, n = 20)

cat("\n=== WHO DOES ELO WRONGLY BACK? ===\n")
cat("(Players Elo backed against strong favorites, who then lost)\n\n")

# Players Elo wrongly backed
elo_wrong_pick <- strong_fav %>%
  filter(!elo_correct) %>%
  count(elo_pick, name = "times_elo_wrong_pick") %>%
  arrange(desc(times_elo_wrong_pick))

print(elo_wrong_pick, n = 20)

cat("\n=== DETAILED CASE STUDIES ===\n\n")

# Get some specific examples
cases <- strong_fav %>%
  filter(!elo_correct) %>%
  head(15)

for (i in 1:nrow(cases)) {
  row <- cases[i, ]
  cat(sprintf("Case %d: %s %s (%s)\n", i, row$tournament, row$round, row$date))
  cat(sprintf("  Market pick: %s @ %.2f odds\n", row$market_fav, row$market_odds))
  cat(sprintf("  Elo pick: %s (%.1f%% confidence)\n", row$elo_pick, 100 * row$elo_conf))
  cat(sprintf("  Actual winner: %s\n", row$actual_winner))
  cat(sprintf("  → Elo was WRONG\n\n"))
}

cat("\n=== PATTERN ANALYSIS: TOURNAMENT CONTEXT ===\n\n")

strong_fav %>%
  filter(!elo_correct) %>%
  count(tournament) %>%
  arrange(desc(n)) %>%
  print(n = 20)

cat("\n=== PATTERN ANALYSIS: ROUND CONTEXT ===\n\n")

strong_fav %>%
  filter(!elo_correct) %>%
  count(round) %>%
  arrange(desc(n)) %>%
  print()

cat("\n=== THE RARE WINS: When Elo was RIGHT against strong favorites ===\n\n")

elo_right <- strong_fav %>%
  filter(elo_correct)

if (nrow(elo_right) > 0) {
  print(elo_right, n = 20)

  cat("\n=== Who were the upsets? ===\n\n")
  elo_right %>%
    count(elo_pick, name = "upset_wins") %>%
    arrange(desc(upset_wins)) %>%
    print(n = 20)
} else {
  cat("No cases where Elo correctly picked against strong favorites.\n")
}

# Save for further analysis
saveRDS(disagree_matches, "data/processed/elo_market_disagreements.rds")
cat("\nSaved disagreement data to data/processed/elo_market_disagreements.rds\n")
