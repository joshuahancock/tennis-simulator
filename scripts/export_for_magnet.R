#!/usr/bin/env Rscript
#
# scripts/export_for_magnet.R
#
# Export tennis match data to CSV for the MagNet GNN replication pipeline.
# Produces two files in data/processed/magnet/:
#
#   match_data.csv   -- all completed premium-tier matches, 2014–Jun 2025
#   player_data.csv  -- player attributes (height, weight, dob, handedness)
#
# Paper split (Clegg & Cartlidge 2025):
#   Training: Jan 2014 – Dec 2022
#   Test:     Jan 2023 – Jun 2025
#
# Usage:
#   Rscript scripts/export_for_magnet.R
#
# Name format note:
#   Match data uses tennis-data.co.uk "Last F." convention (e.g. "Sinner J.").
#   Player attribute sources are joined on this same format.
#   Known limitation: compound surnames like "Del Potro" may match as "Potro J."
#   rather than "Del Potro J." — review player_data_coverage.csv after running
#   to identify gaps.

suppressPackageStartupMessages({
  library(tidyverse)
  library(lubridate)
})

source("src/data/tennis_data_loader.R")

OUT_DIR  <- "data/processed/magnet"
ATTR_DIR <- "data/raw/player_attributes"

dir.create(OUT_DIR, recursive = TRUE, showWarnings = FALSE)

PAPER_CUTOFF <- as.Date("2025-06-30")


# ============================================================================
# 1. Load match data (ATP + WTA, premium-tier, 2014–Jun 2025)
# ============================================================================

cat("Loading ATP matches...\n")
atp <- load_tduk_matches(tour = "atp", year_from = 2014, year_to = 2025,
                          premium_only = TRUE, verbose = TRUE)

cat("\nLoading WTA matches...\n")
wta <- load_tduk_matches(tour = "wta", year_from = 2014, year_to = 2025,
                          premium_only = TRUE, verbose = TRUE)

matches <- bind_rows(atp, wta) %>%
  filter(completed, match_date <= PAPER_CUTOFF) %>%
  arrange(match_date, tournament)

cat(sprintf("\nCombined (completed, <= %s): %d matches  (%s to %s)\n",
            PAPER_CUTOFF, nrow(matches),
            min(matches$match_date), max(matches$match_date)))

cat("\nBy tour and year:\n")
matches %>%
  count(tour, year) %>%
  pivot_wider(names_from = tour, values_from = n, values_fill = 0L) %>%
  arrange(year) %>%
  print(n = 20)


# ============================================================================
# 2. Build match_data.csv
#
# Player assignment: alphabetically earlier name → player_i, other → player_j.
# This is deterministic and consistent with how Python will rebuild the graph.
# ============================================================================

cat("\nBuilding match_data.csv...\n")

match_data <- matches %>%
  mutate(
    match_id  = row_number(),
    player_i  = if_else(winner_name <= loser_name, winner_name, loser_name),
    player_j  = if_else(winner_name <= loser_name, loser_name,  winner_name),
    winner    = if_else(winner_name == player_i, "i", "j"),
    games_i   = if_else(winner_name == player_i, winner_games, loser_games),
    games_j   = if_else(winner_name == player_i, loser_games,  winner_games),
    ps_odds_i = if_else(winner_name == player_i, ps_winner_odds, ps_loser_odds),
    ps_odds_j = if_else(winner_name == player_i, ps_loser_odds,  ps_winner_odds),
    tier      = series,
  ) %>%
  select(match_id, match_date, tour, tournament, tier, surface, round, best_of,
         player_i, player_j, winner, games_i, games_j,
         ps_odds_i, ps_odds_j)

cat(sprintf("  %d matches written\n", nrow(match_data)))
cat(sprintf("  With Pinnacle odds: %d (%.1f%%)\n",
            sum(!is.na(match_data$ps_odds_i)),
            mean(!is.na(match_data$ps_odds_i)) * 100))


# ============================================================================
# 3. Build player_data.csv
#
# Attribute sources (in priority order):
#   1. men.csv            -- manually curated ATP file ("Last F." names)
#   2. te_scraped_atp.csv -- scraped from tennisexplorer ("First Last" names)
#   3. te_scraped_wta.csv -- scraped from tennisexplorer ("First Last" names)
# ============================================================================

cat("\nBuilding player_data.csv...\n")

# Unique players with gender tagged from which tour their matches appear in
atp_names <- unique(c(atp$winner_name, atp$loser_name))
wta_names <- unique(c(wta$winner_name, wta$loser_name))

all_names <- tibble(name = unique(c(match_data$player_i, match_data$player_j))) %>%
  arrange(name) %>%
  mutate(gender = case_when(
    name %in% atp_names ~ "M",
    name %in% wta_names ~ "F",
    TRUE                ~ NA_character_
  ))

cat(sprintf("  %d unique players  (M: %d, F: %d)\n",
            nrow(all_names),
            sum(all_names$gender == "M", na.rm = TRUE),
            sum(all_names$gender == "F", na.rm = TRUE)))


# ---- Helper: convert "First Last" (Sackmann) to "Last F." (tduk format) ----
# NOTE: compound surnames (e.g. "Juan Martin Del Potro" -> "Potro J.") will
# not match "Del Potro J." — these are flagged in the coverage report.
sackmann_to_tduk <- function(full_name) {
  parts <- str_split(full_name, "\\s+")[[1]]
  if (length(parts) < 2) return(full_name)
  last    <- parts[length(parts)]
  initial <- str_sub(parts[1], 1, 1)
  paste0(last, " ", initial, ".")
}

