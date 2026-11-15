"""Exercise the real power-save log calls and their surrounding state updates."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


PLATFORM = r'''
const
  TASK_API = 9'u8
  VIF_TYPE_STA = 0'u8
  MACHW_TIMLO_REG = 0x24B00120'u
type
  PsEnv = object
    mode, flags, deferredMode, pendingCount, psActive, enabled: uint8
  Vif = object
    next: pointer
    flags, psLastTime: uint32
    vifType, state, psNullRetry, uapsdBitmap, staIdx, vifIdx, psOptions: uint8
  VifEnv = object
    activeList: tuple[first: pointer]
  MacHeader {.packed.} = object
    frameControl, duration: uint16
    addr1, addr2, addr3: array[6, uint8]
    seqCtrl: uint16
  QosHeader {.packed.} = object
    header: MacHeader
    qosCtrl: uint16
  Qos4Header {.packed.} = object
    header: MacHeader
    addr4: array[6, uint8]
    qosCtrl: uint16
var
  ps: PsEnv
  vif: Vif
  vifEnv: VifEnv
  logging: bool
  lookups: int
  powerControl, macNow: uint32
  events: seq[string]
  messages: seq[tuple[line: cint, text: string]]

proc psEnvView(): ptr PsEnv = addr ps
proc vifMgmtEnvView(): ptr VifEnv = addr vifEnv
proc vifChannelAt(p: pointer): ptr Vif = cast[ptr Vif](p)
proc macDataFrameAt(p: pointer): ptr MacHeader = cast[ptr MacHeader](p)
proc macQosDataFrameAt(p: pointer): ptr QosHeader = cast[ptr QosHeader](p)
proc macQos4AddrFrameAt(p: pointer): ptr Qos4Header = cast[ptr Qos4Header](p)
proc pointerAddrU32(p: pointer): uint32 = cast[uint32](cast[uint](p))
proc volatileLoad(p: ptr uint32): uint32 =
  doAssert cast[uint](p) == 0x24B0004C'u
  events.add("power-read")
  powerControl
proc volatileStore(p: ptr uint32; value: uint32) =
  doAssert cast[uint](p) == 0x24B0004C'u
  events.add("power-write")
  powerControl = value
proc regRead(address: uint): uint32 =
  doAssert address == MACHW_TIMLO_REG
  events.add("time")
  macNow
proc chan_is_on_channel(p: pointer): bool {.cdecl.} = true
proc txl_frame_send_null_frame(sta: uint8; callback: pointer; arg: uint32): uint8 =
  raiseAssert "unexpected null-frame submission"
proc ps_enable_cfm(p: pointer; status: uint32) {.cdecl.} = discard
proc ps_disable_cfm(p: pointer; status: uint32) {.cdecl.} = discard
proc ps_enable_cfm_handle(p: pointer) =
  doAssert p == nil
  events.add("enable")
proc ps_disable_cfm_handle(p: pointer): uint32 =
  doAssert p == nil
  events.add("disable")
  0
proc td_pck_ps_ind(index, direction: uint8) =
  doAssert index == vif.vifIdx and direction == 1
  events.add("traffic")
proc ps_send_pspoll(p: pointer): uint8 =
  raiseAssert "unexpected PS-Poll submission"

{.emit: "#include <stdarg.h>\n#include <stdio.h>".}
proc logWrite(level: uint32; tag, file: cstring; line: cint; format: cstring)
    {.cdecl, varargs.} =
  doAssert level == 1 and tag == nil and file == cstring("ps.c")
  doAssert format != nil
  case line
  of 702:
    doAssert format == cstring("Enable DPSM on\r\n")
    doAssert ps.flags == 0 and powerControl == 0xA5000000'u32
  of 1005:
    doAssert format == cstring("rx frame: UAPSD CLR\r\n")
    doAssert vif.psLastTime == macNow and (vif.flags and 8) != 0
  else:
    raiseAssert "unexpected power-save log line"
  var output: array[96, char]
  var length: cint
  {.emit: ["va_list args; va_start(args, ", format, "); ", length,
    " = vsnprintf((char*)", output, ", sizeof(", output, "), ",
    format, ", args); va_end(args);"].}
  doAssert length > 0 and length < output.len.cint
  messages.add((line, $cast[cstring](addr output[0])))
  events.add("log:" & $line)
proc getLogFunc(slot: int): pointer =
  doAssert slot == 204
  inc lookups
  if logging: cast[pointer](logWrite) else: nil
proc setup() =
  ps = default(PsEnv)
  vif = Vif(vifIdx: 1, flags: 0xA5A5000E'u32, psLastTime: 42)
  vifEnv = default(VifEnv)
  logging = true
  lookups = 0
  powerControl = 0xA5000000'u32
  macNow = 0x87654321'u32
  events.setLen(0)
  messages.setLen(0)
'''


def source(*names: str) -> str:
    text = (FW / "power_save.nim").read_text()
    return PLATFORM + "\n".join(procedure(text, name) for name in names)


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_mode_logging_abi_and_state_order(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source("ps_set_mode") + r'''
for hasLogger in [false, true]:
  setup()
  logging = hasLogger
  ps.pendingCount = 5
  ps.psActive = 1
  ps_set_mode(2, 4)
  doAssert lookups == 1 and ps.mode == 4 and ps.flags == 1
  doAssert powerControl == 0xA5000004'u32
  doAssert ps.pendingCount == 0 and ps.psActive == 0
  if hasLogger:
    doAssert messages == @[(702.cint, "Enable DPSM on\r\n")]
    doAssert events == @["log:702", "power-read", "power-write", "enable"]
  else:
    doAssert messages.len == 0
    doAssert events == @["power-read", "power-write", "enable"]

for requested in [0'u8, 1]:
  setup()
  ps_set_mode(requested, 4)
  doAssert lookups == 0 and messages.len == 0 and ps.mode == 4
  doAssert ps.flags == 0
  if requested == 0:
    doAssert powerControl == 0xA5000000'u32
    doAssert events == @["power-read", "power-write", "disable"]
  else:
    doAssert powerControl == 0xA5000004'u32
    doAssert events == @["power-read", "power-write", "enable"]

setup()
ps.flags = 3
ps_set_mode(2, 4)
doAssert ps.flags == 0x13 and ps.deferredMode == 2 and ps.mode == 4
doAssert lookups == 0 and events.len == 0
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_rx_eosp_logging_abi_and_state_order(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source("psTxTidToAc", "ps_check_frame") + r'''
static:
  doAssert sizeof(MacHeader) == 24
  doAssert offsetOf(QosHeader, qosCtrl) == 24
  doAssert offsetOf(Qos4Header, qosCtrl) == 30

for fourAddress in [false, true]:
  for tid in 0'u8 .. 7'u8:
    for hasLogger in [false, true]:
      setup()
      logging = hasLogger
      ps.enabled = 1
      ps.psActive = 1
      let ac = [1'u8, 0, 0, 1, 2, 2, 3, 3][tid]
      vif.uapsdBitmap = 1'u8 shl ac
      var frame: Qos4Header
      frame.header.frameControl = if fourAddress: 0x0388 else: 0x0088
      if fourAddress:
        cast[ptr QosHeader](addr frame).qosCtrl = tid.uint16
        frame.qosCtrl = tid.uint16 or 0x10
      else:
        cast[ptr QosHeader](addr frame).qosCtrl = tid.uint16 or 0x10
        frame.qosCtrl = tid.uint16
      ps_check_frame(addr frame, 0, addr vif)
      doAssert lookups == 1 and vif.psLastTime == macNow
      doAssert vif.flags == 0xA5A50006'u32
      if hasLogger:
        doAssert messages == @[(1005.cint, "rx frame: UAPSD CLR\r\n")]
        doAssert events == @["time", "log:1005"]
      else:
        doAssert messages.len == 0 and events == @["time"]

# Adjacent paths do not emit an EOSP log or clear the U-APSD state.
for scenario in 0 .. 4:
  setup()
  ps.enabled = 1
  ps.psActive = 1
  vif.uapsdBitmap = 2
  var frame: QosHeader
  frame.header.frameControl = 0x0088
  frame.qosCtrl = 0x10
  var frameFlags = 0'u32
  case scenario
  of 0: ps.enabled = 0
  of 1: frameFlags = 0x200
  of 2: frame.qosCtrl = 0
  of 3: vif.uapsdBitmap = 0
  of 4: ps.psActive = 0
  else: discard
  ps_check_frame(addr frame, frameFlags, addr vif)
  doAssert lookups == 0 and messages.len == 0
  if scenario == 2:
    doAssert events == @["time"] and vif.psLastTime == macNow
  elif scenario in [3, 4]:
    doAssert events == @["traffic"] and vif.psLastTime == 42
  else:
    doAssert events.len == 0 and vif.psLastTime == 42
  doAssert vif.flags == (if scenario in [3, 4]: 0xA5A5000A'u32
                        else: 0xA5A5000E'u32)
''')
