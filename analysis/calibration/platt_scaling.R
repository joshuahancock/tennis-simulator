# Platt Scaling for Elo Calibration
#
# The calibration table shows Elo overestimates favorites and underestimates underdogs.
# Platt scaling fits: calibrated_prob = plogis(a + b * qlogis(elo_prob))
# If b < 1, it compresses extreme probabilities toward 50%.
#
# Training: 2021-2023
# Validation: H1 2024

library(tidyverse)
source("src/backtesting/07_elo_ratings.R")

cat("=== PLATT SCALING FOR ELO CALIBRATION ===\n\n")

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

generate_predictions <- function(year, hist_matches, name_map) {
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

    # Market implied probability (from winner's odds)
    mkt_prob_w <- 1 / m$PSW

    # Frame as: does higher-Elo player win?
    # This gives us actual 0/1 outcomes for calibration
    elo_fav <- ifelse(elo_prob_w > 0.5, m$winner, m$loser)
    elo_fav_prob <- ifelse(elo_prob_w > 0.5, elo_prob_w, 1 - elo_prob_w)
    elo_fav_won <- (elo_fav == m$winner)

    results[[i]] <- tibble(
      date = m$Date,
      year = year,
      winner = m$winner,
      loser = m$loser,
      surface = surface,
      w_odds = m$PSW,
      l_odds = m$PSL,
      elo_prob_w = elo_prob_w,
      mkt_prob_w = mkt_prob_w,
      elo_fav = elo_fav,
      elo_fav_prob = elo_fav_prob,
      elo_fav_won = as.integer(elo_fav_won)
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

# Generate predictions for 2021-2024
cat("Generating Elo predictions...\n")
name_map <- create_name_lookup(hist_matches)

all_preds <- list()
for (year in 2021:2024) {
  cat(sprintf("  %d...\n", year))
  all_preds[[as.character(year)]] <- generate_predictions(year, hist_matches, name_map)
}

preds <- bind_rows(all_preds)
cat(sprintf("\nTotal predictions: %d\n", nrow(preds)))

# ============================================================================
# SPLIT INTO TRAINING (2021-2023) AND VALIDATION (H1 2024)
# ============================================================================

train <- preds %>% filter(year %in% 2021:2023)
valid <- preds %>% filter(year == 2024, date < as.Date("2024-07-01"))

cat(sprintf("\nTraining set (2021-2023): %d matches\n", nrow(train)))
cat(sprintf("Validation set (H1 2024): %d matches\n", nrow(valid)))

# ============================================================================
# FIT PLATT SCALING
# ============================================================================

cat("\n========================================\n")
cat("FITTING PLATT SCALING\n")
cat("========================================\n\n")

# Transform to logit scale
# Use elo_fav_prob (probability Elo assigns to its favorite) as predictor
# Use elo_fav_won (did Elo's favorite win?) as outcome
train <- train %>%
  mutate(
    elo_logit = qlogis(pmax(0.01, pmin(0.99, elo_fav_prob)))
  )

# Fit logistic regression: P(elo_fav wins) ~ logit(elo_fav_prob)
# This is Platt scaling: calibrated = plogis(a + b * qlogis(elo_prob))
platt_model <- glm(elo_fav_won ~ elo_logit, data = train, family = binomial)

cat("Platt scaling coefficients:\n")
cat(sprintf("  Intercept (a): %.4f\n", coef(platt_model)[1]))
cat(sprintf("  Slope (b): %.4f\n", coef(platt_model)[2]))

# Interpretation:
# If b < 1: compresses probabilities toward 50% (reduces overconfidence)
# If b > 1: expands probabilities away from 50%
# If a != 0: shifts overall bias

if (coef(platt_model)[2] < 1) {
  cat("\n  Interpretation: b < 1 means Elo IS overconfident.\n")
  cat("  Platt scaling will compress extreme probabilities toward 50%.\n")
} else {
  cat("\n  Interpretation: b >= 1 means Elo is NOT overconfident.\n")
}

# ============================================================================
# APPLY TO VALIDATION SET
# ============================================================================

cat("\n========================================\n")
cat("VALIDATION: H1 2024\n")
cat("========================================\n\n")

valid <- valid %>%
  mutate(
    elo_logit = qlogis(pmax(0.01, pmin(0.99, elo_fav_prob)))
  )

# Predict calibrated probability that Elo's favorite wins
valid$calibrated_fav_prob <- predict(platt_model, newdata = valid, type = "response")

# Convert back to probability of winner winning (for comparison)
valid <- valid %>%
  mutate(
    calibrated_prob_w = ifelse(elo_fav == winner, calibrated_fav_prob, 1 - calibrated_fav_prob)
  )

# ============================================================================
# CALIBRATION COMPARISON
# ============================================================================

# Calibration using Elo favorite framing (prob > 0.5 always)
calc_calibration <- function(df, prob_col, outcome_col = "elo_fav_won") {
  df %>%
    mutate(
      prob_bucket = cut(!!sym(prob_col),
                        breaks = c(0.5, 0.55, 0.60, 0.65, 0.70, 0.75, 0.80, 1.0),
                        labels = c("50-55%", "55-60%", "60-65%", "65-70%", "70-75%", "75-80%", "80-100%"))
    ) %>%
    filter(!is.na(prob_bucket)) %>%
    group_by(prob_bucket) %>%
    summarise(
      n = n(),
      predicted = mean(!!sym(prob_col)),
      actual = mean(!!sym(outcome_col)),
      .groups = "drop"
    ) %>%
    mutate(error = actual - predicted)
}

cat("CALIBRATION - Raw Elo (Elo favorite's probability):\n")
cal_raw <- calc_calibration(valid, "elo_fav_prob", "elo_fav_won")
print(cal_raw)

cat("\nCALIBRATION - Platt-Scaled Elo:\n")
cal_platt <- calc_calibration(valid, "calibrated_fav_prob", "elo_fav_won")
print(cal_platt)

# Brier scores (using Elo favorite framing)
brier_raw <- mean((valid$elo_fav_prob - valid$elo_fav_won)^2)
brier_platt <- mean((valid$calibrated_fav_prob - valid$elo_fav_won)^2)

cat("\n----------------------------------------\n")
cat("BRIER SCORES (lower is better):\n")
cat(sprintf("  Raw Elo: %.4f\n", brier_raw))
cat(sprintf("  Platt-Scaled: %.4f\n", brier_platt))
cat(sprintf("  Improvement: %.4f (%.1f%%)\n",
            brier_raw - brier_platt,
            100 * (brier_raw - brier_platt) / brier_raw))

# Log loss (using Elo favorite framing)
logloss_raw <- -mean(valid$elo_fav_won * log(pmax(0.001, valid$elo_fav_prob)) +
                      (1 - valid$elo_fav_won) * log(pmax(0.001, 1 - valid$elo_fav_prob)))
logloss_platt <- -mean(valid$elo_fav_won * log(pmax(0.001, valid$calibrated_fav_prob)) +
                        (1 - valid$elo_fav_won) * log(pmax(0.001, 1 - valid$calibrated_fav_prob)))

cat("\nLOG LOSS (lower is better):\n")
cat(sprintf("  Raw Elo: %.4f\n", logloss_raw))
cat(sprintf("  Platt-Scaled: %.4f\n", logloss_platt))
cat(sprintf("  Improvement: %.4f (%.1f%%)\n",
            logloss_raw - logloss_platt,
            100 * (logloss_raw - logloss_platt) / logloss_raw))

# ============================================================================
# BETTING ANALYSIS WITH CALIBRATED PROBABILITIES
# ============================================================================

cat("\n========================================\n")
cat("BETTING ANALYSIS\n")
cat("========================================\n\n")

# Calculate edge using calibrated probabilities
valid <- valid %>%
  mutate(
    # Market implied probability (with margin removed - assume symmetric)
    margin = 1/w_odds + 1/l_odds - 1,
    mkt_prob_w_fair = (1/w_odds) / (1/w_odds + 1/l_odds),

    # Edge calculations
    raw_edge = elo_prob_w - mkt_prob_w_fair,
    platt_edge = calibrated_prob_w - mkt_prob_w_fair,

    # Betting decisions
    raw_pick = ifelse(elo_prob_w > 0.5, winner, loser),
    platt_pick = ifelse(calibrated_prob_w > 0.5, winner, loser),

    raw_correct = (raw_pick == winner),
    platt_correct = (platt_pick == winner),

    raw_bet_odds = ifelse(raw_pick == winner, w_odds, l_odds),
    platt_bet_odds = ifelse(platt_pick == winner, w_odds, l_odds),

    raw_profit = ifelse(raw_correct, raw_bet_odds - 1, -1),
    platt_profit = ifelse(platt_correct, platt_bet_odds - 1, -1)
  )

cat("Overall (H1 2024):\n")
cat(sprintf("  Raw Elo accuracy: %.1f%%\n", 100 * mean(valid$raw_correct)))
cat(sprintf("  Platt Elo accuracy: %.1f%%\n", 100 * mean(valid$platt_correct)))
cat(sprintf("  Raw Elo ROI: %+.2f%%\n", 100 * mean(valid$raw_profit)))
cat(sprintf("  Platt Elo ROI: %+.2f%%\n", 100 * mean(valid$platt_profit)))

# ============================================================================
# "AGREE BUT LESS CONFIDENT" SIGNAL WITH CALIBRATED PROBS
# ============================================================================

cat("\n========================================\n")
cat("'AGREE BUT LESS CONFIDENT' WITH PLATT SCALING\n")
cat("========================================\n\n")

# Original signal: Elo agrees with market but is 0-5pp less confident
valid <- valid %>%
  mutate(
    mkt_pick = ifelse(w_odds < l_odds, winner, loser),

    # Raw version
    raw_agrees = (raw_pick == mkt_pick),
    raw_conf_diff = ifelse(mkt_pick == winner,
                           mkt_prob_w_fair - elo_prob_w,
                           (1 - mkt_prob_w_fair) - (1 - elo_prob_w)),
    raw_less_confident = raw_agrees & raw_conf_diff > 0 & raw_conf_diff <= 0.05,

    # Platt version
    platt_agrees = (platt_pick == mkt_pick),
    platt_conf_diff = ifelse(mkt_pick == winner,
                             mkt_prob_w_fair - calibrated_prob_w,
                             (1 - mkt_prob_w_fair) - (1 - calibrated_prob_w)),
    platt_less_confident = platt_agrees & platt_conf_diff > 0 & platt_conf_diff <= 0.05
  )

cat("RAW Elo 'agree but less confident':\n")
raw_signal <- valid %>% filter(raw_less_confident)
cat(sprintf("  N: %d\n", nrow(raw_signal)))
cat(sprintf("  Accuracy: %.1f%%\n", 100 * mean(raw_signal$raw_correct)))
cat(sprintf("  ROI: %+.2f%%\n", 100 * mean(raw_signal$raw_profit)))

cat("\nPLATT-SCALED 'agree but less confident':\n")
platt_signal <- valid %>% filter(platt_less_confident)
cat(sprintf("  N: %d\n", nrow(platt_signal)))
cat(sprintf("  Accuracy: %.1f%%\n", 100 * mean(platt_signal$platt_correct)))
cat(sprintf("  ROI: %+.2f%%\n", 100 * mean(platt_signal$platt_profit)))

# ============================================================================
# SAVE RESULTS
# ============================================================================

platt_results <- list(
  model = platt_model,
  coefficients = coef(platt_model),
  training_years = 2021:2023,
  validation = valid,
  brier_improvement = brier_raw - brier_platt
)

saveRDS(platt_results, "data/processed/platt_scaling_results.rds")

cat("\n========================================\n")
cat("SUMMARY\n")
cat("========================================\n\n")

cat("Platt scaling coefficients (train 2021-2023):\n")
cat(sprintf("  calibrated = plogis(%.4f + %.4f * qlogis(elo_prob))\n",
            coef(platt_model)[1], coef(platt_model)[2]))
cat("\nKey finding: Slope b = %.4f ", coef(platt_model)[2])
if (coef(platt_model)[2] < 1) {
  cat("< 1 confirms Elo overconfidence.\n")
} else {
  cat(">= 1 suggests Elo is not overconfident.\n")
}

cat("\nResults saved to data/processed/platt_scaling_results.rds\n")
