# Setup script for renv dependency management
# =============================================
#
# Run this script once to initialize renv and snapshot dependencies.
#
# Usage:
#   Rscript code/setup_renv.R
#   # Or in R console:
#   source("code/setup_renv.R")

cat("Setting up renv for dependency management...\n\n")

# Install renv if not already installed
if (!requireNamespace("renv", quietly = TRUE)) {
  cat("Installing renv...\n")
  install.packages("renv")
}

# Initialize renv (creates renv/ directory and .Rprofile)
cat("Initializing renv...\n")
renv::init(bare = TRUE)

# Install project dependencies
cat("\nInstalling project dependencies...\n")
renv::install(c(
  "tidyverse",
  "lubridate",
  "readxl"
))

# Snapshot the current state
cat("\nCreating renv.lock snapshot...\n")
renv::snapshot()

cat("\n")
cat("=" %>% rep(60) %>% paste(collapse = ""), "\n")
cat("renv setup complete!\n")
cat("=" %>% rep(60) %>% paste(collapse = ""), "\n")
cat("\n")
cat("The following files were created:\n")
cat("  - .Rprofile (activates renv on project load)\n")
cat("  - renv.lock (records package versions)\n")
cat("  - renv/ (local package library)\n")
cat("\n")
cat("To restore this environment on another machine:\n")
cat("  renv::restore()\n")
cat("\n")
