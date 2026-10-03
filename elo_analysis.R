###############################################################################
##  ELO PAYMENT AGGREGATOR - BOARD REVIEW
##  Team: ERROR 404
##  File: elo_analysis.R  -- standalone analysis pipeline
##
##  PURPOSE
##  -------
##  Answers the Board's question: "what kind of payment network are we, and
##  where should that tell us to point the promotions programme in Q4?"
##
##  This script reproduces every number and figure in Elo_Analysis.Rmd and
##  in the board deck (Elo.pptx).
##  It is self-contained: source it and it writes all figures to ./figures/
##  and prints every headline statistic to the console.
##
##  HOW TO RUN
##  ----------
##    setwd("<folder containing this file>")
##    source("elo_analysis.R")
##
##  Expects a sub-folder  Data/  containing:
##     historical_transactions_100k.csv
##     new_merchant_transactions.csv
##     merchants1.csv
###############################################################################

## ---------------------------------------------------------------- 0. SETUP
need <- c("dplyr", "ggplot2", "tidyr", "scales", "knitr")
for (p in need) {
  if (!requireNamespace(p, quietly = TRUE)) {
    install.packages(p, repos = "https://cloud.r-project.org")
  }
}
suppressPackageStartupMessages({
  library(dplyr); library(ggplot2); library(tidyr); library(scales)
})

options(stringsAsFactors = FALSE, scipen = 999)
set.seed(404)
## ---- Paths ----------------------------------------------------------------
## Resolve the folder that contains this script, so the analysis works no
## matter what the current working directory is (RStudio "Source",
## source("..."), or Rscript from any folder). Folder names with spaces
## (e.g. "ERROR 404") are handled because every path goes through file.path().
get_script_dir <- function() {
  ## 1. Rscript path/to/elo_analysis.R
  args <- commandArgs(trailingOnly = FALSE)
  file_arg <- sub("^--file=", "", args[grep("^--file=", args)])
  file_arg <- gsub("~+~", " ", file_arg, fixed = TRUE)  # Rscript encodes spaces as ~+~
  if (length(file_arg) == 1 && nzchar(file_arg)) {
    return(dirname(normalizePath(file_arg, winslash = "/")))
  }
  ## 2. source("path/to/elo_analysis.R")
  for (i in rev(seq_len(sys.nframe()))) {
    ofile <- tryCatch(get("ofile", envir = sys.frame(i), inherits = FALSE),
                      error = function(e) NULL)
    if (is.character(ofile) && length(ofile) == 1 && file.exists(ofile)) {
      return(dirname(normalizePath(ofile, winslash = "/")))
    }
  }
  ## 3. Run line-by-line from an RStudio editor tab
  if (requireNamespace("rstudioapi", quietly = TRUE) &&
      rstudioapi::isAvailable()) {
    p <- tryCatch(rstudioapi::getSourceEditorContext()$path,
                  error = function(e) "")
    if (!is.null(p) && nzchar(p)) return(dirname(normalizePath(p, winslash = "/")))
  }
  ## 4. Fall back to the working directory
  normalizePath(getwd(), winslash = "/")
}

BASE_DIR <- get_script_dir()
DATA_DIR <- file.path(BASE_DIR, "Data")
if (!dir.exists(DATA_DIR) && dir.exists(file.path(getwd(), "Data"))) {
  BASE_DIR <- normalizePath(getwd(), winslash = "/")
  DATA_DIR <- file.path(BASE_DIR, "Data")
}
if (!dir.exists(DATA_DIR)) {
  stop("Could not find the 'Data' folder. Looked in:\n  ",
       file.path(get_script_dir(), "Data"), "\n  ",
       file.path(getwd(), "Data"),
       "\nRun setwd() to the folder that contains elo_analysis.R and Data/.")
}
FIG_DIR <- file.path(BASE_DIR, "figures")
if (!dir.exists(FIG_DIR)) dir.create(FIG_DIR, recursive = TRUE)
message("Project folder: ", BASE_DIR)

## House style for every chart -------------------------------------------------
elo_theme <- theme_minimal(base_size = 12) +
  theme(panel.grid.minor = element_blank(),
        panel.grid.major.x = element_blank(),
        plot.title    = element_text(face = "bold", size = 13),
        plot.subtitle = element_text(colour = "grey35", size = 10),
        plot.caption  = element_text(colour = "grey50", size = 8, hjust = 0),
        legend.position = "top")
theme_set(elo_theme)
PAL <- c("#1F4E79", "#2E86AB", "#7FB3D5", "#E8A33D", "#C0504D", "#7F7F7F")

## Fast reader: use data.table when present, base R otherwise -------------------
read_fast <- function(path) {
  if (!file.exists(path)) stop("File not found: ", path)
  if (requireNamespace("data.table", quietly = TRUE)) {
    as.data.frame(data.table::fread(path, showProgress = FALSE,
                                    na.strings = c("", "NA")))
  } else {
    read.csv(path, na.strings = c("", "NA"))
  }
}

###############################################################################
## 1. LOAD AND CLEAN
###############################################################################
message("Loading data ...")
hist_raw  <- read_fast(file.path(DATA_DIR, "historical_transactions_100k.csv"))
new_raw   <- read_fast(file.path(DATA_DIR, "new_merchant_transactions.csv"))
merch_raw <- read_fast(file.path(DATA_DIR, "merchants1.csv"))

cat("\n--- RAW ROW COUNTS -------------------------------------------------\n")
print(data.frame(file = c("historical_transactions_100k",
                          "new_merchant_transactions", "merchants1"),
                 rows_as_read = c(nrow(hist_raw), nrow(new_raw), nrow(merch_raw))))

