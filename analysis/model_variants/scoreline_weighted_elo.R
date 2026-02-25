# Scoreline-Weighted Elo (Angelini et al. approach)
#
# Standard Elo treats all wins equally. But a 6-0, 6-1 win shows
# more dominance than a 7-6, 7-6 win. We weight K-factor by margin.
#
# Margin can be computed as:
# 1. Sets differential (sets won - sets lost)
# 2. Games differential (total games won - lost)
# 3. Dominance score (games won / total games)

library(tidyverse)
source("src/backtesting/07_elo_ratings.R")

cat("=== SCORELINE-WEIGHTED ELO ===\n\n")

hist_matches <- readRDS("data/processed/atp_matches_aligned.rds")

# ============================================================================
# PARSE SCORE TO EXTRACT MARGIN
# ============================================================================

parse_score <- function(score) {
  if (is.na(score) || score == "" || str_detect(score, "W/O|RET|DEF|ABN")) {
    return(list(
      w_sets = NA, l_sets = NA,
      w_games = NA, l_games = NA,
      margin = NA, dominance = NA
    ))
  }

  # Split by space to get sets
  sets <- str_split(score, " ")[[1]]

  w_sets <- 0
  l_sets <- 0
  w_games <- 0
  l_games <- 0

  for (set in sets) {
    # Parse "6-3" or "7-6(5)" format
    # Remove tiebreak scores in parentheses
    clean_set <- str_replace(set, "\\(\\d+\\)", "")

    if (str_detect(clean_set, "^\\d+-\\d+$")) {
      games <- as.numeric(str_split(clean_set, "-")[[1]])
      w_games <- w_games + games[1]
      l_games <- l_games + games[2]

      if (games[1] > games[2]) {
        w_sets <- w_sets + 1
      } else {
        l_sets <- l_sets + 1
      }
    }
  }

  total_games <- w_games + l_games
  if (total_games == 0) {
    dominance <- NA
    margin <- NA
  } else {
    dominance <- w_games / total_games
    margin <- w_games - l_games
  }

  list(
    w_sets = w_sets, l_sets = l_sets,
    w_games = w_games, l_games = l_games,
    margin = margin, dominance = dominance
  )
}

# Test parsing
cat("Testing score parsing:\n")
test_scores <- c("6-3 6-1", "7-6(5) 7-6(6)", "6-0 6-0", "6-4 3-6 7-5")
for (s in test_scores) {
  p <- parse_score(s)
  cat(sprintf("  %s → W:%d-%d, Games:%d-%d, Dominance:%.2f\n",
              s, p$w_sets, p$l_sets, p$w_games, p$l_games, p$dominance))
}

# ============================================================================
# BUILD SCORELINE-WEIGHTED ELO
# ============================================================================

# Parse all scores
cat("\nParsing all match scores...\n")
hist_matches <- hist_matches %>%
  mutate(
    score_parsed = map(score, parse_score),
    w_sets = map_dbl(score_parsed, "w_sets"),
    l_sets = map_dbl(score_parsed, "l_sets"),
    w_games = map_dbl(score_parsed, "w_games"),
    l_games = map_dbl(score_parsed, "l_games"),
    margin = map_dbl(score_parsed, "margin"),
    dominance = map_dbl(score_parsed, "dominance")
  ) %>%
  select(-score_parsed)

cat(sprintf("Matches with valid scores: %d (%.1f%%)\n",
            sum(!is.na(hist_matches$dominance)),
            100 * mean(!is.na(hist_matches$dominance))))

# ============================================================================
# WEIGHTED K-FACTOR FUNCTION
# ============================================================================

# Angelini approach: K_effective = K_base * weight(margin)
# Weight function options:
# 1. Linear: weight = 1 + alpha * (dominance - 0.5)
# 2. Sqrt: weight = sqrt(dominance / 0.5)
# 3. Step: weight = 1.2 if dominance > 0.6 else 1.0

