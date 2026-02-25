# Betting Data Integration
# Download and process historical betting lines from tennis-data.co.uk
#
# Usage:
#   source("src/data/betting_data.R")
#   betting <- load_betting_data()
#   odds <- get_match_odds("2023-01-15", "Novak Djokovic", "Andrey Rublev", betting)

library(tidyverse)
library(lubridate)

# ============================================================================
# CONFIGURATION
# ============================================================================

# Data directory for betting data
BETTING_DATA_DIR <- "data/raw/tennis_betting"

# tennis-data.co.uk base URL
# Note: URLs may change - check http://www.tennis-data.co.uk/alldata.php
BETTING_BASE_URL <- "http://www.tennis-data.co.uk"

# Preferred bookmakers (in order of preference - Pinnacle is sharpest)
PREFERRED_BOOKS <- c("PS", "B365", "EX", "LB", "CB", "SB")

# ============================================================================
# DATA DOWNLOAD
# ============================================================================

#' Download betting data files from tennis-data.co.uk
#' @param years Vector of years to download
#' @param tour "ATP" or "WTA"
#' @param output_dir Directory to save files
#' @return Paths to downloaded files
download_betting_data <- function(years = 2015:2024, tour = "ATP",
                                   output_dir = BETTING_DATA_DIR) {

  if (!dir.exists(output_dir)) {
    dir.create(output_dir, recursive = TRUE)
    cat(sprintf("Created directory: %s\n", output_dir))
  }

  tour_code <- str_to_lower(tour)

  downloaded <- c()

  for (year in years) {
    # File naming convention varies by year
    # Recent years: {year}.xlsx or {year}.csv
    # Older years: {year}w.xls (WTA) or {year}.xls (ATP)

    # Try CSV first (easier to parse)
    url <- sprintf("%s/%sdata/%d.csv", BETTING_BASE_URL, tour_code, year)
    destfile <- file.path(output_dir, sprintf("%s_%d.csv", tour_code, year))

    # Check if already downloaded
    if (file.exists(destfile)) {
      cat(sprintf("  Already exists: %s\n", basename(destfile)))
      downloaded <- c(downloaded, destfile)
      next
    }

    cat(sprintf("Downloading %s %d...\n", tour, year))

    tryCatch({
      download.file(url, destfile, mode = "wb", quiet = TRUE)
      cat(sprintf("  Saved: %s\n", basename(destfile)))
      downloaded <- c(downloaded, destfile)
    }, error = function(e) {
      # Try Excel format
      url_xls <- sprintf("%s/%sdata/%d.xlsx", BETTING_BASE_URL, tour_code, year)
      destfile_xls <- file.path(output_dir, sprintf("%s_%d.xlsx", tour_code, year))

      tryCatch({
        download.file(url_xls, destfile_xls, mode = "wb", quiet = TRUE)
        cat(sprintf("  Saved: %s (xlsx)\n", basename(destfile_xls)))
        downloaded <- c(downloaded, destfile_xls)
      }, error = function(e2) {
        warning(sprintf("Failed to download %s %d: %s", tour, year, e2$message))
      })
    })
  }

  return(downloaded)
}

#' Read a single betting data file
#' @param filepath Path to CSV or Excel file
#' @return Dataframe with standardized columns
read_betting_file <- function(filepath) {
  ext <- tools::file_ext(filepath)

  if (ext == "csv") {
    data <- read_csv(filepath, show_col_types = FALSE)
  } else if (ext %in% c("xls", "xlsx")) {
    if (!requireNamespace("readxl", quietly = TRUE)) {
      stop("Package 'readxl' needed to read Excel files. Install with: install.packages('readxl')")
    }
    data <- readxl::read_excel(filepath)
  } else {
    stop("Unsupported file format: ", ext)
  }

  # Convert problematic columns to consistent types
  # Rank columns can be character (e.g., "N/A") or numeric
  rank_cols <- c("WRank", "LRank", "WPts", "LPts")
  for (col in rank_cols) {
    if (col %in% names(data)) {
      data[[col]] <- as.numeric(as.character(data[[col]]))
    }
  }

  # Ensure odds columns are numeric

  odds_cols <- names(data)[str_detect(names(data), "(^PS|^B365|^EX|^LB|^CB|^SB|Max|Avg)[WL]?$")]
  for (col in odds_cols) {
    if (col %in% names(data)) {
      data[[col]] <- as.numeric(as.character(data[[col]]))
    }
  }

  return(data)
}

