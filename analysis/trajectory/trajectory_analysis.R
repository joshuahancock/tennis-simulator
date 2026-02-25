# Player Trajectory Analysis
#
# Hypothesis: Elo ratings lag behind rapid skill changes. Players who are
# "rising" (winning more than Elo predicts) or "falling" (losing more than
# Elo predicts) may be mispriced by both Elo and the market.
#
# Approach:
# 1. Track each player's recent performance vs Elo expectations
# 2. Identify "rising" players (recent wins > expected) and "falling" players
# 3. Test if trajectory provides edge beyond what market already prices

library(tidyverse)
source("src/backtesting/07_elo_ratings.R")

cat("=== PLAYER TRAJECTORY ANALYSIS ===\n\n")

hist_matches <- readRDS("data/processed/atp_matches_aligned.rds")
platt_results <- readRDS("data/processed/platt_scaling_results.rds")
platt_a <- platt_results$coefficients[1]
platt_b <- platt_results$coefficients[2]

# ============================================================================
# TRAJECTORY CALCULATION
# ============================================================================

# For each match, calculate player's recent trajectory:
# - Look at last N matches
# - Compare actual wins to Elo-expected wins
# - Trajectory = (actual - expected) / N

calculate_trajectory <- function(player, current_date, match_history, window = 10) {
  # Get player's recent matches before current date
  recent <- match_history %>%
    filter(match_date < current_date) %>%
    filter(winner_name == player | loser_name == player) %>%
    arrange(desc(match_date)) %>%
    head(window)

  if (nrow(recent) < 5) {
    return(list(trajectory = NA, n_matches = nrow(recent), recent_elo_change = NA))
  }

  # Calculate trajectory as excess wins over expectation
  # This requires Elo expectations at each match - will compute from elo_change
  # Simpler: use raw win rate minus expected win rate

  recent_wins <- sum(recent$winner_name == player)
  recent_losses <- sum(recent$loser_name == player)

  # Get average expected win rate from Elo ratings at time of matches
  # (This is approximate - we'd need the Elo at each match for precision)
  # Use recent Elo change as proxy for trajectory

  # Return simple win rate - 0.5 as trajectory proxy
  trajectory <- (recent_wins / nrow(recent)) - 0.5

  list(
    trajectory = trajectory,
    n_matches = nrow(recent),
    recent_win_rate = recent_wins / nrow(recent)
  )
}

# ============================================================================
# ENHANCED APPROACH: Track Elo momentum
# ============================================================================

# Build Elo with trajectory tracking
build_elo_with_trajectory <- function(matches, trajectory_window = 10) {
  matches <- matches %>%
    filter(!is.na(winner_name), !is.na(loser_name)) %>%
    arrange(match_date)

  # Initialize Elo database
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

  cat("Building Elo with trajectory tracking...\n")
  pb <- txtProgressBar(min = 0, max = nrow(matches), style = 3)

  for (i in 1:nrow(matches)) {
    m <- matches[i, ]

    # Get or create Elo entries
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

    # Expected probability
    expected_w <- elo_expected_prob(w_elo, l_elo)
    expected_l <- 1 - expected_w

    # Update Elo
    update <- elo_update(w_elo, l_elo)
    elo_db$overall$elo[w_idx] <- update$new_winner_elo
    elo_db$overall$elo[l_idx] <- update$new_loser_elo
    elo_db$overall$matches[w_idx] <- elo_db$overall$matches[w_idx] + 1
    elo_db$overall$matches[l_idx] <- elo_db$overall$matches[l_idx] + 1

    # Record history
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
      expected = expected_l
    ))

    setTxtProgressBar(pb, i)
  }
  close(pb)

  elo_db
}

