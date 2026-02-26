# Angelini et al. (2022) Weighted Elo (WElo)
#
# Source: welo R package (CRAN), welofit() in R/functions.R
#
# Update rule (from official source):
#   new_rating = old_rating + K * (Y - expected_prob) * f_g
#   where f_g = winner_games / total_games  (the winner's proportion, for BOTH players)
#
# This SCALES the standard Elo update by games proportion — it does NOT replace
# the binary outcome. The winner always gains rating; the loser always loses rating.
# A dominant winner gains more; a narrow winner gains less.
#
# Our earlier (incorrect) formulation replaced Y with games_prop, which caused
# the winner's rating to DECREASE when they were a strong favorite who barely
# won on games — explaining the degraded Brier score.
#
# Data source: tennis-data.co.uk (same source as the paper).
# Local files available: 2020-2026. Years 2014-2019 can be downloaded from
# tennis-data.co.uk/alldata.php — add to data/raw/tennis_betting/ to extend
# the training history to match the paper's 2014 start date.
#
# Run: Rscript analysis/model_variants/angelini_elo.R

suppressPackageStartupMessages({
  library(tidyverse)
  library(lubridate)
})

source("src/data/tennis_data_loader.R")

# ============================================================================
# CONFIGURATION
# ============================================================================

TOUR        <- "atp"  # "atp" or "wta" — paper treats tours separately
TRAIN_FROM  <- 2014   # paper uses 2014 start (download older files if needed)
TEST_TO     <- 2025   # now covers 2025 via tennis-data.co.uk
DEFAULT_ELO <- 1500
K_DEFAULT   <- 32
K_PROV      <- 48
MIN_PROV    <- 5      # matches before non-provisional
MIN_SURF    <- 10     # surface matches for full surface weight
SURFACES    <- c("Hard", "Clay", "Grass")

# ============================================================================
# ELO STORE (environments = O(1) hash maps, mutable in-place)
# ============================================================================

get_e  <- function(e, p) { v <- e[[p]]; if (is.null(v)) DEFAULT_ELO else v }
get_c  <- function(c, p) { v <- c[[p]]; if (is.null(v)) 0L else v }
get_k  <- function(c, p) { if (get_c(c, p) < MIN_PROV) K_PROV else K_DEFAULT }
incr_c <- function(c, p) { c[[p]] <- get_c(c, p) + 1L }

elo_prob <- function(ea, eb) 1 / (1 + 10^((eb - ea) / 400))

# Blended prediction Elo: weight surface-specific vs overall
blended_elo <- function(ov_e, sf_e, sf_c, player) {
  w <- min(1.0, get_c(sf_c, player) / MIN_SURF)
  w * get_e(sf_e, player) + (1 - w) * get_e(ov_e, player)
}

# ============================================================================
# DATA LOADING
# ============================================================================

cat(sprintf("=== Angelini et al. Weighted Elo [%s] ===\n\n", toupper(TOUR)))

# load_tduk_matches() filters to premium tier by default and returns
# completed + retired matches (walkovers excluded).
# winner_games / loser_games are NA for retired matches.
df <- load_tduk_matches(tour = TOUR, year_from = TRAIN_FROM, year_to = TEST_TO,
                        premium_only = TRUE, verbose = TRUE)

cat(sprintf("\n  Training window: %d-%d\n", TRAIN_FROM, TEST_TO))
cat(sprintf("  Total matches: %d\n", nrow(df)))
cat(sprintf("  Test period (2021+): %d\n", sum(df$year >= 2021)))

# ============================================================================
# SINGLE-PASS WALK-FORWARD
# ============================================================================

cat("\nRunning single-pass walk-forward Elo...\n")

# Separate Elo stores for Standard and Angelini; shared count stores
std_ov <- new.env(hash = TRUE, parent = emptyenv())  # standard overall Elo
ang_ov <- new.env(hash = TRUE, parent = emptyenv())  # Angelini overall Elo
ov_cnt <- new.env(hash = TRUE, parent = emptyenv())  # overall match count

