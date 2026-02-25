# Matchup Features (Handedness) + Fatigue/Scheduling Features
# Testing if these dimensions reveal edges
#
# ODDS PARAMETER: Set to "pinnacle" for Pinnacle opening, "b365" for Bet365, "avg" for average
# NOTE: "max" is hindsight data (you don't know best line until after) - avoid for realistic backtests
ODDS_TYPE <- "pinnacle"  # Options: "pinnacle", "b365", "avg"

library(tidyverse)
source("src/backtesting/07_elo_ratings.R")

cat("=== MATCHUP & FATIGUE FEATURE ANALYSIS ===\n")
cat(sprintf("Using %s odds\n\n", toupper(ODDS_TYPE)))

hist_matches <- readRDS("data/processed/atp_matches_aligned.rds")

# ============================================================================
# BUILD FEATURE DATABASES
# ============================================================================

# 1. Handedness database
cat("Building handedness database...\n")
hand_db <- hist_matches %>%
  filter(!is.na(winner_hand), winner_hand != "U") %>%
  select(player = winner_name, hand = winner_hand) %>%
  bind_rows(
    hist_matches %>%
      filter(!is.na(loser_hand), loser_hand != "U") %>%
      select(player = loser_name, hand = loser_hand)
  ) %>%
  group_by(player) %>%
  summarise(hand = first(hand), .groups = "drop")

cat(sprintf("  Players with handedness: %d\n", nrow(hand_db)))
cat(sprintf("  Lefties: %d (%.1f%%)\n", sum(hand_db$hand == "L"),
            100 * mean(hand_db$hand == "L")))

# 2. Height database (proxy for playing style - tall = big server)
cat("\nBuilding height database...\n")
height_db <- hist_matches %>%
  filter(!is.na(winner_ht)) %>%
  select(player = winner_name, height = winner_ht) %>%
  bind_rows(
    hist_matches %>%
      filter(!is.na(loser_ht)) %>%
      select(player = loser_name, height = loser_ht)
  ) %>%
  group_by(player) %>%
  summarise(height = mean(height, na.rm = TRUE), .groups = "drop")

cat(sprintf("  Players with height: %d\n", nrow(height_db)))
cat(sprintf("  Avg height: %.1f cm\n", mean(height_db$height, na.rm = TRUE)))

# 3. Calculate days since last match and recent match load
cat("\nBuilding schedule/fatigue features...\n")

# Create a match-level dataset with player appearances
player_schedule <- bind_rows(
  hist_matches %>%
    select(player = winner_name, match_date, tourney_name) %>%
    mutate(result = "W"),
  hist_matches %>%
    select(player = loser_name, match_date, tourney_name) %>%
    mutate(result = "L")
) %>%
  arrange(player, match_date)

# Function to get fatigue features for a player on a given date
get_fatigue_features <- function(player_name, date, schedule_db) {
  player_matches <- schedule_db %>%
    filter(player == player_name, match_date < date) %>%
    arrange(desc(match_date))

  if (nrow(player_matches) == 0) {
    return(list(
      days_since_last = NA,
      matches_last_14d = 0,
      matches_last_30d = 0,
      recent_wins = 0,
      recent_losses = 0
    ))
  }

  last_match <- player_matches$match_date[1]
  days_since <- as.numeric(date - last_match)

  recent_14 <- player_matches %>% filter(match_date >= date - 14)
  recent_30 <- player_matches %>% filter(match_date >= date - 30)

  list(
    days_since_last = days_since,
    matches_last_14d = nrow(recent_14),
    matches_last_30d = nrow(recent_30),
    recent_wins = sum(recent_30$result == "W"),
    recent_losses = sum(recent_30$result == "L")
  )
}

# ============================================================================
# BACKTEST WITH FEATURES
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

