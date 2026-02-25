# Date Alignment Module
# Fixes the tourney_date vs actual match date mismatch between ATP and betting data
#
# The Problem:
#   ATP data uses `tourney_date` (tournament start date) for all matches
#   Betting data uses actual match dates
#   This causes data leakage when filtering by date
#
# The Solution:
#   Join ATP matches with betting matches to inherit actual dates
#   Fall back to inferred dates for unmatched matches
#
# Usage:
#   source("src/data/date_alignment.R")
#   aligned <- align_match_dates(atp_matches, betting_data)

library(tidyverse)
library(lubridate)
library(stringdist)

# ============================================================================
# ROUND MAPPING
# ============================================================================

# Map ATP round codes to betting round names
ROUND_MAP <- c(

"F" = "The Final",
"SF" = "Semifinals",
"QF" = "Quarterfinals",
"R16" = "4th Round|3rd Round|2nd Round",
"R32" = "3rd Round|2nd Round|1st Round",
"R64" = "2nd Round|1st Round",
"R128" = "1st Round",
"RR" = "Round Robin",
"BR" = "Bronze"
)

# Inferred days from tournament start by round and draw size
# Grand Slams: 14 days, Masters: 9 days, ATP 500/250: 7 days
get_round_day_offset <- function(round, draw_size) {
  if (draw_size >= 128) {
    # Grand Slam (128 draw, 14 days)
    offsets <- c("R128" = 0, "R64" = 2, "R32" = 4, "R16" = 6,
                 "QF" = 9, "SF" = 11, "F" = 13, "RR" = 0, "BR" = 13)
  } else if (draw_size >= 56) {
    # Masters 1000 (56-96 draw, 9 days)
    offsets <- c("R64" = 0, "R32" = 1, "R16" = 3, "QF" = 5,
                 "SF" = 7, "F" = 8, "RR" = 0, "BR" = 8)
  } else if (draw_size >= 32) {
    # ATP 500/250 (32 draw, 6-7 days)
    offsets <- c("R32" = 0, "R16" = 1, "QF" = 3, "SF" = 5, "F" = 6, "RR" = 0, "BR" = 6)
  } else {
    # Smaller draws (16 or less)
    offsets <- c("R16" = 0, "QF" = 1, "SF" = 3, "F" = 4, "RR" = 0, "BR" = 4)
  }

  offset <- offsets[round]
  if (is.na(offset)) offset <- 0
  return(offset)
}

# ============================================================================
# NAME CONVERSION
# ============================================================================

# Known player name mappings (ATP name -> betting format)
# These are players whose betting data name differs significantly from ATP
PLAYER_ALIASES <- list(
  "Albert Ramos" = "Ramos-Vinolas A.",
  "Christopher Oconnell" = "O'Connell C.",  # May not exist in betting data
  "Tomas Barrios Vera" = "Barrios M.",  # Full name is Marcelo Tomas Barrios Vera
  "Nicolas Moreno De Alboran" = "Moreno De Alboran N.",
  "Giovanni Mpetshi Perricard" = "Mpetshi G."  # Betting uses just first surname
)

#' Convert ATP name (First Last) to betting format (Last F.)
#' Handles edge cases:
#'   - Hyphenated names: "Felix Auger Aliassime" -> "Auger-Aliassime F."
#'   - Double first names: "Tomas Martin Etcheverry" -> "Etcheverry T."
#'   - Double initials: "J J Wolf" -> "Wolf J."
#' @param name ATP format name
#' @return Betting format name
atp_to_betting_name <- function(name) {
  if (is.na(name) || name == "") return(NA_character_)

  parts <- str_split(name, " ")[[1]]
  if (length(parts) < 2) return(name)

  # Detect double initials (e.g., "J J Wolf")
  # Pattern: first two parts are single letters
  if (length(parts) >= 3 && nchar(parts[1]) == 1 && nchar(parts[2]) == 1) {
    first_initial <- parts[1]
    last_name <- paste(parts[3:length(parts)], collapse = " ")
    return(paste0(last_name, " ", first_initial, "."))
  }

  # Detect double first names (e.g., "Tomas Martin Etcheverry", "Jan Lennard Struff")
  # Heuristic: if we have 3+ parts and middle part is capitalized and >= 3 chars,
  # it's likely a middle/second first name
  if (length(parts) >= 3) {
    # Check if second part looks like a first name (capitalized, not a suffix like "Jr")
    second_part <- parts[2]
    if (nchar(second_part) >= 3 &&
        str_to_upper(str_sub(second_part, 1, 1)) == str_sub(second_part, 1, 1) &&
        !second_part %in% c("Jr", "Jr.", "II", "III", "IV", "De", "Van", "Von", "Del", "Di", "Da")) {
      # Could be double first name - take last part(s) as surname
      first_initial <- str_sub(parts[1], 1, 1)
      last_name <- parts[length(parts)]
      return(paste0(last_name, " ", first_initial, "."))
    }
  }

  # Standard case: First Last or First De Minaur
  first_name <- parts[1]
  last_name <- paste(parts[-1], collapse = " ")
  first_initial <- str_sub(first_name, 1, 1)

  paste0(last_name, " ", first_initial, ".")
}

