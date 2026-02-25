# Hybrid Elo: Add Head-to-Head Adjustment
# Theory: Some players consistently beat others beyond what Elo predicts
# We adjust Elo probability based on historical H2H record

library(tidyverse)
source("src/backtesting/07_elo_ratings.R")

cat("=== HYBRID ELO: HEAD-TO-HEAD ADJUSTMENT ===\n\n")

hist_matches <- readRDS("data/processed/atp_matches_aligned.rds")

# Build H2H database
cat("Building H2H database...\n")
h2h_db <- hist_matches %>%
  filter(!is.na(winner_name), !is.na(loser_name)) %>%
  mutate(
    # Create sorted pair key for consistent lookup
    p1 = pmin(winner_name, loser_name),
    p2 = pmax(winner_name, loser_name),
    p1_won = (winner_name == p1)
  ) %>%
  group_by(p1, p2, surface) %>%
  summarise(
    total_matches = n(),
    p1_wins = sum(p1_won),
    p2_wins = sum(!p1_won),
    .groups = "drop"
  ) %>%
  mutate(
    # H2H edge: how much does P1 overperform expected 50%?
    h2h_edge_p1 = (p1_wins / total_matches) - 0.5
  )

cat(sprintf("H2H records: %d unique matchups\n", nrow(h2h_db)))
cat(sprintf("Matchups with 3+ meetings: %d\n\n", sum(h2h_db$total_matches >= 3)))

# Function to get H2H adjustment
get_h2h_adjustment <- function(player1, player2, surface, h2h_db, min_matches = 3) {
  p1 <- min(player1, player2)
  p2 <- max(player1, player2)
  is_p1 <- (player1 == p1)

  # Look for surface-specific H2H first
  h2h <- h2h_db %>%
    filter(p1 == !!p1, p2 == !!p2, surface == !!surface, total_matches >= min_matches)

  if (nrow(h2h) == 0) {
    # Fall back to all-surface H2H
    h2h <- h2h_db %>%
      filter(p1 == !!p1, p2 == !!p2) %>%
      group_by(p1, p2) %>%
      summarise(
        total_matches = sum(total_matches),
        p1_wins = sum(p1_wins),
        p2_wins = sum(p2_wins),
        .groups = "drop"
      ) %>%
      filter(total_matches >= min_matches) %>%
      mutate(h2h_edge_p1 = (p1_wins / total_matches) - 0.5)
  }

  if (nrow(h2h) == 0) {
    return(0)  # No H2H data
  }

  # Return adjustment for player1 (flip sign if player1 is p2)
  edge <- h2h$h2h_edge_p1[1]
  if (!is_p1) edge <- -edge

  edge
}

# Test the hybrid model
cat("Testing hybrid Elo + H2H...\n\n")

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

# Run backtest for a year with H2H adjustment
backtest_hybrid <- function(year, hist_matches, h2h_db, h2h_weight = 0.15) {
  elo_cutoff <- as.Date(sprintf("%d-01-01", year))

  # Build Elo and H2H only from prior data
  prior_matches <- hist_matches %>%
    filter(match_date < elo_cutoff) %>%
    filter(!is.na(winner_name), !is.na(loser_name))

  elo_db <- build_elo_db_from_matches(prior_matches, verbose = FALSE)

  # Build H2H from prior data only
  prior_h2h <- prior_matches %>%
    mutate(
      p1 = pmin(winner_name, loser_name),
      p2 = pmax(winner_name, loser_name),
      p1_won = (winner_name == p1)
    ) %>%
    group_by(p1, p2, surface) %>%
    summarise(
      total_matches = n(),
      p1_wins = sum(p1_won),
      p2_wins = sum(!p1_won),
      .groups = "drop"
    ) %>%
    mutate(h2h_edge_p1 = (p1_wins / total_matches) - 0.5)

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
    filter(!is.na(winner), !is.na(loser))

  # Generate predictions
  results <- vector("list", nrow(matched))

  for (i in 1:nrow(matched)) {
    m <- matched[i, ]
    surface <- m$Surface

    # Get Elo prediction
    w_info <- get_player_elo(m$winner, surface, elo_db)
    l_info <- get_player_elo(m$loser, surface, elo_db)
    elo_prob_w <- elo_expected_prob(w_info$elo, l_info$elo)

    # Get H2H adjustment
    h2h_adj <- get_h2h_adjustment(m$winner, m$loser, surface, prior_h2h, min_matches = 3)

    # Hybrid probability: blend Elo with H2H
    hybrid_prob_w <- elo_prob_w + h2h_weight * h2h_adj
    hybrid_prob_w <- pmax(0.05, pmin(0.95, hybrid_prob_w))  # Bound probabilities

    results[[i]] <- tibble(
      date = m$Date,
      winner = m$winner,
      loser = m$loser,
      surface = surface,
      w_odds = m$PSW,
      l_odds = m$PSL,
      elo_prob = elo_prob_w,
      h2h_adj = h2h_adj,
      hybrid_prob = hybrid_prob_w,
      elo_correct = elo_prob_w > 0.5,
      hybrid_correct = hybrid_prob_w > 0.5,
      has_h2h = h2h_adj != 0
    )

    # Rolling Elo update
    update <- elo_update(w_info$elo, l_info$elo)
    idx_w <- which(elo_db$overall$player == m$winner)
    idx_l <- which(elo_db$overall$player == m$loser)
    if (length(idx_w) > 0) elo_db$overall$elo[idx_w] <- update$new_winner_elo
    if (length(idx_l) > 0) elo_db$overall$elo[idx_l] <- update$new_loser_elo
  }

  preds <- bind_rows(results) %>%
    mutate(
      elo_pick = ifelse(elo_prob > 0.5, winner, loser),
      hybrid_pick = ifelse(hybrid_prob > 0.5, winner, loser),
      elo_bet_odds = ifelse(elo_pick == winner, w_odds, l_odds),
      hybrid_bet_odds = ifelse(hybrid_pick == winner, w_odds, l_odds),
      elo_profit = ifelse(elo_correct, elo_bet_odds - 1, -1),
      hybrid_profit = ifelse(hybrid_correct, hybrid_bet_odds - 1, -1)
    )

  preds
}

