# Pre-compute Date Alignment
# Run this once to generate cached aligned matches for fast backtesting
#
# Usage:
#   Rscript scripts/precompute_alignment.R
#
# Output:
#   data/processed/atp_matches_aligned.rds

source("src/data/date_alignment.R")
source("src/data/player_stats.R")
source("src/data/betting_data.R")

cat("=== Pre-computing Date Alignment ===\n\n")

# Load all historical data
cat("Loading ATP matches (2015-2024)...\n")
atp_matches <- load_atp_matches(year_from = 2015, year_to = 2024)
cat(sprintf("  Loaded %d matches\n", nrow(atp_matches)))

cat("\nLoading betting data (2020-2024)...\n")
betting <- load_betting_data(year_from = 2020, year_to = 2024, tour = "ATP")
cat(sprintf("  Loaded %d matches\n", nrow(betting)))

# Run alignment (this takes a few minutes)
cat("\nAligning dates (this may take 3-5 minutes)...\n")
start_time <- Sys.time()

aligned <- align_match_dates(atp_matches, betting, verbose = TRUE)

elapsed <- difftime(Sys.time(), start_time, units = "mins")
cat(sprintf("\nAlignment completed in %.1f minutes\n", elapsed))

# Save to cache
output_file <- "data/processed/atp_matches_aligned.rds"
saveRDS(aligned, output_file)
cat(sprintf("\nSaved to %s\n", output_file))

# Summary stats
cat("\n=== ALIGNMENT SUMMARY ===\n")
cat(sprintf("Total matches: %d\n", nrow(aligned)))
cat(sprintf("With actual dates: %d (%.1f%%)\n",
            sum(aligned$match_method %in% c("exact", "variant", "lastname")),
            100 * sum(aligned$match_method %in% c("exact", "variant", "lastname")) / nrow(aligned)))

method_counts <- table(aligned$match_method)
for (m in names(method_counts)) {
  cat(sprintf("  %s: %d\n", m, method_counts[m]))
}

cat("\n=== Done ===\n")
