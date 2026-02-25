# True Out-of-Sample Test: 2025
# Strategy developed on 2021-2024, tested on untouched 2025 data

library(tidyverse)
source("src/backtesting/07_elo_ratings.R")

cat("=== TRUE OUT-OF-SAMPLE TEST: 2025 ===\n\n")

hist_matches <- readRDS("data/processed/atp_matches_aligned.rds")

# Load Platt coefficients (frozen from 2021-2023)
platt_results <- readRDS("data/processed/platt_scaling_results.rds")
platt_a <- platt_results$coefficients[1]
platt_b <- platt_results$coefficients[2]

cat(sprintf("Frozen Platt coefficients: a=%.4f, b=%.4f\n", platt_a, platt_b))

# Build Elo through end of 2024
elo_cutoff <- as.Date("2025-01-01")
prior_matches <- hist_matches %>%
  filter(match_date < elo_cutoff) %>%
  filter(!is.na(winner_name), !is.na(loser_name))

elo_db <- build_elo_db_from_matches(prior_matches, verbose = FALSE)
cat(sprintf("Elo built from %d matches through 2024\n\n", nrow(prior_matches)))

# Helper functions
extract_last <- function(name) {
  name %>%
    str_replace("\\s+[A-Z]\\.$", "") %>%
    str_replace("\\s+[A-Z]\\.[A-Z]\\.$", "") %>%
    str_to_lower() %>%
    str_trim()
}

create_name_lookup <- function(matches) {
  matches %>%
    filter(!is.na(winner_name)) %>%
    mutate(last = str_to_lower(word(winner_name, -1))) %>%
    select(last, full = winner_name) %>%
    distinct(last, .keep_all = TRUE)
}

name_map <- create_name_lookup(hist_matches)

# Load 2025 betting data
betting <- readxl::read_xlsx("data/raw/tennis_betting/2025.xlsx") %>%
  mutate(Date = as.Date(Date))

matched <- betting %>%
  mutate(w_last = extract_last(Winner), l_last = extract_last(Loser)) %>%
  left_join(name_map, by = c("w_last" = "last")) %>%
  rename(winner = full) %>%
  left_join(name_map, by = c("l_last" = "last")) %>%
  rename(loser = full) %>%
  filter(!is.na(winner), !is.na(loser), !is.na(PSW), !is.na(PSL))

cat(sprintf("2025 matches with Elo coverage: %d\n\n", nrow(matched)))

# Generate predictions
results <- vector("list", nrow(matched))

for (i in 1:nrow(matched)) {
  m <- matched[i, ]
  surface <- m$Surface

  w_info <- get_player_elo(m$winner, surface, elo_db)
  l_info <- get_player_elo(m$loser, surface, elo_db)
  elo_prob_w <- elo_expected_prob(w_info$elo, l_info$elo)

  # Platt scaling
  elo_fav_prob <- max(elo_prob_w, 1 - elo_prob_w)
  elo_logit <- qlogis(pmax(0.01, pmin(0.99, elo_fav_prob)))
  calibrated_fav_prob <- plogis(platt_a + platt_b * elo_logit)
  calibrated_prob_w <- ifelse(elo_prob_w > 0.5, calibrated_fav_prob, 1 - calibrated_fav_prob)

  # Market info
  implied_w <- 1 / m$PSW
  implied_l <- 1 / m$PSL
  mkt_prob_w <- implied_w / (implied_w + implied_l)

  mkt_fav <- ifelse(m$PSW < m$PSL, m$winner, m$loser)
  mkt_dog <- ifelse(m$PSW < m$PSL, m$loser, m$winner)
  mkt_dog_odds <- max(m$PSW, m$PSL)
  mkt_dog_prob <- 1 - max(mkt_prob_w, 1 - mkt_prob_w)
  calibrated_dog_prob <- ifelse(mkt_dog == m$winner, calibrated_prob_w, 1 - calibrated_prob_w)
  dog_edge <- calibrated_dog_prob - mkt_dog_prob

  results[[i]] <- tibble(
    date = m$Date,
    winner = m$winner,
    loser = m$loser,
    surface = surface,
    mkt_dog = mkt_dog,
    mkt_dog_odds = mkt_dog_odds,
    dog_edge = dog_edge,
    dog_won = (mkt_dog == m$winner),
    dog_profit = ifelse(mkt_dog == m$winner, mkt_dog_odds - 1, -1)
  )

  # Rolling update
  update <- elo_update(w_info$elo, l_info$elo)
  idx_w <- which(elo_db$overall$player == m$winner)
  idx_l <- which(elo_db$overall$player == m$loser)
  if (length(idx_w) > 0) elo_db$overall$elo[idx_w] <- update$new_winner_elo
  if (length(idx_l) > 0) elo_db$overall$elo[idx_l] <- update$new_loser_elo
}

