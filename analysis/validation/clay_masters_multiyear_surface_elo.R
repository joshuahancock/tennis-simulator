# Multi-Year Validation with Surface-Specific Elo
# Testing if Clay Masters edge persists across H1 2022, 2023, 2024

library(tidyverse)
source("src/backtesting/07_elo_ratings.R")

cat("=== MULTI-YEAR CLAY MASTERS VALIDATION (SURFACE ELO) ===\n")
cat("Testing if edge is persistent across years\n\n")

hist_matches <- readRDS("data/processed/atp_matches_aligned.rds")

extract_last <- function(name) {
  name %>%
    str_replace("\\s+[A-Z]\\.$", "") %>%
    str_replace("\\s+[A-Z]\\.[A-Z]\\.$", "") %>%
    str_to_lower() %>%
    str_trim()
}

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

create_name_lookup <- function(matches) {
  matches %>%
    filter(!is.na(winner_name)) %>%
    mutate(last = str_to_lower(word(winner_name, -1))) %>%
    select(last, full = winner_name) %>%
    distinct(last, .keep_all = TRUE)
}

validate_h1_surface_elo <- function(year, hist_matches) {
  cat(sprintf("\n========================================\n"))
  cat(sprintf("H1 %d\n", year))
  cat(sprintf("========================================\n"))

  elo_cutoff <- as.Date(sprintf("%d-01-01", year))
  h1_start <- as.Date(sprintf("%d-01-01", year))
  h1_end <- as.Date(sprintf("%d-07-01", year))

  # Build surface Elo
  prior_matches <- hist_matches %>%
    filter(match_date < elo_cutoff) %>%
    filter(!is.na(winner_name), !is.na(loser_name))

  elo_db <- build_elo_db_from_matches(prior_matches, verbose = FALSE)

  # Load betting data
  betting_file <- sprintf("data/raw/tennis_betting/%d.xlsx", year)
  betting <- readxl::read_xlsx(betting_file) %>%
    mutate(Date = as.Date(Date)) %>%
    filter(Date >= h1_start, Date < h1_end)

  name_map <- create_name_lookup(hist_matches)
  ranks <- get_rankings(hist_matches, elo_cutoff - 180, elo_cutoff)

  matched <- betting %>%
    mutate(w_last = extract_last(Winner), l_last = extract_last(Loser)) %>%
    left_join(name_map, by = c("w_last" = "last")) %>%
    rename(winner = full) %>%
    left_join(name_map, by = c("l_last" = "last")) %>%
    rename(loser = full) %>%
    filter(!is.na(winner), !is.na(loser))

  cat(sprintf("Matched %d/%d betting matches\n", nrow(matched), nrow(betting)))

  preds_list <- vector("list", nrow(matched))

  for (i in 1:nrow(matched)) {
    m <- matched[i, ]
    w <- m$winner
    l <- m$loser
    surface <- m$Surface

    w_info <- get_player_elo(w, surface, elo_db)
    l_info <- get_player_elo(l, surface, elo_db)

    prob_w <- elo_expected_prob(w_info$elo, l_info$elo)

    preds_list[[i]] <- tibble(
      date = m$Date, tournament = m$Tournament, surface = surface,
      winner = w, loser = l, w_odds = m$PSW, l_odds = m$PSL,
      elo_prob = prob_w, elo_correct = prob_w > 0.5
    )

    # Rolling update
    update <- elo_update(w_info$elo, l_info$elo)
    idx_w <- which(elo_db$overall$player == w)
    idx_l <- which(elo_db$overall$player == l)
    if (length(idx_w) > 0) elo_db$overall$elo[idx_w] <- update$new_winner_elo
    if (length(idx_l) > 0) elo_db$overall$elo[idx_l] <- update$new_loser_elo

    if (surface %in% ELO_SURFACES) {
      surf_w <- which(elo_db$surface$player == w & elo_db$surface$surface == surface)
      surf_l <- which(elo_db$surface$player == l & elo_db$surface$surface == surface)
      if (length(surf_w) > 0) elo_db$surface$elo[surf_w] <- update$new_winner_elo
      if (length(surf_l) > 0) elo_db$surface$elo[surf_l] <- update$new_loser_elo
    }
  }

  preds <- bind_rows(preds_list) %>%
    left_join(ranks, by = c("winner" = "player")) %>%
    rename(w_rank = best_rank) %>%
    left_join(ranks, by = c("loser" = "player")) %>%
    rename(l_rank = best_rank) %>%
    mutate(
      mkt_fav = ifelse(w_odds < l_odds, winner, loser),
      elo_pick = ifelse(elo_prob > 0.5, winner, loser),
      bet_odds = ifelse(elo_pick == winner, w_odds, l_odds),
      profit = ifelse(elo_correct, bet_odds - 1, -1),
      is_clay = str_detect(tolower(surface), "clay"),
      is_masters = str_detect(tolower(tournament), "masters|monte carlo|madrid|rome"),
      fav_rank = ifelse(mkt_fav == winner, w_rank, l_rank),
      dog_rank = ifelse(mkt_fav == winner, l_rank, w_rank),
      fav_top10 = !is.na(fav_rank) & fav_rank <= 10,
      dog_top30 = !is.na(dog_rank) & dog_rank <= 30
    )

  cat(sprintf("Overall: N=%d, Accuracy=%.1f%%, ROI=%+.1f%%\n",
              nrow(preds), 100*mean(preds$elo_correct), 100*mean(preds$profit)))

  clay_masters <- preds %>% filter(is_clay, is_masters)
  cm_top10 <- clay_masters %>% filter(fav_top10)
  cm_top30dog <- clay_masters %>% filter(dog_top30)

  if (nrow(clay_masters) >= 10) {
    cat(sprintf("Clay Masters: N=%d, Accuracy=%.1f%%, ROI=%+.1f%%\n",
                nrow(clay_masters), 100*mean(clay_masters$elo_correct), 100*mean(clay_masters$profit)))
  }
  if (nrow(cm_top10) >= 10) {
    cat(sprintf("  + Top 10 Fav: N=%d, Accuracy=%.1f%%, ROI=%+.1f%%\n",
                nrow(cm_top10), 100*mean(cm_top10$elo_correct), 100*mean(cm_top10$profit)))
  }
  if (nrow(cm_top30dog) >= 10) {
    cat(sprintf("  + Top 30 Dog: N=%d, Accuracy=%.1f%%, ROI=%+.1f%%\n",
                nrow(cm_top30dog), 100*mean(cm_top30dog$elo_correct), 100*mean(cm_top30dog$profit)))
  }

  tibble(
    year = year,
    overall_n = nrow(preds),
    overall_roi = mean(preds$profit),
    cm_n = nrow(clay_masters),
    cm_accuracy = if(nrow(clay_masters) > 0) mean(clay_masters$elo_correct) else NA,
    cm_roi = if(nrow(clay_masters) > 0) mean(clay_masters$profit) else NA,
    cm_top10_n = nrow(cm_top10),
    cm_top10_roi = if(nrow(cm_top10) > 0) mean(cm_top10$profit) else NA,
    cm_top30dog_n = nrow(cm_top30dog),
    cm_top30dog_roi = if(nrow(cm_top30dog) > 0) mean(cm_top30dog$profit) else NA
  )
}

