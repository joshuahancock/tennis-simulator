# Tennis Data Loader: tennis-data.co.uk
#
# Loads ATP or WTA match data from tennis-data.co.uk Excel files.
# Used for all models that do NOT require serve/return statistics (Elo, MagNet).
# For serve/return stats, use src/data/player_stats.R (Sackmann source).
#
# Files live in data/raw/tennis_betting/{tour}/{year}.xlsx
#   ATP: data/raw/tennis_betting/atp/2014.xlsx ... 2026.xlsx
#   WTA: data/raw/tennis_betting/wta/2014.xlsx ... 2026.xlsx
#
# Years 2014-2019 can be downloaded from tennis-data.co.uk/alldata.php
# (same format, required for full paper-comparable training history)
#
# Usage:
#   source("src/data/tennis_data_loader.R")
#   atp <- load_tduk_matches(tour = "atp", year_from = 2014, year_to = 2025)
#   wta <- load_tduk_matches(tour = "wta", year_from = 2014, year_to = 2025)

suppressPackageStartupMessages(library(tidyverse))
suppressPackageStartupMessages(library(readxl))

# ============================================================================
# CONFIGURATION
# ============================================================================

# Tier labels that qualify as premium, by tour.
#
# ATP:  Series column — "Grand Slam", "Masters 1000", "Masters Cup", "ATP500"
#
# WTA:  Tier column (different column name from ATP's Series).
#   Post-2021: clean labels — WTA1000, WTA500, Grand Slam, Tour Championships
#   Pre-2021:  "Premier" covers ALL Premier sub-tiers (Mandatory=1000, 5=500,
#              and lower Premier) under one label — tennis-data.co.uk does not
#              distinguish them. We include all Premier matches for training;
#              evaluation accuracy should be assessed on 2021+ data only.
#   "International" = WTA 250 level — excluded.
PREMIUM_SERIES_ATP <- c("Grand Slam", "Masters 1000", "Masters Cup", "ATP500")
PREMIUM_SERIES_WTA <- c("Grand Slam", "WTA1000", "WTA500", "Tour Championships", "Premier")

# Comment values indicating no match was actually completed
SKIP_COMMENTS <- c("Walkover", "Disqualified")

# Valid surfaces
VALID_SURFACES <- c("Hard", "Clay", "Grass")

# ============================================================================
# LOADER
# ============================================================================