# ============================================================================
# DATA PROCESSING
# ============================================================================

#' Load and process all betting data
#' @param data_dir Directory containing betting files
#' @param tour "ATP", "WTA", or "both"
#' @param year_from First year to include (default: 2000)
#' @param year_to Last year to include (default: 2024)
#' @return Dataframe with processed betting data
load_betting_data <- function(data_dir = BETTING_DATA_DIR, tour = "both",
                               year_from = 2000, year_to = 2024) {
  if (!dir.exists(data_dir)) {
    warning("Betting data directory not found: ", data_dir)
    cat("To download betting data, run:\n")
    cat("  download_betting_data(years = 2015:2024, tour = 'ATP')\n")
    return(NULL)
  }

  # Find all files - support multiple naming conventions:
  # YYYY.xlsx (tennis-data.co.uk default)
  # atp_YYYY.xlsx or wta_YYYY.xlsx (prefixed format)
  # YYYY.csv (CSV format)
  all_files <- list.files(data_dir, full.names = TRUE)

  # Filter to data files (xlsx, xls, csv)
  data_files <- all_files[str_detect(all_files, "\\.(xlsx?|csv)$")]

  # Extract years from filenames
  files_df <- tibble(path = data_files) %>%
    mutate(
      filename = basename(path),
      # Extract year from filename (handles YYYY.xlsx, atp_YYYY.xlsx, etc.)
      year = as.integer(str_extract(filename, "\\d{4}")),
      # Detect tour from filename
      file_tour = case_when(
        str_detect(str_to_lower(filename), "wta") ~ "WTA",
        str_detect(str_to_lower(filename), "atp") ~ "ATP",
        TRUE ~ "ATP"  # Default to ATP for files like 2020.xlsx
      )
    ) %>%
    filter(
      !is.na(year),
      year >= year_from,
      year <= year_to
    )

  # Filter by tour if specified

  if (tour != "both") {
    files_df <- files_df %>% filter(file_tour == str_to_upper(tour))
  }

  files <- files_df$path

  if (length(files) == 0) {
    warning("No betting data files found in: ", data_dir)
    return(NULL)
  }

  cat(sprintf("Loading %d betting data files (%d-%d)...\n",
              length(files), min(files_df$year), max(files_df$year)))

  all_data <- map_dfr(files, function(f) {
    cat(sprintf("  Loading: %s\n", basename(f)))
    tryCatch({
      data <- read_betting_file(f)
      # Add source info
      data$source_file <- basename(f)
      data$tour <- if(str_detect(f, "wta")) "WTA" else "ATP"
      data
    }, error = function(e) {
      warning(sprintf("Error reading %s: %s", f, e$message))
      NULL
    })
  })

  if (is.null(all_data) || nrow(all_data) == 0) {
    return(NULL)
  }

  # Handle duplicate column names (can happen with different file formats)
  dup_cols <- duplicated(names(all_data))
  if (any(dup_cols)) {
    cat(sprintf("  Removing %d duplicate columns\n", sum(dup_cols)))
    all_data <- all_data[, !dup_cols]
  }

  # Standardize column names
  all_data <- standardize_betting_columns(all_data)

  cat(sprintf("Loaded %s matches with betting data\n",
              format(nrow(all_data), big.mark = ",")))

  return(all_data)
}

