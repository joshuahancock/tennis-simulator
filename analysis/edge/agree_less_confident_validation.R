# Multi-Year Validation: "Agree But Less Confident" Signal
#
# Signal definition: Elo agrees with market favorite, but Elo assigns
# 0-5pp LOWER probability than market (Elo is skeptical of favorite)
#
# Original finding (H1 2024): N=256, Win rate=72.3%, ROI=+6.4%, p=0.041
#
# This script validates across 2021-2024 (H1 periods) to determine if
# the signal is consistent or driven by one period.

library(tidyverse)
source("src/backtesting/07_elo_ratings.R")

cat("=== MULTI-YEAR VALIDATION: AGREE BUT LESS CONFIDENT ===\n\n")

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
# GENERATE PREDICTIONS FOR ALL YEARS
# ============================================================================

generate_predictions <- function(year, hist_matches, name_map, period = "H1") {
  elo_cutoff <- as.Date(sprintf("%d-01-01", year))

  prior_matches <- hist_matches %>%
    filter(match_date < elo_cutoff) %>%
    filter(!is.na(winner_name), !is.na(loser_name))

  elo_db <- build_elo_db_from_matches(prior_matches, verbose = FALSE)

  betting_file <- sprintf("data/raw/tennis_betting/%d.xlsx", year)
  betting <- readxl::read_xlsx(betting_file) %>%
    mutate(Date = as.Date(Date))

  # Filter to H1 or H2
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

    # Market implied probabilities (vig-adjusted)
    implied_w <- 1 / m$PSW
    implied_l <- 1 / m$PSL
    total_implied <- implied_w + implied_l
    mkt_prob_w <- implied_w / total_implied
    mkt_prob_l <- implied_l / total_implied

    # Market favorite
    mkt_fav <- ifelse(m$PSW < m$PSL, m$winner, m$loser)
    mkt_fav_odds <- min(m$PSW, m$PSL)

    # Elo pick
    elo_pick <- ifelse(elo_prob_w > 0.5, m$winner, m$loser)

    # Confidence measures
    elo_conf <- max(elo_prob_w, 1 - elo_prob_w)
    mkt_conf <- max(mkt_prob_w, mkt_prob_l)

    # Agreement and confidence difference
    agrees <- (elo_pick == mkt_fav)
    conf_diff <- elo_conf - mkt_conf  # Positive = Elo more confident

    results[[i]] <- tibble(
      date = m$Date,
      year = year,
      period = period,
      winner = m$winner,
      loser = m$loser,
      surface = surface,
      w_odds = m$PSW,
      l_odds = m$PSL,
      elo_prob_w = elo_prob_w,
      mkt_prob_w = mkt_prob_w,
      mkt_fav = mkt_fav,
      mkt_fav_odds = mkt_fav_odds,
      elo_pick = elo_pick,
      elo_conf = elo_conf,
      mkt_conf = mkt_conf,
      conf_diff = conf_diff,
      agrees = agrees,
      mkt_fav_won = (mkt_fav == m$winner),
      elo_correct = (elo_pick == m$winner)
    )

    # Rolling Elo update
    update <- elo_update(w_info$elo, l_info$elo)
    idx_w <- which(elo_db$overall$player == m$winner)
    idx_l <- which(elo_db$overall$player == m$loser)
    if (length(idx_w) > 0) elo_db$overall$elo[idx_w] <- update$new_winner_elo
    if (length(idx_l) > 0) elo_db$overall$elo[idx_l] <- update$new_loser_elo
  }

  bind_rows(results)
}

# Generate predictions for 2021-2024 H1
cat("Generating Elo predictions for H1 2021-2024...\n")
name_map <- create_name_lookup(hist_matches)

all_preds <- list()
for (year in 2021:2024) {
  cat(sprintf("  H1 %d...\n", year))
  all_preds[[sprintf("H1_%d", year)]] <- generate_predictions(year, hist_matches, name_map, "H1")
}

# Also generate H2 2024 for out-of-sample validation
cat("  H2 2024 (out-of-sample)...\n")
all_preds[["H2_2024"]] <- generate_predictions(2024, hist_matches, name_map, "H2")

preds <- bind_rows(all_preds, .id = "period_year")
cat(sprintf("\nTotal predictions: %d\n", nrow(preds)))