## 1a. new_merchant_transactions.csv was exported from Excel and padded out to
##     the 1,048,576-row sheet limit. Everything past row 100,000 is empty.
new_raw <- new_raw[!is.na(new_raw$card_id) & new_raw$card_id != "", ]
cat("\nBlank filler rows removed from new_merchant_transactions:",
    1048575 - nrow(new_raw), "-> real transactions:", nrow(new_raw), "\n")

## 1b. merchants1.csv repeats 63 merchant_ids. Keep the first record of each.
dup_merch <- sum(duplicated(merch_raw$merchant_id))
merch <- merch_raw[!duplicated(merch_raw$merchant_id), ]
cat("Duplicate merchant_id rows dropped:", dup_merch,
    "-> unique merchants:", nrow(merch), "\n")
## The duplicated IDs carry conflicting records (sales range, lags, group), and
## any merchant join on them would double-count every transaction they touch.
dup_ids <- unique(merch_raw$merchant_id[duplicated(merch_raw$merchant_id)])
cat("Transactions at duplicated merchant_ids (double-counted on a join):",
    sum(hist_raw$merchant_id %in% dup_ids) + sum(new_raw$merchant_id %in% dup_ids),
    "\n")

## 1c. The lag ratio columns contain literal 'inf' for merchants whose base
##     month had zero transactions. Force numeric and mark them non-finite.
lag_cols <- c("avg_sales_lag3", "avg_purchases_lag3", "avg_sales_lag6",
              "avg_purchases_lag6", "avg_sales_lag12", "avg_purchases_lag12")
for (cc in lag_cols) merch[[cc]] <- suppressWarnings(as.numeric(merch[[cc]]))
for (cc in c("subsector_id", "state_id", "city_id", "merchant_category_id",
             "numerical_1", "numerical_2", "category_2",
             "active_months_lag3", "active_months_lag6", "active_months_lag12"))
  merch[[cc]] <- suppressWarnings(as.numeric(merch[[cc]]))

###############################################################################
## 2. THE DE-NORMALISATION STEP  (the analytical unlock)
###############################################################################
## purchase_amount is z-like and unreadable by a Board. Recovering the affine
## transform turns the whole ledger into Brazilian Reais:
##     BRL = purchase_amount / SCALE + OFFSET
## Validation: the minimum of the ledger maps to R$0.01-0.08, the median to
## roughly R$35 and the 99th percentile to about R$1,030 - a coherent everyday
## retail distribution. A wrong constant would produce negative money.
SCALE  <- 0.00150265
OFFSET <- 497.06
to_brl <- function(x) x / SCALE + OFFSET

prep_txn <- function(df) {
  ## Columns can arrive as character when a file carries blank padding rows or
  ## literal 'inf'. Force the numeric keys so every join and comparison is safe.
  num_cols <- c("purchase_amount", "installments", "month_lag", "city_id",
                "state_id", "subsector_id", "merchant_category_id", "category_2")
  for (cc in intersect(num_cols, names(df)))
    df[[cc]] <- suppressWarnings(as.numeric(df[[cc]]))
  df %>%
    mutate(
      amount_brl   = to_brl(purchase_amount),
      purchase_ts  = as.POSIXct(purchase_date, format = "%d-%m-%Y %H:%M", tz = "UTC"),
      purchase_day = as.Date(purchase_ts),
      month        = format(purchase_ts, "%Y-%m"),
      hour         = as.integer(format(purchase_ts, "%H")),
      dow          = weekdays(purchase_ts),
      instal       = ifelse(is.na(installments) | installments < 0,
                            NA_real_, as.numeric(installments)),
      instal_band  = cut(instal, breaks = c(-1, 0, 1, 3, 6, 12, 999),
                         labels = c("0 (lump sum)", "1 (single)", "2-3",
                                    "4-6", "7-12", "13+")),
      approved     = authorized_flag == "Y"
    )
}
hist_txn <- prep_txn(hist_raw)
new_txn  <- prep_txn(new_raw)
## installments = -1 (with category_3 missing) = payment type unknown. prep_txn
## sets these to NA, so they are left out of every instalment statistic.
cat("\nTransactions with installments = -1 (excluded from instalment stats):",
    sum(hist_txn$installments == -1, na.rm = TRUE) +
      sum(new_txn$installments == -1, na.rm = TRUE), "\n")

cat("\nDe-normalised ticket, historical ledger (BRL):\n")
print(round(quantile(hist_txn$amount_brl, c(0, .01, .25, .5, .75, .99, 1)), 2))
cat("Transactions below R$50:",
    percent(mean(hist_txn$amount_brl < 50), 0.1), "\n")

## 2b. Second, independent validation of the transform: Benford's Law.
##     Naturally occurring money amounts follow a known leading-digit pattern
##     (digit 1 ~30%, digit 9 ~5%). A wrong offset or scale would break it.
##     Mean Absolute Deviation (MAD) bands for the first digit (Nigrini):
##     < 0.006 close, 0.006-0.012 acceptable, 0.012-0.015 marginal, > 0.015 none.
benford_x     <- hist_txn$amount_brl[hist_txn$amount_brl >= 1]
first_digit   <- as.integer(substr(formatC(benford_x, format = "e", digits = 6), 1, 1))
benford_obs   <- tabulate(first_digit, nbins = 9) / length(first_digit)
benford_exp   <- log10(1 + 1 / (1:9))
benford_mad   <- mean(abs(benford_obs - benford_exp))
cat("\n--- BENFORD CHECK (first digit, historical ledger) -----------------\n")
print(data.frame(digit = 1:9, observed = percent(benford_obs, 0.1),
                 expected = percent(benford_exp, 0.1)))