#' Standardize betting data column names
#' @param data Raw betting dataframe
#' @return Dataframe with standardized columns
standardize_betting_columns <- function(data) {
  # tennis-data.co.uk uses various column naming conventions
  # We'll standardize to a common format

  # First, handle columns that might both exist and map to the same target
  # Coalesce Surface and Court into a single surface column
  if ("Surface" %in% names(data) && "Court" %in% names(data)) {
    data <- data %>%
      mutate(surface = coalesce(Surface, Court)) %>%
      select(-Surface, -Court)
  } else if ("Surface" %in% names(data)) {
    data <- data %>% rename(surface = Surface)
  } else if ("Court" %in% names(data)) {
    data <- data %>% rename(surface = Court)
  }

  # Common column mappings (excluding Surface/Court which we handled above)
  col_map <- c(
    # Match info
    "ATP" = "tournament_id",
    "Location" = "location",
    "Tournament" = "tournament",
    "Date" = "match_date",
    "Series" = "series",
    "Round" = "round",
    "Best of" = "best_of",
    "Best.of" = "best_of",
    "BestOf" = "best_of",

    # Players
    "Winner" = "winner",
    "Loser" = "loser",
    "WRank" = "winner_rank",
    "LRank" = "loser_rank",

    # Scores
    "W1" = "w_set1",
    "L1" = "l_set1",
    "W2" = "w_set2",
    "L2" = "l_set2",
    "W3" = "w_set3",
    "L3" = "l_set3",
    "W4" = "w_set4",
    "L4" = "l_set4",
    "W5" = "w_set5",
    "L5" = "l_set5",
    "Wsets" = "winner_sets",
    "Lsets" = "loser_sets",

    # Bookmaker odds (various columns)
    # Pinnacle Sports
    "PSW" = "ps_winner_odds",
    "PSL" = "ps_loser_odds",
    # Bet365
    "B365W" = "b365_winner_odds",
    "B365L" = "b365_loser_odds",
    # Betfair Exchange
    "EXW" = "ex_winner_odds",
    "EXL" = "ex_loser_odds",
    # Ladbrokes
    "LBW" = "lb_winner_odds",
    "LBL" = "lb_loser_odds",
    # Coral/Ladbrokes
    "CBW" = "cb_winner_odds",
    "CBL" = "cb_loser_odds",
    # Stan James / Sky Bet
    "SBW" = "sb_winner_odds",
    "SBL" = "sb_loser_odds",
    # Max/Avg odds
    "MaxW" = "max_winner_odds",
    "MaxL" = "max_loser_odds",
    "AvgW" = "avg_winner_odds",
    "AvgL" = "avg_loser_odds"
  )

  # Rename columns that match
  for (old_name in names(col_map)) {
    if (old_name %in% names(data)) {
      names(data)[names(data) == old_name] <- col_map[old_name]
    }
  }

  # Remove any remaining duplicate columns
  dup_cols <- duplicated(names(data))
  if (any(dup_cols)) {
    data <- data[, !dup_cols]
  }

  # Parse date
  if ("match_date" %in% names(data)) {
    data <- data %>%
      mutate(match_date = as_date(match_date))
  }

  # Parse best_of to numeric
  if ("best_of" %in% names(data)) {
    data <- data %>%
      mutate(best_of = as.integer(best_of))
  }

  return(data)
}

#' Get the best available odds for a match
#' @param match_row Single row from betting data
#' @param preferred_books Vector of preferred bookmaker codes
#' @return List with winner_odds, loser_odds, bookmaker used
get_best_odds <- function(match_row, preferred_books = PREFERRED_BOOKS) {
  # Try each bookmaker in order of preference
  for (book in preferred_books) {
    winner_col <- paste0(str_to_lower(book), "_winner_odds")
    loser_col <- paste0(str_to_lower(book), "_loser_odds")

    if (winner_col %in% names(match_row) && loser_col %in% names(match_row)) {
      w_odds <- match_row[[winner_col]]
      l_odds <- match_row[[loser_col]]

      if (!is.na(w_odds) && !is.na(l_odds) && w_odds > 1 && l_odds > 1) {
        return(list(
          winner_odds = w_odds,
          loser_odds = l_odds,
          bookmaker = book
        ))
      }
    }
  }

  # Fall back to max or average odds
  if ("max_winner_odds" %in% names(match_row)) {
    return(list(
      winner_odds = match_row$max_winner_odds,
      loser_odds = match_row$max_loser_odds,
      bookmaker = "MAX"
    ))
  }

  if ("avg_winner_odds" %in% names(match_row)) {
    return(list(
      winner_odds = match_row$avg_winner_odds,
      loser_odds = match_row$avg_loser_odds,
      bookmaker = "AVG"
    ))
  }

  return(list(winner_odds = NA, loser_odds = NA, bookmaker = NA))
}

