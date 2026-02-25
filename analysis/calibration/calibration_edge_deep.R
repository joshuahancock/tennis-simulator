# Deep Dive: Calibration-Based Edge Exploitation
#
# The calibration table shows:
# - Elo underestimates underdogs (predicts 20.3%, actual 26.8% = +6.5pp)
# - Elo overestimates favorites (predicts 76.9%, actual 70.7% = -6.2pp)
#
# Hypothesis: Bet on underdogs where Platt-corrected Elo probability
# EXCEEDS the market-implied probability. This exploits the systematic
# underdog underestimation.

library(tidyverse)
source("src/backtesting/07_elo_ratings.R")

cat("=== CALIBRATION-BASED EDGE: DEEP DIVE ===\n\n")

# Load Platt model and predictions
platt_results <- readRDS("data/processed/platt_scaling_results.rds")
platt_a <- platt_results$coefficients[1]
platt_b <- platt_results$coefficients[2]

hist_matches <- readRDS("data/processed/atp_matches_aligned.rds")

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

# ============================================================================
# GENERATE PREDICTIONS WITH CALIBRATION
# ============================================================================

generate_calibrated_preds <- function(year, hist_matches, name_map, platt_a, platt_b, period = "full") {
  elo_cutoff <- as.Date(sprintf("%d-01-01", year))

  prior_matches <- hist_matches %>%
    filter(match_date < elo_cutoff) %>%
    filter(!is.na(winner_name), !is.na(loser_name))

  elo_db <- build_elo_db_from_matches(prior_matches, verbose = FALSE)

  betting_file <- sprintf("data/raw/tennis_betting/%d.xlsx", year)
  betting <- readxl::read_xlsx(betting_file) %>%
    mutate(Date = as.Date(Date))

  if (period == "H1") {
    betting <- betting %>% filter(Date < as.Date(sprintf("%d-07-01", year)))
  } else if (period == "H2") {
    betting <- betting %>% filter(Date >= as.Date(sprintf("%d-07-01", year)))
  }

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
    surface <- m$Surface

    w_info <- get_player_elo(m$winner, surface, elo_db)
    l_info <- get_player_elo(m$loser, surface, elo_db)
    elo_prob_w <- elo_expected_prob(w_info$elo, l_info$elo)

    # Apply Platt scaling
    elo_fav_prob <- max(elo_prob_w, 1 - elo_prob_w)
    elo_logit <- qlogis(pmax(0.01, pmin(0.99, elo_fav_prob)))
    calibrated_fav_prob <- plogis(platt_a + platt_b * elo_logit)
    calibrated_prob_w <- ifelse(elo_prob_w > 0.5, calibrated_fav_prob, 1 - calibrated_fav_prob)

    # Market probabilities (vig-adjusted)
    implied_w <- 1 / m$PSW
    implied_l <- 1 / m$PSL
    mkt_prob_w <- implied_w / (implied_w + implied_l)
    mkt_prob_l <- implied_l / (implied_w + implied_l)

    # Market favorite/underdog
    mkt_fav <- ifelse(m$PSW < m$PSL, m$winner, m$loser)
    mkt_dog <- ifelse(m$PSW < m$PSL, m$loser, m$winner)
    mkt_fav_odds <- min(m$PSW, m$PSL)
    mkt_dog_odds <- max(m$PSW, m$PSL)
    mkt_dog_prob <- 1 - max(mkt_prob_w, mkt_prob_l)

    # Calibrated probability for the underdog
    calibrated_dog_prob <- ifelse(mkt_dog == m$winner, calibrated_prob_w, 1 - calibrated_prob_w)

    # Edge on underdog = calibrated prob - market prob
    dog_edge <- calibrated_dog_prob - mkt_dog_prob

    results[[i]] <- tibble(
      date = m$Date,
      year = year,
      winner = m$winner,
      loser = m$loser,
      surface = surface,
      w_odds = m$PSW,
      l_odds = m$PSL,
      elo_prob_w = elo_prob_w,
      calibrated_prob_w = calibrated_prob_w,
      mkt_prob_w = mkt_prob_w,
      mkt_fav = mkt_fav,
      mkt_dog = mkt_dog,
      mkt_dog_odds = mkt_dog_odds,
      mkt_dog_prob = mkt_dog_prob,
      calibrated_dog_prob = calibrated_dog_prob,
      dog_edge = dog_edge,
      dog_won = (mkt_dog == m$winner)
    )

    # Rolling update
    update <- elo_update(w_info$elo, l_info$elo)
    idx_w <- which(elo_db$overall$player == m$winner)
    idx_l <- which(elo_db$overall$player == m$loser)
    if (length(idx_w) > 0) elo_db$overall$elo[idx_w] <- update$new_winner_elo
    if (length(idx_l) > 0) elo_db$overall$elo[idx_l] <- update$new_loser_elo
  }

  bind_rows(results)
}