# Run validation for each year
results <- list()
for (year in c(2022, 2023, 2024)) {
  results[[as.character(year)]] <- validate_h1_surface_elo(year, hist_matches)
}

summary <- bind_rows(results)

cat("\n\n========================================\n")
cat("MULTI-YEAR SUMMARY\n")
cat("========================================\n\n")

cat("Clay Masters Overall:\n")
summary %>%
  select(year, cm_n, cm_accuracy, cm_roi) %>%
  mutate(
    cm_accuracy = sprintf("%.1f%%", 100 * cm_accuracy),
    cm_roi = sprintf("%+.1f%%", 100 * cm_roi)
  ) %>%
  print()

cat("\nClay Masters + Top 10 Favorite:\n")
summary %>%
  select(year, cm_top10_n, cm_top10_roi) %>%
  mutate(cm_top10_roi = sprintf("%+.1f%%", 100 * cm_top10_roi)) %>%
  print()

cat("\nClay Masters + Top 30 Underdog:\n")
summary %>%
  select(year, cm_top30dog_n, cm_top30dog_roi) %>%
  mutate(cm_top30dog_roi = sprintf("%+.1f%%", 100 * cm_top30dog_roi)) %>%
  print()

# Pooled analysis
cat("\n========================================\n")
cat("POOLED ANALYSIS\n")
cat("========================================\n\n")

pooled_cm <- summary %>% filter(!is.na(cm_roi))
if (nrow(pooled_cm) >= 2) {
  total_n <- sum(pooled_cm$cm_n)
  weighted_roi <- sum(pooled_cm$cm_n * pooled_cm$cm_roi) / total_n
  positive_years <- sum(pooled_cm$cm_roi > 0)

  cat(sprintf("Clay Masters: N=%d across %d years, Weighted ROI=%+.1f%%, Positive years=%d/%d\n",
              total_n, nrow(pooled_cm), 100*weighted_roi, positive_years, nrow(pooled_cm)))
}

pooled_top10 <- summary %>% filter(!is.na(cm_top10_roi), cm_top10_n >= 10)
if (nrow(pooled_top10) >= 2) {
  total_n <- sum(pooled_top10$cm_top10_n)
  weighted_roi <- sum(pooled_top10$cm_top10_n * pooled_top10$cm_top10_roi) / total_n
  positive_years <- sum(pooled_top10$cm_top10_roi > 0)

  cat(sprintf("Clay Masters + Top 10 Fav: N=%d, Weighted ROI=%+.1f%%, Positive years=%d/%d\n",
              total_n, 100*weighted_roi, positive_years, nrow(pooled_top10)))
}

saveRDS(summary, "data/processed/clay_masters_multiyear_surface_elo.rds")
