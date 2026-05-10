"""Tests for the Nim Phase enum generator."""
from __future__ import annotations

import pytest

from gen_e2e_marker_nim import (
    render_phase_block,
    splice_into_file,
    BEGIN_SENTINEL,
    END_SENTINEL,
    DEFAULT_TARGET,
)


def test_render_phase_block_includes_all_python_phases():
    block = render_phase_block()
    # Each Python Phase value must appear as a Nim enum member.
    for name in ("attempt", "scan", "auth", "4whs", "assoc",
                 "dhcp", "tcp", "adv_start"):
        assert f'"{name}"' in block, f"missing {name} in generated block"


def test_render_phase_block_is_deterministic():
    """Repeat calls return identical text — required for stable diffs."""
    assert render_phase_block() == render_phase_block()


def test_render_phase_block_contains_kind_enum():
    block = render_phase_block()
    assert "Kind* = enum" in block
    for k in ("start", "ok", "fail", "info"):
        assert f'"{k}"' in block


def test_splice_into_file_replaces_block_between_sentinels(tmp_path):
    p = tmp_path / "e2e_marker.nim"
    p.write_text(
        "header line\n"
        f"{BEGIN_SENTINEL}\n"
        "OLD CONTENT\n"
        f"{END_SENTINEL}\n"
        "footer line\n"
    )
    splice_into_file(p, "NEW CONTENT\n")
    text = p.read_text()
    assert "OLD CONTENT" not in text
    assert "NEW CONTENT" in text
    assert text.startswith("header line\n")
    assert text.endswith("footer line\n")
    assert text.count(BEGIN_SENTINEL) == 1
    assert text.count(END_SENTINEL) == 1


def test_splice_into_file_errors_when_sentinels_missing(tmp_path):
    p = tmp_path / "no_sentinels.nim"
    p.write_text("just some content\n")
    with pytest.raises(ValueError):
        splice_into_file(p, "anything\n")


def test_nim_file_matches_generator_output():
    """Fail loud if e2e_phases.py was edited but the generator wasn't re-run.

    Iteration 2+ will add new phases. Without this test the Nim Phase enum can
    silently desync from Python until something explodes at runtime.
    """
    text = DEFAULT_TARGET.read_text()
    head, _, rest = text.partition(BEGIN_SENTINEL)
    current_block, _, _ = rest.partition(END_SENTINEL)
    expected = render_phase_block()
    assert current_block.strip() == expected.strip(), (
        f"\n{DEFAULT_TARGET} is out of sync with tools/e2e_phases.py.\n"
        f"Run: python tools/gen_e2e_marker_nim.py\n"
    )