#' Extract best odds for all matches
#' @param betting_data Betting dataframe
#' @return Dataframe with best odds added
extract_best_odds <- function(betting_data) {
  cat("Extracting best available odds for each match...\n")

  betting_data <- betting_data %>%
    rowwise() %>%
    mutate(
      best_odds = list(get_best_odds(cur_data())),
      best_winner_odds = best_odds$winner_odds,
      best_loser_odds = best_odds$loser_odds,
      odds_source = best_odds$bookmaker
    ) %>%
    select(-best_odds) %>%
    ungroup()

  # Count by source
  source_counts <- table(betting_data$odds_source, useNA = "ifany")
  cat("Odds sources:\n")
  print(source_counts)

  return(betting_data)
}

# ============================================================================
# NAME MATCHING
# ============================================================================

#' Build a name lookup table from ATP/WTA match data
#' Maps "LastName F." format to "FirstName LastName" format
#' @param stats_db Stats database from load_player_stats()
#' @return Tibble with betting_name and atp_name columns
build_name_lookup <- function(stats_db) {
  # Get all unique player names from ATP data
  atp_names <- unique(stats_db$player_stats_overall$player)

  # Build lookup: create betting-style name from ATP name
  lookup <- tibble(atp_name = atp_names) %>%
    mutate(
      # Split into parts
      parts = str_split(atp_name, " "),
      # First name is first part, last name is rest
      first_name = map_chr(parts, ~ .x[1]),
      last_name = map_chr(parts, ~ paste(.x[-1], collapse = " ")),
      # Create betting-style name: "LastName F."
      first_initial = str_sub(first_name, 1, 1),
      betting_name = paste0(last_name, " ", first_initial, "."),
      # Also create variant without period
      betting_name_alt = paste0(last_name, " ", first_initial),
      # And lowercase versions for matching
      betting_name_lower = str_to_lower(betting_name),
      atp_name_lower = str_to_lower(atp_name)
    ) %>%
    select(atp_name, betting_name, betting_name_alt, betting_name_lower, atp_name_lower, last_name)

  return(lookup)
}

#' Convert betting data player names to ATP format
#' @param betting_data Betting data with winner/loser columns
#' @param stats_db Stats database from load_player_stats()
#' @return Betting data with standardized names
standardize_player_names <- function(betting_data, stats_db) {
  cat("Standardizing player names to match ATP format...\n")

  # Build lookup table
  lookup <- build_name_lookup(stats_db)

  # Function to find ATP name for a betting name
  find_atp_name <- function(betting_name) {
    betting_lower <- str_to_lower(betting_name)

    # Try exact match on betting_name format
    match <- lookup %>%
      filter(betting_name_lower == betting_lower)
    if (nrow(match) == 1) return(match$atp_name[1])

    # Try matching without the period
    betting_no_period <- str_remove(betting_lower, "\\.$")
    match <- lookup %>%
      filter(str_to_lower(betting_name_alt) == betting_no_period)
    if (nrow(match) == 1) return(match$atp_name[1])

    # Try matching just the last name + first initial pattern
    # Parse betting name: "Last F." -> last = "Last", initial = "F"
    if (str_detect(betting_name, "\\s+[A-Z]\\.$")) {
      parts <- str_match(betting_name, "^(.+)\\s+([A-Z])\\.$")
      if (!is.na(parts[1, 2])) {
        last_part <- parts[1, 2]
        initial <- parts[1, 3]
        match <- lookup %>%
          filter(str_to_lower(last_name) == str_to_lower(last_part),
                 str_to_upper(str_sub(atp_name, 1, 1)) == initial)
        if (nrow(match) == 1) return(match$atp_name[1])
        # If multiple matches, return first (could be improved)
        if (nrow(match) > 1) return(match$atp_name[1])
      }
    }

    # Try as-is (maybe it's already in ATP format)
    match <- lookup %>%
      filter(atp_name_lower == betting_lower)
    if (nrow(match) == 1) return(match$atp_name[1])

    # No match found - return original
    return(betting_name)
  }

  # Vectorized version for performance
  find_atp_names <- Vectorize(find_atp_name)

  # Convert names
  n_before <- n_distinct(c(betting_data$winner, betting_data$loser))

  betting_data <- betting_data %>%
    mutate(
      winner = find_atp_names(winner),
      loser = find_atp_names(loser)
    )

  # Count matches
  all_names <- unique(c(betting_data$winner, betting_data$loser))
  atp_names <- unique(stats_db$player_stats_overall$player)
  matched <- sum(all_names %in% atp_names)

  cat(sprintf("  Matched %d/%d player names (%.1f%%)\n",
              matched, length(all_names), matched/length(all_names)*100))

  return(betting_data)
}