# Calculate trajectory from history
get_player_trajectory <- function(player, current_date, history, window = 10) {
  recent <- history %>%
    filter(player == !!player, match_date < current_date) %>%
    arrange(desc(match_date)) %>%
    head(window)

  if (nrow(recent) < 5) {
    return(list(
      trajectory = NA,
      excess_wins = NA,
      elo_momentum = NA,
      n = nrow(recent)
    ))
  }

  # Trajectory metrics:
  # 1. Excess wins = actual wins - expected wins
  excess_wins <- sum(recent$won) - sum(recent$expected)

  # 2. Elo momentum = Elo change over window
  elo_momentum <- recent$elo_after[1] - recent$elo_before[nrow(recent)]

  # 3. Normalized trajectory = excess / n
  trajectory <- excess_wins / nrow(recent)

  list(
    trajectory = trajectory,
    excess_wins = excess_wins,
    elo_momentum = elo_momentum,
    n = nrow(recent)
  )
}

# ============================================================================
# BUILD DATABASE AND GENERATE PREDICTIONS
# ============================================================================

# Build Elo through 2020 first, then predict 2021-2024
cat("Building Elo database through 2020...\n")
pre_2021 <- hist_matches %>% filter(match_date < as.Date("2021-01-01"))
elo_data <- build_elo_with_trajectory(pre_2021)

cat(sprintf("\nElo database: %d players, %d history records\n",
            nrow(elo_data$overall), nrow(elo_data$history)))

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

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

# ============================================================================
# GENERATE PREDICTIONS WITH TRAJECTORY
# ============================================================================

generate_trajectory_preds <- function(year, elo_data, hist_matches, name_map,
                                       platt_a, platt_b, trajectory_window = 10) {

  cat(sprintf("Processing %d...\n", year))

  # Get betting data
  betting_file <- sprintf("data/raw/tennis_betting/%d.xlsx", year)
  betting <- readxl::read_xlsx(betting_file) %>%
    mutate(Date = as.Date(Date)) %>%
    select(Date, Surface, Winner, Loser, PSW, PSL)

  matched <- betting %>%
    mutate(w_last = extract_last(Winner), l_last = extract_last(Loser)) %>%
    left_join(name_map, by = c("w_last" = "last")) %>%
    rename(winner = full) %>%
    left_join(name_map, by = c("l_last" = "last")) %>%
    rename(loser = full) %>%
    filter(!is.na(winner), !is.na(loser), !is.na(PSW), !is.na(PSL))

  results <- vector("list", nrow(matched))

  for (i in 1:nrow(matched)) {
    m <- matched[i, ]

    # Get Elo ratings
    w_idx <- which(elo_data$overall$player == m$winner)
    l_idx <- which(elo_data$overall$player == m$loser)

    if (length(w_idx) == 0 || length(l_idx) == 0) {
      results[[i]] <- NULL
      next
    }

    w_elo <- elo_data$overall$elo[w_idx]
    l_elo <- elo_data$overall$elo[l_idx]
    elo_prob_w <- elo_expected_prob(w_elo, l_elo)

    # Get trajectory for both players
    w_traj <- get_player_trajectory(m$winner, m$Date, elo_data$history, trajectory_window)
    l_traj <- get_player_trajectory(m$loser, m$Date, elo_data$history, trajectory_window)

    # Market info
    implied_w <- 1 / m$PSW
    implied_l <- 1 / m$PSL
    mkt_prob_w <- implied_w / (implied_w + implied_l)
    mkt_fav <- ifelse(m$PSW < m$PSL, m$winner, m$loser)

    # Platt calibration
    elo_fav_prob <- max(elo_prob_w, 1 - elo_prob_w)
    elo_logit <- qlogis(pmax(0.01, pmin(0.99, elo_fav_prob)))
    calibrated_fav_prob <- plogis(platt_a + platt_b * elo_logit)
    calibrated_prob_w <- ifelse(elo_prob_w > 0.5, calibrated_fav_prob, 1 - calibrated_fav_prob)

    # Elo pick
    elo_pick <- ifelse(elo_prob_w > 0.5, m$winner, m$loser)
    elo_pick_odds <- ifelse(elo_prob_w > 0.5, m$PSW, m$PSL)
    elo_correct <- (elo_pick == m$winner)

    results[[i]] <- tibble(
      date = m$Date,
      year = year,
      winner = m$winner,
      loser = m$loser,
      surface = m$Surface,
      w_elo = w_elo,
      l_elo = l_elo,
      elo_prob_w = elo_prob_w,
      calibrated_prob_w = calibrated_prob_w,
      mkt_prob_w = mkt_prob_w,
      mkt_fav = mkt_fav,
      elo_pick = elo_pick,
      elo_pick_odds = elo_pick_odds,
      elo_correct = elo_correct,
      w_trajectory = w_traj$trajectory,
      l_trajectory = l_traj$trajectory,
      w_elo_momentum = w_traj$elo_momentum,
      l_elo_momentum = l_traj$elo_momentum,
      w_excess_wins = w_traj$excess_wins,
      l_excess_wins = l_traj$excess_wins
    )

    # Update Elo
    update <- elo_update(w_elo, l_elo)
    elo_data$overall$elo[w_idx] <- update$new_winner_elo
    elo_data$overall$elo[l_idx] <- update$new_loser_elo

    # Update history
    expected_w <- elo_expected_prob(w_elo, l_elo)
    elo_data$history <- bind_rows(elo_data$history, tibble(
      match_date = m$Date,
      player = m$winner,
      elo_before = w_elo,
      elo_after = update$new_winner_elo,
      won = TRUE,
      expected = expected_w
    ))
    elo_data$history <- bind_rows(elo_data$history, tibble(
      match_date = m$Date,
      player = m$loser,
      elo_before = l_elo,
      elo_after = update$new_loser_elo,
      won = FALSE,
      expected = 1 - expected_w
    ))
  }

  bind_rows(results)
}

