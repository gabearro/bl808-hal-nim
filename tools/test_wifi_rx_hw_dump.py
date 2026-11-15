"""Check RX descriptor diagnostics, field layout, and critical callback balance."""

from pathlib import Path

import pytest

from test_wifi_auth_frames import layouts
from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


PLATFORM = "import std/strutils\n" + layouts(
    "RxHeaderHwDescView", "RxHeaderDumpView", "RxPayloadHwDescView",
) + r'''
type Record = tuple[kind: char, depth: int, message: string]
var
  headers: array[41, RxHeaderDumpView]
  payloads: array[41, RxPayloadHwDescView]
  records: seq[Record]
  headerReads, payloadReads: seq[int]
  children: seq[string]
  printEnabled, putsEnabled, enterEnabled, leaveEnabled: bool
  interruptsEnabled, entryIrq: bool
  token, restoredToken, events: uint32
  criticalDepth, enters, leaves: int
  enterAction, printAction: proc()
proc rxHeaderHwDescAt(index: int): ptr RxHeaderHwDescView =
  doAssert index in 0 ..< headers.len
  headerReads.add(index)
  cast[ptr RxHeaderHwDescView](addr headers[index])
proc rxHeaderDumpView(p: pointer): ptr RxHeaderDumpView = cast[ptr RxHeaderDumpView](p)
proc rxPayloadHwDescAt(index: int): ptr RxPayloadHwDescView =
  doAssert index in 0 ..< payloads.len
  payloadReads.add(index)
  addr payloads[index]
{.emit: "#include <stdarg.h>\n#include <stdio.h>".}
proc printer(format: cstring) {.cdecl, varargs.} =
  doAssert cast[uint](format) > 4096
  var output: array[512, char]
  var size: cint
  {.emit: ["va_list args; va_start(args, ", format, "); ", size,
    " = vsnprintf((char*)", output, ", sizeof(", output, "), ",
    format, ", args); va_end(args);"].}
  doAssert size >= 0 and size < output.len.cint
  records.add(('p', criticalDepth, $cast[cstring](addr output[0])))
  if criticalDepth == 1 and printAction != nil:
    let action = printAction
    printAction = nil
    action()
proc putter(s: cstring) {.cdecl.} = records.add(('s', criticalDepth, $s))
proc enterCritical(): uint32 {.cdecl.} =
  doAssert criticalDepth == 0
  entryIrq = interruptsEnabled
  interruptsEnabled = false
  inc criticalDepth
  inc enters
  records.add(('e', criticalDepth, "enter"))
  if enterAction != nil:
    let action = enterAction
    enterAction = nil
    action()
  token
proc leaveCritical(level: uint32) {.cdecl.} =
  doAssert criticalDepth == 1 and level == token
  restoredToken = level
  dec criticalDepth
  inc leaves
  interruptsEnabled = entryIrq
  records.add(('x', criticalDepth, "leave"))
proc logger(level: uint32; tag, file: cstring; line: cint; format: cstring)
    {.cdecl, varargs.} =
  doAssert level == 2 and tag == nil and file == cstring("ke_event.c")
  doAssert not interruptsEnabled
  records.add(('l', criticalDepth, $format))
proc blOpsFunc(offset: int): pointer =
  case offset
  of 4: (if printEnabled: cast[pointer](printer) else: nil)
  of 8: (if putsEnabled: cast[pointer](putter) else: nil)
  of 20: (if enterEnabled: cast[pointer](enterCritical) else: nil)
  of 24: (if leaveEnabled: cast[pointer](leaveCritical) else: nil)
  of 204: cast[pointer](logger)
  else: raiseAssert "unexpected platform slot"
proc snprintf(output: cstring; size: csize_t; format: cstring): cint
  {.importc, header: "<stdio.h>", varargs.}
proc ptrText(p: pointer): string =
  var output: array[64, char]
  discard snprintf(cast[cstring](addr output[0]), output.len.csize_t, "%p", p)
  $cast[cstring](addr output[0])
proc hex(value: SomeInteger; width = 8; upper = false): string =
  result = toHex(value.uint).strip(leading = true, trailing = false,
                                 chars = {'0'}).align(width, '0')
  if not upper: result = result.toLowerAscii
proc setup(irq = true; criticalToken = 0'u32) =
  doAssert sizeof(RxHeaderHwDescView) == sizeof(RxHeaderDumpView)
  headers = default(typeof(headers))
  payloads = default(typeof(payloads))
  records.setLen(0)
  children.setLen(0)
  headerReads.setLen(0)
  payloadReads.setLen(0)
  printEnabled = true
  putsEnabled = true
  enterEnabled = true
  leaveEnabled = true
  interruptsEnabled = irq
  entryIrq = irq
  token = criticalToken
  restoredToken = not token
  events = 64
  criticalDepth = 0
  enters = 0
  leaves = 0
  enterAction = nil
  printAction = nil
  for index in 0 ..< headers.len:
    let hd = addr headers[index]
    hd.magic = 0xBAADF00D'u32
    hd.next = cast[pointer](0xF1000000'u + index.uint * 100)
    hd.firstPbd = 0xF2000000'u32 + index.uint32 * 52
    hd.swDesc = 0xF3000000'u32 + index.uint32 * 24
    hd.dataStart = 0x60001000'u32 + index.uint32 * 256
    hd.dataEnd = hd.dataStart + 27
    hd.headerControl = 0x81000000'u32 + index.uint32
    hd.frameLength = (0xAB00 + index).uint16
    hd.ampduStatus = (0xC000 + index).uint16
    hd.timestampLow = 0x11000000'u32 + index.uint32
    hd.timestampHigh = 0x22000000'u32 + index.uint32
    hd.rxVector1a = 0xA0000000'u32 + index.uint32 # Not printed by the vendor.
    hd.rxVector1b = 0xB0000000'u32 + index.uint32
    hd.rxVector1c = 0xC0000000'u32 + index.uint32
    hd.rxVector1d = 0xD0000000'u32 + index.uint32
    hd.rxVector2a = 0xE0000000'u32 + index.uint32
    hd.rxVector2b = 0xF0000000'u32 + index.uint32
    hd.status = 0x91000000'u32 + index.uint32
    let pd = addr payloads[index]
    pd.magic = 0xC0DEDBAD'u32
    pd.next = cast[pointer](0xF4000000'u + index.uint * 52)
    pd.bufferAddr = 0x62001000'u32 + index.uint32 * 2048
    pd.bufferEnd = pd.bufferAddr + (100 + index).uint32
    pd.bufferStart = 0x6300F000'u32 # Not the start used by this dump.
    pd.status = 0xABCD1234'u32 + index.uint32
proc expected(): seq[Record] =
  if not printEnabled: return
  if putsEnabled:
    result.add(('s', 0, "---------- rxl_hwdesc_dump -------\r\n"))
  result.add(('p', 0, "rx_dma_hdrdesc: 41\r\n"))
  let depth = (enterEnabled and leaveEnabled).int
  if depth == 1: result.add(('e', 1, "enter"))
  for index, hd in headers:
    result.add(('p', depth, "  [" & ($index).align(2) & "]@" & hex(cast[uint](addr headers[index])) & ": upatternrx " & hex(hd.magic) & " next " & hex(cast[uint](hd.next)) & " first_pbd_ptr " & hex(hd.firstPbd) & ", swdesc " & ptrText(cast[pointer](hd.swDesc.uint)) & "\r\n"))
    result.add(('p', depth, "    datastartptr " & hex(hd.dataStart) & " dataendptr " & hex(hd.dataEnd) & ", headerctrlinfo " & hex(hd.headerControl) & " frmlen " & ($hd.frameLength).align(4) & " ampdu_stat_info " & hex(hd.ampduStatus, 4) & "\r\n"))
    result.add(('p', depth, "    tsflo " & hex(hd.timestampLow) & " tsfhi " & hex(hd.timestampHigh) & " recvec1b " & hex(hd.rxVector1b) & " recvec1c " & hex(hd.rxVector1c) & " recvec1d " & hex(hd.rxVector1d) & " recvec2a " & hex(hd.rxVector2a) & " recvec2b " & hex(hd.rxVector2b) & " statinfo " & hex(hd.status) & "\r\n"))
  if depth == 1: result.add(('x', 0, "leave"))
  result.add(('p', 0, "rx_payload_desc: 41\r\n"))
  for index, pd in payloads:
    let length = if pd.bufferEnd == 0: 0'u32 else: pd.bufferEnd + 1 - pd.bufferAddr
    result.add(('p', 0, "  [" & ($index).align(2) & "]@" & hex(cast[uint](addr payloads[index])) & " " & ($length).align(3) & " Bytes: upatternrx " & hex(pd.magic) & " next " & hex(cast[uint](pd.next)) & " datastartptr " & hex(pd.bufferAddr) & " dataendptr " & hex(pd.bufferEnd) & " bufstatinfo " & hex(pd.status and 0xFFFF, 4) & " reserved " & hex(pd.status shr 16, 4, true) & "\r\n"))
proc ke_evt_clear(mask: uint32) = events = events and not mask
proc irqSave(): uint32 =
  result = if interruptsEnabled: 8'u32 else: 0'u32
  interruptsEnabled = false
proc irqRestore(saved: uint32) = interruptsEnabled = (saved and 8) != 0
proc observe(name: string) =
  doAssert not interruptsEnabled
  children.add(name)
proc bl_utils_dump() {.exportc, cdecl.} = observe("utils")
proc txl_frame_dump() = observe("frame")
proc ipc_emb_dump() = observe("ipc")
proc txl_cntrl_env_dump() = observe("tx")
proc txl_cfm_dump() = observe("confirm")
proc rxl_cntrl_dump() = observe("rx")
'''


