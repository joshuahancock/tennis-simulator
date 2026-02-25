# Systematic Edge Search Across Multiple Years
# Looking for consistent patterns that hold across 2021-2024

library(tidyverse)
source("src/backtesting/07_elo_ratings.R")

cat("=== SYSTEMATIC EDGE SEARCH (2021-2024) ===\n")
cat("Looking for patterns that are CONSISTENT across years\n\n")

hist_matches <- readRDS("data/processed/atp_matches_aligned.rds")

# Helper functions
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

# Generate predictions for a full year (H1 + H2)
generate_year_predictions <- function(year, hist_matches) {
  elo_cutoff <- as.Date(sprintf("%d-01-01", year))
  year_start <- as.Date(sprintf("%d-01-01", year))
  year_end <- as.Date(sprintf("%d-12-31", year))

  prior_matches <- hist_matches %>%
    filter(match_date < elo_cutoff) %>%
    filter(!is.na(winner_name), !is.na(loser_name))

  elo_db <- build_elo_db_from_matches(prior_matches, verbose = FALSE)

  betting_file <- sprintf("data/raw/tennis_betting/%d.xlsx", year)
  if (!file.exists(betting_file)) return(NULL)

  betting <- readxl::read_xlsx(betting_file) %>%
    mutate(Date = as.Date(Date)) %>%
    filter(Date >= year_start, Date <= year_end)

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
      date = m$Date,
      year = year,
      tournament = m$Tournament,
      surface = surface,
      round = m$Round,
      best_of = m$`Best of`,
      winner = m$winner,
      loser = m$loser,
      w_odds = m$PSW,
      l_odds = m$PSL,
      w_elo = w_info$elo,
      l_elo = l_info$elo,
      elo_prob = prob_w,
      elo_correct = prob_w > 0.5
    )

    # Rolling update
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
    rename(l_rank = best_rank)

  preds
}

# Generate all predictions
cat("Generating predictions for 2021-2024...\n")
all_preds <- list()
for (year in 2021:2024) {
  cat(sprintf("  %d...\n", year))
  all_preds[[as.character(year)]] <- generate_year_predictions(year, hist_matches)
}

preds <- bind_rows(all_preds) %>%
  mutate(
    # Market info
    mkt_fav = ifelse(w_odds < l_odds, winner, loser),
    mkt_fav_odds = pmin(w_odds, l_odds),
    mkt_dog_odds = pmax(w_odds, l_odds),
    implied_fav_prob = 1 / mkt_fav_odds,

    # Elo info
    elo_pick = ifelse(elo_prob > 0.5, winner, loser),
    elo_conf = pmax(elo_prob, 1 - elo_prob),
    elo_agrees = (elo_pick == mkt_fav),

    # Betting
    bet_odds = ifelse(elo_pick == winner, w_odds, l_odds),
    profit = ifelse(elo_correct, bet_odds - 1, -1),

    # Rankings
    fav_rank = ifelse(mkt_fav == winner, w_rank, l_rank),
    dog_rank = ifelse(mkt_fav == winner, l_rank, w_rank),
    fav_top10 = !is.na(fav_rank) & fav_rank <= 10,
    fav_top20 = !is.na(fav_rank) & fav_rank <= 20,
    fav_top50 = !is.na(fav_rank) & fav_rank <= 50,
    dog_top30 = !is.na(dog_rank) & dog_rank <= 30,
    dog_top50 = !is.na(dog_rank) & dog_rank <= 50,

    # Tournament type
    is_grand_slam = str_detect(tolower(tournament), "australian|roland|wimbledon|us open"),
    is_masters = str_detect(tolower(tournament), "masters|monte carlo|madrid|rome|miami|indian|canada|cincinnati|shanghai|paris"),
    is_atp500 = str_detect(tolower(tournament), "500|dubai|acapulco|barcelona|hamburg|halle|queen|washington|beijing|tokyo|vienna|basel"),

    # Surface
    is_hard = str_detect(tolower(surface), "hard"),
    is_clay = str_detect(tolower(surface), "clay"),
    is_grass = str_detect(tolower(surface), "grass"),

    # Round
    is_early = str_detect(tolower(round), "1st|r128|r64|r32"),
    is_late = str_detect(tolower(round), "quarter|semi|final"),

    # Best of
    is_bo5 = best_of == 5,

    # Odds buckets
    fav_odds_bucket = case_when(
      mkt_fav_odds < 1.20 ~ "Heavy (<1.20)",
      mkt_fav_odds < 1.40 ~ "Strong (1.20-1.40)",
      mkt_fav_odds < 1.60 ~ "Moderate (1.40-1.60)",
      mkt_fav_odds < 1.80 ~ "Slight (1.60-1.80)",
      TRUE ~ "Close (1.80+)"
    ),

    # Elo confidence buckets
    elo_conf_bucket = case_when(
      elo_conf > 0.75 ~ "Very High (>75%)",
      elo_conf > 0.65 ~ "High (65-75%)",
      elo_conf > 0.55 ~ "Medium (55-65%)",
      TRUE ~ "Low (50-55%)"
    ),

    # Month
    month = month(date)
  )