#' Normalize name for fuzzy matching
#' @param name Any format name
#' @return Lowercase, no punctuation, sorted tokens
normalize_name <- function(name) {
  if (is.na(name) || name == "") return("")

  name %>%
    str_to_lower() %>%
    str_replace_all("[^a-z ]", "") %>%
    str_squish()
}

#' Generate alternative name forms for matching
#' Handles hyphenated names, compound surnames, multi-initials, etc.
#' @param atp_name ATP format name (e.g., "Felix Auger Aliassime")
#' @return Vector of alternative betting-format names to try
generate_name_variants <- function(atp_name) {
  if (is.na(atp_name) || atp_name == "") return(character(0))

  parts <- str_split(atp_name, " ")[[1]]
  if (length(parts) < 2) return(character(0))

  variants <- character(0)

  # For names with 3+ parts, try hyphenating last two parts
  # "Felix Auger Aliassime" -> "Auger-Aliassime F."
  if (length(parts) >= 3) {
    first_initial <- str_sub(parts[1], 1, 1)
    # Try hyphenating second-to-last and last
    hyphenated <- paste(parts[(length(parts)-1):length(parts)], collapse = "-")
    variants <- c(variants, paste0(hyphenated, " ", first_initial, "."))

    # Also try with more parts hyphenated for triple-barrel names
    if (length(parts) >= 4) {
      hyphenated2 <- paste(parts[(length(parts)-2):length(parts)], collapse = "-")
      variants <- c(variants, paste0(hyphenated2, " ", first_initial, "."))
    }
  }

  # For names like "Giovanni Mpetshi Perricard", try "Mpetshi Perricard G."
  if (length(parts) == 3) {
    first_initial <- str_sub(parts[1], 1, 1)
    compound <- paste(parts[2:3], collapse = " ")
    variants <- c(variants, paste0(compound, " ", first_initial, "."))
  }

  # Multi-initial variants for double first names
  # "Jan Lennard Struff" -> "Struff J.L."
  # "Daniel Elahi Galan" -> "Galan D.E."
  if (length(parts) >= 3) {
    # Check if second part looks like a first/middle name
    second_part <- parts[2]
    if (nchar(second_part) >= 3 &&
        !second_part %in% c("De", "Van", "Von", "Del", "Di", "Da", "Jr", "Jr.")) {
      first_init <- str_sub(parts[1], 1, 1)
      second_init <- str_sub(parts[2], 1, 1)
      last_name <- parts[length(parts)]
      # Format: "Struff J.L."
      variants <- c(variants, paste0(last_name, " ", first_init, ".", second_init, "."))
    }
  }

  # Double initials: "J J Wolf" -> "Wolf J.J."
  if (length(parts) >= 3 && nchar(parts[1]) == 1 && nchar(parts[2]) == 1) {
    first_init <- parts[1]
    second_init <- parts[2]
    last_name <- paste(parts[3:length(parts)], collapse = " ")
    variants <- c(variants, paste0(last_name, " ", first_init, ".", second_init, "."))
  }

  # Special handling for Chinese/Korean names where first name might need special initial
  # "Zhizhen Zhang" -> "Zhang Zh."
  # "Soon Woo Kwon" -> "Kwon S.W."
  if (length(parts) == 2) {
    first <- parts[1]
    last <- parts[2]
    # Try two-letter initial for names like Zhizhen
    if (nchar(first) >= 4) {
      two_init <- str_sub(first, 1, 2)
      variants <- c(variants, paste0(last, " ", str_to_title(two_init), "."))
    }
  }
  if (length(parts) == 3) {
    # "Soon Woo Kwon" -> "Kwon S.W."
    first_init <- str_sub(parts[1], 1, 1)
    second_init <- str_sub(parts[2], 1, 1)
    last_name <- parts[3]
    variants <- c(variants, paste0(last_name, " ", first_init, ".", second_init, "."))
  }

  # Check for known player aliases
  if (atp_name %in% names(PLAYER_ALIASES)) {
    variants <- c(variants, PLAYER_ALIASES[[atp_name]])
  }

  # Handle "Juan Pablo Varillas" -> "Varillas J.P." (initials with period and space)
  if (length(parts) >= 3) {
    first_init <- str_sub(parts[1], 1, 1)
    second_init <- str_sub(parts[2], 1, 1)
    last_name <- parts[length(parts)]
    # Format: "Varillas J. P." (with space between initials)
    variants <- c(variants, paste0(last_name, " ", first_init, ". ", second_init, "."))
  }

  return(unique(variants))
}