CASES = {
    "critical_state": r'''
for irq in [false, true]:
  for state in [0'u32, 1, 8, 0xFEDCBA98'u32]:
    setup(irq, state)
    rxl_hwdesc_dump()
    doAssert enters == 1 and leaves == 1, "critical callback pair is unbalanced"
    doAssert restoredToken == state and criticalDepth == 0
    doAssert interruptsEnabled == irq
''',
    "callback_replacement": r'''
for stage in 0 .. 1:
  setup(true, 0)
  let wanted = expected()
  proc replace() =
    enterEnabled = false
    leaveEnabled = false
  if stage == 0: enterAction = replace
  else: printAction = replace
  rxl_hwdesc_dump()
  doAssert records == wanted and leaves == 1 and criticalDepth == 0
  doAssert interruptsEnabled and restoredToken == 0
''',
    "arguments": r'''
setup(true, 0)
let wanted = expected()
let before = (headers, payloads)
rxl_hwdesc_dump()
doAssert records == wanted
doAssert (headers, payloads) == before
doAssert headerReads.len == 41 and payloadReads.len == 41
for index in 0 ..< 41:
  doAssert headerReads[index] == index and payloadReads[index] == index
''',
    "missing_hooks": r'''
for enter in [false, true]:
  for leave in [false, true]:
    setup()
    enterEnabled = enter
    leaveEnabled = leave
    let wanted = expected()
    rxl_hwdesc_dump()
    doAssert records == wanted and criticalDepth == 0 and interruptsEnabled
    doAssert enters == (enter and leave).int and leaves == enters
setup()
putsEnabled = false
let wanted = expected()
rxl_hwdesc_dump()
doAssert records == wanted
setup()
printEnabled = false
rxl_hwdesc_dump()
doAssert records.len == 0 and enters == 0 and leaves == 0
doAssert headerReads.len == 0 and payloadReads.len == 0
''',
    "payload_lengths": r'''
setup()
payloads[0].bufferEnd = 0
payloads[1].bufferAddr = high(uint32)
payloads[1].bufferEnd = high(uint32)
payloads[2].bufferAddr = 100
payloads[2].bufferEnd = 99
payloads[3].bufferAddr = 100
payloads[3].bufferEnd = 98
let wanted = expected()
rxl_hwdesc_dump()
doAssert records == wanted
''',
    "statistics_caller": r'''
for irq in [false, true]:
  setup(irq, 0)
  var wanted: seq[Record] = @[('l', 0,
    "\r\n==========================FW STATISTIC DUMP S===================\r\n")]
  wanted.add(expected())
  wanted.add(('l', 0,
    "==========================FW STATISTIC DUMP E===================\r\n"))
  bl_fw_statistic_dump()
  doAssert records == wanted and criticalDepth == 0 and restoredToken == 0
  doAssert interruptsEnabled == irq and events == 0
  doAssert children == @["utils", "frame", "ipc", "tx", "confirm", "rx"]
''',
}


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("case", CASES)
def test_rx_hw_dump(tmp_path: Path, mode: str, case: str) -> None:
    rx = (FW / "rx_layer.nim").read_text()
    kernel = (FW / "kernel_mac_channel.nim").read_text()
    code = PLATFORM + procedure(rx, "rxl_hwdesc_dump")
    code += procedure(kernel, "bl_fw_statistic_dump")
    run_program(tmp_path, mode, code + CASES[case])
