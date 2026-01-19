# Build Tennis Player Features
# Loads charting data, processes it, and creates normalized feature matrix
# Output: data/processed/charting_only_features_normalized.csv

library(tidyverse)
library(lubridate)

# ============================================================================
# 1. LOAD DATA
# ============================================================================

cat("Loading data...\n")

# Load ATP data (for height, birth year, ranking, career stats)
atp_files <- list.files("data/raw/tennis_atp", pattern = "atp_matches_\\d{4}\\.csv", full.names = TRUE)
atp_matches <- map_dfr(atp_files, ~read_csv(.x, show_col_types = FALSE))
cat(sprintf("  ATP matches: %s\n", format(nrow(atp_matches), big.mark = ",")))

# Load player info
atp_players <- read_csv("data/raw/tennis_atp/atp_players.csv", show_col_types = FALSE)
cat(sprintf("  ATP players: %s\n", format(nrow(atp_players), big.mark = ",")))

# Load charting stats files (derived from shot-by-shot data)
cat("\nLoading charting stats...\n")

charting_overview <- read_csv("data/raw/tennis_charting/charting-m-stats-Overview.csv", show_col_types = FALSE)
cat(sprintf("  Overview stats: %s rows\n", format(nrow(charting_overview), big.mark = ",")))

charting_net <- read_csv("data/raw/tennis_charting/charting-m-stats-NetPoints.csv", show_col_types = FALSE)
cat(sprintf("  Net points stats: %s rows\n", format(nrow(charting_net), big.mark = ",")))

charting_snv <- read_csv("data/raw/tennis_charting/charting-m-stats-SnV.csv", show_col_types = FALSE)
cat(sprintf("  Serve & volley stats: %s rows\n", format(nrow(charting_snv), big.mark = ",")))

charting_rally <- read_csv("data/raw/tennis_charting/charting-m-stats-Rally.csv", show_col_types = FALSE)
cat(sprintf("  Rally stats: %s rows\n", format(nrow(charting_rally), big.mark = ",")))

charting_shot_types <- read_csv("data/raw/tennis_charting/charting-m-stats-ShotTypes.csv", show_col_types = FALSE)
cat(sprintf("  Shot types stats: %s rows\n", format(nrow(charting_shot_types), big.mark = ",")))

charting_shot_dir <- read_csv("data/raw/tennis_charting/charting-m-stats-ShotDirection.csv", show_col_types = FALSE)
cat(sprintf("  Shot direction stats: %s rows\n", format(nrow(charting_shot_dir), big.mark = ",")))

charting_return_depth <- read_csv("data/raw/tennis_charting/charting-m-stats-ReturnDepth.csv", show_col_types = FALSE)
cat(sprintf("  Return depth stats: %s rows\n", format(nrow(charting_return_depth), big.mark = ",")))

charting_return_outcomes <- read_csv("data/raw/tennis_charting/charting-m-stats-ReturnOutcomes.csv", show_col_types = FALSE)
cat(sprintf("  Return outcomes stats: %s rows\n", format(nrow(charting_return_outcomes), big.mark = ",")))

charting_keypoints_return <- read_csv("data/raw/tennis_charting/charting-m-stats-KeyPointsReturn.csv", show_col_types = FALSE)
cat(sprintf("  Key points return stats: %s rows\n", format(nrow(charting_keypoints_return), big.mark = ",")))

charting_keypoints_serve <- read_csv("data/raw/tennis_charting/charting-m-stats-KeyPointsServe.csv", show_col_types = FALSE)
cat(sprintf("  Key points serve stats: %s rows\n", format(nrow(charting_keypoints_serve), big.mark = ",")))

charting_matches <- read_csv("data/raw/tennis_charting/charting-m-matches.csv", show_col_types = FALSE)
cat(sprintf("  Charting matches: %s\n", format(nrow(charting_matches), big.mark = ",")))

# ============================================================================
# 2. BUILD PLAYER INFO LOOKUP (from ATP data)
# ============================================================================

cat("\nBuilding player info lookup...\n")

# Parse dates and extract year
atp_matches <- atp_matches %>%
  mutate(
    match_date = ymd(tourney_date),
    match_year = year(match_date)
  )