cat(sprintf("\nTotal predictions: %d\n", nrow(preds)))
cat(sprintf("By year: %s\n\n", paste(table(preds$year), collapse=", ")))

# Function to analyze a subset across years
analyze_subset <- function(data, name, min_n_per_year = 20) {
  if (nrow(data) < 50) return(NULL)

  by_year <- data %>%
    group_by(year) %>%
    summarise(
      n = n(),
      accuracy = mean(elo_correct),
      roi = mean(profit),
      .groups = "drop"
    )

  # Require minimum sample in at least 3 years
  valid_years <- sum(by_year$n >= min_n_per_year)
  if (valid_years < 3) return(NULL)

  # Calculate consistency
  positive_years <- sum(by_year$roi > 0)
  total_n <- sum(by_year$n)
  weighted_roi <- sum(by_year$n * by_year$roi) / total_n
  roi_sd <- sd(by_year$roi)

  tibble(
    subset = name,
    total_n = total_n,
    n_years = nrow(by_year),
    valid_years = valid_years,
    positive_years = positive_years,
    weighted_roi = weighted_roi,
    roi_sd = roi_sd,
    consistency = positive_years / valid_years,
    roi_2021 = by_year$roi[by_year$year == 2021],
    roi_2022 = by_year$roi[by_year$year == 2022],
    roi_2023 = by_year$roi[by_year$year == 2023],
    roi_2024 = by_year$roi[by_year$year == 2024]
  )
}

# Systematic search
results <- list()
i <- 1

cat("=== SEARCHING EDGES ===\n\n")

# 1. Surface
cat("Testing surfaces...\n")
for (surf in c("Hard", "Clay", "Grass")) {
  results[[i]] <- analyze_subset(preds %>% filter(str_detect(tolower(surface), tolower(surf))),
                                  paste("Surface:", surf))
  i <- i + 1
}

# 2. Tournament level
cat("Testing tournament levels...\n")
results[[i]] <- analyze_subset(preds %>% filter(is_grand_slam), "Grand Slams")
i <- i + 1
results[[i]] <- analyze_subset(preds %>% filter(is_masters), "Masters")
i <- i + 1
results[[i]] <- analyze_subset(preds %>% filter(is_atp500), "ATP 500")
i <- i + 1

# 3. Round stage
cat("Testing round stages...\n")
results[[i]] <- analyze_subset(preds %>% filter(is_early), "Early Rounds")
i <- i + 1
results[[i]] <- analyze_subset(preds %>% filter(is_late), "Late Rounds (QF+)")
i <- i + 1

# 4. Best of 5
cat("Testing best-of formats...\n")
results[[i]] <- analyze_subset(preds %>% filter(is_bo5), "Best of 5")
i <- i + 1
results[[i]] <- analyze_subset(preds %>% filter(!is_bo5), "Best of 3")
i <- i + 1

# 5. Favorite odds buckets
cat("Testing odds buckets...\n")
for (bucket in unique(preds$fav_odds_bucket)) {
  results[[i]] <- analyze_subset(preds %>% filter(fav_odds_bucket == bucket),
                                  paste("Odds:", bucket))
  i <- i + 1
}

# 6. Elo confidence
cat("Testing Elo confidence levels...\n")
for (bucket in unique(preds$elo_conf_bucket)) {
  results[[i]] <- analyze_subset(preds %>% filter(elo_conf_bucket == bucket),
                                  paste("Elo conf:", bucket))
  i <- i + 1
}

# 7. Elo agrees vs disagrees
cat("Testing Elo agreement...\n")
results[[i]] <- analyze_subset(preds %>% filter(elo_agrees), "Elo agrees with market")
i <- i + 1
results[[i]] <- analyze_subset(preds %>% filter(!elo_agrees), "Elo disagrees with market")
i <- i + 1

# 8. Combined: Surface + Tournament level
cat("Testing surface + tournament combos...\n")
for (surf in c("hard", "clay", "grass")) {
  results[[i]] <- analyze_subset(
    preds %>% filter(str_detect(tolower(surface), surf), is_grand_slam),
    paste(str_to_title(surf), "Grand Slams")
  )
  i <- i + 1
  results[[i]] <- analyze_subset(
    preds %>% filter(str_detect(tolower(surface), surf), is_masters),
    paste(str_to_title(surf), "Masters")
  )
  i <- i + 1
}

