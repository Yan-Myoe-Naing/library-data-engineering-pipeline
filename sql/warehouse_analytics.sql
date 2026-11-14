-- Research Question 1:
-- What is the most popular genre for each year from 2020 to 2025 ?

USE green_grass_library_dw;

-- Step 3: Display only the most popular genre for each year
SELECT
    LoanYear,
    Genre AS MostPopularGenre,
    TotalGenreLoans,
    GenreSharePercentage
FROM (
    -- Step 2: Calculate each genre's yearly percentage and rank
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
    FROM (
        -- Step 1: Count the loans for each genre in each year
        SELECT
            t.Year AS LoanYear,
            b.Genre,
            COUNT(*) AS TotalGenreLoans
        FROM FactLoan AS f
        JOIN DimTime AS t
            ON f.TimeKey = t.TimeKey
        JOIN DimBookCopy AS b
            ON f.BookCopyKey = b.BookCopyKey
        GROUP BY
            t.Year,
            b.Genre
    ) AS YearlyGenreTotals
) AS GenreRankings
WHERE PopularityRank = 1
ORDER BY LoanYear;


-- ============================================================
-- Research Question 2:
-- How has loan activity for each membership tier changed from 2020 to 2025?
-- ============================================================

USE green_grass_library_dw;

SELECT
    TierName,
    LoanYear,
    TotalLoans,
    ROUND(
        TotalLoans * 100.0 /
        SUM(TotalLoans) OVER (
            PARTITION BY LoanYear
        ),
        2
    ) AS PercentageOfYearlyLoans
FROM (
    SELECT
        m.TierName,
        m.TierLevel,
        t.Year AS LoanYear,
        COUNT(*) AS TotalLoans
    FROM FactLoan AS f
    JOIN DimMember AS m
        ON f.MemberKey = m.MemberKey
    JOIN DimTime AS t
        ON f.TimeKey = t.TimeKey
    GROUP BY
        m.TierName,
        m.TierLevel,
        t.Year
) AS TierYearLoans
ORDER BY
    TierLevel,
    LoanYear;


-- ============================================================
-- Research Question 3:
-- From 2020 to 2025, how does completed loan activity vary
-- by the loan start day of the week?
-- ============================================================

USE green_grass_library_dw;

SELECT
    t.DayName,
    COUNT(*) AS TotalCompletedLoans,
    ROUND(
        COUNT(*) * 100.0 /
        (
            SELECT COUNT(*)
            FROM FactLoan AS f2
            JOIN DimTime AS t2
                ON f2.TimeKey = t2.TimeKey
            WHERE t2.Year BETWEEN 2020 AND 2025
        ),
        2
    ) AS PercentageOfAllLoans
FROM FactLoan AS f
JOIN DimTime AS t
    ON f.TimeKey = t.TimeKey
WHERE t.Year BETWEEN 2020 AND 2025
GROUP BY
    t.DayOfWeek,
    t.DayName
ORDER BY
    TotalCompletedLoans DESC;


-- ============================================================
-- Research Question 4:
-- From 2020 to 2025, how is completed loan-processing activity
-- distributed across staff departments?
-- ============================================================

USE green_grass_library_dw;

SELECT
    s.Department,
    COUNT(DISTINCT s.StaffKey) AS StaffWhoProcessedLoans,
    COUNT(*) AS TotalCompletedLoans,
    ROUND(
        COUNT(*) * 100.0 /
        (
            SELECT COUNT(*)
            FROM FactLoan AS f2
            JOIN DimTime AS t2
                ON f2.TimeKey = t2.TimeKey
            WHERE t2.Year BETWEEN 2020 AND 2025
        ),
        2
    ) AS PercentageOfAllLoans,
    ROUND(
        COUNT(*) * 1.0 /
        COUNT(DISTINCT s.StaffKey),
        2
    ) AS AverageLoansPerActiveStaff
FROM FactLoan AS f
JOIN DimStaff AS s
    ON f.StaffKey = s.StaffKey
JOIN DimTime AS t
    ON f.TimeKey = t.TimeKey
WHERE t.Year BETWEEN 2020 AND 2025
GROUP BY
    s.Department
