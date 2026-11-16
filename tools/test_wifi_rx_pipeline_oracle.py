"""Reject incomplete or inconsistent RX pipeline observations."""

from pathlib import Path
import struct

import pytest

from check_wifi_rx_pipeline_oracle import elf32, parse_result


PASS = [388864, 5174400, 0, 0, 490, 3, 6, 2, 0x80303, 0, 0, 0]


def line(values: list[int], status: str = "PASS") -> str:
    return "RXPIPE RV32 " + status + "".join(f" {value:08x}" for value in values) + " \n"


def test_complete_pipeline_result() -> None:
    result = parse_result(line(PASS), 0)
    assert result["passed"] and not result["control_rejected"]
    assert result["cases"] == 388864 and result["checks"] == 5174400


@pytest.mark.parametrize("field", range(12))
def test_modified_pipeline_fields(field: int) -> None:
    values = PASS.copy()
    values[field] ^= 1
    assert not parse_result(line(values), 0)["passed"]


@pytest.mark.parametrize("output", [
    "", "RXPIPE RV32 PASS\n", line(PASS) + line(PASS), line(PASS) + "extra\n",
    "RXPIPE TRAP 00000002 80000000 deadbeef\n" + line(PASS),
    line(PASS).replace("0005ef00", "0005EF00"),
])
def test_incomplete_pipeline_output(output: str) -> None:
    result = parse_result(output, 0)
    assert not result["passed"] and not result["control_rejected"]


def test_exit_code_and_status() -> None:
    assert not parse_result(line(PASS), 1)["passed"]
    assert not parse_result(line(PASS, "FAIL"), 0)["passed"]


@pytest.mark.parametrize("profiles", [1, 2, 5, 21, 490])
def test_selected_profile_scope(profiles: int) -> None:
    eapols = sum(i % 5 == 1 for i in range(profiles))
    cases = (profiles * 6 + eapols) * 128
    checks = cases * 13 + (profiles - eapols) * 304
    values = [cases, checks, 0, 0, profiles, 3, 6, 2, 0x80303, 0, 0, 0]
    assert parse_result(line(values), 0, profiles=profiles)["passed"]
    if profiles != 490: assert not parse_result(line(values), 0)["passed"]


@pytest.mark.parametrize("fault,cases,failure,inputs", [
    ("key", 1, 3, [0, 1, 1, 0, 0]),
    ("chain", 15873, 3, [20, 1, 1, 0, 0]),
    ("counter", 1, 9, [0, 1, 1, 0, 0]),
    ("packet", 0, 12, [0, 1, 0, 0, 0]),
])
def test_designated_control_failures(fault: str, cases: int, failure: int, inputs: list[int]) -> None:
    values = [cases, 123, 300, failure, *inputs, 0, 0, 0]
    output = line(values, "FAIL")
    result = parse_result(output, 44, fault=fault)
    assert result["control_rejected"] and not result["passed"]
    assert not parse_result(output, 45, fault=fault)["control_rejected"]
    assert not parse_result(line(PASS), 0, fault=fault)["control_rejected"]
    for field in [0, 3, 4, 5, 6, 7, 8, 9, 10, 11]:
        changed = values.copy()
        changed[field] ^= 1
        assert not parse_result(line(changed, "FAIL"), 44, fault=fault)["control_rejected"]


@pytest.mark.parametrize("profiles,fault", [(0, "none"), (491, "none"), (490, "unknown")])
def test_invalid_scope(profiles: int, fault: str) -> None:
    assert not parse_result(line(PASS), 0, profiles=profiles, fault=fault)["passed"]


@pytest.mark.parametrize("ident,machine", [
    (b"BAD!" + bytes(12), 243),
    (b"\x7fELF\x02\x01\x01" + bytes(9), 243),
    (b"\x7fELF\x01\x02\x01" + bytes(9), 243),
    (b"\x7fELF\x01\x01\x01" + bytes(9), 62),
])
def test_reject_non_rv32_object(tmp_path: Path, ident: bytes, machine: int) -> None:
    path = tmp_path / "wrong.o"
    path.write_bytes(struct.pack("<16sHHIIIIIHHHHHH", ident, 1, machine, 1, 0, 0, 0, 0, 52, 0, 0, 40, 0, 0))
    with pytest.raises(AssertionError):
        elf32(path)


AP_PASS = [449792, 6890688, 0, 0, 560, 3, 6, 2, 0x80303, 0, 0, 0]


def test_ap_result_is_not_a_sta_result() -> None:
    assert parse_result(line(AP_PASS), 0, profiles=560, role="ap")["passed"]
    assert not parse_result(line(AP_PASS), 0)["passed"]
    assert not parse_result(line(PASS), 0, role="ap")["passed"]
    assert not parse_result(line(AP_PASS), 0, profiles=560, role="unknown")["passed"]


@pytest.mark.parametrize("field", range(12))
def test_modified_ap_fields(field: int) -> None:
    values = AP_PASS.copy()
    values[field] ^= 1
    assert not parse_result(line(values), 0, profiles=560, role="ap")["passed"]


