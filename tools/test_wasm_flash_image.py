"""Regression tests for flash-backed compact WASM modules."""

from __future__ import annotations

import subprocess
import textwrap
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]


def u32_leb(value: int) -> list[int]:
    out: list[int] = []
    v = value
    while True:
        b = v & 0x7F
        v >>= 7
        if v:
            out.append(b | 0x80)
        else:
            out.append(b)
            return out


def i32_leb(value: int) -> list[int]:
    out: list[int] = []
    v = value & 0xFFFFFFFF
    more = True
    while more:
        b = v & 0x7F
        v >>= 7
        sign = (b & 0x40) != 0
        more = not ((v == 0 and not sign) or (v == 0x01FFFFFF and sign))
        if more:
            b |= 0x80
        out.append(b)
    return out


def wasm_section(section_id: int, payload: list[int]) -> list[int]:
    return [section_id, *u32_leb(len(payload)), *payload]


def instr_i32_const(value: int) -> list[int]:
    return [0x41, *i32_leb(value)]


def eq_const(value: int) -> list[int]:
    return [*instr_i32_const(value), 0x46]


def add_term(code: list[int], first: bool, term: list[int]) -> bool:
    code.extend(term)
    if not first:
        code.append(0x6A)
    return False


def wasm_i32_ops_module() -> list[int]:
    code: list[int] = [0x00]  # local decl count
    first = True
    terms = [
        [*instr_i32_const(0), 0x45],
        [*instr_i32_const(7), *instr_i32_const(7), 0x46],
        [*instr_i32_const(7), *instr_i32_const(8), 0x47],
        [*instr_i32_const(-1), *instr_i32_const(1), 0x48],
        [*instr_i32_const(1), *instr_i32_const(-1), 0x49],
        [*instr_i32_const(2), *instr_i32_const(-1), 0x4A],
        [*instr_i32_const(-1), *instr_i32_const(2), 0x4B],
        [*instr_i32_const(-1), *instr_i32_const(-1), 0x4C],
        [*instr_i32_const(-1), *instr_i32_const(-1), 0x4F],
        [*instr_i32_const(-7), *instr_i32_const(2), 0x6D, *eq_const(-3)],
        [*instr_i32_const(7), *instr_i32_const(3), 0x6E, *eq_const(2)],
        [*instr_i32_const(-7), *instr_i32_const(2), 0x6F, *eq_const(-1)],
        [*instr_i32_const(7), *instr_i32_const(3), 0x70, *eq_const(1)],
        [*instr_i32_const(0x8000), 0x67, *eq_const(16)],
        [*instr_i32_const(0x10), 0x68, *eq_const(4)],
        [*instr_i32_const(0xF0), 0x69, *eq_const(4)],
        [*instr_i32_const(0x12), *instr_i32_const(8), 0x77, *eq_const(0x1200)],
        [*instr_i32_const(0x1200), *instr_i32_const(8), 0x78, *eq_const(0x12)],
        [*instr_i32_const(0xFF), 0xC0, *eq_const(-1)],
        [*instr_i32_const(0x8001), 0xC1, *eq_const(-32767)],
    ]
    for term in terms:
        first = add_term(code, first, term)
    code.append(0x0B)

    type_payload = [0x01, 0x60, 0x00, 0x01, 0x7F]
    func_payload = [0x01, 0x00]
    name = [ord(c) for c in "i32ops"]
    export_payload = [0x01, len(name), *name, 0x00, 0x00]
    body = [*u32_leb(len(code)), *code]
    code_payload = [0x01, *body]

    return [
        0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00,
        *wasm_section(1, type_payload),
        *wasm_section(3, func_payload),
        *wasm_section(7, export_payload),
        *wasm_section(10, code_payload),
    ]


def wasm_direct_call_module() -> list[int]:
    caller_code = [
        0x00,
        *instr_i32_const(1),
        *instr_i32_const(20),
        *instr_i32_const(22),
        0x10, 0x01,
        0x6A,
        0x0B,
    ]
    helper_code = [
        0x00,
        0x20, 0x00,
        0x20, 0x01,
        0x6A,
        0x0B,
    ]

    type_payload = [
        0x02,
        0x60, 0x00, 0x01, 0x7F,
        0x60, 0x02, 0x7F, 0x7F, 0x01, 0x7F,
    ]
    func_payload = [0x02, 0x00, 0x01]
    name = [ord(c) for c in "caller"]
    export_payload = [0x01, len(name), *name, 0x00, 0x00]
    code_payload = [
        0x02,
        *u32_leb(len(caller_code)), *caller_code,
        *u32_leb(len(helper_code)), *helper_code,
    ]

    return [
        0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00,
        *wasm_section(1, type_payload),
        *wasm_section(3, func_payload),
        *wasm_section(7, export_payload),
        *wasm_section(10, code_payload),
    ]


