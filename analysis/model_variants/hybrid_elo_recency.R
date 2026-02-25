# Recency-Weighted Elo
# Theory: Recent form matters more than career history
# We use exponential decay to weight recent matches more heavily

library(tidyverse)

cat("=== RECENCY-WEIGHTED ELO ===\n\n")

hist_matches <- readRDS("data/processed/atp_matches_aligned.rds")

# Standard Elo parameters
DEFAULT_ELO <- 1500
K_FACTOR <- 32
MIN_SURFACE_MATCHES <- 10

# Recency Elo: higher K for recent matches, lower K for old matches
# Or: maintain both "long-term" and "short-term" Elo and blend

# Approach: Dual-Elo System
# - Long-term Elo: Standard K=32, all history
# - Short-term Elo: K=64, only last 6 months, decays to 1500 if inactive

build_dual_elo <- function(matches, cutoff_date, short_term_days = 180) {
  training <- matches %>%
    filter(match_date < cutoff_date) %>%
    filter(!is.na(winner_name), !is.na(loser_name)) %>%
    arrange(match_date)

  # Long-term Elo
  lt_elo <- list()
  lt_surface <- list()
  for (surf in c("Hard", "Clay", "Grass")) {
    lt_surface[[surf]] <- list()
  }

  # Short-term Elo (only recent matches)
  st_cutoff <- cutoff_date - short_term_days
  st_elo <- list()
  st_matches <- list()  # Track match count in window

  for (i in 1:nrow(training)) {
    m <- training[i, ]
    w <- m$winner_name
    l <- m$loser_name
    surface <- m$surface

    # --- Long-term update ---
    w_lt <- lt_elo[[w]]; if (is.null(w_lt)) w_lt <- DEFAULT_ELO
    l_lt <- lt_elo[[l]]; if (is.null(l_lt)) l_lt <- DEFAULT_ELO
    exp_w <- 1 / (1 + 10^((l_lt - w_lt) / 400))
    lt_elo[[w]] <- w_lt + K_FACTOR * (1 - exp_w)
    lt_elo[[l]] <- l_lt + K_FACTOR * (0 - (1 - exp_w))

    # Surface-specific long-term
    if (surface %in% c("Hard", "Clay", "Grass")) {
      w_surf <- lt_surface[[surface]][[w]]; if (is.null(w_surf)) w_surf <- DEFAULT_ELO
      l_surf <- lt_surface[[surface]][[l]]; if (is.null(l_surf)) l_surf <- DEFAULT_ELO
      exp_surf <- 1 / (1 + 10^((l_surf - w_surf) / 400))
      lt_surface[[surface]][[w]] <- w_surf + K_FACTOR * (1 - exp_surf)
      lt_surface[[surface]][[l]] <- l_surf + K_FACTOR * (0 - (1 - exp_surf))
    }

    # --- Short-term update (only recent matches) ---
    if (m$match_date >= st_cutoff) {
      w_st <- st_elo[[w]]; if (is.null(w_st)) w_st <- DEFAULT_ELO
      l_st <- st_elo[[l]]; if (is.null(l_st)) l_st <- DEFAULT_ELO
      exp_st <- 1 / (1 + 10^((l_st - w_st) / 400))
      # Higher K for short-term (faster adaptation)
      st_elo[[w]] <- w_st + 48 * (1 - exp_st)
      st_elo[[l]] <- l_st + 48 * (0 - (1 - exp_st))

      # Track match count
      st_matches[[w]] <- (st_matches[[w]] %||% 0) + 1
      st_matches[[l]] <- (st_matches[[l]] %||% 0) + 1
    }
  }

  list(
    long_term = lt_elo,
    long_term_surface = lt_surface,
    short_term = st_elo,
    short_term_matches = st_matches
  )
}

# Get blended Elo (combine long-term and short-term)
get_blended_elo <- function(player, surface, elo_db, st_weight = 0.3, min_st_matches = 3) {
  lt <- elo_db$long_term[[player]] %||% DEFAULT_ELO
  st <- elo_db$short_term[[player]] %||% DEFAULT_ELO
  st_n <- elo_db$short_term_matches[[player]] %||% 0

  # Surface-specific long-term
  if (!is.null(surface) && surface %in% c("Hard", "Clay", "Grass")) {
    lt_surf <- elo_db$long_term_surface[[surface]][[player]] %||% DEFAULT_ELO
    # Blend surface and overall
    lt <- 0.7 * lt_surf + 0.3 * lt
  }

  # If not enough recent matches, rely more on long-term
  if (st_n < min_st_matches) {
    return(lt)
  }

  # Blend long-term and short-term
  blended <- (1 - st_weight) * lt + st_weight * st
  blended
}

# Backtest function
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

