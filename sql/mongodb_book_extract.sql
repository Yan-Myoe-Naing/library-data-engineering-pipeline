-- Extract one record for each book for the MongoDB Book collection

USE green_grass_library_oltp;

SELECT
    b.BookID,
    b.Title,
    b.Author,
    b.Genre,
    mt.TierName AS MinimumMembershipTier,

    (
        SELECT COUNT(*)
        FROM BookCopy AS bc
        WHERE bc.BookID = b.BookID
    ) AS TotalCopies,

    (
        SELECT COUNT(*)
        FROM BookCopy AS bc
        WHERE bc.BookID = b.BookID
          AND bc.Status = 'Lost'
    ) AS LostCopies,

    (
        SELECT COUNT(*)
        FROM Loan AS l
        WHERE l.BookID = b.BookID
    ) AS TotalLoanTransactions

FROM Book AS b

JOIN MembershipTier AS mt
    ON b.MinTierID = mt.TierID

ORDER BY b.BookID;
