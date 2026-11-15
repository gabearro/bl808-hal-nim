"""Check the MM start wire layout and the real host-producer/handler contract."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


PLATFORM = r'''
const
  TASK_API = 9'u8
  KeMsgConsumed = 0.cint
type
  Header = object
    id: uint16
    destId, srcId: uint8
    paramLen: uint32
  Message = object
    header: Header
    payload: array[80, uint8]
  BlHw = object
    modParams: pointer
var
  message: Message
  hw: BlHw
  modParams: array[12, int32]
  ps: tuple[uapsdPeriod: uint32]
  mm: tuple[listenWindow: uint16]
  state: uint16
  allocationFails: bool
  events: seq[string]
  assertions: seq[tuple[condition, file: string, line: int]]
  confirmations: seq[tuple[id: uint16, destination, source: uint8]]
  channel: tuple[band, kind: uint8, primary, center1, center2: uint16, power: uint8]
  copiedConfig: array[64, uint8]
  configPointer: pointer
proc mmStartReqView(p: pointer): ptr MmStartReqPayload = cast[ptr MmStartReqPayload](p)
proc keMsgHdrFromPayload(p: pointer): ptr Header =
  doAssert p == addr message.payload[0]
  addr message.header
proc psEnvView(): ptr typeof(ps) = addr ps
proc mmEnvView(): ptr typeof(mm) = addr mm
proc ke_state_get(task: uint8): uint16 =
  doAssert task == message.header.destId
  events.add("state")
  state
proc ke_state_set(task: uint8; value: uint16) =
  doAssert task == message.header.destId and value == 2
  events.add("going-idle")
  state = value
proc assert_err(condition, file: cstring; line: int) =
  assertions.add(($condition, $file, line))
proc phy_init(p: pointer) =
  doAssert p == addr message.payload[0], "MM_START must pass the supplied PHY configuration"
  configPointer = p
  copyMem(addr copiedConfig[0], p, copiedConfig.len)
  events.add("phy")
proc phySetChannel(band, kind: uint8; primary, center1, center2: uint16; power: uint8) =
  channel = (band, kind, primary, center1, center2, power)
  events.add("channel")
proc tpc_update_tx_power(index: uint8) =
  doAssert index == 16
  events.add("power")
proc ke_msg_send_basic(id: uint16; destination, source: uint8) =
  let req = mmStartReqView(addr message.payload[0])
  doAssert ps.uapsdPeriod == req.uapsdTimeoutMs * 1000'u32
  doAssert mm.listenWindow == req.lpClockAccuracy
  confirmations.add((id, destination, source))
  events.add("confirm")
proc mm_active() = events.add("activate")
proc hal_machw_idle_req() = events.add("idle")
proc storeU32(p: pointer; offset: uint; value: uint32) =
  let bytes = cast[ptr UncheckedArray[uint8]](p)
  for i in 0 .. 3: bytes[offset + i.uint] = ((value shr (i * 8)) and 255).uint8
proc storeU16(p: pointer; offset: uint; value: uint16) =
  let bytes = cast[ptr UncheckedArray[uint8]](p)
  bytes[offset] = (value and 255).uint8
  bytes[offset + 1] = (value shr 8).uint8
proc loadPtr(p: pointer; offset: uint): pointer =
  doAssert p == (addr hw) and offset == BlHwModParamsOff
  hw.modParams
proc loadI32(p: pointer; offset: uint): int32 =
  doAssert p == (addr modParams[0]) and offset in [BlModParamsUapsdTimeoutOff, BlModParamsLpClkPpmOff]
  modParams[offset div 4]
proc blMsgZalloc(id: uint16; destination, source: uint8; length: uint16): pointer =
  doAssert id == MM_START_REQ and length == 72
  if allocationFails: return nil
  message = default(Message)
  message.header = Header(id: id, destId: destination, srcId: source, paramLen: length.uint32)
  addr message.payload[0]
proc blSendMsg(hardware: ptr BlHw; p: pointer; flags: uint32;
               expected: uint16; confirmation: pointer): cint
proc setup() =
  message = default(Message)
  message.header = Header(id: MM_START_REQ, destId: TASK_MM, srcId: DRV_TASK_ID, paramLen: 72)
  for i in 0 ..< 64: message.payload[i] = (i * 3 + 1).uint8
  hw.modParams = addr modParams[0]
  modParams = default(typeof(modParams))
  ps.uapsdPeriod = 0xABABABAB'u32
  mm.listenWindow = 0xCDCD
  state = MM_IDLE
  allocationFails = false
  events.setLen(0)
  assertions.setLen(0)
  confirmations.setLen(0)
  channel = default(typeof(channel))
  copiedConfig = default(typeof(copiedConfig))
  configPointer = nil
'''

HOST_SEND = r'''
proc blSendMsg(hardware: ptr BlHw; p: pointer; flags: uint32;
               expected: uint16; confirmation: pointer): cint =
  doAssert hardware == (addr hw) and p == (addr message.payload[0])
  doAssert flags == 1 and expected == MM_START_CFM and confirmation == nil
  mm_start_req_handler(p)
'''


def source() -> str:
    wifi = FW.parent
    wire = wifi / "msg_tx/layout"
    constants = "\n".join((wire / name).read_text() for name in [
        "task_ids.nim", "request_sizes.nim", "host_cmd.nim", "mm_me_payloads.nim", "message_ids.nim"
    ])
    constants += (wifi / "fw_constants/states.nim").read_text()
    layout = (FW / "layout_types.nim").read_text()
    payload = "type\n  MmStartReqPayload" + layout.split("  MmStartReqPayload", 1)[1].split(
        "\n\n  ", 1
    )[0] + "\nconst MmStartReqPayloadSize = sizeof(MmStartReqPayload).uint32\n"
    handler = procedure((FW / "task_handlers.nim").read_text(), "mm_start_req_handler")
    producer = procedure((wifi / "msg_tx/mm_control_parts/lifecycle.nim").read_text(), "bl_send_start")
    return constants + payload + PLATFORM + handler + HOST_SEND + producer


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_host_start_roundtrip(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for timeout in [0'i32, 1, 3000, 2147483647'i32]:
  for ppm in [0'i32, 20, 65535]:
    setup()
    modParams[BlModParamsUapsdTimeoutOff div 4] = timeout
    modParams[BlModParamsLpClkPpmOff div 4] = ppm
    doAssert bl_send_start(addr hw) == 0
    doAssert configPointer == addr message.payload[0]
    doAssert copiedConfig[0] == 1
    for i in 1 ..< copiedConfig.len: doAssert copiedConfig[i] == 0
    doAssert ps.uapsdPeriod == timeout.uint32 * 1000'u32
    doAssert mm.listenWindow == ppm.uint16
    doAssert confirmations == @[(MM_START_CFM, DRV_TASK_ID, TASK_MM)]
    doAssert channel == (0'u8, 0'u8, 2412'u16, 2412'u16, 0'u16, 0'u8)
    doAssert events == @["state", "phy", "channel", "power", "confirm", "activate", "idle", "going-idle"]
    doAssert state == MM_GOING_TO_IDLE and assertions.len == 0

setup()
hw.modParams = nil
doAssert bl_send_start(addr hw) == 0
doAssert ps.uapsdPeriod == 0 and mm.listenWindow == 0

setup()
allocationFails = true
doAssert bl_send_start(addr hw) == -Enomem and events.len == 0
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_wire_layout_and_raw_start_fields(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
static:
  doAssert sizeof(MmStartReqPayload) == SizeMmStartReq.int
  doAssert offsetOf(MmStartReqPayload, phyConfig) == MmStartPhyCfgOff.int
  doAssert offsetOf(MmStartReqPayload, uapsdTimeoutMs) == MmStartUapsdTimeoutOff.int
  doAssert offsetOf(MmStartReqPayload, lpClockAccuracy) == MmStartLpClkAccuracyOff.int

for timeout in [0'u32, 1, 3000, 4294968'u32, 0xFFFFFFFF'u32]:
  setup()
  message.header.srcId = 17
  let p = addr message.payload[0]
  storeU32(p, 64, timeout)
  storeU16(p, 68, 0xFEDC)
  var expected: array[64, uint8]
  copyMem(addr expected[0], p, 64)
  doAssert mm_start_req_handler(p) == KeMsgConsumed
  doAssert copiedConfig == expected
  doAssert ps.uapsdPeriod == timeout * 1000'u32 and mm.listenWindow == 0xFEDC
  doAssert confirmations == @[(MM_START_CFM, 17'u8, TASK_MM)]
  doAssert channel == (0'u8, 0'u8, 2412'u16, 2412'u16, 0'u16, 0'u8)
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_truncated_start_has_no_side_effects(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for length in [0'u32, 1, 8, 9, 63, 64, 68, 69, 70, 71]:
  setup()
  message.header.paramLen = length
  doAssert mm_start_req_handler(addr message.payload[0]) == KeMsgConsumed
  doAssert events.len == 0 and assertions.len == 0 and confirmations.len == 0
  doAssert ps.uapsdPeriod == 0xABABABAB'u32 and mm.listenWindow == 0xCDCD
setup()
doAssert mm_start_req_handler(nil) == KeMsgConsumed
doAssert events.len == 0
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_start_rejects_nonidle_state(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for previous in [1'u16, 2, 255]:
  setup()
  state = previous
  doAssert mm_start_req_handler(addr message.payload[0]) == KeMsgConsumed
  doAssert events == @["state"] and confirmations.len == 0
  doAssert state == previous and ps.uapsdPeriod == 0xABABABAB'u32
  doAssert assertions == @[("ke_state_get(dest_id) == MM_IDLE", "mm_task.c", 308)]
''')
