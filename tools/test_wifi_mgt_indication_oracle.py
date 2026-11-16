"""Reject incomplete, inconsistent or misclassified management observations."""
import pytest

from check_wifi_mgt_indication_oracle import parse_result

PASS = [3036, 30228, 0, 0, 11, 2304, 2, 9, 16, 2, 0, 0, 0]


def line(values: list[int], status: str = "PASS") -> str:
    return "MGTCOPY RV32 " + status + "".join(f" {v:08x}" for v in values) + " \n"


def test_complete_result() -> None:
    result = parse_result(line(PASS), 0)
    assert result["passed"] and not result["control_rejected"]


@pytest.mark.parametrize("field", range(13))
def test_modified_pass_fields(field: int) -> None:
    values = PASS.copy()
    values[field] ^= 1
    assert not parse_result(line(values), 0)["passed"]


@pytest.mark.parametrize("output", [
    "", "MGTCOPY RV32 PASS\n", line(PASS) + line(PASS), line(PASS) + "extra\n",
    "MGTCOPY TRAP 00000002 80000000 deadbeef\n" + line(PASS),
    line(PASS).replace("00000bdc", "00000BDC"),
    line(PASS[:-1]), line(PASS + [0]),
])
def test_incomplete_output(output: str) -> None:
    result = parse_result(output, 0)
    assert not result["passed"] and not result["control_rejected"]


@pytest.mark.parametrize("fault,cases,checks,failure,inputs", [
    ("length", 1, 7, 9, [0, 12, 0, 0, 0, 0]),
    ("body", 1, 9, 11, [0, 12, 0, 0, 0, 0]),
    ("cleanup", 146, 1601, 6, [0, 1713, 0, 0, 0, 1]),
    ("routing", 1, 8, 10, [0, 12, 0, 0, 0, 0]),
])
def test_designated_control(fault: str, cases: int, checks: int, failure: int, inputs: list[int]) -> None:
    values = [cases, checks, failure, failure, *inputs, 0, 0, 0]
    result = parse_result(line(values, "FAIL"), failure, fault)
    assert result["control_rejected"] and not result["passed"]
    assert not parse_result(line(PASS), 0, fault)["control_rejected"]
    assert not parse_result(line(values, "FAIL"), failure + 1, fault)["control_rejected"]
    assert not parse_result(line(values), failure, fault)["control_rejected"]
    assert not parse_result(line(values, "FAIL"), failure)["passed"]
    for field in range(13):
        changed = values.copy()
        changed[field] ^= 1
        assert not parse_result(line(changed, "FAIL"), failure, fault)["control_rejected"]


def test_unknown_control_status_and_exit_code() -> None:
    assert not parse_result(line(PASS), 0, "unknown")["passed"]
    assert not parse_result(line(PASS), 1)["passed"]
    assert not parse_result(line(PASS, "FAIL"), 0)["passed"]