# Test across years
cat("Running hybrid backtest 2021-2024...\n\n")

all_results <- list()
for (year in 2021:2024) {
  cat(sprintf("  %d...\n", year))
  all_results[[as.character(year)]] <- backtest_hybrid(year, hist_matches, h2h_db, h2h_weight = 0.15)
}

combined <- bind_rows(all_results, .id = "year")

cat("\n========================================\n")
cat("RESULTS: ELO vs HYBRID (ELO + H2H)\n")
cat("========================================\n\n")

# Overall comparison
cat("Overall:\n")
cat(sprintf("  Elo accuracy: %.1f%%\n", 100 * mean(combined$elo_correct)))
cat(sprintf("  Hybrid accuracy: %.1f%%\n", 100 * mean(combined$hybrid_correct)))
cat(sprintf("  Elo ROI: %+.1f%%\n", 100 * mean(combined$elo_profit)))
cat(sprintf("  Hybrid ROI: %+.1f%%\n\n", 100 * mean(combined$hybrid_profit)))

# By year
cat("By year:\n")
combined %>%
  group_by(year) %>%
  summarise(
    n = n(),
    elo_accuracy = mean(elo_correct),
    hybrid_accuracy = mean(hybrid_correct),
    elo_roi = mean(elo_profit),
    hybrid_roi = mean(hybrid_profit),
    n_with_h2h = sum(has_h2h),
    .groups = "drop"
  ) %>%
  mutate(
    elo_accuracy = sprintf("%.1f%%", 100 * elo_accuracy),
    hybrid_accuracy = sprintf("%.1f%%", 100 * hybrid_accuracy),
    elo_roi = sprintf("%+.1f%%", 100 * elo_roi),
    hybrid_roi = sprintf("%+.1f%%", 100 * hybrid_roi)
  ) %>%
  print()

# Focus on matches WITH H2H data
cat("\nMatches WITH H2H data (3+ prior meetings):\n")
h2h_matches <- combined %>% filter(has_h2h)
cat(sprintf("  N: %d (%.1f%% of all matches)\n", nrow(h2h_matches), 100*nrow(h2h_matches)/nrow(combined)))
cat(sprintf("  Elo accuracy: %.1f%%\n", 100 * mean(h2h_matches$elo_correct)))
cat(sprintf("  Hybrid accuracy: %.1f%%\n", 100 * mean(h2h_matches$hybrid_correct)))
cat(sprintf("  Elo ROI: %+.1f%%\n", 100 * mean(h2h_matches$elo_profit)))
cat(sprintf("  Hybrid ROI: %+.1f%%\n", 100 * mean(h2h_matches$hybrid_profit)))

# By year for H2H matches
cat("\nH2H matches by year:\n")
h2h_matches %>%
  group_by(year) %>%
  summarise(
    n = n(),
    elo_roi = mean(elo_profit),
    hybrid_roi = mean(hybrid_profit),
    .groups = "drop"
  ) %>%
  mutate(
    elo_roi = sprintf("%+.1f%%", 100 * elo_roi),
    hybrid_roi = sprintf("%+.1f%%", 100 * hybrid_roi)
  ) %>%
  print()

saveRDS(combined, "data/processed/hybrid_elo_h2h_results.rds")