cat("Benford MAD:", round(benford_mad, 4),
    ifelse(benford_mad < 0.006, "(close conformity)",
    ifelse(benford_mad < 0.012, "(acceptable conformity)",
    ifelse(benford_mad < 0.015, "(marginal conformity)", "(non-conformity)"))), "\n")

## 2a. Trim the top 0.1% of tickets for every value-based statistic.
##     99 records (0.1%) run to R$7.5m and would otherwise own every mean.
CAP <- quantile(hist_txn$amount_brl, 0.999)
cat("Trim threshold (99.9th pct):", comma(round(CAP)),
    "BRL - records above it:", sum(hist_txn$amount_brl > CAP), "\n")
hist_w <- hist_txn %>% filter(amount_brl <= CAP)
new_w  <- new_txn  %>% filter(amount_brl <= quantile(amount_brl, 0.999))
hist_ok <- hist_w %>% filter(approved)          # approved + trimmed

###############################################################################
## 3. WHO TRANSACTS ON OUR CARDS
###############################################################################
ref_date <- max(hist_ok$purchase_ts, na.rm = TRUE)

card <- hist_ok %>%
  group_by(card_id) %>%
  summarise(txns        = n(),
            spend       = sum(amount_brl),
            avg_ticket  = mean(amount_brl),
            merchants   = n_distinct(merchant_id),
            subsectors  = n_distinct(subsector_id),
            states      = n_distinct(state_id),
            first_seen  = min(purchase_ts),
            last_seen   = max(purchase_ts),
            .groups = "drop") %>%
  mutate(recency_days  = as.numeric(difftime(ref_date, last_seen, units = "days")),
         active_months = pmax(as.numeric(difftime(last_seen, first_seen, units = "days")) / 30.44, 1),
         txns_pm       = txns  / active_months,
         spend_pm      = spend / active_months)

decline_by_card <- hist_w %>%
  group_by(card_id) %>%
  summarise(decline_rate = mean(!approved), .groups = "drop")
card <- left_join(card, decline_by_card, by = "card_id")

## 3a. Pareto concentration
card_sorted <- card %>% arrange(desc(spend)) %>%
  mutate(rank = row_number(), cum_share = cumsum(spend) / sum(spend),
         card_share = rank / n())
pareto <- sapply(c(.05, .10, .20, .50), function(p)
  card_sorted$cum_share[ceiling(p * nrow(card_sorted))])
cat("\n--- SPEND CONCENTRATION --------------------------------------------\n")
print(data.frame(top_pct_of_cards = percent(c(.05, .10, .20, .50)),
                 share_of_spend   = percent(pareto, 0.1)))

## 3b. Behavioural segmentation: value per active month x merchant breadth
card <- card %>%
  mutate(hi_value   = spend_pm  >= median(spend_pm),
         hi_breadth = merchants >= median(merchants),
         segment = case_when(
           hi_value  &  hi_breadth ~ "Core Everyday",
           hi_value  & !hi_breadth ~ "Big-Ticket Narrow",
           !hi_value &  hi_breadth ~ "Explorer Light",
           TRUE                    ~ "Occasional"),
         segment = factor(segment, levels = c("Core Everyday", "Big-Ticket Narrow",
                                              "Explorer Light", "Occasional")))

seg_profile <- card %>%
  group_by(segment) %>%
  summarise(cards = n(),
            share_of_cards = n() / nrow(card),
            share_of_spend = sum(spend) / sum(card$spend),
            spend_pm   = mean(spend_pm),
            txns_pm    = mean(txns_pm),
            avg_ticket = mean(avg_ticket),
            merchants  = mean(merchants),
            subsectors = mean(subsectors),
            recency    = mean(recency_days),
            decline    = mean(decline_rate),
            .groups = "drop")
cat("\n--- CARDHOLDER SEGMENTS --------------------------------------------\n")
print(as.data.frame(seg_profile %>% mutate(across(where(is.numeric), ~round(.x, 3)))))

## 3c. Cross-check with k-means on standardised behaviour
km_in <- card %>% transmute(l_spend = log1p(spend_pm), l_txns = log1p(txns_pm),
                            l_merch = log1p(merchants), l_tkt = log1p(avg_ticket)) %>%
  scale()
km <- kmeans(km_in, centers = 4, nstart = 25)
card$cluster <- factor(km$cluster)
cat("\nk-means (k=4) cluster sizes:", paste(km$size, collapse = " / "),
    "| between/total SS:", percent(km$betweenss / km$totss, 0.1), "\n")

## 3d. Gini coefficient of card spend, with a bootstrap 95% interval
##     (1,000 resamples of the 463 cards) - is the concentration real?
gini <- function(x) {
  x <- sort(x); n <- length(x)
  sum((2 * seq_len(n) - n - 1) * x) / (n * sum(x))
}
gini_card <- gini(card$spend)
set.seed(404)
gini_boot <- replicate(1000, gini(sample(card$spend, replace = TRUE)))
gini_ci   <- quantile(gini_boot, c(0.025, 0.975))
cat("\nGini of card spend:", round(gini_card, 2),
    "| 95% bootstrap CI:", round(gini_ci[1], 2), "-", round(gini_ci[2], 2), "\n")

