# Edge Hunting Part 3: Creative/Structural Patterns
# First match effects, scheduling, momentum, matchup dynamics

library(tidyverse)

preds <- readRDS("data/processed/preds_with_player_info.rds")
hist_matches <- readRDS("data/processed/atp_matches_aligned.rds")

cat("=== CREATIVE EDGE HUNTING ===\n\n")

# Add more features
preds <- preds %>%
  mutate(
    # Round number (approximate)
    round_num = case_when(
      str_detect(round, "1st|R128|R64|R32") ~ 1,
      str_detect(round, "2nd|R16") ~ 2,
      str_detect(round, "3rd") ~ 3,
      str_detect(round, "4th") ~ 4,
      str_detect(round, "Quarter") ~ 5,
      str_detect(round, "Semi") ~ 6,
      str_detect(round, "Final") ~ 7,
      TRUE ~ 0
    ),

    # Is it first round? (potential rust/nerves)
    is_first_round = round_num == 1,

    # Is it a final? (high pressure)
    is_final = str_detect(round, "Final") & !str_detect(round, "Semi"),

    # Is it a semifinal or final? (late stage pressure)
    is_late_stage = round_num >= 6,

    # Best of 5 (Grand Slams only)
    is_best_of_5 = is_grand_slam,

    # Day of week patterns
    is_weekend = day_of_week %in% c("Sat", "Sun"),

    # Season timing
    season = case_when(
      month %in% 1:3 ~ "Early (Jan-Mar)",
      month %in% 4:6 ~ "Clay/Grass (Apr-Jun)",
      TRUE ~ "Other"
    ),

    # Odds-implied upset probability
    upset_prob = 1 - 1/market_fav_odds,

    # Is Elo picking the upset?
    elo_picks_upset = !agree
  )

