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
    "linking/link-time-virtualization.wast",
    "linking/shared-everything-dynamic-linking.wast",
    "linking/unit.wast",
    "linking/tags.wast",
    "validation/abi.wast",
    "validation/defined-types.wast",
    "validation/map.wast",
    "validation/max-value-size.wast",
    "validation/kebab.wast",
    "validation/extern-names.wast",
    "validation/attributes.wast",
    "validation/annotated-names.wast",
    "validation/version-suffix.wast",
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
    "values/post-return.wast",
    "values/alignment.wast",
    "values/concat.wast",
    "values/variants.wast",
    "resources/handle-table.wast",
    "resources/borrows.wast",
    "resources/multiple-resources.wast",
    "async/dtor-context-is-zero.wast",
    "async/validate-no-async-abi-for-sync-type.wast",
    "async/validate-task-return.wast",
    "async/cross-abi-calls.wast",
    "async/drop-waitable-set.wast",
)
STACKFUL_WAST_FILES = ("async/dont-block-start.wast", "async/drop-subtask.wast")
THREAD_WAST_FILES = (
    "async/self-switch-traps.wast",
    "async/during-sync-call-may-block-if-other-ready-threads.wast",
    "async/during-sync-call-exclusive-resume.wast",
    "async/during-sync-call-no-sibling-resume.wast",
    "async/during-sync-scheduling-candidates.wast",
)
THREAD_FUTURE_WAST_FILES = (
    "async/switch-to-ready-callback.wast", "async/cancel-resumed-callback-switch.wast",
    "async/cancel-targeted-resume.wast",
)
THREAD_FEATURES = "--features=cm-async-stackful,cm-more-async-builtins,cm-threading"
THREAD_TRAPS = {
    "self-switch-traps": "cannot switch to the current canonical thread",
    "switch-to-ready-callback": "canonical thread is not suspended",
}
THREAD_STREAM_WAST_FILES = (
    "async/during-sync-call-blocking-ops.wast", "async/trap-if-block-and-sync.wast",
)
FUTURE_WAST_FILES = ("async/future-completion-order.wast", "async/futures-must-write.wast",
                     "async/cross-task-future.wast")
STREAM_WAST_FILES = (
    "async/partial-stream-copies.wast", "async/cancel-stream.wast",
    "async/closed-stream.wast", "async/drop-stream.wast", "async/sync-streams.wast",
    "async/forward.wast", "async/same-component-stream-future.wast", "async/idle-drop.wast",
    "async/trap-if-transfer-in-waitable-set.wast", "async/trap-if-done.wast",
    "async/validate-no-stream-char.wast",
)
FUTURE_FEATURES = "--features=cm-async-stackful,cm-more-async-builtins,cm-forward"
STREAM_TRAPS = {
    "drop-stream": {158: "cannot drop a pending canonical stream endpoint",
                    160: "cannot drop a pending canonical stream endpoint"},
    "forward": {
        **dict.fromkeys((991, 993, 995, 1009, 1011), "canonical stream endpoint type mismatch"),
        **dict.fromkeys((997, 999, 1001, 1003, 1005, 1007),
                        "canonical stream forward requires idle, unjoined endpoints"),
        1013: "canonical future endpoint type mismatch",
        1015: "canonical future forward requires idle, unjoined endpoints",
        1017: "rendezvous requires a unit or numeric payload",
        1019: "rendezvous requires a unit or numeric payload",
    },
    "idle-drop": {
        566: "canonical stream endpoint is not idle",
        568: "canonical stream endpoint is not idle",
        570: "canonical future endpoint is not idle",
        572: "canonical stream transfer requires an idle, unjoined reader",
    },
    "trap-if-transfer-in-waitable-set": {
        49: "canonical future transfer requires an idle, unjoined reader",
        51: "canonical stream transfer requires an idle, unjoined reader",
    },
    "trap-if-done": {
        **dict.fromkeys((495, 497, 499, 501, 505), "canonical future endpoint is not idle"),
        **dict.fromkeys((503, 507), "canonical future transfer requires an idle, unjoined reader"),
        **dict.fromkeys((509, 511, 513, 517, 521), "canonical stream endpoint is not idle"),
        **dict.fromkeys((515, 519, 523), "canonical stream transfer requires an idle, unjoined reader"),
    },
    "same-component-stream-future": dict.fromkeys(range(292, 311, 2),
                                                  "rendezvous requires a unit or numeric payload"),
}
LOCAL_VISIBILITY = {
    "wasm_component_instance_visibility": "named component result type is not externally visible",
    "wasm_component_resource_visibility": "interface method resource type is not exported",
}
CORE_FUNCTION_TYPES = "wasm_component_core_function_types"
FIXED_LISTS = "wasm_component_fixed_lists"
CONTEXT_CASES = "wasm_component_context"
ABSTRACT_RESOURCE_EXPORTS = "wasm_component_abstract_resource_exports"
CANCELLATION = "wasm_component_cancellation"
STACKFUL = "wasm_component_stackful"
SYNC_LOWER = "wasm_component_sync_lower"
ASYNC_BORROWS = "wasm_component_async_borrows"
FUTURES = "wasm_component_futures"
STREAMS = "wasm_component_streams"
THREADS = "wasm_component_guest_threads"
ERROR_CONTEXT = "wasm_component_error_context"
STACKFUL_LOCAL_CASES = (STACKFUL, SYNC_LOWER, ASYNC_BORROWS)
LOCAL_COMPONENT_CASES = (CORE_FUNCTION_TYPES, "wasm_component_maps", FIXED_LISTS, CONTEXT_CASES,
                         "wasm_component_type_ascription", ABSTRACT_RESOURCE_EXPORTS,
                         "wasm_component_callback_types", CANCELLATION, *STACKFUL_LOCAL_CASES,
                         FUTURES, STREAMS, THREADS, ERROR_CONTEXT)
