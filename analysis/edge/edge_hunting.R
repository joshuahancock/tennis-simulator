# Edge Hunting: Find Structural Patterns Where Elo Has Edge
# Don't compare to lines first - find where Elo is ACCURATE, then check if market misprices

library(tidyverse)

# Load data
elo_results <- readRDS("data/processed/backtest_elo_h1_2024_clean.rds")
preds <- elo_results$predictions
hist_matches <- readRDS("data/processed/atp_matches_aligned.rds")

cat("=== EDGE HUNTING: STRUCTURAL PATTERNS ===\n")
cat("Looking for subsets where model accuracy is HIGH, not just where it beats market\n\n")

# Enrich predictions with more features
preds <- preds %>%
  mutate(
    # Basic info
    month = month(match_date),
    week = week(match_date),
    day_of_week = wday(match_date, label = TRUE),

    # Tournament info from name patterns
    is_grand_slam = str_detect(tournament, "Open|Roland Garros|Wimbledon"),
    is_masters = str_detect(tournament, "Masters|Monte Carlo|Madrid|Rome|Paris|Miami|Indian Wells|Canada|Cincinnati|Shanghai"),
    tourney_level = case_when(
      is_grand_slam ~ "Grand Slam",
      is_masters ~ "Masters",
      TRUE ~ "Other"
    ),

    # Round info
    round_clean = case_when(
      str_detect(round, "1st|R32|R64|R128") ~ "Early",
      str_detect(round, "2nd|3rd|R16") ~ "Middle",
      str_detect(round, "Quarter|Semi|Final") ~ "Late",
      TRUE ~ "Other"
    ),

    # Elo confidence buckets
    elo_conf = pmax(model_prob_p1, model_prob_p2),
    elo_conf_bucket = cut(elo_conf, breaks = c(0.5, 0.55, 0.60, 0.65, 0.70, 0.80, 1.0)),

    # Elo pick and outcome
    elo_pick = ifelse(model_prob_p1 > 0.5, player1, player2),
    elo_correct = (elo_pick == winner),

    # Market info
    market_fav = ifelse(p1_odds < p2_odds, player1, player2),
    market_fav_odds = pmin(p1_odds, p2_odds),
    market_dog_odds = pmax(p1_odds, p2_odds),

    # Odds spread (how lopsided is market)
    odds_ratio = market_dog_odds / market_fav_odds,
    market_confidence = case_when(
      odds_ratio > 3 ~ "Very lopsided",
      odds_ratio > 2 ~ "Lopsided",
      odds_ratio > 1.5 ~ "Moderate",
      TRUE ~ "Close"
    ),

    # Does Elo agree with market
    agree = (elo_pick == market_fav),

    # Betting outcomes
    bet_odds = ifelse(elo_pick == player1, p1_odds, p2_odds),
    bet_won = elo_correct,
    profit = ifelse(bet_won, bet_odds - 1, -1)
  )

# Function to analyze a subset
analyze_subset <- function(data, name) {
  if (nrow(data) < 30) return(NULL)

  tibble(
    subset = name,
    n = nrow(data),
    elo_accuracy = mean(data$elo_correct),
    avg_odds_when_bet = mean(data$bet_odds),
    roi = mean(data$profit),
    win_rate_needed = 1 / mean(data$bet_odds),
    edge = mean(data$elo_correct) - 1/mean(data$bet_odds)
  )
}

results <- list()
i <- 1

cat("=== DIMENSION 1: SURFACE ===\n\n")
for (surf in unique(preds$surface)) {
  subset <- preds %>% filter(surface == surf)
  results[[i]] <- analyze_subset(subset, paste("Surface:", surf))
  i <- i + 1
}

cat("=== DIMENSION 2: TOURNAMENT LEVEL ===\n\n")
for (level in unique(preds$tourney_level)) {
  subset <- preds %>% filter(tourney_level == level)
  results[[i]] <- analyze_subset(subset, paste("Level:", level))
  i <- i + 1
}

cat("=== DIMENSION 3: ROUND STAGE ===\n\n")
for (stage in c("Early", "Middle", "Late")) {
  subset <- preds %>% filter(round_clean == stage)
  results[[i]] <- analyze_subset(subset, paste("Round:", stage))
  i <- i + 1
}

cat("=== DIMENSION 4: MONTH ===\n\n")
for (m in sort(unique(preds$month))) {
  subset <- preds %>% filter(month == m)
  results[[i]] <- analyze_subset(subset, paste("Month:", month.abb[m]))
  i <- i + 1
}

cat("=== DIMENSION 5: MARKET CONFIDENCE ===\n\n")
for (conf in c("Very lopsided", "Lopsided", "Moderate", "Close")) {
  subset <- preds %>% filter(market_confidence == conf)
  results[[i]] <- analyze_subset(subset, paste("Market:", conf))
  i <- i + 1
}

