# Find Subsets Where Elo Has Edge Over Market
# Goal: Identify match characteristics where Elo outperforms market baseline
# Before optimizing globally, find local optima

library(tidyverse)

# Load clean Elo backtest results
elo_results <- readRDS("data/processed/backtest_elo_h1_2024_clean.rds")
preds <- elo_results$predictions

cat("=== FINDING ELO EDGE SUBSETS ===\n")
cat("Goal: Where does Elo add value over simply picking the market favorite?\n\n")

# Add derived columns for analysis
preds <- preds %>%
  mutate(
    # Market favorite info
    market_fav = ifelse(p1_odds < p2_odds, player1, player2),
    market_fav_odds = pmin(p1_odds, p2_odds),
    market_dog_odds = pmax(p1_odds, p2_odds),
    market_fav_prob = 1 / market_fav_odds,  # Implied prob (no vig adjustment)

    # Elo pick info
    elo_pick = ifelse(model_prob_p1 > 0.5, player1, player2),
    elo_conf = pmax(model_prob_p1, model_prob_p2),
    elo_fav_prob = ifelse(market_fav == player1, model_prob_p1, model_prob_p2),

    # Agreement
    agree = (elo_pick == market_fav),

    # Outcomes
    market_fav_won = (market_fav == winner),
    elo_correct = (elo_pick == winner),

    # Edge metrics
    elo_edge_on_fav = elo_fav_prob - market_fav_prob,  # Positive = Elo more bullish on favorite

    # Confidence buckets
    elo_conf_bucket = cut(elo_conf, breaks = c(0.5, 0.55, 0.60, 0.65, 0.70, 0.80, 1.0),
                          labels = c("50-55%", "55-60%", "60-65%", "65-70%", "70-80%", "80%+"))
  )

# Baseline: Market favorite accuracy
market_baseline <- mean(preds$market_fav_won)
cat(sprintf("Market baseline (picking favorite): %.1f%%\n", 100 * market_baseline))
cat(sprintf("Elo overall accuracy: %.1f%%\n\n", 100 * mean(preds$elo_correct)))

cat("=== SUBSET 1: BY AGREEMENT ===\n\n")

preds %>%
  group_by(agree) %>%
  summarise(
    n = n(),
    elo_accuracy = mean(elo_correct),
    market_accuracy = mean(market_fav_won),
    elo_edge = mean(elo_correct) - mean(market_fav_won),
    .groups = "drop"
  ) %>%
  mutate(
    elo_accuracy = sprintf("%.1f%%", 100 * elo_accuracy),
    market_accuracy = sprintf("%.1f%%", 100 * market_accuracy),
    elo_edge = sprintf("%+.1fpp", 100 * as.numeric(str_extract(elo_edge, "[\\d.-]+")))
  ) %>%
  print()

cat("\n=== SUBSET 2: BY ELO CONFIDENCE (when agreeing with market) ===\n\n")

preds %>%
  filter(agree) %>%
  group_by(elo_conf_bucket) %>%
  summarise(
    n = n(),
    elo_accuracy = mean(elo_correct),
    market_accuracy = mean(market_fav_won),
    avg_elo_conf = mean(elo_conf),
    avg_market_prob = mean(market_fav_prob),
    .groups = "drop"
  ) %>%
  mutate(
    elo_edge = elo_accuracy - market_accuracy,
    elo_accuracy = sprintf("%.1f%%", 100 * elo_accuracy),
    market_accuracy = sprintf("%.1f%%", 100 * market_accuracy),
    elo_edge_pp = sprintf("%+.1fpp", 100 * elo_edge)
  ) %>%
  select(elo_conf_bucket, n, elo_accuracy, market_accuracy, elo_edge_pp, avg_elo_conf) %>%
  print()

cat("\n=== SUBSET 3: BY ELO-MARKET PROBABILITY DIFFERENCE (agreement cases) ===\n")
cat("Positive = Elo more confident in favorite than market\n\n")

preds %>%
  filter(agree) %>%
  mutate(
    edge_bucket = cut(elo_edge_on_fav,
                      breaks = c(-1, -0.10, -0.05, 0, 0.05, 0.10, 0.15, 1),
                      labels = c("<-10pp", "-10 to -5pp", "-5 to 0pp",
                                "0 to 5pp", "5 to 10pp", "10 to 15pp", ">15pp"))
  ) %>%
  group_by(edge_bucket) %>%
  summarise(
    n = n(),
    elo_accuracy = mean(elo_correct),
    market_accuracy = mean(market_fav_won),
    .groups = "drop"
  ) %>%
  mutate(
    elo_edge = elo_accuracy - market_accuracy
  ) %>%
  print()

cat("\n=== SUBSET 4: BY MARKET ODDS RANGE (agreement cases) ===\n\n")

