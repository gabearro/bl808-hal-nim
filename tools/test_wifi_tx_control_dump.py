"""Verify TX control diagnostics with the vendor fields and real C varargs."""

from pathlib import Path

import pytest

from test_wifi_auth_frames import layouts
from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


PLATFORM = r'''
import std/strutils
const NUM_TX_QUEUES = 5
type
  CoListHdr = object
    next: ptr CoListHdr
  CoList = object
    first, last: ptr CoListHdr
''' + layouts(
    "HostTxDescView", "HostTxHwDescView", "TxDumpHwDescView", "TxControlAcView",
    "TxDumpRateDescView", "TxDumpBufferDescView",
) + r'''
type Record = tuple[kind: char, file: string, line: cint, message: string]
var
  queues: array[NUM_TX_QUEUES, TxControlAcView]
  descriptors: array[6, HostTxDescView]
  hardware: array[6, TxDumpHwDescView]
  policies: array[6, TxDumpRateDescView]
  buffers: array[12, TxDumpBufferDescView]
  records: seq[Record]
  logEnabled, printEnabled, interruptsEnabled: bool
  countCalls, bufferReads: int
  events: uint32
  children: seq[string]
proc txControlAc(index: uint32): ptr TxControlAcView = addr queues[index]
proc hostTxDescAt(p: pointer): ptr HostTxDescView = cast[ptr HostTxDescView](p)
proc hostTxHwDescAt(p: pointer): ptr HostTxHwDescView = cast[ptr HostTxHwDescView](p)
proc txDumpHwDescAt(p: pointer): ptr TxDumpHwDescView = cast[ptr TxDumpHwDescView](p)
proc txDumpRateDescAt(p: pointer): ptr TxDumpRateDescView = cast[ptr TxDumpRateDescView](p)
proc txDumpBufferDescAt(p: pointer): ptr TxDumpBufferDescView =
  inc bufferReads
  # The first PBD pointer is a 32-bit word in the production hardware view.
  # Tokens adapt only that address to this native 64-bit process.
  let address = cast[uint](p)
  if address in 1'u .. buffers.len.uint: return addr buffers[address.int - 1]
  doAssert address >= cast[uint](addr buffers[0])
  doAssert address < cast[uint](addr buffers[0]) + sizeof(buffers).uint
  doAssert (address - cast[uint](addr buffers[0])) mod sizeof(buffers[0]).uint == 0
  cast[ptr TxDumpBufferDescView](p)
proc co_list_cnt(list: ptr CoList): uint32 =
  inc countCalls
  var node = list.first
  while node != nil:
    inc result
    doAssert result <= descriptors.len.uint32
    node = node.next
{.emit: "#include <stdarg.h>\n#include <stdio.h>".}
proc logger(level: uint32; tag, file: cstring; line: cint; format: cstring)
    {.cdecl, varargs.} =
  doAssert level == 2 and tag == nil
  doAssert file == cstring("txl_cntrl.c") or file == cstring("ke_event.c")
  doAssert cast[uint](format) > 4096
  var output: array[768, char]
  var size: cint
  {.emit: ["va_list args; va_start(args, ", format, "); ", size,
    " = vsnprintf((char*)", output, ", sizeof(", output, "), ",
    format, ", args); va_end(args);"].}
  doAssert size >= 0 and size < output.len.cint
  records.add(('l', $file, line, $cast[cstring](addr output[0])))
proc printer(format: cstring) {.cdecl, varargs.} =
  doAssert format == cstring(" %p(%08lx)") or format == cstring(" %08lx")
  var output: array[96, char]
  var size: cint
  {.emit: ["va_list args; va_start(args, ", format, "); ", size,
    " = vsnprintf((char*)", output, ", sizeof(", output, "), ",
    format, ", args); va_end(args);"].}
  doAssert size > 0 and size < output.len.cint
  records.add(('p', "", 0.cint, $cast[cstring](addr output[0])))
proc blOpsFunc(offset: int): pointer =
  case offset
  of 204: (if logEnabled: cast[pointer](logger) else: nil)
  of 4: (if printEnabled: cast[pointer](printer) else: nil)
  else: raiseAssert "unexpected platform slot"
proc getLogFunc(offset: int): pointer = blOpsFunc(offset)
proc snprintf(output: cstring; size: csize_t; format: cstring): cint
  {.importc, header: "<stdio.h>", varargs.}
proc ptrText(p: pointer): string =
  var output: array[64, char]
  discard snprintf(cast[cstring](addr output[0]), output.len.csize_t, "%p", p)
  $cast[cstring](addr output[0])
proc hex(value: SomeInteger): string =
  toHex(value.uint).toLowerAscii.strip(leading = true, trailing = false,
                                     chars = {'0'}).align(8, '0')
proc setup(populated: bool) =
  queues = default(typeof(queues))
  descriptors = default(typeof(descriptors))
  hardware = default(typeof(hardware))
  policies = default(typeof(policies))
  buffers = default(typeof(buffers))
  records.setLen(0)
  children.setLen(0)
  logEnabled = true
  printEnabled = true
  interruptsEnabled = true
  events = 64
  countCalls = 0
  bufferReads = 0
  if not populated: return
  var index = 0
  for ac, count in [2, 0, 1, 0, 3]:
    # Only pending is walked; current and counters are not descriptor links.
    queues[ac].current = cast[pointer](1)
    queues[ac].packetCount = 0xABCD
    queues[ac].busyFlag = 0xFFFF
    if count == 0: continue
    queues[ac].pending.first = addr descriptors[index].link
    for position in 0 ..< count:
      let desc = addr descriptors[index]
      let hw = addr hardware[index].hardware
      desc.hwDesc = hw
      desc.descriptorStatus = 0x12340000'u32 + index.uint32
      if position + 1 < count: desc.link.next = addr descriptors[index + 1].link
      queues[ac].pending.last = addr desc.link
      hw.txConfirmDescPtr = 1 # Not read by this dump.
      hw.magic = 0xCAFEBABE'u32
      hw.confirmStatus = 0xA1000000'u32 + index.uint32
      hw.frameLen = 64 + index.uint32
      hw.chainedThd = addr policies[index]
      hw.ackPolicyControl = 0x81000000'u32 + index.uint32
      hw.controlFlags = 0x82000000'u32 + index.uint32
      hardware[index].mediumTimeUsed = 0xF0000000'u32 + index.uint32
      hw.status = (2 * index + 1).uint32
      policies[index].rateDumpHeader0 = 0xAABBCCDD'u32
      policies[index].rateDumpHeader1 = 0x11111111
      policies[index].rateDumpHeader2 = 0x22222222
      policies[index].rateDumpHeader3 = 0x33333333
      policies[index].macControl2 = 1 # A control word, never a next pointer.
      for word in 0 ..< 4:
        policies[index].primaryPolicyWords[word] = 0x84000000'u32 + (index * 4 + word).uint32
        policies[index].secondaryPolicyWords[word] = 0x94000000'u32 + (index * 4 + word).uint32
      for part in 0 ..< 2:
        let bufferIndex = 2 * index + part
        let buffer = addr buffers[bufferIndex]
        buffer.bufferDumpHeader = 0xBADCAB1E'u32
        buffer.dataStart = 0x60001000'u32 + (bufferIndex * 128).uint32
        buffer.dataEnd = buffer.dataStart + (31 + bufferIndex).uint32
        buffer.control = 0xB1000000'u32 + bufferIndex.uint32
        if part == 0: buffer.next = addr buffers[bufferIndex + 1]
      inc index
proc expected(): seq[Record] =
  if not logEnabled: return
  template log(line: cint; message: string) = result.add(('l', "txl_cntrl.c", line.cint, message))
  template print(message: string) =
    if printEnabled: result.add(('p', "", 0.cint, message))
  log(0x925, "---------- txl_cntrl_env_dump ----\r\n")
  log(0x927, "txl_cntrl_env:\r\n")
  log(0x928, "  txlist: 5 [AC_BK AC_BE AC_VI AC_VO AC_BEACON]\r\n")
  for ac in 0 ..< 5:
    var nodes: seq[ptr HostTxDescView]
    var node = queues[ac].pending.first
    while node != nil:
      nodes.add(hostTxDescAt(node))
      node = node.next
    log(0x92C, "    [" & $ac & "] transmitting header " & ptrText(queues[ac].pending.first) & " and cnt " & $nodes.len & "\r\n")
    log(0x931, "      transmitting list:")
    for desc in nodes:
      let hw = hostTxHwDescAt(desc.hwDesc)
      let status = if hw == nil: 0'u32 else: hw.confirmStatus
      print(" " & ptrText(desc) & "(" & hex(status) & ")")
    log(0x939, "\r\n")
    for desc in nodes:
      log(0x8EF, "        txdesc@" & ptrText(desc) & ", pbuf " & ptrText(cast[pointer](desc.descriptorStatus.uint)) & ":\r\n")
      if desc.hwDesc == nil: continue
      let dumpHw = txDumpHwDescAt(desc.hwDesc)
      let hw = addr dumpHw.hardware
      log(0x8F0, "          thd " & ptrText(addr hw.magic) & ", upatterntx " & hex(hw.magic) & ", frmlen " & ($hw.frameLen).align(4) & ", policyentryaddr " & hex(cast[uint](hw.chainedThd)) & ", macctrlinfo1 " & hex(hw.ackPolicyControl) & ", macctrlinfo1 " & hex(hw.controlFlags) & " mediumtimeused " & $dumpHw.mediumTimeUsed & "\r\n")
      if hw.chainedThd != nil:
        let policy = txDumpRateDescAt(hw.chainedThd)
        log(0x8FB, "          tbl " & ptrText(policy) & ", upatterntx " & hex(policy.rateDumpHeader0) & ", phyctrlinfo_1 " & hex(policy.rateDumpHeader1) & ", phyctrlinfo_2 " & hex(policy.rateDumpHeader2) & ", macctrlinfo_1 " & hex(policy.rateDumpHeader3) & ", macctrlinfo_2 " & hex(policy.macControl2) & "\r\n")
        log(0x903, "            ratecntrlinfo: ")
        for word in policy.primaryPolicyWords: print(" " & hex(word))
        log(0x907, "\r\n")
        log(0x908, "            powercntrlinfo:")
        for word in policy.secondaryPolicyWords: print(" " & hex(word))
        log(0x90C, "\r\n")
      var bufferPointer = cast[pointer](hw.status.uint)
      var index = 0
      while bufferPointer != nil:
        let buffer = txDumpBufferDescAt(bufferPointer)
        let length = buffer.dataEnd + 1'u32 - buffer.dataStart
        log(0x911, "          pbd[" & $index & "] " & ($length).align(4) & " Bytes " & ptrText(bufferPointer) & ", upatterntx " & hex(buffer.bufferDumpHeader) & ", next " & hex(cast[uint](buffer.next)) & ", datastartptr " & hex(buffer.dataStart) & ", dataendptr " & hex(buffer.dataEnd) & ", bufctrlinfo " & hex(buffer.control) & "\r\n")
        bufferPointer = buffer.next
        inc index
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
proc txl_cfm_dump() = observe("confirm")
proc rxl_hwdesc_dump() = observe("rx-desc")
proc rxl_cntrl_dump() = observe("rx")
'''


