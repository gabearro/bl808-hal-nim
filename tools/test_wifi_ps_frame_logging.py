"""Exercise the real power-save log calls and their surrounding state updates."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program
from test_wifi_ps_table import ps_source as machine_source


PLATFORM = r'''
# The platform of ps_check_frame (the transition procs run on the
# test_wifi_ps_table.py harness, machine_source).
const
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
  mappedVif: ptr Vif
  logging: bool
  pollEnabled: bool
  pollStatus: uint8
  lookups: int
  macNow: uint32
  events: seq[string]
  messages: seq[tuple[line: cint, text: string]]

proc psEnvView(): ptr PsEnv = addr ps
proc vifChannelAt(p: pointer): ptr Vif = cast[ptr Vif](p)
proc vifChannelForIdx(index: uint8): ptr Vif =
  if index == 1: mappedVif else: nil
proc macDataFrameAt(p: pointer): ptr MacHeader = cast[ptr MacHeader](p)
proc macQosDataFrameAt(p: pointer): ptr QosHeader = cast[ptr QosHeader](p)
proc macQos4AddrFrameAt(p: pointer): ptr Qos4Header = cast[ptr Qos4Header](p)
proc regRead(address: uint): uint32 =
  doAssert address == MACHW_TIMLO_REG
  events.add("time")
  macNow
proc td_pck_ps_ind(index, direction: uint8) =
  doAssert index == vif.vifIdx and direction == 1
  events.add("traffic")
proc ps_send_pspoll(p: pointer): uint8 =
  doAssert pollEnabled and p == addr vif
  events.add("poll")
  pollStatus

{.emit: "#include <stdarg.h>\n#include <stdio.h>".}
proc logWrite(level: uint32; tag, file: cstring; line: cint; format: cstring)
    {.cdecl, varargs.} =
  doAssert level == 1 and tag == nil and file == cstring("ps.c")
  doAssert format != nil
  case line
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
  mappedVif = addr vif
  logging = true
  pollEnabled = false
  pollStatus = 0
  lookups = 0
  macNow = 0x87654321'u32
  events.setLen(0)
  messages.setLen(0)
'''


def source(*names: str) -> str:
    text = (FW / "power_save.nim").read_text()
    return PLATFORM + "\n".join(procedure(text, name) for name in names)


MODE_LOGGER = r'''
{.emit: "#include <stdarg.h>\n#include <stdio.h>".}
var logged: seq[tuple[line: cint, text: string, pm: uint32, flags: uint8]]
proc modeLog(level: uint32; tag, file: cstring; line: cint; format: cstring)
    {.cdecl, varargs.} =
  doAssert level == 1 and tag == nil and file == cstring("ps.c")
  doAssert line == 702 and format == cstring("Enable DPSM on\r\n")
  var output: array[96, char]
  var length: cint
  {.emit: ["va_list args; va_start(args, ", format, "); ", length,
    " = vsnprintf((char*)", output, ", sizeof(", output, "), ",
    format, ", args); va_end(args);"].}
  doAssert length > 0 and length < output.len.cint
  logged.add((line, $cast[cstring](addr output[0]), pmRegister, ps.flags))
'''


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_mode_logging_abi_and_state_order(tmp_path: Path, mode: str) -> None:
    """ps_set_mode logs dynamic PS at line 702 before it writes the flags and
    the PM bit, stores the requester at ps_env+1 and resets ps_env+29."""
    run_program(tmp_path, mode, machine_source() + MODE_LOGGER + r'''
for hasLogger in [false, true]:
  for requested in [0'u8, 1, 2]:
    setup()
    logged.setLen(0)
    if hasLogger: logFunc = cast[pointer](modeLog)
    ps.psActive = 1
    vifs[0].uapsdBitmap = 0
    nullSendStatus = 1
    ps_set_mode(requested, 4)
    doAssert ps.mode == 4 and ps.psActive == 0
    doAssert ps.flags == uint8(requested == 2) and ps.pendingCount == 0
    doAssert ((pmRegister and 4) != 0) == (requested != 0)
    doAssert ps.enabled == uint8(requested != 0) and psOwn.kind == psIdle
    if hasLogger and requested == 2:
      doAssert logged == @[(702.cint, "Enable DPSM on\r\n", 0'u32, 0'u8)]
    else:
      doAssert logged.len == 0
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_explicit_mode_replaces_dynamic_wake_state(tmp_path: Path, mode: str) -> None:
    """An explicit mode replaces DPSM's awake state. statusFlags bit 3 then
    mirrors PS's PM choice (set while it is clear: mode 0); ps.o clears it for
    every mode, and PS off does not let bl_sleep_schedule nap either way."""
    run_program(tmp_path, mode, machine_source() + r'''
for requested in 0'u8 .. 2'u8:
  enter(2)
  discard ps_traffic_status_update(0, 4)
  doAssert ps.flags == 9 and (ps.statusFlags and 8) != 0
  ps.statusFlags = ps.statusFlags or 0xA0000004'u32  # unrelated status bits
  ps_set_mode(requested, 4)
  ackAll()
  doAssert ps.flags == uint8(requested == 2)
  doAssert ps.statusFlags == (if requested == 0: 0xA000000C'u32 else: 0xA0000004'u32)
  doAssert ((pmRegister and 4) != 0) == (requested != 0)
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_mode_completion_uses_last_sta_not_skipped_ap(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, machine_source() + r'''
for requested in [0'u8, 1]:
  for order in 0 .. 2:
    setup()
    vifs[0] = Vif(vifIdx: 0, vifType: VIF_TYPE_STA, state: 1, staIdx: 3,
                  uapsdBitmap: 1, psNullRetry: 7, keyPsState: 9)
    vifs[1] = Vif(vifIdx: 1, vifType: 1, state: 1, staIdx: 9)
    case order
    of 0: vifEnv.activeList.first = addr vifs[1]
    of 1:
      vifEnv.activeList.first = addr vifs[0]
      vifs[0].next = addr vifs[1]
    else:
      vifEnv.activeList.first = addr vifs[1]
      vifs[1].next = addr vifs[0]
    ps_set_mode(requested, 4)
    ackAll()
    doAssert psOwn.kind == psIdle and ps.pendingCount == 0
    doAssert vifs[0].psNullRetry == (if order == 0: 7'u8 else: 0'u8)
    doAssert vifs[1].psNullRetry == 0 and vifs[1].flags == 0
    doAssert frames.len == (if order == 0: 0 else: 1)
    doAssert vifs[0].keyPsState == (if order == 0: 9'u32 else: requested.uint32)
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_mode_null_send_result_controls_pending_confirmation(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, machine_source() + r'''
for requested in [0'u8, 1, 2]:
  for sendStatus in [0'u8, 1]:
    setup()
    vifs[0].uapsdBitmap = 8
    vifs[0].psNullRetry = 7
    nullSendStatus = sendStatus
    ps_set_mode(requested, 4)
    doAssert vifs[0].psNullRetry == 0 and ps.psActive == 1 and frames.len == 1
    # txl_frame_send_null_frame returns 1 for a refused frame, which gets no
    # confirmation, and 0 for a pushed one.
    doAssert ps.pendingCount == (if sendStatus == 1: 0'u8 else: 1'u8)
    doAssert (psOwn.kind == psIdle) == (sendStatus == 1)
    nullSendStatus = 0
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_mode_inline_completion_finishes_once(tmp_path: Path, mode: str) -> None:
    """A frame confirmed while the walk still sends only counts: the walk's
    held count keeps the transition live until it is done sending."""
    run_program(tmp_path, mode, machine_source() + r'''
for requested in [0'u8, 2]:
  for count in [1, 2]:
    setup(count)
    let p = request(requested, fromMe = false)
    proc inline() =
      doAssert psOwn.kind == psExplicit and ps.pendingCount >= 2
      deliver(frames.len - 1, TxAck)
      doAssert psOwn.kind == psExplicit and answers.len == 0
      onSend = inline
    onSend = inline
    doAssert dispatch(p) == KeMsgNoFree
    onSend = nil
    doAssert psOwn.kind == psIdle and ps.pendingCount == 0 and frames.len == count
    doAssert answers.len == 1 and answers[0].message == p
    freeAnswers()
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
def test_rx_poll_and_missing_inputs(tmp_path: Path, mode: str) -> None:
    """A protected frame on a static-PS station polls; a queued PS-Poll keeps
    vif[4] bit 2, a refused one clears it. The logger, the traffic counter and
    the poll cannot retire the VIF, so nothing is checked again after them."""
    run_program(tmp_path, mode, source("psTxTidToAc", "ps_check_frame") + r'''
var protectedFrame: MacHeader
protectedFrame.frameControl = 0x2008
for status in [0'u8, 1]:
  setup()
  ps.enabled = 1
  pollEnabled = true
  pollStatus = status
  ps_check_frame(addr protectedFrame, 0, addr vif)
  doAssert events == @["traffic", "poll"]
  doAssert vif.flags == (if status == 0: 0xA5A5000E'u32 else: 0xA5A5000A'u32)

setup()
ps.enabled = 1
ps_check_frame(nil, 0, addr vif)
ps_check_frame(addr protectedFrame, 0, nil)
doAssert events.len == 0 and vif.flags == 0xA5A5000E'u32
''')
