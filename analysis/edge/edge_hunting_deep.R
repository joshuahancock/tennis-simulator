# Edge Hunting Part 2: Deeper Dimensions
# Focus on player characteristics, matchup types, and the promising Clay Masters signal

library(tidyverse)

# Load enriched data
preds <- readRDS("data/processed/preds_enriched.rds")
hist_matches <- readRDS("data/processed/atp_matches_aligned.rds")

cat("=== DEEP EDGE HUNTING ===\n\n")

# First, let's understand Clay Masters better
cat("========================================\n")
cat("DEEP DIVE: CLAY MASTERS (N=53, ROI=+13.5%)\n")
cat("========================================\n\n")

clay_masters <- preds %>%
  filter(surface == "Clay", str_detect(tournament, "Masters|Monte Carlo|Madrid|Rome"))

cat("Tournaments in this subset:\n")
clay_masters %>% count(tournament) %>% print()

cat("\nBy round:\n")
clay_masters %>%
  group_by(round) %>%
  summarise(
    n = n(),
    accuracy = mean(elo_correct),
    roi = mean(profit),
    .groups = "drop"
  ) %>%
  arrange(desc(roi)) %>%
  print()

cat("\nBy Elo confidence:\n")
clay_masters %>%
  mutate(elo_high_conf = elo_conf > 0.6) %>%
  group_by(elo_high_conf) %>%
  summarise(
    n = n(),
    accuracy = mean(elo_correct),
    roi = mean(profit),
    avg_odds = mean(bet_odds),
    .groups = "drop"
  ) %>%
  print()

# Add player characteristics from historical data
cat("\n========================================\n")
cat("ADDING PLAYER CHARACTERISTICS\n")
cat("========================================\n\n")

# Get player info from historical matches
player_info <- hist_matches %>%
  filter(!is.na(winner_hand) | !is.na(loser_hand)) %>%
  select(player = winner_name, hand = winner_hand, age = winner_age, rank = winner_rank) %>%
  bind_rows(
    hist_matches %>%
      select(player = loser_name, hand = loser_hand, age = loser_age, rank = loser_rank)
  ) %>%
  group_by(player) %>%
  summarise(
    hand = first(na.omit(hand)),
    avg_age = mean(age, na.rm = TRUE),
    best_rank = min(rank, na.rm = TRUE),
    .groups = "drop"
  )

# Merge player info
preds <- preds %>%
  left_join(player_info %>% select(player, p1_hand = hand, p1_rank = best_rank),
            by = c("player1" = "player")) %>%
  left_join(player_info %>% select(player, p2_hand = hand, p2_rank = best_rank),
            by = c("player2" = "player"))

# Add matchup characteristics
preds <- preds %>%
  mutate(
    # Handedness matchups
    lefty_matchup = case_when(
      p1_hand == "L" & p2_hand == "L" ~ "L vs L",
      p1_hand == "L" | p2_hand == "L" ~ "L vs R",
      TRUE ~ "R vs R"
    ),

    # Ranking differential
    rank_diff = abs(p1_rank - p2_rank),
    rank_bucket = case_when(
      is.na(rank_diff) ~ "Unknown",
      rank_diff < 20 ~ "Close ranks (<20)",
      rank_diff < 50 ~ "Moderate gap (20-50)",
      rank_diff < 100 ~ "Large gap (50-100)",
      TRUE ~ "Huge gap (100+)"
    ),

    # Favorite's rank
    fav_rank = ifelse(market_fav == player1, p1_rank, p2_rank),
    fav_rank_bucket = case_when(
      is.na(fav_rank) ~ "Unknown",
      fav_rank <= 10 ~ "Top 10",
      fav_rank <= 30 ~ "11-30",
      fav_rank <= 50 ~ "31-50",
      fav_rank <= 100 ~ "51-100",
      TRUE ~ "100+"
    ),

    # Underdog's rank
    dog_rank = ifelse(market_fav == player1, p2_rank, p1_rank),
    dog_rank_bucket = case_when(
      is.na(dog_rank) ~ "Unknown",
      dog_rank <= 30 ~ "Top 30 dog",
      dog_rank <= 50 ~ "31-50 dog",
      dog_rank <= 100 ~ "51-100 dog",
      TRUE ~ "100+ dog"
    )
  )