def wasm_if_else_module() -> list[int]:
    choose_code = [
        0x00,
        0x20, 0x00,
        0x04, 0x7F,
        *instr_i32_const(7),
        0x05,
        *instr_i32_const(11),
        0x0B,
        0x0B,
    ]
    no_else_code = [
        0x01, 0x01, 0x7F,
        *instr_i32_const(3),
        0x21, 0x01,
        0x20, 0x00,
        0x04, 0x40,
        *instr_i32_const(4),
        0x21, 0x01,
        0x0B,
        0x20, 0x01,
        0x0B,
    ]

    type_payload = [
        0x01,
        0x60, 0x01, 0x7F, 0x01, 0x7F,
    ]
    func_payload = [0x02, 0x00, 0x00]
    choose_name = [ord(c) for c in "choose"]
    no_else_name = [ord(c) for c in "noelse"]
    export_payload = [
        0x02,
        len(choose_name), *choose_name, 0x00, 0x00,
        len(no_else_name), *no_else_name, 0x00, 0x01,
    ]
    code_payload = [
        0x02,
        *u32_leb(len(choose_code)), *choose_code,
        *u32_leb(len(no_else_code)), *no_else_code,
    ]

    return [
        0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00,
        *wasm_section(1, type_payload),
        *wasm_section(3, func_payload),
        *wasm_section(7, export_payload),
        *wasm_section(10, code_payload),
    ]


def wasm_loop_module() -> list[int]:
    sum_to_code = [
        0x01, 0x02, 0x7F,
        *instr_i32_const(0),
        0x21, 0x01,
        0x02, 0x40,
        0x03, 0x40,
        0x20, 0x00,
        0x45,
        0x0D, 0x01,
        0x20, 0x01,
        0x20, 0x00,
        0x6A,
        0x21, 0x01,
        0x20, 0x00,
        *instr_i32_const(1),
        0x6B,
        0x21, 0x00,
        0x0C, 0x00,
        0x0B,
        0x0B,
        0x20, 0x01,
        0x0B,
    ]

    type_payload = [
        0x01,
        0x60, 0x01, 0x7F, 0x01, 0x7F,
    ]
    func_payload = [0x01, 0x00]
    name = [ord(c) for c in "sumto"]
    export_payload = [0x01, len(name), *name, 0x00, 0x00]
    code_payload = [0x01, *u32_leb(len(sum_to_code)), *sum_to_code]

    return [
        0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00,
        *wasm_section(1, type_payload),
        *wasm_section(3, func_payload),
        *wasm_section(7, export_payload),
        *wasm_section(10, code_payload),
    ]


def nim_byte_array(data: list[int]) -> str:
    return ", ".join(f"byte 0x{b:02X}" for b in data)


