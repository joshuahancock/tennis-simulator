# Best Trajectory Subset Validation
#
# Finding: Traj < -20%, Odds 3.0-5.0 shows +10.69% ROI, 4/4 years positive
#
# This script validates this specific subset more rigorously.

library(tidyverse)
source("src/backtesting/07_elo_ratings.R")

cat("=== BEST TRAJECTORY SUBSET VALIDATION ===\n\n")

# Load 2021-2024 predictions
preds <- readRDS("data/processed/trajectory_analysis.rds")

preds_traj <- preds %>%
  filter(!is.na(trajectory_diff)) %>%
  mutate(
    elo_opp = ifelse(elo_pick == winner, loser, winner),
    elo_opp_odds = ifelse(elo_pick == winner,
                          1 / (1 - mkt_prob_w),
                          1 / mkt_prob_w),
    elo_opp_won = !elo_correct,
    contrarian_profit = ifelse(elo_opp_won, elo_opp_odds - 1, -1)
  )

# ============================================================================
# BEST SUBSET: Traj < -20%, Odds 3.0-5.0
# ============================================================================

cat("==================================================\n")
cat("IN-SAMPLE: Traj < -20%, Odds 3.0-5.0\n")
cat("==================================================\n\n")

best <- preds_traj %>%
  filter(trajectory_diff < -0.20,
         elo_opp_odds >= 3.0,
         elo_opp_odds < 5.0)

cat(sprintf("Total N: %d\n", nrow(best)))
cat(sprintf("Opponent win rate: %.1f%%\n", 100*mean(best$elo_opp_won)))
cat(sprintf("Avg opponent odds: %.2f\n", mean(best$elo_opp_odds)))
cat(sprintf("Breakeven: %.1f%%\n", 100/mean(best$elo_opp_odds)))
cat(sprintf("ROI: %+.2f%%\n\n", 100*mean(best$contrarian_profit)))

cat("By year:\n")
best %>%
  group_by(year) %>%
  summarise(
    n = n(),
    opp_wins = sum(elo_opp_won),
    opp_win_rate = mean(elo_opp_won),
    avg_odds = mean(elo_opp_odds),
    profit = sum(contrarian_profit),
    roi = mean(contrarian_profit),
    .groups = "drop"
  ) %>%
  mutate(
    cumulative_profit = cumsum(profit),
    opp_win_rate = sprintf("%.1f%%", 100 * opp_win_rate),
    roi = sprintf("%+.2f%%", 100 * roi),
    profit = sprintf("%+.1f", profit),
    cumulative_profit = sprintf("%+.1f", cumulative_profit)
  ) %>%
  print()

# Statistical test
cat("\nStatistical test:\n")
wins <- sum(best$elo_opp_won)
n <- nrow(best)
breakeven <- 1 / mean(best$elo_opp_odds)
test <- binom.test(wins, n, p = breakeven, alternative = "greater")
cat(sprintf("  p-value: %.6f\n", test$p.value))

# ============================================================================
# BY SURFACE
# ============================================================================

cat("\n\n==================================================\n")
cat("BY SURFACE\n")
cat("==================================================\n\n")

best %>%
  group_by(surface) %>%
  summarise(
    n = n(),
    opp_win_rate = mean(elo_opp_won),
    roi = mean(contrarian_profit),
    .groups = "drop"
  ) %>%
  mutate(
    opp_win_rate = sprintf("%.1f%%", 100 * opp_win_rate),
    roi = sprintf("%+.2f%%", 100 * roi)
  ) %>%
  print()

# ============================================================================
# OUT-OF-SAMPLE: 2025
# ============================================================================

cat("\n\n==================================================\n")
cat("OUT-OF-SAMPLE: 2025\n")
cat("==================================================\n\n")

# Generate 2025 predictions with trajectory
hist_matches <- readRDS("data/processed/atp_matches_aligned.rds")
platt_results <- readRDS("data/processed/platt_scaling_results.rds")

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

# Build Elo through 2024
cat("Building Elo through 2024...\n")
pre_2025 <- hist_matches %>% filter(match_date < as.Date("2025-01-01"))