backtest_with_features <- function(year, hist_matches, hand_db, height_db, player_schedule) {
  elo_cutoff <- as.Date(sprintf("%d-01-01", year))

  prior_matches <- hist_matches %>%
    filter(match_date < elo_cutoff) %>%
    filter(!is.na(winner_name), !is.na(loser_name))

  elo_db <- build_elo_db_from_matches(prior_matches, verbose = FALSE)

  # Prior schedule for fatigue calc
  prior_schedule <- player_schedule %>% filter(match_date < elo_cutoff)

  betting_file <- sprintf("data/raw/tennis_betting/%d.xlsx", year)
  betting_raw <- readxl::read_xlsx(betting_file) %>%
    mutate(Date = as.Date(Date))

  # Select odds columns based on ODDS_TYPE parameter
  if (ODDS_TYPE == "b365") {
    betting <- betting_raw %>%
      mutate(PSW = B365W, PSL = B365L)  # Use Bet365 odds
  } else if (ODDS_TYPE == "avg") {
    betting <- betting_raw %>%
      mutate(PSW = AvgW, PSL = AvgL)  # Use average odds
  } else {
    betting <- betting_raw  # Use Pinnacle opening (default)
  }

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
    current_date <- m$Date

    # Elo prediction
    w_info <- get_player_elo(m$winner, surface, elo_db)
    l_info <- get_player_elo(m$loser, surface, elo_db)
    elo_prob_w <- elo_expected_prob(w_info$elo, l_info$elo)

    # Handedness
    w_hand <- hand_db$hand[hand_db$player == m$winner]
    l_hand <- hand_db$hand[hand_db$player == m$loser]
    w_hand <- if (length(w_hand) == 0) "U" else w_hand
    l_hand <- if (length(l_hand) == 0) "U" else l_hand

    matchup_type <- case_when(
      w_hand == "L" & l_hand == "L" ~ "L_vs_L",
      w_hand == "L" | l_hand == "L" ~ "L_vs_R",
      TRUE ~ "R_vs_R"
    )

    # Height
    w_height <- height_db$height[height_db$player == m$winner]
    l_height <- height_db$height[height_db$player == m$loser]
    w_height <- if (length(w_height) == 0) NA else w_height
    l_height <- if (length(l_height) == 0) NA else l_height
    height_diff <- if (!is.na(w_height) && !is.na(l_height)) w_height - l_height else NA

    # Fatigue (simplified - just days since last and match count)
    w_last <- prior_schedule %>%
      filter(player == m$winner, match_date < current_date) %>%
      arrange(desc(match_date)) %>%
      slice(1)
    l_last <- prior_schedule %>%
      filter(player == m$loser, match_date < current_date) %>%
      arrange(desc(match_date)) %>%
      slice(1)

    w_days_since <- if (nrow(w_last) > 0) as.numeric(current_date - w_last$match_date[1]) else NA
    l_days_since <- if (nrow(l_last) > 0) as.numeric(current_date - l_last$match_date[1]) else NA

    # Match load last 30 days
    w_load_30 <- prior_schedule %>%
      filter(player == m$winner, match_date >= current_date - 30, match_date < current_date) %>%
      nrow()
    l_load_30 <- prior_schedule %>%
      filter(player == m$loser, match_date >= current_date - 30, match_date < current_date) %>%
      nrow()

    results[[i]] <- tibble(
      date = current_date,
      year = year,
      winner = m$winner,
      loser = m$loser,
      surface = surface,
      w_odds = m$PSW,
      l_odds = m$PSL,
      elo_prob = elo_prob_w,
      # Matchup features
      matchup_type = matchup_type,
      w_hand = w_hand,
      l_hand = l_hand,
      height_diff = height_diff,
      # Fatigue features
      w_days_since = w_days_since,
      l_days_since = l_days_since,
      w_load_30 = w_load_30,
      l_load_30 = l_load_30
    )

    # Update schedule for rolling fatigue calc
    prior_schedule <- bind_rows(prior_schedule,
                                 tibble(player = m$winner, match_date = current_date, tourney_name = m$Tournament, result = "W"),
                                 tibble(player = m$loser, match_date = current_date, tourney_name = m$Tournament, result = "L"))

    # Rolling Elo update
    update <- elo_update(w_info$elo, l_info$elo)
    idx_w <- which(elo_db$overall$player == m$winner)
    idx_l <- which(elo_db$overall$player == m$loser)
    if (length(idx_w) > 0) elo_db$overall$elo[idx_w] <- update$new_winner_elo
    if (length(idx_l) > 0) elo_db$overall$elo[idx_l] <- update$new_loser_elo
  }

  bind_rows(results)
}