BINARY_CORE_TYPE_REJECTIONS = {
    916: "unsupported core module type declaration",
    926: "unsupported core module type alias",
    936: "unsupported core module type alias",
    957: "expected func type tag 0x60",
    967: "expected func type tag 0x60",
}
RESOURCE_TYPE_REJECTIONS = {
    "type not valid to be used as export": "component value resource type is not exported",
    "type not valid to be used as import": "resource type import refers to an exported name",
}
ATTRIBUTES_REJECTIONS = {
    **dict.fromkeys((99, 102, 158, 161, 167, 193), "implements requires an interface name"),
    **dict.fromkeys((107, 113, 119, 125, 131, 137), "duplicate component import"),
    **dict.fromkeys((145, 164, 175, 185, 189), "only instances can have an implements"),
    **dict.fromkeys((150, 180), "implements requires a plain external name"),
    **dict.fromkeys((227, 236), "missing component instantiation argument"),
}
ANNOTATED_NAME_REJECTIONS = {
    **dict.fromkeys((18, 57, 61, 65, 69, 73, 105, 109, 113, 117, 121),
                    "invalid Component Model name"),
    **dict.fromkeys((22, 26, 35, 40, 45), "constructor must return an owned resource"),
    **dict.fromkeys((77, 125), "resource member name requires a function"),
    **dict.fromkeys((81, 85, 89), "resource method requires a self borrow"),
    **dict.fromkeys((30, 93, 129, 144, 154, 171, 177),
                    "resource member names a type absent from its interface"),
    **dict.fromkeys((194, 199), "duplicate component import"),
}
VERSION_SUFFIX_REJECTIONS = {
    **dict.fromkeys((22, 25, 28, 31, 34, 91, 94, 140, 143),
                    "invalid canonical interface version split"),
    **dict.fromkeys((48, 51, 54, 57), "version suffix cannot be empty"),
    **dict.fromkeys((62, 65, 70, 73, 76, 79, 82, 85, 88, 131, 137),
                    "invalid interface version"),
    99: "version-suffix requires an interface name or implements",
    **dict.fromkeys((102, 134), "a version suffix requires the name to have a version"),
    **dict.fromkeys((107, 110, 113, 116), "only instances can have a version-suffix"),
    **dict.fromkeys((180, 185), "duplicate component import"),
    190: "duplicate component export",
    209: "missing component instantiation argument",
}
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
    "wasm trap: list content out-of-bounds": "linear memory range out of bounds",
    "wasm trap: unaligned pointer": "unaligned canonical realloc result",
    "invalid `char` bit pattern": "invalid canonical Unicode scalar",
    "invalid variant discriminant": "canonical variant discriminant out of range",
    "cannot block a synchronous task before returning": "cannot block a synchronous task before returning",
    "unsupported callback code": "invalid canonical callback code",
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
    **dict.fromkeys((91, 297), "component value resource type is not exported"),
    112: "named component result type is not externally visible",
    131: "named component result type is not externally visible",
    150: "named component result type is not externally visible",
    **dict.fromkeys((168, 185), "resource result type is not exported"),
    196: "named component field type is not externally visible",
    209: "interface method resource type is not exported",
    **dict.fromkeys((239, 276, 283, 290),
                    "named component list element type is not externally visible"),
    **dict.fromkeys((232, 246),
                    "named component field type is not externally visible"),
    **dict.fromkeys((253, 260, 267),
                    "named component case payload type is not externally visible"),
    **dict.fromkeys((313, 329, 338, 369, 385), "named component field type is not externally visible"),
    **dict.fromkeys((347, 354), "named component result type is not externally visible"),
    **dict.fromkeys((378, 433, 444), "named component parameter type is not externally visible"),
    395: "resource result type is not imported",
    459: "named component result type is not externally visible",
    **dict.fromkeys((490, 498), "named component result type is not externally visible"),
    **dict.fromkeys((588, 596), "unknown component instance function: f"),
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
    372: "component instantiation argument type mismatch",
    **dict.fromkeys((388, 418, 435, 462, 480, 495, 509),
                    "component instantiation resource equality mismatch"),
    546: "component instantiation argument type mismatch",
    578: "component instantiation resource equality mismatch",
    **dict.fromkeys((652, 660), "component instantiation argument sort mismatch"),
    669: "missing component instantiation resource argument",
    **dict.fromkeys((678, 683, 688, 694), "unknown resource type in handle"),
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


def check_local_wast(suite, source):
    features = {
        FIXED_LISTS: ("--features=cm-fixed-length-lists",),
        CANCELLATION: ("--features=cm-more-async-builtins",),
        FUTURES: (FUTURE_FEATURES,),
        STREAMS: (FUTURE_FEATURES,),
        THREADS: (THREAD_FEATURES,),
        ERROR_CONTEXT: ("--features=cm-error-context",),
        **dict.fromkeys(STACKFUL_LOCAL_CASES, ("--features=cm-async-stackful,cm-more-async-builtins",)),
    }
    options = features.get(suite, ())
    command = ("wasm-tools", "wast", "--ignore-error-messages", *options, source)
    if suite != ABSTRACT_RESOURCE_EXPORTS:
        run(*command)
        return
    oracle = subprocess.run(command, cwd=ROOT, text=True, capture_output=True, timeout=120)
    if oracle.returncode == 0:
        return
    failures = oracle.stderr.split("failed directive on ")[1:]
    if not failures or not all("ascribed type of export is not compatible" in detail and
                               "resource types are not the same" in detail for detail in failures):
        raise RuntimeError(oracle.stderr)
    print(f"{source.name}: reference validator rejects the spec's abstract export ascriptions", flush=True)


def build_wit_fixture(stem, features=(), wit=None, world=None, core_fixture=None):
    embedded = OUTPUT / f"{stem}.embedded.wasm"
    component = OUTPUT / f"{stem}.component.wasm"
    fixture = OUTPUT / f"{stem}.stripped.wasm"
    selection = ("--world", world) if world else ()
    run("wasm-tools", "component", "embed", *selection, f"tools/wasm_component_{wit or stem}.wit",
        f"tools/wasm_component_{core_fixture or stem}.wat", "-o", embedded)
    run("wasm-tools", "component", "new", embedded, "-o", component)
    run("wasm-tools", "strip", "--all", component, "-o", fixture)
    run("wasm-tools", "validate", *features, fixture)
    return fixture


def check_qemu_profiles(**options):
    from run_wasm_component import CORES, check_qemu

    for core, target in CORES.items():
        check_qemu(core, *target, **options)


