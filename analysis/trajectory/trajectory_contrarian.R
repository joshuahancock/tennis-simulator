# Contrarian Trajectory Strategy: Deep Dive
#
# Key finding from trajectory_analysis.R:
# - Betting AGAINST falling Elo picks shows +1.27% ROI
# - When Elo pick is falling (trajectory < -10%), opponent wins 39.7%
# - At average opponent odds of 3.65, breakeven is 27.4%
# - This is a 12pp edge on win rate
#
# This script validates the contrarian signal more rigorously.

library(tidyverse)
source("src/backtesting/07_elo_ratings.R")

cat("=== CONTRARIAN TRAJECTORY STRATEGY ===\n\n")

# Load the trajectory predictions
preds <- readRDS("data/processed/trajectory_analysis.rds")

# Filter to matches with trajectory data
preds_traj <- preds %>%
  filter(!is.na(trajectory_diff)) %>%
  mutate(
    # Opponent of Elo pick
    elo_opp = ifelse(elo_pick == winner, loser, winner),
    elo_opp_odds = ifelse(elo_pick == winner,
                          1 / (1 - mkt_prob_w),
                          1 / mkt_prob_w),
    elo_opp_won = !elo_correct,
    contrarian_profit = ifelse(elo_opp_won, elo_opp_odds - 1, -1)
  )

# ============================================================================
# ANALYSIS 1: CONTRARIAN BY TRAJECTORY THRESHOLD
# ============================================================================

cat("==================================================\n")
cat("CONTRARIAN ROI BY TRAJECTORY THRESHOLD\n")
cat("(Betting AGAINST Elo pick when pick is falling)\n")
cat("==================================================\n\n")

thresholds <- c(-0.05, -0.10, -0.15, -0.20, -0.25, -0.30)

for (thresh in thresholds) {
  subset <- preds_traj %>% filter(trajectory_diff < thresh)
  if (nrow(subset) >= 50) {
    yearly <- subset %>%
      group_by(year) %>%
      summarise(roi = mean(contrarian_profit), .groups = "drop")
    pos_years <- sum(yearly$roi > 0)

    cat(sprintf("Traj < %+.0f%%: N=%4d, OppWins=%.1f%%, AvgOdds=%.2f, BE=%.1f%%, ROI=%+.2f%%, %d/4 pos\n",
                100*thresh, nrow(subset),
                100*mean(subset$elo_opp_won),
                mean(subset$elo_opp_odds),
                100/mean(subset$elo_opp_odds),
                100*mean(subset$contrarian_profit), pos_years))
  }
}

# ============================================================================
# ANALYSIS 2: BEST THRESHOLD BY YEAR
# ============================================================================

cat("\n\n==================================================\n")
cat("TRAJECTORY < -20% BY YEAR\n")
cat("==================================================\n\n")

strong_fall <- preds_traj %>% filter(trajectory_diff < -0.20)

strong_fall %>%
  group_by(year) %>%
  summarise(
    n = n(),
    opp_win_rate = mean(elo_opp_won),
    avg_opp_odds = mean(elo_opp_odds),
    contrarian_roi = mean(contrarian_profit),
    .groups = "drop"
  ) %>%
  mutate(
    breakeven = 1 / avg_opp_odds,
    excess = opp_win_rate - breakeven,
    opp_win_rate = sprintf("%.1f%%", 100 * opp_win_rate),
    breakeven = sprintf("%.1f%%", 100 * breakeven),
    excess = sprintf("%+.1fpp", 100 * excess),
    contrarian_roi = sprintf("%+.2f%%", 100 * contrarian_roi)
  ) %>%
  print()

# Statistical test
cat("\nStatistical test vs breakeven:\n")
wins <- sum(strong_fall$elo_opp_won)
n <- nrow(strong_fall)
breakeven <- 1 / mean(strong_fall$elo_opp_odds)
test <- binom.test(wins, n, p = breakeven, alternative = "greater")
cat(sprintf("  N=%d, Wins=%d, Win rate=%.1f%%, Breakeven=%.1f%%\n",
            n, wins, 100*wins/n, 100*breakeven))