backtest_recency <- function(year, hist_matches, st_weight = 0.3) {
  elo_cutoff <- as.Date(sprintf("%d-01-01", year))

  prior_matches <- hist_matches %>%
    filter(match_date < elo_cutoff) %>%
    filter(!is.na(winner_name), !is.na(loser_name))

  # Build dual Elo system
  elo_db <- build_dual_elo(prior_matches, elo_cutoff, short_term_days = 180)

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

    # Standard Elo (long-term only)
    w_lt <- elo_db$long_term[[m$winner]] %||% DEFAULT_ELO
    l_lt <- elo_db$long_term[[m$loser]] %||% DEFAULT_ELO

    if (surface %in% c("Hard", "Clay", "Grass")) {
      w_surf <- elo_db$long_term_surface[[surface]][[m$winner]] %||% DEFAULT_ELO
      l_surf <- elo_db$long_term_surface[[surface]][[m$loser]] %||% DEFAULT_ELO
      w_lt <- 0.7 * w_surf + 0.3 * w_lt
      l_lt <- 0.7 * l_surf + 0.3 * l_lt
    }

    elo_prob_w <- 1 / (1 + 10^((l_lt - w_lt) / 400))

    # Blended Elo (with recency)
    w_blend <- get_blended_elo(m$winner, surface, elo_db, st_weight)
    l_blend <- get_blended_elo(m$loser, surface, elo_db, st_weight)
    blend_prob_w <- 1 / (1 + 10^((l_blend - w_blend) / 400))

    results[[i]] <- tibble(
      date = m$Date,
      winner = m$winner,
      loser = m$loser,
      w_odds = m$PSW,
      l_odds = m$PSL,
      elo_prob = elo_prob_w,
      blend_prob = blend_prob_w,
      elo_correct = elo_prob_w > 0.5,
      blend_correct = blend_prob_w > 0.5
    )

    # Rolling update
    w_elo <- elo_db$long_term[[m$winner]] %||% DEFAULT_ELO
    l_elo <- elo_db$long_term[[m$loser]] %||% DEFAULT_ELO
    exp_w <- 1 / (1 + 10^((l_elo - w_elo) / 400))
    elo_db$long_term[[m$winner]] <- w_elo + K_FACTOR * (1 - exp_w)
    elo_db$long_term[[m$loser]] <- l_elo + K_FACTOR * (0 - (1 - exp_w))

    # Short-term update
    w_st <- elo_db$short_term[[m$winner]] %||% DEFAULT_ELO
    l_st <- elo_db$short_term[[m$loser]] %||% DEFAULT_ELO
    exp_st <- 1 / (1 + 10^((l_st - w_st) / 400))
    elo_db$short_term[[m$winner]] <- w_st + 48 * (1 - exp_st)
    elo_db$short_term[[m$loser]] <- l_st + 48 * (0 - (1 - exp_st))
  }

  preds <- bind_rows(results) %>%
    mutate(
      elo_pick = ifelse(elo_prob > 0.5, winner, loser),
      blend_pick = ifelse(blend_prob > 0.5, winner, loser),
      elo_bet_odds = ifelse(elo_pick == winner, w_odds, l_odds),
      blend_bet_odds = ifelse(blend_pick == winner, w_odds, l_odds),
      elo_profit = ifelse(elo_correct, elo_bet_odds - 1, -1),
      blend_profit = ifelse(blend_correct, blend_bet_odds - 1, -1)
    )

  preds
}

# Run backtest
cat("Running recency-weighted Elo backtest 2021-2024...\n\n")

all_results <- list()
for (year in 2021:2024) {
  cat(sprintf("  %d...\n", year))
  all_results[[as.character(year)]] <- backtest_recency(year, hist_matches, st_weight = 0.3)
}

combined <- bind_rows(all_results, .id = "year")

cat("\n========================================\n")
cat("RESULTS: STANDARD ELO vs RECENCY-WEIGHTED ELO\n")
cat("========================================\n\n")

cat("Overall:\n")
cat(sprintf("  Standard Elo accuracy: %.1f%%\n", 100 * mean(combined$elo_correct)))
cat(sprintf("  Recency Elo accuracy: %.1f%%\n", 100 * mean(combined$blend_correct)))
cat(sprintf("  Standard Elo ROI: %+.1f%%\n", 100 * mean(combined$elo_profit)))
cat(sprintf("  Recency Elo ROI: %+.1f%%\n\n", 100 * mean(combined$blend_profit)))

cat("By year:\n")
combined %>%
  group_by(year) %>%
  summarise(
    n = n(),
    elo_accuracy = mean(elo_correct),
    blend_accuracy = mean(blend_correct),
    elo_roi = mean(elo_profit),
    blend_roi = mean(blend_profit),
    .groups = "drop"
  ) %>%
  mutate(
    elo_accuracy = sprintf("%.1f%%", 100 * elo_accuracy),
    blend_accuracy = sprintf("%.1f%%", 100 * blend_accuracy),
    elo_roi = sprintf("%+.1f%%", 100 * elo_roi),
    blend_roi = sprintf("%+.1f%%", 100 * blend_roi)
  ) %>%
  print()

# When models disagree
cat("\nWhen Standard and Recency Elo DISAGREE:\n")
disagree <- combined %>% filter(elo_pick != blend_pick)
cat(sprintf("  N: %d (%.1f%% of matches)\n", nrow(disagree), 100*nrow(disagree)/nrow(combined)))
cat(sprintf("  Standard Elo accuracy: %.1f%%\n", 100 * mean(disagree$elo_correct)))
cat(sprintf("  Recency Elo accuracy: %.1f%%\n", 100 * mean(disagree$blend_correct)))
cat(sprintf("  Standard Elo ROI: %+.1f%%\n", 100 * mean(disagree$elo_profit)))
cat(sprintf("  Recency Elo ROI: %+.1f%%\n", 100 * mean(disagree$blend_profit)))

saveRDS(combined, "data/processed/hybrid_elo_recency_results.rds")