get_weighted_k <- function(dominance, k_base = 32, method = "linear", alpha = 1.0) {
  if (is.na(dominance)) {
    return(k_base)  # Default to standard K if no score
  }

  if (method == "linear") {
    # dominance = 0.5 → weight = 1.0
    # dominance = 0.7 → weight = 1.4 (if alpha = 2)
    # dominance = 0.3 → weight = 0.6 (if alpha = 2)
    weight <- 1 + alpha * (dominance - 0.5)
  } else if (method == "sqrt") {
    weight <- sqrt(dominance / 0.5)
  } else {
    # Step function
    weight <- ifelse(dominance > 0.6, 1.3, 1.0)
  }

  # Bound weight to reasonable range
  weight <- pmax(0.5, pmin(2.0, weight))

  k_base * weight
}

# Build weighted Elo
build_weighted_elo <- function(matches, cutoff_date, k_base = 32, alpha = 1.0) {
  training <- matches %>%
    filter(match_date < cutoff_date) %>%
    filter(!is.na(winner_name), !is.na(loser_name)) %>%
    arrange(match_date)

  DEFAULT_ELO <- 1500
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

    # Get weighted K based on dominance
    k <- get_weighted_k(m$dominance, k_base, method = "linear", alpha = alpha)

    # Overall Elo update
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

# ============================================================================
# BACKTEST COMPARISON
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

backtest_weighted_elo <- function(year, hist_matches, alpha = 1.0) {
  elo_cutoff <- as.Date(sprintf("%d-01-01", year))

  prior_matches <- hist_matches %>%
    filter(match_date < elo_cutoff) %>%
    filter(!is.na(winner_name), !is.na(loser_name))

  # Build both standard and weighted Elo
  standard_db <- build_elo_db_from_matches(prior_matches, verbose = FALSE)
  weighted_db <- build_weighted_elo(prior_matches, elo_cutoff, k_base = 32, alpha = alpha)

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
    DEFAULT_ELO <- 1500

    # Standard Elo prediction (using existing function)
    w_info <- get_player_elo(m$winner, surface, standard_db)
    l_info <- get_player_elo(m$loser, surface, standard_db)
    std_prob_w <- elo_expected_prob(w_info$elo, l_info$elo)

    # Weighted Elo prediction
    w_welo <- weighted_db$overall[[m$winner]] %||% DEFAULT_ELO
    l_welo <- weighted_db$overall[[m$loser]] %||% DEFAULT_ELO

    if (surface %in% c("Hard", "Clay", "Grass")) {
      w_surf <- weighted_db$surface[[surface]][[m$winner]] %||% DEFAULT_ELO
      l_surf <- weighted_db$surface[[surface]][[m$loser]] %||% DEFAULT_ELO
      w_welo <- 0.7 * w_surf + 0.3 * w_welo
      l_welo <- 0.7 * l_surf + 0.3 * l_welo
    }

    wgt_prob_w <- 1 / (1 + 10^((l_welo - w_welo) / 400))

    results[[i]] <- tibble(
      date = m$Date,
      year = year,
      winner = m$winner,
      loser = m$loser,
      surface = surface,
      w_odds = m$PSW,
      l_odds = m$PSL,
      std_prob = std_prob_w,
      wgt_prob = wgt_prob_w,
      std_correct = std_prob_w > 0.5,
      wgt_correct = wgt_prob_w > 0.5
    )

    # Update both models
    k <- 32
    exp_w <- 1 / (1 + 10^((l_info$elo - w_info$elo) / 400))

    idx_w <- which(standard_db$overall$player == m$winner)
    idx_l <- which(standard_db$overall$player == m$loser)
    if (length(idx_w) > 0) standard_db$overall$elo[idx_w] <- w_info$elo + k * (1 - exp_w)
    if (length(idx_l) > 0) standard_db$overall$elo[idx_l] <- l_info$elo + k * (0 - (1 - exp_w))

    # Weighted update (without actual score since we don't have it for betting matches)
    weighted_db$overall[[m$winner]] <- w_welo + k * (1 - (1 / (1 + 10^((l_welo - w_welo) / 400))))
    weighted_db$overall[[m$loser]] <- l_welo + k * (0 - (1 - (1 / (1 + 10^((l_welo - w_welo) / 400)))))
  }

  bind_rows(results) %>%
    mutate(
      std_pick = ifelse(std_prob > 0.5, winner, loser),
      wgt_pick = ifelse(wgt_prob > 0.5, winner, loser),
      std_bet_odds = ifelse(std_pick == winner, w_odds, l_odds),
      wgt_bet_odds = ifelse(wgt_pick == winner, w_odds, l_odds),
      std_profit = ifelse(std_correct, std_bet_odds - 1, -1),
      wgt_profit = ifelse(wgt_correct, wgt_bet_odds - 1, -1)
    )
}

