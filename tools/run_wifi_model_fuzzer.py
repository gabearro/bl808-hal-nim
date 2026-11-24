"""Run the deterministic BL808 Wi-Fi model fuzzer without allowing skips."""

import argparse
import os
from pathlib import Path
import shutil
import sys

import pytest


class RequiredCases:
    def __init__(self) -> None:
        self.passed: set[str] = set()
        self.skipped: set[str] = set()

    def pytest_runtest_logreport(self, report: pytest.TestReport) -> None:
        if report.skipped:
            self.skipped.add(report.nodeid)
        elif report.passed and report.when == "call":
            self.passed.add(report.nodeid)

    def pytest_collectreport(self, report: pytest.CollectReport) -> None:
        if report.skipped:
            self.skipped.add(report.nodeid)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seed", type=int, default=808)
    parser.add_argument("--steps", type=int, default=256)
    args = parser.parse_args()
    if args.seed < 0 or args.steps < 1:
        parser.error("seed must be nonnegative and steps must be positive")
    if shutil.which("nim") is None:
        parser.error("Nim is required; no fuzz cases were run")
    os.environ["BL808_WIFI_MODEL_SEED"] = str(args.seed)
    os.environ["BL808_WIFI_MODEL_STEPS"] = str(args.steps)
    tools = Path(__file__).resolve().parent
    files = [str(tools / f"test_wifi_{domain}_model_fuzzer.py")
             for domain in ("queue", "scan", "timer", "loss", "cleanup", "ieee2012")]
    required = RequiredCases()
    print(f"BL808 Wi-Fi model seed={args.seed} steps={args.steps}", flush=True)
    result = pytest.main(["-q", "-p", "no:cacheprovider", *files], plugins=[required])
    if result != pytest.ExitCode.OK:
        return int(result)
    for file in files:
        if not any(Path(node.split("::", 1)[0]).name == Path(file).name
                   for node in required.passed):
            print(f"No passing cases from {file}", file=sys.stderr)
            return 1
    if required.skipped:
        print("Required cases skipped: " + ", ".join(sorted(required.skipped)),
              file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
