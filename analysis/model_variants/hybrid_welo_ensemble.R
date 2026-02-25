# WElo (Weighted Elo by Tournament Importance) + Elo-MC Ensemble
#
# 1. WElo: Different K-factors based on tournament level
# 2. Ensemble: Combine Elo prediction with simple serve-based model

library(tidyverse)

cat("=== WELO + ENSEMBLE APPROACHES ===\n\n")

hist_matches <- readRDS("data/processed/atp_matches_aligned.rds")

DEFAULT_ELO <- 1500

# WElo K-factors by tournament importance
get_k_factor_welo <- function(tourney_level) {
  case_when(
    tourney_level == "G" ~ 48,      # Grand Slam
    tourney_level == "M" ~ 40,      # Masters
    tourney_level == "A" ~ 32,      # ATP 500
    TRUE ~ 24                       # ATP 250 and below
  )
}

# Build WElo
build_welo <- function(matches, cutoff_date) {
  training <- matches %>%
    filter(match_date < cutoff_date) %>%
    filter(!is.na(winner_name), !is.na(loser_name)) %>%
    arrange(match_date)

  elo <- list()
  surface_elo <- list()
  for (surf in c("Hard", "Clay", "Grass")) {
    surface_elo[[surf]] <- list()
  }

  for (i in 1:nrow(training)) {
    m <- training[i, ]
    w <- m$winner_name
    l <- m$loser_name
    surface <- m$surface
    k <- get_k_factor_welo(m$tourney_level)

    w_elo <- elo[[w]] %||% DEFAULT_ELO
    l_elo <- elo[[l]] %||% DEFAULT_ELO
    exp_w <- 1 / (1 + 10^((l_elo - w_elo) / 400))

    elo[[w]] <- w_elo + k * (1 - exp_w)
    elo[[l]] <- l_elo + k * (0 - (1 - exp_w))

    # Surface-specific
    if (surface %in% c("Hard", "Clay", "Grass")) {
      w_surf <- surface_elo[[surface]][[w]] %||% DEFAULT_ELO
      l_surf <- surface_elo[[surface]][[l]] %||% DEFAULT_ELO
      exp_surf <- 1 / (1 + 10^((l_surf - w_surf) / 400))
      surface_elo[[surface]][[w]] <- w_surf + k * (1 - exp_surf)
      surface_elo[[surface]][[l]] <- l_surf + k * (0 - (1 - exp_surf))
    }
  }

  list(overall = elo, surface = surface_elo)
}

# Build serve stats database
build_serve_stats <- function(matches, cutoff_date, min_matches = 20) {
  training <- matches %>%
    filter(match_date < cutoff_date) %>%
    filter(!is.na(winner_name), !is.na(loser_name))

  # Winner stats
  winner_stats <- training %>%
    filter(!is.na(w_1stIn), w_svpt > 0) %>%
    group_by(player = winner_name) %>%
    summarise(
      matches = n(),
      first_in = mean(w_1stIn / w_svpt, na.rm = TRUE),
      first_won = mean(w_1stWon / pmax(w_1stIn, 1), na.rm = TRUE),
      second_won = mean(w_2ndWon / pmax(w_svpt - w_1stIn, 1), na.rm = TRUE),
      .groups = "drop"
    )

  # Loser stats (they were serving too)
  loser_stats <- training %>%
    filter(!is.na(l_1stIn), l_svpt > 0) %>%
    group_by(player = loser_name) %>%
    summarise(
      matches = n(),
      first_in = mean(l_1stIn / l_svpt, na.rm = TRUE),
      first_won = mean(l_1stWon / pmax(l_1stIn, 1), na.rm = TRUE),
      second_won = mean(l_2ndWon / pmax(l_svpt - l_1stIn, 1), na.rm = TRUE),
      .groups = "drop"
    )

  # Combine
  all_stats <- bind_rows(winner_stats, loser_stats) %>%
    group_by(player) %>%
    summarise(
      matches = sum(matches),
      first_in = mean(first_in, na.rm = TRUE),
      first_won = mean(first_won, na.rm = TRUE),
      second_won = mean(second_won, na.rm = TRUE),
      .groups = "drop"
    ) %>%
    filter(matches >= min_matches)

  all_stats
}

