#!/usr/bin/env python3
"""Audit saved Ox64 TCP fallback A/B rounds (no device access).

Field checks use stage 9 as the eligibility witness. Response counts use the
first TX output per probe, whether or not that output was eligible. Incomplete
evidence is a guardrail failure, not a retry exhaustion. Exit 1 for a failed
guardrail and 2 for invalid input.
"""

from __future__ import annotations

import argparse
import json
import struct
from collections import Counter, defaultdict
from collections.abc import Iterable
from dataclasses import dataclass, field
from pathlib import Path

from analyze_wifi_tcp_path import (
    CAPACITY, DONE, FALLBACK_CHOICE, HTTP, MAC, POLICY_CAPACITY, POLICY_ENTRY,
    RETRY_LIMIT, RX, RX_REJECT, SUCCESS, SW_DONE, TX, TX_REJECT, Event, Flow,
    Tcp, TxPolicy, read_pcap, read_policies, read_snapshot,
)


ARMS = ("control", "treatment")
OUTCOMES = ("ok", "exhausted", "other", "retired", "rejected", "no-output", "unknown")
SUMMARY_COUNTS = (
    "probes", "client-ok", "client-failed", "body-unchecked",
    "wire-data-probes", "wire-data-copies", "ring-uncovered",
    "outputs", "repeat-range-outputs", "hardware", "policy-status-ok",
    "choices", "choices-verified",
)


@dataclass(frozen=True)
class Probe:
    port: int
    client_ok: bool
    body_checked: bool


@dataclass(frozen=True)
class Submission:
    outcome: str
    choice: Event | None = None
    policy: TxPolicy | None = None


@dataclass
class Totals:
    counts: dict[str, Counter[str]] = field(
        default_factory=lambda: {arm: Counter() for arm in ARMS}
    )
    # Compare starting rates, never the replacement rate or a reached retry slot.
    rates: dict[str, Counter[tuple[int, int]]] = field(
        default_factory=lambda: {arm: Counter() for arm in ARMS}
    )
    unresolved: Counter[str] = field(default_factory=Counter)

    def add(self, other: Totals) -> None:
        for arm in ARMS:
            self.counts[arm].update(other.counts[arm])
            self.rates[arm].update(other.rates[arm])
        self.unresolved.update(other.unresolved)


def arm_for_port(port: int) -> str:
    return ARMS[(port ^ (port >> 4) ^ (port >> 8)) & 1]


def read_probes(path: Path) -> list[Probe]:
    rows = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(rows, list) or not rows:
        raise ValueError("probe.json must contain a nonempty array of probes")
    probes, ids, ports = [], set(), set()
    for index, row in enumerate(rows, 1):
        try:
            ident, rc = row["id"], row["http_rc"]
            metric_port, _, _, _, metric_code = row["metrics"].split()
            port, code = int(metric_port), int(metric_code)
            body_ok = row.get("body_ok", True)
            if (type(ident) is not int or type(rc) is not int or rc < 0
                    or not 0 <= port <= 65535 or port == HTTP or type(body_ok) is not bool
                    or len(metric_code) != 3 or (code != 0 and not 100 <= code <= 599)):
                raise ValueError("expected probe id, curl result, peer port, HTTP status and optional body_ok")
        except (TypeError, KeyError, AttributeError, ValueError) as error:
            raise ValueError(f"probe.json row {index}: {error}") from error
        if ident in ids or (port and port in ports):
            raise ValueError(f"probe.json row {index}: ambiguous repeated id={ident} or port={port}")
        ids.add(ident)
        ports.add(port)
        probes.append(Probe(port, rc == 0 and code == 200 and body_ok, "body_ok" in row))
    return probes


def outbound_data(tcp: Tcp) -> bool:
    return tcp.src == HTTP and tcp.dst != HTTP and tcp.kind == "data"


def hardware_done(event: Event) -> bool:
    return event.detail & (DONE | SW_DONE) == DONE


def client_syn(tcp: Tcp) -> bool:
    return tcp.dst == HTTP and tcp.kind == "SYN"