# Analyze subset function
analyze <- function(data, name) {
  if (nrow(data) < 30) return(NULL)
  tibble(
    subset = name,
    n = nrow(data),
    accuracy = mean(data$elo_correct),
    roi = mean(data$profit),
    avg_odds = mean(data$bet_odds),
    edge = mean(data$elo_correct) - 1/mean(data$bet_odds)
  )
}

results <- list()
i <- 1

cat("=== DIMENSION: HANDEDNESS MATCHUPS ===\n\n")
for (matchup in c("L vs L", "L vs R", "R vs R")) {
  results[[i]] <- analyze(preds %>% filter(lefty_matchup == matchup), paste("Handedness:", matchup))
  i <- i + 1
}

cat("=== DIMENSION: FAVORITE'S RANKING ===\n\n")
for (bucket in c("Top 10", "11-30", "31-50", "51-100", "100+")) {
  results[[i]] <- analyze(preds %>% filter(fav_rank_bucket == bucket), paste("Fav rank:", bucket))
  i <- i + 1
}

cat("=== DIMENSION: UNDERDOG'S RANKING ===\n\n")
for (bucket in c("Top 30 dog", "31-50 dog", "51-100 dog", "100+ dog")) {
  results[[i]] <- analyze(preds %>% filter(dog_rank_bucket == bucket), paste("Dog rank:", bucket))
  i <- i + 1
}

cat("=== DIMENSION: RANKING DIFFERENTIAL ===\n\n")
for (bucket in c("Close ranks (<20)", "Moderate gap (20-50)", "Large gap (50-100)", "Huge gap (100+)")) {
  results[[i]] <- analyze(preds %>% filter(rank_bucket == bucket), paste("Rank diff:", bucket))
  i <- i + 1
}

cat("=== COMBINED: SURFACE + HANDEDNESS ===\n\n")
for (surf in c("Hard", "Clay", "Grass")) {
  for (matchup in c("L vs L", "L vs R", "R vs R")) {
    results[[i]] <- analyze(preds %>% filter(surface == surf, lefty_matchup == matchup),
                            paste(surf, matchup))
    i <- i + 1
  }
}

cat("=== COMBINED: SURFACE + FAVORITE RANK ===\n\n")
for (surf in c("Hard", "Clay", "Grass")) {
  for (bucket in c("Top 10", "11-30", "31-50")) {
    results[[i]] <- analyze(preds %>% filter(surface == surf, fav_rank_bucket == bucket),
                            paste(surf, "Fav", bucket))
    i <- i + 1
  }
}

cat("=== COMBINED: TOURNAMENT LEVEL + RANKING ===\n\n")
# Masters with Top 30 dogs (quality upset potential)
results[[i]] <- analyze(
  preds %>% filter(str_detect(tournament, "Masters"), dog_rank_bucket == "Top 30 dog"),
  "Masters + Top 30 underdog"
)
i <- i + 1

# Grand Slams with Top 30 dogs
results[[i]] <- analyze(
  preds %>% filter(is_grand_slam, dog_rank_bucket == "Top 30 dog"),
  "Grand Slam + Top 30 underdog"
)
i <- i + 1

cat("=== SPECIAL: CLAY + SPECIFIC CONDITIONS ===\n\n")
# Clay + early rounds + moderate favorites
results[[i]] <- analyze(
  preds %>% filter(surface == "Clay", round_clean == "Early", market_fav_odds >= 1.4, market_fav_odds < 1.8),
  "Clay Early + Moderate fav"
)
i <- i + 1