#' Generate all name forms for matching (primary + variants)
#' @param atp_name ATP format name
#' @return Vector of all betting-format names to try (primary first)
get_all_name_forms <- function(atp_name) {
  primary <- atp_to_betting_name(atp_name)
  variants <- generate_name_variants(atp_name)
  unique(c(primary, variants))
}

#' Extract last name for matching
#' @param name Any format name
#' @return Last name component
extract_last_name <- function(name) {
  if (is.na(name) || name == "") return("")

  # Remove initials and periods
  cleaned <- str_replace_all(name, "\\s+[A-Z]\\.$", "")

  # For "First Last" format, take everything after first space
  parts <- str_split(cleaned, " ")[[1]]
  if (length(parts) >= 2) {
    # Could be "First Last" or "Last F." - check if last part is initial
    last_part <- parts[length(parts)]
    if (nchar(last_part) <= 2) {
      # Likely "Last F." format - take first part(s)
      return(paste(parts[-length(parts)], collapse = " "))
    } else {
      # Likely "First Last" format - take last part(s)
      return(paste(parts[-1], collapse = " "))
    }
  }
  return(cleaned)
}

# ============================================================================
# TOURNAMENT MATCHING
# ============================================================================

# Known tournament name mappings (ATP name -> betting name patterns)
TOURNAMENT_ALIASES <- list(
  "roland garros" = c("french open", "paris"),
  "us open" = c("us open", "new york", "flushing"),
  "australian open" = c("australian open", "melbourne"),
  "wimbledon" = c("wimbledon", "london"),
  "canada masters" = c("canadian open", "montreal", "toronto"),
  "indian wells masters" = c("bnp paribas open", "indian wells"),
  "miami masters" = c("miami open", "miami"),
  "monte carlo masters" = c("monte carlo masters", "monte carlo"),
  "rome masters" = c("internazionali", "rome"),
  "madrid masters" = c("mutua madrid", "madrid"),
  "cincinnati masters" = c("western southern", "cincinnati"),
  "shanghai masters" = c("shanghai masters", "shanghai"),
  "paris masters" = c("bnp paribas masters", "paris"),
  "tour finals" = c("masters cup", "turin", "atp finals"),
  "s hertogenbosch" = c("hertogenbosch", "rosmalen"),
  "halle" = c("halle open", "halle"),
  "queens" = c("queen", "london")
)

#' Normalize tournament name for matching
#' @param name Tournament name
#' @return Normalized name
normalize_tournament <- function(name) {
  if (is.na(name) || name == "") return("")

  norm <- name %>%
    str_to_lower() %>%
    str_replace_all("masters|open|international|championship|classic|trophy|cup", "") %>%
    str_replace_all("[^a-z ]", "") %>%
    str_squish()

  # Check for known aliases
  for (alias_key in names(TOURNAMENT_ALIASES)) {
    if (str_detect(norm, fixed(str_replace_all(alias_key, " ", "")))) {
      return(alias_key)
    }
    # Also check if name contains the alias key
    if (str_detect(str_to_lower(name), fixed(alias_key))) {
      return(alias_key)
    }
  }

  return(norm)
}