# ============================================================================
# DEFINE THE SIGNAL
# ============================================================================

# "Agree but less confident": Elo agrees with market but is 0-5pp less confident
preds <- preds %>%
  mutate(
    signal = agrees & conf_diff >= -0.05 & conf_diff < 0,

    # Betting on market favorite when signal is true
    bet_won = mkt_fav_won,
    bet_odds = mkt_fav_odds,
    profit = ifelse(bet_won, bet_odds - 1, -1)
  )

# ============================================================================
# VALIDATION BY YEAR
# ============================================================================

cat("\n========================================\n")
cat("SIGNAL: AGREE BUT LESS CONFIDENT (0-5pp)\n")
cat("========================================\n\n")

cat("Definition: Elo agrees with market favorite, but Elo's confidence\n")
cat("is 0-5pp LOWER than market's implied probability.\n\n")

# H1 periods (training/validation)
h1_preds <- preds %>% filter(str_starts(period_year, "H1"))

cat("BY YEAR (H1 periods):\n\n")

yearly_results <- h1_preds %>%
  filter(signal) %>%
  group_by(period_year) %>%
  summarise(
    n = n(),
    win_rate = mean(bet_won),
    avg_odds = mean(bet_odds),
    roi = mean(profit),
    .groups = "drop"
  ) %>%
  mutate(
    breakeven = 1 / avg_odds,
    edge_vs_breakeven = win_rate - breakeven
  )

yearly_results %>%
  mutate(
    win_rate = sprintf("%.1f%%", 100 * win_rate),
    roi = sprintf("%+.1f%%", 100 * roi),
    breakeven = sprintf("%.1f%%", 100 * breakeven),
    edge = sprintf("%+.1fpp", 100 * edge_vs_breakeven)
  ) %>%
  select(period_year, n, win_rate, breakeven, edge, roi) %>%
  print()

# Pooled H1 results
cat("\nPOOLED H1 2021-2024:\n")
pooled <- h1_preds %>% filter(signal)
n_pooled <- nrow(pooled)
win_rate_pooled <- mean(pooled$bet_won)
avg_odds_pooled <- mean(pooled$bet_odds)
roi_pooled <- mean(pooled$profit)
breakeven_pooled <- 1 / avg_odds_pooled

cat(sprintf("  N: %d matches\n", n_pooled))
cat(sprintf("  Win rate: %.1f%%\n", 100 * win_rate_pooled))
cat(sprintf("  Breakeven: %.1f%%\n", 100 * breakeven_pooled))
cat(sprintf("  Edge: %+.1fpp\n", 100 * (win_rate_pooled - breakeven_pooled)))
cat(sprintf("  ROI: %+.1f%%\n", 100 * roi_pooled))

# Statistical test
if (n_pooled > 30) {
  test <- binom.test(sum(pooled$bet_won), n_pooled, p = breakeven_pooled, alternative = "greater")
  cat(sprintf("  p-value (vs breakeven): %.4f\n", test$p.value))
}

# ============================================================================
# OUT-OF-SAMPLE: H2 2024
# ============================================================================

cat("\n========================================\n")
cat("OUT-OF-SAMPLE VALIDATION: H2 2024\n")
cat("========================================\n\n")

h2_2024 <- preds %>% filter(period_year == "H2_2024", signal)

if (nrow(h2_2024) > 0) {
  cat(sprintf("N: %d matches\n", nrow(h2_2024)))
  cat(sprintf("Win rate: %.1f%%\n", 100 * mean(h2_2024$bet_won)))
  cat(sprintf("Avg odds: %.2f\n", mean(h2_2024$bet_odds)))
  cat(sprintf("ROI: %+.1f%%\n", 100 * mean(h2_2024$profit)))

  if (nrow(h2_2024) > 30) {
    breakeven_h2 <- 1 / mean(h2_2024$bet_odds)
    test_h2 <- binom.test(sum(h2_2024$bet_won), nrow(h2_2024), p = breakeven_h2, alternative = "greater")
    cat(sprintf("p-value: %.4f\n", test_h2$p.value))
  }
} else {
  cat("No matches in H2 2024 matching signal criteria.\n")
}

# ============================================================================
# VARIATIONS: TEST DIFFERENT CONFIDENCE RANGES
# ============================================================================