# ---- Source 1: men.csv ----
men_csv <- file.path(ATTR_DIR, "men.csv")
men_attrs <- if (file.exists(men_csv)) {
  read_csv(men_csv, show_col_types = FALSE) %>%
    transmute(
      name      = player_name,
      height_cm = as.numeric(height),
      weight_kg = as.numeric(weight),
      dob       = as.character(date_of_birth),
      hand      = if_else(righthanded == 1, "R",
                  if_else(righthanded == 0, "L", NA_character_)),
      src       = "men.csv"
    )
} else {
  cat("  [WARN] men.csv not found — skipping\n")
  tibble(name=character(), height_cm=numeric(), weight_kg=numeric(),
         dob=character(), hand=character(), src=character())
}

# ---- Source 2: te_scraped_atp.csv ----
te_atp_csv <- file.path(ATTR_DIR, "te_scraped_atp.csv")
te_atp_attrs <- if (file.exists(te_atp_csv)) {
  read_csv(te_atp_csv, show_col_types = FALSE) %>%
    mutate(name = map_chr(player_name, sackmann_to_tduk)) %>%
    transmute(
      name,
      height_cm = as.numeric(height_cm),
      weight_kg = as.numeric(weight_kg),
      dob       = as.character(dob),
      hand      = if_else(is_righthanded == 1L, "R",
                  if_else(is_righthanded == 0L, "L", NA_character_)),
      src       = "te_scraped_atp"
    )
} else {
  tibble(name=character(), height_cm=numeric(), weight_kg=numeric(),
         dob=character(), hand=character(), src=character())
}

# ---- Source 3: te_scraped_wta.csv ----
te_wta_csv <- file.path(ATTR_DIR, "te_scraped_wta.csv")
te_wta_attrs <- if (file.exists(te_wta_csv)) {
  read_csv(te_wta_csv, show_col_types = FALSE) %>%
    mutate(name = map_chr(player_name, sackmann_to_tduk)) %>%
    transmute(
      name,
      height_cm = as.numeric(height_cm),
      weight_kg = as.numeric(weight_kg),
      dob       = as.character(dob),
      hand      = if_else(is_righthanded == 1L, "R",
                  if_else(is_righthanded == 0L, "L", NA_character_)),
      src       = "te_scraped_wta"
    )
} else {
  cat("  [INFO] te_scraped_wta.csv not found — WTA attributes not yet available\n")
  tibble(name=character(), height_cm=numeric(), weight_kg=numeric(),
         dob=character(), hand=character(), src=character())
}

# ---- Merge: coalesce across sources (men.csv takes priority) ----
all_attrs <- bind_rows(men_attrs, te_atp_attrs, te_wta_attrs) %>%
  group_by(name) %>%
  summarise(
    height_cm = first(height_cm[!is.na(height_cm)]),
    weight_kg = first(weight_kg[!is.na(weight_kg)]),
    dob       = first(dob[!is.na(dob)]),
    hand      = first(hand[!is.na(hand)]),
    .groups   = "drop"
  )

player_data <- all_names %>%
  left_join(all_attrs, by = "name") %>%
  select(name, gender, hand, dob, height_cm, weight_kg)


# ---- Coverage report ----
report_coverage <- function(col, label, df = player_data) {
  n_ok  <- sum(!is.na(df[[col]]))
  total <- nrow(df)
  # Also by gender
  m_ok  <- sum(!is.na(df[[col]][df$gender == "M"]))
  m_tot <- sum(df$gender == "M", na.rm = TRUE)
  f_ok  <- sum(!is.na(df[[col]][df$gender == "F"]))
  f_tot <- sum(df$gender == "F", na.rm = TRUE)
  cat(sprintf("  %-12s %4d/%4d (%5.1f%%)   M: %4d/%4d (%5.1f%%)   F: %4d/%4d (%5.1f%%)\n",
              label,
              n_ok, total, n_ok / total * 100,
              m_ok, m_tot, if (m_tot > 0) m_ok / m_tot * 100 else 0,
              f_ok, f_tot, if (f_tot > 0) f_ok / f_tot * 100 else 0))
}

cat(sprintf("\nPlayer attribute coverage (%d total players):\n", nrow(player_data)))
cat(sprintf("  %-12s %4s/%4s (%5s)   %-22s   %-22s\n",
            "Field", "ok", "tot", "pct", "M", "F"))
report_coverage("height_cm", "height_cm")
report_coverage("weight_kg", "weight_kg")
report_coverage("hand",      "hand")
report_coverage("dob",       "dob")

# Save coverage detail for manual inspection
coverage_out <- file.path(OUT_DIR, "player_data_coverage.csv")
player_data %>%
  mutate(
    has_height = !is.na(height_cm),
    has_weight = !is.na(weight_kg),
    has_hand   = !is.na(hand),
    has_dob    = !is.na(dob),
    n_attrs    = has_height + has_weight + has_hand + has_dob
  ) %>%
  write_csv(coverage_out)

cat(sprintf("\n  Full detail: %s\n", coverage_out))


# ============================================================================
# 4. Write outputs
# ============================================================================

match_out  <- file.path(OUT_DIR, "match_data.csv")
player_out <- file.path(OUT_DIR, "player_data.csv")

write_csv(match_data,  match_out)
write_csv(player_data, player_out)

cat(sprintf("\nWrote: %s  (%d rows)\n", match_out,  nrow(match_data)))
cat(sprintf("Wrote: %s (%d rows)\n", player_out, nrow(player_data)))

cat("\n=== Done ===\n")