# Run for 2021-2024
cat("\nRunning backtest with matchup/fatigue features...\n")
all_preds <- list()
for (year in 2021:2024) {
  cat(sprintf("  %d...\n", year))
  all_preds[[as.character(year)]] <- backtest_with_features(
    year, hist_matches, hand_db, height_db, player_schedule
  )
}

preds <- bind_rows(all_preds) %>%
  mutate(
    # Derived features
    mkt_fav = ifelse(w_odds < l_odds, winner, loser),
    mkt_fav_odds = pmin(w_odds, l_odds),
    elo_pick = ifelse(elo_prob > 0.5, winner, loser),
    elo_correct = (elo_pick == winner),
    bet_odds = ifelse(elo_pick == winner, w_odds, l_odds),
    profit = ifelse(elo_correct, bet_odds - 1, -1),

    # Fatigue differentials (positive = winner more rested)
    rest_diff = l_days_since - w_days_since,  # Higher = winner more tired relative to loser (counterintuitive!)
    load_diff = w_load_30 - l_load_30,  # Higher = winner played more recently

    # Categorize
    fav_more_rested = case_when(
      is.na(w_days_since) | is.na(l_days_since) ~ "Unknown",
      mkt_fav == winner & w_days_since > l_days_since ~ "Yes",
      mkt_fav == loser & l_days_since > w_days_since ~ "Yes",
      TRUE ~ "No"
    ),

    # Is favorite a lefty?
    fav_is_lefty = (mkt_fav == winner & w_hand == "L") | (mkt_fav == loser & l_hand == "L")
  )

cat(sprintf("\nTotal predictions: %d\n", nrow(preds)))

# ============================================================================
# ANALYSIS
# ============================================================================

cat("\n========================================\n")
cat("HANDEDNESS MATCHUP ANALYSIS\n")
cat("========================================\n\n")

preds %>%
  group_by(matchup_type) %>%
  summarise(
    n = n(),
    elo_accuracy = mean(elo_correct),
    elo_roi = mean(profit),
    .groups = "drop"
  ) %>%
  mutate(
    elo_accuracy = sprintf("%.1f%%", 100 * elo_accuracy),
    elo_roi = sprintf("%+.2f%%", 100 * elo_roi)
  ) %>%
  print()

# Lefty vs Righty - who does Elo favor?
cat("\nL vs R matchups - does Elo systematically favor one side?\n")
lvr <- preds %>% filter(matchup_type == "L_vs_R")

# When lefty is favorite vs when righty is favorite
cat("\n  When LEFTY is market favorite:\n")
lefty_fav <- lvr %>% filter(fav_is_lefty)
cat(sprintf("    N: %d\n", nrow(lefty_fav)))
cat(sprintf("    Elo accuracy: %.1f%%\n", 100 * mean(lefty_fav$elo_correct)))
cat(sprintf("    Elo ROI: %+.2f%%\n", 100 * mean(lefty_fav$profit)))

cat("\n  When RIGHTY is market favorite:\n")
righty_fav <- lvr %>% filter(!fav_is_lefty)
cat(sprintf("    N: %d\n", nrow(righty_fav)))
cat(sprintf("    Elo accuracy: %.1f%%\n", 100 * mean(righty_fav$elo_correct)))
cat(sprintf("    Elo ROI: %+.2f%%\n", 100 * mean(righty_fav$profit)))

# By year for L vs R
cat("\nL vs R by year:\n")
lvr %>%
  group_by(year) %>%
  summarise(n = n(), roi = mean(profit), .groups = "drop") %>%
  mutate(roi = sprintf("%+.2f%%", 100 * roi)) %>%
  print()

cat("\n========================================\n")
cat("FATIGUE/SCHEDULING ANALYSIS\n")
cat("========================================\n\n")

# Filter to matches where we have fatigue data
with_fatigue <- preds %>% filter(!is.na(w_days_since), !is.na(l_days_since))
cat(sprintf("Matches with fatigue data: %d (%.1f%%)\n\n",
            nrow(with_fatigue), 100 * nrow(with_fatigue)/nrow(preds)))

