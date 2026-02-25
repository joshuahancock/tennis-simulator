# Multi-Year Validation: Clay Masters Edge
# CRITICAL: No data leakage - Elo trained only on data BEFORE each test period
#
# For H1 2024: Train Elo through 2023-12-31
# For H1 2023: Train Elo through 2022-12-31
# For H1 2022: Train Elo through 2021-12-31

library(tidyverse)

cat("=== MULTI-YEAR CLAY MASTERS VALIDATION ===\n")
cat("Testing if edge is persistent or spurious\n\n")

# Load historical matches
hist_matches <- readRDS("data/processed/atp_matches_aligned.rds")

# Helper: Extract last name from betting format ("Sinner J." -> "sinner")
extract_last <- function(name) {
  name %>%
    str_replace("\\s+[A-Z]\\.$", "") %>%
    str_replace("\\s+[A-Z]\\.[A-Z]\\.$", "") %>%
    str_to_lower() %>%
    str_trim()
}

# Helper: Build Elo ratings up to a cutoff date (NO DATA AFTER CUTOFF)
build_elo_through <- function(matches, cutoff_date, k = 32) {
  training <- matches %>%
    filter(match_date < cutoff_date) %>%
    filter(!is.na(winner_name), !is.na(loser_name)) %>%
    arrange(match_date)

  elo <- list()

  for (i in 1:nrow(training)) {
    m <- training[i, ]
    w <- m$winner_name
    l <- m$loser_name
    w_elo <- elo[[w]]
    if (is.null(w_elo)) w_elo <- 1500
    l_elo <- elo[[l]]
    if (is.null(l_elo)) l_elo <- 1500
    exp_w <- 1 / (1 + 10^((l_elo - w_elo) / 400))
    elo[[w]] <- w_elo + k * (1 - exp_w)
    elo[[l]] <- l_elo + k * (0 - (1 - exp_w))
  }

  cat(sprintf("  Built Elo from %d matches through %s for %d players\n",
              nrow(training), cutoff_date, length(elo)))

  elo
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

# Helper: Create name lookup from historical data
create_name_lookup <- function(matches) {
  matches %>%
    filter(!is.na(winner_name)) %>%
    mutate(last = str_to_lower(word(winner_name, -1))) %>%
    select(last, full = winner_name) %>%
    distinct(last, .keep_all = TRUE)
}

# Function to validate one H1 period
validate_h1_period <- function(year, hist_matches, k = 32) {
  cat(sprintf("\n========================================\n"))
  cat(sprintf("H1 %d VALIDATION\n", year))
  cat(sprintf("========================================\n"))

  # Define periods
  elo_cutoff <- as.Date(sprintf("%d-01-01", year))
  h1_start <- as.Date(sprintf("%d-01-01", year))
  h1_end <- as.Date(sprintf("%d-07-01", year))

  cat(sprintf("Elo trained through: %s\n", elo_cutoff - 1))
  cat(sprintf("Test period: %s to %s\n\n", h1_start, h1_end - 1))

  # Build Elo (NO DATA FROM TEST YEAR)
  elo <- build_elo_through(hist_matches, elo_cutoff, k)

  # Load betting data
  betting_file <- sprintf("data/raw/tennis_betting/%d.xlsx", year)
  if (!file.exists(betting_file)) {
    cat(sprintf("  No betting file for %d\n", year))
    return(NULL)
  }

  betting <- readxl::read_xlsx(betting_file) %>%
    mutate(Date = as.Date(Date)) %>%
    filter(Date >= h1_start, Date < h1_end)

  cat(sprintf("  Betting matches in H1 %d: %d\n", year, nrow(betting)))

  # Get rankings from prior 6 months (for filtering quality matchups)
  ranks <- get_rankings(hist_matches, elo_cutoff - 180, elo_cutoff)

  # Name lookup
  name_map <- create_name_lookup(hist_matches)

  # Match betting data to full names
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

  if (nrow(matched) < 50) {
    cat("  Insufficient matches\n")
    return(NULL)
  }

  # Generate predictions with rolling Elo updates
  preds_list <- vector("list", nrow(matched))

  for (i in 1:nrow(matched)) {
    m <- matched[i, ]
    w <- m$winner
    l <- m$loser

    w_elo <- elo[[w]]
    if (is.null(w_elo)) w_elo <- 1500
    l_elo <- elo[[l]]
    if (is.null(l_elo)) l_elo <- 1500

    prob_w <- 1 / (1 + 10^((l_elo - w_elo) / 400))

    preds_list[[i]] <- tibble(
      date = m$Date,
      tournament = m$Tournament,
      surface = m$Surface,
      round = m$Round,
      winner = w,
      loser = l,
      w_odds = m$PSW,
      l_odds = m$PSL,
      elo_prob = prob_w,
      elo_correct = prob_w > 0.5
    )

    # Rolling Elo update (within test period)
    elo[[w]] <- w_elo + k * (1 - prob_w)
    elo[[l]] <- l_elo + k * (0 - (1 - prob_w))
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

  # Clay Masters
  clay_masters <- preds %>% filter(is_clay, is_masters)
  if (nrow(clay_masters) >= 10) {
    cat(sprintf("  Clay Masters: N=%d, Accuracy=%.1f%%, ROI=%+.1f%%\n",
                nrow(clay_masters), 100*mean(clay_masters$elo_correct), 100*mean(clay_masters$profit)))
  } else {
    cat(sprintf("  Clay Masters: N=%d (insufficient)\n", nrow(clay_masters)))
  }

  # Clay Masters + Top 10 Fav
  cm_top10 <- clay_masters %>% filter(fav_top10)
  if (nrow(cm_top10) >= 10) {
    cat(sprintf("  Clay Masters + Top 10 Fav: N=%d, Accuracy=%.1f%%, ROI=%+.1f%%\n",
                nrow(cm_top10), 100*mean(cm_top10$elo_correct), 100*mean(cm_top10$profit)))
  }

  # Clay Masters + Top 30 Dog
  cm_top30dog <- clay_masters %>% filter(dog_top30)
  if (nrow(cm_top30dog) >= 10) {
    cat(sprintf("  Clay Masters + Top 30 Dog: N=%d, Accuracy=%.1f%%, ROI=%+.1f%%\n",
                nrow(cm_top30dog), 100*mean(cm_top30dog$elo_correct), 100*mean(cm_top30dog$profit)))
  }

  # Clay Quality Matchups
  clay_quality <- preds %>% filter(is_clay, fav_top30, dog_top30)
  if (nrow(clay_quality) >= 10) {
    cat(sprintf("  Clay Quality (both Top 30): N=%d, Accuracy=%.1f%%, ROI=%+.1f%%\n",
                nrow(clay_quality), 100*mean(clay_quality$elo_correct), 100*mean(clay_quality$profit)))
  }

  # Return summary
  tibble(
    year = year,
    overall_n = nrow(preds),
    overall_accuracy = mean(preds$elo_correct),
    overall_roi = mean(preds$profit),
    clay_masters_n = nrow(clay_masters),
    clay_masters_accuracy = if(nrow(clay_masters) > 0) mean(clay_masters$elo_correct) else NA,
    clay_masters_roi = if(nrow(clay_masters) > 0) mean(clay_masters$profit) else NA,
    clay_quality_n = nrow(clay_quality),
    clay_quality_roi = if(nrow(clay_quality) > 0) mean(clay_quality$profit) else NA
  )
}

# Run validation for each year
results <- list()
for (year in c(2022, 2023, 2024)) {
  results[[as.character(year)]] <- validate_h1_period(year, hist_matches)
}

# Combine results
summary <- bind_rows(results)

cat("\n\n========================================\n")
cat("MULTI-YEAR SUMMARY\n")
cat("========================================\n\n")

summary %>%
  mutate(
    overall_accuracy = sprintf("%.1f%%", 100 * overall_accuracy),
    overall_roi = sprintf("%+.1f%%", 100 * overall_roi),
    clay_masters_accuracy = ifelse(is.na(clay_masters_accuracy), "-", sprintf("%.1f%%", 100 * clay_masters_accuracy)),
    clay_masters_roi = ifelse(is.na(clay_masters_roi), "-", sprintf("%+.1f%%", 100 * clay_masters_roi)),
    clay_quality_roi = ifelse(is.na(clay_quality_roi), "-", sprintf("%+.1f%%", 100 * clay_quality_roi))
  ) %>%
  select(year, overall_n, overall_accuracy, overall_roi,
         clay_masters_n, clay_masters_accuracy, clay_masters_roi,
         clay_quality_n, clay_quality_roi) %>%
  print()

# Pooled analysis
cat("\n========================================\n")
cat("POOLED ANALYSIS (if edge is consistent)\n")
cat("========================================\n\n")

pooled <- summary %>%
  filter(!is.na(clay_masters_roi))

if (nrow(pooled) >= 2) {
  # Weighted average by N
  total_n <- sum(pooled$clay_masters_n)
  weighted_roi <- sum(pooled$clay_masters_n * pooled$clay_masters_roi) / total_n

  cat(sprintf("Pooled Clay Masters: N=%d across %d years\n", total_n, nrow(pooled)))
  cat(sprintf("Weighted ROI: %+.1f%%\n", 100 * weighted_roi))

  # Consistency check
  positive_years <- sum(pooled$clay_masters_roi > 0)
  cat(sprintf("Years with positive ROI: %d/%d\n", positive_years, nrow(pooled)))
}

# Save
saveRDS(summary, "data/processed/clay_masters_multiyear_validation.rds")