cat("\n========================================\n")
cat("SENSITIVITY: DIFFERENT CONFIDENCE RANGES\n")
cat("========================================\n\n")

ranges <- list(
  list(name = "0 to -5pp (original)", lower = -0.05, upper = 0),
  list(name = "0 to -3pp", lower = -0.03, upper = 0),
  list(name = "-3pp to -7pp", lower = -0.07, upper = -0.03),
  list(name = "-5pp to -10pp", lower = -0.10, upper = -0.05),
  list(name = "0 to -10pp (wider)", lower = -0.10, upper = 0)
)

sensitivity_results <- list()

for (r in ranges) {
  subset <- h1_preds %>%
    filter(agrees, conf_diff >= r$lower, conf_diff < r$upper)

  if (nrow(subset) >= 30) {
    sensitivity_results[[r$name]] <- tibble(
      range = r$name,
      n = nrow(subset),
      win_rate = mean(subset$mkt_fav_won),
      avg_odds = mean(subset$mkt_fav_odds),
      roi = mean(ifelse(subset$mkt_fav_won, subset$mkt_fav_odds - 1, -1))
    )
  }
}

bind_rows(sensitivity_results) %>%
  mutate(
    win_rate = sprintf("%.1f%%", 100 * win_rate),
    roi = sprintf("%+.1f%%", 100 * roi)
  ) %>%
  print()

# ============================================================================
# BY ODDS RANGE (SUB-SEGMENTS)
# ============================================================================

cat("\n========================================\n")
cat("SUB-SEGMENTS BY ODDS RANGE\n")
cat("========================================\n\n")

h1_signal <- h1_preds %>% filter(signal)

h1_signal %>%
  mutate(
    odds_bucket = cut(mkt_fav_odds,
                      breaks = c(1.0, 1.4, 1.6, 1.8, 2.0, 2.5, 10),
                      labels = c("1.0-1.4", "1.4-1.6", "1.6-1.8", "1.8-2.0", "2.0-2.5", "2.5+"))
  ) %>%
  group_by(odds_bucket) %>%
  summarise(
    n = n(),
    win_rate = mean(bet_won),
    avg_odds = mean(bet_odds),
    roi = mean(profit),
    .groups = "drop"
  ) %>%
  mutate(
    win_rate = sprintf("%.1f%%", 100 * win_rate),
    roi = sprintf("%+.1f%%", 100 * roi)
  ) %>%
  print()

# The 1.7-2.0 range from original analysis
cat("\nOdds 1.7-2.0 (original best sub-segment):\n")
best_subset <- h1_signal %>% filter(mkt_fav_odds >= 1.7, mkt_fav_odds <= 2.0)
if (nrow(best_subset) >= 20) {
  cat(sprintf("  N: %d\n", nrow(best_subset)))
  cat(sprintf("  Win rate: %.1f%%\n", 100 * mean(best_subset$bet_won)))
  cat(sprintf("  ROI: %+.1f%%\n", 100 * mean(best_subset$profit)))

  # By year
  cat("\n  By year:\n")
  best_subset %>%
    group_by(year) %>%
    summarise(n = n(), roi = mean(profit), .groups = "drop") %>%
    mutate(roi = sprintf("%+.1f%%", 100 * roi)) %>%
    print()
}

# ============================================================================
# SAVE RESULTS
# ============================================================================

validation_results <- list(
  all_preds = preds,
  yearly_results = yearly_results,
  pooled_n = n_pooled,
  pooled_roi = roi_pooled,
  pooled_win_rate = win_rate_pooled
)

saveRDS(validation_results, "data/processed/agree_less_confident_validation.rds")

cat("\n========================================\n")
cat("SUMMARY\n")
cat("========================================\n\n")

# Count positive years
positive_years <- sum(yearly_results$roi > 0)
total_years <- nrow(yearly_results)

cat(sprintf("Years with positive ROI: %d / %d\n", positive_years, total_years))
cat(sprintf("Pooled ROI: %+.1f%%\n", 100 * roi_pooled))
cat(sprintf("Consistent signal: %s\n",
            ifelse(positive_years >= 3, "YES (3+ years positive)", "NO (< 3 years positive)")))

cat("\nResults saved to data/processed/agree_less_confident_validation.rds\n")
