"""Test the real freestanding console/buffer formatter against host libc."""
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys

import pytest

from test_wifi_disconnect_tx import FW, ROOT, procedure
from test_wifi_message_allocation import run_program

CONSOLE = ROOT / "src/bl808/wifi/support/vendor_console_parts"


def flatten(path: Path) -> str:
    return re.sub(r"(?m)^include ([\w/]+)\s*$",
                  lambda match: flatten(path.parent / (match[1] + ".nim")), path.read_text())


PRELUDE = r'''
var printed: string
var sinkHook: proc()
proc vendorPrintChar(c: char) =
  printed.add(c)
  if sinkHook != nil:
    let action = sinkHook
    sinkHook = nil
    action()
proc testPrintChar(c: char) {.exportc: "bl808_nim_vendor_print_char", cdecl.} = vendorPrintChar(c)
proc testPuts(s: cstring) {.exportc: "bl808_nim_vendor_puts_raw", cdecl.} =
  if s != nil:
    var i = 0
    while s[i] != '\0':
      vendorPrintChar(s[i])
      inc i
{.emit: """
#include <stdio.h>
#include <stdint.h>
#include <stddef.h>
#include <stdarg.h>
#define printf bl808_test_printf
#define puts bl808_test_puts
#define snprintf bl808_test_snprintf
#define sprintf bl808_test_sprintf
static int bl808_test_oracle(char *output, size_t size, const char *format, ...) {
  va_list args;
  va_start(args, format);
  int result = vsnprintf(output, size, format, args);
  va_end(args);
  return result;
}
""".}
'''

CHECKS = r'''
proc targetSnprintf(output: pointer; size: csize_t; format: cstring): cint
  {.importc: "bl808_test_snprintf", nodecl, cdecl, varargs.}
proc targetSprintf(output: pointer; format: cstring): cint
  {.importc: "bl808_test_sprintf", nodecl, cdecl, varargs.}
proc targetPrintf(format: cstring): cint {.importc: "bl808_test_printf", nodecl, cdecl, varargs.}
proc targetOsPrintf(format: cstring) {.importc: "bl808_nim_os_printf", nodecl, cdecl, varargs.}
proc targetLog(level: uint32; tag, file: cstring; line: cint; format: cstring)
  {.importc: "bl808_nim_os_log_write", nodecl, cdecl, varargs.}
proc oracle(output: pointer; size: csize_t; format: cstring): cint
  {.importc: "bl808_test_oracle", nodecl, cdecl, varargs.}
proc bytesToString(bytes: var openArray[char]; count: int): string =
  result = newString(count)
  if count != 0: copyMem(addr result[0], addr bytes[0], count)
template verifyConsole(format: cstring; args: varargs[untyped]) =
  block:
    var expected: array[256, char]
    let count = oracle(addr expected[0], expected.len.csize_t, format, args)
    doAssert count >= 0 and count < expected.len.cint
    let text = bytesToString(expected, count.int)
    printed.setLen(0)
    targetOsPrintf(format, args)
    doAssert printed == text, repr(printed) & " != " & repr(text)
    printed.setLen(0)
    targetLog(2, nil, nil, 123, format, args)
    doAssert printed == text
template verify(format: cstring; args: varargs[untyped]) =
  block:
    for capacity in [0, 1, 2, 4, 15, 31, 128]:
      var actual, expected: array[160, char]
      for i in 0 ..< actual.len: actual[i] = char(0xA5); expected[i] = char(0xA5)
      printed.setLen(0)
      let wanted = oracle(addr expected[8], capacity.csize_t, format, args)
      let got = targetSnprintf(addr actual[8], capacity.csize_t, format, args)
      doAssert actual == expected, "buffer output or surrounding bytes differ"
      doAssert got == wanted and printed.len == 0, "snprintf return count differs"
    doAssert targetSnprintf(nil, 0, format, args) == oracle(nil, 0, format, args)
    verifyConsole(format, args)
    printed.setLen(0)
    let count = targetPrintf(format, args)
    doAssert count == printed.len.cint
'''


def source() -> str:
    return PRELUDE + flatten(CONSOLE / "c_stdio_shims.nim") + CHECKS