# ============================================================================
# GENERATE ALL PREDICTIONS
# ============================================================================

cat("Generating calibrated predictions 2021-2024...\n")
name_map <- create_name_lookup(hist_matches)

all_preds <- list()
for (year in 2021:2024) {
  cat(sprintf("  %d...\n", year))
  all_preds[[as.character(year)]] <- generate_calibrated_preds(
    year, hist_matches, name_map, platt_a, platt_b, period = "full"
  )
}

preds <- bind_rows(all_preds)
cat(sprintf("\nTotal matches: %d\n", nrow(preds)))

# ============================================================================
# STRATEGY 1: BET ON UNDERDOG WHEN CALIBRATED EDGE > 0
# ============================================================================

cat("\n========================================\n")
cat("STRATEGY 1: BET UNDERDOG WHEN CALIBRATED PROB > MARKET\n")
cat("========================================\n\n")

# When calibrated probability for underdog exceeds market's
preds <- preds %>%
  mutate(
    dog_profit = ifelse(dog_won, mkt_dog_odds - 1, -1)
  )

# Test different edge thresholds
edge_thresholds <- c(0, 0.02, 0.05, 0.08, 0.10)

cat("By edge threshold:\n\n")
for (thresh in edge_thresholds) {
  subset <- preds %>% filter(dog_edge > thresh)
  if (nrow(subset) >= 50) {
    win_rate <- mean(subset$dog_won)
    roi <- mean(subset$dog_profit)
    avg_odds <- mean(subset$mkt_dog_odds)
    breakeven <- 1 / avg_odds

    cat(sprintf("Edge > %.0f%%: N=%d, Win=%.1f%%, BE=%.1f%%, ROI=%+.2f%%\n",
                100 * thresh, nrow(subset), 100 * win_rate, 100 * breakeven, 100 * roi))
  }
}

# Best threshold analysis by year
cat("\n\nEdge > 5% by year:\n")
preds %>%
  filter(dog_edge > 0.05) %>%
  group_by(year) %>%
  summarise(
    n = n(),
    win_rate = mean(dog_won),
    avg_odds = mean(mkt_dog_odds),
    roi = mean(dog_profit),
    .groups = "drop"
  ) %>%
  mutate(
    win_rate = sprintf("%.1f%%", 100 * win_rate),
    roi = sprintf("%+.2f%%", 100 * roi)
  ) %>%
  print()

# ============================================================================
# STRATEGY 2: FOCUS ON SPECIFIC ODDS RANGES
# ============================================================================

cat("\n========================================\n")
cat("STRATEGY 2: UNDERDOG EDGE BY ODDS RANGE\n")
cat("========================================\n\n")

# Where calibrated edge > 0
edge_dogs <- preds %>% filter(dog_edge > 0)

edge_dogs %>%
  mutate(
    odds_bucket = cut(mkt_dog_odds,
                      breaks = c(1, 2, 2.5, 3, 4, 5, 10),
                      labels = c("1.0-2.0", "2.0-2.5", "2.5-3.0", "3.0-4.0", "4.0-5.0", "5.0+"))
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
    edge_vs_be = win_rate - breakeven,
    win_rate = sprintf("%.1f%%", 100 * win_rate),
    breakeven = sprintf("%.1f%%", 100 * breakeven),
    roi = sprintf("%+.2f%%", 100 * roi)
  ) %>%
  print()

# ============================================================================
# STRATEGY 3: COMBINE EDGE + ODDS RANGE
# ============================================================================

cat("\n========================================\n")
cat("STRATEGY 3: EDGE > 5% + ODDS 2.0-3.0\n")
cat("========================================\n\n")

focused <- preds %>%
  filter(dog_edge > 0.05, mkt_dog_odds >= 2.0, mkt_dog_odds < 3.0)

if (nrow(focused) >= 30) {
  cat(sprintf("N: %d\n", nrow(focused)))
  cat(sprintf("Win rate: %.1f%%\n", 100 * mean(focused$dog_won)))
  cat(sprintf("Avg odds: %.2f\n", mean(focused$mkt_dog_odds)))
  cat(sprintf("Breakeven: %.1f%%\n", 100 / mean(focused$mkt_dog_odds)))
  cat(sprintf("ROI: %+.2f%%\n", 100 * mean(focused$dog_profit)))

  cat("\nBy year:\n")
  focused %>%
    group_by(year) %>%
    summarise(n = n(), roi = mean(dog_profit), .groups = "drop") %>%
    mutate(roi = sprintf("%+.2f%%", 100 * roi)) %>%
    print()
}

# ============================================================================
# STRATEGY 4: SURFACE-SPECIFIC CALIBRATION
# ============================================================================

cat("\n========================================\n")
cat("STRATEGY 4: SURFACE-SPECIFIC PATTERNS\n")
cat("========================================\n\n")

