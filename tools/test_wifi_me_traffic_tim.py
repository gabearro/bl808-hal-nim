"""Check ME traffic flag changes, MM TIM requests, and reply routing."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


def source() -> str:
    layout = (FW / "layout_types.nim").read_text()
    tasks = (FW / "task_handlers.nim").read_text()
    types = "type\n"
    for name in ["MeTrafficIndReqPayload", "MmTimUpdatePayload"]:
        types += "  " + name + layout.split("  " + name, 1)[1].split("\n\n", 1)[0] + "\n"
    return types + r'''
type
  KeMsgHdr {.packed.} = object
    next: pointer
    id: uint16
    destId, srcId: uint8
    paramLen: uint32
  Request = object
    header: KeMsgHdr
    payload: MeTrafficIndReqPayload
  Station = object
    trafficFlags, psState: uint8
    aid: uint16
    instNbr: uint8
const
  MM_TIM_UPDATE_REQ = 47'u16
  ME_TRAFFIC_IND_CFM = 0xC0B'u16
  TASK_MM = 0'u8
  TASK_ME = 3'u8
  STA_INFO_TAB_ENTRIES = 7
  MeTrafficIndReqPayloadSize = sizeof(MeTrafficIndReqPayload).uint32
  MmTimUpdatePayloadSize = sizeof(MmTimUpdatePayload).uint32
  KeMsgConsumed = 0
var
  request: Request
  stations: array[STA_INFO_TAB_ENTRIES, Station]
  tim: MmTimUpdatePayload
  allocations: seq[tuple[id: uint16, dest, src: uint8, size: uint32]]
  timMessages: seq[MmTimUpdatePayload]
  basicReplies: seq[tuple[id: uint16, dest, src: uint8]]
  failAllocation: bool
  mutateOnSend: bool
proc keMsgHdrFromPayload(p: pointer): ptr KeMsgHdr =
  cast[ptr KeMsgHdr](cast[uint](p) - sizeof(KeMsgHdr).uint)
proc meTrafficIndReqView(p: pointer): ptr MeTrafficIndReqPayload =
  cast[ptr MeTrafficIndReqPayload](p)
proc staInfoForIdx(index: uint8): ptr Station =
  doAssert index < STA_INFO_TAB_ENTRIES.uint8
  addr stations[index]
proc ke_msg_alloc(id: uint16; destId, srcId: uint8; paramLen: uint32): pointer =
  allocations.add((id, destId, srcId, paramLen))
  if failAllocation: return nil
  tim = default(MmTimUpdatePayload)
  addr tim
proc ke_msg_send(p: pointer) =
  doAssert p == addr tim
  timMessages.add(tim)
  if mutateOnSend:
    request.header.srcId = 2
    request.header.destId = 5
proc ke_msg_send_basic(id: uint16; destId, srcId: uint8) =
  basicReplies.add((id, destId, srcId))
proc reset(txAvail, uapsd: uint8; psState = 15'u8; flags = 0xA0'u8;
           src = 9'u8; dest = 3'u8; size = 3'u32; staIdx = 1'u8) =
  request = Request(header: KeMsgHdr(srcId: src, destId: dest, paramLen: size),
                    payload: MeTrafficIndReqPayload(
                      staIdx: staIdx, txAvail: txAvail, uapsd: uapsd))
  stations = default(typeof(stations))
  stations[1] = Station(trafficFlags: flags, psState: psState,
                        aid: 0x123'u16, instNbr: 2)
  allocations.setLen(0)
  timMessages.setLen(0)
  basicReplies.setLen(0)
  failAllocation = false
  mutateOnSend = false
proc payload(): pointer = addr request.payload
''' + procedure(tasks, "me_traffic_ind_req_handler")


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_me_traffic_tim(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for txAvail in [0'u8, 1'u8, 255'u8]:
  for uapsd in [0'u8, 1'u8, 255'u8]:
    for sleeping in [false, true]:
      let initial = if uapsd == 0: 0xA5'u8 else: 0xA0'u8
      reset(txAvail, uapsd, psState = (if sleeping: 15'u8 else: 0'u8),
            flags = initial, src = 11, dest = 4)
      doAssert me_traffic_ind_req_handler(payload()) == KeMsgConsumed
      let mask = if txAvail != 0: 4'u8 else: 1'u8
      let expected = if uapsd != 0: initial or mask else: initial and not mask
      doAssert stations[1].trafficFlags == expected
      doAssert basicReplies == @[(ME_TRAFFIC_IND_CFM, 11'u8, 4'u8)]
      if sleeping:
        doAssert allocations == @[(MM_TIM_UPDATE_REQ, TASK_MM, TASK_ME, 4'u32)]
        doAssert timMessages == @[MmTimUpdatePayload(
          aid: 0x123'u16, setFlag: uapsd, vifIdx: 2)]
      else:
        doAssert allocations.len == 0 and timMessages.len == 0

reset(1, 1)
failAllocation = true
doAssert me_traffic_ind_req_handler(payload()) == KeMsgConsumed
doAssert allocations == @[(MM_TIM_UPDATE_REQ, TASK_MM, TASK_ME, 4'u32)]
doAssert timMessages.len == 0
doAssert basicReplies == @[(ME_TRAFFIC_IND_CFM, 9'u8, 3'u8)]

reset(1, 1)
mutateOnSend = true
doAssert me_traffic_ind_req_handler(payload()) == KeMsgConsumed
doAssert basicReplies == @[(ME_TRAFFIC_IND_CFM, 9'u8, 3'u8)]

reset(1, 1)
doAssert me_traffic_ind_req_handler(nil) == KeMsgConsumed
doAssert allocations.len == 0 and basicReplies.len == 0
for shortSize in 0'u32 .. 2'u32:
  reset(1, 1, size = shortSize)
  doAssert me_traffic_ind_req_handler(payload()) == KeMsgConsumed
  doAssert stations[1].trafficFlags == 0xA0
  doAssert allocations.len == 0 and basicReplies.len == 0
reset(1, 1, staIdx = 7)
doAssert me_traffic_ind_req_handler(payload()) == KeMsgConsumed
doAssert allocations.len == 0 and basicReplies.len == 0
''')