def run(tmp_path: Path, mode: str, code: str) -> None:
    if mode != "ubsan":
        run_program(tmp_path, mode, code)
        return
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("Nim is required")
    path = tmp_path / "format.nim"
    path.write_text(code)
    result = subprocess.run([nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on",
        "--skipUserCfg:on", "--cc:clang", "-d:release", "--assertions:on",
        "--passC:-fsanitize=undefined", "--passC:-fno-sanitize-recover=undefined",
        "--passL:-fsanitize=undefined", f"--nimcache:{tmp_path / 'cache'}",
        f"-o:{tmp_path / 'test'}", str(path)], cwd=ROOT, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=90)
    assert result.returncode == 0, result.stdout


CASES = {
    "numbers": r'''
for value in [low(cint), -1000000, -255, -10, -1, 0, 1, 15, 255, 1000000, high(cint)]:
  for format in ["%d", "%i", "%+08d", "% 12d", "%-12.6d", "%.0d"]:
    verify(format.cstring, value.cint)
for value in [0'u32, 1, 15, 255, 65535, high(uint32)]:
  for format in ["%u", "%08x", "%#12X", "%#o", "%#.0o", "%#.16o", "%#.12x"]:
    verify(format.cstring, value.cuint)
verify("pwr chan[%d] offset:%d\r\n", 13.cint, -128.cint)
''',
    "length_modifiers": r'''
for value in [low(int64), -4294967297'i64, -1, 0, 4294967297, high(int64)]:
  verify("%lld|%020lld|%d", value.clonglong, value.clonglong, 173.cint)
  verify("%llu|%#llx|%u", cast[uint64](value).culonglong, cast[uint64](value).culonglong, 173.cuint)
for value in [low(clong), -1.clong, 0, high(clong)]:
  verify("%ld|%lu|%08lx|%d", value, cast[culong](value), cast[culong](value), 173.cint)
for value in -300 .. 300:
  verify("%hhd|%hd|%hhu|%hu|%d", value.cint, value.cint, (value and 65535).cint, (value and 65535).cint, 173.cint)
verify("%zu|%u", high(csize_t), 173.cuint)
''',
    "padding_precision": r'''
for width in [-20, -1, 0, 1, 7, 20]:
  for precision in [-3, 0, 1, 4, 12]:
    verify("%#0*.*x:%+*.*d", width.cint, precision.cint, 0xABCD.cuint,
      width.cint, precision.cint, -123.cint)
    verify("%#0*.*o:END", width.cint, precision.cint, 0.cuint)
''',
    "strings_characters_pointers": r'''
for text in ["", "A", "ordinary string", "line\r\nend"]:
  for width in [-12, 0, 12]:
    for precision in [-1, 0, 1, 5]:
      verify("%*.*s/%c/%%", width.cint, precision.cint, text.cstring, 0.cint)
var bounded = ['A', 'B', 'C']
verify("%.3s", cast[cstring](addr bounded[0]))
for value in [1'u, 0xABCD, high(uint)]:
  verify("[%p][%20p]", cast[pointer](value), cast[pointer](value))
''',
    "console_signed_minimum": r'''
verifyConsole("%d|%i|%ld", low(cint), low(cint), low(clong))
''',
    "console_padding_and_case": r'''
verifyConsole("%02x:%02X:%08lx:%#x:%-8s", 10.cuint, 10.cuint, 0xABCD.culong, 0xABCD.cuint, cstring("OK"))
''',
    "console_wide_values": r'''
verifyConsole("%lld|%llu|%d", -4294967297.clonglong, high(culonglong), 173.cint)
''',
    "defined_flag_combinations": r'''
for conversion in ['d', 'i', 'u', 'o', 'x', 'X']:
  for mask in 0 .. 31:
    let signed = conversion in {'d', 'i'}
    if not signed and (mask and 6) != 0: continue
    if conversion in {'d', 'i', 'u'} and (mask and 16) != 0: continue
    var flags = ""
    for bit, flag in ['-', '+', ' ', '0', '#']:
      if (mask and (1 shl bit)) != 0: flags.add(flag)
    for width in [0, 1, 8, 20]:
      for precision in [-1, 0, 3, 17]:
        let format = "%" & flags & $width & (if precision < 0: "" else: "." & $precision) & $conversion
        for raw in [0'u32, 1, 42, high(uint32)]:
          if signed: verify(format.cstring, cast[cint](raw))
          else: verify(format.cstring, raw.cuint)
''',
    "errors_and_large_counts": r'''
var output: array[16, char]
for format in ["%", "%07", "prefix %f", "%ls", "%n", "%9999999999999999999d"]:
  for value in output.mitems: value = char(0xA5)
  doAssert targetSnprintf(addr output[0], output.len.csize_t, format.cstring) == -1
  doAssert '\0' in output
doAssert targetSnprintf(addr output[0], output.len.csize_t, "%p", nil) == 3
doAssert $cast[cstring](addr output[0]) == "0x0"
doAssert targetSnprintf(addr output[0], output.len.csize_t, "%s", cast[cstring](nil)) == 6
doAssert $cast[cstring](addr output[0]) == "(null)"
doAssert targetSnprintf(nil, 16, "literal") == -1
doAssert targetSnprintf(addr output[0], output.len.csize_t, nil) == 0 and output[0] == '\0'
doAssert targetSnprintf(addr output[0], output.len.csize_t, "%2147483647d", 0.cint) == high(cint)
for i in 0 ..< output.len - 1: doAssert output[i] == ' '
doAssert output[^1] == '\0'
doAssert targetSnprintf(addr output[0], output.len.csize_t, "%2147483647dX", 0.cint) == -1
doAssert targetSnprintf(addr output[0], output.len.csize_t, "%*d", low(cint), 0.cint) == -1
doAssert targetPrintf(nil) == 0
''',
    "reentrant_console": r'''
proc nested() = targetOsPrintf("inner:%d", -5.cint)
printed.setLen(0)
sinkHook = nested
doAssert targetPrintf("X%dZ", 123.cint) == 5
doAssert printed == "Xinner:-5123Z"
''',
}


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware", "ubsan"])
@pytest.mark.parametrize("case", CASES)
def test_console_format(tmp_path: Path, mode: str, case: str) -> None:
    run(tmp_path, mode, source() + CASES[case])


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware", "ubsan"])
def test_config_dump_uses_actual_target_formatter(tmp_path: Path, mode: str) -> None:
    code = source() + r'''
proc c_snprintf(output: pointer; size: csize_t; format: cstring): cint
  {.importc: "bl808_test_snprintf", nodecl, cdecl, varargs.}
'''
    code += procedure((FW / "mac_config_debug.nim").read_text(), "cfg_api_element_dump")
    run(tmp_path, mode, code + r'''
const names = ["Boolean", "SINT8", "UINT8", "SINT16", "UINT16", "SINT32", "UINT32", "STRING"]
for raw in [0'u32, 1, 127, 128, 255, 32767, 32768, 65535, 0x80000000'u32, high(uint32)]:
  var input = raw
  for kind in 1'u32 .. 8:
    var actual: array[31, char]
    for value in actual.mitems: value = char(0xA5)
    let name = cast[cstring](cfg_api_element_dump(addr input, kind, addr actual[8]))
    let expected = case kind
      of 1: (if (raw and 255) != 0: "True" else: "False")
      of 2: $cast[int8](raw.uint8)
      of 3: $raw.uint8
      of 4: $cast[int16](raw.uint16)
      of 5: $raw.uint16
      of 6: $cast[int32](raw)
      else: $raw
    doAssert $name == names[kind.int - 1]
    doAssert $cast[cstring](addr actual[8]) == expected
    for i in 0 ..< 8: doAssert actual[i] == char(0xA5)
    for i in 23 ..< actual.len: doAssert actual[i] == char(0xA5)
  doAssert input == raw
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware", "ubsan"])
def test_size_and_max_integer_c_argument_types(tmp_path: Path, mode: str) -> None:
    run(tmp_path, mode, source() + r'''
{.emit: """
static int bl808_test_typed(char *output, size_t size, int reference) {
  int (*format)(char *, size_t, const char *, ...) = reference ? bl808_test_oracle : bl808_test_snprintf;
  return format(output, size, "%jd|%ju|%zd|%zu|%td|%tu|%d",
    (intmax_t)INTMAX_MIN, (uintmax_t)UINTMAX_MAX,
    _Generic((size_t)0, unsigned int: (int)-123, unsigned long: (long)-123,
      unsigned long long: (long long)-123), (size_t)SIZE_MAX, (ptrdiff_t)PTRDIFF_MIN,
    _Generic((ptrdiff_t)0, int: (unsigned int)UINTPTR_MAX,
      long: (unsigned long)UINTPTR_MAX, long long: (unsigned long long)UINTPTR_MAX), 173);
}
""".}
proc typed(output: pointer; size: csize_t; reference: cint): cint
  {.importc: "bl808_test_typed", nodecl, cdecl.}
for capacity in [0, 1, 8, 128]:
  var actual, expected: array[160, char]
  for i in 0 ..< actual.len: actual[i] = char(0xA5); expected[i] = char(0xA5)
  let wanted = typed(addr expected[8], capacity.csize_t, 1)
  let got = typed(addr actual[8], capacity.csize_t, 0)
  doAssert got == wanted and actual == expected
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware", "ubsan"])
def test_assert_trace_uses_actual_target_formatter(tmp_path: Path, mode: str) -> None:
    from test_wifi_assert_logging import source as assertion_source
    assertions = assertion_source()
    stub = "proc nimFwTrace(message: cstring) = discard"
    assert assertions.count(stub) == 1
    assertions = assertions.replace(stub, "proc nimFwTrace(message: cstring) = traceMessages.add($message)")
    run(tmp_path, mode, source() + "var traceMessages: seq[string]\n" + assertions + r'''
for suppliedFile in [false, true]:
  for longName in [false, true]:
    for line in [low(cint), -7, 0, 479, high(cint)]:
      setup(false)
      traceMessages.setLen(0)
      var name = if longName: newString(150) else: "rxl_cntrl.c"
      if longName:
        for c in name.mitems: c = 'A'
      assert_err(cstring("condition"), (if suppliedFile: name.cstring else: nil), line)
      var expected = "[WIFI-NIMFW] assert " & (if suppliedFile: name else: "condition") & ":" & $line
      if expected.len > 95: expected.setLen(95)
      doAssert traceMessages == @[expected]
      doAssert keEvtField == 0x80000040'u32 and notes == 1
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware", "ubsan"])
def test_sprintf_entrypoint_and_return_count(tmp_path: Path, mode: str) -> None:
    code = source()
    assert "int sprintf(" in code, "freestanding firmware imports sprintf but the adapter does not provide it"
    run(tmp_path, mode, code + r'''
var actual, expected: array[160, char]
for i in 0 ..< actual.len: actual[i] = char(0xA5); expected[i] = char(0xA5)
let wanted = oracle(addr expected[8], 128, "%lld|%08x|%s", low(clonglong), 0xABCD.cuint, cstring("tail"))
let got = targetSprintf(addr actual[8], "%lld|%08x|%s", low(clonglong), 0xABCD.cuint, cstring("tail"))
doAssert actual == expected and got == wanted
''')


def test_rv32_probe_expected_bytes_match_host_libc(tmp_path: Path) -> None:
    clang = shutil.which("clang")
    if clang is None:
        pytest.skip("C compiler is required")
    output = tmp_path / "host-probe"
    compiled = subprocess.run([clang, "-std=c11", "-fno-builtin", "-DWIFI_CONSOLE_FORMAT_HOST",
        str(ROOT / "tools/wifi_console_format_probe.c"), "-o", str(output)], text=True,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=60)
    assert compiled.returncode == 0, compiled.stdout
    result = subprocess.run([str(output)], timeout=30)
    assert result.returncode == 0, f"host libc differs from probe case {result.returncode}"


def test_rv32_probe_missing_object_replaces_stale_success(tmp_path: Path) -> None:
    (tmp_path / "result.json").write_text('{"passed": true}\n')
    result = subprocess.run([sys.executable, str(ROOT / "tools/run_wifi_console_format_probe.py"),
        "--nimcache", str(tmp_path / "missing-cache"), "--work", str(tmp_path)], cwd=ROOT,
        capture_output=True, text=True, timeout=10)
    evidence = json.loads((tmp_path / "result.json").read_text())
    assert result.returncode == 2, result.stdout + result.stderr
    assert not evidence["passed"] and "required object is missing" in evidence["error"]
    assert evidence["commands"] == []
