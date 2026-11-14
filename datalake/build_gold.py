"""Build the Gold completed-loan analytical dataset from Silver Parquet files."""

from __future__ import annotations

import json
import sys
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent
LOCAL_DEPS = ROOT / ".python_deps"
if LOCAL_DEPS.exists():
    sys.path.insert(0, str(LOCAL_DEPS))

import pandas as pd


SILVER = ROOT / "Silver"
GOLD = ROOT / "Gold"
OUTPUT = GOLD / "completed_loan_analytics.parquet"
REPORT = ROOT / "gold_validation_report.json"

EXPECTED_ROWS = 12_343
EXPECTED_DURATION_DAYS = 108_801
EXPECTED_DAYS_LATE = 10_924


def read(name: str) -> pd.DataFrame:
    path = SILVER / f"{name}.parquet"
    if not path.exists():
        raise FileNotFoundError(f"Required Silver dataset not found: {path}")
    return pd.read_parquet(path, engine="pyarrow")


def build_gold() -> pd.DataFrame:
    loans = read("loans")
    members = read("members")
    tiers = read("membership_tiers")
    books = read("books")
    copies = read("book_copies")
    staff = read("staff")

    # Gold grain: one row per completed loan.
    gold = loans.loc[loans["ReturnDatetime"].notna()].copy()

    member_attributes = members[
        ["MemberID", "Gender", "Occupation", "TierID"]
    ].rename(columns={"Gender": "MemberGender"})
    member_tiers = tiers.rename(
        columns={
            "TierID": "TierID",
            "TierName": "MemberTierName",
            "TierLevel": "MemberTierLevel",
            "BorrowLimit": "MemberBorrowLimit",
        }
    )[["TierID", "MemberTierName", "MemberTierLevel", "MemberBorrowLimit"]]
    member_attributes = member_attributes.merge(member_tiers, on="TierID", validate="many_to_one")
    member_attributes = member_attributes.drop(columns=["TierID"])

    minimum_tiers = tiers.rename(
        columns={
            "TierID": "MinTierID",
            "TierName": "MinimumTierName",
            "TierLevel": "MinimumTierLevel",
        }
    )[["MinTierID", "MinimumTierName", "MinimumTierLevel"]]
    book_attributes = books.merge(minimum_tiers, on="MinTierID", validate="many_to_one")
    book_attributes = book_attributes.drop(columns=["MinTierID"])

    copy_attributes = copies.rename(columns={"Status": "CopyStatus"})
    staff_attributes = staff[
        ["StaffID", "Gender", "EmploymentType", "Department"]
    ].rename(columns={"Gender": "StaffGender"})

    gold = gold.merge(member_attributes, on="MemberID", validate="many_to_one")
    gold = gold.merge(book_attributes, on="BookID", validate="many_to_one")
    gold = gold.merge(copy_attributes, on=["BookID", "CopySeqNo"], validate="many_to_one")
    gold = gold.merge(staff_attributes, on="StaffID", validate="many_to_one")

    # The only two derived measurements requested by the student.
    return_dates = gold["ReturnDatetime"].dt.normalize()
    loan_dates = gold["LoanDatetime"].dt.normalize()
    due_dates = pd.to_datetime(gold["DueDate"])
    gold["LoanDurationDays"] = (return_dates - loan_dates).dt.days.astype("int64")
    gold["DaysLate"] = (return_dates - due_dates).dt.days.clip(lower=0).astype("int64")

    # Reusable time dimensions, not measurements.
    gold["LoanDate"] = gold["LoanDatetime"].dt.date
    gold["LoanYear"] = gold["LoanDatetime"].dt.year.astype("int16")
    gold["LoanQuarter"] = gold["LoanDatetime"].dt.quarter.astype("int8")
    gold["LoanMonth"] = gold["LoanDatetime"].dt.month.astype("int8")
    gold["LoanMonthName"] = gold["LoanDatetime"].dt.month_name().astype("string")
    gold["LoanDayName"] = gold["LoanDatetime"].dt.day_name().astype("string")

    columns = [
        "MemberID", "BookID", "CopySeqNo", "StaffID",
        "LoanDatetime", "DueDate", "ReturnDatetime",
        "MemberGender", "Occupation", "MemberTierName", "MemberTierLevel", "MemberBorrowLimit",
        "Title", "Author", "Genre", "MinimumTierName", "MinimumTierLevel", "CopyStatus",
        "StaffGender", "EmploymentType", "Department",
        "LoanDate", "LoanYear", "LoanQuarter", "LoanMonth", "LoanMonthName", "LoanDayName",
        "LoanDurationDays", "DaysLate",
    ]
    return gold[columns].sort_values(
        ["LoanDatetime", "MemberID", "BookID", "CopySeqNo"]
    ).reset_index(drop=True)


def validate(gold: pd.DataFrame) -> dict:
    key = ["MemberID", "BookID", "CopySeqNo", "LoanDatetime"]
    duplicate_keys = int(gold.duplicated(key, keep=False).sum())
    required = [
        "MemberID", "BookID", "StaffID", "Genre", "MemberTierName",
        "MinimumTierName", "EmploymentType", "Department",
        "LoanDurationDays", "DaysLate",
    ]
    required_nulls = {c: int(gold[c].isna().sum()) for c in required if gold[c].isna().any()}
    metrics = {
        "gold_rows": int(len(gold)),
        "duplicate_transaction_keys": duplicate_keys,
        "required_field_nulls": required_nulls,
        "total_loan_duration_days": int(gold["LoanDurationDays"].sum()),
        "total_days_late": int(gold["DaysLate"].sum()),
        "late_loan_count_derived_at_query_time": int((gold["DaysLate"] > 0).sum()),
        "minimum_loan_duration_days": int(gold["LoanDurationDays"].min()),
        "maximum_loan_duration_days": int(gold["LoanDurationDays"].max()),
    }
    if metrics["gold_rows"] != EXPECTED_ROWS:
        raise ValueError(f"Expected {EXPECTED_ROWS} Gold rows, got {metrics['gold_rows']}")
    if duplicate_keys or required_nulls:
        raise ValueError(f"Gold key/null validation failed: {metrics}")
    if metrics["total_loan_duration_days"] != EXPECTED_DURATION_DAYS:
        raise ValueError("LoanDurationDays total does not reconcile with DW")
    if metrics["total_days_late"] != EXPECTED_DAYS_LATE:
        raise ValueError("DaysLate total does not reconcile with DW")
    metrics["validation_status"] = "PASS"
    return metrics


def main() -> None:
    gold = build_gold()
    metrics = validate(gold)
    GOLD.mkdir(parents=True, exist_ok=True)
    gold.to_parquet(OUTPUT, index=False, engine="pyarrow")

    restored = pd.read_parquet(OUTPUT, engine="pyarrow")
    if len(restored) != len(gold) or list(restored.columns) != list(gold.columns):
        raise ValueError("Written Gold Parquet verification failed")

    metrics.update(
        {
            "output_file": OUTPUT.name,
            "output_columns": list(gold.columns),
            "generated_at_utc": datetime.now(timezone.utc).isoformat(),
        }
    )
    REPORT.write_text(json.dumps(metrics, indent=2), encoding="utf-8")
    print(json.dumps(metrics, indent=2))


if __name__ == "__main__":
    main()
