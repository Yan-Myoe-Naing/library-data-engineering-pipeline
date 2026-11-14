-- ============================================================
-- Green Grass Library CA2 - Data warehouse loading
-- Source OLTP: green_grass_library_oltp
-- Target DW:   green_grass_library_dw
-- Only completed loans are loaded into FactLoan.
-- ============================================================
USE green_grass_library_dw;

-- ============================================================
-- Load member dimension
-- Membership tier attributes are denormalised into DimMember.
-- ============================================================
INSERT INTO DimMember (
    MemberID,
    Name,
    Gender,
    DOB,
    Occupation,
    RegistrationDate,
    TierName,
    TierLevel,
    BorrowLimit
)
SELECT
    m.MemberID,
    m.Name,
    m.Gender,
    m.DOB,
    m.Occupation,
    DATE(m.RegistrationDatetime),
    mt.TierName,
    mt.TierLevel,
    mt.BorrowLimit
FROM green_grass_library_oltp.Member AS m
JOIN green_grass_library_oltp.MembershipTier AS mt
    ON m.TierID = mt.TierID
ORDER BY m.MemberID;

-- ============================================================
-- Load physical book-copy dimension
-- One dimension row represents one BookID + CopySeqNo.
-- Current operational copy status is intentionally excluded.
-- ============================================================
INSERT INTO DimBookCopy (
    BookID,
    CopySeqNo,
    Title,
    Author,
    Genre,
    MinTierName,
    MinTierLevel
)
SELECT
    b.BookID,
    bc.CopySeqNo,
    b.Title,
    b.Author,
    b.Genre,
    mt.TierName,
    mt.TierLevel
FROM green_grass_library_oltp.Book AS b
JOIN green_grass_library_oltp.BookCopy AS bc
    ON b.BookID = bc.BookID
JOIN green_grass_library_oltp.MembershipTier AS mt
    ON b.MinTierID = mt.TierID
ORDER BY b.BookID, bc.CopySeqNo;

-- ============================================================
-- Load staff dimension
-- ============================================================
INSERT INTO DimStaff (
    StaffID,
    Name,
    Gender,
    EmploymentType,
    Department,
    StartDate
)
SELECT
    StaffID,
    Name,
    Gender,
    EmploymentType,
    Department,
    StartDate
FROM green_grass_library_oltp.Staff
ORDER BY StaffID;

-- ============================================================
-- Load a complete day-level date dimension
-- The generated range covers every loan date used by
-- completed loan transactions.
-- Four digit sets generate offsets from 0 to 9,999 days.
-- ============================================================
INSERT INTO DimTime (
    FullDate,
    DayName,
    DayOfWeek,
    DayOfMonth,
    IsWeekend,
    MonthName,
    MonthNumber,
    Quarter,
    Year
)
SELECT
    dates.FullDate,
    DAYNAME(dates.FullDate),
    WEEKDAY(dates.FullDate) + 1,
    DAY(dates.FullDate),
    CASE WHEN WEEKDAY(dates.FullDate) IN (5, 6) THEN 1 ELSE 0 END,
    MONTHNAME(dates.FullDate),
    MONTH(dates.FullDate),
    QUARTER(dates.FullDate),
    YEAR(dates.FullDate)
FROM (
    SELECT DATE_ADD(bounds.MinDate, INTERVAL numbers.DayOffset DAY) AS FullDate
    FROM (
        SELECT
            MIN(DATE(StartDatetime)) AS MinDate,
            MAX(DATE(StartDatetime)) AS MaxDate
        FROM green_grass_library_oltp.Loan
        WHERE ReturnDatetime IS NOT NULL
    ) AS bounds
    CROSS JOIN (
        SELECT
            ones.n
            + tens.n * 10
            + hundreds.n * 100
            + thousands.n * 1000 AS DayOffset
        FROM
            (SELECT 0 AS n UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL
             SELECT 3 UNION ALL SELECT 4 UNION ALL SELECT 5 UNION ALL
             SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL
             SELECT 9) AS ones
        CROSS JOIN
            (SELECT 0 AS n UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL
             SELECT 3 UNION ALL SELECT 4 UNION ALL SELECT 5 UNION ALL
             SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL
             SELECT 9) AS tens
        CROSS JOIN
            (SELECT 0 AS n UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL
             SELECT 3 UNION ALL SELECT 4 UNION ALL SELECT 5 UNION ALL
             SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL
             SELECT 9) AS hundreds
        CROSS JOIN
            (SELECT 0 AS n UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL
             SELECT 3 UNION ALL SELECT 4 UNION ALL SELECT 5 UNION ALL
             SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL
             SELECT 9) AS thousands
    ) AS numbers
    WHERE DATE_ADD(bounds.MinDate, INTERVAL numbers.DayOffset DAY)
          <= bounds.MaxDate
) AS dates
ORDER BY dates.FullDate;

