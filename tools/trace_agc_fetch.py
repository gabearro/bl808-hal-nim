"""Correlate a diagnostic VCD's AGC RAM address bus with a decoded RAM image."""

import argparse
from collections import defaultdict
from collections.abc import Iterator
import csv
from dataclasses import dataclass
from pathlib import Path
import re
import sys

from disasm_agc import decode_image, TARGET_MASK, TRAILER_INDEX


@dataclass(frozen=True)
class Signal:
    code: str
    scope: str
    name: str
    width: int
    select: str | None

    @property
    def qualified(self) -> str:
        return f"{self.scope}.{self.name}" if self.scope else self.name


def directive_body(tokens: Iterator[str]) -> list[str]:
    body = []
    for token in tokens:
        if token == "$end":
            return body
        body.append(token)
    raise ValueError("unterminated VCD directive")


def read_header(tokens: Iterator[str]) -> tuple[str, list[Signal]]:
    scopes = []
    signals = []
    scale = ""
    for token in tokens:
        body = directive_body(tokens)
        if token == "$scope":
            scopes.append(body[1])
        elif token == "$upscope":
            scopes.pop()
        elif token == "$var":
            _, width_text, code, name, *select = body
            width = int(width_text)
            if width == 1 and select and "[" not in name and re.fullmatch(r"\[\d+\]", select[0]):
                name += select[0]
            signals.append(Signal(code, ".".join(scopes), name, width, select[0] if select else None))
        elif token == "$timescale":
            scale = "".join(body)
        elif token == "$enddefinitions":
            return scale, signals
    raise ValueError("VCD is missing $enddefinitions")


def address_signals(
    signals: list[Signal], scope: str | None, address_id: str | None = None
) -> list[Signal]:
    """Accept one nine-bit vector or nine individually named bits."""
    vectors = []
    bits = defaultdict(list)
    for sig in signals:
        if scope is not None and sig.scope != scope:
            continue
        if address_id is not None and sig.code != address_id:
            continue
        if sig.width == 9 and sig.select in (None, "[8:0]") and re.fullmatch(
            r"agcmemaddr(?:\[8:0\])?", sig.name, re.I
        ):
            vectors.append([sig])
        bit = re.fullmatch(r"agcmemaddr\[([0-8])\]", sig.name, re.I)
        if bit and sig.width == 1:
            bits[sig.scope].append((int(bit[1]), sig))
    buses = vectors.copy()
    for group in bits.values():
        ordered = sorted(group, key=lambda item: item[0])
        if [index for index, _ in ordered] == list(range(9)):
            buses.append([sig for _, sig in ordered])
    if len(buses) == 1:
        return buses[0]
    if not buses:
        if address_id is not None:
            raise ValueError(f"VCD identifier {address_id!r} must select a nine-bit AGCMemAddr vector")
        raise ValueError("could not find a complete nine-bit AGCMemAddr bus")
    choices = ", ".join(
        f"{bus[0].scope or '(top)'} ({bus[0].code})" if len(bus) == 1
        else f"{bus[0].scope or '(top)'} (split bits)"
        for bus in buses
    )
    raise ValueError(f"multiple AGCMemAddr buses in {choices}, select --address-scope or --address-id")


def find_signal(signals: list[Signal], name: str) -> Signal:
    matches = [sig for sig in signals if sig.qualified.casefold() == name.casefold()]
    if not matches:
        matches = [sig for sig in signals if sig.name.casefold() == name.casefold()]
    if len(matches) != 1:
        raise ValueError(f"signal {name!r} must identify exactly one VCD variable")
    return matches[0]


def samples(
    tokens: Iterator[str], wanted: set[str]
) -> Iterator[tuple[int, dict[str, str]]]:
    """Yield the final signal values at each timestamp with tracked changes."""
    tick = 0
    values: dict[str, str] = {}
    dirty = False
    for token in tokens:
        lead = token[0].lower()
        if lead == "#":
            new_tick = int(token[1:])
            if new_tick < tick:
                raise ValueError("VCD times must be nondecreasing")
            if new_tick != tick and dirty:
                yield tick, values.copy()
                dirty = False
            tick = new_tick
            continue
        if token == "$comment":
            directive_body(tokens)
            continue
        if token == "$dumpoff":
            dirty = dirty or bool(values)
            values.clear()
            continue
        if lead in "brs":
            code = next(tokens, "")
            value = token[1:].lower()
            if lead != "b":
                continue
        elif lead in "01xz":
            code, value = token[1:], lead
        else:
            continue
        if code in wanted and values.get(code) != value:
            values[code] = value
            dirty = True
    if dirty:
        yield tick, values.copy()


def bus_address(bus: list[Signal], values: dict[str, str]) -> int | None:
    if len(bus) == 1:
        binary = values.get(bus[0].code, "")
    else:
        binary = "".join(values.get(sig.code, "x") for sig in reversed(bus))
    if not re.fullmatch(r"[01]{1,9}", binary):
        return None
    return int(binary, 2)


def word_info(data: bytes) -> list[tuple[str, str, str, str]]:
    states, _, trailer = decode_image(data)
    words = [("PAD", "", "0x00000000", "")] * TRAILER_INDEX
    words.append(("FINAL", "", f"0x{trailer:08X}", ""))
    for state in states:
        owner = f"S{state.index:03X}"
        words[state.index] = ("STATE", owner, f"0x{state.header:08X}", "")
        if state.extension is not None:
            words[state.index + 1] = ("EXT", owner, f"0x{state.extension:08X}", "")
        for index, word in enumerate(state.transitions, state.first_transition):
            words[index] = ("BR", owner, f"0x{word:08X}", f"S{word & TARGET_MASK:03X}")
    return words


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("image", type=Path, help="raw 2048-byte AGC RAM image for the capture")
    parser.add_argument("trace", type=Path, help="text VCD containing AGCMemAddr")
    address = parser.add_mutually_exclusive_group()
    address.add_argument("--address-scope", help="scope of AGCMemAddr if multiple buses are captured")
    address.add_argument("--address-id", help="VCD identifier code for a nine-bit AGCMemAddr vector")
    parser.add_argument("--signal", action="append", default=[], help="additional VCD signal to include")
    args = parser.parse_args()

    try:
        words = word_info(args.image.read_bytes())
        with args.trace.open() as stream:
            tokens = (token for line in stream for token in line.split())
            scale, signals = read_header(tokens)
            bus = address_signals(signals, args.address_scope, args.address_id)
            probes = [find_signal(signals, name) for name in args.signal]
            writer = csv.writer(sys.stdout, lineterminator="\n")
            writer.writerow([
                "tick", "timescale", "fetch_address", "kind", "owner", "word",
                "encoded_branch_target", *(sig.qualified for sig in probes),
            ])
            for tick, values in samples(tokens, {sig.code for sig in bus + probes}):
                index = bus_address(bus, values)
                fields = ("", "UNKNOWN", "", "", "") if index is None else (f"0x{index:03X}", *words[index])
                writer.writerow([tick, scale, *fields, *(values.get(sig.code, "") for sig in probes)])
    except (OSError, ValueError, IndexError) as error:
        parser.exit(1, f"{parser.prog}: {error}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
