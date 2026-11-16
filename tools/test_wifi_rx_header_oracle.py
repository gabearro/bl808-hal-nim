"""Keep the restricted header probe from accepting incomplete reports."""

import pytest

from check_wifi_rx_header_oracle import (
    CATEGORIES, EXPECTED_CHECKS, EXPECTED_HEADERS, EXPECTED_PROTECTED, parse_result,
)


def output(status="PASS", headers=EXPECTED_HEADERS, protected=EXPECTED_PROTECTED,
           checks=EXPECTED_CHECKS, result=0, difference=0, fixture=0, categories=None):
    values = [headers, protected, checks, result, difference, fixture,
              *(CATEGORIES if categories is None else categories)]
    return "RXHEADER RV32 " + status + " " + " ".join(f"{n:08x}" for n in values) + " \n"


def test_complete_report_passes():
    assert parse_result(output(), 0)["passed"]


@pytest.mark.parametrize("changes,exit_code", [
    ({"status": "FAIL"}, 0), ({"headers": EXPECTED_HEADERS - 1}, 0),
    ({"protected": EXPECTED_PROTECTED - 1}, 0), ({"checks": EXPECTED_CHECKS - 1}, 0),
    ({"result": 1}, 0), ({"difference": 1}, 0), ({"fixture": 1}, 0), ({}, 1),
    *[({"categories": [value + (i == bad) for i, value in enumerate(CATEGORIES)]}, 0)
      for bad in range(6)],
])
def test_inconsistent_report_does_not_pass(changes, exit_code):
    assert not parse_result(output(**changes), exit_code)["passed"]


@pytest.mark.parametrize("text", ["", "RXHEADER RV32 PASS", "trap 255", output()[:50],
                                 output() + output(), output() + "RXHEADER RV32 FAIL\n",
                                 output().replace(" \n", " extra\n")])
def test_incomplete_report_is_explicit(text):
    result = parse_result(text, 0)
    assert not result["passed"] and result["status"] == "incomplete"
