"""Tests for the marker parser and aggregators."""
from __future__ import annotations

import pytest

from e2e_phases import Phase, Kind
from e2e_markers import (
    MarkerEvent,
    parse_marker_line,
    AttemptRecord,
    aggregate_attempts,
    CellReport,
    summarize_cell,
)


def test_parse_marker_line_minimal():
    ev = parse_marker_line("@e2e scan:start")
    assert ev == MarkerEvent(phase=Phase.SCAN, kind=Kind.START, kv={})


def test_parse_marker_line_with_kv():
    ev = parse_marker_line("@e2e scan:ok bssid=AA:BB rssi=-58 ch=6")
    assert ev.phase == Phase.SCAN
    assert ev.kind == Kind.OK
    assert ev.kv == {"bssid": "AA:BB", "rssi": "-58", "ch": "6"}


def test_parse_marker_line_ignores_non_marker():
    assert parse_marker_line("[INFO] hello world") is None
    assert parse_marker_line("") is None
    assert parse_marker_line("not a marker @e2e fake:start") is None


def test_parse_marker_line_unknown_phase_raises():
    """A typo in firmware should be loud, not silently dropped."""
    with pytest.raises(ValueError):
        parse_marker_line("@e2e nosuchphase:start")


def test_parse_marker_line_4whs_phase():
    """4whs has a digit prefix — make sure the regex tolerates it."""
    ev = parse_marker_line("@e2e 4whs:ok")
    assert ev.phase == Phase.FOUR_WHS
    assert ev.kind == Kind.OK


def test_aggregate_attempts_happy_path():
    """attempt:start/done frames an attempt; phases inside are bucketed by it."""
    lines = [
        "@e2e attempt:start n=1 total=3",
        "@e2e scan:start",
        "@e2e scan:ok bssid=AA",
        "@e2e auth:start",
        "@e2e auth:ok",
        "@e2e attempt:ok n=1 total=3",
    ]
    events = [parse_marker_line(line) for line in lines]
    attempts = aggregate_attempts(events)
    assert len(attempts) == 1
    a = attempts[0]
    assert a.n == 1
    assert a.total == 3
    assert a.result == "ok"
    assert a.failure_bucket is None
    assert a.last_started_phase == Phase.AUTH
    assert a.last_completed_phase == Phase.AUTH


def test_aggregate_attempts_buckets_by_last_started_without_ok():
    """A phase:start without a matching ok/fail is the failure bucket."""
    lines = [
        "@e2e attempt:start n=1 total=3",
        "@e2e scan:start",
        "@e2e scan:ok",
        "@e2e auth:start",
        "@e2e attempt:fail n=1 total=3",
    ]
    events = [parse_marker_line(line) for line in lines]
    attempts = aggregate_attempts(events)
    assert len(attempts) == 1
    assert attempts[0].result == "fail"
    assert attempts[0].failure_bucket == Phase.AUTH


def test_aggregate_attempts_explicit_fail_marker_wins():
    """If firmware emits phase:fail, that's the bucket regardless of subsequent state."""
    lines = [
        "@e2e attempt:start n=1 total=3",
        "@e2e scan:start",
        "@e2e scan:fail reason=no_match",
        "@e2e attempt:fail n=1 total=3",
    ]
    events = [parse_marker_line(line) for line in lines]
    attempts = aggregate_attempts(events)
    assert attempts[0].failure_bucket == Phase.SCAN
    assert attempts[0].fail_reason == "no_match"


def test_aggregate_attempts_skips_pre_attempt_noise():
    """Phase events emitted before the first attempt:start are ignored."""
    lines = [
        "@e2e scan:start",
        "@e2e scan:ok",
        "@e2e attempt:start n=1 total=1",
        "@e2e auth:start",
        "@e2e auth:ok",
        "@e2e attempt:ok n=1 total=1",
    ]
    events = [parse_marker_line(line) for line in lines]
    attempts = aggregate_attempts(events)
    assert len(attempts) == 1
    assert attempts[0].last_completed_phase == Phase.AUTH


def test_summarize_cell_reports_per_phase_success_rate():
    attempts = [
        AttemptRecord(n=1, total=3, result="ok", last_started_phase=Phase.ASSOC,
                      last_completed_phase=Phase.ASSOC, failure_bucket=None,
                      fail_reason=None),
        AttemptRecord(n=2, total=3, result="fail", last_started_phase=Phase.AUTH,
                      last_completed_phase=Phase.SCAN, failure_bucket=Phase.AUTH,
                      fail_reason="timeout"),
        AttemptRecord(n=3, total=3, result="ok", last_started_phase=Phase.ASSOC,
                      last_completed_phase=Phase.ASSOC, failure_bucket=None,
                      fail_reason=None),
    ]
    report = summarize_cell(attempts)
    assert isinstance(report, CellReport)
    assert report.attempts_total == 3
    assert report.attempts_ok == 2
    assert report.success_rate == pytest.approx(2 / 3)
    # auth was the failure bucket once
    assert report.failures_by_phase[Phase.AUTH] == 1
    # scan succeeded all three times (bucket counts only failures)
    assert report.failures_by_phase.get(Phase.SCAN, 0) == 0


def test_aggregate_attempts_double_start_preserves_first_as_incomplete():
    """Firmware bug: two attempt:start without a close in between. The first
    must be preserved as result='incomplete', not silently dropped."""
    lines = [
        "@e2e attempt:start n=1 total=2",
        "@e2e scan:start",
        "@e2e attempt:start n=2 total=2",
        "@e2e auth:start",
        "@e2e auth:ok",
        "@e2e attempt:ok n=2 total=2",
    ]
    events = [parse_marker_line(line) for line in lines]
    attempts = aggregate_attempts(events)
    assert len(attempts) == 2
    assert attempts[0].n == 1
    assert attempts[0].result == "incomplete"
    assert attempts[0].last_started_phase == Phase.SCAN
    assert attempts[1].n == 2
    assert attempts[1].result == "ok"
