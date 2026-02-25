# Out-of-Sample Validation: Test H1 2024 edges on H2 2024 data
# This is the critical test - do the patterns hold?

library(tidyverse)

cat("=== OUT-OF-SAMPLE VALIDATION ===\n")
cat("Testing H1 2024 edges on H2 2024 data\n\n")

# Load historical matches
hist_matches <- readRDS("data/processed/atp_matches_aligned.rds")

# Load betting data for H2 2024
cat("Loading betting data...\n")
betting_2024 <- readxl::read_xlsx("data/raw/tennis_betting/2024.xlsx")

# Filter to H2 2024 (July-December)
h2_2024_betting <- betting_2024 %>%
  mutate(Date = as.Date(Date)) %>%
  filter(Date >= as.Date("2024-07-01"), Date <= as.Date("2024-12-31"))

cat(sprintf("H2 2024 betting matches: %d\n", nrow(h2_2024_betting)))

# Build Elo ratings through end of H1 2024 (training cutoff)
cat("\nBuilding Elo ratings through H1 2024...\n")

training_matches <- hist_matches %>%
  filter(match_date < as.Date("2024-07-01")) %>%
  filter(!is.na(winner_name), !is.na(loser_name)) %>%
  arrange(match_date)

cat(sprintf("Training matches: %d\n", nrow(training_matches)))

# Initialize and train Elo
elo_ratings <- list()
k <- 32

for (i in 1:nrow(training_matches)) {
  match <- training_matches[i, ]
  winner <- match$winner_name
  loser <- match$loser_name

  winner_elo <- elo_ratings[[winner]]
  if (is.null(winner_elo)) winner_elo <- 1500
  loser_elo <- elo_ratings[[loser]]
  if (is.null(loser_elo)) loser_elo <- 1500

  expected_winner <- 1 / (1 + 10^((loser_elo - winner_elo) / 400))

  elo_ratings[[winner]] <- winner_elo + k * (1 - expected_winner)
  elo_ratings[[loser]] <- loser_elo + k * (0 - (1 - expected_winner))
}

cat(sprintf("Trained Elo for %d players\n", length(elo_ratings)))

# Convert betting names to ATP format for matching
# Betting format: "Sinner J." -> ATP format: "Jannik Sinner"
# We'll match on last name since that's more reliable

extract_last_name <- function(name) {
  # Remove initials and get last name
  name %>%
    str_replace("\\s+[A-Z]\\.$", "") %>%  # Remove " J."
    str_replace("\\s+[A-Z]\\.[A-Z]\\.$", "") %>%  # Remove " J.L."
    str_to_lower() %>%
    str_trim()
}

# Get H2 2024 matches from historical data
h2_matches <- hist_matches %>%
  filter(match_date >= as.Date("2024-07-01"), match_date <= as.Date("2024-12-31")) %>%
  filter(!is.na(winner_name), !is.na(loser_name)) %>%
  arrange(match_date) %>%
  mutate(
    winner_last = str_to_lower(str_extract(winner_name, "\\S+$")),
    loser_last = str_to_lower(str_extract(loser_name, "\\S+$"))
  )

h2_2024_betting <- h2_2024_betting %>%
  mutate(
    winner_last = extract_last_name(Winner),
    loser_last = extract_last_name(Loser)
  )

# Join on date + last names
h2_with_odds <- h2_matches %>%
  left_join(
    h2_2024_betting %>% select(Date, winner_last, loser_last, W_odds = PSW, L_odds = PSL),
    by = c("match_date" = "Date", "winner_last", "loser_last")
  ) %>%
  filter(!is.na(W_odds), !is.na(L_odds))

cat(sprintf("H2 2024 matches with odds: %d\n", nrow(h2_with_odds)))

if (nrow(h2_with_odds) == 0) {
  cat("\nNo matches joined - checking alternative approach...\n")

  # Try more flexible matching
  h2_with_odds <- h2_matches %>%
    inner_join(
      h2_2024_betting %>%
        select(Date, winner_last, loser_last, W_odds = PSW, L_odds = PSL),
      by = c("match_date" = "Date"),
      suffix = c("", "_bet"),
      relationship = "many-to-many"
    ) %>%
    filter(
      (winner_last == winner_last_bet & loser_last == loser_last_bet) |
      (winner_last == loser_last_bet & loser_last == winner_last_bet)
    ) %>%
    mutate(
      # Correct odds if names were swapped
      W_odds_final = ifelse(winner_last == winner_last_bet, W_odds, L_odds),
      L_odds_final = ifelse(winner_last == winner_last_bet, L_odds, W_odds)
    ) %>%
    select(-W_odds, -L_odds, -winner_last_bet, -loser_last_bet) %>%
    rename(W_odds = W_odds_final, L_odds = L_odds_final) %>%
    distinct(match_date, winner_name, loser_name, .keep_all = TRUE)

  cat(sprintf("After flexible matching: %d matches\n", nrow(h2_with_odds)))
}