preds <- bind_rows(results)

# ============================================================================
# TEST STRATEGIES
# ============================================================================

cat("==================================================\n")
cat("REFINED STRATEGY: Odds 2.0-2.5, Edge 0-10%\n")
cat("==================================================\n\n")

subset <- preds %>%
  filter(dog_edge > 0, dog_edge <= 0.10,
         mkt_dog_odds >= 2.0, mkt_dog_odds < 2.5)

cat(sprintf("N: %d\n", nrow(subset)))
cat(sprintf("Win rate: %.1f%%\n", 100 * mean(subset$dog_won)))
cat(sprintf("Avg odds: %.2f\n", mean(subset$mkt_dog_odds)))
cat(sprintf("Breakeven: %.1f%%\n", 100 / mean(subset$mkt_dog_odds)))
cat(sprintf("ROI: %+.2f%%\n\n", 100 * mean(subset$dog_profit)))

# By surface
cat("By surface:\n")
subset %>%
  group_by(surface) %>%
  summarise(n = n(), win_rate = mean(dog_won), roi = mean(dog_profit), .groups = "drop") %>%
  mutate(win_rate = sprintf("%.1f%%", 100 * win_rate), roi = sprintf("%+.2f%%", 100 * roi)) %>%
  print()

# Hard court specifically
cat("\nHard court only:\n")
hard <- subset %>% filter(surface == "Hard")
if (nrow(hard) > 0) {
  cat(sprintf("  N: %d, Win: %.1f%%, ROI: %+.2f%%\n",
              nrow(hard), 100*mean(hard$dog_won), 100*mean(hard$dog_profit)))
}

# Statistical test
if (nrow(subset) > 30) {
  wins <- sum(subset$dog_won)
  n <- nrow(subset)
  breakeven <- 1 / mean(subset$mkt_dog_odds)
  test <- binom.test(wins, n, p = breakeven, alternative = "greater")
  cat(sprintf("\np-value (vs breakeven): %.4f\n", test$p.value))
}

# Monthly breakdown
cat("\nBy month:\n")
subset %>%
  mutate(month = format(date, "%Y-%m")) %>%
  group_by(month) %>%
  summarise(n = n(), roi = mean(dog_profit), .groups = "drop") %>%
  mutate(roi = sprintf("%+.2f%%", 100 * roi)) %>%
  print()

# ============================================================================
# COMPARISON: All odds ranges
# ============================================================================

cat("\n==================================================\n")
cat("ALL ODDS RANGES (Edge 0-10%)\n")
cat("==================================================\n\n")

preds %>%
  filter(dog_edge > 0, dog_edge <= 0.10) %>%
  mutate(
    odds_bucket = cut(mkt_dog_odds,
                      breaks = c(1, 2, 2.5, 3, 4, 10),
                      labels = c("1.0-2.0", "2.0-2.5", "2.5-3.0", "3.0-4.0", "4.0+"))
  ) %>%
  group_by(odds_bucket) %>%
  summarise(
    n = n(),
    win_rate = mean(dog_won),
    avg_odds = mean(mkt_dog_odds),
    roi = mean(dog_profit),
    .groups = "drop"
  ) %>%
  mutate(
    breakeven = 1 / avg_odds,
    win_rate = sprintf("%.1f%%", 100 * win_rate),
    breakeven = sprintf("%.1f%%", 100 * breakeven),
    roi = sprintf("%+.2f%%", 100 * roi)
  ) %>%
  print()

cat("\n==================================================\n")
cat("SUMMARY\n")
cat("==================================================\n\n")

cat("Historical performance (2021-H1 2024):\n")
cat("  Odds 2.0-2.5, Edge 0-10%: N=~1200, ROI=+5.16%, 3/4 years positive\n\n")

cat("2025 out-of-sample result:\n")
cat(sprintf("  N: %d, ROI: %+.2f%%\n", nrow(subset), 100 * mean(subset$dog_profit)))