preds %>%
  filter(agree) %>%
  mutate(
    odds_bucket = cut(market_fav_odds,
                      breaks = c(1.0, 1.20, 1.40, 1.60, 1.80, 2.0, 3.0),
                      labels = c("1.0-1.2", "1.2-1.4", "1.4-1.6", "1.6-1.8", "1.8-2.0", "2.0+"))
  ) %>%
  group_by(odds_bucket) %>%
  summarise(
    n = n(),
    elo_accuracy = mean(elo_correct),
    market_accuracy = mean(market_fav_won),
    elo_edge = mean(elo_correct) - mean(market_fav_won),
    .groups = "drop"
  ) %>%
  print()

cat("\n=== SUBSET 5: BY SURFACE (agreement cases) ===\n\n")

preds %>%
  filter(agree) %>%
  group_by(surface) %>%
  summarise(
    n = n(),
    elo_accuracy = mean(elo_correct),
    market_accuracy = mean(market_fav_won),
    elo_edge = mean(elo_correct) - mean(market_fav_won),
    .groups = "drop"
  ) %>%
  print()

cat("\n=== SUBSET 6: COMBINED FILTER - Potential Edge Zone ===\n")
cat("Looking for: Elo agrees with market, high Elo confidence, moderate odds\n\n")

# Test various combinations
combinations <- list(
  list(name = "High conf (>65%) + Moderate odds (1.4-1.8)",
       filter = quote(agree & elo_conf > 0.65 & market_fav_odds >= 1.4 & market_fav_odds < 1.8)),
  list(name = "High conf (>70%) + Any odds",
       filter = quote(agree & elo_conf > 0.70)),
  list(name = "Elo more bullish (+5pp) + Moderate odds",
       filter = quote(agree & elo_edge_on_fav > 0.05 & market_fav_odds >= 1.3 & market_fav_odds < 1.8)),
  list(name = "Very high conf (>75%) + Not heavy favorite",
       filter = quote(agree & elo_conf > 0.75 & market_fav_odds >= 1.3)),
  list(name = "Moderate conf (60-70%) + Close odds (1.6-2.0)",
       filter = quote(agree & elo_conf >= 0.60 & elo_conf <= 0.70 & market_fav_odds >= 1.6 & market_fav_odds <= 2.0))
)

for (combo in combinations) {
  subset_data <- preds %>% filter(eval(combo$filter))
  if (nrow(subset_data) > 20) {
    elo_acc <- mean(subset_data$elo_correct)
    mkt_acc <- mean(subset_data$market_fav_won)
    edge <- elo_acc - mkt_acc

    cat(sprintf("%s:\n", combo$name))
    cat(sprintf("  N = %d, Elo: %.1f%%, Market: %.1f%%, Edge: %+.1fpp\n\n",
                nrow(subset_data), 100 * elo_acc, 100 * mkt_acc, 100 * edge))
  }
}

cat("\n=== SUBSET 7: Elo DISAGREES but might be right ===\n")
cat("When Elo picks underdog - are there any conditions where it works?\n\n")

disagree_data <- preds %>% filter(!agree)

disagree_data %>%
  mutate(
    dog_odds = market_dog_odds,
    dog_odds_bucket = cut(dog_odds, breaks = c(1, 2, 2.5, 3, 4, 10),
                          labels = c("2.0-", "2.0-2.5", "2.5-3.0", "3.0-4.0", "4.0+"))
  ) %>%
  group_by(dog_odds_bucket) %>%
  summarise(
    n = n(),
    elo_accuracy = mean(elo_correct),
    avg_dog_odds = mean(dog_odds),
    .groups = "drop"
  ) %>%
  print()

cat("\n=== KEY FINDINGS ===\n\n")

# Find the best subset
best_subset <- preds %>%
  filter(agree & elo_conf > 0.65 & market_fav_odds >= 1.3)

cat(sprintf("Best candidate subset: Agree + Elo conf > 65%% + Odds >= 1.3\n"))
cat(sprintf("  N = %d matches (%.1f%% of total)\n", nrow(best_subset), 100 * nrow(best_subset) / nrow(preds)))
cat(sprintf("  Elo accuracy: %.1f%%\n", 100 * mean(best_subset$elo_correct)))
cat(sprintf("  Market accuracy: %.1f%%\n", 100 * mean(best_subset$market_fav_won)))
cat(sprintf("  Elo edge: %+.1fpp\n", 100 * (mean(best_subset$elo_correct) - mean(best_subset$market_fav_won))))

# Save for further analysis
saveRDS(preds, "data/processed/elo_predictions_with_subsets.rds")
cat("\nSaved enriched predictions to data/processed/elo_predictions_with_subsets.rds\n")
