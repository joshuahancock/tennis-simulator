# Prospective Paper Trading: H2 2024
#
# This script freezes ALL parameters at the end of H1 2024 and
# paper-trades H2 2024 with ZERO adjustments.
#
# This is the definitive edge test.
#
# Parameters frozen:
# - Platt scaling coefficients (from 2021-2023 training)
# - Elo ratings (built through H1 2024)
# - Betting rule: Bet on Elo's pick with Platt-calibrated probabilities

library(tidyverse)
source("src/backtesting/07_elo_ratings.R")

cat("=== PROSPECTIVE PAPER TRADING: H2 2024 ===\n\n")

hist_matches <- readRDS("data/processed/atp_matches_aligned.rds")

# ============================================================================
# FREEZE PARAMETERS AT END OF H1 2024
# ============================================================================

cat("Step 1: Loading frozen Platt coefficients from training (2021-2023)\n")

# Load Platt model from previous analysis
platt_results <- readRDS("data/processed/platt_scaling_results.rds")
platt_intercept <- platt_results$coefficients[1]
platt_slope <- platt_results$coefficients[2]

cat(sprintf("  Platt intercept (a): %.4f\n", platt_intercept))
cat(sprintf("  Platt slope (b): %.4f\n", platt_slope))

cat("\nStep 2: Building Elo database through H1 2024\n")

# Build Elo through end of H1 2024
elo_cutoff <- as.Date("2024-07-01")

prior_matches <- hist_matches %>%
  filter(match_date < elo_cutoff) %>%
  filter(!is.na(winner_name), !is.na(loser_name))

elo_db <- build_elo_db_from_matches(prior_matches, verbose = FALSE)
cat(sprintf("  Elo database built from %d matches\n", nrow(prior_matches)))

# ============================================================================
# BETTING RULE (FROZEN)
# ============================================================================

# Rule: Bet on Elo's pick (the player Elo assigns > 50% probability)
# Use Platt-calibrated probabilities for decision-making
# Bet at Pinnacle opening odds

cat("\nStep 3: Defining frozen betting rule\n")
cat("  Rule: Bet on Elo's pick (Platt-calibrated probability > 50%)\n")
cat("  Odds: Pinnacle opening odds\n")
cat("  No edge threshold, no filtering - pure Elo picks\n")

# ============================================================================
# PAPER TRADE H2 2024
# ============================================================================

cat("\nStep 4: Paper trading H2 2024...\n")

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

# Load H2 2024 betting data
betting_file <- "data/raw/tennis_betting/2024.xlsx"
betting <- readxl::read_xlsx(betting_file) %>%
  mutate(Date = as.Date(Date)) %>%
  filter(Date >= as.Date("2024-07-01"))

name_map <- create_name_lookup(hist_matches)

matched <- betting %>%
  mutate(w_last = extract_last(Winner), l_last = extract_last(Loser)) %>%
  left_join(name_map, by = c("w_last" = "last")) %>%
  rename(winner = full) %>%
  left_join(name_map, by = c("l_last" = "last")) %>%
  rename(loser = full) %>%
  filter(!is.na(winner), !is.na(loser), !is.na(PSW), !is.na(PSL))

cat(sprintf("  H2 2024 matches available: %d\n", nrow(matched)))

# Generate predictions with frozen model
results <- vector("list", nrow(matched))

for (i in 1:nrow(matched)) {
  m <- matched[i, ]
  surface <- m$Surface

  # Get Elo prediction
  w_info <- get_player_elo(m$winner, surface, elo_db)
  l_info <- get_player_elo(m$loser, surface, elo_db)
  elo_prob_w <- elo_expected_prob(w_info$elo, l_info$elo)

  # Apply Platt scaling (FROZEN from training)
  elo_fav_prob <- max(elo_prob_w, 1 - elo_prob_w)
  elo_logit <- qlogis(pmax(0.01, pmin(0.99, elo_fav_prob)))
  calibrated_fav_prob <- plogis(platt_intercept + platt_slope * elo_logit)

  # Back-transform to winner probability
  elo_pick <- ifelse(elo_prob_w > 0.5, m$winner, m$loser)
  calibrated_prob_w <- ifelse(elo_prob_w > 0.5, calibrated_fav_prob, 1 - calibrated_fav_prob)

  # Market info
  mkt_fav <- ifelse(m$PSW < m$PSL, m$winner, m$loser)
  mkt_fav_odds <- min(m$PSW, m$PSL)

  results[[i]] <- tibble(
    date = m$Date,
    winner = m$winner,
    loser = m$loser,
    surface = surface,
    w_odds = m$PSW,
    l_odds = m$PSL,
    elo_prob_w = elo_prob_w,
    calibrated_prob_w = calibrated_prob_w,
    elo_pick = elo_pick,
    mkt_fav = mkt_fav,
    elo_correct = (elo_pick == m$winner),
    mkt_correct = (mkt_fav == m$winner)
  )

  # Rolling Elo update (even in paper trading, Elo learns from results)
  update <- elo_update(w_info$elo, l_info$elo)
  idx_w <- which(elo_db$overall$player == m$winner)
  idx_l <- which(elo_db$overall$player == m$loser)
  if (length(idx_w) > 0) elo_db$overall$elo[idx_w] <- update$new_winner_elo
  if (length(idx_l) > 0) elo_db$overall$elo[idx_l] <- update$new_loser_elo
}

