"""Reject incomplete decoder comparisons and report unsupported instructions."""

import pytest

from check_wifi_rx_protected_oracle import (
    EXPECTED_CHECKS, EXPECTED_INSTRUCTIONS, EXPECTED_MATRIX, EXPECTED_WIRE, parse_result,
)


LAST_INPUTS = [28, 1, 26, 3, 3, 1, 255, 8]


def output(status="PASS", matrix=EXPECTED_MATRIX, wire=EXPECTED_WIRE, checks=EXPECTED_CHECKS,
           instructions=EXPECTED_INSTRUCTIONS, result=0, difference=0, inputs=None):
    values = [matrix, wire, checks, instructions, result, difference,
              *(LAST_INPUTS if inputs is None else inputs)]
    return "RXPROTECTED RV32 " + status + " " + " ".join(f"{v:08x}" for v in values) + " \n"


TRAP = "RXPROTECTED TRAP 00000002 80000104 df080677 \n"


def test_complete_report_passes():
    result = parse_result(output(), 0)
    assert result["passed"] and result["matrix_cases"] == EXPECTED_MATRIX


@pytest.mark.parametrize("changes,exit_code", [
    ({"status": "FAIL"}, 0), ({"matrix": EXPECTED_MATRIX - 1}, 0),
    ({"wire": EXPECTED_WIRE - 1}, 0), ({"checks": EXPECTED_CHECKS - 1}, 0),
    ({"instructions": EXPECTED_INSTRUCTIONS - 1}, 0), ({"result": 1}, 0),
    ({"difference": 1}, 0), ({}, 1),
    *[({"inputs": [value + (i == bad) for i, value in enumerate(LAST_INPUTS)]}, 0)
      for bad in range(8)],
])
def test_inconsistent_report_does_not_pass(changes, exit_code):
    assert not parse_result(output(**changes), exit_code)["passed"]


@pytest.mark.parametrize("text", ["", "RXPROTECTED RV32 PASS", "trap 255", output()[:50],
    output() + output(), output() + "RXPROTECTED RV32 FAIL\n", output().replace(" \n", " extra\n"),
    output() + TRAP, TRAP, TRAP + TRAP, "RXPROTECTED TRAP invalid\n"])
def test_incomplete_report_is_explicit(text):
    result = parse_result(text, 0)
    assert not result["passed"] and result["status"] == "incomplete"


def test_trap_details_are_preserved():
    result = parse_result(TRAP, 255)
    assert not result["passed"] and result["status"] == "incomplete"
    assert result["trap"] == {"cause": 2, "pc": 0x80000104, "value": 0xdf080677}
