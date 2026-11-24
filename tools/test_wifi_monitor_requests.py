"""Check monitor request confirmations and PHY calls against mm_task.o."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


def source() -> str:
    layout = (FW / "layout_types.nim").read_text()
    tasks = (FW / "task_handlers.nim").read_text()
    types = "type\n"
    for name in ["MmMonitorReqPayload", "MmMonitorCfmPayload"]:
        types += "  " + name + layout.split("  " + name, 1)[1].split("\n\n", 1)[0] + "\n"
    platform = r'''
type
  KeMsgHdr {.packed.} = object
    next: pointer
    id: uint16
    destId, srcId: uint8
    paramLen: uint32
  Request = object
    header: KeMsgHdr
    payload: MmMonitorReqPayload
  ChannelCall = tuple[band, chanType: uint8, primary, center1, center2: uint16,
                      power: uint8]
const
  MM_MONITOR_CFM = 71'u16
  MM_MONITOR_CHANNEL_CFM = 73'u16
  MmMonitorReqPayloadSize = sizeof(MmMonitorReqPayload).uint32
  MmMonitorCfmPayloadSize = sizeof(MmMonitorCfmPayload).uint32
  KeMsgConsumed = 0
var
  request: Request
  confirmation: MmMonitorCfmPayload
  allocations: seq[tuple[id: uint16, dest, src: uint8, size: uint32]]
  channels: seq[ChannelCall]
  sent: seq[MmMonitorCfmPayload]
  phyInitCalls, memsetCalls, activeCalls: int
  failAllocation: bool
  mutateOnAllocation: bool
proc keMsgHdrFromPayload(p: pointer): ptr KeMsgHdr =
  cast[ptr KeMsgHdr](cast[uint](p) - sizeof(KeMsgHdr).uint)
proc mmMonitorReqView(p: pointer): ptr MmMonitorReqPayload =
  cast[ptr MmMonitorReqPayload](p)
proc ke_msg_alloc(id: uint16; destId, srcId: uint8; paramLen: uint32): pointer =
  allocations.add((id, destId, srcId, paramLen))
  if mutateOnAllocation: request.payload.channel = 0
  if failAllocation: return nil
  confirmation = default(MmMonitorCfmPayload)
  addr confirmation
proc ke_msg_send(p: pointer) =
  doAssert p == addr confirmation
  sent.add(confirmation)
proc c_memset(p: pointer; value: cint; count: csize_t): pointer =
  doAssert value == 0 and count == 64
  inc memsetCalls
  zeroMem(p, count.int)
  p
proc phy_init(p: pointer) =
  inc phyInitCalls
  let bytes = cast[ptr UncheckedArray[uint8]](p)
  for index in 0 ..< 64: doAssert bytes[index] == 0
proc phySetChannel(band, chanType: uint8; primary, center1, center2: uint16;
                   power: uint8) =
  channels.add((band, chanType, primary, center1, center2, power))
proc mm_active() = inc activeCalls
proc reset(channel: uint32; src = 9'u8; dest = 3'u8; size = 4'u32) =
  request = Request(header: KeMsgHdr(srcId: src, destId: dest, paramLen: size),
                    payload: MmMonitorReqPayload(channel: channel))
  allocations.setLen(0)
  channels.setLen(0)
  sent.setLen(0)
  phyInitCalls = 0
  memsetCalls = 0
  activeCalls = 0
  failAllocation = false
  mutateOnAllocation = false
proc payload(): pointer = addr request.payload
proc checkCfm(id: uint16; channel: uint32; src, dest: uint8) =
  doAssert allocations == @[(id, src, dest, 40'u32)]
  doAssert sent.len == 1
  let cfm = sent[0]
  doAssert cfm.status == 0 and cfm.channel == channel and cfm.debugReserved == 0
  doAssert [cfm.debug1, cfm.debug2, cfm.debug3, cfm.debug4,
            cfm.debug5, cfm.debug6, cfm.debug7] ==
           [0x11111111'u32, 0x22222222'u32, 0x33333333'u32,
            0x44444444'u32, 0x55555555'u32, 0x66666666'u32, 0x77777777'u32]
'''
    return (
        types + platform
        + procedure(tasks, "mm_monitor_enable_req_handler")
        + procedure(tasks, "mm_monitor_channel_req_handler")
    )


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_monitor_requests(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
reset(0xABCD0965'u32, 11, 4)
doAssert mm_monitor_enable_req_handler(payload()) == KeMsgConsumed
checkCfm(MM_MONITOR_CFM, 0xABCD0965'u32, 11, 4)
doAssert phyInitCalls == 1 and memsetCalls == 1 and activeCalls == 1
doAssert channels == @[(0'u8, 0'u8, 2437'u16, 2437'u16, 0'u16, 0'u8)]

reset(0xABCD0965'u32, 13, 5)
doAssert mm_monitor_channel_req_handler(payload()) == KeMsgConsumed
checkCfm(MM_MONITOR_CHANNEL_CFM, 0xABCD0965'u32, 13, 5)
doAssert phyInitCalls == 0 and memsetCalls == 0 and activeCalls == 0
doAssert channels == @[(0'u8, 0'u8, 2405'u16, 2405'u16, 0'u16, 0'u8)]

for shortSize in 0'u32 .. 3'u32:
  reset(0xABCD0965'u32, size = shortSize)
  doAssert mm_monitor_enable_req_handler(payload()) == KeMsgConsumed
  doAssert mm_monitor_channel_req_handler(payload()) == KeMsgConsumed
  doAssert allocations.len == 0 and sent.len == 0 and channels.len == 0
  doAssert phyInitCalls == 0 and activeCalls == 0

reset(0)
doAssert mm_monitor_enable_req_handler(nil) == KeMsgConsumed
doAssert mm_monitor_channel_req_handler(nil) == KeMsgConsumed
doAssert allocations.len == 0

for enable in [false, true]:
  reset(0xABCD0965'u32)
  failAllocation = true
  if enable:
    doAssert mm_monitor_enable_req_handler(payload()) == KeMsgConsumed
  else:
    doAssert mm_monitor_channel_req_handler(payload()) == KeMsgConsumed
  doAssert allocations.len == 1 and sent.len == 0
  doAssert channels.len == 0 and phyInitCalls == 0 and activeCalls == 0

reset(0xABCD0965'u32)
mutateOnAllocation = true
doAssert mm_monitor_channel_req_handler(payload()) == KeMsgConsumed
checkCfm(MM_MONITOR_CHANNEL_CFM, 0xABCD0965'u32, 9, 3)
doAssert channels[0].primary == 2405
''')