# ============================================================================
# ODDS UTILITIES
# ============================================================================

#' Convert decimal odds to implied probability
#' @param odds Decimal odds
#' @return Implied probability (0-1)
odds_to_implied_prob <- function(odds) {
  ifelse(odds > 0, 1 / odds, NA_real_)
}

#' Convert implied probability to decimal odds
#' @param prob Probability (0-1)
#' @return Decimal odds
implied_prob_to_odds <- function(prob) {
  ifelse(prob > 0, 1 / prob, NA_real_)
}

#' Remove vig from odds to get fair odds
#' @param odds1 Decimal odds for outcome 1
#' @param odds2 Decimal odds for outcome 2
#' @return List with fair_prob1, fair_prob2, vig
remove_vig <- function(odds1, odds2) {
  impl1 <- odds_to_implied_prob(odds1)
  impl2 <- odds_to_implied_prob(odds2)

  total_implied <- impl1 + impl2
  vig <- total_implied - 1

  # Distribute vig proportionally
  fair_prob1 <- impl1 / total_implied
  fair_prob2 <- impl2 / total_implied

  list(
    fair_prob1 = fair_prob1,
    fair_prob2 = fair_prob2,
    vig = vig,
    vig_pct = vig * 100
  )
}

#' Calculate edge (model probability - implied probability)
#' @param model_prob Model's predicted probability
#' @param odds Decimal odds offered
#' @param remove_vig Whether to compare to fair odds (default: TRUE)
#' @param other_odds Odds for other outcome (needed if remove_vig = TRUE)
#' @return Edge as a decimal
calculate_edge <- function(model_prob, odds, remove_vig = TRUE, other_odds = NULL) {
  if (remove_vig && !is.null(other_odds)) {
    fair <- remove_vig(odds, other_odds)
    implied_prob <- 1 - fair$fair_prob2  # Fair prob for this outcome
  } else {
    implied_prob <- odds_to_implied_prob(odds)
  }

  model_prob - implied_prob
}

# ============================================================================
# MATCH LOOKUP
# ============================================================================

#' Get odds for a specific match
#' @param match_date Date of match (as Date or string)
#' @param player1 First player name
#' @param player2 Second player name
#' @param betting_data Betting dataframe
#' @return Match row with odds, or NULL if not found
get_match_odds <- function(match_date, player1, player2, betting_data) {
  if (is.null(betting_data)) return(NULL)

  match_date <- as_date(match_date)

  # Try exact match first
  match <- betting_data %>%
    filter(
      match_date == !!match_date,
      (str_to_lower(winner) == str_to_lower(player1) & str_to_lower(loser) == str_to_lower(player2)) |
        (str_to_lower(winner) == str_to_lower(player2) & str_to_lower(loser) == str_to_lower(player1))
    )

  if (nrow(match) == 0) {
    # Try fuzzy matching on names
    match <- betting_data %>%
      filter(match_date == !!match_date) %>%
      filter(
        (str_detect(str_to_lower(winner), str_to_lower(player1)) |
           str_detect(str_to_lower(player1), str_to_lower(winner))) &
          (str_detect(str_to_lower(loser), str_to_lower(player2)) |
             str_detect(str_to_lower(player2), str_to_lower(loser)))
      )
  }

  if (nrow(match) == 0) {
    return(NULL)
  }

  # Return first match (should usually be only one)
  return(match[1, ])
}