# Get player birth years and height from player file
player_info <- atp_players %>%
  mutate(
    birth_date = ymd(dob),
    birth_year = year(birth_date)
  ) %>%
  select(player_id, name_first, name_last, hand, height, birth_year) %>%
  mutate(full_name = paste(name_first, name_last))

# Create lookup from player name to birth_year/height
# Use ATP match data to get consistent name formatting
winner_info <- atp_matches %>%
  select(player_name = winner_name, player_id = winner_id) %>%
  distinct()

loser_info <- atp_matches %>%
  select(player_name = loser_name, player_id = loser_id) %>%
  distinct()

name_to_id <- bind_rows(winner_info, loser_info) %>%
  distinct(player_name, .keep_all = TRUE)

name_lookup <- name_to_id %>%
  left_join(player_info %>% select(player_id, birth_year, height, hand), by = "player_id") %>%
  filter(!is.na(birth_year))

cat(sprintf("  Player name lookup: %s players\n", format(nrow(name_lookup), big.mark = ",")))

# Calculate first year on tour and career stats for each player
all_records <- bind_rows(
  atp_matches %>% select(player_id = winner_id, player_name = winner_name, match_year, rank = winner_rank) %>% mutate(won = 1),
  atp_matches %>% select(player_id = loser_id, player_name = loser_name, match_year, rank = loser_rank) %>% mutate(won = 0)
)

first_year_on_tour <- all_records %>%
  group_by(player_name) %>%
  summarize(first_tour_year = min(match_year), .groups = "drop")

# Career stats by player/year (cumulative)
career_by_year <- all_records %>%
  arrange(player_name, match_year) %>%
  group_by(player_name) %>%
  mutate(
    career_matches_cum = cumsum(rep(1, n())),
    career_wins_cum = cumsum(won)
  ) %>%
  group_by(player_name, match_year) %>%
  summarize(
    season_matches = n(),
    career_matches = max(career_matches_cum),
    career_wins = max(career_wins_cum),
    avg_ranking = mean(rank, na.rm = TRUE),
    .groups = "drop"
  )

# ============================================================================
# 3. PROCESS CHARTING DATA
# ============================================================================

cat("\nProcessing charting data...\n")

# Extract year from match_id and deduplicate
charting_matches <- charting_matches %>%
  mutate(
    match_year = as.integer(substr(match_id, 1, 4)),
    surface = Surface
  ) %>%
  select(match_id, match_year, surface, `Player 1`, `Player 2`) %>%
  distinct(match_id, .keep_all = TRUE)

# Process overview stats - filter to match totals and aggregate duplicates
charting_overview_totals <- charting_overview %>%
  filter(set == "Total") %>%
  group_by(match_id, player) %>%
  summarize(
    serve_pts = sum(serve_pts, na.rm = TRUE),
    aces = sum(aces, na.rm = TRUE),
    dfs = sum(dfs, na.rm = TRUE),
    first_in = sum(first_in, na.rm = TRUE),
    first_won = sum(first_won, na.rm = TRUE),
    second_won = sum(second_won, na.rm = TRUE),
    winners = sum(winners, na.rm = TRUE),
    winners_fh = sum(winners_fh, na.rm = TRUE),
    winners_bh = sum(winners_bh, na.rm = TRUE),
    unforced = sum(unforced, na.rm = TRUE),
    unforced_fh = sum(unforced_fh, na.rm = TRUE),
    unforced_bh = sum(unforced_bh, na.rm = TRUE),
    return_pts = sum(return_pts, na.rm = TRUE),
    return_pts_won = sum(return_pts_won, na.rm = TRUE),
    .groups = "drop"
  )

# Process net points - get NetPoints and Approach rows, aggregate duplicates
charting_net_totals <- charting_net %>%
  filter(row == "NetPoints") %>%
  group_by(match_id, player) %>%
  summarize(
    net_pts = sum(net_pts, na.rm = TRUE),
    net_pts_won = sum(pts_won, na.rm = TRUE),
    net_winner = sum(net_winner, na.rm = TRUE),
    induced_forced = sum(induced_forced, na.rm = TRUE),
    net_unforced = sum(net_unforced, na.rm = TRUE),
    passed_at_net = sum(passed_at_net, na.rm = TRUE),
    total_shots = sum(total_shots, na.rm = TRUE),
    .groups = "drop"
  )

