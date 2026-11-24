"""Offline binary fixtures for the outbound HTTP fallback audit."""

import json
import subprocess
import sys
from dataclasses import replace
from pathlib import Path

import pytest

from analyze_wifi_tcp_fallback import arm_for_port, audit_round
from test_wifi_tcp_path_analysis import RESPONSE, SYN, event, frame, pcap, policy_ring, ring


CONTROL = RESPONSE  # 0xc000: all three relevant bits clear.
TREATMENT = replace(RESPONSE, dst=0xc010)  # Same parity, different bit 4.
PRIMARY, ORIGINAL, FINAL = 0x80000006, 0x80000004, 0x80000400
OK, EXHAUSTED, SOFTWARE = 0x80800001, 0x80010701, 0x40000001


class Fixture:
    def __init__(self):
        self.events = []
        self.policies = []
        self.packets = []
        self.probes = []

    def probe(self, tcp, *, rc=0, code="200", on_wire=True, body_ok=None):
        self.probes.append({
            "id": len(self.probes), "epoch": 10.0, "ping_rc": 0, "http_rc": rc,
            "metrics": f"{tcp.dst} 0.01 0.02 0.03 {code}", "error": "",
        })
        if body_ok is not None:
            self.probes[-1]["body_ok"] = body_ok
        self.packets.append(frame(replace(SYN, src=tcp.dst)))
        if on_wire:
            self.packets.append(frame(tcp))

    def trace(self, stage, tcp, ip_id=7, *, detail=0, repush=0, policy=False):
        ordinal = len(self.events)
        tick, meta, ports, seq, ack, _, _ = event(ordinal * 10, stage, tcp)
        self.events.append((tick, meta | (repush << 24) | (int(policy) << 16),
                            ports, seq, ack, tcp.length | (ip_id << 16), detail))
        return ordinal

    def choice(self, tcp, ip_id=7):
        self.trace(9, tcp, ip_id, detail=ORIGINAL)

    def complete(self, tcp, ip_id=7, *, status=OK, repush=0, policy=True,
                 raw=None, rate=None, power=None):
        ordinal = self.trace(5, tcp, ip_id, detail=status, repush=repush, policy=policy)
        if policy:
            treatment = tcp.dst == TREATMENT.dst
            second = rate if rate is not None else FINAL if treatment else ORIGINAL
            second_power = power if power is not None else 0x50 if treatment else 0x48
            self.policies.append([
                ordinal, PRIMARY, second, 0x80000005, FINAL, 0xffff0704, 0, 0x2200,
                status & ~1 if raw is None else raw, 0x48, second_power, 0x48, 0x50,
            ])

    def submit(self, tcp, *, rc=0, code="200"):
        self.probe(tcp, rc=rc, code=code)
        self.trace(1, replace(SYN, src=tcp.dst))
        self.trace(3, tcp)
        self.choice(tcp)
        self.complete(tcp)

    def write(self, directory):
        directory.mkdir(exist_ok=True)
        (directory / "headers.pcap").write_bytes(pcap(self.packets))
        (directory / "device-trace.bin").write_bytes(ring(self.events[-1024:], head=len(self.events)))
        (directory / "device-policies.bin").write_bytes(
            policy_ring(self.policies[-384:], head=len(self.policies)))
        (directory / "probe.json").write_text(json.dumps(self.probes), encoding="utf-8")
        return directory


def test_assignment_uses_bits_zero_four_and_eight():
    assert arm_for_port(0xc000) == "control"
    assert arm_for_port(0xc001) == arm_for_port(0xc010) == arm_for_port(0xc100) == "treatment"
    assert arm_for_port(0xc110) == arm_for_port(0xc011) == "control"


def test_interleaved_choices_repush_and_tcp_retransmission_count_once(tmp_path):
    fixture = Fixture()
    fixture.probe(CONTROL, rc=28, code="000", on_wire=False)
    fixture.probe(TREATMENT)
    fixture.trace(3, CONTROL)
    fixture.trace(3, TREATMENT)
    fixture.choice(CONTROL)
    fixture.choice(TREATMENT)
    fixture.complete(TREATMENT, raw=OK)  # Bit 0 may agree, too.
    fixture.complete(CONTROL, status=EXHAUSTED)
    fixture.choice(CONTROL)
    fixture.complete(CONTROL, repush=1, status=EXHAUSTED)
    late = replace(CONTROL, ack=CONTROL.ack + 1)
    fixture.trace(3, late, 8)
    fixture.choice(late, 8)
    fixture.complete(late, 8)
    fixture.packets += [frame(late), frame(late)]
    fixture.choice(SYN)  # RX and TX ACK-only noise are out of scope.
    fixture.choice(replace(TREATMENT, length=0))
    fixture.choice(replace(TREATMENT, dst=0xbeef))  # Not a probe.

    totals, issues, _, _ = audit_round(fixture.write(tmp_path))
    assert issues == []
    control, treatment = (totals.counts[arm] for arm in ("control", "treatment"))
    assert control["choices"] == control["choices-verified"] == control["hardware"] == 3
    assert control["first-exhausted"] == control["eligible-first-exhausted"] == 1
    assert control["first-ok"] == control["client-ok"] == 0
    assert control["client-failed"] == control["repeat-range-outputs"] == 1
    assert control["wire-data-probes"] == 1 and control["wire-data-copies"] == 2
    assert treatment["first-ok"] == treatment["eligible-first-ok"] == treatment["client-ok"] == 1
    assert totals.rates["control"] == totals.rates["treatment"] == {(PRIMARY, ORIGINAL): 1}