# Simple serve-based probability
# P(win) based on serve performance differential
calc_serve_prob <- function(p1_stats, p2_stats, tour_avg_first_won = 0.72, tour_avg_second_won = 0.52) {
  if (is.null(p1_stats) || is.null(p2_stats)) return(0.5)

  # Serve game win probability (simplified)
  p1_serve_strength <- 0.4 * p1_stats$first_in * p1_stats$first_won +
                       0.4 * (1 - p1_stats$first_in) * p1_stats$second_won +
                       0.2 * (p1_stats$first_won + p1_stats$second_won) / 2

  p2_serve_strength <- 0.4 * p2_stats$first_in * p2_stats$first_won +
                       0.4 * (1 - p2_stats$first_in) * p2_stats$second_won +
                       0.2 * (p2_stats$first_won + p2_stats$second_won) / 2

  # Normalize to probability
  diff <- (p1_serve_strength - p2_serve_strength) * 2
  prob <- 1 / (1 + exp(-diff * 5))  # Logistic transformation

  pmax(0.2, pmin(0.8, prob))  # Bound to avoid extremes
}

# Backtest
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

backtest_hybrid <- function(year, hist_matches, ensemble_weight = 0.2) {
  elo_cutoff <- as.Date(sprintf("%d-01-01", year))

  prior_matches <- hist_matches %>%
    filter(match_date < elo_cutoff) %>%
    filter(!is.na(winner_name), !is.na(loser_name))

  # Build models
  welo_db <- build_welo(prior_matches, elo_cutoff)
  serve_db <- build_serve_stats(prior_matches, elo_cutoff, min_matches = 20)

  # Load betting data
  betting_file <- sprintf("data/raw/tennis_betting/%d.xlsx", year)
  betting <- readxl::read_xlsx(betting_file) %>%
    mutate(Date = as.Date(Date))

  name_map <- create_name_lookup(hist_matches)

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

    # WElo prediction
    w_elo <- welo_db$overall[[m$winner]] %||% DEFAULT_ELO
    l_elo <- welo_db$overall[[m$loser]] %||% DEFAULT_ELO

    if (surface %in% c("Hard", "Clay", "Grass")) {
      w_surf <- welo_db$surface[[surface]][[m$winner]] %||% DEFAULT_ELO
      l_surf <- welo_db$surface[[surface]][[m$loser]] %||% DEFAULT_ELO
      w_elo <- 0.6 * w_surf + 0.4 * w_elo
      l_elo <- 0.6 * l_surf + 0.4 * l_elo
    }

    welo_prob_w <- 1 / (1 + 10^((l_elo - w_elo) / 400))

    # Serve-based prediction
    w_serve <- serve_db %>% filter(player == m$winner)
    l_serve <- serve_db %>% filter(player == m$loser)

    if (nrow(w_serve) > 0 && nrow(l_serve) > 0) {
      serve_prob_w <- calc_serve_prob(w_serve, l_serve)
      has_serve <- TRUE
    } else {
      serve_prob_w <- 0.5
      has_serve <- FALSE
    }

    # Ensemble: combine WElo and Serve
    ensemble_prob_w <- (1 - ensemble_weight) * welo_prob_w + ensemble_weight * serve_prob_w

    results[[i]] <- tibble(
      date = m$Date,
      winner = m$winner,
      loser = m$loser,
      w_odds = m$PSW,
      l_odds = m$PSL,
      welo_prob = welo_prob_w,
      serve_prob = serve_prob_w,
      ensemble_prob = ensemble_prob_w,
      welo_correct = welo_prob_w > 0.5,
      ensemble_correct = ensemble_prob_w > 0.5,
      has_serve = has_serve
    )

    # Rolling update
    k <- 32  # Use standard K for rolling updates
    exp_w <- 1 / (1 + 10^((l_elo - w_elo) / 400))
    welo_db$overall[[m$winner]] <- w_elo + k * (1 - exp_w)
    welo_db$overall[[m$loser]] <- l_elo + k * (0 - (1 - exp_w))
  }

  preds <- bind_rows(results) %>%
    mutate(
      welo_pick = ifelse(welo_prob > 0.5, winner, loser),
      ensemble_pick = ifelse(ensemble_prob > 0.5, winner, loser),
      welo_bet_odds = ifelse(welo_pick == winner, w_odds, l_odds),
      ensemble_bet_odds = ifelse(ensemble_pick == winner, w_odds, l_odds),
      welo_profit = ifelse(welo_correct, welo_bet_odds - 1, -1),
      ensemble_profit = ifelse(ensemble_correct, ensemble_bet_odds - 1, -1)
    )

  preds
}

