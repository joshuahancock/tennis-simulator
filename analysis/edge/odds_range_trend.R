# Odds Range Trend Analysis
#
# Check if there's a temporal trend in performance by odds range

library(tidyverse)
source("src/backtesting/07_elo_ratings.R")

cat("=== ODDS RANGE TEMPORAL TREND ===\n\n")

# Load existing predictions from validation
# We'll regenerate including 2025 for complete picture

hist_matches <- readRDS("data/processed/atp_matches_aligned.rds")
platt_results <- readRDS("data/processed/platt_scaling_results.rds")
platt_a <- platt_results$coefficients[1]
platt_b <- platt_results$coefficients[2]

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

    elo_fav_prob <- max(elo_prob_w, 1 - elo_prob_w)
    elo_logit <- qlogis(pmax(0.01, pmin(0.99, elo_fav_prob)))
    calibrated_fav_prob <- plogis(platt_a + platt_b * elo_logit)
    calibrated_prob_w <- ifelse(elo_prob_w > 0.5, calibrated_fav_prob, 1 - calibrated_fav_prob)

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
      surface = surface,
      mkt_dog_odds = mkt_dog_odds,
      dog_edge = dog_edge,
      dog_won = (mkt_dog == m$winner),
      dog_profit = ifelse(mkt_dog == m$winner, mkt_dog_odds - 1, -1)
    )

    update <- elo_update(w_info$elo, l_info$elo)
    idx_w <- which(elo_db$overall$player == m$winner)
    idx_l <- which(elo_db$overall$player == m$loser)
    if (length(idx_w) > 0) elo_db$overall$elo[idx_w] <- update$new_winner_elo
    if (length(idx_l) > 0) elo_db$overall$elo[idx_l] <- update$new_loser_elo
  }

  bind_rows(results)
}

# Generate for all years including 2025
cat("Generating predictions 2021-2025...\n")
all_preds <- list()
for (year in 2021:2025) {
  cat(sprintf("  %d...\n", year))
  all_preds[[as.character(year)]] <- generate_year_preds(year, hist_matches, name_map, platt_a, platt_b)
}
preds <- bind_rows(all_preds)

# ============================================================================
# FULL YEAR-BY-YEAR HEATMAP (Edge 0-10%)
# ============================================================================

cat("\n==================================================\n")
cat("ROI BY YEAR AND ODDS RANGE (Edge 0-10%)\n")
cat("==================================================\n\n")

edge_preds <- preds %>%
  filter(dog_edge > 0, dog_edge <= 0.10) %>%
  mutate(
    odds_bucket = cut(mkt_dog_odds,
                      breaks = c(1, 2, 2.5, 3, 4, 100),
                      labels = c("1.0-2.0", "2.0-2.5", "2.5-3.0", "3.0-4.0", "4.0+"))
  )

# ROI matrix
roi_matrix <- edge_preds %>%
  group_by(year, odds_bucket) %>%
  summarise(
    n = n(),
    roi = mean(dog_profit),
    .groups = "drop"
  ) %>%
  pivot_wider(
    names_from = odds_bucket,
    values_from = c(n, roi)
  )

cat("Sample sizes:\n")
roi_matrix %>%
  select(year, starts_with("n_")) %>%
  rename_with(~ str_replace(., "n_", ""), starts_with("n_")) %>%
  print()

cat("\nROI by year and odds range:\n")
roi_matrix %>%
  select(year, starts_with("roi_")) %>%
  rename_with(~ str_replace(., "roi_", ""), starts_with("roi_")) %>%
  mutate(across(where(is.numeric), ~ sprintf("%+.1f%%", 100 * .))) %>%
  print()

# ============================================================================
# TREND ANALYSIS
# ============================================================================

cat("\n\n==================================================\n")
cat("TREND ANALYSIS: IS HIGH ODDS IMPROVING?\n")
cat("==================================================\n\n")

# Test for trend in 4.0+ performance
high_odds <- edge_preds %>%
  filter(odds_bucket == "4.0+") %>%
  group_by(year) %>%
  summarise(
    n = n(),
    roi = mean(dog_profit),
    .groups = "drop"
  )

