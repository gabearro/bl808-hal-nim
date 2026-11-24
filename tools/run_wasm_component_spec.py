#!/usr/bin/env python3
"""Run a defined subset of the pinned upstream Component Model WAST tests."""

import argparse
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "build" / "wasm-component" / "upstream"
REVISION = "585526aa1f2c7f76f07557d16e265dede38b3acb"

WAST_FILES = (
    "binary/binary.wast",
    "linking/unit.wast",
    "linking/tags.wast",
    "validation/abi.wast",
    "validation/defined-types.wast",
    "validation/kebab.wast",
    "validation/extern-names.wast",
    "validation/external-visibility.wast",
    "validation/instantiation.wast",
    "validation/core-modules.wast",
    "validation/outer-alias.wast",
    "validation/indicies.wast",
    "validation/resources.wast",
    "values/numerics.wast",
    "values/strings.wast",
    "values/transcode.wast",
    "values/realloc.wast",
    "values/alignment.wast",
    "values/concat.wast",
    "values/variants.wast",
    "resources/handle-table.wast",
    "resources/borrows.wast",
    "resources/multiple-resources.wast",
)
LINKING_UNIT_FIXTURES = {1230, 1267, 1318, 1362, 1418, 1468, 1535, 1569, 1595, 1639}
ABI_REJECTIONS = {
    39: "unknown canonical lower memory",
    49: "composite signature needs canonical memory",
    56: "composite signature needs canonical memory",
    73: "composite input needs canonical realloc",
    84: "composite input needs canonical realloc",
    99: "string import result needs canonical realloc",
    134: "duplicate canonical string encoding",
    140: "duplicate canonical string encoding",
    146: "duplicate canonical string encoding",
    155: "duplicate canonical memory",
    165: "duplicate canonical realloc",
    180: "duplicate canonical post-return",
    201: "invalid canonical realloc function",
    215: "invalid canonical post-return function",
    232: "unsupported canonical lower option",
    251: "canonical function type mismatch",
    258: "canonical function type mismatch",
}
TRAPS = {
    "string pointer/length out of bounds of memory": "linear memory range out of bounds",
    "invalid utf-8": "invalid UTF-8 canonical string",
    "incomplete utf-8 byte sequence": "invalid UTF-8 canonical string",
    "realloc return: beyond end of memory": "linear memory range out of bounds",
    "realloc return: result not aligned": "unaligned canonical realloc result",
    "invalid `char` bit pattern": "invalid canonical Unicode scalar",
    "invalid variant discriminant": "canonical variant discriminant out of range",
    "cannot remove owned resource while borrowed": "crBorrowActive",
    **dict.fromkeys((f"unknown handle index {index}" for index in (0, 1, 3, 5, 4294967295)),
                    "crInvalidHandle"),
    ("handle index 1 used with the wrong type, expected guest-defined resource "
     "but found a different guest-defined resource"): "crInvalidType",
}
ALIGNMENT_TRAPS = {
    27: "unaligned canonical record result",
    52: "unaligned canonical return area",
    82: "unaligned canonical realloc result",
    111: "unaligned canonical argument area",
    139: "unaligned canonical string pointer",
    171: "unaligned canonical string pointer",
    173: "unaligned canonical string pointer",
    205: "linear memory range out of bounds",
    207: "linear memory range out of bounds",
}
TAG_REJECTIONS = {
    138: "invalid core export alias",
    146: "unknown inline core external",
}
DEFINED_TYPE_REJECTIONS = {
    **dict.fromkeys((32, 35, 38, 41, 44, 71, 74, 77, 80), "invalid Component Model label"),
    50: "duplicate component record field",
    **dict.fromkeys((53, 56), "duplicate component variant case"),
    59: "duplicate component flag",
    62: "duplicate component enum case",
    65: "duplicate component parameter",
    86: "empty component variant",
    89: "empty component enum",
    **dict.fromkeys((92, 98), "empty component record or tuple"),
    95: "empty component flags",
    111: "component count limit",
    **dict.fromkeys((122, 127, 132, 140, 143, 146, 149, 152, 155),
                    "unsupported component value type index"),
    **dict.fromkeys((162, 180), "unknown component import type"),
    165: "unknown component function type",
    171: "unknown core module value",
    174: "unknown exported component instance",
    185: "component function export annotation type mismatch",
    193: "unknown component contract function type",
    **dict.fromkeys((199, 205), "invalid interface method type"),
    **dict.fromkeys((215, 220, 226), "unknown component interface type"),
    **dict.fromkeys((235, 240, 246), "unknown core module type"),
}
VISIBILITY_REJECTIONS = {
    20: "resource result type is not exported",
    29: "resource result type is not exported",
    39: "resource result type is not imported",
    46: "resource result type is not imported",
    62: "named component result type is not externally visible",
    71: "named component result type is not externally visible",
    112: "named component result type is not externally visible",
    131: "named component result type is not externally visible",
    150: "named component result type is not externally visible",
    **dict.fromkeys((239, 276, 283, 290),
                    "named component list element type is not externally visible"),
    **dict.fromkeys((232, 246),
                    "named component field type is not externally visible"),
    **dict.fromkeys((253, 260, 267),
                    "named component case payload type is not externally visible"),
    **dict.fromkeys((313, 329, 338, 369, 385), "named component field type is not externally visible"),
    **dict.fromkeys((347, 354), "named component result type is not externally visible"),
    378: "named component parameter type is not externally visible",
    395: "resource result type is not imported",
    **dict.fromkeys((490, 498), "named component result type is not externally visible"),
}
INSTANTIATION_REJECTIONS = {
    **dict.fromkeys((62, 71, 80, 89, 98, 107, 116, 125, 134, 143, 152, 161,
                     170, 179, 188, 197, 206),
                   "component instantiation value type mismatch"),
    **dict.fromkeys((224, 231, 238, 245, 252),
                   "component instantiation argument type mismatch"),
    298: "core module import type mismatch: :f",
    306: "core module requires import: :extra",
    314: "core module lacks export: x",
    322: "core module export type mismatch: g",
    **dict.fromkeys((484, 491), "component instantiation argument sort mismatch"),
    510: "duplicate component instantiation argument",
    560: "unknown inline instance function",
    564: "unknown inline instance",
    600: "unknown component instantiation instance",
    606: "unknown component instantiation function",
    620: "unknown nested interface export",
    627: "unknown component instance",
    632: "unknown component instance function",
}
CORE_MODULE_REJECTIONS = {
    25: "invalid embedded core module",
    37: "unknown core function type",
    **dict.fromkeys((44, 63, 73), "duplicate core module export"),
    52: "invalid core module memory limits",
    **dict.fromkeys((87, 95, 103, 111), "duplicate core module import"),
}
OUTER_ALIAS_REJECTIONS = {
    **dict.fromkeys((40, 47, 55, 63, 70, 82, 90), "outer type alias refers to a resource"),
    174: "unsupported component contract type alias",
    183: "unsupported component contract type alias",
    190: "unsupported component contract core alias",
    197: "unsupported interface type alias",
    **dict.fromkeys((206, 213, 231), "unknown component defined value type"),
    **dict.fromkeys((220, 227), "unknown outer type scope"),
    **dict.fromkeys((240, 248, 256), "unknown outer type scope"),
    244: "unknown outer core type",
    252: "unknown core module value",
    260: "unknown component definition",
}
RESOURCE_REJECTIONS = {
    7: "component instantiation resource equality mismatch",
    29: "component instantiation resource equality mismatch",
    73: "component instantiation argument type mismatch",
    92: "component instantiation argument type mismatch",
    103: "component instantiation argument type mismatch",
    **dict.fromkeys((168, 181, 201, 212, 223, 242, 261),
                    "component instantiation argument type mismatch"),
    **dict.fromkeys((281, 302), "component instantiation value resource type mismatch"),
    462: "component instantiation resource equality mismatch",
    546: "component instantiation argument type mismatch",
    669: "missing component instantiation resource argument",
    678: "unknown resource type in handle",
    683: "unknown resource type in handle",
    702: "component function result contains a borrowed resource",
    **dict.fromkeys((708, 714, 720), "component function result contains a borrowed resource"),
    **dict.fromkeys((730, 736), "resource definitions require a concrete component"),
    751: "invalid core resource destructor type",
    759: "unknown core resource destructor",
    **dict.fromkeys((766, 772, 778, 784, 804),
                    "canonical function requires a local resource type"),
    791: "canonical function requires a local resource type",
    797: "canonical function requires a local resource type",
}


