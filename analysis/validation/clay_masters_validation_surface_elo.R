# Multi-Year Validation with Surface-Specific Elo (matching original backtest)
# Using the proper 07_elo_ratings.R implementation

library(tidyverse)
source("src/backtesting/07_elo_ratings.R")

cat("=== MULTI-YEAR VALIDATION WITH SURFACE ELO ===\n\n")

hist_matches <- readRDS("data/processed/atp_matches_aligned.rds")

# Helper: Extract last name from betting format
extract_last <- function(name) {
  name %>%
    str_replace("\\s+[A-Z]\\.$", "") %>%
    str_replace("\\s+[A-Z]\\.[A-Z]\\.$", "") %>%
    str_to_lower() %>%
    str_trim()
}

# Helper: Get player rankings from a period
get_rankings <- function(matches, start_date, end_date) {
  matches %>%
    filter(match_date >= start_date, match_date < end_date) %>%
    select(player = winner_name, rank = winner_rank) %>%
    bind_rows(
      matches %>%
        filter(match_date >= start_date, match_date < end_date) %>%
        select(player = loser_name, rank = loser_rank)
    ) %>%
    filter(!is.na(rank)) %>%
    group_by(player) %>%
    summarise(best_rank = min(rank), .groups = "drop")
}

# Create name lookup from historical data
create_name_lookup <- function(matches) {
  matches %>%
    filter(!is.na(winner_name)) %>%
    mutate(last = str_to_lower(word(winner_name, -1))) %>%
    select(last, full = winner_name) %>%
    distinct(last, .keep_all = TRUE)
}