#' Join model predictions with betting data
#' @param predictions Dataframe with player1, player2, match_date, p1_win_prob
#' @param betting_data Betting dataframe
#' @return Joined dataframe with odds and edge calculations
join_predictions_with_odds <- function(predictions, betting_data) {
  if (is.null(betting_data)) {
    warning("No betting data available")
    return(predictions)
  }

  # Ensure dates are comparable
  predictions <- predictions %>%
    mutate(match_date = as_date(match_date))

  betting_data <- betting_data %>%
    mutate(match_date = as_date(match_date))

  # Create lookup key
  predictions <- predictions %>%
    mutate(
      p1_lower = str_to_lower(player1),
      p2_lower = str_to_lower(player2)
    )

  betting_data <- betting_data %>%
    mutate(
      winner_lower = str_to_lower(winner),
      loser_lower = str_to_lower(loser)
    )

  # Try to join
  result <- predictions %>%
    left_join(
      betting_data %>%
        select(match_date, winner_lower, loser_lower,
               starts_with("best_"), odds_source, surface, round),
      by = c("match_date" = "match_date",
             "p1_lower" = "winner_lower",
             "p2_lower" = "loser_lower")
    )

  # Also try with players swapped
  unmatched <- result %>% filter(is.na(best_winner_odds))

  if (nrow(unmatched) > 0) {
    matched_swapped <- unmatched %>%
      select(-starts_with("best_"), -odds_source, -surface, -round) %>%
      left_join(
        betting_data %>%
          select(match_date, winner_lower, loser_lower,
                 starts_with("best_"), odds_source, surface, round),
        by = c("match_date" = "match_date",
               "p1_lower" = "loser_lower",
               "p2_lower" = "winner_lower")
      ) %>%
      # Swap odds since player order is reversed
      mutate(
        temp = best_winner_odds,
        best_winner_odds = best_loser_odds,
        best_loser_odds = temp
      ) %>%
      select(-temp)

    # Combine
    result <- bind_rows(
      result %>% filter(!is.na(best_winner_odds)),
      matched_swapped
    )
  }

  # Calculate edge
  result <- result %>%
    mutate(
      implied_prob_p1 = odds_to_implied_prob(best_winner_odds),
      edge = p1_win_prob - implied_prob_p1
    )

  return(result)
}

# ============================================================================
# SUMMARY STATISTICS
# ============================================================================

#' Summarize betting data coverage
#' @param betting_data Betting dataframe
#' @return Summary statistics
summarize_betting_data <- function(betting_data) {
  if (is.null(betting_data)) {
    cat("No betting data loaded\n")
    return(NULL)
  }

  cat("\n=== Betting Data Summary ===\n\n")

  # Date range
  cat(sprintf("Date range: %s to %s\n",
              min(betting_data$match_date, na.rm = TRUE),
              max(betting_data$match_date, na.rm = TRUE)))

  # Total matches
  cat(sprintf("Total matches: %s\n", format(nrow(betting_data), big.mark = ",")))

  # By tour
  if ("tour" %in% names(betting_data)) {
    cat("\nBy tour:\n")
    print(table(betting_data$tour))
  }

  # By year
  cat("\nBy year:\n")
  year_counts <- betting_data %>%
    mutate(year = year(match_date)) %>%
    count(year) %>%
    arrange(year)
  print(year_counts, n = 20)

  # By surface
  if ("surface" %in% names(betting_data)) {
    cat("\nBy surface:\n")
    print(table(betting_data$surface))
  }

  # Odds coverage
  cat("\nOdds coverage:\n")
  odds_cols <- names(betting_data)[str_detect(names(betting_data), "_odds$")]
  coverage <- sapply(odds_cols, function(col) {
    sum(!is.na(betting_data[[col]])) / nrow(betting_data) * 100
  })
  print(round(coverage, 1))

  invisible(betting_data)
}

# ============================================================================
# QUICK TEST
# ============================================================================

if (FALSE) {  # Set to TRUE to run test
  # Download betting data (run once)
  download_betting_data(years = 2020:2024, tour = "ATP")

  # Load betting data
  betting <- load_betting_data()

  # Summarize
  summarize_betting_data(betting)

  # Extract best odds
  betting <- extract_best_odds(betting)

  # Look up specific match
  match <- get_match_odds("2023-01-15", "Djokovic", "Rublev", betting)
  if (!is.null(match)) {
    cat("\nFound match:\n")
    cat(sprintf("  %s vs %s\n", match$winner, match$loser))
    cat(sprintf("  Winner odds: %.2f\n", match$best_winner_odds))
    cat(sprintf("  Loser odds: %.2f\n", match$best_loser_odds))

    fair <- remove_vig(match$best_winner_odds, match$best_loser_odds)
    cat(sprintf("  Fair probs: %.1f%% / %.1f%% (vig: %.1f%%)\n",
                fair$fair_prob1 * 100, fair$fair_prob2 * 100, fair$vig_pct))
  }
}
