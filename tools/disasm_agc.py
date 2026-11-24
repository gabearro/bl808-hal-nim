"""Disassemble a 512-word BL808 AGC RAM image into states and transitions."""

import argparse
from collections.abc import Iterator
from contextlib import redirect_stdout
from dataclasses import dataclass
from io import StringIO
from pathlib import Path
import struct
import sys


IMAGE = struct.Struct("<512I")
TRAILER_INDEX = IMAGE.size // 4 - 1
TARGET_MASK = 0x1FF
TIMER_FLAG = 1 << 27
STATE_BIT26 = 1 << 26
DELAY_LOW_MASK = 0x7FF

# Two controlled BL808 RAM traces measured every row of each combiner.
# The annotated listing prints the encoded operands alongside these forms.
PREDICATE_FORMS = {
    0: "{a} | {b} | {c}",
    1: "{a} & {b} & {c}",
    2: "({a} | {b}) & {c}",
    3: "({a} & {b}) | {c}",
    4: "{a} | {b} | !{c}",
    5: "{a} & {b} & !{c}",
    6: "({a} | {b}) & !{c}",
    7: "{a} & !{b} & !{c}",
}
SIMPLE_TRANSITIONS = {
    (1, 1, 1, 1): "jump",
    (0, 2, 0, 0): "on timer expiry",
    (0, 0, 2, 0): "on timer expiry",
    (0, 0, 0, 2): "on timer expiry",
    (1, 2, 1, 1): "on timer expiry",
    (1, 1, 2, 1): "on timer expiry",
    (1, 1, 1, 2): "on timer expiry",
    (3, 0, 0, 2): "on timer expiry",
}

# These roles describe where the exact words are used in the pinned BL808
# Wi-Fi program. Candidate physical assignments are marked as such.
EXTENSION_ROLES = {
    0x01000000: "acquisition entry setup",
    0x0D001401: "setup on the saturation route",
    0x0EF1EE07: "receive setup after the first result or on the late P21 branch",
    0x0EF1F10B: "setup at the DSSS-associated entry",
    0x0FF1EE07: "alternate receive setup on the late !P21 branch",
    0x10000231: "gain-event form, middle byte=0x02, payload bit 4=1",
    0x1404051C: "third stage of the index-2 startup profile",
    0x14040523: "third stage of the index-4 startup profile",
    0x1404052D: "third stage of the index-6 startup profile",
    0x1404053A: "third stage of the index-8 startup profile",
    0x1F102021: "timed setup before the second parameter decision",
    0x1F191910: "setup before the first parameter decision",
    0x1F1E2331: "setup before the acquisition retry decision",
    0x1F242010: "setup at the alternate entry to the first decision",
    0x21000003: "setup before the middle-byte result decision",
    0x21000303: "setup before the two-byte result decision",
    0x32000000: "receive setup or return",
    0x32000001: "setup before the second parameter decision, payload bit 0=1",
    0x32000100: "setup before the DSSS-associated waits, payload bit 8=1",
    0x34000000: "timed DSSS-associated setup",
    0x3D000101: "setup on the saturation or gain-event route",
    0x3D000303: "acquisition or receive setup",
    0x3D010101: "setup on the P30 extended wait route",
    0x3D030303: "setup before the shared late return",
    0x3E000100: "setup on the saturation or gain-event route",
    0x3E000200: "setup before the acquisition retry decision",
    0x3E000201: "setup before the second parameter decision",
    0x3F000102: "setup after 0x3D000303 and before 0x1F102021",
    0x40000001: "timed common setup before selector 44",
    0x4100000F: "receive setup, wait, or return action",
    0x41000F00: "acquisition retry action",
    0x44002001: "common setup, bits 15:8 are a DSSS threshold candidate",
    0x5B000000: "saturation event entry action",
    0x60000000: "setup on a route to the gain-event word 0x10000231",
    0x6E000000: "setup at the alternate entry to the late decision",
}


@dataclass(frozen=True)
class State:
    index: int
    header: int
    extension: int | None
    transitions: tuple[int, ...]

    @property
    def first_transition(self) -> int:
        return self.index + 1 + (self.extension is not None)