std_sf <- setNames(lapply(SURFACES, \(s) new.env(hash=TRUE, parent=emptyenv())), SURFACES)
ang_sf <- setNames(lapply(SURFACES, \(s) new.env(hash=TRUE, parent=emptyenv())), SURFACES)
sf_cnt <- setNames(lapply(SURFACES, \(s) new.env(hash=TRUE, parent=emptyenv())), SURFACES)

n     <- nrow(df)
preds <- vector("list", n)

for (i in seq_len(n)) {
  r    <- df[i, ]
  w    <- r$winner_name
  l    <- r$loser_name
  surf <- r$surface

  # ------------------------------------------------------------------
  # PRE-MATCH: blended Elos for prediction
  # ------------------------------------------------------------------
  s_ov_w <- blended_elo(std_ov, std_sf[[surf]], sf_cnt[[surf]], w)
  s_ov_l <- blended_elo(std_ov, std_sf[[surf]], sf_cnt[[surf]], l)
  a_ov_w <- blended_elo(ang_ov, ang_sf[[surf]], sf_cnt[[surf]], w)
  a_ov_l <- blended_elo(ang_ov, ang_sf[[surf]], sf_cnt[[surf]], l)

  std_p <- elo_prob(s_ov_w, s_ov_l)  # P(winner wins) under Standard Elo
  ang_p <- elo_prob(a_ov_w, a_ov_l)  # P(winner wins) under Angelini Elo

  # Record prediction if in test window (all loaded matches are premium-tier)
  if (r$year >= 2021) {
    preds[[i]] <- list(
      date    = r$match_date,
      year    = r$year,
      surface = surf,
      winner  = w,
      loser   = l,
      std_p   = std_p,
      ang_p   = ang_p,
      wg      = r$winner_games,
      lg      = r$loser_games,
      ps_w    = r$ps_winner_odds,
      ps_l    = r$ps_loser_odds
    )
  }

  # ------------------------------------------------------------------
  # POST-MATCH: Update ratings
  # ------------------------------------------------------------------

  k_w_ov <- get_k(ov_cnt, w)
  k_l_ov <- get_k(ov_cnt, l)

  # Games proportion (Angelini outcome variable).
  # NA winner_games means retired/incomplete — fall back to binary (1.0).
  wg <- r$winner_games
  lg <- r$loser_games
  total_g    <- if (!is.na(wg) && !is.na(lg)) wg + lg else 0L
  games_prop <- if (total_g > 0) wg / total_g else 1.0

  # --- Overall Elo update ---

  s_raw_w   <- get_e(std_ov, w)
  s_raw_l   <- get_e(std_ov, l)
  s_exp_ov  <- elo_prob(s_raw_w, s_raw_l)
  std_delta <- 1 - s_exp_ov
  std_ov[[w]] <- s_raw_w + k_w_ov * std_delta
  std_ov[[l]] <- s_raw_l - k_l_ov * std_delta

  a_raw_w   <- get_e(ang_ov, w)
  a_raw_l   <- get_e(ang_ov, l)
  a_exp_ov  <- elo_prob(a_raw_w, a_raw_l)
  # Scale standard update by winner's games proportion (paper's f_g, same for both players)
  ang_delta <- (1 - a_exp_ov) * games_prop
  ang_ov[[w]] <- a_raw_w + k_w_ov * ang_delta
  ang_ov[[l]] <- a_raw_l - k_l_ov * ang_delta

  incr_c(ov_cnt, w)
  incr_c(ov_cnt, l)

  # --- Surface Elo update ---
  k_w_sf <- get_k(sf_cnt[[surf]], w)
  k_l_sf <- get_k(sf_cnt[[surf]], l)

  s_sf_w   <- get_e(std_sf[[surf]], w)
  s_sf_l   <- get_e(std_sf[[surf]], l)
  s_exp_sf <- elo_prob(s_sf_w, s_sf_l)
  std_sf_d <- 1 - s_exp_sf
  std_sf[[surf]][[w]] <- s_sf_w + k_w_sf * std_sf_d
  std_sf[[surf]][[l]] <- s_sf_l - k_l_sf * std_sf_d

  a_sf_w   <- get_e(ang_sf[[surf]], w)
  a_sf_l   <- get_e(ang_sf[[surf]], l)
  a_exp_sf <- elo_prob(a_sf_w, a_sf_l)
  ang_sf_d <- (1 - a_exp_sf) * games_prop
  ang_sf[[surf]][[w]] <- a_sf_w + k_w_sf * ang_sf_d
  ang_sf[[surf]][[l]] <- a_sf_l - k_l_sf * ang_sf_d

  incr_c(sf_cnt[[surf]], w)
  incr_c(sf_cnt[[surf]], l)

  if (i %% 5000 == 0) {
    cat(sprintf("  %d / %d (%.0f%%)...\n", i, n, 100 * i / n))
  }
}

