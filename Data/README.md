# Data

The data files are **not included** in this repository. They come from the
public Kaggle competition
[Elo Merchant Category Recommendation](https://www.kaggle.com/competitions/elo-merchant-category-recommendation/data),
and the competition rules do not allow sharing them again.

## How to get the data

1. Sign in to [Kaggle](https://www.kaggle.com/) and accept the competition
   rules on the competition page.
2. Download these three files from the **Data** tab:
   - `historical_transactions.csv`
   - `new_merchant_transactions.csv`
   - `merchants.csv`
3. Create a folder called `raw` inside this `Data/` folder and put the three
   files there:

   ```
   Data/
   └── raw/
       ├── historical_transactions.csv
       ├── new_merchant_transactions.csv
       └── merchants.csv
   ```

4. From the main project folder, run:

   ```bash
   Rscript prepare_data.R
   ```

This creates the three files the analysis reads:

| File | What it is | Rows |
|------|------------|------|
| `historical_transactions_100k.csv` | Regular card spending — the first 100,000 transactions | 100,000 |
| `new_merchant_transactions.csv` | Purchases at merchants the card had never used before — the first 100,000 | 100,000 |
| `merchants1.csv` | One row per merchant: size, sales trends, location | 334,696 |

The script keeps the first 100,000 rows of each transaction file and changes
the date format to `DD-MM-YYYY HH:MM`. These are the same files the analysis
was built on.

> **Note:** The original course copy of `new_merchant_transactions.csv` had
> about 950,000 empty rows added by Excel. The analysis removes them, so the
> "blank rows removed" count you see may be different. All results are the same.

## What the main columns mean

| Column | Meaning |
|--------|---------|
| `card_id` | Anonymous card ID |
| `merchant_id` | Anonymous merchant ID |
| `purchase_amount` | Normalised purchase amount (the analysis converts it back to Brazilian Reais) |
| `purchase_date` | Date and time of the purchase |
| `authorized_flag` | `Y` if the payment was approved, `N` if it was declined |
| `installments` | Number of instalments the purchase was split into |
| `category_1`, `category_2`, `category_3` | Anonymous categories |
| `subsector_id`, `merchant_category_id` | Anonymous merchant category codes |
| `state_id`, `city_id` | Anonymous location codes |
| `month_lag` | Months between the purchase and the card's reference date |
| `most_recent_sales_range` | Merchant size band, from `A` (largest) to `E` (smallest) |
| `avg_sales_lag3/6/12`, `avg_purchases_lag3/6/12` | Merchant sales trends over the last 3, 6 and 12 months |

The full field definitions are in `Data_Dictionary.xlsx` on the same Kaggle page.
