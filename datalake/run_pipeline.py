"""Run the complete Green Grass Library data-lake pipeline.

Execution order:
    Bronze sources -> Silver/Quarantine -> Gold -> report demonstrations

The detailed transformations remain in separate layer modules so that each
stage can be tested independently, while this file provides one command for
the complete submission demonstration.
"""

from build_silver import main as build_silver
from build_gold import main as build_gold
from run_report_queries import main as run_report_queries


def main() -> None:
    print("[1/3] Building Silver and Quarantine from Bronze...")
    build_silver()

    print("\n[2/3] Building Gold from Silver...")
    build_gold()

    print("\n[3/3] Running the Silver and Gold queries shown in the report...")
    run_report_queries()

    print("\nPipeline completed successfully.")


if __name__ == "__main__":
    main()
