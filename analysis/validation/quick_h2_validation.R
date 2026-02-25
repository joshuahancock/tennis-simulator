# Quick H2 2024 validation
library(tidyverse)

hist_matches <- readRDS("data/processed/atp_matches_aligned.rds")
betting_2024 <- readxl::read_xlsx("data/raw/tennis_betting/2024.xlsx")

h2_betting <- betting_2024 %>%
  mutate(Date = as.Date(Date)) %>%
  filter(Date >= as.Date("2024-07-01"), Date <= as.Date("2024-12-31"))

# Build Elo through H1 2024
training <- hist_matches %>%
  filter(match_date < as.Date("2024-07-01")) %>%
  filter(!is.na(winner_name), !is.na(loser_name)) %>%
  arrange(match_date)

elo <- list()
k <- 32

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

cat(sprintf("Trained Elo for %d players\n\n", length(elo)))

# Create name lookup
extract_last <- function(name) {
  name %>%
    str_replace("\\s+[A-Z]\\.$", "") %>%
    str_replace("\\s+[A-Z]\\.[A-Z]\\.$", "") %>%
    str_to_lower() %>%
    str_trim()
}

name_map <- hist_matches %>%
  filter(!is.na(winner_name)) %>%
  mutate(last = str_to_lower(word(winner_name, -1))) %>%
  select(last, full = winner_name) %>%
  distinct(last, .keep_all = TRUE)

# Get rankings
ranks <- hist_matches %>%
  filter(match_date >= "2024-01-01", match_date < "2024-07-01") %>%
  select(player = winner_name, rank = winner_rank) %>%
  bind_rows(
    hist_matches %>%
      filter(match_date >= "2024-01-01", match_date < "2024-07-01") %>%
      select(player = loser_name, rank = loser_rank)
  ) %>%
  filter(!is.na(rank)) %>%
  group_by(player) %>%
  summarise(best_rank = min(rank), .groups = "drop")

# Match H2 betting to full names
h2_matched <- h2_betting %>%
  mutate(
    w_last = extract_last(Winner),
    l_last = extract_last(Loser)
  ) %>%
  left_join(name_map, by = c("w_last" = "last")) %>%
  rename(winner = full) %>%
  left_join(name_map, by = c("l_last" = "last")) %>%
  rename(loser = full) %>%
  filter(!is.na(winner), !is.na(loser))

cat(sprintf("Matched %d H2 2024 matches\n\n", nrow(h2_matched)))

# Generate predictions
preds_list <- vector("list", nrow(h2_matched))

for (i in 1:nrow(h2_matched)) {
  m <- h2_matched[i, ]
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

  # Update Elo
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
    agree = (elo_pick == mkt_fav),
    bet_odds = ifelse(elo_pick == winner, w_odds, l_odds),
    profit = ifelse(elo_correct, bet_odds - 1, -1),
    is_masters = str_detect(tolower(tournament), "masters|paris"),
    is_clay = str_detect(tolower(surface), "clay"),
    is_hard = str_detect(tolower(surface), "hard"),
    fav_rank = ifelse(mkt_fav == winner, w_rank, l_rank),
    dog_rank = ifelse(mkt_fav == winner, l_rank, w_rank),
    fav_top10 = !is.na(fav_rank) & fav_rank <= 10,
    fav_top30 = !is.na(fav_rank) & fav_rank <= 30,
    dog_top30 = !is.na(dog_rank) & dog_rank <= 30
  )

cat("========================================\n")
cat("H2 2024 OVERALL\n")
cat("========================================\n\n")
cat(sprintf("N = %d\n", nrow(preds)))
cat(sprintf("Elo accuracy: %.1f%%\n", 100 * mean(preds$elo_correct)))
cat(sprintf("ROI: %+.1f%%\n\n", 100 * mean(preds$profit)))

cat("========================================\n")
cat("VALIDATION OF H1 2024 EDGES\n")
cat("========================================\n\n")

# Clay Masters (Paris only in H2)
clay_masters <- preds %>% filter(is_clay, is_masters)
cat(sprintf("Clay Masters:\n"))
cat(sprintf("  H1: N=144, ROI=+13.6%%\n"))
if (nrow(clay_masters) > 0) {
  cat(sprintf("  H2: N=%d, Accuracy=%.1f%%, ROI=%+.1f%%\n\n",
              nrow(clay_masters), 100*mean(clay_masters$elo_correct), 100*mean(clay_masters$profit)))
} else {
  cat("  H2: No Clay Masters matches (only Paris Masters in Nov, indoor hard)\n\n")
}