build_elo_with_history <- function(matches) {
  matches <- matches %>%
    filter(!is.na(winner_name), !is.na(loser_name)) %>%
    arrange(match_date)

  elo_db <- list(
    overall = tibble(player = character(), elo = numeric(), matches = integer()),
    history = tibble(
      match_date = as.Date(character()),
      player = character(),
      elo_before = numeric(),
      elo_after = numeric(),
      won = logical(),
      expected = numeric()
    )
  )

  for (i in 1:nrow(matches)) {
    m <- matches[i, ]

    w_idx <- which(elo_db$overall$player == m$winner_name)
    l_idx <- which(elo_db$overall$player == m$loser_name)

    if (length(w_idx) == 0) {
      elo_db$overall <- bind_rows(elo_db$overall,
        tibble(player = m$winner_name, elo = 1500, matches = 0))
      w_idx <- nrow(elo_db$overall)
    }
    if (length(l_idx) == 0) {
      elo_db$overall <- bind_rows(elo_db$overall,
        tibble(player = m$loser_name, elo = 1500, matches = 0))
      l_idx <- nrow(elo_db$overall)
    }

    w_elo <- elo_db$overall$elo[w_idx]
    l_elo <- elo_db$overall$elo[l_idx]
    expected_w <- elo_expected_prob(w_elo, l_elo)

    update <- elo_update(w_elo, l_elo)
    elo_db$overall$elo[w_idx] <- update$new_winner_elo
    elo_db$overall$elo[l_idx] <- update$new_loser_elo
    elo_db$overall$matches[w_idx] <- elo_db$overall$matches[w_idx] + 1
    elo_db$overall$matches[l_idx] <- elo_db$overall$matches[l_idx] + 1

    elo_db$history <- bind_rows(elo_db$history, tibble(
      match_date = m$match_date,
      player = m$winner_name,
      elo_before = w_elo,
      elo_after = update$new_winner_elo,
      won = TRUE,
      expected = expected_w
    ))
    elo_db$history <- bind_rows(elo_db$history, tibble(
      match_date = m$match_date,
      player = m$loser_name,
      elo_before = l_elo,
      elo_after = update$new_loser_elo,
      won = FALSE,
      expected = 1 - expected_w
    ))
  }

  elo_db
}

elo_db <- build_elo_with_history(pre_2025)

get_trajectory <- function(player, current_date, history, window = 10) {
  recent <- history %>%
    filter(player == !!player, match_date < current_date) %>%
    arrange(desc(match_date)) %>%
    head(window)

  if (nrow(recent) < 5) return(NA)
  excess_wins <- sum(recent$won) - sum(recent$expected)
  excess_wins / nrow(recent)
}

# Load 2025 betting data
betting_2025 <- readxl::read_xlsx("data/raw/tennis_betting/2025.xlsx") %>%
  mutate(Date = as.Date(Date)) %>%
  select(Date, Surface, Winner, Loser, PSW, PSL)

matched_2025 <- betting_2025 %>%
  mutate(w_last = extract_last(Winner), l_last = extract_last(Loser)) %>%
  left_join(name_map, by = c("w_last" = "last")) %>%
  rename(winner = full) %>%
  left_join(name_map, by = c("l_last" = "last")) %>%
  rename(loser = full) %>%
  filter(!is.na(winner), !is.na(loser), !is.na(PSW), !is.na(PSL))

# Generate predictions
results_2025 <- vector("list", nrow(matched_2025))

for (i in 1:nrow(matched_2025)) {
  m <- matched_2025[i, ]

  w_idx <- which(elo_db$overall$player == m$winner)
  l_idx <- which(elo_db$overall$player == m$loser)

  if (length(w_idx) == 0 || length(l_idx) == 0) {
    results_2025[[i]] <- NULL
    next
  }

  w_elo <- elo_db$overall$elo[w_idx]
  l_elo <- elo_db$overall$elo[l_idx]
  elo_prob_w <- elo_expected_prob(w_elo, l_elo)

  w_traj <- get_trajectory(m$winner, m$Date, elo_db$history)
  l_traj <- get_trajectory(m$loser, m$Date, elo_db$history)

  implied_w <- 1 / m$PSW
  implied_l <- 1 / m$PSL
  mkt_prob_w <- implied_w / (implied_w + implied_l)

  elo_pick <- ifelse(elo_prob_w > 0.5, m$winner, m$loser)
  elo_opp <- ifelse(elo_pick == m$winner, m$loser, m$winner)
  elo_opp_odds <- ifelse(elo_pick == m$winner, 1/(1-mkt_prob_w), 1/mkt_prob_w)
  elo_correct <- (elo_pick == m$winner)
  traj_diff <- ifelse(elo_pick == m$winner, w_traj - l_traj, l_traj - w_traj)

  results_2025[[i]] <- tibble(
    date = m$Date,
    winner = m$winner,
    loser = m$loser,
    surface = m$Surface,
    elo_pick = elo_pick,
    elo_opp = elo_opp,
    elo_correct = elo_correct,
    elo_opp_odds = elo_opp_odds,
    elo_opp_won = !elo_correct,
    trajectory_diff = traj_diff,
    contrarian_profit = ifelse(!elo_correct, elo_opp_odds - 1, -1)
  )

  # Update Elo
  update <- elo_update(w_elo, l_elo)
  elo_db$overall$elo[w_idx] <- update$new_winner_elo
  elo_db$overall$elo[l_idx] <- update$new_loser_elo

  expected_w <- elo_expected_prob(w_elo, l_elo)
  elo_db$history <- bind_rows(elo_db$history, tibble(
    match_date = m$Date,
    player = m$winner,
    elo_before = w_elo,
    elo_after = update$new_winner_elo,
    won = TRUE,
    expected = expected_w
  ))
  elo_db$history <- bind_rows(elo_db$history, tibble(
    match_date = m$Date,
    player = m$loser,
    elo_before = l_elo,
    elo_after = update$new_loser_elo,
    won = FALSE,
    expected = 1 - expected_w
  ))
}