# Run backtest
cat("Running WElo + Serve Ensemble backtest 2021-2024...\n\n")

all_results <- list()
for (year in 2021:2024) {
  cat(sprintf("  %d...\n", year))
  all_results[[as.character(year)]] <- backtest_hybrid(year, hist_matches, ensemble_weight = 0.2)
}

combined <- bind_rows(all_results, .id = "year")

cat("\n========================================\n")
cat("RESULTS: WELO vs WELO+SERVE ENSEMBLE\n")
cat("========================================\n\n")

cat("Overall:\n")
cat(sprintf("  WElo accuracy: %.1f%%\n", 100 * mean(combined$welo_correct)))
cat(sprintf("  Ensemble accuracy: %.1f%%\n", 100 * mean(combined$ensemble_correct)))
cat(sprintf("  WElo ROI: %+.1f%%\n", 100 * mean(combined$welo_profit)))
cat(sprintf("  Ensemble ROI: %+.1f%%\n\n", 100 * mean(combined$ensemble_profit)))

cat("By year:\n")
combined %>%
  group_by(year) %>%
  summarise(
    n = n(),
    welo_accuracy = mean(welo_correct),
    ensemble_accuracy = mean(ensemble_correct),
    welo_roi = mean(welo_profit),
    ensemble_roi = mean(ensemble_profit),
    .groups = "drop"
  ) %>%
  mutate(
    welo_accuracy = sprintf("%.1f%%", 100 * welo_accuracy),
    ensemble_accuracy = sprintf("%.1f%%", 100 * ensemble_accuracy),
    welo_roi = sprintf("%+.1f%%", 100 * welo_roi),
    ensemble_roi = sprintf("%+.1f%%", 100 * ensemble_roi)
  ) %>%
  print()

# Matches with serve data
cat("\nMatches WITH serve data for both players:\n")
with_serve <- combined %>% filter(has_serve)
cat(sprintf("  N: %d (%.1f%% of matches)\n", nrow(with_serve), 100*nrow(with_serve)/nrow(combined)))
cat(sprintf("  WElo accuracy: %.1f%%\n", 100 * mean(with_serve$welo_correct)))
cat(sprintf("  Ensemble accuracy: %.1f%%\n", 100 * mean(with_serve$ensemble_correct)))
cat(sprintf("  WElo ROI: %+.1f%%\n", 100 * mean(with_serve$welo_profit)))
cat(sprintf("  Ensemble ROI: %+.1f%%\n", 100 * mean(with_serve$ensemble_profit)))

# When models disagree
cat("\nWhen WElo and Ensemble DISAGREE:\n")
disagree <- combined %>% filter(welo_pick != ensemble_pick, has_serve)
if (nrow(disagree) > 50) {
  cat(sprintf("  N: %d\n", nrow(disagree)))
  cat(sprintf("  WElo accuracy: %.1f%%\n", 100 * mean(disagree$welo_correct)))
  cat(sprintf("  Ensemble accuracy: %.1f%%\n", 100 * mean(disagree$ensemble_correct)))
  cat(sprintf("  WElo ROI: %+.1f%%\n", 100 * mean(disagree$welo_profit)))
  cat(sprintf("  Ensemble ROI: %+.1f%%\n", 100 * mean(disagree$ensemble_profit)))
}

saveRDS(combined, "data/processed/hybrid_welo_ensemble_results.rds")