charting_approach_totals <- charting_net %>%
  filter(row == "Approach") %>%
  group_by(match_id, player) %>%
  summarize(
    approach_pts = sum(net_pts, na.rm = TRUE),
    approach_won = sum(pts_won, na.rm = TRUE),
    approach_winner = sum(net_winner, na.rm = TRUE),
    approach_forced = sum(induced_forced, na.rm = TRUE),
    approach_unforced = sum(net_unforced, na.rm = TRUE),
    approach_passed = sum(passed_at_net, na.rm = TRUE),
    .groups = "drop"
  )

# Process serve & volley stats - aggregate duplicates
charting_snv_totals <- charting_snv %>%
  filter(row == "SnV") %>%
  group_by(match_id, player) %>%
  summarize(
    snv_pts = sum(snv_pts, na.rm = TRUE),
    snv_won = sum(pts_won, na.rm = TRUE),
    snv_aces = sum(aces, na.rm = TRUE),
    snv_winner = sum(net_winner, na.rm = TRUE),
    snv_forced = sum(induced_forced, na.rm = TRUE),
    snv_unforced = sum(net_unforced, na.rm = TRUE),
    snv_passed = sum(passed_at_net, na.rm = TRUE),
    .groups = "drop"
  )

# Process rally length stats - reshape from server/returner to per-player
# Rally data has pl1 (server) and pl2 (returner) stats per row
rally_server <- charting_rally %>%
  filter(row %in% c("1-3", "4-6", "7-9", "10")) %>%
  select(match_id, player = server, row, pts, won = pl1_won,
         winners = pl1_winners, forced = pl1_forced, unforced = pl1_unforced)

rally_returner <- charting_rally %>%
  filter(row %in% c("1-3", "4-6", "7-9", "10")) %>%
  select(match_id, player = returner, row, pts, won = pl2_won,
         winners = pl2_winners, forced = pl2_forced, unforced = pl2_unforced)

# Combine and aggregate by match/player/rally_length
charting_rally_combined <- bind_rows(rally_server, rally_returner) %>%
  group_by(match_id, player, row) %>%
  summarize(
    pts = sum(pts, na.rm = TRUE),
    won = sum(won, na.rm = TRUE),
    winners = sum(winners, na.rm = TRUE),
    forced = sum(forced, na.rm = TRUE),
    unforced = sum(unforced, na.rm = TRUE),
    .groups = "drop"
  )

# Pivot to wide format - one row per match/player with columns for each rally length
charting_rally_totals <- charting_rally_combined %>%
  pivot_wider(
    id_cols = c(match_id, player),
    names_from = row,
    values_from = c(pts, won, winners, forced, unforced),
    values_fill = 0
  ) %>%
  # Rename columns to be cleaner
  rename(
    rally_short_pts = `pts_1-3`,
    rally_short_won = `won_1-3`,
    rally_med_pts = `pts_4-6`,
    rally_med_won = `won_4-6`,
    rally_medlong_pts = `pts_7-9`,
    rally_medlong_won = `won_7-9`,
    rally_long_pts = `pts_10`,
    rally_long_won = `won_10`
  ) %>%
  # Calculate total rally points for distribution
  mutate(
    rally_total_pts = rally_short_pts + rally_med_pts + rally_medlong_pts + rally_long_pts
  ) %>%
  select(match_id, player, starts_with("rally_"))

# Process shot types - extract key shot type counts
# First aggregate any duplicates, then pivot
charting_shot_types_agg <- charting_shot_types %>%
  filter(row %in% c("Total", "Fgs", "Bgs", "Dr", "Sl", "Lo")) %>%
  group_by(match_id, player, row) %>%
  summarize(shots = sum(shots, na.rm = TRUE), .groups = "drop")

charting_shot_types_totals <- charting_shot_types_agg %>%
  pivot_wider(
    id_cols = c(match_id, player),
    names_from = row,
    values_from = shots,
    values_fill = 0
  ) %>%
  rename(
    total_shots_all = Total,
    fh_groundstrokes = Fgs,
    bh_groundstrokes = Bgs,
    dropshots = Dr,
    slices = Sl,
    lobs = Lo
  )

