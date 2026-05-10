"""Tests for tools/hw_e2e.py orchestrator (parser path, mocked I/O)."""
from __future__ import annotations

import io
from pathlib import Path

import pytest

from e2e_phases import Phase
from hw_e2e import (
    drive_uart_for_attempts,
    write_cell_report_json,
    print_cell_summary,
)


def test_drive_uart_for_attempts_collects_n_attempts():
    """Parser reads UART line-by-line and returns when N attempts are seen."""
    uart_lines = [
        "boot banner ignored\n",
        "@e2e attempt:start n=1 total=2\n",
        "@e2e scan:start\n",
        "@e2e scan:ok\n",
        "@e2e auth:start\n",
        "@e2e auth:ok\n",
        "@e2e attempt:ok n=1 total=2\n",
        "@e2e attempt:start n=2 total=2\n",
        "@e2e scan:start\n",
        "@e2e scan:fail reason=no_match\n",
        "@e2e attempt:fail n=2 total=2\n",
        "ignored trailing line\n",
    ]
    fake = io.StringIO("".join(uart_lines))
    attempts = drive_uart_for_attempts(fake, expected_attempts=2, overall_timeout_s=10)
    assert len(attempts) == 2
    assert attempts[0].result == "ok"
    assert attempts[1].result == "fail"
    assert attempts[1].failure_bucket == Phase.SCAN


def test_write_cell_report_json_round_trip(tmp_path):
    from e2e_markers import AttemptRecord, summarize_cell
    attempts = [
        AttemptRecord(n=1, total=1, result="ok",
                      last_started_phase=Phase.ASSOC,
                      last_completed_phase=Phase.ASSOC,
                      failure_bucket=None, fail_reason=None),
    ]
    report = summarize_cell(attempts)
    out = tmp_path / "report.json"
    write_cell_report_json(
        out, cell_name="wifi-blob", report=report, extra={"firmware": "x.bin"})
    text = out.read_text()
    assert '"cell_name": "wifi-blob"' in text
    assert '"attempts_total": 1' in text
    assert '"attempts_ok": 1' in text
    assert '"firmware": "x.bin"' in text


def test_print_cell_summary_emits_per_phase_table(capsys):
    from e2e_markers import AttemptRecord, summarize_cell
    attempts = [
        AttemptRecord(n=1, total=2, result="ok",
                      last_started_phase=Phase.ASSOC,
                      last_completed_phase=Phase.ASSOC,
                      failure_bucket=None, fail_reason=None),
        AttemptRecord(n=2, total=2, result="fail",
                      last_started_phase=Phase.AUTH,
                      last_completed_phase=Phase.SCAN,
                      failure_bucket=Phase.AUTH, fail_reason="timeout"),
    ]
    report = summarize_cell(attempts)
    print_cell_summary("wifi-blob", report)
    out = capsys.readouterr().out
    assert "wifi-blob" in out
    assert "1/2" in out  # ok count
    assert "auth" in out  # phase that failed