-- ============================================================
-- Load completed loan facts
-- TimeKey represents the date on which the loan started.
-- ============================================================
INSERT INTO FactLoan (
    MemberKey,
    BookCopyKey,
    StaffKey,
    TimeKey,
    LoanDurationDays,
    DaysLate
)
SELECT
    dm.MemberKey,
    dbc.BookCopyKey,
    ds.StaffKey,
    loan_date.TimeKey,
    DATEDIFF(DATE(l.ReturnDatetime), DATE(l.StartDatetime)),
    CASE
        WHEN DATE(l.ReturnDatetime) > l.DueDate
        THEN DATEDIFF(DATE(l.ReturnDatetime), l.DueDate)
        ELSE 0
    END
FROM green_grass_library_oltp.Loan AS l
JOIN DimMember AS dm
    ON l.MemberID = dm.MemberID
JOIN DimBookCopy AS dbc
    ON l.BookID = dbc.BookID
   AND l.CopySeqNo = dbc.CopySeqNo
JOIN DimStaff AS ds
    ON l.StaffID = ds.StaffID
JOIN DimTime AS loan_date
    ON DATE(l.StartDatetime) = loan_date.FullDate
WHERE l.ReturnDatetime IS NOT NULL
ORDER BY l.StartDatetime, l.MemberID, l.BookID, l.CopySeqNo;

-- ============================================================
-- Verification
-- ============================================================
SELECT 'DimMember' AS TableName, COUNT(*) AS RowCount FROM DimMember
UNION ALL
SELECT 'DimBookCopy', COUNT(*) FROM DimBookCopy
UNION ALL
SELECT 'DimStaff', COUNT(*) FROM DimStaff
UNION ALL
SELECT 'DimTime', COUNT(*) FROM DimTime
UNION ALL
SELECT 'FactLoan', COUNT(*) FROM FactLoan;

-- Expected counts for the current cleaned source:
-- DimMember:   301
-- DimBookCopy: 1265
-- DimStaff:    51
-- DimTime:     2192 (2020-01-01 through 2025-12-31)
-- FactLoan:    12343 completed loans

-- Source-to-target completed-loan reconciliation.
SELECT
    (SELECT COUNT(*)
     FROM green_grass_library_oltp.Loan
     WHERE ReturnDatetime IS NOT NULL) AS OLTPCompletedLoans,
    (SELECT COUNT(*)
     FROM FactLoan) AS DWFactRows;

-- Measure reconciliation. Expected values for the current source:
-- TotalLoanDurationDays = 108801
-- TotalLateLoans        = 1045
-- TotalDaysLate         = 10924
SELECT
    COUNT(*) AS TotalLoans,
    SUM(LoanDurationDays) AS TotalLoanDurationDays,
    SUM(
        CASE
            WHEN DaysLate > 0 THEN 1
            ELSE 0
        END
    ) AS TotalLateLoans,
    SUM(DaysLate) AS TotalDaysLate
FROM FactLoan;


SELECT
    MIN(FullDate) AS EarliestDate,
    MAX(FullDate) AS LatestDate,
    COUNT(*) AS TotalDates
FROM DimTime;

-- Each of these missing-key checks should return 0.
SELECT COUNT(*) AS MissingMemberKeys
FROM FactLoan f
LEFT JOIN DimMember d ON f.MemberKey = d.MemberKey
WHERE d.MemberKey IS NULL;

SELECT COUNT(*) AS MissingBookCopyKeys
FROM FactLoan f
LEFT JOIN DimBookCopy d ON f.BookCopyKey = d.BookCopyKey
WHERE d.BookCopyKey IS NULL;

SELECT COUNT(*) AS MissingStaffKeys
FROM FactLoan f
LEFT JOIN DimStaff d ON f.StaffKey = d.StaffKey
WHERE d.StaffKey IS NULL;

SELECT COUNT(*) AS MissingTimeKeys
FROM FactLoan f
LEFT JOIN DimTime d ON f.TimeKey = d.TimeKey
WHERE d.TimeKey IS NULL;