# Generate for all years
all_preds <- list()
for (year in 2021:2024) {
  all_preds[[as.character(year)]] <- generate_trajectory_preds(
    year, elo_data, hist_matches, name_map, platt_a, platt_b
  )
}

preds <- bind_rows(all_preds) %>%
  mutate(
    profit = ifelse(elo_correct, elo_pick_odds - 1, -1),
    # Trajectory differential: positive means Elo pick is rising relative to opponent
    trajectory_diff = ifelse(elo_pick == winner, w_trajectory - l_trajectory, l_trajectory - w_trajectory),
    momentum_diff = ifelse(elo_pick == winner, w_elo_momentum - l_elo_momentum, l_elo_momentum - w_elo_momentum)
  )

cat(sprintf("\nTotal predictions: %d\n", nrow(preds)))
cat(sprintf("With trajectory data: %d\n", sum(!is.na(preds$trajectory_diff))))

# ============================================================================
# ANALYSIS 1: TRAJECTORY VS ELO ACCURACY
# ============================================================================

cat("\n==================================================\n")
cat("TRAJECTORY VS ELO ACCURACY\n")
cat("==================================================\n\n")

# Does trajectory predict Elo accuracy?
preds_with_traj <- preds %>% filter(!is.na(trajectory_diff))

cat(sprintf("Matches with trajectory data: %d\n\n", nrow(preds_with_traj)))

# Bucket by trajectory differential
preds_with_traj %>%
  mutate(
    traj_bucket = cut(trajectory_diff,
                      breaks = c(-1, -0.2, -0.1, 0, 0.1, 0.2, 1),
                      labels = c("<-20%", "-20 to -10%", "-10 to 0%",
                                "0 to +10%", "+10 to +20%", ">+20%"))
  ) %>%
  group_by(traj_bucket) %>%
  summarise(
    n = n(),
    elo_accuracy = mean(elo_correct),
    avg_odds = mean(elo_pick_odds),
    roi = mean(profit),
    .groups = "drop"
  ) %>%
  mutate(
    elo_accuracy = sprintf("%.1f%%", 100 * elo_accuracy),
    roi = sprintf("%+.2f%%", 100 * roi)
  ) %>%
  print()