cat("Odds 4.0+ by year:\n")
high_odds %>%
  mutate(roi = sprintf("%+.2f%%", 100 * roi)) %>%
  print()

# Simple regression for trend
if (nrow(high_odds) >= 4) {
  trend_model <- lm(roi ~ year, data = high_odds)
  cat(sprintf("\nTrend coefficient: %+.4f per year\n", coef(trend_model)[2]))
  cat(sprintf("R-squared: %.3f\n", summary(trend_model)$r.squared))
  cat(sprintf("p-value for trend: %.4f\n", summary(trend_model)$coefficients[2,4]))
}

# Low odds trend
low_odds <- edge_preds %>%
  filter(odds_bucket == "2.0-2.5") %>%
  group_by(year) %>%
  summarise(
    n = n(),
    roi = mean(dog_profit),
    .groups = "drop"
  )

cat("\nOdds 2.0-2.5 by year:\n")
low_odds %>%
  mutate(roi = sprintf("%+.2f%%", 100 * roi)) %>%
  print()

if (nrow(low_odds) >= 4) {
  trend_model <- lm(roi ~ year, data = low_odds)
  cat(sprintf("\nTrend coefficient: %+.4f per year\n", coef(trend_model)[2]))
  cat(sprintf("R-squared: %.3f\n", summary(trend_model)$r.squared))
  cat(sprintf("p-value for trend: %.4f\n", summary(trend_model)$coefficients[2,4]))
}

# ============================================================================
# CORRELATION BETWEEN ODDS RANGES
# ============================================================================

cat("\n\n==================================================\n")
cat("YEAR-TO-YEAR CORRELATION BETWEEN ODDS RANGES\n")
cat("==================================================\n\n")

yearly_roi <- edge_preds %>%
  group_by(year, odds_bucket) %>%
  summarise(roi = mean(dog_profit), .groups = "drop") %>%
  pivot_wider(names_from = odds_bucket, values_from = roi)

cat("Yearly ROI:\n")
yearly_roi %>%
  mutate(across(where(is.numeric), ~ sprintf("%+.1f%%", 100 * .))) %>%
  print()

# Check if low odds and high odds are negatively correlated
if (all(c("2.0-2.5", "4.0+") %in% names(yearly_roi))) {
  cor_test <- cor.test(yearly_roi$`2.0-2.5`, yearly_roi$`4.0+`)
  cat(sprintf("\nCorrelation (2.0-2.5 vs 4.0+): %.3f (p=%.3f)\n",
              cor_test$estimate, cor_test$p.value))
}

# ============================================================================
# MARKET CALIBRATION DRIFT?
# ============================================================================

cat("\n\n==================================================\n")
cat("MARKET CALIBRATION BY YEAR\n")
cat("==================================================\n\n")

cat("Are underdogs winning more/less often over time?\n\n")

preds %>%
  mutate(
    odds_bucket = cut(mkt_dog_odds,
                      breaks = c(1, 2, 2.5, 3, 4, 100),
                      labels = c("1.0-2.0", "2.0-2.5", "2.5-3.0", "3.0-4.0", "4.0+"))
  ) %>%
  group_by(year, odds_bucket) %>%
  summarise(
    n = n(),
    win_rate = mean(dog_won),
    avg_odds = mean(mkt_dog_odds),
    breakeven = 1 / avg_odds,
    excess = win_rate - breakeven,
    .groups = "drop"
  ) %>%
  select(year, odds_bucket, n, win_rate, breakeven, excess) %>%
  filter(odds_bucket %in% c("2.0-2.5", "4.0+")) %>%
  mutate(
    win_rate = sprintf("%.1f%%", 100 * win_rate),
    breakeven = sprintf("%.1f%%", 100 * breakeven),
    excess = sprintf("%+.1fpp", 100 * excess)
  ) %>%
  print(n = 20)

cat("\n\nInterpretation:\n")
cat("- 'excess' shows actual win rate minus breakeven rate\n")
cat("- Positive excess = underdogs winning more than expected\n")
cat("- This tests if the market itself has shifted calibration\n")