## 3e. Lapse index: measure each card against its own rhythm.
##     lapse_index = days since the card's last active day
##                   / the card's own median gap between active days.
##     Above 3 = the card is overdue by three of its own normal cycles.
##     Cards with a single active day have no gap and are left out.
lapse <- hist_ok %>%
  distinct(card_id, purchase_day) %>%
  arrange(card_id, purchase_day) %>%
  group_by(card_id) %>%
  mutate(gap = as.numeric(purchase_day - lag(purchase_day))) %>%
  summarise(median_gap = median(gap, na.rm = TRUE),
            last_day   = max(purchase_day), .groups = "drop") %>%
  mutate(days_since  = as.numeric(as.Date(ref_date) - last_day),
         lapse_index = days_since / median_gap)
lapsed <- lapse %>% filter(lapse_index > 3)
card$lapsed <- card$card_id %in% lapsed$card_id
cat("Lapsing cards (lapse index > 3):", nrow(lapsed), "of", nrow(card),
    "(", percent(nrow(lapsed) / nrow(card), 0.1), "of cards,",
    percent(sum(card$spend[card$lapsed]) / sum(card$spend), 0.1), "of spend )\n")

## 3f. Activation-cohort retention: of the cards whose first approved month
##     is at least 12 months before the end of the window, what share are
##     still transacting in their 12th month after activation?
card_months <- hist_ok %>%
  distinct(card_id, month) %>%
  mutate(month_idx = as.integer(substr(month, 1, 4)) * 12 +
                     as.integer(substr(month, 6, 7)))
activation <- card_months %>% group_by(card_id) %>%
  summarise(first_idx = min(month_idx), .groups = "drop")
cohort <- activation %>% filter(first_idx + 12 <= max(card_months$month_idx))
active_m12 <- card_months %>% inner_join(cohort, by = "card_id") %>%
  filter(month_idx == first_idx + 12) %>% pull(card_id)
retention_12m <- length(unique(active_m12)) / nrow(cohort)
cat("12-month retention of the activation cohort:", percent(retention_12m, 0.1),
    "(", nrow(cohort), "cards activated early enough to be observed at month 12 )\n")

p_pareto <- ggplot(card_sorted, aes(card_share, cum_share)) +
  geom_area(fill = PAL[3], alpha = .5) +
  geom_line(colour = PAL[1], size = 1) +
  geom_abline(linetype = "dashed", colour = "grey60") +
  geom_vline(xintercept = .2, linetype = "dotted", colour = PAL[5]) +
  scale_x_continuous(labels = percent) + scale_y_continuous(labels = percent) +
  labs(title = "Spend is owned by a fifth of the portfolio",
       subtitle = "Cumulative share of card spend, cards ranked highest to lowest",
       x = "Share of cards", y = "Share of spend",
       caption = "Historical ledger, approved transactions, top 0.1% of tickets excluded")
ggsave(file.path(FIG_DIR, "01_pareto.png"), p_pareto, width = 8, height = 4.6, dpi = 160)

p_seg <- seg_profile %>%
  select(segment, share_of_cards, share_of_spend) %>%
  pivot_longer(-segment) %>%
  ggplot(aes(segment, value, fill = name)) +
  geom_col(position = "dodge") +
  geom_text(aes(label = percent(value, 0.1)), position = position_dodge(.9),
            vjust = -0.4, size = 3) +
  scale_y_continuous(labels = percent, expand = expansion(mult = c(0, .15))) +
  scale_fill_manual(values = c(share_of_cards = PAL[3], share_of_spend = PAL[1]),
                    labels = c("Share of cards", "Share of spend"), name = NULL) +
  labs(title = "One segment is the network",
       subtitle = "Core Everyday cardholders are a third of the base and three quarters of the money",
       x = NULL, y = NULL)
ggsave(file.path(FIG_DIR, "02_segments.png"), p_seg, width = 8, height = 4.6, dpi = 160)

###############################################################################
## 4. HOW THE NETWORK IS ACTUALLY USED
###############################################################################
instal_mix <- hist_w %>% filter(!is.na(instal_band)) %>%
  count(instal_band) %>% mutate(share = n / sum(n))
cat("\n--- INSTALMENT MIX (this is the identity question) -----------------\n")
print(as.data.frame(instal_mix %>% mutate(share = percent(share, 0.1))))

approval_overall <- mean(hist_txn$approved)
approval_by_band <- hist_w %>% filter(!is.na(instal_band)) %>%
  group_by(instal_band) %>%
  summarise(txns = n(), approval = mean(approved), .groups = "drop")
ticket_band <- hist_w %>%
  mutate(band = cut(amount_brl, c(0, 25, 50, 100, 250, 500, 1000, Inf),
                    labels = c("<25", "25-50", "50-100", "100-250",
                               "250-500", "500-1k", "1k+"))) %>%
  group_by(band) %>%
  summarise(txns = n(), share = n() / nrow(hist_w),
            decline = mean(!approved), .groups = "drop")
cat("\nOverall approval rate:", percent(approval_overall, 0.01), "\n")
print(as.data.frame(approval_by_band %>% mutate(approval = percent(approval, 0.1))))
cat("\nDecline rate by ticket band:\n")
print(as.data.frame(ticket_band %>% mutate(share = percent(share, 0.1),
                                           decline = percent(decline, 0.1))))

## 4a. Chi-square: is the instalment/approval relationship real?
ct_df <- hist_w %>% filter(!is.na(instal_band)) %>%
  mutate(instal_band = droplevels(instal_band))
ct <- table(ct_df$instal_band, ct_df$approved)   # drop unused levels: no zero rows
chi <- chisq.test(ct)
cat("\nChi-square, instalment band x authorisation: X2 =", round(chi$statistic, 1),
    "df =", chi$parameter, "p =", format.pval(chi$p.value, digits = 3), "\n")