# ============================================================================
# ANALYSIS 2: RISING PLAYERS
# ============================================================================

cat("\n==================================================\n")
cat("RISING PLAYERS (Trajectory > +10%)\n")
cat("==================================================\n\n")

# When Elo pick is rising (trajectory > 0.1)
rising <- preds_with_traj %>% filter(trajectory_diff > 0.1)

cat(sprintf("N: %d\n", nrow(rising)))
cat(sprintf("Elo accuracy: %.1f%%\n", 100 * mean(rising$elo_correct)))
cat(sprintf("Avg odds: %.2f\n", mean(rising$elo_pick_odds)))
cat(sprintf("Breakeven: %.1f%%\n", 100 / mean(rising$elo_pick_odds)))
cat(sprintf("ROI: %+.2f%%\n", 100 * mean(rising$profit)))

# By year
cat("\nBy year:\n")
rising %>%
  group_by(year) %>%
  summarise(n = n(), accuracy = mean(elo_correct), roi = mean(profit), .groups = "drop") %>%
  mutate(accuracy = sprintf("%.1f%%", 100 * accuracy), roi = sprintf("%+.2f%%", 100 * roi)) %>%
  print()

# ============================================================================
# ANALYSIS 3: FALLING PLAYERS
# ============================================================================

cat("\n==================================================\n")
cat("FALLING PLAYERS (Trajectory < -10%)\n")
cat("==================================================\n\n")

# When Elo pick is falling (trajectory < -0.1)
falling <- preds_with_traj %>% filter(trajectory_diff < -0.1)

cat(sprintf("N: %d\n", nrow(falling)))
cat(sprintf("Elo accuracy: %.1f%%\n", 100 * mean(falling$elo_correct)))
cat(sprintf("Avg odds: %.2f\n", mean(falling$elo_pick_odds)))
cat(sprintf("Breakeven: %.1f%%\n", 100 / mean(falling$elo_pick_odds)))
cat(sprintf("ROI: %+.2f%%\n", 100 * mean(falling$profit)))

# ============================================================================
# ANALYSIS 4: BET AGAINST FALLING ELO PICKS
# ============================================================================

cat("\n==================================================\n")
cat("CONTRARIAN: BET AGAINST FALLING ELO PICKS\n")
cat("==================================================\n\n")

# When Elo pick is falling, bet on opponent
contrarian <- falling %>%
  mutate(
    contrarian_pick = ifelse(elo_pick == winner, loser, winner),
    contrarian_odds = ifelse(elo_pick == winner, 1/mkt_prob_w * (1 - mkt_prob_w), 1/(1-mkt_prob_w) * mkt_prob_w),
    # Actually, opponent odds
    contrarian_odds = ifelse(elo_pick == winner,
                             1 / (1 - mkt_prob_w) * (mkt_prob_w + (1 - mkt_prob_w)),  # need actual odds
                             1 / mkt_prob_w * (mkt_prob_w + (1 - mkt_prob_w)))
  )

# Simpler: opponent won when Elo pick lost
contrarian_wins <- sum(!falling$elo_correct)
contrarian_n <- nrow(falling)

cat(sprintf("N: %d\n", contrarian_n))
cat(sprintf("Contrarian win rate: %.1f%%\n", 100 * contrarian_wins / contrarian_n))

# We need actual opponent odds - let's recalculate
falling <- falling %>%
  mutate(
    opp_odds = ifelse(elo_pick == winner,
                      1 / (1 - mkt_prob_w),  # Loser odds (approx)
                      1 / mkt_prob_w),       # Winner odds (approx)
    contrarian_won = !elo_correct,
    contrarian_profit = ifelse(contrarian_won, opp_odds - 1, -1)
  )

