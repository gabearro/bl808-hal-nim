"""Validate the RV32 BIP TX result parser and its designated MIC control."""
import pytest

from check_wifi_bip_tx_oracle import parse_result

PASS = [4224, 25152, 0, 0, 96, 1, 5, 16, 0, 0]
FAULT = [1, 3, 3, 3, 0, 0, 4, 0, 0, 0]


def line(values: list[int], status: str = "PASS") -> str:
    return "BIPTX RV32 " + status + "".join(f" {v:08x}" for v in values) + " \n"


def test_complete_result() -> None:
    result = parse_result(line(PASS), 0, False)
    assert result["passed"] and not result["control_rejected"]


@pytest.mark.parametrize("field", range(len(PASS)))
def test_modified_fields(field: int) -> None:
    values = PASS.copy()
    values[field] ^= 1
    assert not parse_result(line(values), 0, False)["passed"]


@pytest.mark.parametrize("output", [
    "", "BIPTX RV32 PASS\n", line(PASS) + line(PASS), line(PASS) + "extra\n",
    "BIPTX TRAP 00000002 80000000 deadbeef\n" + line(PASS),
    line(PASS).replace("00006240", "0000624A"), line(PASS[:-1]), line(PASS + [0]),
])
def test_malformed_output(output: str) -> None:
    result = parse_result(output, 0, False)
    assert not result["passed"] and not result["control_rejected"]


def test_designated_control() -> None:
    assert parse_result(line(FAULT, "FAIL"), 3, True)["control_rejected"]
    assert not parse_result(line(PASS), 0, True)["control_rejected"]
    assert not parse_result(line(FAULT), 3, True)["control_rejected"]
    assert not parse_result(line(FAULT, "FAIL"), 4, True)["control_rejected"]
    for field in range(len(FAULT)):
        changed = FAULT.copy()
        changed[field] ^= 1
        assert not parse_result(line(changed, "FAIL"), 3, True)["control_rejected"]


def test_wrong_exit_status() -> None:
    assert not parse_result(line(PASS), 1, False)["passed"]
    assert not parse_result(line(PASS, "FAIL"), 0, False)["passed"]