# Days since last match buckets
cat("By winner's days since last match:\n")
with_fatigue %>%
  mutate(w_rest_bucket = case_when(
    w_days_since <= 2 ~ "0-2 days (back-to-back)",
    w_days_since <= 7 ~ "3-7 days (same week)",
    w_days_since <= 14 ~ "8-14 days (week off)",
    TRUE ~ "15+ days (extended rest)"
  )) %>%
  group_by(w_rest_bucket) %>%
  summarise(n = n(), elo_accuracy = mean(elo_correct), elo_roi = mean(profit), .groups = "drop") %>%
  mutate(elo_accuracy = sprintf("%.1f%%", 100 * elo_accuracy), elo_roi = sprintf("%+.2f%%", 100 * elo_roi)) %>%
  print()

cat("\nBy favorite's rest advantage:\n")
with_fatigue %>%
  filter(fav_more_rested != "Unknown") %>%
  group_by(fav_more_rested) %>%
  summarise(n = n(), elo_accuracy = mean(elo_correct), elo_roi = mean(profit), .groups = "drop") %>%
  mutate(elo_accuracy = sprintf("%.1f%%", 100 * elo_accuracy), elo_roi = sprintf("%+.2f%%", 100 * elo_roi)) %>%
  print()

# Match load analysis
cat("\nBy winner's match load (last 30 days):\n")
with_fatigue %>%
  mutate(w_load_bucket = case_when(
    w_load_30 == 0 ~ "0 matches (fresh)",
    w_load_30 <= 3 ~ "1-3 matches",
    w_load_30 <= 6 ~ "4-6 matches",
    TRUE ~ "7+ matches (heavy load)"
  )) %>%
  group_by(w_load_bucket) %>%
  summarise(n = n(), elo_accuracy = mean(elo_correct), elo_roi = mean(profit), .groups = "drop") %>%
  mutate(elo_accuracy = sprintf("%.1f%%", 100 * elo_accuracy), elo_roi = sprintf("%+.2f%%", 100 * elo_roi)) %>%
  print()

# Combined: Fatigue by year
cat("\nFatigue-based splits by year (when favorite has rest advantage):\n")
with_fatigue %>%
  filter(fav_more_rested == "Yes") %>%
  group_by(year) %>%
  summarise(n = n(), roi = mean(profit), .groups = "drop") %>%
  mutate(roi = sprintf("%+.2f%%", 100 * roi)) %>%
  print()

cat("\n========================================\n")
cat("HEIGHT DIFFERENTIAL ANALYSIS\n")
cat("========================================\n\n")

with_height <- preds %>% filter(!is.na(height_diff))
cat(sprintf("Matches with height data: %d (%.1f%%)\n\n",
            nrow(with_height), 100 * nrow(with_height)/nrow(preds)))

with_height %>%
  mutate(height_bucket = case_when(
    abs(height_diff) <= 3 ~ "Similar height (±3cm)",
    height_diff > 3 ~ "Winner taller (>3cm)",
    TRUE ~ "Winner shorter (>3cm)"
  )) %>%
  group_by(height_bucket) %>%
  summarise(n = n(), elo_accuracy = mean(elo_correct), elo_roi = mean(profit), .groups = "drop") %>%
  mutate(elo_accuracy = sprintf("%.1f%%", 100 * elo_accuracy), elo_roi = sprintf("%+.2f%%", 100 * elo_roi)) %>%
  print()

saveRDS(preds, "data/processed/matchup_fatigue_predictions.rds")

# ============================================================================
# COMBINED FEATURE ANALYSIS
# ============================================================================

cat("\n========================================\n")
cat("COMBINED FEATURE ANALYSIS\n")
cat("========================================\n\n")

# Combine promising features: height + rest
combined <- preds %>%
  filter(!is.na(height_diff), !is.na(w_days_since)) %>%
  mutate(
    winner_taller = height_diff > 3,
    winner_rested = w_days_since >= 8 & w_days_since <= 14
  )