cat(sprintf("Avg opponent odds: %.2f\n", mean(falling$opp_odds)))
cat(sprintf("Breakeven: %.1f%%\n", 100 / mean(falling$opp_odds)))
cat(sprintf("Contrarian ROI: %+.2f%%\n", 100 * mean(falling$contrarian_profit)))

# ============================================================================
# ANALYSIS 5: MOMENTUM SIGNAL
# ============================================================================

cat("\n==================================================\n")
cat("ELO MOMENTUM ANALYSIS\n")
cat("==================================================\n\n")

# Elo momentum = rating change over last 10 matches
preds_momentum <- preds %>% filter(!is.na(momentum_diff))

# Bucket by momentum
preds_momentum %>%
  mutate(
    mom_bucket = cut(momentum_diff,
                     breaks = c(-500, -100, -50, 0, 50, 100, 500),
                     labels = c("<-100", "-100 to -50", "-50 to 0",
                               "0 to +50", "+50 to +100", ">+100"))
  ) %>%
  group_by(mom_bucket) %>%
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
# ANALYSIS 6: COMBINED TRAJECTORY + MARKET EDGE
# ============================================================================

cat("\n==================================================\n")
cat("COMBINED: RISING TRAJECTORY + MARKET UNDERPRICING\n")
cat("==================================================\n\n")

# Elo pick is rising AND Elo assigns higher prob than market
combined <- preds_with_traj %>%
  mutate(
    elo_pick_prob = ifelse(elo_pick == winner, calibrated_prob_w, 1 - calibrated_prob_w),
    mkt_pick_prob = ifelse(elo_pick == winner, mkt_prob_w, 1 - mkt_prob_w),
    edge = elo_pick_prob - mkt_pick_prob
  ) %>%
  filter(trajectory_diff > 0.1, edge > 0)

cat(sprintf("N: %d\n", nrow(combined)))
if (nrow(combined) > 30) {
  cat(sprintf("Elo accuracy: %.1f%%\n", 100 * mean(combined$elo_correct)))
  cat(sprintf("Avg odds: %.2f\n", mean(combined$elo_pick_odds)))
  cat(sprintf("ROI: %+.2f%%\n", 100 * mean(combined$profit)))

  cat("\nBy year:\n")
  combined %>%
    group_by(year) %>%
    summarise(n = n(), roi = mean(profit), .groups = "drop") %>%
    mutate(roi = sprintf("%+.2f%%", 100 * roi)) %>%
    print()
}

# ============================================================================
# SUMMARY
# ============================================================================

cat("\n==================================================\n")
cat("SUMMARY: TRAJECTORY SIGNALS\n")
cat("==================================================\n\n")

signals <- list(
  list(name = "All matches", filter = quote(TRUE)),
  list(name = "Rising trajectory (>+10%)", filter = quote(trajectory_diff > 0.1)),
  list(name = "Strong rising (>+20%)", filter = quote(trajectory_diff > 0.2)),
  list(name = "Falling trajectory (<-10%)", filter = quote(trajectory_diff < -0.1)),
  list(name = "Strong falling (<-20%)", filter = quote(trajectory_diff < -0.2)),
  list(name = "High momentum (>+100)", filter = quote(momentum_diff > 100)),
  list(name = "Negative momentum (<-100)", filter = quote(momentum_diff < -100))
)

for (sig in signals) {
  subset <- preds_with_traj %>% filter(eval(sig$filter))
  if (nrow(subset) >= 50) {
    yearly <- subset %>%
      group_by(year) %>%
      summarise(roi = mean(profit), .groups = "drop")
    pos_years <- sum(yearly$roi > 0)

    cat(sprintf("%-30s N=%4d, Acc=%.1f%%, ROI=%+.2f%%, %d/4 pos\n",
                sig$name, nrow(subset),
                100*mean(subset$elo_correct), 100*mean(subset$profit), pos_years))
  }
}

# Save results
saveRDS(preds, "data/processed/trajectory_analysis.rds")
cat("\n\nResults saved to data/processed/trajectory_analysis.rds\n")

