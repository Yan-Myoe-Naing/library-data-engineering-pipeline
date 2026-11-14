"""Build Green Grass Library Silver-layer Parquet datasets from Bronze files.

The rules mirror the cleaning used for the CA2 OLTP/DW load while keeping the
transformation reproducible. Bronze files are read-only inputs and are never
modified. Run from any directory with:

    python build_silver.py
"""

from __future__ import annotations

import json
import sys
from datetime import datetime, timezone
from pathlib import Path

# Use the project-local Parquet dependency when present.
_SCRIPT_ROOT = Path(__file__).resolve().parent
_LOCAL_DEPS = _SCRIPT_ROOT / ".python_deps"
if _LOCAL_DEPS.exists():
    sys.path.insert(0, str(_LOCAL_DEPS))

import pandas as pd
from docx import Document


ROOT = _SCRIPT_ROOT
BRONZE = ROOT / "Bronze"
SILVER = ROOT / "Silver"
QUARANTINE = ROOT / "Quarantine"
REPORT = ROOT / "silver_validation_report.json"

DATA_FILE = BRONZE / "data.xlsx"
STAFF_FILE = BRONZE / "staff.csv"
TIER_FILE = BRONZE / "MembershipTier.docx"

GENDER_MAP = {"Male": "M", "Female": "F", "M": "M", "F": "F"}
COPY_STATUS_MAP = {"Availble": "Available"}
VALID_COPY_STATUSES = {"Available", "On Loan", "Lost"}
VALID_LOAN_STATUSES = {"Returned", "On Loan", "Lost"}


def clean_text(df: pd.DataFrame) -> pd.DataFrame:
    """Trim surrounding whitespace without replacing genuine null values."""
    result = df.copy()
    for column in result.select_dtypes(include=["object", "string"]).columns:
        result[column] = result[column].astype("string").str.strip()
    return result


def parse_datetime(series: pd.Series) -> pd.Series:
    """Parse mixed date-only and date-time source values without coercion."""
    return pd.to_datetime(series, format="mixed", errors="raise")


def require_columns(df: pd.DataFrame, required: list[str], name: str) -> None:
    missing = sorted(set(required) - set(df.columns))
    if missing:
        raise ValueError(f"{name}: missing required columns: {missing}")


def require_no_nulls(df: pd.DataFrame, columns: list[str], name: str) -> None:
    counts = df[columns].isna().sum()
    invalid = counts[counts > 0]
    if not invalid.empty:
        raise ValueError(f"{name}: unexpected nulls: {invalid.to_dict()}")


def require_unique(df: pd.DataFrame, columns: list[str], name: str) -> None:
    count = int(df.duplicated(subset=columns, keep=False).sum())
    if count:
        raise ValueError(f"{name}: {count} rows have duplicate key {columns}")


def extract_tiers() -> pd.DataFrame:
    document = Document(TIER_FILE)
    if not document.tables:
        raise ValueError("MembershipTier.docx contains no table")
    rows = [[cell.text.strip() for cell in row.cells] for row in document.tables[0].rows]
    tiers = pd.DataFrame(rows[1:], columns=rows[0])
    tiers = clean_text(tiers)
    tiers["TierLevel"] = pd.to_numeric(tiers["TierLevel"], errors="raise").astype("int64")
    tiers["BorrowLimit"] = pd.to_numeric(tiers["BorrowLimit"], errors="raise").astype("int64")
    # The narrative business policy specifies the current limits as 10/20/30.
    # Apply the same correction used by the OLTP/DW cleaning process; retain the
    # SuperAdmin testing record unchanged.
    tier_limits = {"Basic": 10, "Advanced": 20, "Premium": 30}
    tiers["BorrowLimit"] = tiers.apply(
        lambda row: tier_limits.get(row["TierName"], row["BorrowLimit"]), axis=1
    ).astype("int64")
    return tiers