# 9. Ranking-based
cat("Testing ranking patterns...\n")
results[[i]] <- analyze_subset(preds %>% filter(fav_top10), "Top 10 Favorite")
i <- i + 1
results[[i]] <- analyze_subset(preds %>% filter(fav_top20, !fav_top10), "Top 11-20 Favorite")
i <- i + 1
results[[i]] <- analyze_subset(preds %>% filter(fav_top10, dog_top30), "Top 10 vs Top 30")
i <- i + 1
results[[i]] <- analyze_subset(preds %>% filter(fav_top20, dog_top50), "Top 20 vs Top 50")
i <- i + 1

# 10. High confidence scenarios
cat("Testing high confidence scenarios...\n")
results[[i]] <- analyze_subset(
  preds %>% filter(elo_conf > 0.70, elo_agrees),
  "Elo high conf + agrees"
)
i <- i + 1
results[[i]] <- analyze_subset(
  preds %>% filter(elo_conf > 0.65, !elo_agrees),
  "Elo high conf + disagrees (upset pick)"
)
i <- i + 1

# 11. Specific tournaments
cat("Testing specific tournaments...\n")
for (tourney in c("Australian Open", "Roland Garros", "Wimbledon", "US Open")) {
  results[[i]] <- analyze_subset(
    preds %>% filter(str_detect(tournament, tourney)),
    tourney
  )
  i <- i + 1
}

# 12. Late rounds at majors
cat("Testing late rounds at majors...\n")
results[[i]] <- analyze_subset(
  preds %>% filter(is_grand_slam, is_late),
  "Grand Slam QF+"
)
i <- i + 1
results[[i]] <- analyze_subset(
  preds %>% filter(is_masters, is_late),
  "Masters QF+"
)
i <- i + 1

# 13. BO5 with high Elo confidence (skill should dominate)
results[[i]] <- analyze_subset(
  preds %>% filter(is_bo5, elo_conf > 0.65),
  "BO5 + High Elo Conf"
)
i <- i + 1

# 14. Close matches where Elo has slight edge
results[[i]] <- analyze_subset(
  preds %>% filter(mkt_fav_odds >= 1.70, mkt_fav_odds <= 2.10, elo_agrees),
  "Close match + Elo agrees"
)
i <- i + 1

# 15. Heavy favorites where Elo disagrees (upset specialist)
results[[i]] <- analyze_subset(
  preds %>% filter(mkt_fav_odds < 1.30, !elo_agrees),
  "Heavy fav + Elo picks upset"
)
i <- i + 1

# Compile results
all_results <- bind_rows(results) %>%
  filter(!is.na(subset)) %>%
  arrange(desc(consistency), desc(weighted_roi))

cat("\n========================================\n")
cat("RESULTS SORTED BY CONSISTENCY\n")
cat("(Looking for positive ROI in 3+ of 4 years)\n")
cat("========================================\n\n")

all_results %>%
  filter(valid_years >= 3) %>%
  mutate(
    weighted_roi = sprintf("%+.1f%%", 100 * weighted_roi),
    roi_sd = sprintf("%.1f%%", 100 * roi_sd),
    consistency = sprintf("%d/%d", positive_years, valid_years),
    roi_2021 = sprintf("%+.1f%%", 100 * roi_2021),
    roi_2022 = sprintf("%+.1f%%", 100 * roi_2022),
    roi_2023 = sprintf("%+.1f%%", 100 * roi_2023),
    roi_2024 = sprintf("%+.1f%%", 100 * roi_2024)
  ) %>%
  select(subset, total_n, consistency, weighted_roi, roi_sd, roi_2021, roi_2022, roi_2023, roi_2024) %>%
  print(n = 50)

cat("\n========================================\n")
cat("BEST CANDIDATES (Consistency >= 75%)\n")
cat("========================================\n\n")

best <- all_results %>%
  filter(valid_years >= 3, consistency >= 0.75, weighted_roi > 0)

if (nrow(best) > 0) {
  best %>%
    mutate(
      weighted_roi = sprintf("%+.1f%%", 100 * weighted_roi),
      consistency = sprintf("%d/%d", positive_years, valid_years)
    ) %>%
    select(subset, total_n, consistency, weighted_roi) %>%
    print()
} else {
  cat("No subsets found with >= 75% consistency and positive ROI\n")
}

saveRDS(all_results, "data/processed/systematic_edge_search_results.rds")
saveRDS(preds, "data/processed/all_predictions_2021_2024.rds")
