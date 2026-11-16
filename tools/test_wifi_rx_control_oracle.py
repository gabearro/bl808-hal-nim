"""Reject partial or inconsistent normal RX-control comparison reports."""

import pytest

from check_wifi_rx_control_oracle import EXPECTED_CASES, EXPECTED_CHECKS, parse_result


LAST_INPUTS = [11, 2, 2, 9, 2, 2, 2, 16]


def output(status="PASS", cases=EXPECTED_CASES, checks=EXPECTED_CHECKS,
           result=0, difference=0, fixture=0, inputs=None):
    values = [cases, checks, result, difference, fixture,
              *(LAST_INPUTS if inputs is None else inputs)]
    return "RXCONTROL RV32 " + status + " " + " ".join(f"{n:08x}" for n in values) + " \n"


def test_complete_report_passes():
    result = parse_result(output(), 0)
    assert result["passed"] and result["cases"] == EXPECTED_CASES


@pytest.mark.parametrize("changes,exit_code", [
    ({"status": "FAIL"}, 0), ({"cases": EXPECTED_CASES - 1}, 0),
    ({"checks": EXPECTED_CHECKS - 1}, 0), ({"result": 1}, 0),
    ({"difference": 1}, 0), ({"fixture": 1}, 0), ({}, 1),
    *[({"inputs": [value + (i == bad) for i, value in enumerate(LAST_INPUTS)]}, 0)
      for bad in range(8)],
])
def test_inconsistent_report_does_not_pass(changes, exit_code):
    assert not parse_result(output(**changes), exit_code)["passed"]


@pytest.mark.parametrize("text", ["", "RXCONTROL RV32 PASS", "trap 255", output()[:50],
                                 output() + output(), output() + "RXCONTROL RV32 FAIL\n",
                                 output().replace(" \n", " extra\n")])
def test_incomplete_report_is_explicit(text):
    result = parse_result(text, 0)
    assert not result["passed"] and result["status"] == "incomplete"