def load_and_clean() -> tuple[dict[str, pd.DataFrame], dict[str, pd.DataFrame], dict]:
    members = clean_text(pd.read_excel(DATA_FILE, sheet_name="Members"))
    books = clean_text(pd.read_excel(DATA_FILE, sheet_name="Books"))
    copies = clean_text(pd.read_excel(DATA_FILE, sheet_name="BookCopies"))
    loans_raw = pd.read_excel(DATA_FILE, sheet_name="Loans")
    staff = clean_text(pd.read_csv(STAFF_FILE))
    tiers = extract_tiers()

    bronze_counts = {
        "members": len(members),
        "books": len(books),
        "book_copies": len(copies),
        "loans": len(loans_raw),
        "staff": len(staff),
        "membership_tiers": len(tiers),
    }

    # Members: match the OLTP CHAR(1) gender representation.
    members["Gender"] = members["Gender"].map(GENDER_MAP).astype("string")
    members["TierID"] = members["TierID"].replace({"T00001": "T0001"})
    members["DateOfBirth"] = parse_datetime(members["DateOfBirth"]).dt.date
    members["RegistrationDatetime"] = parse_datetime(members["RegistrationDatetime"])
    # Occupation is optional and intentionally remains nullable.

    # Book copies: correct known spelling issue and the outstanding-copy state.
    copies["CopySeqNo"] = pd.to_numeric(copies["CopySeqNo"], errors="raise").astype("int64")
    copies["Status"] = copies["Status"].replace(COPY_STATUS_MAP)
    copies.loc[
        (copies["BookID"] == "B00489") & (copies["CopySeqNo"] == 2), "Status"
    ] = "On Loan"

    # Staff: match the DW-cleaned naming/types and remove time from StartDate.
    staff["Gender"] = staff["Gender"].map(GENDER_MAP).astype("string")
    staff["StartDate"] = parse_datetime(staff.pop("StartDatetime")).dt.date
    staff["DOB"] = parse_datetime(staff["DOB"]).dt.date
    staff = staff[
        [
            "StaffID", "StaffName", "Gender", "Contact", "EmploymentType",
            "StartDate", "Department", "DOB",
        ]
    ]

    # Loans: six shifted statuses appear in Unnamed: 8. Restore them before
    # dropping spreadsheet analysis/residue columns.
    unnamed = [c for c in loans_raw.columns if str(c).startswith("Unnamed:")]
    if "Unnamed: 8" in loans_raw.columns:
        shifted_status = loans_raw["LoanStatus"].isna() & loans_raw["Unnamed: 8"].notna()
        loans_raw.loc[shifted_status, "LoanStatus"] = loans_raw.loc[
            shifted_status, "Unnamed: 8"
        ]

    loans = clean_text(loans_raw.drop(columns=unnamed))
    loans["CopySeqNo"] = pd.to_numeric(loans["CopySeqNo"], errors="raise").astype("int64")
    loans["LoanDatetime"] = parse_datetime(loans["LoanDatetime"])
    loans["DueDate"] = parse_datetime(loans["DueDate"]).dt.date
    loans["ReturnDatetime"] = pd.to_datetime(
        loans["ReturnDatetime"], format="mixed", errors="coerce"
    )

    # A missing return date represents the one valid outstanding loan.
    outstanding = loans["ReturnDatetime"].isna() & loans["LoanStatus"].isna()
    loans.loc[outstanding, "LoanStatus"] = "On Loan"

    # Quarantine the known corrupted record rather than silently deleting it.
    # It references non-existent StaffID S0101 and CopySeqNo 8, and its due date
    # precedes the loan date.
    invalid_known = (
        (loans["MemberID"] == "M0107")
        & (loans["BookID"] == "B00153")
        & (loans["CopySeqNo"] == 8)
        & (loans["LoanDatetime"] == pd.Timestamp("2024-07-04 11:38:15"))
    )
    quarantined_loans = loans.loc[invalid_known].copy()
    loans = loans.loc[~invalid_known].copy()

    datasets = {
        "members": members,
        "books": books,
        "book_copies": copies,
        "loans": loans,
        "staff": staff,
        "membership_tiers": tiers,
    }
    quarantine = {"loans_invalid_records": quarantined_loans}
    metrics = {
        "bronze_counts": bronze_counts,
        "rules_applied": {
            "member_gender_standardised": int(len(members)),
            "member_tier_id_corrected": 1,
            "membership_borrow_limits_corrected": 3,
            "staff_gender_standardised": int(len(staff)),
            "book_copy_status_spelling_corrected": 4,
            "book_copy_marked_on_loan": 1,
            "shifted_loan_statuses_restored": int(
                (loans_raw.get("Unnamed: 8", pd.Series(dtype="object")).notna()
                 & loans_raw["LoanStatus"].notna()).sum()
            ),
            "outstanding_loan_status_derived": int(outstanding.sum()),
            "loan_rows_quarantined": int(invalid_known.sum()),
            "unnamed_columns_removed": len(unnamed),
        },
    }
    return datasets, quarantine, metrics