cat(sprintf("  p-value: %.4f\n", test$p.value))

# ============================================================================
# ANALYSIS 3: ADD ODDS FILTER
# ============================================================================

cat("\n\n==================================================\n")
cat("CONTRARIAN + ODDS FILTER\n")
cat("(Falling trajectory + specific opponent odds range)\n")
cat("==================================================\n\n")

# When Elo pick is falling, bet on opponent in certain odds ranges
for (min_odds in c(2.0, 2.5, 3.0)) {
  for (max_odds in c(3.0, 4.0, 5.0, 10.0)) {
    if (max_odds <= min_odds) next

    subset <- strong_fall %>%
      filter(elo_opp_odds >= min_odds, elo_opp_odds < max_odds)

    if (nrow(subset) >= 30) {
      yearly <- subset %>%
        group_by(year) %>%
        summarise(roi = mean(contrarian_profit), .groups = "drop")
      pos_years <- sum(yearly$roi > 0)

      cat(sprintf("Traj<-20%%, Odds %.1f-%.1f: N=%3d, WinRate=%.1f%%, ROI=%+.2f%%, %d/4 pos\n",
                  min_odds, max_odds, nrow(subset),
                  100*mean(subset$elo_opp_won),
                  100*mean(subset$contrarian_profit), pos_years))
    }
  }
}

# ============================================================================
# ANALYSIS 4: SURFACE BREAKDOWN
# ============================================================================

cat("\n\n==================================================\n")
cat("CONTRARIAN (TRAJ < -20%) BY SURFACE\n")
cat("==================================================\n\n")

strong_fall %>%
  group_by(surface) %>%
  summarise(
    n = n(),
    opp_win_rate = mean(elo_opp_won),
    avg_opp_odds = mean(elo_opp_odds),
    roi = mean(contrarian_profit),
    .groups = "drop"
  ) %>%
  mutate(
    opp_win_rate = sprintf("%.1f%%", 100 * opp_win_rate),
    roi = sprintf("%+.2f%%", 100 * roi)
  ) %>%
  print()

# ============================================================================
# ANALYSIS 5: COMBINED WITH MOMENTUM
# ============================================================================

cat("\n\n==================================================\n")
cat("CONTRARIAN: FALLING TRAJECTORY + NEGATIVE MOMENTUM\n")
cat("==================================================\n\n")

# When Elo pick has both falling trajectory AND negative momentum
double_fall <- preds_traj %>%
  filter(trajectory_diff < -0.15, momentum_diff < -50)

if (nrow(double_fall) >= 50) {
  cat(sprintf("N: %d\n", nrow(double_fall)))
  cat(sprintf("Opponent win rate: %.1f%%\n", 100*mean(double_fall$elo_opp_won)))
  cat(sprintf("Avg opponent odds: %.2f\n", mean(double_fall$elo_opp_odds)))
  cat(sprintf("Breakeven: %.1f%%\n", 100/mean(double_fall$elo_opp_odds)))
  cat(sprintf("Contrarian ROI: %+.2f%%\n\n", 100*mean(double_fall$contrarian_profit)))

  cat("By year:\n")
  double_fall %>%
    group_by(year) %>%
    summarise(n = n(), roi = mean(contrarian_profit), .groups = "drop") %>%
    mutate(roi = sprintf("%+.2f%%", 100 * roi)) %>%
    print()
}

# ============================================================================
# ANALYSIS 6: OUT-OF-SAMPLE TEST ON 2025
# ============================================================================

cat("\n\n==================================================\n")
cat("OUT-OF-SAMPLE: 2025 CONTRARIAN TEST\n")
cat("==================================================\n\n")

# Need to generate 2025 predictions with trajectory
# Load saved Elo data and extend to 2025

hist_matches <- readRDS("data/processed/atp_matches_aligned.rds")
platt_results <- readRDS("data/processed/platt_scaling_results.rds")
platt_a <- platt_results$coefficients[1]
platt_b <- platt_results$coefficients[2]

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

elo_db_2024 <- build_elo_with_history(pre_2025)

