"""Tests for tools/e2e_phases.py — the Phase enum source of truth."""
from __future__ import annotations

import pytest

from e2e_phases import (
    Phase,
    Kind,
    Milestone,
    phases_for_milestone,
    deadline_seconds,
)


def test_phase_enum_has_expected_wifi_iter1_phases():
    """Iteration 1 WiFi binary needs exactly these phases reachable from the firmware."""
    values = {p.value for p in Phase}
    assert {"attempt", "scan", "auth", "4whs", "assoc"}.issubset(values)


def test_kind_enum_values_are_lowercase_strings():
    assert {k.value for k in Kind} == {"start", "ok", "fail", "info"}


def test_phases_for_milestone_wifi_returns_ordered_list():
    """The order matters — it's the canonical sequence used by reports."""
    seq = phases_for_milestone(Milestone.WIFI)
    assert seq[:5] == [
        Phase.SCAN, Phase.AUTH, Phase.FOUR_WHS, Phase.ASSOC, Phase.DHCP,
    ]
    # `tcp` is the terminal phase for WiFi.
    assert seq[-1] == Phase.TCP


def test_deadline_seconds_returns_positive_floats():
    for p in Phase:
        d = deadline_seconds(p)
        assert isinstance(d, (int, float))
        assert d > 0


def test_phase_str_value_matches_marker_grammar():
    """Phase.value must be the exact string that appears in `@e2e <name>:...` lines."""
    assert Phase.FOUR_WHS.value == "4whs"
    assert Phase.SCAN.value == "scan"
    assert Phase.ATTEMPT.value == "attempt"


def test_unknown_phase_string_raises():
    """Looking up a name that isn't an enum member must error, not silently fall through."""
    with pytest.raises(ValueError):
        Phase("not_a_phase")