def validate(d: dict[str, pd.DataFrame], metrics: dict) -> dict:
    members, books = d["members"], d["books"]
    copies, loans = d["book_copies"], d["loans"]
    staff, tiers = d["staff"], d["membership_tiers"]

    required = {
        "members": ["MemberID", "FullName", "ContactNo", "Email", "DateOfBirth", "Gender", "RegistrationDatetime", "TierID"],
        "books": ["BookID", "Title", "Author", "Genre", "MinTierID"],
        "book_copies": ["BookID", "CopySeqNo", "Status"],
        "loans": ["MemberID", "BookID", "CopySeqNo", "StaffID", "LoanDatetime", "DueDate", "LoanStatus"],
        "staff": ["StaffID", "StaffName", "Gender", "Contact", "EmploymentType", "StartDate", "Department", "DOB"],
        "membership_tiers": ["TierID", "TierName", "TierLevel", "BorrowLimit"],
    }
    for name, columns in required.items():
        require_columns(d[name], columns, name)
        require_no_nulls(d[name], columns, name)

    require_unique(members, ["MemberID"], "members")
    require_unique(books, ["BookID"], "books")
    require_unique(copies, ["BookID", "CopySeqNo"], "book_copies")
    require_unique(loans, ["MemberID", "BookID", "CopySeqNo", "LoanDatetime"], "loans")
    require_unique(staff, ["StaffID"], "staff")
    require_unique(tiers, ["TierID"], "membership_tiers")

    if not set(members["Gender"]) <= {"M", "F"} or not set(staff["Gender"]) <= {"M", "F"}:
        raise ValueError("Unexpected gender value after standardisation")
    if not set(copies["Status"]) <= VALID_COPY_STATUSES:
        raise ValueError(f"Unexpected book-copy status: {set(copies['Status']) - VALID_COPY_STATUSES}")
    if not set(loans["LoanStatus"]) <= VALID_LOAN_STATUSES:
        raise ValueError(f"Unexpected loan status: {set(loans['LoanStatus']) - VALID_LOAN_STATUSES}")

    fk_checks = {
        "members_to_tiers": int((~members["TierID"].isin(tiers["TierID"])).sum()),
        "books_to_tiers": int((~books["MinTierID"].isin(tiers["TierID"])).sum()),
        "copies_to_books": int((~copies["BookID"].isin(books["BookID"])).sum()),
        "loans_to_members": int((~loans["MemberID"].isin(members["MemberID"])).sum()),
        "loans_to_staff": int((~loans["StaffID"].isin(staff["StaffID"])).sum()),
    }
    valid_copy_keys = set(zip(copies["BookID"], copies["CopySeqNo"]))
    fk_checks["loans_to_book_copies"] = int(
        sum((book_id, copy_no) not in valid_copy_keys for book_id, copy_no in zip(loans["BookID"], loans["CopySeqNo"]))
    )
    if any(fk_checks.values()):
        raise ValueError(f"Foreign-key validation failed: {fk_checks}")

    due_mismatch = pd.to_datetime(loans["DueDate"]) != (
        loans["LoanDatetime"].dt.normalize() + pd.Timedelta(days=14)
    )
    if int(due_mismatch.sum()):
        raise ValueError(f"{int(due_mismatch.sum())} loans do not have a 14-day due date")

    metrics.update(
        {
            "silver_counts": {name: int(len(frame)) for name, frame in d.items()},
            "foreign_key_failures": fk_checks,
            "completed_loans": int(loans["ReturnDatetime"].notna().sum()),
            "outstanding_loans": int(loans["ReturnDatetime"].isna().sum()),
            "optional_missing_occupations": int(members["Occupation"].isna().sum()),
            "validation_status": "PASS",
        }
    )
    return metrics


def write_outputs(datasets: dict[str, pd.DataFrame], quarantine: dict[str, pd.DataFrame], metrics: dict) -> None:
    SILVER.mkdir(parents=True, exist_ok=True)
    QUARANTINE.mkdir(parents=True, exist_ok=True)

    for name, frame in datasets.items():
        frame.to_parquet(SILVER / f"{name}.parquet", index=False, engine="pyarrow")
    for name, frame in quarantine.items():
        if not frame.empty:
            frame.to_parquet(QUARANTINE / f"{name}.parquet", index=False, engine="pyarrow")

    metrics["generated_at_utc"] = datetime.now(timezone.utc).isoformat()
    metrics["silver_files"] = sorted(path.name for path in SILVER.glob("*.parquet"))
    REPORT.write_text(json.dumps(metrics, indent=2), encoding="utf-8")


def verify_written_files(expected: dict[str, pd.DataFrame]) -> None:
    for name, source in expected.items():
        path = SILVER / f"{name}.parquet"
        restored = pd.read_parquet(path, engine="pyarrow")
        if len(restored) != len(source) or list(restored.columns) != list(source.columns):
            raise ValueError(f"Written-file verification failed for {path.name}")


def main() -> None:
    for source in (DATA_FILE, STAFF_FILE, TIER_FILE):
        if not source.exists():
            raise FileNotFoundError(f"Required Bronze source not found: {source}")
    datasets, quarantine, metrics = load_and_clean()
    metrics = validate(datasets, metrics)
    write_outputs(datasets, quarantine, metrics)
    verify_written_files(datasets)
    print(json.dumps(metrics, indent=2))


if __name__ == "__main__":
    main()