if (nrow(h2_with_odds) < 100) {
  cat("\nInsufficient matches for validation. Trying direct betting data approach...\n")

  # Use betting data directly (we know who won from the Winner column)
  # Generate predictions based on Elo
  cat("\nUsing betting data directly with Elo predictions...\n")

  # Create name lookup from historical data
  name_lookup <- hist_matches %>%
    filter(!is.na(winner_name)) %>%
    mutate(last_name = str_to_lower(str_extract(winner_name, "\\S+$"))) %>%
    select(last_name, full_name = winner_name) %>%
    distinct(last_name, .keep_all = TRUE)

  h2_predictions <- h2_2024_betting %>%
    mutate(
      winner_last = extract_last_name(Winner),
      loser_last = extract_last_name(Loser)
    ) %>%
    left_join(name_lookup, by = c("winner_last" = "last_name")) %>%
    rename(winner_full = full_name) %>%
    left_join(name_lookup, by = c("loser_last" = "last_name")) %>%
    rename(loser_full = full_name) %>%
    filter(!is.na(winner_full), !is.na(loser_full))

  cat(sprintf("Matched %d betting matches to full names\n", nrow(h2_predictions)))

  # Generate predictions
  predictions <- list()

  for (i in 1:nrow(h2_predictions)) {
    match <- h2_predictions[i, ]
    winner <- match$winner_full
    loser <- match$loser_full

    winner_elo <- elo_ratings[[winner]]
    if (is.null(winner_elo)) winner_elo <- 1500
    loser_elo <- elo_ratings[[loser]]
    if (is.null(loser_elo)) loser_elo <- 1500

    elo_prob_winner <- 1 / (1 + 10^((loser_elo - winner_elo) / 400))

    predictions[[i]] <- tibble(
      match_date = match$Date,
      tournament = match$Tournament,
      surface = match$Surface,
      round = match$Round,
      winner = winner,
      loser = loser,
      winner_odds = match$PSW,
      loser_odds = match$PSL,
      elo_prob_winner = elo_prob_winner,
      elo_correct = elo_prob_winner > 0.5
    )

    # Rolling update
    expected_winner <- elo_prob_winner
    elo_ratings[[winner]] <- winner_elo + k * (1 - expected_winner)
    elo_ratings[[loser]] <- loser_elo + k * (0 - (1 - expected_winner))
  }

  preds <- bind_rows(predictions)
  cat(sprintf("Generated %d predictions\n", nrow(preds)))

} else {
  # Use the matched data
  preds <- h2_with_odds %>%
    rename(winner_odds = W_odds, loser_odds = L_odds)

  # Generate Elo predictions
  for (i in 1:nrow(preds)) {
    winner <- preds$winner_name[i]
    loser <- preds$loser_name[i]

    winner_elo <- elo_ratings[[winner]]
    if (is.null(winner_elo)) winner_elo <- 1500
    loser_elo <- elo_ratings[[loser]]
    if (is.null(loser_elo)) loser_elo <- 1500

    preds$elo_prob_winner[i] <- 1 / (1 + 10^((loser_elo - winner_elo) / 400))
    preds$elo_correct[i] <- preds$elo_prob_winner[i] > 0.5

    # Rolling update
    expected_winner <- preds$elo_prob_winner[i]
    elo_ratings[[winner]] <- winner_elo + k * (1 - expected_winner)
    elo_ratings[[loser]] <- loser_elo + k * (0 - (1 - expected_winner))
  }

  preds <- preds %>%
    mutate(winner = winner_name, loser = loser_name, tournament = tourney_name)
}

# Enrich with features
preds <- preds %>%
  mutate(
    market_fav = ifelse(winner_odds < loser_odds, winner, loser),
    market_fav_odds = pmin(winner_odds, loser_odds),
    elo_pick = ifelse(elo_prob_winner > 0.5, winner, loser),
    elo_conf = pmax(elo_prob_winner, 1 - elo_prob_winner),
    agree = (elo_pick == market_fav),
    bet_odds = ifelse(elo_pick == winner, winner_odds, loser_odds),
    bet_won = elo_correct,
    profit = ifelse(bet_won, bet_odds - 1, -1),
    is_masters = str_detect(tolower(tournament), "masters|monte carlo|madrid|rome|paris|canada|cincinnati|shanghai"),
    is_grand_slam = str_detect(tolower(tournament), "open|wimbledon|roland garros|us open")
  )

# Get player rankings
player_ranks <- hist_matches %>%
  filter(match_date >= as.Date("2024-01-01"), match_date < as.Date("2024-07-01")) %>%
  select(player = winner_name, rank = winner_rank) %>%
  bind_rows(
    hist_matches %>%
      filter(match_date >= as.Date("2024-01-01"), match_date < as.Date("2024-07-01")) %>%
      select(player = loser_name, rank = loser_rank)
  ) %>%
  group_by(player) %>%
  summarise(best_rank = min(rank, na.rm = TRUE), .groups = "drop") %>%
  filter(is.finite(best_rank))