#' Check if two tournament names match
#' @param atp_name ATP tournament name (normalized)
#' @param bet_name Betting tournament name (original)
#' @param bet_location Betting location (original)
#' @return TRUE if they match
tournaments_match <- function(atp_name, bet_name, bet_location) {
  if (is.na(atp_name) || is.na(bet_name)) return(FALSE)

  atp_norm <- normalize_tournament(atp_name)
  bet_norm <- normalize_tournament(bet_name)
  loc_norm <- normalize_tournament(bet_location)

  # Direct match
  if (atp_norm == bet_norm || atp_norm == loc_norm) return(TRUE)

  # Substring match
  if (nchar(atp_norm) >= 4) {
    if (str_detect(bet_norm, fixed(atp_norm)) ||
        str_detect(loc_norm, fixed(atp_norm))) return(TRUE)
  }

  # Check aliases
  if (atp_norm %in% names(TOURNAMENT_ALIASES)) {
    patterns <- TOURNAMENT_ALIASES[[atp_norm]]
    bet_lower <- str_to_lower(paste(bet_name, bet_location))
    for (p in patterns) {
      if (str_detect(bet_lower, fixed(p))) return(TRUE)
    }
  }

  return(FALSE)
}

#' Build tournament mapping between ATP and betting data
#' @param atp_tourneys Unique ATP tournament names
#' @param bet_tourneys Unique betting tournament names
#' @return Tibble with atp_name and betting_name
build_tournament_mapping <- function(atp_tourneys, bet_tourneys) {
  # Create normalized versions
  atp_df <- tibble(atp_name = atp_tourneys) %>%
    mutate(atp_norm = map_chr(atp_name, normalize_tournament))

  bet_df <- tibble(betting_name = bet_tourneys) %>%
    mutate(bet_norm = map_chr(betting_name, normalize_tournament))

  # Try exact match on normalized names first
  exact <- atp_df %>%
    inner_join(bet_df, by = c("atp_norm" = "bet_norm")) %>%
    select(atp_name, betting_name)

  # For unmatched, use string distance
  unmatched_atp <- atp_df %>% filter(!(atp_name %in% exact$atp_name))

  if (nrow(unmatched_atp) > 0 && nrow(bet_df) > 0) {
    fuzzy_matches <- unmatched_atp %>%
      rowwise() %>%
      mutate(
        best_match = {
          dists <- stringdist(atp_norm, bet_df$bet_norm, method = "jw")
          if (min(dists) < 0.3) {
            bet_df$betting_name[which.min(dists)]
          } else {
            NA_character_
          }
        }
      ) %>%
      ungroup() %>%
      filter(!is.na(best_match)) %>%
      select(atp_name, betting_name = best_match)

    result <- bind_rows(exact, fuzzy_matches)
  } else {
    result <- exact
  }

  return(result)
}

# ============================================================================
# MAIN ALIGNMENT FUNCTION
# ============================================================================