validate_h1_surface_elo <- function(year, hist_matches) {
  cat(sprintf("\n========================================\n"))
  cat(sprintf("H1 %d VALIDATION (SURFACE ELO)\n", year))
  cat(sprintf("========================================\n"))

  elo_cutoff <- as.Date(sprintf("%d-01-01", year))
  h1_start <- as.Date(sprintf("%d-01-01", year))
  h1_end <- as.Date(sprintf("%d-07-01", year))

  cat(sprintf("Elo trained through: %s\n", elo_cutoff - 1))

  # Build Elo using the proper implementation with surface support
  prior_matches <- hist_matches %>%
    filter(match_date < elo_cutoff) %>%
    filter(!is.na(winner_name), !is.na(loser_name))

  elo_db <- build_elo_db_from_matches(prior_matches, verbose = FALSE)
  cat(sprintf("  Built surface Elo for %d players\n", nrow(elo_db$overall)))

  # Load betting data
  betting_file <- sprintf("data/raw/tennis_betting/%d.xlsx", year)
  betting <- readxl::read_xlsx(betting_file) %>%
    mutate(Date = as.Date(Date)) %>%
    filter(Date >= h1_start, Date < h1_end)

  cat(sprintf("  Betting matches in H1: %d\n", nrow(betting)))

  # Name lookup
  name_map <- create_name_lookup(hist_matches)
  ranks <- get_rankings(hist_matches, elo_cutoff - 180, elo_cutoff)

  # Match betting to full names
  matched <- betting %>%
    mutate(
      w_last = extract_last(Winner),
      l_last = extract_last(Loser)
    ) %>%
    left_join(name_map, by = c("w_last" = "last")) %>%
    rename(winner = full) %>%
    left_join(name_map, by = c("l_last" = "last")) %>%
    rename(loser = full) %>%
    filter(!is.na(winner), !is.na(loser))

  cat(sprintf("  Matched to full names: %d\n", nrow(matched)))

  # Generate predictions using surface-specific Elo
  preds_list <- vector("list", nrow(matched))

  for (i in 1:nrow(matched)) {
    m <- matched[i, ]
    w <- m$winner
    l <- m$loser
    surface <- m$Surface

    # Get surface-specific Elo (matching original backtest)
    w_info <- get_player_elo(w, surface, elo_db)
    l_info <- get_player_elo(l, surface, elo_db)

    w_elo <- w_info$elo
    l_elo <- l_info$elo

    prob_w <- elo_expected_prob(w_elo, l_elo)

    preds_list[[i]] <- tibble(
      date = m$Date,
      tournament = m$Tournament,
      surface = surface,
      round = m$Round,
      winner = w,
      loser = l,
      w_odds = m$PSW,
      l_odds = m$PSL,
      elo_prob = prob_w,
      elo_correct = prob_w > 0.5,
      w_elo = w_elo,
      l_elo = l_elo
    )

    # Rolling update (update elo_db after each match)
    # For simplicity, just update the overall elo in the list
    # (A proper implementation would rebuild, but this approximates rolling)
    update <- elo_update(w_elo, l_elo)
    elo_db$overall$elo[elo_db$overall$player == w] <- update$new_winner_elo
    elo_db$overall$elo[elo_db$overall$player == l] <- update$new_loser_elo

    # Also update surface-specific
    if (surface %in% ELO_SURFACES) {
      surf_idx_w <- which(elo_db$surface$player == w & elo_db$surface$surface == surface)
      surf_idx_l <- which(elo_db$surface$player == l & elo_db$surface$surface == surface)
      if (length(surf_idx_w) > 0) {
        elo_db$surface$elo[surf_idx_w] <- update$new_winner_elo
      }
      if (length(surf_idx_l) > 0) {
        elo_db$surface$elo[surf_idx_l] <- update$new_loser_elo
      }
    }
  }

  preds <- bind_rows(preds_list) %>%
    left_join(ranks, by = c("winner" = "player")) %>%
    rename(w_rank = best_rank) %>%
    left_join(ranks, by = c("loser" = "player")) %>%
    rename(l_rank = best_rank) %>%
    mutate(
      mkt_fav = ifelse(w_odds < l_odds, winner, loser),
      mkt_fav_odds = pmin(w_odds, l_odds),
      elo_pick = ifelse(elo_prob > 0.5, winner, loser),
      bet_odds = ifelse(elo_pick == winner, w_odds, l_odds),
      profit = ifelse(elo_correct, bet_odds - 1, -1),
      is_clay = str_detect(tolower(surface), "clay"),
      is_masters = str_detect(tolower(tournament), "masters|monte carlo|madrid|rome"),
      fav_rank = ifelse(mkt_fav == winner, w_rank, l_rank),
      dog_rank = ifelse(mkt_fav == winner, l_rank, w_rank),
      fav_top10 = !is.na(fav_rank) & fav_rank <= 10,
      fav_top30 = !is.na(fav_rank) & fav_rank <= 30,
      dog_top30 = !is.na(dog_rank) & dog_rank <= 30
    )

  # Results
  cat(sprintf("\n  Overall: N=%d, Accuracy=%.1f%%, ROI=%+.1f%%\n",
              nrow(preds), 100*mean(preds$elo_correct), 100*mean(preds$profit)))

  clay_masters <- preds %>% filter(is_clay, is_masters)
  if (nrow(clay_masters) >= 10) {
    cat(sprintf("  Clay Masters: N=%d, Accuracy=%.1f%%, ROI=%+.1f%%\n",
                nrow(clay_masters), 100*mean(clay_masters$elo_correct), 100*mean(clay_masters$profit)))
  }

  cm_top10 <- clay_masters %>% filter(fav_top10)
  if (nrow(cm_top10) >= 10) {
    cat(sprintf("  Clay Masters + Top 10 Fav: N=%d, Accuracy=%.1f%%, ROI=%+.1f%%\n",
                nrow(cm_top10), 100*mean(cm_top10$elo_correct), 100*mean(cm_top10$profit)))
  }

  cm_top30dog <- clay_masters %>% filter(dog_top30)
  if (nrow(cm_top30dog) >= 10) {
    cat(sprintf("  Clay Masters + Top 30 Dog: N=%d, Accuracy=%.1f%%, ROI=%+.1f%%\n",
                nrow(cm_top30dog), 100*mean(cm_top30dog$elo_correct), 100*mean(cm_top30dog$profit)))
  }

  tibble(
    year = year,
    overall_n = nrow(preds),
    overall_accuracy = mean(preds$elo_correct),
    overall_roi = mean(preds$profit),
    clay_masters_n = nrow(clay_masters),
    clay_masters_accuracy = if(nrow(clay_masters) > 0) mean(clay_masters$elo_correct) else NA,
    clay_masters_roi = if(nrow(clay_masters) > 0) mean(clay_masters$profit) else NA,
    cm_top10_n = nrow(cm_top10),
    cm_top10_roi = if(nrow(cm_top10) > 0) mean(cm_top10$profit) else NA
  )
}

# Run for 2024 only first to compare with original
results <- validate_h1_surface_elo(2024, hist_matches)

cat("\n========================================\n")
cat("COMPARISON WITH ORIGINAL BACKTEST\n")
cat("========================================\n\n")

preds_orig <- readRDS("data/processed/preds_with_player_info.rds")
cm_orig <- preds_orig %>%
  filter(surface == "Clay", str_detect(tournament, "Masters|Monte Carlo|Madrid|Rome"))

cat(sprintf("Original: N=%d, Accuracy=%.1f%%, ROI=%+.1f%%\n",
            nrow(cm_orig), 100*mean(cm_orig$elo_correct), 100*mean(cm_orig$profit)))

cm_top10_orig <- cm_orig %>% filter(fav_rank_bucket == "Top 10")
cat(sprintf("Original Top 10 Fav: N=%d, Accuracy=%.1f%%, ROI=%+.1f%%\n",
            nrow(cm_top10_orig), 100*mean(cm_top10_orig$elo_correct), 100*mean(cm_top10_orig$profit)))
