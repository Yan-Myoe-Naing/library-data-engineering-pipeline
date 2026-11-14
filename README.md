# Library Data Engineering Pipeline

An end-to-end data engineering project for Green Grass Library, covering operational database design, data cleaning, dimensional modelling, warehouse analytics, document-database preparation, and a medallion data lake.

## Architecture

```text
Excel / CSV / Word sources
          |
          v
   Bronze raw layer
          |
          v
Silver cleaned + validated ----> Quarantine invalid records
          |
          v
 Gold analytics layer
          |
          v
 DuckDB reporting queries

Operational MySQL database ----> Star-schema data warehouse
                             \--> MongoDB book collection extract
```

## What this project demonstrates

- OLTP relational modelling with referential integrity
- Data profiling, cleaning, standardisation, and validation
- Star-schema dimensional modelling
- ETL from an operational database into a data warehouse
- Bronze, Silver, Quarantine, and Gold data-lake layers
- Columnar Parquet storage and DuckDB analytics
- Reconciliation checks between warehouse and lake outputs

## Data warehouse design

The warehouse uses one completed loan transaction for one physical book copy as its fact-table grain.

- `FactLoan` — loan duration and days-late measures
- `DimMember` — member and membership-tier attributes
- `DimBookCopy` — book, copy, genre, and minimum-tier attributes
- `DimStaff` — staff and department attributes
- `DimTime` — day-level calendar attributes

## Medallion pipeline

- **Bronze:** preserves the original Excel, CSV, and Word inputs
- **Silver:** standardises fields, corrects known quality issues, validates keys, and writes Parquet datasets
- **Quarantine:** retains invalid records for investigation instead of silently deleting them
- **Gold:** creates a completed-loan analytical dataset with reusable dimensions and derived measures

The validation reports record row counts, foreign-key checks, duplicate checks, reconciliation totals, and pipeline status.

## Repository structure

```text
datalake/
  build_silver.py
  build_gold.py
  run_pipeline.py
  run_report_queries.py
  report_queries.sql
  requirements.txt
  validation reports and sample query results
design/
  oltp-erd.png
  warehouse-erd.png
  editable MySQL Workbench models
sql/
  oltp_schema.sql
  warehouse_schema.sql
  warehouse_load.sql
  warehouse_analytics.sql
  mongodb_book_extract.sql
```

## Run the data-lake pipeline

1. Install Python 3.12 or later.
2. From `datalake/`, install dependencies:

   ```bash
   pip install -r requirements.txt
   ```

3. Create `datalake/Bronze/` and add the source files expected by `build_silver.py`:
   - `data.xlsx`
   - `staff.csv`
   - `MembershipTier.docx`
4. Run:

   ```bash
   python run_pipeline.py
   ```

The pipeline creates the Silver, Quarantine, and Gold folders and then runs the DuckDB reporting queries.

## Key validation results

- 12,343 completed loan transactions in the Gold dataset
- 108,801 total loan-duration days
- 10,924 total days late
- No missing dimension keys in the validated warehouse load
- Pipeline validation status: `PASS`

## Example analytical questions

- How does genre popularity change over time?
- Which membership tiers generate the most loan activity?
- Which weekdays have the highest transaction volume?
- How is workload distributed across staff departments?
- Which genres and member tiers have higher late-return rates?

## Privacy and reproducibility note

Raw source files, bulk generated inserts, and person-like records are not published. The transformation code, schemas, validation reports, and analytical queries remain available for review. To rerun the pipeline, provide compatible source files in the local Bronze folder.

## Tools

- MySQL and MySQL Workbench
- Python, pandas, PyArrow, and python-docx
- Parquet and DuckDB
- MongoDB-compatible JavaScript extraction

## Author

Yan Myoe Naing

This was completed as a team data-engineering project; this repository presents Yan Myoe Naing's technical contribution and the shared final architecture.