analyze <- function(data, name) {
  if (nrow(data) < 25) return(NULL)
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

cat("=== FIRST ROUND EFFECTS (rust/nerves) ===\n\n")

# First round by surface
for (surf in c("Hard", "Clay", "Grass")) {
  results[[i]] <- analyze(preds %>% filter(is_first_round, surface == surf),
                          paste("First round", surf))
  i <- i + 1

  results[[i]] <- analyze(preds %>% filter(!is_first_round, surface == surf),
                          paste("Later rounds", surf))
  i <- i + 1
}

cat("=== FINALS AND LATE STAGE ===\n\n")

results[[i]] <- analyze(preds %>% filter(is_final), "Finals only")
i <- i + 1
results[[i]] <- analyze(preds %>% filter(is_late_stage), "Semis + Finals")
i <- i + 1
results[[i]] <- analyze(preds %>% filter(!is_late_stage & !is_first_round), "Middle rounds only")
i <- i + 1

cat("=== BEST OF 5 vs BEST OF 3 ===\n\n")

results[[i]] <- analyze(preds %>% filter(is_best_of_5), "Best of 5 (Slams)")
i <- i + 1
results[[i]] <- analyze(preds %>% filter(!is_best_of_5), "Best of 3 (non-Slams)")
i <- i + 1

# Best of 5 with high Elo confidence (fitter players should win more)
results[[i]] <- analyze(preds %>% filter(is_best_of_5, elo_conf > 0.65),
                        "BO5 + High Elo conf (>65%)")
i <- i + 1

cat("=== WEEKEND vs WEEKDAY ===\n\n")

results[[i]] <- analyze(preds %>% filter(is_weekend), "Weekend matches")
i <- i + 1
results[[i]] <- analyze(preds %>% filter(!is_weekend), "Weekday matches")
i <- i + 1

cat("=== SEASONAL PATTERNS ===\n\n")

for (s in unique(preds$season)) {
  results[[i]] <- analyze(preds %>% filter(season == s), paste("Season:", s))
  i <- i + 1
}

cat("=== CLAY MASTERS DEEP DIVE ===\n\n")

clay_masters <- preds %>%
  filter(surface == "Clay",
         str_detect(tournament, "Masters|Monte Carlo|Madrid|Rome"))

# By round stage
for (r in c(1, 2, 3, 4, 5, 6, 7)) {
  results[[i]] <- analyze(clay_masters %>% filter(round_num == r),
                          paste("Clay Masters round", r))
  i <- i + 1
}

# By favorite rank
for (rank_b in c("Top 10", "11-30", "31-50")) {
  results[[i]] <- analyze(clay_masters %>% filter(fav_rank_bucket == rank_b),
                          paste("Clay Masters, Fav", rank_b))
  i <- i + 1
}

# By underdog rank
for (rank_b in c("Top 30 dog", "31-50 dog", "51-100 dog")) {
  results[[i]] <- analyze(clay_masters %>% filter(dog_rank_bucket == rank_b),
                          paste("Clay Masters, Dog", rank_b))
  i <- i + 1
}

cat("=== MONTE CARLO SPECIFIC ===\n\n")

monte_carlo <- preds %>% filter(str_detect(tournament, "Monte Carlo"))

results[[i]] <- analyze(monte_carlo, "Monte Carlo overall")
i <- i + 1

# MC by round
for (r in unique(monte_carlo$round_clean)) {
  results[[i]] <- analyze(monte_carlo %>% filter(round_clean == r),
                          paste("Monte Carlo", r, "rounds"))
  i <- i + 1
}

# MC when Elo agrees vs disagrees
results[[i]] <- analyze(monte_carlo %>% filter(agree), "Monte Carlo when Elo agrees")
i <- i + 1
results[[i]] <- analyze(monte_carlo %>% filter(!agree), "Monte Carlo when Elo disagrees")
i <- i + 1

cat("=== UPSET CONDITIONS ===\n\n")

# When Elo picks upset, by odds range
results[[i]] <- analyze(preds %>% filter(elo_picks_upset, market_dog_odds >= 2.0, market_dog_odds < 2.5),
                        "Elo picks upset, odds 2.0-2.5")
i <- i + 1
results[[i]] <- analyze(preds %>% filter(elo_picks_upset, market_dog_odds >= 2.5, market_dog_odds < 3.5),
                        "Elo picks upset, odds 2.5-3.5")
i <- i + 1

cat("=== HIGH ELO CONFIDENCE FAVORITES ===\n\n")

# When Elo agrees with market AND has very high confidence
results[[i]] <- analyze(preds %>% filter(agree, elo_conf > 0.75),
                        "Agree + Very high conf (>75%)")
i <- i + 1
results[[i]] <- analyze(preds %>% filter(agree, elo_conf > 0.80),
                        "Agree + Extreme conf (>80%)")
i <- i + 1

# High conf favorites on specific surfaces
results[[i]] <- analyze(preds %>% filter(agree, elo_conf > 0.70, surface == "Clay"),
                        "Clay + Agree + High conf")
i <- i + 1
results[[i]] <- analyze(preds %>% filter(agree, elo_conf > 0.70, surface == "Hard"),
                        "Hard + Agree + High conf")
i <- i + 1

cat("=== QUALITY MATCHUPS BY SURFACE ===\n\n")

# Both players ranked highly
for (surf in c("Hard", "Clay", "Grass")) {
  results[[i]] <- analyze(
    preds %>% filter(
      surface == surf,
      fav_rank_bucket %in% c("Top 10", "11-30"),
      dog_rank_bucket == "Top 30 dog"
    ),
    paste(surf, "quality matchups (both Top 30)")
  )
  i <- i + 1
}

cat("=== SPECIFIC TOURNAMENT LEVELS ===\n\n")

# Grand Slam specific conditions
results[[i]] <- analyze(preds %>% filter(is_grand_slam, round_num <= 2),
                        "Grand Slam early rounds")
i <- i + 1
results[[i]] <- analyze(preds %>% filter(is_grand_slam, round_num >= 3),
                        "Grand Slam later rounds")
i <- i + 1

# Grand Slam + Top 10 favorite
results[[i]] <- analyze(preds %>% filter(is_grand_slam, fav_rank_bucket == "Top 10"),
                        "Grand Slam + Top 10 fav")
i <- i + 1

# Compile
all_results <- bind_rows(results) %>%
  filter(!is.na(subset)) %>%
  arrange(desc(roi))

cat("\n========================================\n")
cat("TOP 20 BY ROI (minimum N=25)\n")
cat("========================================\n\n")

all_results %>%
  filter(n >= 25) %>%
  head(20) %>%
  mutate(
    accuracy = sprintf("%.1f%%", 100 * accuracy),
    edge = sprintf("%+.1fpp", 100 * edge),
    roi = sprintf("%+.1f%%", 100 * roi)
  ) %>%
  print()

cat("\n========================================\n")
cat("POSITIVE ROI SUBSETS (N >= 25)\n")
cat("========================================\n\n")

positive_roi <- all_results %>%
  filter(roi > 0, n >= 25) %>%
  arrange(desc(roi))

positive_roi %>%
  mutate(
    accuracy = sprintf("%.1f%%", 100 * accuracy),
    edge = sprintf("%+.1fpp", 100 * edge),
    roi = sprintf("%+.1f%%", 100 * roi)
  ) %>%
  print(n = 30)

# Save
saveRDS(all_results, "data/processed/edge_hunting_creative_results.rds")

# Statistical tests on top subsets
cat("\n========================================\n")
cat("STATISTICAL SIGNIFICANCE TESTS\n")
cat("========================================\n\n")

# Test Monte Carlo overall
mc <- preds %>% filter(str_detect(tournament, "Monte Carlo"))
if (nrow(mc) >= 25) {
  wins <- sum(mc$elo_correct)
  n <- nrow(mc)
  breakeven <- 1/mean(mc$bet_odds)
  test <- binom.test(wins, n, p = breakeven, alternative = "greater")
  cat(sprintf("Monte Carlo: %d/%d wins (%.1f%%), breakeven=%.1f%%, p=%.4f\n",
              wins, n, 100*wins/n, 100*breakeven, test$p.value))
}

# Test Clay Masters
cm <- preds %>% filter(surface == "Clay", str_detect(tournament, "Masters|Monte Carlo|Madrid|Rome"))
if (nrow(cm) >= 25) {
  wins <- sum(cm$elo_correct)
  n <- nrow(cm)
  breakeven <- 1/mean(cm$bet_odds)
  test <- binom.test(wins, n, p = breakeven, alternative = "greater")
  cat(sprintf("Clay Masters: %d/%d wins (%.1f%%), breakeven=%.1f%%, p=%.4f\n",
              wins, n, 100*wins/n, 100*breakeven, test$p.value))
}

# Test BO5 + High Elo confidence
bo5_high <- preds %>% filter(is_best_of_5, elo_conf > 0.65)
if (nrow(bo5_high) >= 25) {
  wins <- sum(bo5_high$elo_correct)
  n <- nrow(bo5_high)
  breakeven <- 1/mean(bo5_high$bet_odds)
  test <- binom.test(wins, n, p = breakeven, alternative = "greater")
  cat(sprintf("BO5 + High conf: %d/%d wins (%.1f%%), breakeven=%.1f%%, p=%.4f\n",
              wins, n, 100*wins/n, 100*breakeven, test$p.value))
}