# ============================================================================
# RUN COMPARISON
# ============================================================================

cat("\nRunning backtest comparison (alpha=1.0)...\n")

all_results <- list()
for (year in 2021:2024) {
  cat(sprintf("  %d...\n", year))
  all_results[[as.character(year)]] <- backtest_weighted_elo(year, hist_matches, alpha = 1.0)
}

combined <- bind_rows(all_results, .id = "year_str")

cat("\n========================================\n")
cat("RESULTS: STANDARD ELO vs SCORELINE-WEIGHTED ELO\n")
cat("========================================\n\n")

cat("Overall:\n")
cat(sprintf("  Standard Elo accuracy: %.1f%%\n", 100 * mean(combined$std_correct)))
cat(sprintf("  Weighted Elo accuracy: %.1f%%\n", 100 * mean(combined$wgt_correct)))
cat(sprintf("  Standard Elo ROI: %+.2f%%\n", 100 * mean(combined$std_profit)))
cat(sprintf("  Weighted Elo ROI: %+.2f%%\n\n", 100 * mean(combined$wgt_profit)))

cat("By year:\n")
combined %>%
  group_by(year_str) %>%
  summarise(
    n = n(),
    std_accuracy = mean(std_correct),
    wgt_accuracy = mean(wgt_correct),
    std_roi = mean(std_profit),
    wgt_roi = mean(wgt_profit),
    .groups = "drop"
  ) %>%
  mutate(
    std_accuracy = sprintf("%.1f%%", 100 * std_accuracy),
    wgt_accuracy = sprintf("%.1f%%", 100 * wgt_accuracy),
    std_roi = sprintf("%+.2f%%", 100 * std_roi),
    wgt_roi = sprintf("%+.2f%%", 100 * wgt_roi)
  ) %>%
  print()

# ============================================================================
# SENSITIVITY TO ALPHA
# ============================================================================

cat("\n========================================\n")
cat("SENSITIVITY: ALPHA PARAMETER\n")
cat("========================================\n\n")

# Test different alpha values
alphas <- c(0.5, 1.0, 1.5, 2.0)
alpha_results <- list()

for (a in alphas) {
  cat(sprintf("Testing alpha = %.1f...\n", a))

  year_results <- list()
  for (year in 2021:2024) {
    year_results[[as.character(year)]] <- backtest_weighted_elo(year, hist_matches, alpha = a)
  }

  combined_a <- bind_rows(year_results)
  alpha_results[[sprintf("alpha_%.1f", a)]] <- tibble(
    alpha = a,
    accuracy = mean(combined_a$wgt_correct),
    roi = mean(combined_a$wgt_profit)
  )
}

bind_rows(alpha_results) %>%
  mutate(
    accuracy = sprintf("%.1f%%", 100 * accuracy),
    roi = sprintf("%+.2f%%", 100 * roi)
  ) %>%
  print()

cat("\n========================================\n")
cat("SUMMARY\n")
cat("========================================\n\n")

std_roi <- mean(combined$std_profit)
wgt_roi <- mean(combined$wgt_profit)

cat(sprintf("Standard Elo ROI: %+.2f%%\n", 100 * std_roi))
cat(sprintf("Weighted Elo ROI: %+.2f%%\n", 100 * wgt_roi))
cat(sprintf("Improvement: %+.2fpp\n", 100 * (wgt_roi - std_roi)))

if (wgt_roi > std_roi) {
  cat("\nScoreline weighting IMPROVES performance.\n")
} else {
  cat("\nScoreline weighting does NOT improve performance.\n")
}

saveRDS(combined, "data/processed/scoreline_weighted_elo_results.rds")
cat("\nResults saved to data/processed/scoreline_weighted_elo_results.rds\n")
