# Find Subsets Where Elo Has BETTING Edge Over Market
# Different question: Not "who wins more" but "whose probabilities are better calibrated"
# and "where does betting on Elo's probability vs market odds yield positive returns"

library(tidyverse)

# Load clean Elo backtest results
elo_results <- readRDS("data/processed/backtest_elo_h1_2024_clean.rds")
preds <- elo_results$predictions

cat("=== FINDING BETTING EDGE SUBSETS ===\n")
cat("Goal: Where do Elo probabilities beat market implied probabilities?\n\n")

# Add betting-relevant columns
preds <- preds %>%
  mutate(
    # Market info
    market_fav = ifelse(p1_odds < p2_odds, player1, player2),
    market_fav_odds = pmin(p1_odds, p2_odds),
    market_dog_odds = pmax(p1_odds, p2_odds),

    # Implied probabilities (from odds)
    implied_p1 = 1 / p1_odds,
    implied_p2 = 1 / p2_odds,
    vig = implied_p1 + implied_p2 - 1,
    # Vig-adjusted implied probs
    market_prob_p1 = implied_p1 / (implied_p1 + implied_p2),
    market_prob_p2 = implied_p2 / (implied_p1 + implied_p2),

    # Elo edge = Elo prob - market prob (for player 1)
    elo_edge_p1 = model_prob_p1 - market_prob_p1,
    elo_edge_p2 = model_prob_p2 - market_prob_p2,

    # Which player does Elo favor more than market?
    elo_favors_p1_more = elo_edge_p1 > 0,

    # Actual outcome
    p1_won = (player1 == winner),

    # Elo's prediction direction
    elo_pick = ifelse(model_prob_p1 > 0.5, player1, player2),
    agree_with_market = (elo_pick == market_fav),

    # Elo's maximum edge on either player
    max_elo_edge = pmax(elo_edge_p1, elo_edge_p2),
    edge_player = ifelse(elo_edge_p1 > elo_edge_p2, player1, player2),
    edge_odds = ifelse(elo_edge_p1 > elo_edge_p2, p1_odds, p2_odds),
    edge_won = (edge_player == winner)
  )

cat("=== STRATEGY 1: Bet on Elo's Edge ===\n")
cat("Bet on whichever player Elo rates higher than market\n\n")

# Group by edge magnitude
preds %>%
  mutate(
    edge_bucket = cut(max_elo_edge,
                      breaks = c(0, 0.03, 0.05, 0.10, 0.15, 0.20, 1),
                      labels = c("0-3%", "3-5%", "5-10%", "10-15%", "15-20%", "20%+"))
  ) %>%
  group_by(edge_bucket) %>%
  summarise(
    n = n(),
    win_rate = mean(edge_won),
    avg_odds = mean(edge_odds),
    expected_roi = mean(edge_won * edge_odds - 1),
    .groups = "drop"
  ) %>%
  mutate(
    win_rate = sprintf("%.1f%%", 100 * win_rate),
    expected_roi = sprintf("%+.1f%%", 100 * expected_roi)
  ) %>%
  print()

cat("\n=== STRATEGY 2: Bet on Favorite When Elo Agrees + High Confidence ===\n\n")

# When Elo agrees with market AND has higher confidence than market
agree_high_conf <- preds %>%
  filter(agree_with_market) %>%
  mutate(
    # Elo's confidence vs market's confidence
    elo_conf = pmax(model_prob_p1, model_prob_p2),
    market_conf = pmax(market_prob_p1, market_prob_p2),
    conf_diff = elo_conf - market_conf,

    # Betting on the favorite
    bet_won = (market_fav == winner),
    bet_odds = market_fav_odds
  )

agree_high_conf %>%
  mutate(
    conf_diff_bucket = cut(conf_diff,
                           breaks = c(-1, -0.05, 0, 0.05, 0.10, 0.15, 1),
                           labels = c("<-5pp", "-5 to 0pp", "0 to 5pp", "5-10pp", "10-15pp", "15pp+"))
  ) %>%
  group_by(conf_diff_bucket) %>%
  summarise(
    n = n(),
    win_rate = mean(bet_won),
    avg_odds = mean(bet_odds),
    roi = mean(bet_won * bet_odds - 1),
    .groups = "drop"
  ) %>%
  print()

cat("\n=== STRATEGY 3: Bet Underdog When Elo Disagrees AND Underdog Odds are Good ===\n\n")

disagree <- preds %>%
  filter(!agree_with_market) %>%
  mutate(
    elo_dog = elo_pick,  # Elo picked the market underdog
    dog_odds = market_dog_odds,
    dog_won = (elo_dog == winner),
    elo_dog_prob = ifelse(elo_dog == player1, model_prob_p1, model_prob_p2)
  )

