# Multiple Testing Correction Audit
#
# Catalog all subset tests conducted and apply appropriate corrections.
# The referee noted ~50+ subset tests, requiring Bonferroni or FDR correction.

library(tidyverse)

cat("=== MULTIPLE TESTING CORRECTION AUDIT ===\n\n")

# ============================================================================
# CATALOG OF ALL SUBSET TESTS
# ============================================================================

# Each test is cataloged with: name, n, win_rate, raw_roi, raw_p_value

# Load the main prediction datasets
h1_preds <- readRDS("data/processed/agree_less_confident_validation.rds")$all_preds %>%
  filter(str_starts(period_year, "H1"))

cat("Loaded H1 2021-2024 predictions\n")
cat(sprintf("Total matches: %d\n\n", nrow(h1_preds)))

# Function to test a subset and return results
test_subset <- function(data, name) {
  if (nrow(data) < 30) return(NULL)

  # Betting on market favorite
  data <- data %>%
    mutate(
      profit = ifelse(mkt_fav_won, mkt_fav_odds - 1, -1)
    )

  n <- nrow(data)
  wins <- sum(data$mkt_fav_won)
  win_rate <- mean(data$mkt_fav_won)
  avg_odds <- mean(data$mkt_fav_odds)
  breakeven <- 1 / avg_odds
  roi <- mean(data$profit)

  # One-sided binomial test (win rate > breakeven)
  p_value <- binom.test(wins, n, p = breakeven, alternative = "greater")$p.value

  tibble(
    test_name = name,
    n = n,
    win_rate = win_rate,
    breakeven = breakeven,
    roi = roi,
    p_value = p_value
  )
}

# ============================================================================
# ENUMERATE ALL TESTS
# ============================================================================

tests <- list()
i <- 1

cat("Enumerating subset tests...\n\n")

# 1. Agreement-based tests
cat("Category: Agreement\n")
for (agree in c(TRUE, FALSE)) {
  subset <- h1_preds %>% filter(agrees == agree)
  tests[[i]] <- test_subset(subset, sprintf("Agree=%s", agree))
  i <- i + 1
}

# 2. Confidence difference buckets (when agreeing)
cat("Category: Confidence difference (agrees only)\n")
conf_breaks <- c(-1, -0.10, -0.05, -0.03, 0, 0.03, 0.05, 0.10, 1)
conf_labels <- c("<-10pp", "-10 to -5pp", "-5 to -3pp", "-3 to 0pp",
                 "0 to 3pp", "3 to 5pp", "5 to 10pp", ">10pp")
for (j in 1:(length(conf_breaks)-1)) {
  subset <- h1_preds %>%
    filter(agrees,
           conf_diff >= conf_breaks[j],
           conf_diff < conf_breaks[j+1])
  tests[[i]] <- test_subset(subset, sprintf("Conf diff %s", conf_labels[j]))
  i <- i + 1
}

# 3. Odds range tests
cat("Category: Odds ranges\n")
odds_breaks <- c(1.0, 1.2, 1.4, 1.6, 1.8, 2.0, 2.5, 10)
odds_labels <- c("1.0-1.2", "1.2-1.4", "1.4-1.6", "1.6-1.8", "1.8-2.0", "2.0-2.5", "2.5+")
for (j in 1:(length(odds_breaks)-1)) {
  subset <- h1_preds %>%
    filter(mkt_fav_odds >= odds_breaks[j],
           mkt_fav_odds < odds_breaks[j+1])
  tests[[i]] <- test_subset(subset, sprintf("Odds %s", odds_labels[j]))
  i <- i + 1
}

# 4. Surface tests
cat("Category: Surface\n")
for (surf in c("Hard", "Clay", "Grass")) {
  subset <- h1_preds %>% filter(surface == surf)
  tests[[i]] <- test_subset(subset, sprintf("Surface=%s", surf))
  i <- i + 1
}

# 5. Elo confidence buckets
cat("Category: Elo confidence\n")
elo_conf_breaks <- c(0.5, 0.55, 0.60, 0.65, 0.70, 0.75, 0.80, 1.0)
for (j in 1:(length(elo_conf_breaks)-1)) {
  subset <- h1_preds %>%
    filter(elo_conf >= elo_conf_breaks[j],
           elo_conf < elo_conf_breaks[j+1])
  tests[[i]] <- test_subset(subset, sprintf("Elo conf %.0f-%.0f%%",
                                             100*elo_conf_breaks[j], 100*elo_conf_breaks[j+1]))
  i <- i + 1
}

