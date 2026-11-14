"""Run only the DuckDB queries demonstrated in the individual report."""

from pathlib import Path

import duckdb


BASE = Path(__file__).resolve().parent
QUERY_FILE = BASE / "report_queries.sql"
OUTPUT_FILE = BASE / "report_query_results.txt"


def main() -> None:
    sql_text = QUERY_FILE.read_text(encoding="utf-8")
    queries = [statement.strip() for statement in sql_text.split(";") if statement.strip()]
    labels = [
        "SILVER LOANS SAMPLE",
        "SILVER PARQUET COLUMN METADATA",
        "MOST POPULAR GENRE BY YEAR",
    ]
    output_blocks: list[str] = []

    connection = duckdb.connect()
    try:
        for label, query in zip(labels, queries, strict=True):
            result = connection.execute(query)
            columns = [item[0] for item in result.description]
            rows = result.fetchall()
            output_blocks.append(label)
            output_blocks.append(" | ".join(columns))
            output_blocks.extend(" | ".join(str(value) for value in row) for row in rows)
            output_blocks.append("")
    finally:
        connection.close()

    OUTPUT_FILE.write_text("\n".join(output_blocks), encoding="utf-8")
    print(f"Executed {len(queries)} report queries; results saved to {OUTPUT_FILE.name}")


if __name__ == "__main__":
    main()
