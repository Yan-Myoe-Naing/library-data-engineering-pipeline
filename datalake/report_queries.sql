-- Figure 3: inspect a five-row sample from the Silver loan Parquet file.
SELECT
    MemberID,
    BookID,
    LoanStatus
FROM read_parquet('Silver/loans.parquet')
LIMIT 5;

-- Figure 3: demonstrate that Parquet stores separate column-level metadata.
SELECT
    path_in_schema AS ColumnName,
    type AS PhysicalType,
    num_values AS ValueCount,
    total_compressed_size AS CompressedSizeBytes
FROM parquet_metadata('Silver/loans.parquet')
WHERE row_group_id = 0
ORDER BY column_id;

-- Output 1: the same analytical question used in Group Part D, Question 1.
WITH YearlyGenreTotals AS (
    SELECT
        LoanYear,
        Genre,
        COUNT(*) AS TotalGenreLoans
    FROM read_parquet('Gold/completed_loan_analytics.parquet')
    GROUP BY LoanYear, Genre
),
GenreRankings AS (
    SELECT
        LoanYear,
        Genre,
        TotalGenreLoans,
        ROUND(
            TotalGenreLoans * 100.0 /
            SUM(TotalGenreLoans) OVER (PARTITION BY LoanYear),
            2
        ) AS GenreSharePercentage,
        RANK() OVER (
            PARTITION BY LoanYear
            ORDER BY TotalGenreLoans DESC
        ) AS PopularityRank
    FROM YearlyGenreTotals
)
SELECT
    LoanYear,
    Genre AS MostPopularGenre,
    TotalGenreLoans,
    GenreSharePercentage
FROM GenreRankings
WHERE PopularityRank = 1
ORDER BY LoanYear;
