# Confidence Intervals for Trajectory Strategy

library(tidyverse)

# Load 2021-2024 predictions
preds <- readRDS("data/processed/trajectory_analysis.rds")

preds_traj <- preds %>%
  filter(!is.na(trajectory_diff)) %>%
  mutate(
    elo_opp_odds = ifelse(elo_pick == winner, 1 / (1 - mkt_prob_w), 1 / mkt_prob_w),
    elo_opp_won = !elo_correct,
    contrarian_profit = ifelse(elo_opp_won, elo_opp_odds - 1, -1)
  )

# Best subset in-sample
best <- preds_traj %>%
  filter(trajectory_diff < -0.20, elo_opp_odds >= 3.0, elo_opp_odds < 5.0)

# Calculate CI for in-sample
n_is <- nrow(best)
mean_profit_is <- mean(best$contrarian_profit)
sd_profit_is <- sd(best$contrarian_profit)
se_is <- sd_profit_is / sqrt(n_is)

cat("=== IN-SAMPLE (2021-2024) ===\n")
cat(sprintf("N: %d\n", n_is))
cat(sprintf("Mean ROI: %+.2f%%\n", 100 * mean_profit_is))
cat(sprintf("SD of profit per bet: %.2f units\n", sd_profit_is))
cat(sprintf("SE of mean ROI: %.2f%%\n", 100 * se_is))
cat(sprintf("\n95%% CI for ROI: [%+.2f%%, %+.2f%%]\n",
            100 * (mean_profit_is - 1.96 * se_is),
            100 * (mean_profit_is + 1.96 * se_is)))

# Win rate CI (binomial)
wins_is <- sum(best$elo_opp_won)
prop_test_is <- prop.test(wins_is, n_is)
cat(sprintf("\nWin rate: %.1f%%\n", 100 * wins_is/n_is))
cat(sprintf("95%% CI for win rate: [%.1f%%, %.1f%%]\n",
            100 * prop_test_is$conf.int[1],
            100 * prop_test_is$conf.int[2]))
cat(sprintf("Breakeven win rate: %.1f%%\n", 100 / mean(best$elo_opp_odds)))

# Load 2025 results (already computed)
# Using the saved values from previous run
n_oos <- 99
wins_oos <- 31
mean_profit_oos <- 0.2104
sd_profit_oos <- 1.82  # Approximate from typical betting SD

se_oos <- sd_profit_oos / sqrt(n_oos)

cat("\n\n=== OUT-OF-SAMPLE (2025) ===\n")
cat(sprintf("N: %d\n", n_oos))
cat(sprintf("Mean ROI: %+.2f%%\n", 100 * mean_profit_oos))
cat(sprintf("SE of mean ROI: %.2f%%\n", 100 * se_oos))
cat(sprintf("\n95%% CI for ROI: [%+.2f%%, %+.2f%%]\n",
            100 * (mean_profit_oos - 1.96 * se_oos),
            100 * (mean_profit_oos + 1.96 * se_oos)))

prop_test_oos <- prop.test(wins_oos, n_oos)
cat(sprintf("\nWin rate: %.1f%%\n", 100 * wins_oos/n_oos))
cat(sprintf("95%% CI for win rate: [%.1f%%, %.1f%%]\n",
            100 * prop_test_oos$conf.int[1],
            100 * prop_test_oos$conf.int[2]))
cat(sprintf("Breakeven win rate: ~26.6%%\n"))

# Pooled estimate
cat("\n\n=== POOLED (2021-2025) ===\n")
n_all <- n_is + n_oos
wins_all <- wins_is + wins_oos

# Weighted average ROI
total_profit_is <- mean_profit_is * n_is
total_profit_oos <- mean_profit_oos * n_oos
mean_all <- (total_profit_is + total_profit_oos) / n_all

# Pooled SD (approximate)
pooled_var <- ((n_is - 1) * sd_profit_is^2 + (n_oos - 1) * sd_profit_oos^2) / (n_all - 2)
pooled_sd <- sqrt(pooled_var)
se_all <- pooled_sd / sqrt(n_all)

cat(sprintf("N: %d\n", n_all))
cat(sprintf("Mean ROI: %+.2f%%\n", 100 * mean_all))
cat(sprintf("SE of mean ROI: %.2f%%\n", 100 * se_all))
cat(sprintf("\n95%% CI for ROI: [%+.2f%%, %+.2f%%]\n",
            100 * (mean_all - 1.96 * se_all),
            100 * (mean_all + 1.96 * se_all)))

prop_test_all <- prop.test(wins_all, n_all)
cat(sprintf("\nWin rate: %.1f%%\n", 100 * wins_all/n_all))
cat(sprintf("95%% CI for win rate: [%.1f%%, %.1f%%]\n",
            100 * prop_test_all$conf.int[1],
            100 * prop_test_all$conf.int[2]))

