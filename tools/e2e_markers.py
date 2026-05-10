"""Marker line parser and per-attempt / per-cell aggregators.

Marker grammar:  @e2e <phase>:<kind> [k=v]...
"""
from __future__ import annotations

import re
from collections import Counter
from dataclasses import dataclass, field

from e2e_phases import Phase, Kind


_MARKER_RE = re.compile(
    r"^@e2e\s+(?P<phase>[a-z0-9_]+):(?P<kind>start|ok|fail|info)(?:\s+(?P<rest>.*))?$"
)


@dataclass(frozen=True)
class MarkerEvent:
    phase: Phase
    kind: Kind
    kv: dict[str, str]


def parse_marker_line(line: str) -> MarkerEvent | None:
    """Parse a single UART line. Returns None for non-marker lines.

    Raises ValueError if the line *looks* like a marker but uses an unknown phase
    name — silently dropping a typo in firmware would corrupt the bucket data.
    """
    line = line.strip()
    m = _MARKER_RE.match(line)
    if m is None:
        return None
    phase = Phase(m.group("phase"))  # raises ValueError on unknown
    kind = Kind(m.group("kind"))
    rest = m.group("rest") or ""
    kv: dict[str, str] = {}
    for token in rest.split():
        if "=" in token:
            k, _, v = token.partition("=")
            kv[k] = v
    return MarkerEvent(phase=phase, kind=kind, kv=kv)


@dataclass
class AttemptRecord:
    n: int
    total: int
    result: str  # "ok" | "fail" | "incomplete"
    last_started_phase: Phase | None
    last_completed_phase: Phase | None  # last phase that emitted :ok
    failure_bucket: Phase | None
    fail_reason: str | None
    events: list[MarkerEvent] = field(default_factory=list)


# Phases that count as "milestone" phases (anything other than ATTEMPT framing).
_MILESTONE_PHASES = {p for p in Phase if p is not Phase.ATTEMPT}


def aggregate_attempts(events: list[MarkerEvent | None]) -> list[AttemptRecord]:
    """Group a stream of events into AttemptRecords. None entries (non-marker
    lines) are skipped."""
    attempts: list[AttemptRecord] = []
    cur: AttemptRecord | None = None

    for ev in events:
        if ev is None:
            continue

        # Attempt framing: start opens a new record; ok/fail closes one.
        if ev.phase is Phase.ATTEMPT and ev.kind is Kind.START:
            if cur is not None:
                # Previous attempt never closed. Preserve as incomplete.
                attempts.append(cur)
            cur = AttemptRecord(
                # Firmware emits values as 0x-prefixed hex (sendHex32). int(s, 0)
                # auto-detects base, so plain decimal also works.
                n=int(ev.kv.get("n", "0"), 0),
                total=int(ev.kv.get("total", "0"), 0),
                result="incomplete",
                last_started_phase=None,
                last_completed_phase=None,
                failure_bucket=None,
                fail_reason=None,
            )
            continue
        if cur is None:
            # Pre-attempt noise; ignore.
            continue
        cur.events.append(ev)
        if ev.phase is Phase.ATTEMPT and ev.kind is Kind.OK:
            cur.result = "ok"
            attempts.append(cur)
            cur = None
            continue
        if ev.phase is Phase.ATTEMPT and ev.kind is Kind.FAIL:
            cur.result = "fail"
            attempts.append(cur)
            cur = None
            continue

        # Milestone phase tracking.
        if ev.phase in _MILESTONE_PHASES:
            if ev.kind is Kind.START:
                cur.last_started_phase = ev.phase
            elif ev.kind is Kind.OK:
                cur.last_completed_phase = ev.phase
            elif ev.kind is Kind.FAIL:
                # Explicit fail wins over the implicit "last started without ok"
                # rule.
                cur.failure_bucket = ev.phase
                cur.fail_reason = ev.kv.get("reason")

    # Stream ended mid-attempt — finalize as incomplete.
    if cur is not None:
        attempts.append(cur)

    # Backfill failure_bucket for attempts where firmware closed with result=fail
    # (or incomplete) without emitting an explicit phase:fail.
    for a in attempts:
        if a.failure_bucket is not None:
            continue
        if a.result == "ok":
            continue
        # Last started without matching ok.
        if a.last_started_phase is not None and (
            a.last_completed_phase is None
            or a.last_completed_phase != a.last_started_phase
        ):
            a.failure_bucket = a.last_started_phase

    return attempts


@dataclass
class CellReport:
    attempts_total: int
    attempts_ok: int
    failures_by_phase: dict[Phase, int]
    attempts: list[AttemptRecord]

    @property
    def success_rate(self) -> float:
        if self.attempts_total == 0:
            return 0.0
        return self.attempts_ok / self.attempts_total


def summarize_cell(attempts: list[AttemptRecord]) -> CellReport:
    ok_count = sum(1 for a in attempts if a.result == "ok")
    fail_buckets: Counter[Phase] = Counter()
    for a in attempts:
        if a.failure_bucket is not None:
            fail_buckets[a.failure_bucket] += 1
    return CellReport(
        attempts_total=len(attempts),
        attempts_ok=ok_count,
        failures_by_phase=dict(fail_buckets),
        attempts=list(attempts),
    )