## 4b. Logistic regression: what actually drives a decline?
mdl_df <- hist_w %>%
  filter(!is.na(instal)) %>%
  transmute(decline  = as.integer(!approved),
            log_amt  = log1p(pmax(amount_brl, 0.01)),
            multi    = as.integer(instal >= 2),
            cat1_y   = as.integer(category_1 == "Y"))
decline_model <- glm(decline ~ log_amt + multi + cat1_y,
                     data = mdl_df, family = binomial())
cat("\n--- LOGISTIC REGRESSION: P(decline) --------------------------------\n")
print(summary(decline_model)$coefficients)
cat("\nOdds ratios:\n"); print(round(exp(coef(decline_model)), 3))
cat("McFadden pseudo-R2:",
    round(1 - decline_model$deviance / decline_model$null.deviance, 4), "\n")

p_instal <- ggplot(instal_mix, aes(instal_band, share)) +
  geom_col(fill = PAL[1]) +
  geom_text(aes(label = percent(share, 0.1)), vjust = -0.4, size = 3.4) +
  scale_y_continuous(labels = percent, expand = expansion(mult = c(0, .15))) +
  labs(title = "Elo is not an instalment network",
       subtitle = "96% of transactions settle in one payment - the parcelado market is happening elsewhere",
       x = "Instalments on the transaction", y = "Share of transactions")
ggsave(file.path(FIG_DIR, "03_instalments.png"), p_instal, width = 8, height = 4.4, dpi = 160)

p_decline <- ggplot(ticket_band, aes(band, decline)) +
  geom_col(fill = PAL[5]) +
  geom_text(aes(label = percent(decline, 0.1)), vjust = -0.4, size = 3.4) +
  scale_y_continuous(labels = percent, expand = expansion(mult = c(0, .18))) +
  labs(title = "Declines climb with the size of the basket",
       subtitle = "Decline rate by ticket band, historical ledger",
       x = "Ticket size (BRL)", y = "Declined share")
ggsave(file.path(FIG_DIR, "04_decline_by_ticket.png"), p_decline, width = 8, height = 4.4, dpi = 160)

hourly <- hist_ok %>% count(hour) %>% mutate(share = n / sum(n))
p_hour <- ggplot(hourly, aes(hour, share)) +
  geom_col(fill = PAL[2]) +
  scale_y_continuous(labels = percent) +
  scale_x_continuous(breaks = seq(0, 23, 3)) +
  labs(title = "A daytime, everyday network",
       subtitle = "Share of approved transactions by hour of day",
       x = "Hour", y = NULL)
ggsave(file.path(FIG_DIR, "05_hourly.png"), p_hour, width = 8, height = 4, dpi = 160)

monthly <- hist_ok %>%
  group_by(month) %>%
  summarise(txns = n(), spend = sum(amount_brl), cards = n_distinct(card_id),
            avg_ticket = mean(amount_brl), .groups = "drop")
cat("\n--- MONTHLY TREND ---------------------------------------------------\n")
print(as.data.frame(monthly %>% mutate(spend = comma(round(spend)),
                                       avg_ticket = round(avg_ticket, 2))))
p_month <- ggplot(monthly, aes(month, txns, group = 1)) +
  geom_line(colour = PAL[1], size = 1) +
  geom_point(colour = PAL[1]) +
  geom_line(aes(y = cards * 20), colour = PAL[4], linetype = "dashed", size = .8) +
  scale_y_continuous(labels = comma,
                     sec.axis = sec_axis(~ . / 20, name = "Active cards (dashed)")) +
  labs(title = "Volume grows because cards activate, not because cards spend more",
       subtitle = "Approved transactions (solid) against active cards (dashed, right axis)",
       x = NULL, y = "Transactions") +
  theme(axis.text.x = element_text(angle = 45, hjust = 1))
ggsave(file.path(FIG_DIR, "06_monthly.png"), p_month, width = 8, height = 4.4, dpi = 160)

###############################################################################
## 5. THE MERCHANT SIDE
###############################################################################
size_pyramid <- merch %>% filter(!is.na(most_recent_sales_range)) %>%
  count(most_recent_sales_range) %>% mutate(share = n / sum(n))
cat("\n--- MERCHANT SIZE PYRAMID (A = largest) ----------------------------\n")
print(as.data.frame(size_pyramid %>% mutate(share = percent(share, 0.1))))

## Rows with no merchant_id (0.5%) are excluded from merchant-level counts,
## otherwise "unknown" ranks as the network's largest merchant.
hist_m <- hist_ok %>% filter(!is.na(merchant_id))
new_m  <- new_w   %>% filter(!is.na(merchant_id))

merch_txn <- hist_m %>% count(merchant_id, name = "txns") %>% arrange(desc(txns)) %>%
  mutate(cum_share = cumsum(txns) / sum(txns), rank = row_number())
cat("\nActive merchants in the historical window:", nrow(merch_txn),
    "(", percent(nrow(merch_txn) / nrow(merch), 0.1), "of the reference file )\n")
for (k in c(10, 100, 1000)) {
  cat("  top", k, "merchants =", percent(merch_txn$cum_share[k], 0.1), "of transactions\n")
}
seen <- union(unique(hist_m$merchant_id), unique(new_m$merchant_id))
cat("Merchants in merchants1.csv never seen in either window:",
    percent(1 - length(seen) / nrow(merch), 0.1), "\n")