preds_2025 <- bind_rows(results_2025) %>%
  filter(!is.na(trajectory_diff))

# Apply best subset filter
best_2025 <- preds_2025 %>%
  filter(trajectory_diff < -0.20,
         elo_opp_odds >= 3.0,
         elo_opp_odds < 5.0)

cat(sprintf("2025 N (Traj<-20%%, Odds 3-5): %d\n", nrow(best_2025)))

if (nrow(best_2025) >= 10) {
  cat(sprintf("Opponent win rate: %.1f%%\n", 100*mean(best_2025$elo_opp_won)))
  cat(sprintf("Avg opponent odds: %.2f\n", mean(best_2025$elo_opp_odds)))
  cat(sprintf("Breakeven: %.1f%%\n", 100/mean(best_2025$elo_opp_odds)))
  cat(sprintf("ROI: %+.2f%%\n", 100*mean(best_2025$contrarian_profit)))
  cat(sprintf("Total profit (1u bets): %+.2f units\n", sum(best_2025$contrarian_profit)))

  # By month
  cat("\nBy month:\n")
  best_2025 %>%
    mutate(month = format(date, "%Y-%m")) %>%
    group_by(month) %>%
    summarise(
      n = n(),
      wins = sum(elo_opp_won),
      roi = mean(contrarian_profit),
      .groups = "drop"
    ) %>%
    mutate(roi = sprintf("%+.2f%%", 100 * roi)) %>%
    print()
}

# Statistical test for 2025
if (nrow(best_2025) >= 20) {
  wins <- sum(best_2025$elo_opp_won)
  n <- nrow(best_2025)
  breakeven <- 1 / mean(best_2025$elo_opp_odds)
  test <- binom.test(wins, n, p = breakeven, alternative = "greater")
  cat(sprintf("\np-value (2025 vs breakeven): %.4f\n", test$p.value))
}

# ============================================================================
# SUMMARY
# ============================================================================

cat("\n\n==================================================\n")
cat("SUMMARY: CONTRARIAN TRAJECTORY STRATEGY\n")
cat("==================================================\n\n")

cat("Strategy: Bet AGAINST Elo pick when:\n")
cat("  - Elo pick's trajectory < -20% (falling player)\n")
cat("  - Opponent odds between 3.0 and 5.0\n\n")

cat("In-Sample (2021-2024):\n")
cat(sprintf("  N: %d\n", nrow(best)))
cat(sprintf("  Opponent win rate: %.1f%%\n", 100*mean(best$elo_opp_won)))
cat(sprintf("  Breakeven: %.1f%%\n", 100/mean(best$elo_opp_odds)))
cat(sprintf("  ROI: %+.2f%%\n", 100*mean(best$contrarian_profit)))
cat("  Years positive: 4/4\n\n")

if (nrow(best_2025) >= 10) {
  cat("Out-of-Sample (2025):\n")
  cat(sprintf("  N: %d\n", nrow(best_2025)))
  cat(sprintf("  Opponent win rate: %.1f%%\n", 100*mean(best_2025$elo_opp_won)))
  cat(sprintf("  Breakeven: %.1f%%\n", 100/mean(best_2025$elo_opp_odds)))
  cat(sprintf("  ROI: %+.2f%%\n", 100*mean(best_2025$contrarian_profit)))
}

cat("\n\nInterpretation:\n")
cat("The contrarian signal exploits Elo's trajectory lag. When a player\n")
cat("is falling (performing worse than expected), Elo has not yet fully\n")
cat("adjusted their rating. Betting against such players captures this\n")
cat("adjustment gap.\n")

