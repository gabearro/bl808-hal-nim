"""Generate the Nim Phase + Kind enums into src/bl808/kernel/e2e_marker.nim.

The hand-written Nim file contains two sentinel comments. This script splices
the generated block in between them, leaving the rest untouched.

Run: python tools/gen_e2e_marker_nim.py
"""
from __future__ import annotations

import sys
from pathlib import Path

from e2e_phases import Kind, Phase

BEGIN_SENTINEL = "## --- BEGIN GENERATED PHASE/KIND ENUM (do not edit by hand) ---"
END_SENTINEL = "## --- END GENERATED PHASE/KIND ENUM ---"

DEFAULT_TARGET = (
    Path(__file__).resolve().parent.parent
    / "src" / "bl808" / "kernel" / "e2e_marker.nim"
)


def render_phase_block() -> str:
    """Render the Nim source for the Phase + Kind enums."""
    lines: list[str] = []
    lines.append("type")
    lines.append("  Phase* = enum")
    for p in Phase:
        # Nim identifier from value: replace non-ident chars and prefix digits.
        ident = _nim_ident(p.value, prefix="ph")
        lines.append(f'    {ident} = "{p.value}"')
    lines.append("")
    lines.append("  Kind* = enum")
    for k in Kind:
        ident = _nim_ident(k.value, prefix="kn")
        lines.append(f'    {ident} = "{k.value}"')
    lines.append("")
    return "\n".join(lines)


def _nim_ident(value: str, *, prefix: str) -> str:
    """Convert a marker value into a valid Nim identifier.

    Rules: lowercase, underscores allowed; digits can't lead → prefix them;
    any other char (none today, but defensive) becomes '_'.
    """
    safe = "".join(c if (c.isalnum() or c == "_") else "_" for c in value)
    if not safe or safe[0].isdigit():
        safe = f"{prefix}{safe.capitalize()}"
    return safe


def splice_into_file(path: Path, block: str) -> None:
    text = path.read_text()
    if BEGIN_SENTINEL not in text or END_SENTINEL not in text:
        raise ValueError(
            f"Sentinels missing in {path}; expected:\n  {BEGIN_SENTINEL}\n  {END_SENTINEL}"
        )
    head, _, rest = text.partition(BEGIN_SENTINEL)
    _, _, tail = rest.partition(END_SENTINEL)
    new_text = (
        head
        + BEGIN_SENTINEL
        + "\n"
        + block.rstrip("\n")
        + "\n"
        + END_SENTINEL
        + tail
    )
    path.write_text(new_text)


def main(argv: list[str]) -> int:
    target = Path(argv[1]) if len(argv) > 1 else DEFAULT_TARGET
    splice_into_file(target, render_phase_block())
    print(f"Generated Phase/Kind enums into {target}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