# Process shot direction - extract direction patterns
# First aggregate any duplicates, then pivot
charting_shot_dir_agg <- charting_shot_dir %>%
  filter(row %in% c("Total", "F", "B")) %>%
  group_by(match_id, player, row) %>%
  summarize(
    crosscourt = sum(crosscourt, na.rm = TRUE),
    down_the_line = sum(down_the_line, na.rm = TRUE),
    inside_out = sum(inside_out, na.rm = TRUE),
    inside_in = sum(inside_in, na.rm = TRUE),
    .groups = "drop"
  )

charting_shot_dir_totals <- charting_shot_dir_agg %>%
  pivot_wider(
    id_cols = c(match_id, player),
    names_from = row,
    values_from = c(crosscourt, down_the_line, inside_out, inside_in),
    values_fill = 0
  ) %>%
  rename(
    total_crosscourt = crosscourt_Total,
    total_dtl = down_the_line_Total,
    fh_crosscourt = crosscourt_F,
    fh_dtl = down_the_line_F,
    fh_inside_out = inside_out_F,
    fh_inside_in = inside_in_F,
    bh_crosscourt = crosscourt_B,
    bh_dtl = down_the_line_B
  )

# Process return depth - aggregate by player/match
charting_return_depth_totals <- charting_return_depth %>%
  filter(row == "Total") %>%
  group_by(match_id, player) %>%
  summarize(
    return_returnable = sum(returnable, na.rm = TRUE),
    return_shallow = sum(shallow, na.rm = TRUE),
    return_deep = sum(deep, na.rm = TRUE),
    return_very_deep = sum(very_deep, na.rm = TRUE),
    .groups = "drop"
  )

# Process return outcomes - aggregate by player/match
charting_return_outcomes_totals <- charting_return_outcomes %>%
  filter(row == "Total") %>%
  group_by(match_id, player) %>%
  summarize(
    return_outcomes_in_play = sum(in_play, na.rm = TRUE),
    return_outcomes_winners = sum(winners, na.rm = TRUE),
    .groups = "drop"
  )

# Process key points - break point opportunities (returning)
charting_bp_return <- charting_keypoints_return %>%
  filter(row == "BPO") %>%
  group_by(match_id, player) %>%
  summarize(
    bp_opportunities = sum(pts, na.rm = TRUE),
    bp_converted = sum(pts_won, na.rm = TRUE),
    .groups = "drop"
  )

# Process key points - break points faced (serving)
charting_bp_serve <- charting_keypoints_serve %>%
  filter(row == "BP") %>%
  group_by(match_id, player) %>%
  summarize(
    bp_faced = sum(pts, na.rm = TRUE),
    bp_saved = sum(pts_won, na.rm = TRUE),
    .groups = "drop"
  )

# Join charting stats with match info
charting_player_match <- charting_overview_totals %>%
  left_join(charting_matches, by = "match_id") %>%
  left_join(charting_net_totals, by = c("match_id", "player")) %>%
  left_join(charting_approach_totals, by = c("match_id", "player")) %>%
  left_join(charting_snv_totals, by = c("match_id", "player")) %>%
  left_join(charting_rally_totals, by = c("match_id", "player")) %>%
  left_join(charting_shot_types_totals, by = c("match_id", "player")) %>%
  left_join(charting_shot_dir_totals, by = c("match_id", "player")) %>%
  left_join(charting_return_depth_totals, by = c("match_id", "player")) %>%
  left_join(charting_return_outcomes_totals, by = c("match_id", "player")) %>%
  left_join(charting_bp_return, by = c("match_id", "player")) %>%
  left_join(charting_bp_serve, by = c("match_id", "player"))

