"""Exercise the real power-save log calls and their surrounding state updates."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


PLATFORM = r'''
const
  TASK_API = 9'u8
  VIF_TYPE_STA = 0'u8
  MAX_VIFS = 2
  MACHW_TIMLO_REG = 0x24B00120'u
type
  PsEnv = object
    mode, flags, deferredMode, pendingCount, psActive, enabled: uint8
    statusFlags: uint32
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
  confirmVif: pointer
  mappedVif: ptr Vif
  logging: bool
  retireOnLog, retireOnPoll, retireOnTraffic, pollEnabled: bool
  disableUapsdOnLog, disablePsActiveOnLog: bool
  pollStatus: uint8
  rxVifEpochs: array[MAX_VIFS, uint32]
  txResetEpoch, psModeBuildSerial: uint32
  mmPsModeRequest: pointer
  lookups: int
  powerControl, macNow: uint32
  nullSendStatus: uint8
  finishNullInline, resetDuringNull: bool
  events: seq[string]
  messages: seq[tuple[line: cint, text: string]]

proc psEnvView(): ptr PsEnv = addr ps
proc vifMgmtEnvView(): ptr VifEnv = addr vifEnv
proc vifChannelAt(p: pointer): ptr Vif = cast[ptr Vif](p)
proc vifChannelForIdx(index: uint8): ptr Vif =
  if index == 1: mappedVif else: nil
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
proc ps_enable_cfm(p: pointer; status: uint32) {.cdecl.} = discard
proc ps_disable_cfm(p: pointer; status: uint32) {.cdecl.} = discard
proc txl_frame_send_null_frame(sta: uint8; callback: pointer; arg: uint32): uint8 =
  doAssert confirmVif != nil and sta == 3 and callback != nil
  doAssert arg == pointerAddrU32(confirmVif)
  events.add("null")
  if finishNullInline:
    doAssert ps.pendingCount != 0
    dec ps.pendingCount
    if ps.pendingCount == 0:
      events.add(if callback == cast[pointer](ps_disable_cfm): "disable" else: "enable")
  if resetDuringNull:
    inc txResetEpoch
    ps.pendingCount = 7
  nullSendStatus
proc ps_enable_cfm_handle(p: pointer) =
  doAssert p == confirmVif
  events.add("enable")
proc ps_disable_cfm_handle(p: pointer): uint32 =
  doAssert p == confirmVif
  events.add("disable")
  0
proc td_pck_ps_ind(index, direction: uint8) =
  doAssert index == vif.vifIdx and direction == 1
  events.add("traffic")
  if retireOnTraffic:
    inc rxVifEpochs[index]
    vif.flags = 0xDEADBEEF'u32
proc ps_send_pspoll(p: pointer): uint8 =
  doAssert pollEnabled and p == addr vif
  events.add("poll")
  if retireOnPoll:
    inc rxVifEpochs[vif.vifIdx]
    vif.flags = 0xDEADBEEF'u32
  pollStatus

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
    if retireOnLog:
      inc rxVifEpochs[vif.vifIdx]
      vif.flags = 0xDEADBEEF'u32
    if disableUapsdOnLog: vif.uapsdBitmap = 0
    if disablePsActiveOnLog: ps.psActive = 0
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
  confirmVif = nil
  mappedVif = addr vif
  logging = true
  retireOnLog = false
  disableUapsdOnLog = false
  disablePsActiveOnLog = false
  retireOnPoll = false
  retireOnTraffic = false
  pollEnabled = false
  pollStatus = 0
  rxVifEpochs = default(array[MAX_VIFS, uint32])
  txResetEpoch = 0
  lookups = 0
  powerControl = 0xA5000000'u32
  macNow = 0x87654321'u32
  nullSendStatus = 1
  finishNullInline = false
  resetDuringNull = false
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
def test_explicit_mode_replaces_dynamic_wake_state(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source("ps_set_mode") + r'''
for requested in 0'u8 .. 2'u8:
  setup()
  logging = false
  ps.enabled = 1
  ps.flags = 9 # Dynamic mode, awake.
  ps.statusFlags = 0xA000000C'u32 # Wake shadow and unrelated status bits.
  ps_set_mode(requested, 4)
  doAssert ps.flags == uint8(requested == 2)
  doAssert ps.statusFlags == 0xA0000004'u32
  doAssert (powerControl and 4) == (if requested == 0: 0'u32 else: 4'u32)

setup()
ps.flags = 3 # A dynamic wake is still in flight.
ps.statusFlags = 8
ps_set_mode(1, 4)
doAssert ps.flags == 0x13 and ps.statusFlags == 8 and ps.deferredMode == 1
doAssert events.len == 0
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_mode_completion_uses_last_sta_not_skipped_ap(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source("ps_set_mode") + r'''
for requested in [0'u8, 1]:
  for order in 0 .. 2:
    setup()
    var sta = Vif(vifType: VIF_TYPE_STA, state: 1, staIdx: 3,
                  uapsdBitmap: 1, psNullRetry: 7)
    var ap = Vif(vifType: 1, state: 1, staIdx: 9)
    case order
    of 0:
      vifEnv.activeList.first = addr ap
    of 1:
      vifEnv.activeList.first = addr sta
      sta.next = addr ap
      confirmVif = addr sta
    else:
      vifEnv.activeList.first = addr ap
      ap.next = addr sta
      confirmVif = addr sta
    ps_set_mode(requested, 4)
    doAssert ps.pendingCount == 0
    doAssert sta.psNullRetry == (if order == 0: 7'u8 else: 0'u8)
    doAssert ap.psNullRetry == 0 and ap.flags == 0
    doAssert events == (if order == 0:
      @["power-read", "power-write", (if requested == 0: "disable" else: "enable")]
      else:
      @["power-read", "power-write", "null", (if requested == 0: "disable" else: "enable")])
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_mode_null_send_result_controls_pending_confirmation(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source("ps_set_mode") + r'''
for requested in [0'u8, 1, 2]:
  for sendStatus in [0'u8, 1, 2]:
    setup()
    var sta = Vif(vifType: VIF_TYPE_STA, state: 1, staIdx: 3,
                  uapsdBitmap: 8, psNullRetry: 7)
    vifEnv.activeList.first = addr sta
    confirmVif = addr sta
    logging = false
    nullSendStatus = sendStatus
    ps_set_mode(requested, 4)
    doAssert sta.psNullRetry == 0 and ps.psActive == 1
    doAssert ps.pendingCount == (if sendStatus == 1: 0'u8 else: 1'u8)
    doAssert events == (if sendStatus == 1:
      @["power-read", "power-write", "null",
        (if requested == 0: "disable" else: "enable")]
      else: @["power-read", "power-write", "null"])
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_mode_inline_completion_and_replaced_submission(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source("ps_set_mode") + r'''
for requested in [0'u8, 2]:
  setup()
  logging = false
  vif.vifType = VIF_TYPE_STA
  vif.state = 1
  vif.staIdx = 3
  vifEnv.activeList.first = addr vif
  confirmVif = addr vif
  finishNullInline = true
  nullSendStatus = 0
  ps_set_mode(requested, 4)
  doAssert ps.pendingCount == 0
  doAssert events == @["power-read", "power-write", "null",
    (if requested == 0: "disable" else: "enable")]
  events.setLen(0)
  finishNullInline = false
  resetDuringNull = true
  nullSendStatus = 1
  ps_set_mode(requested, 4)
  doAssert ps.pendingCount == 7
  doAssert events == @["power-read", "power-write", "null"]
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

# The vendor aliases TIDs 8..15 to 0..7; reserved TIDs must not initiate
# a U-APSD state transition or read the MAC timer.
for fourAddress in [false, true]:
  for tid in 8'u16 .. 15'u16:
    setup()
    ps.enabled = 1
    ps.psActive = 1
    vif.uapsdBitmap = 15
    var frame: Qos4Header
    frame.header.frameControl = if fourAddress: 0x0388 else: 0x0088
    if fourAddress:
      frame.qosCtrl = tid or 0x10
    else:
      cast[ptr QosHeader](addr frame).qosCtrl = tid or 0x10
    ps_check_frame(addr frame, 0, addr vif)
    doAssert lookups == 0 and messages.len == 0 and events.len == 0
    doAssert vif.psLastTime == 42 and vif.flags == 0xA5A5000E'u32
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_rx_callbacks_do_not_write_retired_vif(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source("psTxTidToAc", "ps_check_frame") + r'''
setup()
ps.enabled = 1
ps.psActive = 1
vif.uapsdBitmap = 2
retireOnLog = true
var qos: QosHeader
qos.header.frameControl = 0x0088
qos.qosCtrl = 0x10
ps_check_frame(addr qos, 0, addr vif)
doAssert events == @["time", "log:1005"]
doAssert vif.flags == 0xDEADBEEF'u32

for change in 0 .. 1:
  setup()
  ps.enabled = 1
  ps.psActive = 1
  vif.uapsdBitmap = 2
  if change == 0: disableUapsdOnLog = true
  else: disablePsActiveOnLog = true
  ps_check_frame(addr qos, 0, addr vif)
  doAssert events == @["time", "log:1005"]
  doAssert vif.flags == 0xA5A5000E'u32

setup()
ps.enabled = 1
pollEnabled = true
pollStatus = 1
retireOnPoll = true
var protectedFrame: MacHeader
protectedFrame.frameControl = 0x2008
ps_check_frame(addr protectedFrame, 0, addr vif)
doAssert events == @["traffic", "poll"]
doAssert vif.flags == 0xDEADBEEF'u32

for protected in [false, true]:
  setup()
  ps.enabled = 1
  retireOnTraffic = true
  pollEnabled = true
  var frame: MacHeader
  frame.frameControl = if protected: 0x2008 else: 0x0008
  ps_check_frame(addr frame, 0, addr vif)
  doAssert events == @["traffic"]
  doAssert vif.flags == 0xDEADBEEF'u32

setup()
ps.enabled = 1
pollEnabled = true
pollStatus = 1
ps_check_frame(addr protectedFrame, 0, addr vif)
doAssert events == @["traffic", "poll"]
doAssert vif.flags == 0xA5A5000A'u32

setup()
ps.enabled = 1
ps_check_frame(nil, 0, addr vif)
ps_check_frame(addr protectedFrame, 0, nil)
doAssert events.len == 0 and vif.flags == 0xA5A5000E'u32
''')