cat("=== DIMENSION 6: ELO CONFIDENCE ===\n\n")
for (bucket in levels(preds$elo_conf_bucket)) {
  subset <- preds %>% filter(elo_conf_bucket == bucket)
  if (!is.null(bucket)) {
    results[[i]] <- analyze_subset(subset, paste("Elo conf:", bucket))
    i <- i + 1
  }
}

cat("=== DIMENSION 7: AGREEMENT STATUS ===\n\n")
results[[i]] <- analyze_subset(preds %>% filter(agree), "Elo agrees with market")
i <- i + 1
results[[i]] <- analyze_subset(preds %>% filter(!agree), "Elo disagrees with market")
i <- i + 1

cat("=== DIMENSION 8: SURFACE + ROUND COMBINATIONS ===\n\n")
for (surf in unique(preds$surface)) {
  for (stage in c("Early", "Middle", "Late")) {
    subset <- preds %>% filter(surface == surf, round_clean == stage)
    results[[i]] <- analyze_subset(subset, paste(surf, stage, "rounds"))
    i <- i + 1
  }
}

cat("=== DIMENSION 9: SURFACE + TOURNAMENT LEVEL ===\n\n")
for (surf in unique(preds$surface)) {
  for (level in unique(preds$tourney_level)) {
    subset <- preds %>% filter(surface == surf, tourney_level == level)
    results[[i]] <- analyze_subset(subset, paste(surf, level))
    i <- i + 1
  }
}

cat("=== DIMENSION 10: ELO CONFIDENCE + AGREEMENT ===\n\n")
for (bucket in levels(preds$elo_conf_bucket)) {
  # When agreeing
  subset <- preds %>% filter(elo_conf_bucket == bucket, agree)
  results[[i]] <- analyze_subset(subset, paste("Agree + Elo", bucket))
  i <- i + 1

  # When disagreeing
  subset <- preds %>% filter(elo_conf_bucket == bucket, !agree)
  results[[i]] <- analyze_subset(subset, paste("Disagree + Elo", bucket))
  i <- i + 1
}

cat("=== DIMENSION 11: CLOSE MATCHES (market near 50/50) ===\n\n")
close_matches <- preds %>% filter(market_fav_odds >= 1.7, market_fav_odds <= 2.1)
results[[i]] <- analyze_subset(close_matches, "Close matches (odds 1.7-2.1)")
i <- i + 1

cat("=== DIMENSION 12: HEAVY FAVORITES ===\n\n")
heavy_fav <- preds %>% filter(market_fav_odds < 1.3)
results[[i]] <- analyze_subset(heavy_fav, "Heavy favorites (<1.3 odds)")
i <- i + 1

cat("=== DIMENSION 13: MODERATE FAVORITES ===\n\n")
mod_fav <- preds %>% filter(market_fav_odds >= 1.3, market_fav_odds < 1.6)
results[[i]] <- analyze_subset(mod_fav, "Moderate favorites (1.3-1.6)")
i <- i + 1

cat("=== DIMENSION 14: SLIGHT FAVORITES ===\n\n")
slight_fav <- preds %>% filter(market_fav_odds >= 1.6, market_fav_odds < 2.0)
results[[i]] <- analyze_subset(slight_fav, "Slight favorites (1.6-2.0)")
i <- i + 1

# Compile results
all_results <- bind_rows(results) %>%
  filter(!is.na(subset)) %>%
  arrange(desc(edge))

cat("\n\n========================================\n")
cat("RESULTS: ALL SUBSETS RANKED BY EDGE\n")
cat("========================================\n\n")

cat("Edge = Elo accuracy - breakeven rate (positive = profitable)\n\n")

all_results %>%
  mutate(
    elo_accuracy = sprintf("%.1f%%", 100 * elo_accuracy),
    win_rate_needed = sprintf("%.1f%%", 100 * win_rate_needed),
    edge = sprintf("%+.1fpp", 100 * edge),
    roi = sprintf("%+.1f%%", 100 * roi)
  ) %>%
  print(n = 50)

cat("\n\n========================================\n")
cat("TOP 10 POSITIVE EDGE SUBSETS\n")
cat("========================================\n\n")

top_positive <- all_results %>%
  filter(edge > 0) %>%
  head(10)

if (nrow(top_positive) > 0) {
  top_positive %>%
    mutate(
      elo_accuracy = sprintf("%.1f%%", 100 * elo_accuracy),
      edge = sprintf("%+.1fpp", 100 * edge),
      roi = sprintf("%+.1f%%", 100 * roi)
    ) %>%
    print()
} else {
  cat("No subsets with positive edge found in basic dimensions.\n")
}

# Save for further analysis
saveRDS(all_results, "data/processed/edge_hunting_results.rds")
saveRDS(preds, "data/processed/preds_enriched.rds")