# Aggregate by player/year
charting_player_year <- charting_player_match %>%
  filter(!is.na(match_year)) %>%
  group_by(player, match_year) %>%
  summarize(
    charting_matches = n(),

    # Serve stats (from charting)
    total_serve_pts = sum(serve_pts, na.rm = TRUE),
    total_aces = sum(aces, na.rm = TRUE),
    total_dfs = sum(dfs, na.rm = TRUE),
    total_first_in = sum(first_in, na.rm = TRUE),
    total_first_won = sum(first_won, na.rm = TRUE),
    total_second_won = sum(second_won, na.rm = TRUE),

    # Return stats (from charting)
    total_return_pts = sum(return_pts, na.rm = TRUE),
    total_return_won = sum(return_pts_won, na.rm = TRUE),

    # Winners and errors
    total_winners = sum(winners, na.rm = TRUE),
    total_winners_fh = sum(winners_fh, na.rm = TRUE),
    total_winners_bh = sum(winners_bh, na.rm = TRUE),
    total_unforced = sum(unforced, na.rm = TRUE),
    total_unforced_fh = sum(unforced_fh, na.rm = TRUE),
    total_unforced_bh = sum(unforced_bh, na.rm = TRUE),

    # Net play - overall
    total_net_pts = sum(net_pts, na.rm = TRUE),
    total_net_won = sum(net_pts_won, na.rm = TRUE),
    total_net_winner = sum(net_winner, na.rm = TRUE),
    total_net_forced = sum(induced_forced, na.rm = TRUE),
    total_net_unforced = sum(net_unforced, na.rm = TRUE),
    total_passed_at_net = sum(passed_at_net, na.rm = TRUE),
    total_shots = sum(total_shots, na.rm = TRUE),

    # Net play - approach shots (mid-rally)
    total_approach_pts = sum(approach_pts, na.rm = TRUE),
    total_approach_won = sum(approach_won, na.rm = TRUE),
    total_approach_winner = sum(approach_winner, na.rm = TRUE),
    total_approach_forced = sum(approach_forced, na.rm = TRUE),
    total_approach_passed = sum(approach_passed, na.rm = TRUE),

    # Net play - serve & volley
    total_snv_pts = sum(snv_pts, na.rm = TRUE),
    total_snv_won = sum(snv_won, na.rm = TRUE),
    total_snv_winner = sum(snv_winner, na.rm = TRUE),
    total_snv_forced = sum(snv_forced, na.rm = TRUE),
    total_snv_passed = sum(snv_passed, na.rm = TRUE),

    # Rally length stats
    total_rally_short_pts = sum(rally_short_pts, na.rm = TRUE),
    total_rally_short_won = sum(rally_short_won, na.rm = TRUE),
    total_rally_med_pts = sum(rally_med_pts, na.rm = TRUE),
    total_rally_med_won = sum(rally_med_won, na.rm = TRUE),
    total_rally_medlong_pts = sum(rally_medlong_pts, na.rm = TRUE),
    total_rally_medlong_won = sum(rally_medlong_won, na.rm = TRUE),
    total_rally_long_pts = sum(rally_long_pts, na.rm = TRUE),
    total_rally_long_won = sum(rally_long_won, na.rm = TRUE),
    total_rally_pts = sum(rally_total_pts, na.rm = TRUE),

    # Shot types
    total_shots_all = sum(total_shots_all, na.rm = TRUE),
    total_fh_groundstrokes = sum(fh_groundstrokes, na.rm = TRUE),
    total_bh_groundstrokes = sum(bh_groundstrokes, na.rm = TRUE),
    total_dropshots = sum(dropshots, na.rm = TRUE),
    total_slices = sum(slices, na.rm = TRUE),
    total_lobs = sum(lobs, na.rm = TRUE),

    # Shot direction
    total_crosscourt = sum(total_crosscourt, na.rm = TRUE),
    total_dtl = sum(total_dtl, na.rm = TRUE),
    total_fh_crosscourt = sum(fh_crosscourt, na.rm = TRUE),
    total_fh_dtl = sum(fh_dtl, na.rm = TRUE),
    total_fh_inside_out = sum(fh_inside_out, na.rm = TRUE),
    total_fh_inside_in = sum(fh_inside_in, na.rm = TRUE),
    total_bh_crosscourt = sum(bh_crosscourt, na.rm = TRUE),
    total_bh_dtl = sum(bh_dtl, na.rm = TRUE),

    # Return depth
    total_return_returnable = sum(return_returnable, na.rm = TRUE),
    total_return_shallow = sum(return_shallow, na.rm = TRUE),
    total_return_deep = sum(return_deep, na.rm = TRUE),
    total_return_very_deep = sum(return_very_deep, na.rm = TRUE),

    # Return outcomes
    total_return_in_play = sum(return_outcomes_in_play, na.rm = TRUE),
    total_return_winners = sum(return_outcomes_winners, na.rm = TRUE),

    # Break points
    total_bp_opportunities = sum(bp_opportunities, na.rm = TRUE),
    total_bp_converted = sum(bp_converted, na.rm = TRUE),
    total_bp_faced = sum(bp_faced, na.rm = TRUE),
    total_bp_saved = sum(bp_saved, na.rm = TRUE),

    .groups = "drop"
  )