preds <- preds %>%
  left_join(player_ranks %>% rename(winner_rank = best_rank), by = c("winner" = "player")) %>%
  left_join(player_ranks %>% rename(loser_rank = best_rank), by = c("loser" = "player")) %>%
  mutate(
    fav_rank = ifelse(market_fav == winner, winner_rank, loser_rank),
    dog_rank = ifelse(market_fav == winner, loser_rank, winner_rank),
    fav_rank_bucket = case_when(
      is.na(fav_rank) ~ "Unknown",
      fav_rank <= 10 ~ "Top 10",
      fav_rank <= 30 ~ "11-30",
      TRUE ~ "31+"
    ),
    dog_rank_bucket = case_when(
      is.na(dog_rank) ~ "Unknown",
      dog_rank <= 30 ~ "Top 30 dog",
      dog_rank <= 50 ~ "31-50 dog",
      TRUE ~ "51+ dog"
    )
  )

# Overall performance
cat("\n========================================\n")
cat("H2 2024 OVERALL PERFORMANCE\n")
cat("========================================\n\n")

cat(sprintf("Total matches: %d\n", nrow(preds)))
cat(sprintf("Elo accuracy: %.1f%%\n", 100 * mean(preds$elo_correct)))
cat(sprintf("Overall ROI: %+.1f%%\n", 100 * mean(preds$profit)))

# Test subsets
cat("\n========================================\n")
cat("VALIDATION OF H1 2024 EDGE SUBSETS\n")
cat("========================================\n\n")

test_subset <- function(data, name, h1_roi = NA) {
  if (nrow(data) < 10) {
    cat(sprintf("%s: N=%d (too small for H2)\n", name, nrow(data)))
    return(NULL)
  }

  wins <- sum(data$bet_won)
  n <- nrow(data)
  breakeven <- 1/mean(data$bet_odds)
  roi <- mean(data$profit)

  cat(sprintf("%s:\n", name))
  cat(sprintf("  H2 N=%d, Accuracy=%.1f%%, ROI=%+.1f%%\n", n, 100*wins/n, 100*roi))
  if (!is.na(h1_roi)) {
    cat(sprintf("  (H1 ROI was %+.1f%%)\n", h1_roi))
  }
  cat("\n")

  tibble(subset = name, n = n, accuracy = wins/n, roi = roi, h1_roi = h1_roi)
}

results <- list()
i <- 1

# Test the key H1 edges
results[[i]] <- test_subset(
  preds %>% filter(str_detect(tolower(surface), "clay"), is_masters, dog_rank_bucket == "Top 30 dog"),
  "Clay Masters + Top 30 Dog", h1_roi = 17.2
)
i <- i + 1

results[[i]] <- test_subset(
  preds %>% filter(str_detect(tolower(surface), "clay"), is_masters, fav_rank_bucket == "Top 10"),
  "Clay Masters + Top 10 Fav", h1_roi = 20.8
)
i <- i + 1

results[[i]] <- test_subset(
  preds %>% filter(str_detect(tolower(surface), "clay"),
                   fav_rank_bucket %in% c("Top 10", "11-30"),
                   dog_rank_bucket == "Top 30 dog"),
  "Clay Quality Matchups", h1_roi = 4.2
)
i <- i + 1

results[[i]] <- test_subset(
  preds %>% filter(str_detect(tolower(surface), "hard"),
                   !str_detect(tolower(round), "1st|r128|r64|r32")),
  "Hard Later Rounds", h1_roi = 2.4
)
i <- i + 1

results[[i]] <- test_subset(
  preds %>% filter(str_detect(tolower(surface), "clay"), is_masters),
  "All Clay Masters", h1_roi = 13.6
)
i <- i + 1

# Exploratory
cat("========================================\n")
cat("EXPLORATORY H2 2024\n")
cat("========================================\n\n")

for (surf in c("Hard", "Clay", "Grass")) {
  results[[i]] <- test_subset(preds %>% filter(str_detect(tolower(surface), tolower(surf))), paste("Surface:", surf))
  i <- i + 1
}

results[[i]] <- test_subset(preds %>% filter(is_grand_slam), "Grand Slams")
i <- i + 1

# Summary
cat("\n========================================\n")
cat("VALIDATION SUMMARY\n")
cat("========================================\n\n")

summary_df <- bind_rows(results) %>%
  filter(!is.na(subset)) %>%
  mutate(
    validated = roi > 0,
    consistent = !is.na(h1_roi) & ((roi > 0 & h1_roi > 0) | (roi < 0 & h1_roi < 0))
  )

summary_df %>%
  mutate(
    accuracy = sprintf("%.1f%%", 100 * accuracy),
    roi = sprintf("%+.1f%%", 100 * roi),
    h1_roi = ifelse(is.na(h1_roi), "-", sprintf("%+.1f%%", h1_roi)),
    status = case_when(
      is.na(validated) ~ "N/A",
      validated & consistent ~ "VALIDATED",
      validated ~ "Positive (new)",
      TRUE ~ "Not validated"
    )
  ) %>%
  select(subset, n, accuracy, roi, h1_roi, status) %>%
  print(n = 20)

# Save
saveRDS(preds, "data/processed/h2_2024_predictions.rds")