# Clay Quality Matchups
clay_quality <- preds %>% filter(is_clay, fav_top30, dog_top30)
cat("Clay Quality Matchups (both Top 30):\n")
cat(sprintf("  H1: N=180, ROI=+4.2%%\n"))
if (nrow(clay_quality) >= 10) {
  cat(sprintf("  H2: N=%d, Accuracy=%.1f%%, ROI=%+.1f%%\n\n",
              nrow(clay_quality), 100*mean(clay_quality$elo_correct), 100*mean(clay_quality$profit)))
} else {
  cat(sprintf("  H2: N=%d (insufficient)\n\n", nrow(clay_quality)))
}

# Hard Later Rounds
hard_later <- preds %>% filter(is_hard, !str_detect(tolower(round), "1st|r128|r64|r32"))
cat("Hard Later Rounds:\n")
cat(sprintf("  H1: N=357, ROI=+2.4%%\n"))
if (nrow(hard_later) >= 30) {
  cat(sprintf("  H2: N=%d, Accuracy=%.1f%%, ROI=%+.1f%%\n\n",
              nrow(hard_later), 100*mean(hard_later$elo_correct), 100*mean(hard_later$profit)))
} else {
  cat(sprintf("  H2: N=%d (insufficient)\n\n", nrow(hard_later)))
}

# Quality Matchups (all surfaces)
quality_all <- preds %>% filter(fav_top30, dog_top30)
cat("Quality Matchups (all surfaces, both Top 30):\n")
if (nrow(quality_all) >= 20) {
  cat(sprintf("  H2: N=%d, Accuracy=%.1f%%, ROI=%+.1f%%\n\n",
              nrow(quality_all), 100*mean(quality_all$elo_correct), 100*mean(quality_all$profit)))
}

# Top 10 favorites
top10_fav <- preds %>% filter(fav_top10)
cat("Top 10 Favorites:\n")
if (nrow(top10_fav) >= 30) {
  cat(sprintf("  H2: N=%d, Accuracy=%.1f%%, ROI=%+.1f%%\n\n",
              nrow(top10_fav), 100*mean(top10_fav$elo_correct), 100*mean(top10_fav$profit)))
}

cat("========================================\n")
cat("BY SURFACE\n")
cat("========================================\n\n")

for (surf in c("hard", "clay", "grass")) {
  subset <- preds %>% filter(str_detect(tolower(surface), surf))
  if (nrow(subset) > 20) {
    cat(sprintf("%s: N=%d, Accuracy=%.1f%%, ROI=%+.1f%%\n",
                str_to_title(surf), nrow(subset), 100*mean(subset$elo_correct), 100*mean(subset$profit)))
  }
}

cat("\n========================================\n")
cat("COMBINED VALIDATION\n")
cat("========================================\n\n")

# Combine H1 and H2 for edges that showed up in both
cat("If we pool H1+H2 data for key subsets:\n\n")

# Load H1 predictions
h1_preds <- readRDS("data/processed/preds_with_player_info.rds")

# Clay Quality in H1
h1_clay_q <- h1_preds %>%
  filter(surface == "Clay",
         fav_rank_bucket %in% c("Top 10", "11-30"),
         dog_rank_bucket == "Top 30 dog")

cat(sprintf("Clay Quality Matchups:\n"))
cat(sprintf("  H1: N=%d, ROI=%+.1f%%\n", nrow(h1_clay_q), 100*mean(h1_clay_q$profit)))
if (nrow(clay_quality) > 0) {
  combined_n <- nrow(h1_clay_q) + nrow(clay_quality)
  combined_roi <- (sum(h1_clay_q$profit) + sum(clay_quality$profit)) / combined_n
  cat(sprintf("  H2: N=%d, ROI=%+.1f%%\n", nrow(clay_quality), 100*mean(clay_quality$profit)))
  cat(sprintf("  Combined: N=%d, ROI=%+.1f%%\n", combined_n, 100*combined_roi))
}