def check_thread_spawn() -> None:
    output = OUTPUT.parent / "thread-spawn"
    output.mkdir(parents=True, exist_ok=True)
    source = (ROOT / "tools/wasm_component_thread_spawn.wat").read_text()
    # wasm-tools 1.263 uses the older spelling and omits sharedness from
    # these definitions. Validate the generated core module separately and
    # replace only the exact canonical section prefix of this fixture.
    header = bytes.fromhex("0061736d0d000100 03050160017f00")
    old = bytes.fromhex("080702400009007900")

    def build(name, text):
        wat = output / f"{name}.wat"
        wasm = output / f"{name}.wasm"
        wat.write_text(text.replace("thread.available-parallelism", "thread.available_parallelism"))
        run("wasm-tools", "strip", "--all", wat, "-o", wasm)
        return wasm.read_bytes()

    def pin(blob, shared=0, entry=0):
        if not blob.startswith(header + old):
            raise AssertionError("unexpected wasm-tools format for thread-spawn fixture")
        payload = bytes([2, 0x40, shared, entry, 0x09, 0, 0x79, 0])
        return header + bytes([8, len(payload)]) + payload + blob[len(header + old):]

    legacy = build("legacy", source)
    probe = pin(legacy)
    core_section = legacy[len(header + old):]
    assert core_section[0] == 1 and core_section[1] < 128
    core = output / "guest.wasm"
    core.write_bytes(core_section[2:2 + core_section[1]])
    run("wasm-tools", "validate", core)
    capacity = (source[:source.index('(func (export "run")')] + '''(func (export "run")
      (loop $repeat
        (drop (call $spawn (ref.func $worker) (i32.const 42)))
        (br $repeat))))
    ''' + source[source.index("(core instance $m"):])
    for name, data in {
        "probe": probe, "shared": pin(legacy, shared=1),
        "invalid-flag": pin(legacy, shared=2), "missing-type": pin(legacy, entry=1),
        "erased-import": pin(build("erased-import", source.replace("(ref null $entry)", "funcref"))),
        "null": pin(build("null", source.replace("ref.func $worker", "ref.null $entry"))),
        "capacity": pin(build("capacity", capacity)),
    }.items():
        (output / f"{name}.wasm").write_bytes(data)
    parallelism = build("parallelism", (ROOT / "tools/wasm_component_thread_parallelism.wat").read_text())
    parallelism_header = bytes.fromhex("0061736d0d000100")
    old_parallelism = bytes.fromhex("08020142")
    assert parallelism.startswith(parallelism_header + old_parallelism)
    parallelism_tail = parallelism[len(parallelism_header + old_parallelism):]
    (output / "parallelism.wasm").write_bytes(
        parallelism_header + bytes.fromhex("0803014200") + parallelism_tail)
    (output / "parallelism-shared.wasm").write_bytes(
        parallelism_header + bytes.fromhex("0803014201") + parallelism_tail)
    indirect = build("indirect", '''(component
      (core type $entry (func (param i32)))
      (core module $table (table (export "t") 1 funcref))
      (core instance $table (instantiate $table))
      (core func $spawn (canon thread.spawn-indirect $entry (core table $table "t"))))''')
    old_indirect = bytes.fromhex("080401410000")
    assert indirect.endswith(old_indirect)
    (output / "indirect.wasm").write_bytes(indirect[:-len(old_indirect)] + bytes.fromhex("08050141000000"))
    for optional in (False, True):
        build_name = "enabled" if optional else "disabled"
        run("nim", "c", "-r", "--skipUserCfg", "--skipParentCfg", "--skipProjCfg",
            "--path:src", "--checks:on", "--assertions:on", "-d:wasmFunctionReferences",
            "-d:wasmComponentAsyncCallbacks", "-d:wasmComponentStackful", "-d:wasmComponentThreads",
            *(("-d:wasmComponentThreadSpawn",) if optional else ()),
            f"--nimcache:{output / (build_name + '-cache')}", f"--out:{output / build_name}",
            "tools/test_wasm_component_thread_spawn.nim", output)


def check_error_context(*, endpoints=False, qemu=False):
    features = ("--features=cm-error-context",)
    identity = build_wit_fixture("error_context_identity", features, wit="error_context",
                                 world="error-context-test")
    source = OUTPUT / "error-context.wasm"
    run("wasm-tools", "strip", "--all", f"tools/{ERROR_CONTEXT}.wat", "-o", source)
    run("wasm-tools", "validate", *features, source)
    cases = [("disabled", (), ()),
             ("discard", ("-d:wasmComponentErrorContext",), ()),
             ("retain", ("-d:wasmComponentErrorContext", "-d:wasmComponentErrorContextMessages"), ())]
    if endpoints:
        future = OUTPUT / "error-context-future.wasm"
        run("wasm-tools", "strip", "--all", f"tools/{ERROR_CONTEXT}_future.wat", "-o", future)
        run("wasm-tools", "validate", FUTURE_FEATURES + ",cm-error-context", future)
        cases.append(("future", ("-d:wasmComponentErrorContext", "-d:wasmComponentAsyncCallbacks",
                     "-d:wasmComponentStackful", "-d:wasmComponentFutures",
                     "-d:wasmComponentHostEndpoints"), (future,)))
    for name, flags, extra in cases:
        cache = OUTPUT / f"error-context-{name}"
        run("nim", "c", "-r", "--skipUserCfg", "--skipParentCfg", "--skipProjCfg",
            "--path:src", "--checks:on", "--assertions:on", *flags,
            f"--nimcache:{cache}", f"--out:{cache / 'test'}",
            "tools/test_wasm_component_error_context.nim", source, identity, *extra)
    if qemu:
        fixture = OUTPUT / "error-context-lp.wasm"
        run("wasm-tools", "strip", "--all", f"tools/{ERROR_CONTEXT}_lp.wat", "-o", fixture)
        run("wasm-tools", "validate", *features, fixture)
        check_qemu_profiles(error_context_case=True)


def check_fixed_lists():
    features = ("--features=cm-fixed-length-lists",)
    direct = build_wit_fixture("fixed_list", features, world="fixed-list-direct")
    indirect = build_wit_fixture("fixed_list_indirect", features,
                                 wit="fixed_list", world="fixed-list-indirect")
    for enabled in (False, True):
        cache = OUTPUT / ("fixed-list-host" if enabled else "fixed-list-gate")
        flags = ("-d:wasmComponentFixedLists",) if enabled else ()
        run("nim", "c", "-r", "--skipUserCfg", "--skipParentCfg", "--skipProjCfg",
            "--path:src", "--checks:on", "--assertions:on", *flags,
            f"--nimcache:{cache}", f"--out:{cache / 'fixture'}",
            "tools/wasm_component_fixed_list_fixture.nim", direct, indirect)
    check_qemu_profiles(fixed_list_case=True)