# Where calibrated edge > 0, by surface
edge_dogs %>%
  group_by(surface) %>%
  summarise(
    n = n(),
    win_rate = mean(dog_won),
    avg_odds = mean(mkt_dog_odds),
    roi = mean(dog_profit),
    .groups = "drop"
  ) %>%
  mutate(
    win_rate = sprintf("%.1f%%", 100 * win_rate),
    roi = sprintf("%+.2f%%", 100 * roi)
  ) %>%
  print()

# Clay underdogs with edge
cat("\nClay underdogs with calibrated edge > 5%:\n")
clay_dogs <- preds %>% filter(surface == "Clay", dog_edge > 0.05)
if (nrow(clay_dogs) >= 30) {
  cat(sprintf("  N: %d\n", nrow(clay_dogs)))
  cat(sprintf("  Win rate: %.1f%%\n", 100 * mean(clay_dogs$dog_won)))
  cat(sprintf("  ROI: %+.2f%%\n", 100 * mean(clay_dogs$dog_profit)))

  cat("\n  By year:\n")
  clay_dogs %>%
    group_by(year) %>%
    summarise(n = n(), roi = mean(dog_profit), .groups = "drop") %>%
    mutate(roi = sprintf("%+.2f%%", 100 * roi)) %>%
    print()
}

# ============================================================================
# RAW VS CALIBRATED COMPARISON
# ============================================================================

cat("\n========================================\n")
cat("RAW ELO VS CALIBRATED ELO ON UNDERDOGS\n")
cat("========================================\n\n")

# Raw Elo edge on underdog
preds <- preds %>%
  mutate(
    raw_dog_prob = ifelse(mkt_dog == winner, elo_prob_w, 1 - elo_prob_w),
    raw_dog_edge = raw_dog_prob - mkt_dog_prob
  )

cat("When raw Elo says underdog is underpriced (raw edge > 0):\n")
raw_edge_dogs <- preds %>% filter(raw_dog_edge > 0)
cat(sprintf("  N: %d\n", nrow(raw_edge_dogs)))
cat(sprintf("  Win rate: %.1f%%\n", 100 * mean(raw_edge_dogs$dog_won)))
cat(sprintf("  ROI: %+.2f%%\n\n", 100 * mean(raw_edge_dogs$dog_profit)))

cat("When CALIBRATED Elo says underdog is underpriced (calibrated edge > 0):\n")
cat(sprintf("  N: %d\n", nrow(edge_dogs)))
cat(sprintf("  Win rate: %.1f%%\n", 100 * mean(edge_dogs$dog_won)))
cat(sprintf("  ROI: %+.2f%%\n", 100 * mean(edge_dogs$dog_profit)))

# ============================================================================
# SUMMARY
# ============================================================================

cat("\n========================================\n")
cat("SUMMARY: BEST UNDERDOG STRATEGIES\n")
cat("========================================\n\n")

# Find best performing subset
best_subsets <- list()

# Test various combinations
combinations <- list(
  list(name = "Edge > 0%", filter = quote(dog_edge > 0)),
  list(name = "Edge > 2%", filter = quote(dog_edge > 0.02)),
  list(name = "Edge > 5%", filter = quote(dog_edge > 0.05)),
  list(name = "Edge > 5% + Odds 2-3", filter = quote(dog_edge > 0.05 & mkt_dog_odds >= 2 & mkt_dog_odds < 3)),
  list(name = "Edge > 5% + Clay", filter = quote(dog_edge > 0.05 & surface == "Clay")),
  list(name = "Edge > 8%", filter = quote(dog_edge > 0.08)),
  list(name = "Edge > 10%", filter = quote(dog_edge > 0.10))
)

for (combo in combinations) {
  subset <- preds %>% filter(eval(combo$filter))
  if (nrow(subset) >= 50) {
    # Check year consistency
    yearly <- subset %>%
      group_by(year) %>%
      summarise(roi = mean(dog_profit), .groups = "drop")

    positive_years <- sum(yearly$roi > 0)

    best_subsets[[combo$name]] <- tibble(
      strategy = combo$name,
      n = nrow(subset),
      win_rate = mean(subset$dog_won),
      roi = mean(subset$dog_profit),
      positive_years = positive_years
    )
  }
}

bind_rows(best_subsets) %>%
  arrange(desc(roi)) %>%
  mutate(
    win_rate = sprintf("%.1f%%", 100 * win_rate),
    roi = sprintf("%+.2f%%", 100 * roi),
    consistency = sprintf("%d/4", positive_years)
  ) %>%
  select(strategy, n, win_rate, roi, consistency) %>%
  print()

saveRDS(preds, "data/processed/calibration_edge_deep.rds")
cat("\nResults saved to data/processed/calibration_edge_deep.rds\n")
