###############################################################################
##  ELO PAYMENT AGGREGATOR - BOARD REVIEW
##  File: prepare_data.R  -- turns the original Kaggle files into Data/
##
##  The raw data is not stored in this repository. This script rebuilds the
##  exact input files the analysis expects from the public Kaggle download.
##
##  HOW TO RUN
##  ----------
##  1. Download the competition files from
##     https://www.kaggle.com/competitions/elo-merchant-category-recommendation/data
##  2. Put these three files in  Data/raw/ :
##        historical_transactions.csv
##        new_merchant_transactions.csv
##        merchants.csv
##  3. From the project folder run:   Rscript prepare_data.R
##
##  WHAT IT DOES
##  ------------
##  - Keeps the first 100,000 rows of each transaction file (the sample the
##    analysis was built on).
##  - Rewrites purchase_date from "2017-06-25 15:33:07" to "25-06-2017 15:33",
##    the format the analysis reads.
##  - Copies merchants.csv to merchants1.csv.
###############################################################################

if (!requireNamespace("data.table", quietly = TRUE))
  install.packages("data.table", repos = "https://cloud.r-project.org")

RAW_DIR  <- file.path("Data", "raw")
DATA_DIR <- "Data"
N_ROWS   <- 100000

need <- c("historical_transactions.csv", "new_merchant_transactions.csv",
          "merchants.csv")
missing <- need[!file.exists(file.path(RAW_DIR, need))]
if (length(missing))
  stop("Missing in ", RAW_DIR, ": ", paste(missing, collapse = ", "),
       "\nDownload them from Kaggle first (see the top of this file).")

## Read a transaction file, keep the first N_ROWS, fix the date format -------
prep_txn_file <- function(in_name, out_name) {
  message("Preparing ", out_name, " ...")
  ## Blank fields (e.g. a missing merchant_id) must stay blank. Reading them as
  ## NA makes fwrite write them back empty instead of as a quoted "".
  df <- data.table::fread(file.path(RAW_DIR, in_name), nrows = N_ROWS,
                          colClasses = list(character = "purchase_date"),
                          na.strings = c("", "NA"), showProgress = FALSE)
  ts <- as.POSIXct(df$purchase_date, format = "%Y-%m-%d %H:%M:%S", tz = "UTC")
  df$purchase_date <- format(ts, "%d-%m-%Y %H:%M")
  data.table::fwrite(df, file.path(DATA_DIR, out_name))
}

prep_txn_file("historical_transactions.csv",   "historical_transactions_100k.csv")
prep_txn_file("new_merchant_transactions.csv", "new_merchant_transactions.csv")

message("Preparing merchants1.csv ...")
invisible(file.copy(file.path(RAW_DIR, "merchants.csv"),
                    file.path(DATA_DIR, "merchants1.csv"), overwrite = TRUE))

message("Done. Data/ is ready - now run elo_analysis.R or knit Elo_Analysis.Rmd.")