## 5a. Momentum segmentation of the supply base
merch_seg <- merch %>%
  filter(is.finite(avg_purchases_lag3), is.finite(avg_purchases_lag12),
         avg_purchases_lag12 != 0) %>%
  mutate(momentum = avg_purchases_lag3 / avg_purchases_lag12,
         health = case_when(
           active_months_lag12 < 12 ~ "Intermittent",
           momentum >= 1.05         ~ "Accelerating",
           momentum <= 0.95         ~ "Decelerating",
           TRUE                     ~ "Steady"))
cat("\n--- MERCHANT HEALTH MIX --------------------------------------------\n")
print(as.data.frame(merch_seg %>% count(health) %>% mutate(share = percent(n / sum(n), 0.1))))

## 5b. Where does demand actually land, by merchant size tier?
tier <- merch %>% select(merchant_id, most_recent_sales_range)
tier_flow <- bind_rows(
  hist_m %>% select(merchant_id) %>% mutate(window = "Incumbent spend"),
  new_m   %>% select(merchant_id) %>% mutate(window = "New-merchant spend")) %>%
  left_join(tier, by = "merchant_id") %>%
  filter(!is.na(most_recent_sales_range)) %>%
  count(window, most_recent_sales_range) %>%
  group_by(window) %>% mutate(share = n / sum(n)) %>% ungroup() %>%
  bind_rows(size_pyramid %>% transmute(window = "Merchant population",
                                       most_recent_sales_range, n, share))
cat("\n--- DEMAND BY MERCHANT SIZE TIER -----------------------------------\n")
print(as.data.frame(tier_flow %>% select(-n) %>%
                      pivot_wider(names_from = window, values_from = share)))

p_tier <- ggplot(tier_flow, aes(most_recent_sales_range, share,
                                fill = factor(window, levels = c("Merchant population",
                                                                 "Incumbent spend",
                                                                 "New-merchant spend")))) +
  geom_col(position = "dodge") +
  scale_y_continuous(labels = percent) +
  scale_fill_manual(values = PAL[c(6, 1, 4)], name = NULL) +
  labs(title = "Discovery happens in the long tail, incumbency at the top",
       subtitle = "Tier A is 0.3% of merchants and a quarter of incumbent volume - but far less of new-merchant volume",
       x = "Merchant size tier (A = largest revenue band)", y = "Share")
ggsave(file.path(FIG_DIR, "07_size_tiers.png"), p_tier, width = 8.5, height = 4.6, dpi = 160)

###############################################################################
## 6. GEOGRAPHY: DEMAND AGAINST SUPPLY
###############################################################################
geo <- full_join(
  hist_ok %>% count(state_id, name = "inc_txns"),
  new_w   %>% count(state_id, name = "nov_txns"), by = "state_id") %>%
  full_join(merch %>% count(state_id, name = "merchants"), by = "state_id") %>%
  replace_na(list(inc_txns = 0, nov_txns = 0, merchants = 0)) %>%
  mutate(demand_share = inc_txns / sum(inc_txns),
         novelty_share = nov_txns / sum(nov_txns),
         supply_share  = merchants / sum(merchants),
         coverage_index = supply_share / demand_share,
         novelty_index  = novelty_share / demand_share) %>%
  arrange(desc(inc_txns))
cat("\n--- STATE-LEVEL DEMAND vs SUPPLY -----------------------------------\n")
print(as.data.frame(head(geo, 12) %>% mutate(across(where(is.numeric), ~round(.x, 3)))))

p_geo <- geo %>% filter(inc_txns >= 500) %>%
  ggplot(aes(demand_share, supply_share)) +
  geom_abline(linetype = "dashed", colour = "grey60") +
  geom_point(aes(size = inc_txns), colour = PAL[1], alpha = .75) +
  geom_text(aes(label = paste0("S", state_id)), vjust = -1, size = 3, colour = "grey30") +
  scale_x_continuous(labels = percent) + scale_y_continuous(labels = percent) +
  scale_size_continuous(range = c(2, 9), guide = "none") +
  labs(title = "Where the merchant base does not match the cardholders",
       subtitle = "Below the line = more demand than supply (under-served). Above = over-supplied.",
       x = "Share of card transactions", y = "Share of merchants")
ggsave(file.path(FIG_DIR, "08_geo.png"), p_geo, width = 8, height = 5, dpi = 160)

###############################################################################
## 7. THE NOVELTY WINDOW
###############################################################################
cat("\n--- NOVELTY WINDOW --------------------------------------------------\n")
cat("Transactions:", comma(nrow(new_w)), "| cards:", comma(n_distinct(new_w$card_id)),
    "| merchants:", comma(n_distinct(new_m$merchant_id)), "\n")
cat("Average new-merchant ticket: R$", round(mean(new_w$amount_brl), 2),
    " vs incumbent R$", round(mean(hist_ok$amount_brl), 2), "\n")
cat("New merchants tried per card in the 2-month window:",
    round(mean(tapply(new_m$merchant_id, new_m$card_id, function(x) length(unique(x)))), 1), "\n")
cat("Cards in historical file:", n_distinct(hist_txn$card_id),
    "| in new-merchant file:", n_distinct(new_txn$card_id),
    "| in both:", length(intersect(unique(hist_txn$card_id), unique(new_txn$card_id))), "\n")

novelty_instal <- bind_rows(
  hist_ok %>% filter(!is.na(instal_band)) %>% count(instal_band) %>%
    mutate(window = "Incumbent", share = n / sum(n)),
  new_w %>% filter(!is.na(instal_band)) %>% count(instal_band) %>%
    mutate(window = "New merchant", share = n / sum(n)))