cat(sprintf("  Charting player/year combinations: %s\n", format(nrow(charting_player_year), big.mark = ",")))

# ============================================================================
# 4. BUILD CHARTING-ONLY FEATURE MATRIX
# ============================================================================

cat("\nBuilding charting-only feature matrix...\n")

# Add player info (birth_year, height) to calculate age
charting_features <- charting_player_year %>%
  left_join(name_lookup %>% select(player_name, birth_year, height, hand),
            by = c("player" = "player_name")) %>%
  mutate(age = match_year - birth_year) %>%
  filter(!is.na(age), age >= 17, age <= 42)

# Add career context from ATP data
charting_features <- charting_features %>%
  left_join(first_year_on_tour, by = c("player" = "player_name")) %>%
  mutate(years_on_tour = match_year - first_tour_year) %>%
  left_join(career_by_year %>% select(player_name, match_year, career_matches, avg_ranking),
            by = c("player" = "player_name", "match_year"))

# Carry forward most recent career stats for players with missing data (e.g., 2025)
# Get the most recent career stats for each player
most_recent_career <- career_by_year %>%
  group_by(player_name) %>%
  filter(match_year == max(match_year)) %>%
  ungroup() %>%
  select(player_name, latest_career_matches = career_matches, latest_avg_ranking = avg_ranking)

charting_features <- charting_features %>%
  left_join(most_recent_career, by = c("player" = "player_name")) %>%
  mutate(
    career_matches = coalesce(career_matches, latest_career_matches),
    avg_ranking = coalesce(avg_ranking, latest_avg_ranking)
  ) %>%
  select(-latest_career_matches, -latest_avg_ranking)

cat(sprintf("  Filled missing career stats: %d rows\n",
            sum(!is.na(charting_features$career_matches))))

# Calculate all features from charting data
charting_features <- charting_features %>%
  mutate(
    # Serve stats (from charting)
    serve_pct = (total_first_won + total_second_won) / total_serve_pts,
    first_in_pct = total_first_in / total_serve_pts,
    first_won_pct = total_first_won / total_first_in,
    ace_pct = total_aces / total_serve_pts,
    df_pct = total_dfs / total_serve_pts,

    # Return stats (from charting)
    return_pct = total_return_won / total_return_pts,

    # Play style - winners vs errors
    winner_pct = total_winners / (total_winners + total_unforced),
    fh_winner_ratio = total_winners_fh / (total_winners_fh + total_winners_bh + 0.1),
    fh_ue_ratio = total_unforced_fh / (total_unforced_fh + total_unforced_bh + 0.1),

    # Net play style - overall
    net_approach_rate = total_net_pts / (total_serve_pts + total_return_pts),
    net_win_pct = total_net_won / (total_net_pts + 0.1),
    net_winner_pct = total_net_winner / (total_net_pts + 0.1),
    net_forced_error_pct = total_net_forced / (total_net_pts + 0.1),
    passed_at_net_pct = total_passed_at_net / (total_net_pts + 0.1),

    # Net play - serve & volley (coming to net after serve)
    snv_rate = total_snv_pts / (total_serve_pts + 0.1),
    snv_success_pct = total_snv_won / (total_snv_pts + 0.1),
    snv_winner_pct = total_snv_winner / (total_snv_pts + 0.1),

    # Net play - approach shots (coming to net mid-rally)
    approach_rate = total_approach_pts / (total_serve_pts + total_return_pts + 0.1),
    approach_success_pct = total_approach_won / (total_approach_pts + 0.1),
    approach_winner_pct = total_approach_winner / (total_approach_pts + 0.1),

    # Aggression metrics
    winners_per_shot = total_winners / (total_shots + 0.1),
    ue_per_shot = total_unforced / (total_shots + 0.1),

    # Rally length - point distribution (what % of points fall in each bucket)
    rally_short_pct = total_rally_short_pts / (total_rally_pts + 0.1),
    rally_med_pct = total_rally_med_pts / (total_rally_pts + 0.1),
    rally_medlong_pct = total_rally_medlong_pts / (total_rally_pts + 0.1),
    rally_long_pct = total_rally_long_pts / (total_rally_pts + 0.1),

    # Rally length - win rates at each length
    rally_short_win_pct = total_rally_short_won / (total_rally_short_pts + 0.1),
    rally_med_win_pct = total_rally_med_won / (total_rally_med_pts + 0.1),
    rally_medlong_win_pct = total_rally_medlong_won / (total_rally_medlong_pts + 0.1),
    rally_long_win_pct = total_rally_long_won / (total_rally_long_pts + 0.1),

    # Groundstroke patterns - shot selection
    fh_groundstroke_pct = total_fh_groundstrokes / (total_fh_groundstrokes + total_bh_groundstrokes + 0.1),
    dropshot_rate = total_dropshots / (total_shots_all + 0.1),
    slice_rate = total_slices / (total_shots_all + 0.1),
    lob_rate = total_lobs / (total_shots_all + 0.1),

    # Groundstroke patterns - direction tendencies
    fh_inside_out_rate = (total_fh_inside_out + total_fh_inside_in) / (total_fh_crosscourt + total_fh_dtl + total_fh_inside_out + total_fh_inside_in + 0.1),
    fh_dtl_rate = total_fh_dtl / (total_fh_crosscourt + total_fh_dtl + 0.1),
    bh_dtl_rate = total_bh_dtl / (total_bh_crosscourt + total_bh_dtl + 0.1),
    overall_dtl_rate = total_dtl / (total_crosscourt + total_dtl + 0.1),

    # Court position / aggression - return depth
    deep_return_pct = (total_return_deep + total_return_very_deep) / (total_return_returnable + 0.1),
    very_deep_return_pct = total_return_very_deep / (total_return_returnable + 0.1),
    shallow_return_pct = total_return_shallow / (total_return_returnable + 0.1),

    # Court position / aggression - return outcomes
    return_winner_rate = total_return_winners / (total_return_returnable + 0.1),
    return_in_play_rate = total_return_in_play / (total_return_returnable + 0.1),

    # Pressure performance - break points
    bp_conversion_rate = total_bp_converted / (total_bp_opportunities + 0.1),
    bp_save_rate = total_bp_saved / (total_bp_faced + 0.1)
  )