#' Align ATP match dates with betting data actual dates
#'
#' Uses multiple matching strategies to maximize data retention:
#' 1. Exact match on normalized names + tournament + date window
#' 2. Fuzzy match on last names + tournament + date window
#' 3. Inferred date from round for unmatched matches
#'
#' @param atp_matches ATP match data with tourney_date
#' @param betting_data Betting data with actual Date
#' @param verbose Print progress messages
#' @return ATP matches with actual_match_date column added
align_match_dates <- function(atp_matches, betting_data, verbose = TRUE) {
  if (verbose) cat("=== Aligning ATP match dates with betting data ===\n\n")

  n_atp <- nrow(atp_matches)

  # Prepare ATP data
  atp_prep <- atp_matches %>%
    mutate(
      atp_row_id = row_number(),
      tourney_start = ymd(tourney_date),
      winner_betting = map_chr(winner_name, atp_to_betting_name),
      loser_betting = map_chr(loser_name, atp_to_betting_name),
      winner_norm = map_chr(winner_name, normalize_name),
      loser_norm = map_chr(loser_name, normalize_name),
      winner_last = map_chr(winner_name, extract_last_name),
      loser_last = map_chr(loser_name, extract_last_name),
      tourney_norm = map_chr(tourney_name, normalize_tournament)
    )

  # Prepare betting data
  # Handle both raw (Date, Winner, Loser, Tournament, Location) and
  # processed (match_date, winner, loser, tournament, location) column names

  # Standardize column names first
  betting_std <- betting_data
  if ("Date" %in% names(betting_std) && !"match_date" %in% names(betting_std)) {
    betting_std$match_date <- as_date(betting_std$Date)
  }
  if ("Winner" %in% names(betting_std) && !"winner" %in% names(betting_std)) {
    betting_std$winner <- betting_std$Winner
  }
  if ("Loser" %in% names(betting_std) && !"loser" %in% names(betting_std)) {
    betting_std$loser <- betting_std$Loser
  }
  if ("Tournament" %in% names(betting_std) && !"tournament" %in% names(betting_std)) {
    betting_std$tournament <- betting_std$Tournament
  }
  if ("Location" %in% names(betting_std) && !"location" %in% names(betting_std)) {
    betting_std$location <- betting_std$Location
  }
  if ("Round" %in% names(betting_std) && !"round" %in% names(betting_std)) {
    betting_std$round <- betting_std$Round
  }

  betting_prep <- betting_std %>%
    mutate(
      bet_row_id = row_number(),
      bet_match_date = as_date(match_date),
      bet_winner_norm = map_chr(winner, normalize_name),
      bet_loser_norm = map_chr(loser, normalize_name),
      bet_winner_last = map_chr(winner, extract_last_name),
      bet_loser_last = map_chr(loser, extract_last_name),
      bet_tourney_orig = tournament,
      bet_location_orig = location
    ) %>%
    select(bet_row_id, bet_match_date, bet_winner_norm, bet_loser_norm,
           bet_winner_last, bet_loser_last, bet_tourney_orig, bet_location_orig)

  if (verbose) cat(sprintf("ATP matches to align: %d\n", n_atp))
  if (verbose) cat(sprintf("Betting matches available: %d\n", nrow(betting_prep)))

  # ---- Strategy 1: Exact match on betting-format names + tournament ----
  if (verbose) cat("\nStrategy 1: Betting-format name + tournament match...\n")

  # Create normalized betting-format names for ATP data
  atp_prep <- atp_prep %>%
    mutate(
      winner_bet_norm = map_chr(winner_betting, normalize_name),
      loser_bet_norm = map_chr(loser_betting, normalize_name)
    )

  matched_exact <- atp_prep %>%
    inner_join(
      betting_prep,
      by = c("winner_bet_norm" = "bet_winner_norm", "loser_bet_norm" = "bet_loser_norm"),
      relationship = "many-to-many"
    ) %>%
    # Filter to same tournament using improved matching
    rowwise() %>%
    filter(tournaments_match(tourney_name, bet_tourney_orig, bet_location_orig)) %>%
    ungroup() %>%
    # Filter to reasonable date window (within 21 days of tourney start)
    filter(
      bet_match_date >= tourney_start - days(1),
      bet_match_date <= tourney_start + days(21)
    ) %>%
    # Take closest match if multiple
    group_by(atp_row_id) %>%
    slice_min(abs(as.numeric(bet_match_date - tourney_start)), n = 1, with_ties = FALSE) %>%
    ungroup() %>%
    select(atp_row_id, actual_match_date = bet_match_date, match_source = bet_row_id)

  if (verbose) cat(sprintf("  Matched: %d (%.1f%%)\n",
                           nrow(matched_exact), 100 * nrow(matched_exact) / n_atp))

  # ---- Strategy 1b: Name variants for hyphenated/compound names ----
  remaining_ids <- setdiff(atp_prep$atp_row_id, matched_exact$atp_row_id)

  if (length(remaining_ids) > 0) {
    if (verbose) cat("\nStrategy 1b: Name variants (hyphenated/compound)...\n")

    atp_remaining <- atp_prep %>% filter(atp_row_id %in% remaining_ids)

    # Generate name variants for remaining matches
    atp_with_variants <- atp_remaining %>%
      rowwise() %>%
      mutate(
        winner_variants = list(generate_name_variants(winner_name)),
        loser_variants = list(generate_name_variants(loser_name))
      ) %>%
      ungroup()

    # For each match with variants, try to find a betting match
    matched_variants <- atp_with_variants %>%
      filter(map_int(winner_variants, length) > 0 | map_int(loser_variants, length) > 0) %>%
      rowwise() %>%
      mutate(
        bet_match = list({
          # Try each winner variant
          w_forms <- if (length(winner_variants) > 0)
            map_chr(winner_variants, normalize_name) else winner_bet_norm
          l_forms <- if (length(loser_variants) > 0)
            map_chr(loser_variants, normalize_name) else loser_bet_norm

          # Also include original forms
          w_forms <- unique(c(winner_bet_norm, w_forms))
          l_forms <- unique(c(loser_bet_norm, l_forms))

          # Find matching betting rows
          matches <- betting_prep %>%
            filter(
              bet_winner_norm %in% w_forms,
              bet_loser_norm %in% l_forms,
              bet_match_date >= tourney_start - days(1),
              bet_match_date <= tourney_start + days(21)
            )

          if (nrow(matches) > 0) {
            # Filter by tournament
            tourney_matches <- matches %>%
              rowwise() %>%
              filter(tournaments_match(tourney_name, bet_tourney_orig, bet_location_orig)) %>%
              ungroup()
            if (nrow(tourney_matches) > 0) {
              # Return best match
              best <- tourney_matches %>%
                slice_min(abs(as.numeric(bet_match_date - tourney_start)), n = 1)
              list(date = best$bet_match_date[1], source = best$bet_row_id[1])
            } else {
              list(date = NA, source = NA)
            }
          } else {
            list(date = NA, source = NA)
          }
        })
      ) %>%
      ungroup() %>%
      mutate(
        actual_match_date = as.Date(map_dbl(bet_match, ~ if(is.na(.x$date)) NA else as.numeric(.x$date)), origin = "1970-01-01"),
        match_source = map_int(bet_match, ~ if(is.na(.x$source)) NA_integer_ else as.integer(.x$source))
      ) %>%
      filter(!is.na(actual_match_date)) %>%
      select(atp_row_id, actual_match_date, match_source)

    if (verbose) cat(sprintf("  Matched: %d (%.1f%% of remaining)\n",
                             nrow(matched_variants),
                             100 * nrow(matched_variants) / length(remaining_ids)))

    # Update remaining
    remaining_ids <- setdiff(remaining_ids, matched_variants$atp_row_id)
  } else {
    matched_variants <- tibble(atp_row_id = integer(),
                               actual_match_date = as.Date(character()),
                               match_source = integer())
  }

  # ---- Strategy 2: Last name match for remaining ----
  if (length(remaining_ids) > 0) {
    if (verbose) cat("\nStrategy 2: Last name + tournament match...\n")

    atp_remaining <- atp_prep %>% filter(atp_row_id %in% remaining_ids)

    matched_lastname <- atp_remaining %>%
      inner_join(
        betting_prep,
        by = c("winner_last" = "bet_winner_last", "loser_last" = "bet_loser_last"),
        relationship = "many-to-many"
      ) %>%
      # Filter to same tournament using improved matching
      rowwise() %>%
      filter(tournaments_match(tourney_name, bet_tourney_orig, bet_location_orig)) %>%
      ungroup() %>%
      # Filter to reasonable date window
      filter(
        bet_match_date >= tourney_start - days(1),
        bet_match_date <= tourney_start + days(21)
      ) %>%
      # Take closest match if multiple
      group_by(atp_row_id) %>%
      slice_min(abs(as.numeric(bet_match_date - tourney_start)), n = 1, with_ties = FALSE) %>%
      ungroup() %>%
      select(atp_row_id, actual_match_date = bet_match_date, match_source = bet_row_id)

    if (verbose) cat(sprintf("  Matched: %d (%.1f%% of remaining)\n",
                             nrow(matched_lastname),
                             100 * nrow(matched_lastname) / length(remaining_ids)))
  } else {
    matched_lastname <- tibble(atp_row_id = integer(),
                               actual_match_date = as.Date(character()),
                               match_source = integer())
  }

  # Combine matches from all strategies
  all_matched <- bind_rows(
    matched_exact %>% mutate(match_method = "exact"),
    matched_variants %>% mutate(match_method = "variant"),
    matched_lastname %>% mutate(match_method = "lastname")
  )

  # ---- Strategy 3: Infer date from round for unmatched ----
  still_remaining <- setdiff(atp_prep$atp_row_id, all_matched$atp_row_id)

  if (length(still_remaining) > 0) {
    if (verbose) cat("\nStrategy 3: Inferring dates from round...\n")

    inferred <- atp_prep %>%
      filter(atp_row_id %in% still_remaining) %>%
      rowwise() %>%
      mutate(
        day_offset = get_round_day_offset(round, draw_size),
        actual_match_date = tourney_start + days(day_offset),
        match_source = NA_integer_,
        match_method = "inferred"
      ) %>%
      ungroup() %>%
      select(atp_row_id, actual_match_date, match_source, match_method)

    if (verbose) cat(sprintf("  Inferred: %d (%.1f%% of total)\n",
                             nrow(inferred), 100 * nrow(inferred) / n_atp))

    all_matched <- bind_rows(all_matched, inferred)
  }

  # ---- Combine with original data ----
  result <- atp_matches %>%
    mutate(atp_row_id = row_number()) %>%
    left_join(all_matched, by = "atp_row_id") %>%
    mutate(
      # Use tourney_date as fallback if still missing
      actual_match_date = coalesce(actual_match_date, ymd(tourney_date)),
      match_method = coalesce(match_method, "fallback")
    ) %>%
    select(-atp_row_id)

  # ---- Summary ----
  if (verbose) {
    cat("\n=== ALIGNMENT SUMMARY ===\n")
    method_counts <- result %>% count(match_method)
    for (i in seq_len(nrow(method_counts))) {
      cat(sprintf("  %s: %d (%.1f%%)\n",
                  method_counts$match_method[i],
                  method_counts$n[i],
                  100 * method_counts$n[i] / n_atp))
    }
    cat(sprintf("\nTotal matches: %d\n", nrow(result)))
    cat(sprintf("With actual dates: %d (%.1f%%)\n",
                sum(result$match_method %in% c("exact", "variant", "lastname")),
                100 * sum(result$match_method %in% c("exact", "variant", "lastname")) / n_atp))
  }

  return(result)
}

