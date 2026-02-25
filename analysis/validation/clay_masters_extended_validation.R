# Extended Multi-Year Validation: 2020-2024
# Testing Clay Masters edge across 5 years of H1 data

library(tidyverse)
source("src/backtesting/07_elo_ratings.R")

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

validate_h1 <- function(year, hist_matches) {
  elo_cutoff <- as.Date(sprintf("%d-01-01", year))
  h1_start <- as.Date(sprintf("%d-01-01", year))
  h1_end <- as.Date(sprintf("%d-07-01", year))

  prior_matches <- hist_matches %>%
    filter(match_date < elo_cutoff) %>%
    filter(!is.na(winner_name), !is.na(loser_name))

  elo_db <- build_elo_db_from_matches(prior_matches, verbose = FALSE)

  betting_file <- sprintf("data/raw/tennis_betting/%d.xlsx", year)
  if (!file.exists(betting_file)) return(NULL)

  betting <- readxl::read_xlsx(betting_file) %>%
    mutate(Date = as.Date(Date)) %>%
    filter(Date >= h1_start, Date < h1_end)

  # 2020 special case: COVID cancelled most of clay season
  if (nrow(betting) < 100) {
    cat(sprintf("  H1 %d: Only %d matches (COVID impact?)\n", year, nrow(betting)))
  }

  name_map <- create_name_lookup(hist_matches)
  ranks <- get_rankings(hist_matches, elo_cutoff - 180, elo_cutoff)

  matched <- betting %>%
    mutate(w_last = extract_last(Winner), l_last = extract_last(Loser)) %>%
    left_join(name_map, by = c("w_last" = "last")) %>%
    rename(winner = full) %>%
    left_join(name_map, by = c("l_last" = "last")) %>%
    rename(loser = full) %>%
    filter(!is.na(winner), !is.na(loser))

  if (nrow(matched) == 0) return(NULL)

  preds_list <- vector("list", nrow(matched))

  for (i in 1:nrow(matched)) {
    m <- matched[i, ]
    surface <- m$Surface
    w_info <- get_player_elo(m$winner, surface, elo_db)
    l_info <- get_player_elo(m$loser, surface, elo_db)
    prob_w <- elo_expected_prob(w_info$elo, l_info$elo)

    preds_list[[i]] <- tibble(
      tournament = m$Tournament, surface = surface,
      winner = m$winner, loser = m$loser,
      w_odds = m$PSW, l_odds = m$PSL,
      elo_prob = prob_w, elo_correct = prob_w > 0.5
    )

    update <- elo_update(w_info$elo, l_info$elo)
    idx_w <- which(elo_db$overall$player == m$winner)
    idx_l <- which(elo_db$overall$player == m$loser)
    if (length(idx_w) > 0) elo_db$overall$elo[idx_w] <- update$new_winner_elo
    if (length(idx_l) > 0) elo_db$overall$elo[idx_l] <- update$new_loser_elo
  }

  preds <- bind_rows(preds_list) %>%
    left_join(ranks, by = c("winner" = "player")) %>%
    rename(w_rank = best_rank) %>%
    left_join(ranks, by = c("loser" = "player")) %>%
    rename(l_rank = best_rank) %>%
    mutate(
      mkt_fav = ifelse(w_odds < l_odds, winner, loser),
      bet_odds = ifelse(elo_prob > 0.5, w_odds, l_odds),
      profit = ifelse(elo_correct, bet_odds - 1, -1),
      is_clay = str_detect(tolower(surface), "clay"),
      is_masters = str_detect(tolower(tournament), "masters|monte carlo|madrid|rome"),
      fav_rank = ifelse(mkt_fav == winner, w_rank, l_rank),
      fav_top10 = !is.na(fav_rank) & fav_rank <= 10
    )

  cm <- preds %>% filter(is_clay, is_masters)
  cm_top10 <- cm %>% filter(fav_top10)

  tibble(
    year = year,
    total_n = nrow(preds),
    cm_n = nrow(cm),
    cm_accuracy = if(nrow(cm) > 0) mean(cm$elo_correct) else NA,
    cm_roi = if(nrow(cm) > 0) mean(cm$profit) else NA,
    cm_top10_n = nrow(cm_top10),
    cm_top10_accuracy = if(nrow(cm_top10) > 0) mean(cm_top10$elo_correct) else NA,
    cm_top10_roi = if(nrow(cm_top10) > 0) mean(cm_top10$profit) else NA
  )
}

cat("=== EXTENDED MULTI-YEAR VALIDATION (2020-2024) ===\n\n")

results <- list()
for (year in 2020:2024) {
  cat(sprintf("Processing H1 %d...\n", year))
  results[[as.character(year)]] <- validate_h1(year, hist_matches)
}

summary <- bind_rows(results)

cat("\n========================================\n")
cat("CLAY MASTERS - ALL YEARS\n")
cat("========================================\n\n")

summary %>%
  mutate(
    cm_accuracy = ifelse(is.na(cm_accuracy), "-", sprintf("%.1f%%", 100 * cm_accuracy)),
    cm_roi = ifelse(is.na(cm_roi), "-", sprintf("%+.1f%%", 100 * cm_roi)),
    cm_top10_accuracy = ifelse(is.na(cm_top10_accuracy), "-", sprintf("%.1f%%", 100 * cm_top10_accuracy)),
    cm_top10_roi = ifelse(is.na(cm_top10_roi), "-", sprintf("%+.1f%%", 100 * cm_top10_roi))
  ) %>%
  select(year, total_n, cm_n, cm_accuracy, cm_roi, cm_top10_n, cm_top10_accuracy, cm_top10_roi) %>%
  print()

cat("\n========================================\n")
cat("POOLED STATISTICS\n")
cat("========================================\n\n")

# Clay Masters overall
valid_cm <- summary %>% filter(!is.na(cm_roi), cm_n >= 10)
if (nrow(valid_cm) > 0) {
  total_cm_n <- sum(valid_cm$cm_n)
  weighted_cm_roi <- sum(valid_cm$cm_n * valid_cm$cm_roi) / total_cm_n
  positive_cm <- sum(valid_cm$cm_roi > 0)
  cat(sprintf("Clay Masters:\n"))
  cat(sprintf("  Total N: %d across %d years\n", total_cm_n, nrow(valid_cm)))
  cat(sprintf("  Weighted ROI: %+.1f%%\n", 100 * weighted_cm_roi))
  cat(sprintf("  Positive years: %d/%d\n\n", positive_cm, nrow(valid_cm)))
}

# Top 10 Fav
valid_top10 <- summary %>% filter(!is.na(cm_top10_roi), cm_top10_n >= 10)
if (nrow(valid_top10) > 0) {
  total_top10_n <- sum(valid_top10$cm_top10_n)
  weighted_top10_roi <- sum(valid_top10$cm_top10_n * valid_top10$cm_top10_roi) / total_top10_n
  positive_top10 <- sum(valid_top10$cm_top10_roi > 0)
  cat(sprintf("Clay Masters + Top 10 Favorite:\n"))
  cat(sprintf("  Total N: %d across %d years\n", total_top10_n, nrow(valid_top10)))
  cat(sprintf("  Weighted ROI: %+.1f%%\n", 100 * weighted_top10_roi))
  cat(sprintf("  Positive years: %d/%d\n", positive_top10, nrow(valid_top10)))
}

saveRDS(summary, "data/processed/clay_masters_extended_validation.rds")
