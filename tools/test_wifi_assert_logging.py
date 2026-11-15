"""Verify assertion callback ABI, MAC status reads, and reset requests."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


PLATFORM = r'''
type
  ArchAssertLogFn = proc(level: uint32; tag, file: cstring; line: cint;
                         format: cstring) {.cdecl, varargs.}
  LegacyLogFn = proc(level, severity: uint32; file: pointer;
                     line: uint32) {.cdecl, varargs.}
  Record = tuple[line: cint, message: string]
const MACHW_INTC_BASE = 0x24B08000'u
var
  records: seq[Record]
  reads: seq[uint]
  operations: seq[string]
  dbg_assert_block: array[10, uint32]
  keEvtField: uint32
  interrupts, expectedIrq, loggerEnabled, printerEnabled: bool
  logAction: proc()
  notes, logLookups: int
  words = [0x1234ABCD'u32, 0x89ABCDEF'u32, 0x01020304'u32, 0'u32,
           0xFEDCBA98'u32, 0x10203040'u32, 0xFFFFFFFF'u32, 1'u32]
{.emit: """
#include <stdarg.h>
#include <stdio.h>
void cfg_trace(char *s) { (void)s; }
void cfg_trace_rc(char *s, int value) { (void)s; (void)value; }
""".}
proc logger(level: uint32; tag, file: cstring; line: cint; format: cstring)
    {.cdecl, varargs.} =
  doAssert level == 2 and tag == nil
  doAssert file != nil and file == cstring("arch_main.c")
  doAssert format != nil and cast[uint](format) > 4096
  doAssert interrupts == expectedIrq
  var output: array[256, char]
  var size: cint
  {.emit: ["va_list args; va_start(args, ", format, "); ", size,
    " = vsnprintf((char*)", output, ", sizeof(", output, "), ",
    format, ", args); va_end(args);"].}
  doAssert size >= 0 and size < output.len.cint
  records.add((line, $cast[cstring](addr output[0])))
  operations.add("log")
  if logAction != nil: logAction()
proc printer(format: cstring) {.cdecl, varargs.} =
  doAssert interrupts == expectedIrq
  doAssert format != nil and format == cstring("Recovery MAC...\r\n")
  operations.add("print")
proc taskNotify(task: pointer) {.cdecl.} =
  doAssert false, "assertion logger called the task-notify slot"
proc enterCritical(): uint32 {.cdecl.} =
  result = if interrupts: 8'u32 else: 0'u32
  interrupts = false
proc leaveCritical(saved: uint32) {.cdecl.} =
  doAssert not interrupts
  interrupts = (saved and 8) != 0
proc blOpsFunc(slot: int): pointer =
  case slot
  of 204:
    inc logLookups
    if loggerEnabled: cast[pointer](logger) else: nil
  of 76: cast[pointer](taskNotify)
  of 4: (if printerEnabled: cast[pointer](printer) else: nil)
  of 20: cast[pointer](enterCritical)
  of 24: cast[pointer](leaveCritical)
  else: raiseAssert "unexpected callback slot"
proc getLogFunc(slot: int): LegacyLogFn = cast[LegacyLogFn](blOpsFunc(slot))
proc regRead(address: uint): uint32 =
  doAssert address >= MACHW_INTC_BASE + 0x188 and
    address <= MACHW_INTC_BASE + 0x1A4 and address mod 4 == 0
  reads.add(address)
  words[((address - MACHW_INTC_BASE - 0x188) div 4).int]
proc c_snprintf(output: pointer; size: csize_t; format: cstring): cint
  {.importc: "snprintf", header: "<stdio.h>", varargs.}
proc noteAssertErr(file: cstring; line: cint) = inc notes
proc nimFwTrace(message: cstring) = discard
proc nimFwTraceU32(message: string; value: uint32) = discard
proc nimFwTrace2U32(message: string; first, second: uint32) = discard
proc irqSave(): uint32 =
  result = if interrupts: 8'u32 else: 0'u32
  interrupts = false
proc irqRestore(saved: uint32) = interrupts = (saved and 8) != 0
proc hal_machw_disable_int() =
  doAssert not interrupts
  operations.add("disable")
proc ke_evt_set(mask: uint32) =
  doAssert not interrupts and mask == 0x80000000'u32
  operations.add("reset")
  keEvtField = keEvtField or mask
proc setup(irq: bool; pending = false) =
  records.setLen(0)
  reads.setLen(0)
  operations.setLen(0)
  interrupts = irq
  expectedIrq = irq
  loggerEnabled = true
  printerEnabled = true
  logAction = nil
  notes = 0
  logLookups = 0
  keEvtField = if pending: 0x80000040'u32 else: 0x40'u32
  for word in dbg_assert_block.mitems: word = 0xDEADBEEF'u32
proc expected(kind: string; condition, file: string; line: cint): seq[Record] =
  if kind == "err":
    result = @[(148.cint, "[CON Err] " & condition & "\r\n"),
               (149.cint, "[file] " & file & "\r\n"),
               (150.cint, "[line] " & $line & "\r\n"),
               (151.cint, "[MAC] [STATUS] [DUMP]\r\n")]
  elif kind == "rec":
    result = @[(86.cint, "[CON REC] " & condition & "," & file & "," & $line & "\r\n"),
               (87.cint, "[MAC] [STATUS] [DUMP]\r\n")]
  else:
    return @[(179.cint, "[CON WRN] " & condition & "\r\n"),
             (180.cint, "[file] " & file & "\r\n"),
             (181.cint, "[line] " & $line & "\r\n")]
  result.add(((if kind == "err": 152.cint else: 88.cint),
    "    0x44B08188 1234ABCD 89abcdef 01020304 00000000\r\n"))
  result.add(((if kind == "err": 158.cint else: 94.cint),
    "    0x44B08198 FEDCBA98 10203040 ffffffff 00000001\r\n"))
'''


def source() -> str:
    text = (FW / "mac_config_debug.nim").read_text()
    code = PLATFORM
    if "proc logAssertMacStatus(" in text:
        code += procedure(text, "logAssertMacStatus")
    for name in ("assert_err", "assert_rec", "assert_warn"):
        code += procedure(text, name)
    return code + r'''
proc invoke(kind: string; condition, file: cstring; line: cint) =
  case kind
  of "err": assert_err(condition, file, line)
  of "rec": assert_rec(condition, file, line)
  else: assert_warn(condition, file, line)
proc checkTail(kind: string; pending: bool) =
  doAssert interrupts == expectedIrq
  doAssert notes == (kind == "err").int
  if kind == "warn":
    doAssert reads.len == 0 and keEvtField ==
      (if pending: 0x80000040'u32 else: 0x40'u32)
    doAssert "print" notin operations and "reset" notin operations
  else:
    doAssert reads.len == 8 and keEvtField == 0x80000040'u32
    for index, address in reads:
      doAssert address == MACHW_INTC_BASE + 0x188'u + index.uint * 4
    let reset = kind == "err" or not pending
    doAssert ("reset" in operations) == reset
    doAssert ("disable" in operations) == reset
    doAssert ("print" in operations) == (kind == "rec" and printerEnabled)
'''


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("kind", ["err", "rec", "warn"])
def test_assert_arguments(tmp_path: Path, mode: str, kind: str) -> None:
    run_program(tmp_path, mode, source() + f'let kind = "{kind}"\n' + r'''
for irq in [false, true]:
  for pending in [false, true]:
    setup(irq, pending)
    invoke(kind, "length %u != 0", "rxl_cntrl.c", -7)
    doAssert records == expected(kind, "length %u != 0", "rxl_cntrl.c", -7)
    checkTail(kind, pending)
  setup(irq)
  invoke(kind, nil, nil, 479)
  doAssert records == expected(kind, "(null)", "(null)", 479)
  checkTail(kind, false)
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_assert_missing_callbacks(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for kind in ["err", "rec", "warn"]:
  for irq in [false, true]:
    setup(irq)
    loggerEnabled = false
    printerEnabled = false
    invoke(kind, "condition", "rxl_cntrl.c", 479)
    doAssert records.len == 0
    checkTail(kind, false)
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_assert_logger_replacement(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for kind in ["err", "rec", "warn"]:
  for irq in [false, true]:
    setup(irq)
    logAction = proc() = loggerEnabled = false
    invoke(kind, "condition", "rxl_cntrl.c", 479)
    doAssert records == @[expected(kind, "condition", "rxl_cntrl.c", 479)[0]]
    doAssert logLookups == (if kind == "err": 6 elif kind == "rec": 4 else: 3)
    checkTail(kind, false)
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_rx_release_reports_after_critical_exit(tmp_path: Path, mode: str) -> None:
    lower = (FW / "rx_layer.nim").read_text()
    code = source() + r'''
type
  RxPayloadHwDescView = object
    next: pointer
    status, usedFlag: uint32
  RxSwDescView = object
    bufferChain: pointer
    uploadDone: uint32
  RxMpduDescView = object
    prevDesc, curDesc: pointer
var
  rx_payload_desc: array[2 * sizeof(RxPayloadHwDescView), uint8]
  header: RxSwDescView
  descriptor: RxMpduDescView
  generation: uint32
  releases: int
proc rxDmaProgressDescAt(p: pointer): ptr RxPayloadHwDescView =
  cast[ptr RxPayloadHwDescView](p)
proc rxMpduDescView(p: pointer): ptr RxMpduDescView = cast[ptr RxMpduDescView](p)
proc rxMpduHeader(p: pointer): ptr RxSwDescView =
  if p == addr descriptor: addr header else: nil
proc rxInvalidateUpload(p: pointer) = inc generation
proc rxUploadGeneration(p: pointer): uint32 = generation
proc rxUploadCurrent(p: pointer; expected: uint32): bool = generation == expected
proc rxl_frame_release(p: pointer) = inc releases
'''
    for name in ("rxPayloadDescIndex", "rxPayloadChainBounds", "rxl_mpdu_free"):
        code += procedure(lower, name)
    run_program(tmp_path, mode, code + r'''
for irq in [false, true]:
  setup(irq)
  zeroMem(addr rx_payload_desc[0], sizeof(rx_payload_desc))
  let first = rxDmaProgressDescAt(addr rx_payload_desc[0])
  let second = rxDmaProgressDescAt(addr rx_payload_desc[sizeof(RxPayloadHwDescView)])
  first.next = second
  second.next = first
  first.usedFlag = 7
  second.usedFlag = 9
  header = RxSwDescView(bufferChain: first, uploadDone: 1)
  rxl_mpdu_free(addr descriptor)
  doAssert records == expected("rec", "rxl_hwdesc.c", "rxl_hwdesc.c", 872)
  doAssert releases == 0 and header.uploadDone == 1
  doAssert first.usedFlag == 7 and second.usedFlag == 9
  checkTail("rec", false)
''')