def test_eligible_repush_does_not_replace_unmarked_original(tmp_path):
    fixture = Fixture()
    fixture.submit(CONTROL)
    fixture.probe(TREATMENT, code="503")  # Curl rc=0 does not suffice.
    fixture.trace(3, TREATMENT)
    fixture.complete(TREATMENT, status=EXHAUSTED)
    fixture.choice(TREATMENT)
    fixture.complete(TREATMENT, repush=1)
    totals, issues, _, _ = audit_round(fixture.write(tmp_path))
    counts = totals.counts["treatment"]
    assert counts["choices-verified"] == counts["first-exhausted"] == counts["client-failed"] == 1
    assert counts["eligible-first"] == counts["first-ok"] == counts["client-ok"] == 0
    assert issues == ["treatment: no eligible first submission with a verified hardware status"]


@pytest.mark.parametrize(
    ("change", "message"),
    [
        ("missing-policy", "missing policy"),
        ("status", "status mismatch"),
        ("control-rate", "control slot mismatch"),
        ("treatment-rate", "treatment slot mismatch"),
        ("treatment-power", "treatment slot mismatch"),
        ("missing-completion", "missing matching completion"),
        ("software", "missing hardware completion"),
        ("ip-id", "missing matching completion"),
        ("ack", "missing matching completion"),
        ("duplicate-choice", "ambiguous choices"),
        ("duplicate-output", "ambiguous output/submission order"),
        ("missing-first-completion", "ambiguous output/submission order"),
    ],
)
def test_guardrails_report_broken_submission_evidence(tmp_path, change, message):
    fixture = Fixture()
    tcp = CONTROL if change == "control-rate" else TREATMENT
    fixture.submit(TREATMENT if tcp == CONTROL else CONTROL)
    fixture.probe(tcp)
    fixture.trace(3, tcp)
    if change == "duplicate-output":
        fixture.trace(3, tcp)
    fixture.choice(tcp)
    if change == "duplicate-choice":
        fixture.choice(tcp)
    if change != "missing-completion":
        fixture.complete(
            replace(tcp, ack=tcp.ack + 1) if change == "ack" else tcp,
            ip_id=8 if change == "ip-id" else 7,
            status=SOFTWARE if change == "software" else OK,
            repush=1 if change == "missing-first-completion" else 0,
            policy=change != "software",
            raw=OK ^ 2 if change == "status" else None,
            rate=0x80000002 if change.endswith("-rate") else None,
            power=0x48 if change == "treatment-power" else None,
        )
        if change == "missing-policy":
            fixture.policies.pop()  # Completion advertises a row, but the row is absent.

    totals, issues, _, _ = audit_round(fixture.write(tmp_path))
    counts = totals.counts[arm_for_port(tcp.dst)]
    assert counts["choices-verified"] == 0
    assert any(message in issue and f"port={tcp.dst}" in issue for issue in issues)
    if change in ("status", "missing-policy", "duplicate-output", "missing-first-completion"):
        assert counts["first-unknown"] == 1 and counts["first-exhausted"] == 0


def test_missing_original_anchor_does_not_promote_later_output(tmp_path):
    fixture = Fixture()
    fixture.submit(CONTROL)
    fixture.probe(TREATMENT)
    fixture.choice(TREATMENT)  # The original output marker is missing.
    fixture.complete(TREATMENT, status=EXHAUSTED)
    fixture.trace(3, TREATMENT, 8)
    fixture.choice(TREATMENT, 8)
    fixture.complete(TREATMENT, 8)
    totals, issues, _, _ = audit_round(fixture.write(tmp_path))
    counts = totals.counts["treatment"]
    assert counts["choices-verified"] == 2
    assert counts["first-unknown"] == 1 and counts["first-ok"] == 0
    assert any("missing TX output" in issue for issue in issues)