cat("\nInstalment mix, incumbent vs novelty:\n")
print(as.data.frame(novelty_instal %>% select(window, instal_band, share) %>%
                      pivot_wider(names_from = window, values_from = share) %>%
                      mutate(across(where(is.numeric), ~percent(.x, 0.1)))))

###############################################################################
## 8. THE PROMOTIONS TARGETING MAP  (the synthesis)
###############################################################################
## Two indices per subsector:
##   Novelty Capture Index (NCI) = share of new-merchant volume / share of
##      incumbent volume. Above 1 -> cardholders go there to try something new.
##   Coverage Index (COV) = share of merchants / share of incumbent volume.
##      Above 1 -> more merchant supply than cardholder demand.
sub_map <- full_join(
  hist_ok %>% count(subsector_id, name = "inc_txns"),
  new_w   %>% count(subsector_id, name = "nov_txns"), by = "subsector_id") %>%
  full_join(merch %>% count(subsector_id, name = "merchants"), by = "subsector_id") %>%
  full_join(hist_ok %>% group_by(subsector_id) %>%
              summarise(inc_value = sum(amount_brl), avg_ticket = mean(amount_brl),
                        .groups = "drop"), by = "subsector_id") %>%
  replace_na(list(inc_txns = 0, nov_txns = 0, merchants = 0, inc_value = 0)) %>%
  mutate(demand_share  = inc_txns / sum(inc_txns),
         novelty_share = nov_txns / sum(nov_txns),
         supply_share  = merchants / sum(merchants),
         NCI = novelty_share / demand_share,
         COV = supply_share  / demand_share) %>%
  filter(inc_txns >= 300) %>%
  mutate(role = case_when(
    NCI >= 1.2 ~ "Acquisition engine",
    COV >= 1.2 ~ "Over-served (promotion waste)",
    TRUE       ~ "Habit anchor (under-supplied)")) %>%
  arrange(desc(demand_share))
cat("\n--- SUBSECTOR TARGETING MAP ----------------------------------------\n")
print(as.data.frame(sub_map %>%
        select(subsector_id, inc_txns, demand_share, novelty_share, supply_share,
               NCI, COV, avg_ticket, role) %>%
        mutate(across(where(is.numeric), ~round(.x, 3)))))

p_map <- ggplot(sub_map, aes(COV, NCI)) +
  geom_hline(yintercept = 1.2, linetype = "dashed", colour = "grey55") +
  geom_vline(xintercept = 1.2, linetype = "dashed", colour = "grey55") +
  geom_point(aes(size = demand_share, colour = role), alpha = .85) +
  geom_text(aes(label = subsector_id), size = 2.8, vjust = -1.1, colour = "grey25") +
  scale_size_continuous(range = c(2.5, 12), labels = percent, name = "Share of volume") +
  scale_colour_manual(values = c("Acquisition engine" = PAL[1],
                                 "Habit anchor (under-supplied)" = PAL[4],
                                 "Over-served (promotion waste)" = PAL[2]), name = NULL) +
  guides(colour = guide_legend(nrow = 1, override.aes = list(size = 4))) +
  labs(title = "Where to point the Q4 promotions programme",
       subtitle = "Novelty Capture Index against Coverage Index, by merchant subsector",
       x = "Coverage Index  (merchant supply / cardholder demand)",
       y = "Novelty Capture Index  (new-merchant volume / incumbent volume)",
       caption = "Bubble size = share of incumbent transactions. Subsectors with at least 300 incumbent transactions.")
ggsave(file.path(FIG_DIR, "09_targeting_map.png"), p_map, width = 9, height = 5.6, dpi = 160)

## 8b. The Board version of the map (deck slide 8): card reach x NCI, with
##     95% intervals, so budget follows evidence rather than point estimates.
##   Card reach = share of cardholders who already use the subsector.
##   NCI interval: delta method on log(NCI) = log(p_new) - log(p_inc), where
##     Var(log p_hat) ~ (1 - p) / count, so
##     SE = sqrt((1 - p_new) / nov_txns + (1 - p_inc) / inc_txns).
##   Quadrants (cut-offs: NCI 1.2 = at least a 20% over-index; reach 60% sits
##   in the natural gap between 56% and 70%):
##     reach >= 60% and lower CI > 1.2  -> Merchant discovery
##     reach >= 60% and NCI < 1.2       -> Habit channel
##     reach <  60% and lower CI > 1.2  -> Category expansion
##     anything else (interval crosses 1.2 or sits below it) -> Deprioritise
n_cards_ok <- n_distinct(hist_ok$card_id)
reach <- hist_ok %>% group_by(subsector_id) %>%
  summarise(reach = n_distinct(card_id) / n_cards_ok, .groups = "drop")
REACH_CUT <- 0.60; NCI_CUT <- 1.2
QUAD_LEVELS <- c("Habit channel", "Merchant discovery", "Category expansion", "Deprioritise")
reach_map <- sub_map %>%
  left_join(reach, by = "subsector_id") %>%
  mutate(se_log = sqrt((1 - novelty_share) / nov_txns + (1 - demand_share) / inc_txns),
         nci_lo = exp(log(NCI) - 1.96 * se_log),
         nci_hi = exp(log(NCI) + 1.96 * se_log),
         quadrant = case_when(
           reach >= REACH_CUT & nci_lo > NCI_CUT ~ "Merchant discovery",
           reach >= REACH_CUT & NCI    < NCI_CUT ~ "Habit channel",
           reach <  REACH_CUT & nci_lo > NCI_CUT ~ "Category expansion",
           TRUE                                  ~ "Deprioritise"),
         quadrant = factor(quadrant, levels = QUAD_LEVELS))
