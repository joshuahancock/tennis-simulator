# welo Package Comparison
#
# Runs the official welo CRAN package (welofit()) on our ATP/WTA data and
# compares against our custom angelini_elo.R implementation.
#
# Purpose: isolate the source of the ~0.7pp accuracy gap vs paper baselines.
#
# Key structural differences between the package and our custom code:
#
#   1. Surface ratings: package uses ONE overall Elo per player; our code
#      maintains separate surface Elo stores with blending. If the gap closes
#      when using the package, surface blending is hurting, not helping.
#
#   2. Loser update formula:
#        Package: loser loses K * (1-p) * f_g_j  [f_g_j = loser's games proportion]
#        Ours:    loser loses K * (1-p) * f_g_i  [f_g_i = winner's games proportion]
#      Example (dominant 6-1 6-1 win, f_g_i=0.83, f_g_j=0.17):
#        Package loser: small loss (-0.17 scale)
#        Our loser:     big loss   (-0.83 scale, same as winner's gain)
#      The paper's approach: loser loss is proportional to games they won.
#
# Runtime note: welofit() is O(n²) — scans all prior rows per match.
# Expect ~10-30 minutes for 15k+ matches.
#
# Run: Rscript analysis/model_variants/welo_package_comparison.R

suppressPackageStartupMessages({
  library(tidyverse)
  library(lubridate)
})

source("src/data/tennis_data_loader.R")

# ============================================================================
# INSTALL welo IF NEEDED
# ============================================================================

if (!requireNamespace("welo", quietly = TRUE)) {
  message("Installing welo from CRAN...")
  install.packages("welo", repos = "https://cloud.r-project.org", quiet = TRUE)
}

# ============================================================================
# CONFIGURATION
# ============================================================================

TOUR       <- "atp"   # "atp" or "wta"
TRAIN_FROM <- 2014
TEST_TO    <- 2025
TEST_FROM  <- 2023    # evaluate on 2023+ to match paper test window

# ============================================================================
# LOAD DATA
# ============================================================================

cat(sprintf("=== welo Package Comparison [%s] ===\n\n", toupper(TOUR)))

df <- load_tduk_matches(tour = TOUR, year_from = TRAIN_FROM, year_to = TEST_TO,
                        premium_only = TRUE, verbose = TRUE)

cat(sprintf("\n  Total matches: %d  |  Test (>=%d): %d\n\n",
            nrow(df), TEST_FROM, sum(df$year >= TEST_FROM)))

# ============================================================================
# PREPARE welofit() INPUT FORMAT
#
# Required columns: P_i, P_j, Y_i, Y_j, NG_i, NG_j, NS_i, NS_j,
#                   f_g_i, f_g_j, Series, Surface
#
# P_i = winner (Y_i = 1), P_j = loser (Y_j = 0)
# f_g_i = winner_games / total  (winner's proportion — used for winner update)
# f_g_j = loser_games  / total  (loser's proportion  — used for loser update)
# Retired/incomplete matches (NA games): f_g_i = 1, f_g_j = 0 (treat as binary)
# ============================================================================

wf <- df %>%
  mutate(
    P_i  = winner_name,
    P_j  = loser_name,
    Y_i  = 1L,
    Y_j  = 0L,
    NG_i = coalesce(winner_games, 0L),
    NG_j = coalesce(loser_games,  0L),
    NS_i = NA_integer_,  # sets not tracked in loader; unused when W="GAMES"
    NS_j = NA_integer_,
    tg   = NG_i + NG_j,
    f_g_i  = if_else(tg > 0L, NG_i / tg, 1.0),
    f_g_j  = if_else(tg > 0L, NG_j / tg, 0.0),
    Series  = series,
    Surface = surface,
    Date    = as.character(match_date),  # welofit() requires a "Date" column
    # welofit() output assembly references these columns; supply stubs so it
    # doesn't error — we don't use the odds columns in our evaluation
    Winner = winner_name,   # same as P_i; used in ifelse(P_i==Winner, B365W, B365L)
    Loser  = loser_name,
    B365W  = NA_real_,
    B365L  = NA_real_,
    MaxW   = NA_real_,
    MaxL   = NA_real_,
    AvgW   = NA_real_,
    AvgL   = NA_real_
  ) %>%
  select(Date, match_date, year, P_i, P_j, Y_i, Y_j, NG_i, NG_j, NS_i, NS_j,
         f_g_i, f_g_j, Series, Surface, Winner, Loser,
         B365W, B365L, MaxW, MaxL, AvgW, AvgL,
         ps_winner_odds, ps_loser_odds) %>%
  as.data.frame()   # welofit() uses base-R indexing; tibble causes issues

