"""Reject truncated, inconsistent or incorrectly classified RV32 BIP observations."""
import pytest

from check_wifi_bip_rx_oracle import parse_result

PASS = [11856, 142272, 0, 0, 39, 6, 2, 8, 16, 19, 0, 0, 0, 896]


def line(values: list[int], status: str = "PASS") -> str:
    return "BIPRX RV32 " + status + "".join(f" {v:08x}" for v in values) + " \n"


def test_complete_result() -> None:
    result = parse_result(line(PASS), 0)
    assert result["passed"] and not result["control_rejected"]


@pytest.mark.parametrize("field", range(14))
def test_modified_fields(field: int) -> None:
    values = PASS.copy()
    values[field] ^= 1
    assert not parse_result(line(values), 0)["passed"]


@pytest.mark.parametrize("output", [
    "", "BIPRX RV32 PASS\n", line(PASS) + line(PASS), line(PASS) + "extra\n",
    "BIPRX TRAP 00000002 80000000 deadbeef\n" + line(PASS),
    line(PASS).replace("00002e50", "00002E50"), line(PASS[:-1]), line(PASS + [0]),
])
def test_malformed_output(output: str) -> None:
    result = parse_result(output, 0)
    assert not result["passed"] and not result["control_rejected"]


@pytest.mark.parametrize("fault,check", [("accept", 3), ("replay", 5), ("input", 6), ("stack", 11)])
def test_designated_controls(fault: str, check: int) -> None:
    values = [1, check, check, check, 0, 4, 0, 0, 0, 0, 0, 0, 0, 784]
    result = parse_result(line(values, "FAIL"), check, fault=fault)
    assert result["control_rejected"] and not result["passed"]
    assert not parse_result(line(PASS), 0, fault=fault)["control_rejected"]
    assert not parse_result(line(values), check, fault=fault)["control_rejected"]
    assert not parse_result(line(values, "FAIL"), check + 1, fault=fault)["control_rejected"]
    assert not parse_result(line(values, "FAIL"), check)["passed"]
    for field in range(14):
        changed = values.copy()
        changed[field] ^= 1
        assert not parse_result(line(changed, "FAIL"), check, fault=fault)["control_rejected"]


@pytest.mark.parametrize("profiles", [1, 2, 14, 27, 39])
def test_selected_corpus(profiles: int) -> None:
    cases = profiles * 304
    values = [cases, cases * 12, 0, 0, profiles, 6, 2, 8, 16, 19, 0, 0, 0, 864]
    assert parse_result(line(values), 0, profiles=profiles)["passed"]
    if profiles != 39:
        assert not parse_result(line(values), 0)["passed"]


@pytest.mark.parametrize("profiles,fault", [(0, "none"), (40, "none"), (39, "unknown")])
def test_invalid_corpus(profiles: int, fault: str) -> None:
    assert not parse_result(line(PASS), 0, profiles, fault)["passed"]


@pytest.mark.parametrize("touched", [0, 3, 2049, 2052])
def test_invalid_stack_observation(touched: int) -> None:
    values = PASS.copy()
    values[-1] = touched
    assert not parse_result(line(values), 0)["passed"]


def test_exit_status_and_unexpected_observer() -> None:
    assert not parse_result(line(PASS), 1)["passed"]
    assert not parse_result(line(PASS, "FAIL"), 0)["passed"]
    values = [1, 1, 1, 1, 0, 4, 0, 0, 0, 0, 0, 1, 0, 544]
    result = parse_result(line(values, "FAIL"), 1)
    assert not result["passed"] and not result["control_rejected"]