cat("Winner taller (>3cm) + Well-rested (8-14 days):\n")
combined %>%
  mutate(
    combo = case_when(
      winner_taller & winner_rested ~ "Both favorable",
      winner_taller ~ "Taller only",
      winner_rested ~ "Rested only",
      TRUE ~ "Neither"
    )
  ) %>%
  group_by(combo) %>%
  summarise(
    n = n(),
    elo_accuracy = mean(elo_correct),
    elo_roi = mean(profit),
    .groups = "drop"
  ) %>%
  mutate(
    elo_accuracy = sprintf("%.1f%%", 100 * elo_accuracy),
    elo_roi = sprintf("%+.2f%%", 100 * elo_roi)
  ) %>%
  arrange(desc(n)) %>%
  print()

# By year for the "taller + rested" combo
cat("\n'Both favorable' by year:\n")
combined %>%
  filter(winner_taller, winner_rested) %>%
  group_by(year) %>%
  summarise(n = n(), roi = mean(profit), .groups = "drop") %>%
  mutate(roi = sprintf("%+.2f%%", 100 * roi)) %>%
  print()

# Try: Elo pick IS the taller player
cat("\n\nWhen Elo pick is TALLER than opponent:\n")
preds_enhanced <- preds %>%
  filter(!is.na(height_diff)) %>%
  mutate(
    elo_pick_is_taller = (elo_pick == winner & height_diff > 3) | (elo_pick == loser & height_diff < -3)
  )

preds_enhanced %>%
  group_by(elo_pick_is_taller) %>%
  summarise(
    n = n(),
    elo_accuracy = mean(elo_correct),
    elo_roi = mean(profit),
    .groups = "drop"
  ) %>%
  mutate(
    elo_accuracy = sprintf("%.1f%%", 100 * elo_accuracy),
    elo_roi = sprintf("%+.2f%%", 100 * elo_roi)
  ) %>%
  print()

# By year
cat("\nElo pick is taller - by year:\n")
preds_enhanced %>%
  filter(elo_pick_is_taller) %>%
  group_by(year) %>%
  summarise(n = n(), roi = mean(profit), .groups = "drop") %>%
  mutate(roi = sprintf("%+.2f%%", 100 * roi)) %>%
  print()

# Heavy match load + Elo pick
cat("\n\nWhen Elo pick has heavy match load (7+ in 30 days):\n")
preds %>%
  filter(!is.na(w_load_30), !is.na(l_load_30)) %>%
  mutate(
    elo_pick_heavy_load = (elo_pick == winner & w_load_30 >= 7) | (elo_pick == loser & l_load_30 >= 7)
  ) %>%
  group_by(elo_pick_heavy_load) %>%
  summarise(
    n = n(),
    elo_accuracy = mean(elo_correct),
    elo_roi = mean(profit),
    .groups = "drop"
  ) %>%
  mutate(
    elo_accuracy = sprintf("%.1f%%", 100 * elo_accuracy),
    elo_roi = sprintf("%+.2f%%", 100 * elo_roi)
  ) %>%
  print()

# R vs R only (avoid lefty complexity)
cat("\n\nR vs R matchups only:\n")
preds %>%
  filter(matchup_type == "R_vs_R", !is.na(height_diff), !is.na(w_days_since)) %>%
  mutate(
    winner_taller = height_diff > 3,
    winner_rested = w_days_since >= 8 & w_days_since <= 14
  ) %>%
  mutate(
    combo = case_when(
      winner_taller & winner_rested ~ "Both favorable",
      winner_taller ~ "Taller only",
      winner_rested ~ "Rested only",
      TRUE ~ "Neither"
    )
  ) %>%
  group_by(combo) %>%
  summarise(
    n = n(),
    elo_accuracy = mean(elo_correct),
    elo_roi = mean(profit),
    .groups = "drop"
  ) %>%
  mutate(
    elo_accuracy = sprintf("%.1f%%", 100 * elo_accuracy),
    elo_roi = sprintf("%+.2f%%", 100 * elo_roi)
  ) %>%
  arrange(desc(n)) %>%
  print()

# Year breakdown for R vs R taller only
cat("\nR vs R, winner taller - by year:\n")
preds %>%
  filter(matchup_type == "R_vs_R", !is.na(height_diff), height_diff > 3) %>%
  group_by(year) %>%
  summarise(n = n(), roi = mean(profit), .groups = "drop") %>%
  mutate(roi = sprintf("%+.2f%%", 100 * roi)) %>%
  print()