# ============================================================================
# VALIDATION
# ============================================================================

#' Validate date alignment by checking for leakage
#' @param aligned_matches Output from align_match_dates
#' @return Tibble with validation results
validate_date_alignment <- function(aligned_matches) {
  # Check for cases where actual_match_date < tourney_date (impossible)
  impossible <- aligned_matches %>%
    mutate(tourney_start = ymd(tourney_date)) %>%
    filter(actual_match_date < tourney_start - days(2))  # Allow 2 day buffer for timezone

  if (nrow(impossible) > 0) {
    warning(sprintf("%d matches have actual_date before tourney_date", nrow(impossible)))
  }

  # Check for cases where later rounds have earlier dates (within tournament)
  round_order <- c("R128" = 1, "R64" = 2, "R32" = 3, "R16" = 4,
                   "QF" = 5, "SF" = 6, "F" = 7, "RR" = 0, "BR" = 7)

  ordering_issues <- aligned_matches %>%
    mutate(round_num = round_order[round]) %>%
    group_by(tourney_id) %>%
    arrange(actual_match_date, round_num) %>%
    mutate(
      prev_round = lag(round_num),
      date_order_ok = is.na(prev_round) | round_num >= prev_round
    ) %>%
    filter(!date_order_ok) %>%
    ungroup()

  if (nrow(ordering_issues) > 0) {
    warning(sprintf("%d matches may have incorrect date ordering within tournament",
                    nrow(ordering_issues)))
  }

  return(list(
    impossible_dates = impossible,
    ordering_issues = ordering_issues,
    is_valid = nrow(impossible) == 0 && nrow(ordering_issues) == 0
  ))
}