# 6. Combined filters
cat("Category: Combined filters\n")
combined_tests <- list(
  list(name = "Agree + Odds 1.4-1.8",
       filter = quote(agrees & mkt_fav_odds >= 1.4 & mkt_fav_odds < 1.8)),
  list(name = "Agree + High conf (>65%)",
       filter = quote(agrees & elo_conf > 0.65)),
  list(name = "Agree + Less confident (0-5pp)",
       filter = quote(agrees & conf_diff >= -0.05 & conf_diff < 0)),
  list(name = "Agree + Less confident + Odds 1.7-2.0",
       filter = quote(agrees & conf_diff >= -0.05 & conf_diff < 0 &
                       mkt_fav_odds >= 1.7 & mkt_fav_odds <= 2.0)),
  list(name = "Disagree + Odds 2.0-2.5",
       filter = quote(!agrees & mkt_fav_odds >= 2.0 & mkt_fav_odds < 2.5)),
  list(name = "Clay + Agree",
       filter = quote(surface == "Clay" & agrees)),
  list(name = "Hard + Agree + High conf",
       filter = quote(surface == "Hard" & agrees & elo_conf > 0.65))
)

for (test in combined_tests) {
  subset <- h1_preds %>% filter(eval(test$filter))
  tests[[i]] <- test_subset(subset, test$name)
  i <- i + 1
}

# 7. Year-specific tests
cat("Category: By year\n")
for (yr in 2021:2024) {
  subset <- h1_preds %>% filter(year == yr)
  tests[[i]] <- test_subset(subset, sprintf("Year %d", yr))
  i <- i + 1
}

# Combine all tests
all_tests <- bind_rows(tests) %>%
  filter(!is.na(test_name))

cat(sprintf("\nTotal tests cataloged: %d\n", nrow(all_tests)))

# ============================================================================
# APPLY MULTIPLE TESTING CORRECTIONS
# ============================================================================

cat("\n========================================\n")
cat("MULTIPLE TESTING CORRECTIONS\n")
cat("========================================\n\n")

n_tests <- nrow(all_tests)

# Bonferroni correction
bonferroni_threshold <- 0.05 / n_tests
cat(sprintf("Bonferroni threshold (α = 0.05 / %d tests): %.5f\n", n_tests, bonferroni_threshold))

# Holm-Bonferroni
all_tests <- all_tests %>%
  arrange(p_value) %>%
  mutate(
    rank = row_number(),
    holm_threshold = 0.05 / (n_tests - rank + 1),
    holm_significant = p_value < holm_threshold,

    # FDR (Benjamini-Hochberg)
    fdr_threshold = 0.05 * rank / n_tests,
    fdr_significant = p_value < fdr_threshold,

    # Raw significance
    raw_significant = p_value < 0.05
  )

cat(sprintf("Tests with raw p < 0.05: %d\n", sum(all_tests$raw_significant)))
cat(sprintf("Tests surviving Bonferroni: %d\n", sum(all_tests$p_value < bonferroni_threshold)))
cat(sprintf("Tests surviving Holm-Bonferroni: %d\n", sum(all_tests$holm_significant)))
cat(sprintf("Tests surviving FDR (BH): %d\n", sum(all_tests$fdr_significant)))

# ============================================================================
# SHOW RESULTS
# ============================================================================

cat("\n========================================\n")
cat("ALL TESTS SORTED BY P-VALUE\n")
cat("========================================\n\n")

all_tests %>%
  mutate(
    win_rate = sprintf("%.1f%%", 100 * win_rate),
    roi = sprintf("%+.1f%%", 100 * roi),
    p_value = sprintf("%.4f", p_value),
    significant = case_when(
      holm_significant ~ "***Holm",
      fdr_significant ~ "**FDR",
      raw_significant ~ "*raw",
      TRUE ~ ""
    )
  ) %>%
  select(test_name, n, win_rate, roi, p_value, significant) %>%
  print(n = 40)

cat("\n========================================\n")
cat("TESTS WITH POSITIVE ROI\n")
cat("========================================\n\n")

positive_roi <- all_tests %>% filter(roi > 0)

if (nrow(positive_roi) > 0) {
  positive_roi %>%
    mutate(
      win_rate = sprintf("%.1f%%", 100 * win_rate),
      roi = sprintf("%+.1f%%", 100 * roi),
      p_value = sprintf("%.4f", p_value)
    ) %>%
    select(test_name, n, win_rate, roi, p_value) %>%
    print()
} else {
  cat("No tests with positive ROI.\n")
}

cat("\n========================================\n")
cat("SUMMARY\n")
cat("========================================\n\n")

cat(sprintf("Total subset tests: %d\n", n_tests))
cat(sprintf("Expected false positives at α=0.05: %.1f\n", n_tests * 0.05))
cat(sprintf("Tests with raw p < 0.05: %d\n", sum(all_tests$raw_significant)))
cat(sprintf("Tests surviving Holm-Bonferroni: %d\n", sum(all_tests$holm_significant)))

if (sum(all_tests$holm_significant) == 0) {
  cat("\nConclusion: No tests survive multiple testing correction.\n")
  cat("Any positive ROI findings are likely due to chance.\n")
}

# Save results
saveRDS(all_tests, "data/processed/multiple_testing_results.rds")
cat("\nResults saved to data/processed/multiple_testing_results.rds\n")