def test_ambiguous_wired_connection_keeps_client_result_but_not_mac_result(tmp_path):
    fixture = Fixture()
    fixture.submit(CONTROL)
    fixture.submit(TREATMENT)
    fixture.packets.append(frame(replace(SYN, src=CONTROL.dst, seq=123)))
    totals, issues, _, _ = audit_round(fixture.write(tmp_path))
    counts = totals.counts["control"]
    assert counts["client-ok"] == counts["first-unknown"] == 1
    assert counts["first-ok"] == 0 and any("connection reuse" in issue for issue in issues)


def test_wrapped_rings_can_pass_for_covered_wire_ports(tmp_path):
    fixture = Fixture()
    unrelated = replace(CONTROL, dst=0xc200)
    for _ in range(700):
        fixture.trace(1, replace(SYN, src=unrelated.dst))
    for _ in range(400):
        fixture.complete(unrelated)
    fixture.trace(3, CONTROL)
    fixture.complete(CONTROL, status=EXHAUSTED)  # Same port/key, earlier round.
    fixture.submit(CONTROL)
    fixture.submit(TREATMENT)
    totals, issues, trace_head, policy_head = audit_round(fixture.write(tmp_path))
    assert trace_head > 1024 and policy_head > 384
    assert issues == []
    for counts in totals.counts.values():
        assert counts["outputs"] == counts["choices-verified"] == counts["first-ok"] == 1
        assert counts["first-exhausted"] == 0


def test_wrapped_trace_without_syn_does_not_claim_original_submission(tmp_path):
    fixture = Fixture()
    fixture.trace(1, SYN)
    fixture.probe(CONTROL)
    for _ in range(1024):
        fixture.trace(1, replace(SYN, src=0xc200))
    fixture.trace(3, CONTROL)
    fixture.choice(CONTROL)
    fixture.complete(CONTROL)
    fixture.submit(TREATMENT)
    totals, issues, _, _ = audit_round(fixture.write(tmp_path))
    assert any("wrapped trace does not retain a matching wired SYN" in issue for issue in issues)
    control = totals.counts["control"]
    assert control["ring-uncovered"] == control["first-unknown"] == control["client-ok"] == 1
    assert control["first-ok"] == 0
    assert totals.counts["treatment"]["first-ok"] == 1


def test_missing_probe_port_and_body_results(tmp_path):
    fixture = Fixture()
    fixture.submit(CONTROL)
    fixture.submit(TREATMENT)
    fixture.probes[0].update(requested_port=TREATMENT.dst, body_ok=False)
    fixture.probes[1].update(requested_port=CONTROL.dst, body_ok=True)
    fixture.probe(replace(CONTROL, dst=0), rc=28, code="000", on_wire=False, body_ok=False)
    fixture.probes[-1]["requested_port"] = CONTROL.dst
    fixture.probe(replace(CONTROL, dst=0), rc=28, code="000", on_wire=False)
    totals, issues, _, _ = audit_round(fixture.write(tmp_path))
    assert issues == []
    assert totals.unresolved == {"probes": 2, "client-failed": 2, "body-unchecked": 1}
    assert totals.unresolved["client-ok"] == 0
    assert totals.counts["control"]["client-failed"] == 1
    assert totals.counts["treatment"]["client-ok"] == 1
    assert sum(counts["first-ok"] for counts in totals.counts.values()) == 2


def test_cli_reports_rounds_aggregate_and_nonzero_guardrail_status(tmp_path):
    fixture = Fixture()
    fixture.submit(CONTROL)
    fixture.submit(TREATMENT)
    first = fixture.write(tmp_path / "one")
    second = fixture.write(tmp_path / "two")
    tool = Path(__file__).with_name("analyze_wifi_tcp_fallback.py")
    command = [sys.executable, str(tool), str(first), str(second)]
    result = subprocess.run(command, capture_output=True, text=True, check=True)
    assert result.stdout.count("Guardrails: PASS") == 2
    assert "Aggregate (descriptive): rounds=2 passed=2 invalid=0" in result.stdout
    assert "control: probes=2 client-ok=2" in result.stdout
    assert "treatment: probes=2 client-ok=2" in result.stdout

    fixture.policies.pop()
    fixture.write(second)
    result = subprocess.run(command, capture_output=True, text=True)
    assert result.returncode == 1
    assert "rounds=2 passed=1 invalid=0" in result.stdout
    assert "missing policy" in result.stdout

    fixture.probes.append({**fixture.probes[-1], "id": 99})
    fixture.write(second)
    result = subprocess.run(command, capture_output=True, text=True)
    assert result.returncode == 2
    assert "rounds=2 passed=1 invalid=1" in result.stdout
    assert "ambiguous repeated id" in result.stdout
