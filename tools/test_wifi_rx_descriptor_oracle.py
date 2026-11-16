"""Validate terminal-report handling for the RX binary comparison."""

import pytest

from check_wifi_rx_descriptor_oracle import EXPECTED_CASES, EXPECTED_CHECKS, parse_result


def output(status="PASS", cases=EXPECTED_CASES, checks=EXPECTED_CHECKS,
           result=0, difference=0, fixture=0, side=1):
    return f"RXDESC RV32 {status} {cases:08x} {checks:08x} {result:08x} {difference:08x} {fixture:08x} {side:08x} \n"


def test_complete_report_passes():
    result = parse_result(output(), 0)
    assert result["passed"] and result["cases"] == EXPECTED_CASES
    assert result["checks"] == EXPECTED_CHECKS


@pytest.mark.parametrize("changes,exit_code", [
    ({"status": "FAIL"}, 0), ({"cases": EXPECTED_CASES - 1}, 0),
    ({"checks": EXPECTED_CHECKS - 1}, 0), ({"result": 1}, 0),
    ({"difference": 1}, 0), ({"fixture": 1}, 0), ({"side": 0}, 0), ({}, 1),
])
def test_inconsistent_report_does_not_pass(changes, exit_code):
    assert not parse_result(output(**changes), exit_code)["passed"]


@pytest.mark.parametrize("text", ["", "RXDESC RV32 PASS", "trap 255", output()[:50],
                                 output() + output(), output() + "RXDESC RV32 FAIL\n"])
def test_incomplete_report_is_explicit(text):
    result = parse_result(text, 0)
    assert not result["passed"] and result["status"] == "incomplete"