preds <- bind_rows(results) %>%
  mutate(
    bet_odds = ifelse(elo_pick == winner, w_odds, l_odds),
    profit = ifelse(elo_correct, bet_odds - 1, -1)
  )

# ============================================================================
# RESULTS
# ============================================================================

cat("\n========================================\n")
cat("PROSPECTIVE PAPER TRADING RESULTS: H2 2024\n")
cat("========================================\n\n")

n_bets <- nrow(preds)
wins <- sum(preds$elo_correct)
win_rate <- mean(preds$elo_correct)
avg_odds <- mean(preds$bet_odds)
total_profit <- sum(preds$profit)
roi <- mean(preds$profit)

cat(sprintf("Total bets: %d\n", n_bets))
cat(sprintf("Wins: %d\n", wins))
cat(sprintf("Win rate: %.1f%%\n", 100 * win_rate))
cat(sprintf("Average odds: %.2f\n", avg_odds))
cat(sprintf("Breakeven: %.1f%%\n", 100 / avg_odds))
cat(sprintf("\n"))
cat(sprintf("Total profit (1 unit bets): %+.2f units\n", total_profit))
cat(sprintf("ROI: %+.2f%%\n", 100 * roi))

# Statistical test
breakeven <- 1 / avg_odds
binom_test <- binom.test(wins, n_bets, p = breakeven, alternative = "greater")
cat(sprintf("p-value (vs breakeven): %.4f\n", binom_test$p.value))

cat("\n----------------------------------------\n")
cat("COMPARISON: Elo vs Market\n")
cat("----------------------------------------\n\n")

cat(sprintf("Elo accuracy: %.1f%%\n", 100 * mean(preds$elo_correct)))
cat(sprintf("Market accuracy: %.1f%%\n", 100 * mean(preds$mkt_correct)))

# When Elo disagrees with market
disagree <- preds %>% filter(elo_pick != mkt_fav)
if (nrow(disagree) > 0) {
  cat(sprintf("\nWhen Elo DISAGREES with market (N=%d):\n", nrow(disagree)))
  cat(sprintf("  Elo accuracy: %.1f%%\n", 100 * mean(disagree$elo_correct)))
  cat(sprintf("  Market accuracy: %.1f%%\n", 100 * mean(disagree$mkt_correct)))
}

cat("\n----------------------------------------\n")
cat("BY SURFACE\n")
cat("----------------------------------------\n\n")

preds %>%
  group_by(surface) %>%
  summarise(
    n = n(),
    elo_accuracy = mean(elo_correct),
    roi = mean(profit),
    .groups = "drop"
  ) %>%
  mutate(
    elo_accuracy = sprintf("%.1f%%", 100 * elo_accuracy),
    roi = sprintf("%+.2f%%", 100 * roi)
  ) %>%
  print()

cat("\n----------------------------------------\n")
cat("BY MONTH\n")
cat("----------------------------------------\n\n")

preds %>%
  mutate(month = format(date, "%Y-%m")) %>%
  group_by(month) %>%
  summarise(
    n = n(),
    elo_accuracy = mean(elo_correct),
    roi = mean(profit),
    .groups = "drop"
  ) %>%
  mutate(
    elo_accuracy = sprintf("%.1f%%", 100 * elo_accuracy),
    roi = sprintf("%+.2f%%", 100 * roi)
  ) %>%
  print()

# ============================================================================
# VERDICT
# ============================================================================

cat("\n========================================\n")
cat("VERDICT\n")
cat("========================================\n\n")

if (roi > 0 && binom_test$p.value < 0.05) {
  cat("POSITIVE EDGE CONFIRMED in out-of-sample paper trading.\n")
  cat("The Elo model provides a statistically significant betting edge.\n")
} else if (roi > 0) {
  cat("POSITIVE ROI but NOT statistically significant.\n")
  cat("Could be luck. More data needed to confirm edge.\n")
} else {
  cat("NEGATIVE ROI in out-of-sample paper trading.\n")
  cat("No betting edge exists with the current Elo model.\n")
  cat("\nConclusion: The market is more efficient than Elo for match predictions.\n")
}

# Save results
saveRDS(preds, "data/processed/prospective_paper_trade_h2_2024.rds")
cat("\nResults saved to data/processed/prospective_paper_trade_h2_2024.rds\n")