@pytest.mark.parametrize("profiles", [1, 2, 5, 21, 560])
def test_ap_selected_scope(profiles: int) -> None:
    eapols = sum(i % 5 == 1 for i in range(profiles))
    cases = (profiles * 6 + eapols) * 128 + eapols * 48
    checks = cases * 15 + (profiles - eapols) * 304 + eapols * 68
    ending = [profiles, 2, 6, 0, 0x80302] if (profiles - 1) % 5 == 1 else [profiles, 3, 6, 2, 0x80303]
    values = [cases, checks, 0, 0, *ending, 0, 0, 0]
    assert parse_result(line(values), 0, profiles=profiles, role="ap")["passed"]
    if profiles != 560:
        assert not parse_result(line(values), 0, profiles=560, role="ap")["passed"]


@pytest.mark.parametrize("fault,cases,failure,inputs,callback", [
    ("key", 1, 3, [0, 1, 1, 0, 0], 0),
    ("chain", 16065, 3, [20, 1, 1, 0, 0], 0),
    ("counter", 1, 9, [0, 1, 1, 0, 0], 0),
    ("packet", 0, 12, [0, 1, 0, 0, 0], 0),
    ("destination", 1, 10, [0, 1, 1, 0, 0], 0),
    ("context", 769, 1, [1, 1, 1, 0, 0], 1),
])
def test_ap_designated_controls(fault: str, cases: int, failure: int,
                                inputs: list[int], callback: int) -> None:
    values = [cases, 123, 300, failure, *inputs, 0, callback, 0]
    assert parse_result(line(values, "FAIL"), 44, profiles=560, role="ap", fault=fault)["control_rejected"]
    for field in [0, 3, 4, 5, 6, 7, 8, 9, 10, 11]:
        changed = values.copy()
        changed[field] ^= 1
        assert not parse_result(line(changed, "FAIL"), 44, profiles=560, role="ap", fault=fault)["control_rejected"]
    if fault in ["destination", "context"]:
        assert not parse_result(line(values, "FAIL"), 44, fault=fault)["control_rejected"]


@pytest.mark.parametrize("role,checks", [("sta", 2294208), ("ap", 2638272)])
def test_complete_amsdu_result(role: str, checks: int) -> None:
    values = [172032, checks, 0, 0, 336, 2, 23, 0, 0x8030F, 0, 0, 0]
    assert parse_result(line(values), 0, profiles=336, role=role, corpus="amsdu")["passed"]
    assert not parse_result(line(values), 0, profiles=336, role=role)["passed"]
    for field in range(12):
        changed = values.copy()
        changed[field] ^= 1
        assert not parse_result(line(changed), 0, profiles=336, role=role, corpus="amsdu")["passed"]


@pytest.mark.parametrize("role", ["sta", "ap"])
@pytest.mark.parametrize("profiles", [1, 84, 85, 168, 169, 336])
def test_selected_amsdu_scope(role: str, profiles: int) -> None:
    cases = profiles * 512
    wds = sum((index // 84) % 2 == 1 for index in range(profiles))
    checks = cases * (15 if role == "ap" else 13) + profiles * 168 + wds * 8
    values = [cases, checks, 0, 0, profiles, 2, 23, 0, 0x8030F, 0, 0, 0]
    assert parse_result(line(values), 0, profiles=profiles, role=role, corpus="amsdu")["passed"]
    if profiles != 336:
        assert not parse_result(line(values), 0, profiles=336, role=role, corpus="amsdu")["passed"]


@pytest.mark.parametrize("role", ["sta", "ap"])
@pytest.mark.parametrize("fault,cases,failure,inputs", [
    ("counter", 4, 9, [0, 2, 4, 0, 0]),
    ("packet", 0, 12, [0, 2, 0, 0, 0]),
    ("aggregate", 4, 10, [0, 2, 4, 0, 0]),
    ("destination", 4, 10, [0, 2, 4, 0, 0]),
])
def test_amsdu_controls(role: str, fault: str, cases: int, failure: int, inputs: list[int]) -> None:
    values = [cases, 123, 300, failure, *inputs, 0, 0, 0]
    expected = role == "ap" or fault != "destination"
    assert parse_result(line(values, "FAIL"), 44, profiles=336, role=role,
                        corpus="amsdu", fault=fault)["control_rejected"] == expected
    for field in [0, 3, 4, 5, 6, 7, 8, 9, 10, 11]:
        changed = values.copy()
        changed[field] ^= 1
        assert not parse_result(line(changed, "FAIL"), 44, profiles=336, role=role,
                                corpus="amsdu", fault=fault)["control_rejected"]


@pytest.mark.parametrize("corpus,profiles,fault", [
    ("unknown", 1, "none"), ("amsdu", 337, "none"),
    ("amsdu", 336, "key"), ("amsdu", 336, "chain"),
    ("amsdu", 336, "context"), ("msdu", 336, "aggregate"),
])
def test_invalid_amsdu_scope(corpus: str, profiles: int, fault: str) -> None:
    result = parse_result(line(PASS), 0, profiles=profiles, corpus=corpus, fault=fault)
    assert not result["passed"] and not result["control_rejected"]