cat("\n--- TARGETING MAP: CARD REACH x NCI (95% CI) -----------------------\n")
print(as.data.frame(reach_map %>%
        select(subsector_id, reach, NCI, nci_lo, nci_hi, avg_ticket, quadrant) %>%
        mutate(across(where(is.numeric), ~round(.x, 3)))))
for (q in QUAD_LEVELS)
  cat(sprintf("%-19s", q), ":",
      paste(reach_map$subsector_id[reach_map$quadrant == q], collapse = ", "), "\n")

## First-visit yield: new-merchant transactions per 1,000 incumbent transactions
yield <- reach_map %>%
  mutate(group = case_when(
    quadrant == "Habit channel" ~ "Habit",
    quadrant %in% c("Merchant discovery", "Category expansion") ~ "Discovery",
    TRUE ~ "Deprioritised")) %>%
  group_by(group) %>%
  summarise(inc_txns = sum(inc_txns), nov_txns = sum(nov_txns),
            share_of_volume = sum(demand_share), .groups = "drop") %>%
  mutate(first_visits_per_1000 = 1000 * nov_txns / inc_txns)
cat("\nFirst-visit yield by group:\n")
print(as.data.frame(yield %>% mutate(share_of_volume = percent(share_of_volume, 0.1),
                                     first_visits_per_1000 = round(first_visits_per_1000))))
y_habit <- yield$first_visits_per_1000[yield$group == "Habit"]
y_disc  <- yield$first_visits_per_1000[yield$group == "Discovery"]
habit_inc <- yield$inc_txns[yield$group == "Habit"]
extra_visits <- (habit_inc / 3) * (y_disc - y_habit) / 1000
cat("Discovery / habit yield ratio:", round(y_disc / y_habit, 2), "x\n")
cat("Reallocating one third of habit exposure (", comma(round(habit_inc / 3)),
    "transactions ) -> ~", comma(round(extra_visits, -2)), "extra first visits\n")
cat("  (assumes the discovery yield carries over to reallocated exposure -\n",
    "  exactly what a holdout test would need to confirm)\n")

QUAD_COL <- c("Habit channel" = "#2BA86A", "Merchant discovery" = "#2E7BD6",
              "Category expansion" = "#E8683A", "Deprioritise" = "#8C8C8C")
p_reach <- ggplot(reach_map, aes(reach, NCI)) +
  geom_hline(yintercept = NCI_CUT, linetype = "dashed", colour = "grey55") +
  geom_vline(xintercept = REACH_CUT, linetype = "dashed", colour = "grey55") +
  geom_errorbar(aes(ymin = nci_lo, ymax = nci_hi, colour = quadrant),
                width = 0, linewidth = 0.8, alpha = 0.6) +
  geom_point(aes(size = demand_share, fill = quadrant), shape = 21,
             colour = "white", stroke = 0.6, alpha = 0.9) +
  geom_text(aes(label = subsector_id), size = 3, vjust = -1.3, colour = "grey20") +
  scale_x_continuous(labels = percent, limits = c(0.15, 1.02)) +
  scale_size_continuous(range = c(2.5, 14), guide = "none") +
  scale_fill_manual(values = QUAD_COL, name = NULL) +
  scale_colour_manual(values = QUAD_COL, guide = "none") +
  guides(fill = guide_legend(override.aes = list(size = 5))) +
  labs(title = "Where to point the Q4 promotions programme",
       subtitle = "Novelty Capture Index with 95% intervals (delta method); bubble size = share of transactions",
       x = "Card reach (share of cardholders already using the subsector)",
       y = "Novelty Capture Index")
ggsave(file.path(FIG_DIR, "10_reach_map.png"), p_reach, width = 9, height = 5.6, dpi = 160)

###############################################################################
## 9. SIZING THE PRIZE
###############################################################################
decline_loss <- hist_w %>% filter(!approved) %>% summarise(v = sum(amount_brl)) %>% pull(v)
cat("\n--- HEADLINE NUMBERS FOR THE BOARD ---------------------------------\n")
cat("1. Approval rate", percent(approval_overall, 0.01),
    "- declined value is", percent(decline_loss / sum(hist_w$amount_brl), 0.1),
    "of gross attempted volume\n")
cat("2. category_1 = 'Y' carries", round(exp(coef(decline_model))["cat1_y"], 1),
    "x the odds of a decline\n")
cat("3. Top 20% of cards =", percent(pareto[3], 0.1), "of spend\n")
cat("4. 96% of transactions settle in a single payment\n")
cat("5. Tier A merchants are", percent(size_pyramid$share[size_pyramid$most_recent_sales_range == "A"], 0.1),
    "of the merchant base\n")
cat("6. Acquisition-engine subsectors:",
    paste(sub_map$subsector_id[grepl("Acquisition", sub_map$role)], collapse = ", "), "\n")
cat("7. Benford MAD", round(benford_mad, 4), "| Gini", round(gini_card, 2),
    "( 95% CI", round(gini_ci[1], 2), "-", round(gini_ci[2], 2), ")\n")
cat("8. Lapsing cards:", nrow(lapsed), "holding",
    percent(sum(card$spend[card$lapsed]) / sum(card$spend), 0.1),
    "of spend | 12-month cohort retention", percent(retention_12m, 0.1), "\n")
cat("9. First visits per 1,000: habit", round(y_habit), "vs discovery", round(y_disc),
    "-> ~", comma(round(extra_visits, -2)), "extra first visits from a one-third shift\n")

message("\nDone. Figures written to ", FIG_DIR)