# Clay + late rounds + close match
results[[i]] <- analyze(
  preds %>% filter(surface == "Clay", round_clean == "Late", market_fav_odds >= 1.6),
  "Clay Late + Close match"
)
i <- i + 1

# Clay Masters + specific rounds
for (r in c("Early", "Middle", "Late")) {
  cm_subset <- clay_masters %>% filter(round_clean == r)
  if (nrow(cm_subset) >= 10) {  # Lower threshold for exploration
    results[[i]] <- analyze(cm_subset, paste("Clay Masters", r))
    i <- i + 1
  }
}

cat("=== HUNTING: TOP 10 FAVORITES ===\n\n")
# Top 10 vs different underdog tiers
for (dog_bucket in c("Top 30 dog", "31-50 dog", "51-100 dog")) {
  results[[i]] <- analyze(
    preds %>% filter(fav_rank_bucket == "Top 10", dog_rank_bucket == dog_bucket),
    paste("Top 10 fav vs", dog_bucket)
  )
  i <- i + 1
}

cat("=== HUNTING: QUALITY MATCHUPS ===\n\n")
# Both players ranked - quality matchup
results[[i]] <- analyze(
  preds %>% filter(fav_rank_bucket %in% c("Top 10", "11-30"), dog_rank_bucket == "Top 30 dog"),
  "Quality matchup (both Top 30)"
)
i <- i + 1

# High rank differential + Elo disagrees (upset potential)
results[[i]] <- analyze(
  preds %>% filter(rank_bucket == "Huge gap (100+)", !agree),
  "Huge rank gap + Elo picks upset"
)
i <- i + 1

# Compile results
all_results <- bind_rows(results) %>%
  filter(!is.na(subset)) %>%
  arrange(desc(edge))

cat("\n========================================\n")
cat("ALL NEW SUBSETS RANKED BY EDGE\n")
cat("========================================\n\n")

all_results %>%
  mutate(
    accuracy = sprintf("%.1f%%", 100 * accuracy),
    edge = sprintf("%+.1fpp", 100 * edge),
    roi = sprintf("%+.1f%%", 100 * roi)
  ) %>%
  print(n = 40)

cat("\n========================================\n")
cat("POSITIVE ROI SUBSETS (N >= 30)\n")
cat("========================================\n\n")

positive_roi <- all_results %>%
  filter(roi > 0, n >= 30) %>%
  arrange(desc(roi))

if (nrow(positive_roi) > 0) {
  positive_roi %>%
    mutate(
      accuracy = sprintf("%.1f%%", 100 * accuracy),
      edge = sprintf("%+.1fpp", 100 * edge),
      roi = sprintf("%+.1f%%", 100 * roi)
    ) %>%
    print()

  cat("\nStatistical significance check for top subset:\n")
  top_subset_name <- positive_roi$subset[1]

  # Re-calculate for significance
  if (str_detect(top_subset_name, "Clay Masters")) {
    test_data <- clay_masters
  } else {
    # Generic recreation would need more logic
    cat("(Manual significance check needed for:", top_subset_name, ")\n")
    test_data <- NULL
  }

  if (!is.null(test_data) && nrow(test_data) >= 30) {
    wins <- sum(test_data$bet_won)
    n <- nrow(test_data)
    breakeven <- 1 / mean(test_data$bet_odds)
    test <- binom.test(wins, n, p = breakeven, alternative = "greater")
    cat(sprintf("\nBinomial test for %s:\n", top_subset_name))
    cat(sprintf("  N=%d, Wins=%d (%.1f%%)\n", n, wins, 100*wins/n))
    cat(sprintf("  Breakeven: %.1f%%\n", 100*breakeven))
    cat(sprintf("  p-value (one-sided): %.4f\n", test$p.value))
  }
} else {
  cat("No subsets with positive ROI found.\n")
}

# Save results
saveRDS(all_results, "data/processed/edge_hunting_deep_results.rds")
saveRDS(preds, "data/processed/preds_with_player_info.rds")