def decode_image(data: bytes) -> tuple[list[State], int, int]:
    if len(data) != IMAGE.size:
        raise ValueError(f"expected {IMAGE.size} bytes, got {len(data)}")

    words = IMAGE.unpack(data)
    states = []
    index = 0
    # Check for padding at state boundaries so zero operand words inside a
    # state are still consumed.
    while any(words[index:TRAILER_INDEX]):
        header = words[index]
        count = header >> 29
        has_extension = bool(header & (1 << 28))
        first_transition = index + 1 + has_extension
        end = first_transition + count
        if count == 0 or end > TRAILER_INDEX:
            raise ValueError(f"invalid state header 0x{header:08X} at word 0x{index:03X}")

        extension = words[index + 1] if has_extension else None
        states.append(State(index, header, extension, words[first_transition:end]))
        index = end

    if not states:
        raise ValueError("image has no states")
    return states, index, words[TRAILER_INDEX]


def event_fields(word: int) -> tuple[int, int, int, int, int, int]:
    """Return the public RIU event fields and the raw value of bit 9."""
    return (
        word >> 26,
        (word >> 20) & 0x3F,
        (word >> 14) & 0x3F,
        (word >> 13) & 1,
        (word >> 10) & 7,
        (word >> 9) & 1,
    )


def encode_image(states: list[State], trailer: int) -> bytes:
    """Pack the decoded record fields, preserving opaque control and data."""
    words = []
    for state in states:
        header = (
            (len(state.transitions) << 29)
            | ((state.extension is not None) << 28)
            | (state.header & 0x0FFFFFFF)
        )
        words.append(header)
        if state.extension is not None:
            words.append(state.extension)
        for word in state.transitions:
            a, b, c, pathcomb, opcomb, bit9 = event_fields(word)
            words.append(
                (a << 26) | (b << 20) | (c << 14) | (pathcomb << 13)
                | (opcomb << 10) | (bit9 << 9) | (word & TARGET_MASK)
            )
    words.extend([0] * (TRAILER_INDEX - len(words)))
    words.append(trailer)
    return IMAGE.pack(*words)


def print_listing(states: list[State], code_end: int, trailer: int) -> None:
    transitions = sum(len(state.transitions) for state in states)
    print(f"# {len(states)} states, {transitions} transitions")
    print("# Addresses are word indices. Transition fields use the public RIU event layout.")
    for state in states:
        ext = "" if state.extension is None else f"  ext=0x{state.extension:08X}"
        print(f"S{state.index:03X}: header=0x{state.header:08X}{ext}")
        for index, word in enumerate(state.transitions, state.first_transition):
            op1, op2, op3, pathcomb, opcomb, bit9 = event_fields(word)
            print(
                f"  {index:03X}: 0x{word:08X} -> S{word & TARGET_MASK:03X}"
                f"  op1=0x{op1:02X} op2=0x{op2:02X} op3=0x{op3:02X}"
                f" pathcomb={pathcomb} opcomb={opcomb} bit9={bit9}"
            )

    if code_end < TRAILER_INDEX:
        print(f"# Padding words 0x{code_end:03X}–0x{TRAILER_INDEX - 1:03X}")
    print(f"# Final word 0x{TRAILER_INDEX:03X} = 0x{trailer:08X}")


def describe_predicate(opcomb: int, op1: int, op2: int, op3: int) -> str:
    if opcomb == 0 and 1 in (op1, op2, op3):
        return "jump"
    if opcomb == 1 and 0 in (op1, op2, op3):
        return "never"

    simple = SIMPLE_TRANSITIONS.get((opcomb, op1, op2, op3))
    if simple is not None:
        return simple

    form = PREDICATE_FORMS.get(opcomb)
    if form is None:
        return "on encoded predicate"

    names = {0: "false", 1: "true", 2: "timer"}
    a, b, c = (names.get(op, f"P{op:02X}") for op in (op1, op2, op3))
    return "if " + form.format(a=a, b=b, c=c)


