# Paper Data Comparison
# Compare our dataset to the paper's reported match counts
# Paper: arxiv.org/html/2510.20454v1
# Paper filters: Grand Slams + Tour Finals + Masters 1000 + 500-series only
# Paper date range: 2014-01-01 to 2025-06-08
# Paper counts: 16,663 ATP matches (598 players), 16,447 WTA matches (567 players)

suppressPackageStartupMessages({
  library(tidyverse)
  library(lubridate)
})

# ============================================================================
# ATP 500-SERIES: explicit tournament name list
# draw_size is NOT a reliable proxy -- most 500s have draw_size=32 in Sackmann.
# Source: official ATP 500 tournament list 2014-2024.
# ============================================================================
ATP_500_NAMES <- c(
  "Dubai",           # Dubai Duty Free Tennis Championships
  "Rotterdam",       # ABN AMRO World Tennis Tournament
  "Acapulco",        # Abierto Mexicano Telcel (500 since at least 2014)
  "Rio de Janeiro",  # Rio Open (became 500 in 2014)
  "ATP Rio de Janeiro",  # alternate Sackmann name
  "Barcelona",       # Barcelona Open Banc Sabadell
  "Hamburg",         # bet-at-home Open / Hamburg Open
  "Queen's Club",    # Cinch Championships / Fever-Tree Championships
  "Halle",           # Terra Wortmann Open / Gerry Weber Open
  "Washington",      # Citi Open
  "Tokyo",           # Japan Open Tennis Championships
  "Beijing",         # China Open (ran as 500 through 2019)
  "Vienna",          # Erste Bank Open
  "Basel"            # Swiss Indoors
)

# ============================================================================
# LOAD DATA
# ============================================================================
cat("=== Paper Comparison: Match Counts ===\n\n")

atp_files <- list.files("data/raw/tennis_atp",
                         pattern = "atp_matches_[0-9]{4}.csv", full.names = TRUE)
atp_years  <- as.integer(gsub(".*atp_matches_([0-9]{4}).csv", "\\1", atp_files))
atp_files  <- atp_files[atp_years >= 2014]
cat(sprintf("ATP files: %d to %d\n", min(atp_years[atp_years >= 2014]),
                                       max(atp_years[atp_years >= 2014])))
atp_raw <- map_dfr(atp_files, ~read_csv(., show_col_types = FALSE))
cat(sprintf("ATP raw rows: %d\n\n", nrow(atp_raw)))

wta_files <- list.files("data/raw/tennis_wta",
                         pattern = "wta_matches_[0-9]{4}.csv", full.names = TRUE)
wta_years  <- as.integer(gsub(".*wta_matches_([0-9]{4}).csv", "\\1", wta_files))
wta_files  <- wta_files[wta_years >= 2014]
wta_raw <- map_dfr(wta_files, ~read_csv(., show_col_types = FALSE,
                     col_types = cols(winner_seed = col_character(),
                                      loser_seed  = col_character())))
cat(sprintf("WTA raw rows: %d\n\n", nrow(wta_raw)))

# ============================================================================
# FILTERS
# ============================================================================

remove_incomplete <- function(df) {
  df %>% filter(
    !is.na(score),
    !grepl("W/O|walkover", score, ignore.case = TRUE),
    !grepl("RET",          score, ignore.case = TRUE),
    !grepl("DEF|ABD",      score, ignore.case = TRUE)
  )
}

filter_atp <- function(df) {
  df %>%
    remove_incomplete() %>%
    filter(
      tourney_level %in% c("G", "F", "M") |
      (tourney_level == "A" & tourney_name %in% ATP_500_NAMES)
    )
}

filter_wta <- function(df) {
  # G = Grand Slams, F = WTA Finals
  # PM = Premier Mandatory (1000 equiv), P = Premier (500 equiv)
  # O = Olympics (excluded -- not part of WTA tour tier structure)
  df %>%
    remove_incomplete() %>%
    filter(tourney_level %in% c("G", "F", "PM", "P"))
}

atp_filtered <- filter_atp(atp_raw)
wta_filtered <- filter_wta(wta_raw)

# ============================================================================
# RESULTS
# ============================================================================

atp_players <- length(unique(c(atp_filtered$winner_name, atp_filtered$loser_name)))
wta_players <- length(unique(c(wta_filtered$winner_name, wta_filtered$loser_name)))

cat("=== FILTERED MATCH COUNTS ===\n\n")
cat(sprintf("  ATP (2014-2024):  %6d matches  |  %d unique players\n", nrow(atp_filtered), atp_players))
cat(sprintf("  WTA (2014-2024):  %6d matches  |  %d unique players\n", nrow(wta_filtered), wta_players))
cat("\n")
cat(sprintf("  Paper ATP target: %6d matches  |  598 players\n", 16663))
cat(sprintf("  Paper WTA target: %6d matches  |  567 players\n", 16447))
cat("\n")
cat(sprintf("  ATP gap: %+d matches  (paper goes to June 2025; ~6 months of missing data)\n",
            nrow(atp_filtered) - 16663))
cat(sprintf("  WTA gap: %+d matches\n", nrow(wta_filtered) - 16447))

# ============================================================================
# YEAR-BY-YEAR
# ============================================================================

cat("\n=== YEAR-BY-YEAR (ATP) ===\n")
atp_filtered %>%
  mutate(year = as.integer(substr(as.character(tourney_date), 1, 4))) %>%
  count(year, name = "matches") %>%
  print()

cat("\n=== YEAR-BY-YEAR (WTA) ===\n")
wta_filtered %>%
  mutate(year = as.integer(substr(as.character(tourney_date), 1, 4))) %>%
  count(year, name = "matches") %>%
  print()

# ============================================================================
# TOURNAMENT BREAKDOWN (to verify correct events included)
# ============================================================================

cat("\n=== ATP TOURNAMENTS INCLUDED ===\n")
atp_filtered %>%
  count(tourney_level, tourney_name, name = "matches") %>%
  arrange(tourney_level, desc(matches)) %>%
  print(n = 50)

cat("\n=== WTA TOURNAMENTS INCLUDED (sample top 20) ===\n")
wta_filtered %>%
  count(tourney_level, tourney_name, name = "matches") %>%
  arrange(tourney_level, desc(matches)) %>%
  print(n = 20)

# ============================================================================
# SANITY CHECK: what's in our ATP 500 list that we might be over/under-counting
# ============================================================================

cat("\n=== ATP 500-SERIES MATCHES PER TOURNAMENT ===\n")
atp_filtered %>%
  filter(tourney_level == "A") %>%
  mutate(year = as.integer(substr(as.character(tourney_date), 1, 4))) %>%
  count(tourney_name, name = "total_matches") %>%
  arrange(desc(total_matches)) %>%
  print()