def selected_invocation(suite, filename):
    if suite in ("strings", "tags", "unit", "link-time-virtualization",
                 "shared-everything-dynamic-linking", "realloc",
                 "cross-abi-calls", "drop-waitable-set", "drop-subtask",
                 *(Path(path).stem for path in (*FUTURE_WAST_FILES, *STREAM_WAST_FILES,
                                               *THREAD_WAST_FILES, *THREAD_FUTURE_WAST_FILES,
                                               *THREAD_STREAM_WAST_FILES)),
                 "wasm_component_resource_visibility", *LOCAL_COMPONENT_CASES):
        return True
    if suite == "transcode":
        return filename in {f"transcode.{index}.wasm" for index in range(5)}
    if suite == "numerics":
        return True
    if suite == "post-return":
        # The other modules use gated async definitions.
        return filename in ("post-return.1.wasm", "post-return.2.wasm", "post-return.4.wasm")
    if suite == "dtor-context-is-zero":
        return filename == "dtor-context-is-zero.0.wasm"
    if suite == "variants":
        return filename == "variants.0.wasm"
    if suite == "concat":
        return filename in ("concat.0.wasm", "concat.1.wasm")
    if suite in ("handle-table", "borrows", "multiple-resources"):
        return filename is not None
    return False


def select_commands(path, commands, output, futures=False, streams=False):
    suite = Path(path).stem
    disabled_map_cases = (() if futures else (58, 66)) + (() if streams else (62,))
    definitions = {}
    current = None
    instance = 0
    tests = []
    skipped = 0
    for command in commands:
        kind = command["type"]
        line = command["line"]
        test = None
        if kind == "module_definition":
            definitions[command.get("name")] = command["filename"]
            if suite in LOCAL_VISIBILITY or suite in LOCAL_COMPONENT_CASES or suite in (
                    "extern-names", "external-visibility", "attributes",
                    "annotated-names", "version-suffix", "cross-abi-calls"):
                test = {"kind": "validate", "filename": command["filename"]}
            elif suite == "binary" and line in (1298, 1317):
                test = {"kind": "validate", "filename": command["filename"]}
            elif suite == "map" and futures and streams:
                test = {"kind": "validate", "filename": command["filename"]}
            elif suite == "instantiation" and line in (218, 262):
                test = {"kind": "validate", "filename": command["filename"]}
            elif suite == "core-modules" and line == 7:
                test = {"kind": "validate", "filename": command["filename"]}
            elif suite == "outer-alias" and line in (7, 26, 98, 106, 121, 132, 156, 265):
                test = {"kind": "validate", "filename": command["filename"]}
            elif suite == "resources" and line in (19, 39, 48, 64, 83, 112, 157,
                                                   192, 233, 252, 355):
                test = {"kind": "validate", "filename": command["filename"]}
        elif kind in ("module", "module_instance"):
            current = (command["filename"] if kind == "module"
                       else definitions[command["module"]])
            instance += 1
            if suite == "binary" and (line <= 281 and line != 127 or line in (892, 949, 978, 985)):
                test = {"kind": "instantiate", "filename": current}
            elif suite == "instantiation" and line in (7, 281, 289, 332, 342, 471, 476):
                test = {"kind": "instantiate", "filename": current}
            elif suite == "indicies" and line in (60, 85):
                test = {"kind": "instantiate", "filename": current}
            elif suite == "resources" and line in (271, 292, 313, 404, 427, 446, 531,
                                                   564, 594, 607, 623, 743, 814, 824, 836):
                test = {"kind": "instantiate", "filename": current}
            elif suite == "validate-task-return":
                test = {"kind": "instantiate", "filename": current}
            elif suite == "tags":
                test = {"kind": "instantiate", "filename": current}
            elif suite in ("defined-types", "annotated-names"):
                test = {"kind": "validate", "filename": current}
        elif kind in ("assert_malformed", "assert_invalid"):
            if suite == "binary" and line <= 281:
                test = {"kind": "reject", "filename": command["filename"],
                        "detail": ""}
            elif suite == "binary" and line in BINARY_CORE_TYPE_REJECTIONS:
                test = {"kind": "reject", "filename": command["filename"],
                        "detail": BINARY_CORE_TYPE_REJECTIONS[line]}
            elif suite == "binary" and line == 1497:
                test = {"kind": "reject", "filename": command["filename"],
                        "detail": "duplicate component name attribute"}
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
            elif suite == "attributes" and line in ATTRIBUTES_REJECTIONS:
                test = {"kind": "reject", "filename": command["filename"],
                        "detail": ATTRIBUTES_REJECTIONS[line]}
            elif suite == "annotated-names":
                test = {"kind": "reject", "filename": command["filename"],
                        "detail": ANNOTATED_NAME_REJECTIONS[line]}
            elif suite == "version-suffix":
                test = {"kind": "reject", "filename": command["filename"],
                        "detail": VERSION_SUFFIX_REJECTIONS[line]}
            elif suite in LOCAL_VISIBILITY:
                detail = LOCAL_VISIBILITY[suite]
                if suite == "wasm_component_resource_visibility":
                    detail = RESOURCE_TYPE_REJECTIONS.get(command["text"], detail)
                test = {"kind": "reject", "filename": command["filename"],
                        "detail": detail}
            elif suite in LOCAL_COMPONENT_CASES:
                test = {"kind": "reject", "filename": command["filename"],
                        "detail": command["text"]}
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
            elif suite == "map" and line not in disabled_map_cases:
                test = {"kind": "reject", "filename": command["filename"],
                        "detail": command["text"]}
            elif suite == "validate-no-stream-char":
                test = {"kind": "reject", "filename": command["filename"],
                        "detail": "stream element type cannot be char"}
            elif suite == "forward":
                detail = ("canonical stream operation requires a stream type" if "stream.forward" in
                          command["text"] else "canonical future operation requires a future type")
                test = {"kind": "reject", "filename": command["filename"], "detail": detail}
            elif suite in ("validate-task-return", "validate-no-async-abi-for-sync-type"):
                detail = ("component function result contains a borrowed resource"
                          if suite == "validate-task-return" else
                          "canonical async option requires an async function type")
                test = {"kind": "reject", "filename": command["filename"], "detail": detail}
            elif suite == "max-value-size":
                test = {"kind": "reject", "filename": command["filename"],
                        "detail": command["text"]}
        elif kind == "assert_uninstantiable" and path in STACKFUL_WAST_FILES:
            test = {"kind": kind, "filename": command["filename"], "detail": command["text"]}
        elif kind == "action" and suite == "closed-stream":
            test = {"kind": "assert_return", "filename": current, "instance": instance,
                    "action": command["action"], "expected": []}
        elif kind in ("assert_return", "assert_trap"):
            if suite == "switch-to-ready-callback" and line in (359, 367):
                # The spec script expects the external event loop to report deadlock.
                pass
            elif suite == "cross-abi-calls" and line in (491, 495):
                # These lifts have a memory for their parameters, but the
                # task.return has no memory. The pinned LiftOptions.equal
                # rule requires identity even when there is no result.
                pass
            elif selected_invocation(suite, current) or (suite == "dtor-context-is-zero" and futures) or (
                    suite == "alignment" and line in ALIGNMENT_TRAPS):
                test = {"kind": kind, "filename": current, "instance": instance,
                        "action": command["action"]}
                if kind == "assert_return":
                    test["expected"] = command["expected"]
                else:
                    test["detail"] = (ALIGNMENT_TRAPS[line] if suite == "alignment"
                                      else "canonical waitable set is in use" if suite == "drop-waitable-set"
                                      else "canonical subtask result has not been delivered" if suite == "drop-subtask"
                                      else command["text"] if path in FUTURE_WAST_FILES
                                      else THREAD_TRAPS[suite] if suite in THREAD_TRAPS
                                      else STREAM_TRAPS[suite][line] if suite in STREAM_TRAPS
                                      else command["text"] if suite in LOCAL_COMPONENT_CASES
                                      else TRAPS[command["text"]])
        if test:
            test["location"] = f"{path}:{line}"
            test["filename"] = str(output / test["filename"])
            tests.append(test)
        elif kind.startswith("assert_") or (
                suite in ("binary", "instantiation", "resources", "max-value-size") and kind == "module") or (
                suite == "map" and kind == "module_definition"):
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
    parser.add_argument("--qemu-multi-memory", action="store_true",
                        help="also run an indexed canonical memory fixture on all three CPU profiles")
    parser.add_argument("--qemu-resource-visibility", action="store_true",
                        help="also run the resource relay on all three CPU profiles")
    parser.add_argument("--qemu-resource-ascription", action="store_true",
                        help="also check abstract and equality resource exports on all three profiles")
    parser.add_argument("--qemu-core-function-types", action="store_true",
                        help="also run core function type fixtures on all three CPU profiles")
    parser.add_argument("--qemu-map", action="store_true",
                        help="also run a WIT-generated map round trip on all three CPU profiles")
    parser.add_argument("--qemu-fixed-list", action="store_true",
                        help="also run the WIT-generated fixed-length list fixture")
    parser.add_argument("--qemu-context", action="store_true",
                        help="also run the synchronous canonical context fixture")
    parser.add_argument("--qemu-callbacks", action="store_true",
                        help="run callbacks on all profiles and guest subtasks and cancellation on M0/D0")
    parser.add_argument("--qemu-lp-subtasks-diagnostic", action="store_true",
                        help="run LP subtask probes with extended diagnostic RAM")
    parser.add_argument("--stackful", action="store_true",
                        help="exercise stackful Canonical ABI execution on the host and with --qemu-callbacks")
    parser.add_argument("--qemu-sync-lower", action="store_true",
                        help="exercise synchronous Canonical ABI lowering that suspends on all QEMU profiles")
    parser.add_argument("--qemu-async-borrows", action="store_true",
                        help="exercise async resource borrowing on all QEMU profiles")
    parser.add_argument("--futures", action="store_true",
                        help="exercise the guest-local Canonical ABI future builtins")
    parser.add_argument("--qemu-futures", action="store_true",
                        help="run a blocking guest-local future on all three QEMU profiles")
    parser.add_argument("--streams", action="store_true",
                        help="exercise Canonical ABI streams and futures against upstream")
    parser.add_argument("--qemu-streams", action="store_true",
                        help="also exercise guest stream delivery in all three QEMU profiles")
    parser.add_argument("--host-endpoints", action="store_true",
                        help="exercise host-created futures and streams against guest code")
    parser.add_argument("--qemu-host-endpoints", action="store_true",
                        help="also exercise host-owned buffers on all three QEMU profiles")
    parser.add_argument("--guest-threads", action="store_true",
                        help="exercise Canonical ABI guest thread operations")
    parser.add_argument("--qemu-guest-threads", action="store_true",
                        help="also schedule an explicit guest thread on the three QEMU profiles")
    parser.add_argument("--thread-spawn", action="store_true",
                        help="exercise cooperative thread.spawn-ref and parallelism with pinned binaries")
    parser.add_argument("--qemu-thread-spawn", action="store_true",
                        help="also run the cooperative spawn probe on all three QEMU profiles")
    parser.add_argument("--shared-core-types", action="store_true",
                        help="exercise shared core function types through a canonical lift on the host")
    parser.add_argument("--error-context", action="store_true",
                        help="exercise Canonical ABI error contexts on the host")
    parser.add_argument("--qemu-error-context", action="store_true",
                        help="also run error-context builtins on all three QEMU profiles")
    args = parser.parse_args()
    if args.qemu_error_context:
        args.error_context = True
    if args.qemu_guest_threads:
        args.guest_threads = True
    if args.qemu_thread_spawn:
        args.thread_spawn = True
    if args.thread_spawn:
        args.guest_threads = True
    if args.qemu_host_endpoints:
        args.host_endpoints = True
    if args.qemu_streams or args.host_endpoints:
        args.streams = True
    if args.qemu_futures or args.streams:
        args.futures = True
    if args.qemu_sync_lower or args.qemu_async_borrows or args.futures or args.guest_threads:
        args.stackful = True
    spec = args.spec_dir.resolve()
    revision = subprocess.check_output(
        ("git", "-C", spec, "rev-parse", "HEAD"), text=True).strip()
    if revision != REVISION:
        parser.error(f"expected Component Model revision {REVISION}, got {revision}")

    all_tests = []
    for path in (*WAST_FILES, *(STACKFUL_WAST_FILES if args.stackful else ()),
                 *(FUTURE_WAST_FILES if args.futures else ()),
                 *(STREAM_WAST_FILES if args.streams else ()),
                 *(THREAD_WAST_FILES if args.guest_threads else ()),
                 *(THREAD_FUTURE_WAST_FILES if args.guest_threads and args.futures else ()),
                 *(THREAD_STREAM_WAST_FILES if args.guest_threads and args.streams else ())):
        output = OUTPUT / Path(path).stem
        output.mkdir(parents=True, exist_ok=True)
        script = output / f"{Path(path).stem}.json"
        run("wasm-tools", "json-from-wast", spec / "test" / path,
            "--wasm-dir", output, "-o", script)
        commands = json.loads(script.read_text())["commands"]
        tests, skipped = select_commands(path, commands, output,
                                         futures=args.futures, streams=args.streams)
        print(f"{path}: selected {len(tests)}, excluded {skipped}", flush=True)
        all_tests.extend(tests)
    for suite in (*LOCAL_VISIBILITY, *LOCAL_COMPONENT_CASES):
        if suite in STACKFUL_LOCAL_CASES and not args.stackful:
            continue
        if suite == FUTURES and not args.futures:
            continue
        if suite == STREAMS and not args.streams:
            continue
        if suite == THREADS and not args.guest_threads:
            continue
        if suite == ERROR_CONTEXT and not args.error_context:
            continue
        local = f"tools/{suite}.wast"
        output = OUTPUT / suite
        output.mkdir(parents=True, exist_ok=True)
        script = output / "cases.json"
        if suite in LOCAL_COMPONENT_CASES:
            check_local_wast(suite, ROOT / local)
        run("wasm-tools", "json-from-wast", ROOT / local, "--wasm-dir", output, "-o", script)
        tests, skipped = select_commands(local, json.loads(script.read_text())["commands"], output)
        assert tests and skipped == 0
        print(f"{local}: {len(tests)} local checks", flush=True)
        all_tests.extend(tests)
    if args.futures:
        fixture = OUTPUT / "future-wait.stripped.wasm"
        run("wasm-tools", "strip", "--all", "tools/wasm_component_future_wait.wat", "-o", fixture)
        run("wasm-tools", "validate", FUTURE_FEATURES, fixture)
        all_tests.append({
            "kind": "assert_return", "location": "tools/wasm_component_future_wait.wat",
            "filename": str(fixture), "instance": 0,
            "action": {"type": "invoke", "field": "run", "args": []},
            "expected": [{"type": "u32", "value": "42"}],
        })
    if args.shared_core_types:
        source = "tools/wasm_component_shared_function.wat"
        fixture = OUTPUT / "shared-function.stripped.wasm"
        run("wasm-tools", "strip", "--all", source, "-o", fixture)
        run("wasm-tools", "validate", "--features=shared-everything-threads", fixture)
        all_tests.append({
            "kind": "assert_return", "location": source, "filename": str(fixture), "instance": 0,
            "action": {"type": "invoke", "field": "run", "args": []},
            "expected": [{"type": "u32", "value": "42"}],
        })
    assert all_tests
    manifest = OUTPUT / "cases.json"
    manifest.write_text(json.dumps({"revision": revision, "cases": all_tests}))
    run("nim", "c", "-r", "--skipUserCfg", "--skipParentCfg", "--skipProjCfg",
        "--path:src", "--checks:on", "--assertions:on", "-d:wasmComponentCanonicalNames",
        "-d:wasmComponentFixedLists", "-d:wasmComponentContext", "-d:wasmComponentAsyncCallbacks",
        *(("-d:wasmComponentStackful",) if args.stackful else ()),
        *(("-d:wasmComponentFutures",) if args.futures else ()),
        *(("-d:wasmComponentStreams",) if args.streams else ()),
        *(("-d:wasmComponentHostEndpoints",) if args.host_endpoints else ()),
        *(("-d:wasmComponentThreads",) if args.guest_threads else ()),
        *(("-d:wasmFunctionReferences",) if args.thread_spawn or args.shared_core_types else ()),
        *(("-d:wasmSharedCoreTypes",) if args.shared_core_types else ()),
        *(("-d:wasmComponentThreadSpawn",) if args.thread_spawn else ()),
        *(("-d:wasmComponentErrorContext",) if args.error_context else ()),
        f"--nimcache:{OUTPUT / 'nimcache'}", f"--out:{OUTPUT / 'test'}",
        "tools/test_wasm_component_spec.nim", manifest)
    if args.error_context:
        check_error_context(endpoints=args.host_endpoints, qemu=args.qemu_error_context)
    if args.futures:
        bounce = build_wit_fixture("future_bounce", (FUTURE_FEATURES,), world="future-bounce")
        source = OUTPUT / "future-source.stripped.wasm"
        run("wasm-tools", "strip", "--all", "tools/wasm_component_future_source.wat", "-o", source)
        run("wasm-tools", "validate", FUTURE_FEATURES, source)
        cache = OUTPUT / "future-ownership"
        run("nim", "c", "-r", "--mm:arc", "--skipUserCfg", "--skipParentCfg", "--skipProjCfg",
            "--path:src", "--checks:on", "--assertions:on", "-d:wasmComponentAsyncCallbacks",
            "-d:wasmComponentStackful", "-d:wasmComponentFutures",
            f"--nimcache:{cache}", f"--out:{cache / 'test'}",
            "tools/test_wasm_component_futures.nim", source, bounce)
    if args.streams:
        bounce = build_wit_fixture("stream_bounce", (FUTURE_FEATURES,),
                                   world="stream-bounce", core_fixture="future_bounce")
        source = OUTPUT / "stream-source.stripped.wasm"
        run("wasm-tools", "strip", "--all", "tools/wasm_component_stream_source.wat", "-o", source)
        run("wasm-tools", "validate", FUTURE_FEATURES, source)
        cache = OUTPUT / "stream-ownership"
        run("nim", "c", "-r", "--mm:arc", "--skipUserCfg", "--skipParentCfg", "--skipProjCfg",
            "--path:src", "--checks:on", "--assertions:on", "-d:wasmComponentAsyncCallbacks",
            "-d:wasmComponentStreams", f"--nimcache:{cache}", f"--out:{cache / 'test'}",
            "tools/test_wasm_component_streams.nim", source, bounce)
    if args.host_endpoints:
        fixtures = []
        for stem in ("host_endpoint", "host_endpoint_typed"):
            fixture = OUTPUT / f"{stem.replace('_', '-')}.stripped.wasm"
            run("wasm-tools", "strip", "--all", f"tools/wasm_component_{stem}.wat", "-o", fixture)
            run("wasm-tools", "validate", FUTURE_FEATURES, fixture)
            fixtures.append(fixture)
        cache = OUTPUT / "host-endpoints"
        run("nim", "c", "-r", "--mm:arc", "--skipUserCfg", "--skipParentCfg", "--skipProjCfg",
            "--path:src", "--checks:on", "--assertions:on", "-d:wasmComponentAsyncCallbacks",
            "-d:wasmComponentStackful",
            "-d:wasmComponentFutures", "-d:wasmComponentStreams", "-d:wasmComponentHostEndpoints",
            f"--nimcache:{cache}", f"--out:{cache / 'test'}",
            "tools/test_wasm_component_host_endpoints.nim", *fixtures)
    if args.qemu_host_endpoints:
        check_qemu_profiles(subtasks_case=True, host_endpoint_case=True)
    if args.qemu_guest_threads:
        for profile in ("guest-threads", "sync-threads"):
            fixture = OUTPUT / f"{profile}-lp.stripped.wasm"
            source_name = profile.replace("-", "_")
            run("wasm-tools", "strip", "--all", f"tools/wasm_component_{source_name}_lp.wat",
                "-o", fixture)
            run("wasm-tools", "validate", THREAD_FEATURES, fixture)
        check_qemu_profiles(subtasks_case=True, guest_thread_case=True)
    if args.thread_spawn:
        check_thread_spawn()
    if args.qemu_thread_spawn:
        check_qemu_profiles(subtasks_case=True, guest_thread_case=True, thread_spawn_case=True)
    if args.qemu_streams:
        fixture = OUTPUT / "stream-lp.stripped.wasm"
        run("wasm-tools", "strip", "--all", "tools/wasm_component_stream_lp.wat", "-o", fixture)
        run("wasm-tools", "validate", FUTURE_FEATURES, fixture)
        partial_case = next(test["filename"] for test in all_tests
                            if test["location"].startswith("async/partial-stream-copies.wast:")
                            and test.get("action", {}).get("field") == "writer-buffer-pending")
        fixture = OUTPUT / "stream-partial.stripped.wasm"
        run("wasm-tools", "strip", "--all", partial_case, "-o", fixture)
        run("wasm-tools", "validate", FUTURE_FEATURES, fixture)
        check_qemu_profiles(subtasks_case=True, stream_case=True)
    if args.qemu_futures:
        from run_wasm_component import CORES, check_qemu
        fixture = OUTPUT / "future-wait-lp.stripped.wasm"
        run("wasm-tools", "strip", "--all", "tools/wasm_component_future_wait_lp.wat", "-o", fixture)
        run("wasm-tools", "validate", FUTURE_FEATURES, fixture)
        check_qemu_profiles(subtasks_case=True, future_wait_case=True)
        transfer_case = next(test["filename"] for test in all_tests
                             if test["location"].startswith(f"tools/{FUTURES}.wast:")
                             and test.get("action", {}).get("field") == "check")
        fixture = OUTPUT / "future-transfer.stripped.wasm"
        run("wasm-tools", "strip", "--all", transfer_case, "-o", fixture)
        run("wasm-tools", "validate", FUTURE_FEATURES, fixture)
        fixture = OUTPUT / "future-transfer-lp.stripped.wasm"
        run("wasm-tools", "strip", "--all", "tools/wasm_component_future_transfer_lp.wat",
            "-o", fixture)
        run("wasm-tools", "validate", FUTURE_FEATURES, fixture)
        check_qemu_profiles(subtasks_case=True, future_transfer_case=True)
    if args.qemu_map:
        build_wit_fixture("map")
        check_qemu_profiles(map_case=True)
    if args.qemu_fixed_list:
        check_fixed_lists()
    if args.qemu_sync_lower:
        from run_wasm_component import CORES, check_qemu
        fixtures = (
            (OUTPUT / SYNC_LOWER / "cases.0.wasm", OUTPUT / "async-sync-lower.stripped.wasm"),
            ("tools/wasm_component_sync_lower_lp.wat", OUTPUT / "async-sync-lower-lp.stripped.wasm"),
        )
        for source, fixture in fixtures:
            run("wasm-tools", "strip", "--all", source, "-o", fixture)
            run("wasm-tools", "validate", "--features=cm-async-stackful", fixture)
        for core, target in CORES.items():
            check_qemu(core, *target, subtasks_case=True, sync_lower_case=True)
    if args.qemu_async_borrows:
        from run_wasm_component import CORES, check_qemu
        fixtures = (
            (OUTPUT / ASYNC_BORROWS / "cases.0.wasm", OUTPUT / "async-borrows.stripped.wasm"),
            ("tools/wasm_component_async_borrows_lp.wat", OUTPUT / "async-borrows-lp.stripped.wasm"),
            ("tools/wasm_component_async_borrows_local_lp.wat",
             OUTPUT / "async-borrows-local-lp.stripped.wasm"),
        )
        for source, fixture in fixtures:
            run("wasm-tools", "strip", "--all", source, "-o", fixture)
            run("wasm-tools", "validate", "--features=cm-async-stackful", fixture)
        cache = OUTPUT / "async-borrows-lifetime"
        run("nim", "c", "-r", "--mm:arc", "--skipUserCfg", "--skipParentCfg", "--skipProjCfg",
            "--path:src", "--checks:on", "--assertions:on",
            "-d:wasmComponentAsyncCallbacks", "-d:wasmComponentStackful",
            f"--nimcache:{cache}", f"--out:{cache / 'test'}",
            "tools/test_wasm_component_async_borrows.nim", fixtures[0][1])
        for core, target in CORES.items():
            check_qemu(core, *target, subtasks_case=True, async_borrow_case=True)
        check_qemu("lp", *CORES["lp"], subtasks_case=True, async_borrow_case=True,
                   lp_subtasks_diagnostic="borrows")
    if args.stackful and args.qemu_callbacks:
        from run_wasm_component import CORES, check_qemu
        fixtures = (
            (OUTPUT / STACKFUL / "cases.0.wasm", OUTPUT / "async-stackful.stripped.wasm"),
            ("tools/wasm_component_stackful_lp.wat", OUTPUT / "async-stackful-lp.stripped.wasm"),
        )
        for source, fixture in fixtures:
            run("wasm-tools", "strip", "--all", source, "-o", fixture)
            run("wasm-tools", "validate", "--features=cm-async-stackful,cm-more-async-builtins",
                fixture)
        for core, target in CORES.items():
            check_qemu(core, *target, subtasks_case=True, stackful_case=True)
    if args.qemu_callbacks or args.qemu_lp_subtasks_diagnostic:
        turns = build_wit_fixture("callback_turns")
        failures = OUTPUT / "callback-errors.stripped.wasm"
        payload = OUTPUT / "callback-payload.stripped.wasm"
        subtasks = OUTPUT / "async-subtasks.stripped.wasm"
        subtasks_lp = OUTPUT / "async-subtasks-lp.stripped.wasm"
        local_lp = OUTPUT / "async-local-lp.stripped.wasm"
        run("wasm-tools", "strip", "--all", "tools/wasm_component_callback_errors.wat", "-o", failures)
        run("wasm-tools", "validate", failures)
        run("wasm-tools", "strip", "--all", "tools/wasm_component_callback_payload.wat", "-o", payload)
        run("wasm-tools", "validate", payload)
        for source, fixture in (("async_subtasks", subtasks), ("async_subtasks_lp", subtasks_lp),
                                ("async_local_lp", local_lp)):
            run("wasm-tools", "strip", "--all", f"tools/wasm_component_{source}.wat", "-o", fixture)
            run("wasm-tools", "validate", fixture)
        for enabled in (False, True):
            cache = OUTPUT / ("callback-host" if enabled else "callback-gate")
            options = ("-d:wasmComponentAsyncCallbacks",) if enabled else ()
            run("nim", "c", "-r", "--skipUserCfg", "--skipParentCfg", "--skipProjCfg",
                "--path:src", "--checks:on", "--assertions:on", *options,
                f"--nimcache:{cache}", f"--out:{cache / 'fixture'}",
                "tools/wasm_component_callback_fixture.nim", turns, failures, payload, subtasks,
                subtasks_lp, local_lp)
        if args.qemu_callbacks:
            cancellation = OUTPUT / "async-subtask-cancellation.stripped.wasm"
            source = OUTPUT / CANCELLATION / "cases.0.wasm"
            run("wasm-tools", "strip", "--all", source, "-o", cancellation)
            run("wasm-tools", "validate", "--features=cm-more-async-builtins", cancellation)
            check_qemu_profiles(callback_case=True)
            from run_wasm_component import CORES, check_qemu
            for core in ("m0", "d0"):
                check_qemu(core, *CORES[core], subtasks_case=True)
                check_qemu(core, *CORES[core], subtasks_case=True, subtask_cancellation=True)
        if args.qemu_lp_subtasks_diagnostic:
            from run_wasm_component import CORES, check_qemu
            for fixture in ("local", "cross"):
                check_qemu("lp", *CORES["lp"], subtasks_case=True,
                           lp_subtasks_diagnostic=fixture)
            cancellation_lp = OUTPUT / "async-subtask-cancellation-lp.stripped.wasm"
            run("wasm-tools", "strip", "--all", "tools/wasm_component_cancellation_lp.wat",
                "-o", cancellation_lp)
            run("wasm-tools", "validate", cancellation_lp)
            check_qemu("lp", *CORES["lp"], subtasks_case=True,
                       lp_subtasks_diagnostic="cross", subtask_cancellation=True)
    if args.qemu_context:
        fixture = OUTPUT / "context.stripped.wasm"
        run("wasm-tools", "strip", "--all", OUTPUT / CONTEXT_CASES / "cases.0.wasm",
            "-o", fixture)
        run("wasm-tools", "validate", fixture)
        lp = OUTPUT / "context-lp.stripped.wasm"
        run("wasm-tools", "strip", "--all", "tools/wasm_component_context_lp.wat", "-o", lp)
        run("wasm-tools", "validate", lp)
        post_return = OUTPUT / "context-post-return.stripped.wasm"
        run("wasm-tools", "strip", "--all", OUTPUT / "post-return" / "post-return.1.wasm",
            "-o", post_return)
        run("wasm-tools", "validate", post_return)
        cache = OUTPUT / "context-feature-gate"
        run("nim", "c", "-r", "--skipUserCfg", "--skipParentCfg", "--skipProjCfg",
            "--path:src", "--checks:on", "--assertions:on",
            f"--nimcache:{cache}", f"--out:{cache / 'fixture'}",
            "tools/wasm_component_context_fixture.nim", fixture)
        check_qemu_profiles(context_case=True)
    if args.qemu_core_function_types:
        from run_wasm_component import CORES, check_qemu

        suite = OUTPUT / CORE_FUNCTION_TYPES
        for index, name in enumerate(("typed-core-import", "typed-core-indirect")):
            fixture = OUTPUT / f"{name}.wasm"
            run("wasm-tools", "strip", "--all", suite / f"cases.{index}.wasm", "-o", fixture)
            run("wasm-tools", "validate", fixture)
        lp_fixture = OUTPUT / "typed-core-import-lp.wasm"
        run("wasm-tools", "strip", "--all", "tools/wasm_component_core_function_types_lp.wat",
            "-o", lp_fixture)
        run("wasm-tools", "validate", lp_fixture)
        for core, target in CORES.items():
            check_qemu(core, *target, core_function_types_case=True)
    if args.qemu_resource_visibility:
        from run_wasm_component import CORES, check_qemu

        suite = OUTPUT / "wasm_component_resource_visibility"
        fixture = OUTPUT / "resource-relay.wasm"
        run("wasm-tools", "strip", "--all", suite / "cases.0.wasm", "-o", fixture)
        run("wasm-tools", "validate", fixture)
        lp_fixture = OUTPUT / "resource-relay-lp.wasm"
        run("wasm-tools", "strip", "--all", "tools/wasm_component_resource_relay_lp.wat",
            "-o", lp_fixture)
        run("wasm-tools", "validate", lp_fixture)
        for core, target in CORES.items():
            check_qemu(core, *target, resource_visibility_case=True)
    if args.qemu_resource_ascription:
        suite = OUTPUT / ABSTRACT_RESOURCE_EXPORTS
        for index, name in enumerate(("resource-ascription", "resource-ascription-lp")):
            run("wasm-tools", "strip", "--all", suite / f"cases.{index}.wasm",
                "-o", OUTPUT / f"{name}.wasm")
        check_qemu_profiles(resource_ascription_case=True)
    if args.qemu_multi_memory:
        from run_wasm_component import CORES, check_qemu

        fixture = OUTPUT / "multi-memory.wasm"
        run("wasm-tools", "strip", "--all", "tools/wasm_component_multi_memory.wat",
            "-o", fixture)
        run("wasm-tools", "validate", fixture)
        for core, target in CORES.items():
            check_qemu(core, *target, multi_memory_case=True)
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
