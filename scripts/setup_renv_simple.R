# Simple renv setup with CRAN mirror
options(repos = c(CRAN = "https://cloud.r-project.org"))

cat("Setting up renv...\n")

# Install renv if needed
if (!requireNamespace("renv", quietly = TRUE)) {
  cat("Installing renv...\n")
  install.packages("renv")
}

# Initialize renv
cat("Initializing renv...\n")
renv::init(bare = TRUE)

# Snapshot current packages
cat("Creating snapshot...\n")
renv::snapshot(prompt = FALSE)

cat("\nDone! renv.lock has been created.\n")
