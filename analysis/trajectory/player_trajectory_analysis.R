# Deep analysis: Why does Elo underrate/overrate specific players?
# Compare 2023 performance to H1 2024 to understand trajectory

library(tidyverse)

# Load aligned historical matches
hist <- readRDS("data/processed/atp_matches_aligned.rds")

# Focus on players Elo systematically underrates (rising stars)
underrated <- c("Etcheverry T", "Struff JL", "Auger-Aliassime F",
                "Ben Shelton", "Alex De Minaur", "Tommy Paul", "Mariano Navone")

# Focus on players Elo systematically overrates (declining/inconsistent)
overrated <- c("Kei Nishikori", "Yoshihito Nishioka", "Fabio Fognini",
               "Adrian Mannarino", "Pablo Carreno Busta", "Pedro Cachin")

# Normalize names for matching
normalize_name <- function(name) {
  name %>%
    str_replace_all("[.]", "") %>%
    str_replace_all("\\s+", " ") %>%
    str_trim() %>%
    tolower()
}

# Get 2023 and H1 2024 records
hist_recent <- hist %>%
  filter(year(match_date) >= 2023) %>%
  mutate(
    period = case_when(
      year(match_date) == 2023 ~ "2023",
      year(match_date) == 2024 & month(match_date) <= 6 ~ "H1 2024",
      TRUE ~ "Other"
    ),
    winner_norm = normalize_name(winner_name),
    loser_norm = normalize_name(loser_name)
  ) %>%
  filter(period %in% c("2023", "H1 2024"))

# Function to get player record
get_player_record <- function(player_name, data) {
  norm_name <- normalize_name(player_name)

  wins <- data %>% filter(winner_norm == norm_name)
  losses <- data %>% filter(loser_norm == norm_name)

  list(wins = nrow(wins), losses = nrow(losses))
}

cat("=== PLAYERS ELO UNDERRATES (Rising Stars) ===\n\n")
cat("These are market favorites Elo picked AGAINST, who then WON\n")
cat("(Elo underestimated their current skill level)\n\n")

for (player in underrated) {
  cat(sprintf("--- %s ---\n", player))

  rec_2023 <- get_player_record(player, hist_recent %>% filter(period == "2023"))
  rec_2024 <- get_player_record(player, hist_recent %>% filter(period == "H1 2024"))

  if (rec_2023$wins + rec_2023$losses > 0) {
    pct_2023 <- 100 * rec_2023$wins / (rec_2023$wins + rec_2023$losses)
    cat(sprintf("  2023: %d-%d (%.1f%%)\n", rec_2023$wins, rec_2023$losses, pct_2023))
  }
  if (rec_2024$wins + rec_2024$losses > 0) {
    pct_2024 <- 100 * rec_2024$wins / (rec_2024$wins + rec_2024$losses)
    cat(sprintf("  H1 2024: %d-%d (%.1f%%)\n", rec_2024$wins, rec_2024$losses, pct_2024))
  }
  cat("\n")
}

cat("\n=== PLAYERS ELO OVERRATES (Declining/Inconsistent) ===\n\n")
cat("These are players Elo BACKED (as underdogs), who then LOST\n")
cat("(Elo overestimated their current skill level)\n\n")

for (player in overrated) {
  cat(sprintf("--- %s ---\n", player))

  rec_2023 <- get_player_record(player, hist_recent %>% filter(period == "2023"))
  rec_2024 <- get_player_record(player, hist_recent %>% filter(period == "H1 2024"))

  if (rec_2023$wins + rec_2023$losses > 0) {
    pct_2023 <- 100 * rec_2023$wins / (rec_2023$wins + rec_2023$losses)
    cat(sprintf("  2023: %d-%d (%.1f%%)\n", rec_2023$wins, rec_2023$losses, pct_2023))
  }
  if (rec_2024$wins + rec_2024$losses > 0) {
    pct_2024 <- 100 * rec_2024$wins / (rec_2024$wins + rec_2024$losses)
    cat(sprintf("  H1 2024: %d-%d (%.1f%%)\n", rec_2024$wins, rec_2024$losses, pct_2024))
  }
  cat("\n")
}

cat("\n=== KEY CASE STUDY: Shelton vs Nishikori ===\n")
cat("Elo gave Nishikori 76.5% chance - why?\n\n")

# Nishikori timeline
cat("--- Kei Nishikori Match History ---\n\n")
nishikori <- hist_recent %>%
  filter(winner_norm == "kei nishikori" | loser_norm == "kei nishikori") %>%
  arrange(match_date) %>%
  mutate(
    result = ifelse(winner_norm == "kei nishikori", "W", "L"),
    opponent = ifelse(result == "W", loser_name, winner_name)
  ) %>%
  select(date = match_date, tournament = tourney_name, surface, round, result, opponent)

print(nishikori, n = 30)

cat("\n--- Ben Shelton Match History ---\n\n")
shelton <- hist_recent %>%
  filter(winner_norm == "ben shelton" | loser_norm == "ben shelton") %>%
  arrange(match_date) %>%
  mutate(
    result = ifelse(winner_norm == "ben shelton", "W", "L"),
    opponent = ifelse(result == "W", loser_name, winner_name)
  ) %>%
  select(date = match_date, tournament = tourney_name, surface, round, result, opponent)

print(shelton, n = 50)

cat("\n=== THE INSIGHT ===\n\n")
cat("The market knows Shelton is RISING (young, improving, ranked ~15)\n")
cat("The market knows Nishikori is DECLINING (coming back from injuries, now 34)\n")
cat("Elo still sees Nishikori's historical greatness (former world #4)\n")
cat("and hasn't fully registered Shelton's rapid rise or Nishikori's decline.\n")
