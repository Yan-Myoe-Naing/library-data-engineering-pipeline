-- ============================================================
-- Green Grass Library CA2 - Data Warehouse
-- Grain: One completed loan transaction for one physical book copy
-- ============================================================

DROP DATABASE IF EXISTS green_grass_library_dw;

CREATE DATABASE green_grass_library_dw;
USE green_grass_library_dw;


-- ============================================================
-- Member Dimension
-- ============================================================

CREATE TABLE DimMember (
    MemberKey INT AUTO_INCREMENT PRIMARY KEY,
    MemberID CHAR(10) NOT NULL,
    Name VARCHAR(100) NOT NULL,
    Gender CHAR(1) NOT NULL,
    DOB DATE NOT NULL,
    Occupation VARCHAR(50),
    RegistrationDate DATE NOT NULL,
    TierName VARCHAR(20) NOT NULL,
    TierLevel INT NOT NULL,
    BorrowLimit INT NOT NULL,

    UNIQUE (MemberID)
);


-- ============================================================
-- Book Copy Dimension
-- One row represents one physical copy of a book
-- ============================================================

CREATE TABLE DimBookCopy (
    BookCopyKey INT AUTO_INCREMENT PRIMARY KEY,
    BookID CHAR(10) NOT NULL,
    CopySeqNo INT NOT NULL,
    Title VARCHAR(200) NOT NULL,
    Author VARCHAR(100) NOT NULL,
    Genre VARCHAR(50) NOT NULL,
    MinTierName VARCHAR(20) NOT NULL,
    MinTierLevel INT NOT NULL,

    UNIQUE (BookID, CopySeqNo)
);


-- ============================================================
-- Staff Dimension
-- ============================================================

CREATE TABLE DimStaff (
    StaffKey INT AUTO_INCREMENT PRIMARY KEY,
    StaffID CHAR(10) NOT NULL,
    Name VARCHAR(100) NOT NULL,
    Gender CHAR(1) NOT NULL,
    EmploymentType VARCHAR(20) NOT NULL,
    Department VARCHAR(50) NOT NULL,
    StartDate DATE NOT NULL,

    UNIQUE (StaffID)
);


-- ============================================================
-- Time Dimension
-- Day-level granularity
-- ============================================================

CREATE TABLE DimTime (
    TimeKey INT AUTO_INCREMENT PRIMARY KEY,
    FullDate DATE NOT NULL,
    DayName VARCHAR(10) NOT NULL,
    DayOfWeek INT NOT NULL,
    DayOfMonth INT NOT NULL,
    IsWeekend BOOLEAN NOT NULL,
    MonthName VARCHAR(10) NOT NULL,
    MonthNumber INT NOT NULL,
    Quarter INT NOT NULL,
    Year INT NOT NULL,

    UNIQUE (FullDate)
);


-- ============================================================
-- Loan Fact Table
-- One row represents one completed loan for one physical book copy
-- ============================================================

CREATE TABLE FactLoan (
    LoanKey INT AUTO_INCREMENT PRIMARY KEY,

    -- Dimension foreign keys
    MemberKey INT NOT NULL,
    BookCopyKey INT NOT NULL,
    StaffKey INT NOT NULL,
    TimeKey INT NOT NULL,

    -- Measures
    LoanDurationDays INT NOT NULL,
    DaysLate INT NOT NULL,

    FOREIGN KEY (MemberKey)
        REFERENCES DimMember(MemberKey),

    FOREIGN KEY (BookCopyKey)
        REFERENCES DimBookCopy(BookCopyKey),

    FOREIGN KEY (StaffKey)
        REFERENCES DimStaff(StaffKey),

    FOREIGN KEY (TimeKey)
        REFERENCES DimTime(TimeKey)
);