ORDER BY
    TotalCompletedLoans DESC;


-- ============================================================
-- Research Question 5:
-- Based on book genre, which member tier is most likely to return a book late?
-- ============================================================

USE green_grass_library_dw;

SELECT
    mt.TierLevel,
    mt.TierName AS MemberTier,
    bg.Genre,
    COUNT(f.LoanKey) AS TotalLoans,
    SUM(
        CASE
            WHEN f.DaysLate > 0 THEN 1
            ELSE 0
        END
    ) AS LateLoans,
    CONCAT(
        ROUND(
            COALESCE(
                100.0 * SUM(
                    CASE
                        WHEN f.DaysLate > 0 THEN 1
                        ELSE 0
                    END
                ) / NULLIF(COUNT(f.LoanKey), 0),
                0
            ),
            2
        ),
        '%'
    ) AS LateReturnRate
FROM
    (SELECT DISTINCT TierLevel, TierName FROM DimMember) AS mt
CROSS JOIN
    (SELECT DISTINCT Genre FROM DimBookCopy) AS bg
LEFT JOIN FactLoan AS f
    ON f.MemberKey IN (
        SELECT MemberKey
        FROM DimMember
        WHERE TierLevel = mt.TierLevel
    )
    AND f.BookCopyKey IN (
        SELECT BookCopyKey
        FROM DimBookCopy
        WHERE Genre = bg.Genre
    )
GROUP BY
    mt.TierLevel,
    mt.TierName,
    bg.Genre
ORDER BY
    bg.Genre,
    mt.TierLevel;


-- ============================================================
-- Research Question 6:
-- Who is the employee (staff) of the year each year based on the amount of book loans handled?
-- ============================================================

USE green_grass_library_dw;

WITH StaffYearStats AS (
    SELECT
        dt.Year,
        ds.StaffID,
        ds.Name AS StaffName,
        COUNT(f.LoanKey) AS TotalLoansHandled
    FROM FactLoan AS f
    JOIN DimStaff AS ds
        ON f.StaffKey = ds.StaffKey
    JOIN DimTime AS dt
        ON f.TimeKey = dt.TimeKey
    GROUP BY
        dt.Year,
        ds.StaffID,
        ds.Name
),
RankedStaff AS (
    SELECT
        Year,
        StaffID,
        StaffName,
        TotalLoansHandled,
        RANK() OVER (
            PARTITION BY Year
            ORDER BY TotalLoansHandled DESC
        ) AS StaffRank
    FROM StaffYearStats
)
SELECT
    Year,
    StaffID,
    StaffName,
    TotalLoansHandled
FROM RankedStaff
WHERE StaffRank = 1
ORDER BY Year;


-- ============================================================
-- Research Question 7:
-- Loan Duration and Lateness by Calendar Month
-- ============================================================

USE green_grass_library_dw;

SELECT
    t.MonthNumber,
    t.MonthName,
    COUNT(*) AS TotalLoans,
    ROUND(AVG(f.LoanDurationDays), 2) AS AvgLoanDurationDays,
    ROUND(AVG(f.DaysLate), 2) AS AvgDaysLate
FROM FactLoan f
JOIN DimTime t ON f.TimeKey = t.TimeKey
GROUP BY t.MonthNumber, t.MonthName
ORDER BY t.MonthNumber;


-- ============================================================
-- Research Question 8:
-- Loan Duration and Late-Return Rate by Genre
-- ============================================================

USE green_grass_library_dw;

SELECT
    b.Genre,
    COUNT(*) AS TotalLoans,
    ROUND(AVG(f.LoanDurationDays), 2) AS AvgLoanDurationDays,
    ROUND(AVG(f.DaysLate), 2) AS AvgDaysLate,
    ROUND(
        SUM(CASE WHEN f.DaysLate > 0 THEN 1 ELSE 0 END) * 100.0 / COUNT(*),
        2
    ) AS LateReturnRatePercent
FROM FactLoan f
JOIN DimBookCopy b ON f.BookCopyKey = b.BookCopyKey
GROUP BY b.Genre
ORDER BY AvgLoanDurationDays DESC;