def evidence(event: Event) -> str:
    tcp = event.tcp
    return (f"port={tcp.dst} seq={tcp.seq} ack={tcp.ack} flags={tcp.flags:02x} "
            f"len={tcp.length} ip_id={event.ip_id} ordinal={event.ordinal}")


def audit_key(events: list[Event], policies: dict[int, TxPolicy], arm: str,
              counts: Counter[str], issues: list[str]) -> Submission:
    """Resolve one exact (Tcp, IP ID) key in ring ordinal order."""
    outputs = [event for event in events if event.stage == TX]
    rejects = [event for event in events if event.stage == TX_REJECT]
    choices = [event for event in events if event.stage == FALLBACK_CHOICE]
    completions = [event for event in events if event.stage == MAC]
    counts["choices"] += len(choices)
    trusted = {}
    for event in completions:
        if not hardware_done(event):
            continue
        counts["hardware"] += 1
        policy = policies.get(event.ordinal)
        if policy is None:
            issues.append(f"{evidence(event)}: missing policy for hardware completion")
        elif (policy.hardware_status ^ event.detail) & ~1:
            issues.append(f"{evidence(event)}: status mismatch "
                          f"raw={policy.hardware_status:08x} published={event.detail:08x}")
        else:
            trusted[event.ordinal] = policy
            counts["policy-status-ok"] += 1

    # A repeated exact output key has no generation in this trace. Do not
    # guess which output owns a delayed completion, even if it appears nearby.
    if (len(outputs) > 1 or len(rejects) > 1
            or (rejects and (choices or completions))
            or (outputs and outputs[0] != events[0])
            or any(event.repush != i for i, event in enumerate(completions))):
        issues.append(f"{evidence(events[0])}: ambiguous output/submission order for exact key")
        return Submission("unknown")
    if not outputs:
        issues.append(f"{evidence(events[0])}: missing TX output for exact key")

    pending = []
    first = Submission("rejected" if rejects else "unknown")
    for event in events:
        if event.stage == FALLBACK_CHOICE:
            pending.append(event)
        if event.stage != MAC:
            continue
        choice = None
        policy = trusted.get(event.ordinal)
        if len(pending) > 1:
            ordinals = ",".join(str(marker.ordinal) for marker in pending)
            issues.append(f"{evidence(event)}: ambiguous choices at ordinals {ordinals}")
        elif pending:
            choice = pending[0]
            identity = f"{evidence(event)} choice={choice.ordinal}"
            if not hardware_done(event):
                issues.append(f"{identity}: missing hardware completion for choice")
            if policy is not None:
                rate, power = policy.rates, policy.power
                if arm == "treatment":
                    valid = rate[1] == rate[3] and power[1] == power[3]
                    expected = f"final rate/power={rate[3]:08x}/{power[3]:08x}"
                else:
                    valid = rate[1] == choice.detail
                    expected = f"original rate={choice.detail:08x}"
                if valid:
                    counts["choices-verified"] += 1
                else:
                    issues.append(f"{identity}: {arm} slot mismatch "
                                  f"second rate/power={rate[1]:08x}/{power[1]:08x}; "
                                  f"expected {expected}")
        # A software completion or a completion without a choice also closes
        # this submission. Never carry a marker forward to a host repush.
        pending.clear()
        if event.repush == 0:
            if not hardware_done(event):
                outcome = "retired" if event.detail & SW_DONE else "unknown"
            elif policy is None:
                outcome = "unknown"
            elif event.detail & SUCCESS:
                outcome = "ok"
            elif event.detail & RETRY_LIMIT:
                outcome = "exhausted"
            else:
                outcome = "other"
            first = Submission(outcome, choice, policy)
    for choice in pending:
        issues.append(f"{evidence(choice)}: missing matching completion for choice")
    return first