disagree %>%
  mutate(
    odds_bucket = cut(dog_odds,
                      breaks = c(1, 2, 2.5, 3, 4, 10),
                      labels = c("<2.0", "2.0-2.5", "2.5-3.0", "3.0-4.0", "4.0+"))
  ) %>%
  group_by(odds_bucket) %>%
  summarise(
    n = n(),
    win_rate = mean(dog_won),
    avg_odds = mean(dog_odds),
    roi = mean(dog_won * dog_odds - 1),
    .groups = "drop"
  ) %>%
  print()

cat("\n=== CALIBRATION ANALYSIS: Elo vs Market ===\n")
cat("Are Elo's probabilities better calibrated than market's?\n\n")

# Calibration by probability bucket
preds %>%
  mutate(
    elo_bucket = cut(model_prob_p1, breaks = seq(0, 1, 0.1)),
    market_bucket = cut(market_prob_p1, breaks = seq(0, 1, 0.1))
  ) %>%
  group_by(elo_bucket) %>%
  summarise(
    n = n(),
    predicted = mean(model_prob_p1),
    actual = mean(p1_won),
    calibration_error = abs(predicted - actual),
    .groups = "drop"
  ) %>%
  print()

cat("\n=== CALIBRATION COMPARISON ===\n\n")

# Overall calibration error
elo_cal_error <- preds %>%
  mutate(
    bucket = cut(model_prob_p1, breaks = seq(0, 1, 0.1))
  ) %>%
  group_by(bucket) %>%
  summarise(
    predicted = mean(model_prob_p1),
    actual = mean(p1_won),
    n = n(),
    .groups = "drop"
  ) %>%
  summarise(
    mae = sum(abs(predicted - actual) * n) / sum(n)
  ) %>%
  pull(mae)

market_cal_error <- preds %>%
  mutate(
    bucket = cut(market_prob_p1, breaks = seq(0, 1, 0.1))
  ) %>%
  group_by(bucket) %>%
  summarise(
    predicted = mean(market_prob_p1),
    actual = mean(p1_won),
    n = n(),
    .groups = "drop"
  ) %>%
  summarise(
    mae = sum(abs(predicted - actual) * n) / sum(n)
  ) %>%
  pull(mae)

cat(sprintf("Elo mean calibration error: %.3f\n", elo_cal_error))
cat(sprintf("Market mean calibration error: %.3f\n", market_cal_error))

cat("\n=== SEARCHING FOR POSITIVE ROI SUBSETS ===\n\n")

# Try many combinations to find any positive ROI
test_subsets <- function(data, name, filter_expr) {
  subset <- data %>% filter(eval(filter_expr))
  if (nrow(subset) < 30) return(NULL)

  roi <- mean(subset$edge_won * subset$edge_odds - 1)
  win_rate <- mean(subset$edge_won)
  avg_odds <- mean(subset$edge_odds)

  if (roi > 0) {
    cat(sprintf("*** POSITIVE ROI: %s ***\n", name))
    cat(sprintf("    N=%d, Win rate=%.1f%%, Avg odds=%.2f, ROI=%+.1f%%\n\n",
                nrow(subset), 100 * win_rate, avg_odds, 100 * roi))
  }

  return(tibble(name = name, n = nrow(subset), win_rate = win_rate, avg_odds = avg_odds, roi = roi))
}

subsets_tested <- list()

# Test many filters
subsets_tested[[1]] <- test_subsets(preds, "Edge > 10%, Odds < 2.5",
                                     quote(max_elo_edge > 0.10 & edge_odds < 2.5))
subsets_tested[[2]] <- test_subsets(preds, "Edge > 15%, Any odds",
                                     quote(max_elo_edge > 0.15))
subsets_tested[[3]] <- test_subsets(preds, "Agree + Edge > 5%",
                                     quote(agree_with_market & max_elo_edge > 0.05))
subsets_tested[[4]] <- test_subsets(preds, "Disagree + Odds 2.0-2.5",
                                     quote(!agree_with_market & edge_odds >= 2.0 & edge_odds < 2.5))
subsets_tested[[5]] <- test_subsets(preds, "Clay + Edge > 10%",
                                     quote(surface == "Clay" & max_elo_edge > 0.10))
subsets_tested[[6]] <- test_subsets(preds, "Hard + Agree + Edge > 5%",
                                     quote(surface == "Hard" & agree_with_market & max_elo_edge > 0.05))

# Show all results
all_subsets <- bind_rows(subsets_tested)
cat("\n=== ALL TESTED SUBSETS ===\n\n")
all_subsets %>%
  arrange(desc(roi)) %>%
  mutate(
    win_rate = sprintf("%.1f%%", 100 * win_rate),
    roi = sprintf("%+.1f%%", 100 * roi)
  ) %>%
  print()

cat("\n=== SUMMARY ===\n")
positive_roi <- all_subsets %>% filter(roi > 0)
if (nrow(positive_roi) > 0) {
  cat(sprintf("Found %d subset(s) with positive ROI\n", nrow(positive_roi)))
} else {
  cat("No subsets found with positive ROI in H1 2024 data\n")
  cat("This suggests Elo probabilities are not better calibrated than market\n")
}