# Filter: minimum charted matches threshold
min_charted_matches <- 3
charting_features <- charting_features %>%
  filter(charting_matches >= min_charted_matches)

cat(sprintf("  With %d+ charted matches: %s player/ages\n",
            min_charted_matches, format(nrow(charting_features), big.mark = ",")))
cat(sprintf("  Unique players: %s\n", format(n_distinct(charting_features$player), big.mark = ",")))

# ============================================================================
# 5. PREPARE NORMALIZED FEATURE MATRIX
# ============================================================================

cat("\nPreparing normalized feature matrix...\n")

source("r_analysis/utils.R")

# Create feature matrix with raw values
feature_matrix <- charting_features %>%
  select(player, age, match_year, charting_matches, height, hand,
         all_of(intersect(ALL_FEATURES, names(charting_features)))) %>%
  rename(player_name = player) %>%
  # Remove rows with NAs in critical features
  filter(!is.na(serve_pct), !is.na(return_pct), !is.na(winner_pct))

cat(sprintf("  Feature matrix rows: %s\n", format(nrow(feature_matrix), big.mark = ",")))

# Z-score normalize features
available_features <- intersect(ALL_FEATURES, names(feature_matrix))
feature_matrix_norm <- normalize_features(feature_matrix, available_features)

cat(sprintf("  Features used: %d\n", length(available_features)))

# ============================================================================
# 6. SAVE OUTPUTS
# ============================================================================

cat("\nSaving outputs...\n")

write_csv(feature_matrix, "data/processed/charting_only_features.csv")
write_csv(feature_matrix_norm, "data/processed/charting_only_features_normalized.csv")

cat("Saved:\n")
cat("  - data/processed/charting_only_features.csv\n")
cat("  - data/processed/charting_only_features_normalized.csv\n")

cat(sprintf("\nSummary:\n"))
cat(sprintf("  Player/age combinations: %s\n", format(nrow(feature_matrix), big.mark = ",")))
cat(sprintf("  Unique players: %s\n", format(n_distinct(feature_matrix$player_name), big.mark = ",")))
cat(sprintf("  Features: %d\n", length(available_features)))

cat("\nDone!\n")