# Get player trajectory function
get_trajectory <- function(player, current_date, history, window = 10) {
  recent <- history %>%
    filter(player == !!player, match_date < current_date) %>%
    arrange(desc(match_date)) %>%
    head(window)

  if (nrow(recent) < 5) return(NA)

  excess_wins <- sum(recent$won) - sum(recent$expected)
  trajectory <- excess_wins / nrow(recent)
  trajectory
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

cat(sprintf("2025 matches: %d\n", nrow(matched_2025)))

# Generate predictions
results_2025 <- vector("list", nrow(matched_2025))

for (i in 1:nrow(matched_2025)) {
  m <- matched_2025[i, ]

  w_idx <- which(elo_db_2024$overall$player == m$winner)
  l_idx <- which(elo_db_2024$overall$player == m$loser)

  if (length(w_idx) == 0 || length(l_idx) == 0) {
    results_2025[[i]] <- NULL
    next
  }

  w_elo <- elo_db_2024$overall$elo[w_idx]
  l_elo <- elo_db_2024$overall$elo[l_idx]
  elo_prob_w <- elo_expected_prob(w_elo, l_elo)

  # Get trajectories
  w_traj <- get_trajectory(m$winner, m$Date, elo_db_2024$history)
  l_traj <- get_trajectory(m$loser, m$Date, elo_db_2024$history)

  # Market info
  implied_w <- 1 / m$PSW
  implied_l <- 1 / m$PSL
  mkt_prob_w <- implied_w / (implied_w + implied_l)

  # Elo pick
  elo_pick <- ifelse(elo_prob_w > 0.5, m$winner, m$loser)
  elo_opp <- ifelse(elo_pick == m$winner, m$loser, m$winner)
  elo_opp_odds <- ifelse(elo_pick == m$winner, 1/(1-mkt_prob_w), 1/mkt_prob_w)
  elo_correct <- (elo_pick == m$winner)

  # Trajectory diff (Elo pick's trajectory minus opponent's)
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
  elo_db_2024$overall$elo[w_idx] <- update$new_winner_elo
  elo_db_2024$overall$elo[l_idx] <- update$new_loser_elo

  # Update history
  expected_w <- elo_expected_prob(w_elo, l_elo)
  elo_db_2024$history <- bind_rows(elo_db_2024$history, tibble(
    match_date = m$Date,
    player = m$winner,
    elo_before = w_elo,
    elo_after = update$new_winner_elo,
    won = TRUE,
    expected = expected_w
  ))
  elo_db_2024$history <- bind_rows(elo_db_2024$history, tibble(
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

cat(sprintf("2025 matches with trajectory: %d\n\n", nrow(preds_2025)))

# Test contrarian strategy on 2025
cat("2025 Contrarian Strategy Results:\n")
cat("---------------------------------\n\n")

for (thresh in c(-0.10, -0.15, -0.20, -0.25)) {
  subset <- preds_2025 %>% filter(trajectory_diff < thresh)
  if (nrow(subset) >= 20) {
    cat(sprintf("Traj < %+.0f%%: N=%3d, OppWins=%.1f%%, ROI=%+.2f%%\n",
                100*thresh, nrow(subset),
                100*mean(subset$elo_opp_won),
                100*mean(subset$contrarian_profit)))
  }
}

# ============================================================================
# SUMMARY
# ============================================================================

cat("\n\n==================================================\n")
cat("SUMMARY: CONTRARIAN TRAJECTORY STRATEGY\n")
cat("==================================================\n\n")

cat("In-Sample (2021-2024):\n")
cat("  Traj < -20%: N=1128, OppWins=40.2%, ROI=+3.74%\n")
cat("  Best performing: Traj < -25%, N=676, ROI=+6.33%\n\n")

cat("Out-of-Sample (2025):\n")
subset_2025_20 <- preds_2025 %>% filter(trajectory_diff < -0.20)
if (nrow(subset_2025_20) >= 20) {
  cat(sprintf("  Traj < -20%%: N=%d, OppWins=%.1f%%, ROI=%+.2f%%\n",
              nrow(subset_2025_20),
              100*mean(subset_2025_20$elo_opp_won),
              100*mean(subset_2025_20$contrarian_profit)))
}