CASES = {
    "arguments": r'''
for populated in [false, true]:
  setup(populated)
  let wanted = expected()
  bufferReads = 0
  let before = (queues, descriptors, hardware, policies, buffers)
  txl_cntrl_env_dump()
  doAssert records == wanted
  doAssert before == (queues, descriptors, hardware, policies, buffers)
  doAssert countCalls == 5 and interruptsEnabled
  doAssert bufferReads == (if populated: 12 else: 0)
''',
    "missing_callbacks": r'''
for populated in [false, true]:
  setup(populated)
  logEnabled = false
  txl_cntrl_env_dump()
  doAssert records.len == 0 and countCalls == 0 and bufferReads == 0
  setup(populated)
  printEnabled = false
  let wanted = expected()
  txl_cntrl_env_dump()
  doAssert records == wanted and countCalls == 5
''',
    "partial_descriptors": r'''
setup(true)
descriptors[0].hwDesc = nil
hardware[1].hardware.chainedThd = nil
hardware[2].hardware.status = 0
let wanted = expected()
txl_cntrl_env_dump()
doAssert records == wanted
''',
    "payload_lengths": r'''
setup(true)
buffers[0].dataStart = high(uint32)
buffers[0].dataEnd = high(uint32)
buffers[1].dataEnd = buffers[1].dataStart - 1
let wanted = expected()
txl_cntrl_env_dump()
doAssert records == wanted
''',
    "statistics_caller": r'''
for irq in [false, true]:
  setup(true)
  interruptsEnabled = irq
  var wanted: seq[Record] = @[('l', "ke_event.c", 158.cint,
    "\r\n==========================FW STATISTIC DUMP S===================\r\n")]
  wanted.add(expected())
  wanted.add(('l', "ke_event.c", 175.cint,
    "==========================FW STATISTIC DUMP E===================\r\n"))
  bl_fw_statistic_dump()
  doAssert records == wanted
  doAssert children == @["utils", "frame", "ipc", "confirm", "rx-desc", "rx"]
  doAssert events == 0 and interruptsEnabled == irq
''',
}


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("case", CASES)
def test_tx_control_dump(tmp_path: Path, mode: str, case: str) -> None:
    tx = (FW / "tx_layer.nim").read_text()
    kernel = (FW / "kernel_mac_channel.nim").read_text()
    code = PLATFORM + procedure(tx, "txl_cntrl_env_dump")
    code += procedure(kernel, "bl_fw_statistic_dump")
    run_program(tmp_path, mode, code + CASES[case])