def describe_extension(selector: int, payload: int) -> str:
    """Label observed BL808 extension payload forms."""
    high = payload >> 16
    middle = (payload >> 8) & 0xFF
    low = payload & 0xFF
    if high == 0:
        if selector == 0x10 and low == 0x21 and middle <= 8:
            return f"startup LNA index?={middle}, payload bit 4=0"
        if selector == 0x0C and low == 0x03:
            return f"RF gain ceiling code?=0x{middle:02X}"
        if selector == 0x22 and low == 0x9C:
            return f"in-band floor?=-100 dBm (0x9C), middle byte=0x{middle:02X}"
    if selector == 0x29 and payload == 0:
        return "zero result or setup"
    if (
        selector == 0x29
        and low <= 2
        and high in (0, 1, 3)
        and middle in (0, 1, 3)
        and not (high and middle)
    ):
        return f"stage code={low}, middle result={middle}, high result={high}"
    return EXTENSION_ROLES.get((selector << 24) | payload, "effect unresolved")


def annotated_record(state: State) -> Iterator[str]:
    timer = "off"
    bit26 = ", bit26=1" if state.header & STATE_BIT26 else ""
    delay_line = (state.header >> 2) & 1
    power_estimator = (state.header >> 3) & 1
    if state.header & TIMER_FLAG:
        delay = (state.header >> 15) & DELAY_LOW_MASK
        timer = str(delay)
    extension = "yes" if state.extension is not None else "no"
    yield (
        f"{state.index:03X}   {state.header:08X}  STATE  "
        f"S{state.index:03X}, {len(state.transitions)} transitions, extension={extension}, "
        f"timer_count={timer}{bit26}, delay_line_en={delay_line}, "
        f"inbd20_pow_est_en={power_estimator}, "
        f"control[14:0]=0x{state.header & 0x7FFF:04X}"
    )
    if state.extension is not None:
        selector = state.extension >> 24
        payload = state.extension & 0xFFFFFF
        yield (
            f"{state.index + 1:03X}   {state.extension:08X}  EXT    "
            f"selector=0x{selector:02X} ({selector}), payload=0x{payload:06X}, "
            f"{describe_extension(selector, payload)}"
        )
    for index, word in enumerate(state.transitions, state.first_transition):
        op1, op2, op3, pathcomb, opcomb, bit9 = event_fields(word)
        predicate = "on encoded predicate"
        if pathcomb == 0 and bit9 == 0:
            predicate = describe_predicate(opcomb, op1, op2, op3)
        prior = state.transitions.index(word) + state.first_transition
        duplicate = f", duplicates {prior:03X}" if prior < index else ""
        yield (
            f"{index:03X}   {word:08X}  BR     {predicate} -> S{word & TARGET_MASK:03X}"
            f"  [ops={op1:02X},{op2:02X},{op3:02X} comb={opcomb} path={pathcomb} bit9={bit9}{duplicate}]"
        )


def print_annotated(states: list[State], code_end: int, trailer: int) -> None:
    transitions = sum(len(state.transitions) for state in states)
    print(f"# {len(states)} states, {transitions} transitions")
    print("# ? marks inferred behavior. Pxx denotes an encoded predicate ID.")
    print("# Extension notes describe uses in the pinned BL808 Wi-Fi program.")
    print("# Header bit 2 tracks RIU bank 02[14] and bank 05[4] in controlled BL808 runs.")
    print("# Header bit 3 tracks RIU bank 02[13] in controlled BL808 runs.")
    print("# Header bits 3+10 together activate RIU bank 01[9] in parked BL808 runs.")
    print("# Word  Raw       Type   Interpretation and encoded fields")
    for state in states:
        for line in annotated_record(state):
            print(line)
    if code_end < TRAILER_INDEX:
        print(f"{code_end:03X}–{TRAILER_INDEX - 1:03X}        PAD    zero fill")
    print(f"{TRAILER_INDEX:03X}   {trailer:08X}  FINAL  outside the decoded state graph, hardware use unresolved")