def audit_round(path: Path) -> tuple[Totals, list[str], int, int]:
    probes = read_probes(path / "probe.json")
    snapshot = read_snapshot((path / "device-trace.bin").read_bytes())
    raw_policy = (path / "device-policies.bin").read_bytes()
    policies = read_policies(raw_policy, snapshot)
    policy_head, = struct.unpack_from("<I", raw_policy)
    ports = {probe.port for probe in probes if probe.port}
    wire: dict[int, dict[Flow, Counter[Tcp]]] = defaultdict(lambda: defaultdict(Counter))
    with (path / "headers.pcap").open("rb", buffering=0) as capture:
        for flow, tcp in read_pcap(capture):
            if flow.peer_port in ports:
                wire[flow.peer_port][flow][tcp] += 1

    totals = Totals()
    issues = []
    trace_wrapped = snapshot.head > CAPACITY
    trace_incomplete = snapshot.invalid or snapshot.unused_nonzero
    if snapshot.invalid or snapshot.unused_nonzero:
        issues.append(f"trace ring invalid={snapshot.invalid} stale-slots={snapshot.unused_nonzero}")
    if policy_head < POLICY_CAPACITY and any(raw_policy[4 + policy_head * POLICY_ENTRY.size:]):
        issues.append("policy ring has nonzero slots beyond its head")

    by_port: dict[int, list[Event]] = defaultdict(list)
    syns: dict[int, list[Event]] = defaultdict(list)
    for event in snapshot.events:
        if (event.tcp.src in ports and event.stage in (RX, RX_REJECT) and client_syn(event.tcp)):
            syns[event.tcp.src].append(event)
        elif (event.tcp.dst in ports and outbound_data(event.tcp)
                and event.stage in (TX, TX_REJECT, FALLBACK_CHOICE, MAC)):
            by_port[event.tcp.dst].append(event)

    for probe in probes:
        port = probe.port
        counts = totals.counts[arm_for_port(port)] if port else totals.unresolved
        counts["probes"] += 1
        counts["client-ok" if probe.client_ok else "client-failed"] += 1
        counts["body-unchecked"] += not probe.body_checked
        if not port:
            continue
        arm = arm_for_port(port)
        flows = wire[port]
        if len(flows) != 1:
            problem = "ambiguous wired flows" if flows else "missing wired flow"
            issues.append(f"port={port}: {problem}")
            counts["first-unknown"] += 1
            continue
        packets = next(iter(flows.values()))
        wire_syns = {tcp for tcp in packets if client_syn(tcp)}
        if len({tcp.seq for tcp in wire_syns}) > 1:
            issues.append(f"port={port}: ambiguous connection reuse (distinct client SYNs)")
            counts["first-unknown"] += 1
            continue
        copies = sum(count for tcp, count in packets.items() if outbound_data(tcp))
        counts["wire-data-probes"] += copies != 0
        counts["wire-data-copies"] += copies

        # Heads are boot-global. Use the wired connection's SYN to bound this
        # probe rather than assuming a wrapped snapshot starts with the round.
        start = next((event for event in syns[port] if event.tcp in wire_syns), None)
        if start is None and trace_wrapped:
            issues.append(f"port={port}: wrapped trace does not retain a matching wired SYN; "
                          "original submission coverage unknown")
            counts["ring-uncovered"] += 1
            counts["first-unknown"] += 1
            continue
        events = by_port[port]
        if start is not None:
            stop = next((event.ordinal for event in syns[port]
                         if event.ordinal > start.ordinal and event.tcp.seq != start.tcp.seq),
                        snapshot.head)
            events = [event for event in events if start.ordinal < event.ordinal < stop]
        outputs = [event for event in events if event.stage == TX]
        counts["outputs"] += len(outputs)
        if probe.client_ok and (not copies or not outputs):
            issues.append(f"port={port}: client success lacks wired data or TX output")
        original = None
        if not trace_incomplete and outputs and outputs[0] == events[0]:
            original = outputs[0]
        if original is not None:
            counts["repeat-range-outputs"] += sum(
                (event.tcp.seq, event.tcp.length) == (original.tcp.seq, original.tcp.length)
                for event in outputs[1:]
            )
        groups: dict[tuple[Tcp, int], list[Event]] = defaultdict(list)
        for event in events:
            groups[event.tcp, event.ip_id].append(event)
        first = Submission("unknown" if events or trace_incomplete else "no-output")
        for group in groups.values():
            result = audit_key(group, policies, arm, counts, issues)
            if original is not None and original in group:
                first = result
        counts[f"first-{first.outcome}"] += 1
        if first.choice is not None:
            counts["eligible-first"] += 1
            counts[f"eligible-first-{first.outcome}"] += 1
            if first.policy is not None:
                totals.rates[arm][first.policy.rates[0], first.choice.detail] += 1
        if first.outcome == "unknown":
            issues.append(f"port={port}: missing or ambiguous first-submission outcome")

    for arm in ARMS:
        counts = totals.counts[arm]
        if not counts["eligible-first"] or not totals.rates[arm]:
            issues.append(f"{arm}: no eligible first submission with a verified hardware status")
    return totals, issues, snapshot.head, policy_head