# ============================================================================
# RUN welofit()
# ============================================================================

cat(sprintf("Running welo::welofit() on %d matches [K=Kovalchik, W=GAMES]...\n",
            nrow(wf)))
cat("(O(n²) scan — this may take 10-30 minutes for large datasets)\n\n")

t0 <- proc.time()
result <- welo::welofit(wf, W = "GAMES", K = "Kovalchik", CI = FALSE)
elapsed <- (proc.time() - t0)[["elapsed"]]
cat(sprintf("Done in %.1f seconds (%.1f min).\n\n", elapsed, elapsed / 60))

# welofit() returns a "welo" S3 object; extract the results data frame
# (structure: list with $dataset = input + rating columns, $results = output summary)
result_df <- if (is.data.frame(result)) result else result$dataset

# ============================================================================
# EVALUATION
# ============================================================================

brier    <- function(p) mean((p - 1)^2)
accuracy <- function(p) mean(p > 0.5)

test <- result_df %>% filter(year >= TEST_FROM)

cat(sprintf("Test period (%d–%d, premium tier): N = %d\n\n",
            TEST_FROM, TEST_TO, nrow(test)))

cat(sprintf("%-30s  %6s  %8s  %8s\n", "Model", "N", "Accuracy", "Brier"))
cat(strrep("-", 58), "\n")
cat(sprintf("%-30s  %6d  %7.1f%%  %8.4f\n",
            "Package Standard Elo (overall)", nrow(test),
            100 * accuracy(test$Elo_pi_hat), brier(test$Elo_pi_hat)))
cat(sprintf("%-30s  %6d  %7.1f%%  %8.4f\n",
            "Package WElo (overall)", nrow(test),
            100 * accuracy(test$WElo_pi_hat), brier(test$WElo_pi_hat)))

cat("\n--- Our custom angelini_elo.R (Kovalchik K, surface-specific blending) ---\n")
cat(sprintf("%-30s  %6s  %8s  %8s\n", "Model", "N", "Accuracy", "Brier"))
cat(strrep("-", 58), "\n")
cat(sprintf("%-30s  %6s  %7s  %8s\n",
            "Custom Standard Elo", "~2500", "65.0%", "0.2195"))
cat(sprintf("%-30s  %6s  %7s  %8s\n",
            "Custom Angelini WElo", "~2500", "65.3%", "0.2164"))

cat("\n--- Paper baselines (Tamber et al. 2025, combined ATP+WTA) ---\n")
cat(sprintf("%-30s  %6s  %7s  %8s\n", "Standard Elo",  "—", "65.8%", "0.215"))
cat(sprintf("%-30s  %6s  %7s  %8s\n", "Angelini WElo", "—", "66.4%", "0.212"))
cat(sprintf("%-30s  %6s  %7s  %8s\n", "Pinnacle odds", "—", "69.0%", "0.196"))

# ============================================================================
# BY SURFACE
# ============================================================================

cat(sprintf("\n=== By surface (package, %d–%d) ===\n", TEST_FROM, TEST_TO))
cat(sprintf("%-8s  %6s  %8s  %8s  %8s  %8s\n",
            "Surface", "N", "Elo Acc", "WElo Acc", "Elo BS", "WElo BS"))
cat(strrep("-", 58), "\n")
for (s in c("Hard", "Clay", "Grass")) {
  d <- test %>% filter(Surface == s)
  if (nrow(d) > 0)
    cat(sprintf("%-8s  %6d  %7.1f%%  %8.1f%%  %8.4f  %8.4f\n",
                s, nrow(d),
                100 * accuracy(d$Elo_pi_hat),  100 * accuracy(d$WElo_pi_hat),
                brier(d$Elo_pi_hat), brier(d$WElo_pi_hat)))
}

# ============================================================================
# SAVE
# ============================================================================

saveRDS(result_df, sprintf("data/processed/welo_package_%s_results.rds", TOUR))
cat(sprintf("\nResults saved to data/processed/welo_package_%s_results.rds\n", TOUR))