# ============================================================================
# INTEGRATION WITH EXISTING PIPELINE
# ============================================================================

#' Load ATP matches with aligned dates
#' This is a drop-in replacement for load_atp_matches that fixes the date issue
#'
#' @param year_from Start year
#' @param year_to End year
#' @param betting_data Pre-loaded betting data (optional, will load if NULL)
#' @param verbose Print progress
#' @return ATP matches with actual_match_date column
load_atp_matches_aligned <- function(year_from = 2015, year_to = NULL,
                                      betting_data = NULL, verbose = TRUE) {
  # Load ATP matches using existing function
  # Source the player stats file to get load_atp_matches
  if (!exists("load_atp_matches")) {
    source("src/data/player_stats.R")
  }

  atp_matches <- load_atp_matches(year_from = year_from, year_to = year_to)

  # Load betting data if not provided
  if (is.null(betting_data)) {
    if (!exists("load_betting_data")) {
      source("src/data/betting_data.R")
    }
    betting_data <- load_betting_data(year_from = year_from, year_to = year_to %||% year(Sys.Date()))
  }

  if (is.null(betting_data)) {
    warning("No betting data available - using inferred dates only")
    # Fall back to round-based inference
    aligned <- atp_matches %>%
      mutate(
        tourney_start = ymd(tourney_date),
        day_offset = map2_dbl(round, draw_size, get_round_day_offset),
        actual_match_date = tourney_start + days(day_offset),
        match_method = "inferred"
      ) %>%
      select(-tourney_start, -day_offset)
    return(aligned)
  }

  # Align dates
  aligned <- align_match_dates(atp_matches, betting_data, verbose = verbose)

  return(aligned)
}