def test_flash_wasm_module_ranges_and_lazy_compact_runtime(tmp_path: Path) -> None:
    source = tmp_path / "flash_wasm_check.nim"
    source.write_text(
        textwrap.dedent(
            """
            import cps/wasm/[flash_image, runtime_int]

            let addModule = @[
              byte 0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00,
              0x01, 0x07, 0x01, 0x60, 0x02, 0x7F, 0x7F, 0x01, 0x7F,
              0x03, 0x02, 0x01, 0x00,
              0x07, 0x07, 0x01, 0x03, 0x61, 0x64, 0x64, 0x00, 0x00,
              0x0A, 0x09, 0x01, 0x07, 0x00, 0x20, 0x00, 0x20, 0x01, 0x6A, 0x0B
            ]

            let memoryModule = @[
              byte 0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00,
              0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7F,
              0x03, 0x03, 0x02, 0x00, 0x00,
              0x05, 0x03, 0x01, 0x00, 0x01,
              0x07, 0x13, 0x02,
              0x06, 0x6D, 0x65, 0x6D, 0x69, 0x33, 0x32, 0x00, 0x00,
              0x06, 0x6D, 0x65, 0x6D, 0x66, 0x33, 0x32, 0x00, 0x01,
              0x0A, 0x2C, 0x02,
              0x17, 0x00, 0x41, 0x10, 0x28, 0x02, 0x00, 0x41, 0x01, 0x6A,
              0x41, 0x14, 0x41, 0x07, 0x36, 0x02, 0x00, 0x41, 0x14, 0x28, 0x02, 0x00,
              0x6A, 0x0B,
              0x12, 0x00, 0x41, 0x20, 0x43, 0x00, 0x00, 0xB0, 0x40, 0x38, 0x02, 0x00,
              0x41, 0x20, 0x2A, 0x02, 0x00, 0xBC, 0x0B,
              0x0B, 0x0A, 0x01, 0x00, 0x41, 0x10, 0x0B, 0x04, 0x29, 0x00, 0x00, 0x00
            ]

            let i32OpsModule = @[
              __I32_OPS__
            ]

            let directCallModule = @[
              __DIRECT_CALL__
            ]

            let ifElseModule = @[
              __IF_ELSE__
            ]

            let loopModule = @[
              __LOOP__
            ]

            var addWithCustom: seq[byte] = @[]
            for i in 0 ..< 8:
              addWithCustom.add(addModule[i])
            addWithCustom.add(0x00'u8)
            addWithCustom.add(0x03'u8)
            addWithCustom.add(0x01'u8)
            addWithCustom.add(0x78'u8)
            addWithCustom.add(0x79'u8)
            for i in 8 ..< addModule.len:
              addWithCustom.add(addModule[i])

            let addFlash = parseFlashWasmModule(addWithCustom)
            doAssert addFlash.sections.len == 5
            doAssert addFlash.codes.len == 1
            doAssert addFlash.codes[0].codeLen == 6
            doAssert byteAt(addFlash.image, addFlash.codes[0].codeOffset) == 0x20'u8
            doAssert addFlash.image.rangePtr(addFlash.codes[0].codeOffset, 1)[0] == 0x20'u8

            var addVm = initIntWasmVM()
            let addIdx = addVm.instantiateFlashIntOnly(addFlash)
            doAssert addVm.invokeI32(addIdx, "add", [19'i32, 23'i32]) == 42'i32

            let memFlash = parseFlashWasmModule(memoryModule)
            doAssert memFlash.datas.len == 1
            doAssert memFlash.datas[0].dataLen == 4
            doAssert byteAt(memFlash.image, memFlash.datas[0].dataOffset) == 0x29'u8
            doAssert memFlash.image.rangeBytes(memFlash.datas[0].dataOffset, 4) == @[
              byte 0x29, 0x00, 0x00, 0x00
            ]

            var memVm = initIntWasmVM()
            let memIdx = memVm.instantiateFlashIntOnly(memFlash)
            doAssert memVm.invokeI32(memIdx, "memi32", []) == 49'i32
            doAssert cast[uint32](memVm.invokeI32(memIdx, "memf32", [])) == 0x40B0_0000'u32

            let i32OpsFlash = parseFlashWasmModule(i32OpsModule)
            var i32OpsVm = initIntWasmVM()
            let i32OpsIdx = i32OpsVm.instantiateFlashIntOnly(i32OpsFlash)
            doAssert i32OpsVm.invokeI32(i32OpsIdx, "i32ops", []) == 20'i32

            let directCallFlash = parseFlashWasmModule(directCallModule)
            var directCallVm = initIntWasmVM()
            let directCallIdx = directCallVm.instantiateFlashIntOnly(directCallFlash)
            doAssert directCallVm.invokeI32(directCallIdx, "caller", []) == 43'i32

            let ifElseFlash = parseFlashWasmModule(ifElseModule)
            var ifElseVm = initIntWasmVM()
            let ifElseIdx = ifElseVm.instantiateFlashIntOnly(ifElseFlash)
            doAssert ifElseVm.invokeI32(ifElseIdx, "choose", [1'i32]) == 7'i32
            doAssert ifElseVm.invokeI32(ifElseIdx, "choose", [0'i32]) == 11'i32
            doAssert ifElseVm.invokeI32(ifElseIdx, "noelse", [1'i32]) == 4'i32
            doAssert ifElseVm.invokeI32(ifElseIdx, "noelse", [0'i32]) == 3'i32

            let loopFlash = parseFlashWasmModule(loopModule)
            var loopVm = initIntWasmVM()
            let loopIdx = loopVm.instantiateFlashIntOnly(loopFlash)
            doAssert loopVm.invokeI32(loopIdx, "sumto", [5'i32]) == 15'i32
            doAssert loopVm.invokeI32(loopIdx, "sumto", [0'i32]) == 0'i32
            """
        )
        .replace("__I32_OPS__", nim_byte_array(wasm_i32_ops_module()))
        .replace("__DIRECT_CALL__", nim_byte_array(wasm_direct_call_module()))
        .replace("__IF_ELSE__", nim_byte_array(wasm_if_else_module()))
        .replace("__LOOP__", nim_byte_array(wasm_loop_module()))
    )

    subprocess.run(
        ["nim", "c", "-r", "--path:src", str(source)],
        cwd=REPO_ROOT,
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