def run(*args):
    subprocess.run(args, cwd=ROOT, check=True, timeout=120)


def selected_invocation(suite, filename):
    if suite in ("strings", "tags"):
        return True
    if suite == "transcode":
        return filename in {f"transcode.{index}.wasm" for index in range(5)}
    if suite == "numerics":
        return filename in {f"numerics.{index}.wasm" for index in range(6)}
    if suite == "variants":
        return filename == "variants.0.wasm"
    if suite == "concat":
        return filename == "concat.0.wasm"
    if suite in ("handle-table", "borrows", "multiple-resources"):
        return filename is not None
    return suite == "realloc" and filename in ("realloc.3.wasm", "realloc.4.wasm")


def select_commands(path, commands, output):
    suite = Path(path).stem
    definitions = {}
    current = None
    current_line = None
    instance = 0
    tests = []
    skipped = 0
    for command in commands:
        kind = command["type"]
        line = command["line"]
        test = None
        if kind == "module_definition":
            definitions[command.get("name")] = command["filename"]
            if suite == "extern-names" or (suite == "external-visibility" and
                                         line in (160, 220, 306, 322, 363, 402, 410, 420,
                                                  511, 520, 531, 543, 563)):
                test = {"kind": "validate", "filename": command["filename"]}
            elif suite == "instantiation" and line in (218, 262):
                test = {"kind": "validate", "filename": command["filename"]}
            elif suite == "core-modules" and line == 7:
                test = {"kind": "validate", "filename": command["filename"]}
            elif suite == "outer-alias" and line in (7, 26, 98, 106, 121, 132, 156, 265):
                test = {"kind": "validate", "filename": command["filename"]}
            elif suite == "resources" and line in (19, 39, 48, 64, 83, 112, 157, 192, 233, 252):
                test = {"kind": "validate", "filename": command["filename"]}
        elif kind in ("module", "module_instance"):
            current = (command["filename"] if kind == "module"
                       else definitions[command["module"]])
            current_line = line
            instance += 1
            if suite == "binary" and line <= 281 and line != 127:
                test = {"kind": "instantiate", "filename": current}
            # Line 342 needs the core multi-memory proposal.
            elif suite == "instantiation" and line in (7, 281, 289, 332, 471, 476):
                test = {"kind": "instantiate", "filename": current}
            elif suite == "indicies" and line in (60, 85):
                test = {"kind": "instantiate", "filename": current}
            elif suite == "resources" and line in (271, 292, 404, 446, 531, 607, 623, 743, 814, 824, 836):
                test = {"kind": "instantiate", "filename": current}
            elif suite == "tags":
                test = {"kind": "instantiate", "filename": current}
            elif suite == "defined-types":
                test = {"kind": "validate", "filename": current}
        elif kind in ("assert_malformed", "assert_invalid"):
            if suite == "binary" and line <= 281:
                test = {"kind": "reject", "filename": command["filename"],
                        "detail": ""}
            elif suite == "abi" and line in ABI_REJECTIONS:
                test = {"kind": "reject", "filename": command["filename"],
                        "detail": ABI_REJECTIONS[line]}
            elif suite == "kebab" and 14 <= line <= 90:
                test = {"kind": "reject", "filename": command["filename"],
                        "detail": "invalid Component Model name"}
            elif suite == "extern-names":
                detail = ("duplicate component import"
                          if "conflicts" in command["text"]
                          else "invalid Component Model name")
                test = {"kind": "reject", "filename": command["filename"],
                        "detail": detail}
            elif suite == "external-visibility" and line in VISIBILITY_REJECTIONS:
                test = {"kind": "reject", "filename": command["filename"],
                        "detail": VISIBILITY_REJECTIONS[line]}
            elif suite == "instantiation" and line in INSTANTIATION_REJECTIONS:
                test = {"kind": "reject", "filename": command["filename"],
                        "detail": INSTANTIATION_REJECTIONS[line]}
            elif suite == "core-modules" and line in CORE_MODULE_REJECTIONS:
                test = {"kind": "reject", "filename": command["filename"],
                        "detail": CORE_MODULE_REJECTIONS[line]}
            elif suite == "outer-alias" and line in OUTER_ALIAS_REJECTIONS:
                test = {"kind": "reject", "filename": command["filename"],
                        "detail": OUTER_ALIAS_REJECTIONS[line]}
            elif suite == "resources" and line in RESOURCE_REJECTIONS:
                test = {"kind": "reject", "filename": command["filename"],
                        "detail": RESOURCE_REJECTIONS[line]}
            elif suite == "tags" and line in TAG_REJECTIONS:
                test = {"kind": "reject", "filename": command["filename"],
                        "detail": TAG_REJECTIONS[line]}
            elif suite == "defined-types":
                test = {"kind": "reject", "filename": command["filename"],
                        "detail": DEFINED_TYPE_REJECTIONS[line]}
        elif kind in ("assert_return", "assert_trap"):
            if selected_invocation(suite, current) or (
                    suite == "alignment" and line in ALIGNMENT_TRAPS) or (
                    suite == "unit" and current_line in LINKING_UNIT_FIXTURES):
                test = {"kind": kind, "filename": current, "instance": instance,
                        "action": command["action"]}
                if kind == "assert_return":
                    test["expected"] = command["expected"]
                else:
                    test["detail"] = (ALIGNMENT_TRAPS[line] if suite == "alignment"
                                      else TRAPS[command["text"]])
        if test:
            test["location"] = f"{path}:{line}"
            test["filename"] = str(output / test["filename"])
            tests.append(test)
        elif kind.startswith("assert_") or (
                suite in ("binary", "instantiation", "resources") and kind == "module"):
            skipped += 1
    return tests, skipped


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("spec_dir", type=Path,
                        help="component-model checkout at the pinned revision")
    parser.add_argument("--qemu", action="store_true",
                        help="also run nested bool cases on all three CPU profiles")
    parser.add_argument("--qemu-tags", action="store_true",
                        help="also run upstream core tag cases on all three CPU profiles")
    args = parser.parse_args()
    spec = args.spec_dir.resolve()
    revision = subprocess.check_output(
        ("git", "-C", spec, "rev-parse", "HEAD"), text=True).strip()
    if revision != REVISION:
        parser.error(f"expected Component Model revision {REVISION}, got {revision}")

    all_tests = []
    for path in WAST_FILES:
        output = OUTPUT / Path(path).stem
        output.mkdir(parents=True, exist_ok=True)
        script = output / f"{Path(path).stem}.json"
        run("wasm-tools", "json-from-wast", spec / "test" / path,
            "--wasm-dir", output, "-o", script)
        commands = json.loads(script.read_text())["commands"]
        tests, skipped = select_commands(path, commands, output)
        print(f"{path}: selected {len(tests)}, excluded {skipped}", flush=True)
        all_tests.extend(tests)
    assert all_tests
    manifest = OUTPUT / "cases.json"
    manifest.write_text(json.dumps({"revision": revision, "cases": all_tests}))
    run("nim", "c", "-r", "--skipUserCfg", "--skipParentCfg", "--skipProjCfg",
        "--path:src", "--checks:on", "--assertions:on",
        f"--nimcache:{OUTPUT / 'nimcache'}", f"--out:{OUTPUT / 'test'}",
        "tools/test_wasm_component_spec.nim", manifest)
    if args.qemu_tags:
        from run_wasm_component import CORES, check_qemu

        run("wasm-tools", "strip", "--all", OUTPUT / "tags" / "tags.3.wasm",
            "-o", OUTPUT / "tag-link-3.wasm")
        lp_tags = OUTPUT / "tag-link-lp.wasm"
        run("wasm-tools", "strip", "--all", ROOT / "tools" / "wasm_component_tag_link_lp.wat",
            "-o", lp_tags)
        run("wasm-tools", "validate", lp_tags)
        for core, target in CORES.items():
            check_qemu(core, *target, tag_case=True)
    if args.qemu:
        from run_wasm_component import CORES, check_qemu

        run("wasm-tools", "strip", OUTPUT / "numerics" / "numerics.2.wasm",
            "-o", OUTPUT / "nested-bool.wasm")
        lp_fixture = OUTPUT / "nested-bool-lp.wasm"
        run("wasm-tools", "parse", "tools/wasm_component_nested_lp.wat", "-o", lp_fixture)
        run("wasm-tools", "strip", lp_fixture, "-o", lp_fixture)
        run("wasm-tools", "validate", lp_fixture)
        for core, target in CORES.items():
            check_qemu(core, *target, nested_case=True)


if __name__ == "__main__":
    main()
