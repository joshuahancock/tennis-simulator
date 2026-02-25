# High Odds Underdog Validation
#
# 2025 OOS showed strong ROI in higher odds ranges:
# - Odds 3.0-4.0: +23.67% (N=129)
# - Odds 4.0+: +24.24% (N=98)
#
# Question: Is this consistent across 2021-2024, or 2025-specific?

library(tidyverse)
source("src/backtesting/07_elo_ratings.R")

cat("=== HIGH ODDS UNDERDOG VALIDATION ===\n\n")

# Load data
hist_matches <- readRDS("data/processed/atp_matches_aligned.rds")
platt_results <- readRDS("data/processed/platt_scaling_results.rds")
platt_a <- platt_results$coefficients[1]
platt_b <- platt_results$coefficients[2]

cat(sprintf("Platt coefficients: a=%.4f, b=%.4f\n\n", platt_a, platt_b))

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

# Generate predictions for a year
generate_year_preds <- function(year, hist_matches, name_map, platt_a, platt_b) {
  elo_cutoff <- as.Date(sprintf("%d-01-01", year))

  prior_matches <- hist_matches %>%
    filter(match_date < elo_cutoff) %>%
    filter(!is.na(winner_name), !is.na(loser_name))

  elo_db <- build_elo_db_from_matches(prior_matches, verbose = FALSE)

  betting_file <- sprintf("data/raw/tennis_betting/%d.xlsx", year)
  betting <- readxl::read_xlsx(betting_file) %>%
    mutate(Date = as.Date(Date))

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

    # Platt scaling
    elo_fav_prob <- max(elo_prob_w, 1 - elo_prob_w)
    elo_logit <- qlogis(pmax(0.01, pmin(0.99, elo_fav_prob)))
    calibrated_fav_prob <- plogis(platt_a + platt_b * elo_logit)
    calibrated_prob_w <- ifelse(elo_prob_w > 0.5, calibrated_fav_prob, 1 - calibrated_fav_prob)

    # Market info
    implied_w <- 1 / m$PSW
    implied_l <- 1 / m$PSL
    mkt_prob_w <- implied_w / (implied_w + implied_l)

    mkt_dog <- ifelse(m$PSW < m$PSL, m$loser, m$winner)
    mkt_dog_odds <- max(m$PSW, m$PSL)
    mkt_dog_prob <- 1 - max(mkt_prob_w, 1 - mkt_prob_w)
    calibrated_dog_prob <- ifelse(mkt_dog == m$winner, calibrated_prob_w, 1 - calibrated_prob_w)
    dog_edge <- calibrated_dog_prob - mkt_dog_prob

    results[[i]] <- tibble(
      date = m$Date,
      year = year,
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

  bind_rows(results)
}

# Generate predictions for all years
cat("Generating predictions 2021-2024...\n")
all_preds <- list()
for (year in 2021:2024) {
  cat(sprintf("  %d...\n", year))
  all_preds[[as.character(year)]] <- generate_year_preds(year, hist_matches, name_map, platt_a, platt_b)
}
preds <- bind_rows(all_preds)
cat(sprintf("\nTotal matches: %d\n\n", nrow(preds)))

# ============================================================================
# TEST HIGH ODDS RANGES (Edge 0-10%)
# ============================================================================

cat("==================================================\n")
cat("HIGH ODDS RANGES (Edge 0-10%) BY YEAR\n")
cat("==================================================\n\n")

# Odds 3.0-4.0
cat("ODDS 3.0-4.0:\n")
cat("-------------\n")
preds %>%
  filter(dog_edge > 0, dog_edge <= 0.10, mkt_dog_odds >= 3.0, mkt_dog_odds < 4.0) %>%
  group_by(year) %>%
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

# Pooled 3.0-4.0
subset_3_4 <- preds %>%
  filter(dog_edge > 0, dog_edge <= 0.10, mkt_dog_odds >= 3.0, mkt_dog_odds < 4.0)

cat(sprintf("\nPooled 2021-2024: N=%d, Win=%.1f%%, ROI=%+.2f%%\n",
            nrow(subset_3_4), 100*mean(subset_3_4$dog_won), 100*mean(subset_3_4$dog_profit)))

# Statistical test
if (nrow(subset_3_4) > 30) {
  wins <- sum(subset_3_4$dog_won)
  n <- nrow(subset_3_4)
  breakeven <- 1 / mean(subset_3_4$mkt_dog_odds)
  test <- binom.test(wins, n, p = breakeven, alternative = "greater")
  cat(sprintf("p-value vs breakeven: %.4f\n", test$p.value))
}

# Odds 4.0+
cat("\n\nODDS 4.0+:\n")
cat("----------\n")
preds %>%
  filter(dog_edge > 0, dog_edge <= 0.10, mkt_dog_odds >= 4.0) %>%
  group_by(year) %>%
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

# Pooled 4.0+
subset_4plus <- preds %>%
  filter(dog_edge > 0, dog_edge <= 0.10, mkt_dog_odds >= 4.0)

cat(sprintf("\nPooled 2021-2024: N=%d, Win=%.1f%%, ROI=%+.2f%%\n",
            nrow(subset_4plus), 100*mean(subset_4plus$dog_won), 100*mean(subset_4plus$dog_profit)))

if (nrow(subset_4plus) > 30) {
  wins <- sum(subset_4plus$dog_won)
  n <- nrow(subset_4plus)
  breakeven <- 1 / mean(subset_4plus$mkt_dog_odds)
  test <- binom.test(wins, n, p = breakeven, alternative = "greater")
  cat(sprintf("p-value vs breakeven: %.4f\n", test$p.value))
}

# ============================================================================
# COMBINED 3.0+ RANGE
# ============================================================================

cat("\n\n==================================================\n")
cat("COMBINED: ODDS 3.0+ (Edge 0-10%)\n")
cat("==================================================\n\n")

preds %>%
  filter(dog_edge > 0, dog_edge <= 0.10, mkt_dog_odds >= 3.0) %>%
  group_by(year) %>%
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

subset_3plus <- preds %>%
  filter(dog_edge > 0, dog_edge <= 0.10, mkt_dog_odds >= 3.0)

cat(sprintf("\nPooled 2021-2024: N=%d, Win=%.1f%%, ROI=%+.2f%%\n",
            nrow(subset_3plus), 100*mean(subset_3plus$dog_won), 100*mean(subset_3plus$dog_profit)))

positive_years <- subset_3plus %>%
  group_by(year) %>%
  summarise(roi = mean(dog_profit), .groups = "drop") %>%
  filter(roi > 0) %>%
  nrow()

cat(sprintf("Years positive: %d/4\n", positive_years))

if (nrow(subset_3plus) > 30) {
  wins <- sum(subset_3plus$dog_won)
  n <- nrow(subset_3plus)
  breakeven <- 1 / mean(subset_3plus$mkt_dog_odds)
  test <- binom.test(wins, n, p = breakeven, alternative = "greater")
  cat(sprintf("p-value vs breakeven: %.4f\n", test$p.value))
}

# ============================================================================
# BY SURFACE (Odds 3.0+)
# ============================================================================

cat("\n\n==================================================\n")
cat("ODDS 3.0+ BY SURFACE\n")
cat("==================================================\n\n")

subset_3plus %>%
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

# ============================================================================
# EDGE THRESHOLD SENSITIVITY (Odds 3.0+)
# ============================================================================

cat("\n\n==================================================\n")
cat("EDGE THRESHOLD SENSITIVITY (Odds 3.0+)\n")
cat("==================================================\n\n")

edge_ranges <- list(
  c(0, 0.05),
  c(0, 0.10),
  c(0, 0.15),
  c(0.05, 0.10),
  c(0.05, 0.15),
  c(0.10, 0.20)
)

for (er in edge_ranges) {
  subset <- preds %>%
    filter(dog_edge > er[1], dog_edge <= er[2], mkt_dog_odds >= 3.0)

  if (nrow(subset) >= 30) {
    yearly <- subset %>%
      group_by(year) %>%
      summarise(roi = mean(dog_profit), .groups = "drop")
    pos_years <- sum(yearly$roi > 0)

    cat(sprintf("Edge %.0f-%.0f%%: N=%d, Win=%.1f%%, ROI=%+.2f%%, %d/4 positive\n",
                100*er[1], 100*er[2], nrow(subset),
                100*mean(subset$dog_won), 100*mean(subset$dog_profit), pos_years))
  }
}

# ============================================================================
# SUMMARY
# ============================================================================

cat("\n\n==================================================\n")
cat("SUMMARY: HIGH ODDS UNDERDOG STRATEGIES\n")
cat("==================================================\n\n")

cat("2021-2024 In-Sample Results:\n")
cat("----------------------------\n")

strategies <- list(
  list(name = "Odds 2.0-2.5, Edge 0-10%", min_odds = 2.0, max_odds = 2.5, min_edge = 0, max_edge = 0.10),
  list(name = "Odds 2.5-3.0, Edge 0-10%", min_odds = 2.5, max_odds = 3.0, min_edge = 0, max_edge = 0.10),
  list(name = "Odds 3.0-4.0, Edge 0-10%", min_odds = 3.0, max_odds = 4.0, min_edge = 0, max_edge = 0.10),
  list(name = "Odds 4.0+, Edge 0-10%", min_odds = 4.0, max_odds = 100, min_edge = 0, max_edge = 0.10),
  list(name = "Odds 3.0+, Edge 0-10%", min_odds = 3.0, max_odds = 100, min_edge = 0, max_edge = 0.10)
)

for (s in strategies) {
  subset <- preds %>%
    filter(dog_edge > s$min_edge, dog_edge <= s$max_edge,
           mkt_dog_odds >= s$min_odds, mkt_dog_odds < s$max_odds)

  if (nrow(subset) >= 20) {
    yearly <- subset %>%
      group_by(year) %>%
      summarise(roi = mean(dog_profit), .groups = "drop")
    pos_years <- sum(yearly$roi > 0)

    cat(sprintf("%-25s N=%4d, Win=%.1f%%, ROI=%+.2f%%, %d/4 pos\n",
                s$name, nrow(subset),
                100*mean(subset$dog_won), 100*mean(subset$dog_profit), pos_years))
  }
}

cat("\n\n2025 Out-of-Sample Results (from test_2025_oos.R):\n")
cat("--------------------------------------------------\n")
cat("Odds 3.0-4.0, Edge 0-10%: N=129, ROI=+23.67%\n")
cat("Odds 4.0+, Edge 0-10%:    N=98,  ROI=+24.24%\n")
cat("Odds 3.0+, Edge 0-10%:    N=227, ROI=+23.93%\n")