#' Load ATP or WTA matches from tennis-data.co.uk Excel files
#'
#' Returns a tidy tibble suitable for Elo training and evaluation.
#' Game totals (winner_games, loser_games) are computed from set scores.
#' Walkovers and disqualifications are excluded.
#'
#' @param tour       Tour to load: "atp" or "wta" (default: "atp")
#' @param year_from  First year to load (default: 2014)
#' @param year_to    Last year to load (default: 2026)
#' @param premium_only Filter to top-tier events only (default: TRUE)
#' @param data_dir   Base directory containing atp/ and wta/ subdirs
#' @param verbose    Print loading progress
#' @return Tibble with columns:
#'   tour, match_date, year, tournament, series, surface, round, best_of,
#'   winner_name, loser_name, winner_rank, loser_rank,
#'   winner_games, loser_games, completed,
#'   ps_winner_odds, ps_loser_odds
load_tduk_matches <- function(tour         = "atp",
                               year_from    = 2014,
                               year_to      = 2026,
                               premium_only = TRUE,
                               data_dir     = "data/raw/tennis_betting",
                               verbose      = TRUE) {
  tour <- tolower(tour)
  if (!tour %in% c("atp", "wta")) stop("tour must be 'atp' or 'wta'")

  tour_dir <- file.path(data_dir, tour)
  files    <- list.files(tour_dir, pattern = "^\\d{4}\\.xlsx$", full.names = TRUE)
  years    <- as.integer(sub(".*/?(\\d{4})\\.xlsx$", "\\1", files))

  files <- files[years >= year_from & years <= year_to]
  years <- years[years >= year_from & years <= year_to]

  if (length(files) == 0) {
    stop(sprintf(
      "No .xlsx files found in %s for years %d-%d.\n  Expected path: %s/{year}.xlsx",
      tour_dir, year_from, year_to, tour_dir
    ))
  }

  premium_series <- if (tour == "atp") PREMIUM_SERIES_ATP else PREMIUM_SERIES_WTA

  if (verbose) {
    available_years <- sort(years)
    cat(sprintf("Loading tennis-data.co.uk [%s] files: %s\n",
                toupper(tour), paste(available_years, collapse = ", ")))
    if (year_from < min(available_years)) {
      cat(sprintf(
        "  NOTE: Years %d-%d not available locally. Download from tennis-data.co.uk/alldata.php\n",
        year_from, min(available_years) - 1
      ))
    }
  }

  raw_list <- map(files, \(f) {
    tryCatch({
      d <- suppressWarnings(read_excel(f))
      # WTA files use "Tier" instead of "Series" — normalise to "Series"
      if ("Tier" %in% names(d) && !"Series" %in% names(d))
        names(d)[names(d) == "Tier"] <- "Series"
      # WTA files only have 3 sets; add NA columns so bind_rows works uniformly
      for (col in c("W4", "W5", "L4", "L5"))
        if (!col %in% names(d)) d[[col]] <- NA_real_
      # Some years store WRank/LRank as character, others as double.
      # Normalise to integer before bind_rows to avoid type conflicts.
      coerce_int <- c("WRank", "LRank", "WPts", "LPts")
      coerce_dbl <- c("W1", "L1", "W2", "L2", "W3", "L3", "W4", "L4", "W5", "L5",
                      "Wsets", "Lsets", "B365W", "B365L", "PSW", "PSL",
                      "MaxW", "MaxL", "AvgW", "AvgL", "BFEW", "BFEL")
      for (col in intersect(coerce_int, names(d)))
        d[[col]] <- suppressWarnings(as.integer(as.character(d[[col]])))
      for (col in intersect(coerce_dbl, names(d)))
        d[[col]] <- suppressWarnings(as.numeric(as.character(d[[col]])))
      d
    }, error = function(e) {
      warning(sprintf("Failed to read %s: %s", f, e$message))
      NULL
    })
  })

  raw <- bind_rows(Filter(Negate(is.null), raw_list))

  if (nrow(raw) == 0) stop("No data loaded.")

  # ---- Normalise ----
  df <- raw %>%
    transmute(
      tour         = toupper(tour),
      match_date   = as.Date(Date),
      year         = year(match_date),
      tournament   = Tournament,
      series       = Series,
      surface      = Surface,
      round        = Round,
      best_of      = as.integer(`Best of`),
      winner_name  = Winner,
      loser_name   = Loser,
      winner_rank  = as.integer(WRank),
      loser_rank   = as.integer(LRank),
      # Set scores: sum across up to 5 sets (NA sets contribute 0)
      winner_games = as.integer(rowSums(
        cbind(W1, W2, W3, W4, W5), na.rm = TRUE)),
      loser_games  = as.integer(rowSums(
        cbind(L1, L2, L3, L4, L5), na.rm = TRUE)),
      comment      = coalesce(Comment, "Completed"),
      ps_winner_odds = PSW,
      ps_loser_odds  = PSL
    ) %>%
    filter(
      !is.na(match_date),
      !is.na(winner_name),
      !is.na(loser_name),
      surface %in% VALID_SURFACES,
      !comment %in% SKIP_COMMENTS
    ) %>%
    mutate(
      completed    = (comment == "Completed"),
      # NA game totals on retired/incomplete matches to avoid partial scores
      winner_games = if_else(completed, winner_games, NA_integer_),
      loser_games  = if_else(completed, loser_games,  NA_integer_)
    ) %>%
    arrange(match_date, tournament, round)

  if (premium_only) {
    df <- df %>% filter(series %in% premium_series)
    if (verbose) cat(sprintf("  After premium-tier filter: %d rows\n", nrow(df)))
  }

  if (verbose) {
    cat(sprintf("  Date range: %s to %s\n",
                min(df$match_date), max(df$match_date)))
    cat("  Series breakdown:\n")
    df %>% count(series, sort = TRUE) %>% print()
  }

  df
}

#' Summarise year-by-year coverage of the loaded matches
#'
#' @param df Output of load_tduk_matches()
summarise_tduk_coverage <- function(df) {
  df %>%
    group_by(year, series) %>%
    summarise(n = n(), .groups = "drop") %>%
    pivot_wider(names_from = series, values_from = n, values_fill = 0L) %>%
    mutate(total = rowSums(across(where(is.integer)))) %>%
    arrange(year)
}