cat("  Done.\n\n")

# ============================================================================
# EVALUATION
# ============================================================================

results <- bind_rows(lapply(preds[!sapply(preds, is.null)], as_tibble))
cat(sprintf("Predictions recorded (2021+, premium tier): %d\n\n", nrow(results)))

brier    <- function(prob) mean((prob - 1)^2)  # from winner's perspective
accuracy <- function(prob) mean(prob > 0.5)

eval_period <- function(d, label) {
  if (nrow(d) == 0) return(invisible(NULL))
  cat(sprintf("%-32s  N=%5d  Std: %.1f%%  Ang: %.1f%%  BS_std: %.4f  BS_ang: %.4f\n",
              label, nrow(d),
              100 * accuracy(d$std_p), 100 * accuracy(d$ang_p),
              brier(d$std_p), brier(d$ang_p)))
}

cat("=== Accuracy: premium-tier ATP matches ===\n")
cat(sprintf("%-32s  %6s  %10s  %10s  %10s  %10s\n",
            "Period", "N", "Std Acc", "Ang Acc", "BS_Std", "BS_Ang"))
cat(strrep("-", 82), "\n")

eval_period(results, "2021-2025 (all available)")
for (yr in sort(unique(results$year))) {
  eval_period(results %>% filter(year == yr), sprintf("  %d", yr))
}
eval_period(results %>% filter(year >= 2023), "2023-2025 (paper-comparable)")

cat("\n=== Paper baselines (test: Jan 2023 - Jun 2025) ===\n")
cat("  Standard Elo:          65.7%  Brier 0.215\n")
cat("  Angelini Weighted Elo: 65.8%  Brier 0.215\n")
cat("  MagNet GNN:            65.7%  Brier 0.215\n")
cat("  Pinnacle odds:         69.0%  Brier 0.196\n")
cat(sprintf("\n  Local training from %d; paper trains from 2014.\n", TRAIN_FROM))

# ============================================================================
# BY SURFACE
# ============================================================================

cat("\n=== Accuracy by surface (2021+, premium tier) ===\n")
cat(sprintf("%-10s  %6s  %10s  %10s  %10s  %10s\n", "Surface", "N", "Std Acc", "Ang Acc", "BS_Std", "BS_Ang"))
cat(strrep("-", 62), "\n")
for (s in SURFACES) {
  d <- results %>% filter(surface == s)
  if (nrow(d) > 0)
    cat(sprintf("%-10s  %6d  %9.1f%%  %9.1f%%  %10.4f  %10.4f\n",
                s, nrow(d), 100 * accuracy(d$std_p), 100 * accuracy(d$ang_p),
                brier(d$std_p), brier(d$ang_p)))
}

# ============================================================================
# SAVE
# ============================================================================

saveRDS(results, "data/processed/angelini_elo_results.rds")
cat(sprintf("\nResults saved to data/processed/angelini_elo_results.rds\n"))