def verify_listing(path: Path, states: list[State], code_end: int, trailer: int) -> None:
    """Check that the documented complete listing is generated from this image."""
    document = path.read_text()
    heading = "## Complete annotated listing\n"
    if heading not in document:
        raise ValueError(f"{path}: missing complete annotated listing heading")
    section = document.split(heading, 1)[1]
    opening = "```text\n"
    if opening not in section:
        raise ValueError(f"{path}: missing listing code fence")
    section = section.split(opening, 1)[1]
    if "\n```" not in section:
        raise ValueError(f"{path}: missing closing listing code fence")
    documented = section.split("\n```", 1)[0].splitlines()

    generated_output = StringIO()
    with redirect_stdout(generated_output):
        print_annotated(states, code_end, trailer)
    generated = generated_output.getvalue().splitlines()
    if documented != generated:
        first = next(
            (index for index, pair in enumerate(zip(documented, generated), 1)
             if pair[0] != pair[1]),
            min(len(documented), len(generated)) + 1,
        )
        raise ValueError(
            f"{path}: annotated listing differs at line {first} "
            f"(documented {len(documented)} lines, generated {len(generated)} lines)"
        )


def print_word(index: int, states: list[State], code_end: int, trailer: int) -> None:
    if index == TRAILER_INDEX:
        print(f"{index:03X}   {trailer:08X}  FINAL  outside the decoded state graph, hardware use unresolved")
    elif index >= code_end:
        print(f"{index:03X}   00000000  PAD    zero fill")
    else:
        state = next(state for state in reversed(states) if state.index <= index)
        print(f"# Owner S{state.index:03X}, byte offset 0x{index * 4:03X}")
        print(list(annotated_record(state))[index - state.index])


def print_graph(states: list[State]) -> None:
    print("digraph agc {")
    for state in states:
        print(f'  S{state.index:03X} [label="S{state.index:03X}\\n0x{state.header:08X}"];')
        for word in state.transitions:
            print(f'  S{state.index:03X} -> S{word & TARGET_MASK:03X} [label="0x{word:08X}"];')
    print("}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("image", type=Path, help="raw 2048-byte little-endian AGC RAM image")
    output = parser.add_mutually_exclusive_group()
    output.add_argument("--dot", action="store_true", help="emit a Graphviz control-flow graph")
    output.add_argument("--annotate", action="store_true", help="include inferred BL808 instruction behavior")
    output.add_argument("--word", type=lambda value: int(value, 0), help="classify a word index, such as 0x04E")
    output.add_argument("--verify-encoding", action="store_true", help="repack decoded fields and compare all image bytes")
    output.add_argument("--verify-listing", type=Path, metavar="MARKDOWN", help="compare the complete annotated listing with a Markdown file")
    args = parser.parse_args()
    if args.word is not None and not 0 <= args.word <= TRAILER_INDEX:
        parser.error(f"word index must be in 0x000..0x{TRAILER_INDEX:03X}")

    try:
        data = args.image.read_bytes()
        states, code_end, trailer = decode_image(data)
    except (OSError, ValueError) as error:
        parser.exit(1, f"{parser.prog}: {error}\n")

    if args.dot:
        print_graph(states)
    elif args.annotate:
        print_annotated(states, code_end, trailer)
    elif args.word is not None:
        print_word(args.word, states, code_end, trailer)
    elif args.verify_encoding:
        if encode_image(states, trailer) != data:
            parser.exit(1, f"{parser.prog}: re-encoded data differs from input\n")
        print(f"Re-encoded all {len(data)} bytes exactly.")
    elif args.verify_listing is not None:
        try:
            verify_listing(args.verify_listing, states, code_end, trailer)
        except (OSError, ValueError) as error:
            parser.exit(1, f"{parser.prog}: {error}\n")
        print(f"Annotated listing matches {args.verify_listing} exactly.")
    else:
        print_listing(states, code_end, trailer)

    state_starts = {state.index for state in states}
    valid = True
    for state in states:
        for index, word in enumerate(state.transitions, state.first_transition):
            target = word & TARGET_MASK
            if target not in state_starts:
                valid = False
                print(
                    f"{parser.prog}: word 0x{index:03X} targets 0x{target:03X}, "
                    "which is outside the decoded state starts",
                    file=sys.stderr,
                )
    return 0 if valid else 1


if __name__ == "__main__":
    sys.exit(main())