def print_totals(totals: Totals) -> None:
    for arm in ARMS:
        counts = totals.counts[arm]
        # Keep the eligible and all-probe denominators visible side by side.
        print(f"  {arm}: " + " ".join(f"{key}={counts[key]}" for key in SUMMARY_COUNTS))
        print("    " + " ".join(f"first-{key}={counts[f'first-{key}']}" for key in OUTCOMES))
        eligible = (f"{key}={counts[f'eligible-first-{key}']}" for key in OUTCOMES)
        print("    " + " ".join((f"eligible-first={counts['eligible-first']}", *eligible)))
    unresolved = totals.unresolved
    print("  Unresolved port (not assigned): "
          + " ".join(f"{key}={unresolved[key]}"
                     for key in ("probes", "client-ok", "client-failed", "body-unchecked")))
    all_counts = sum(totals.counts.values(), unresolved)
    print(f"  All client rows: ok={all_counts['client-ok']}/{all_counts['probes']}")
    control, treatment = (totals.rates[arm] for arm in ARMS)
    if control or treatment:
        print("  Eligible first starting rate mix (primary/original second; control/treatment):")
        for primary, second in sorted(control.keys() | treatment.keys()):
            key = (primary, second)
            print(f"    {primary:08x}/{second:08x}: {control[key]}/{treatment[key]}")
        if not control.keys() & treatment.keys():
            print("  Rate guardrail: no shared starting-rate bins; do not interpret raw "
                  "arm differences as an isolated fallback effect.")


def main(argv: Iterable[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("rounds", type=Path, nargs="+", metavar="ROUND_DIR")
    args = parser.parse_args(argv)
    if len({path.resolve() for path in args.rounds}) != len(args.rounds):
        parser.error("the same round directory was supplied more than once")

    aggregate = Totals()
    passed = invalid = 0
    for path in args.rounds:
        print(f"Round: {path}")
        try:
            totals, issues, trace_head, policy_head = audit_round(path)
        except (OSError, ValueError) as error:
            print(f"  Guardrails: INVALID: {error}")
            invalid += 1
            continue
        aggregate.add(totals)
        print(f"  Retained ring ordinals: trace=[{max(0, trace_head - CAPACITY)}, {trace_head}) "
              f"policy=[{max(0, policy_head - POLICY_CAPACITY)}, {policy_head})")
        print_totals(totals)
        print("  Guardrails: " + ("FAIL" if issues else "PASS"))
        for issue in issues:
            print(f"    {issue}")
        passed += not issues

    print(f"Aggregate (descriptive): rounds={len(args.rounds)} passed={passed} invalid={invalid}")
    print_totals(aggregate)
    print("Client success requires curl rc=0, HTTP 200, and body_ok when recorded; "
          "legacy rows without body_ok are marked body-unchecked. Assignment uses the "
          "reported curl port, never requested_port.")
    print("Arm counts are descriptive; a port hash and shared adaptive rate state "
          "do not establish an isolated fallback effect.")
    print("Slot checks cover only recorded submissions, not frame bytes, original "
          "control power, actual retry rates, or RF power.")
    return 2 if invalid else int(passed != len(args.rounds))


if __name__ == "__main__":
    raise SystemExit(main())