# ============================================================================
# UNIT TESTS
# ============================================================================

test_date_alignment <- function() {
  cat("=== Running Date Alignment Unit Tests ===\n\n")

  # Test 1: Name conversion - standard cases
  cat("Test 1: ATP to betting name conversion (standard)\n")
  stopifnot(atp_to_betting_name("Novak Djokovic") == "Djokovic N.")
  stopifnot(atp_to_betting_name("Carlos Alcaraz") == "Alcaraz C.")
  stopifnot(atp_to_betting_name("Alexander De Minaur") == "De Minaur A.")
  cat("  PASSED\n")

  # Test 2: Name conversion - double first names
  cat("Test 2: ATP to betting name conversion (double first names)\n")
  stopifnot(atp_to_betting_name("Tomas Martin Etcheverry") == "Etcheverry T.")
  stopifnot(atp_to_betting_name("Jan Lennard Struff") == "Struff J.")
  stopifnot(atp_to_betting_name("Pierre Hugues Herbert") == "Herbert P.")
  cat("  PASSED\n")

  # Test 3: Name conversion - double initials
  cat("Test 3: ATP to betting name conversion (double initials)\n")
  stopifnot(atp_to_betting_name("J J Wolf") == "Wolf J.")
  cat("  PASSED\n")

  # Test 4: Name variants for hyphenated names
  cat("Test 4: Name variants generation\n")
  variants_fa <- generate_name_variants("Felix Auger Aliassime")
  stopifnot("Auger-Aliassime F." %in% variants_fa)
  variants_gm <- generate_name_variants("Giovanni Mpetshi Perricard")
  stopifnot("Mpetshi-Perricard G." %in% variants_gm || "Mpetshi Perricard G." %in% variants_gm)
  cat("  PASSED\n")

  # Test 5: Name normalization
  cat("Test 5: Name normalization\n")
  stopifnot(normalize_name("Djokovic N.") == "djokovic n")
  stopifnot(normalize_name("Novak Djokovic") == "novak djokovic")
  cat("  PASSED\n")

  # Test 6: Last name extraction
  cat("Test 6: Last name extraction\n")
  stopifnot(extract_last_name("Djokovic N.") == "Djokovic")
  stopifnot(extract_last_name("Novak Djokovic") == "Djokovic")
  stopifnot(extract_last_name("Alexander De Minaur") == "De Minaur")
  cat("  PASSED\n")

  # Test 7: Tournament normalization
  cat("Test 7: Tournament normalization\n")
  stopifnot(normalize_tournament("Brisbane International") == "brisbane")
  stopifnot(normalize_tournament("Australian Open") == "australian open")
  cat("  PASSED\n")

  # Test 8: Round day offset
  cat("Test 8: Round day offset\n")
  stopifnot(get_round_day_offset("F", 128) == 13)  # Grand Slam final
  stopifnot(get_round_day_offset("R128", 128) == 0)  # Grand Slam R1
  stopifnot(get_round_day_offset("F", 32) == 6)   # ATP 250/500 final
  cat("  PASSED\n")

  cat("\n=== All 8 tests passed ===\n")
}

# Run tests if executed directly
if (sys.nframe() == 0) {
  test_date_alignment()
}
