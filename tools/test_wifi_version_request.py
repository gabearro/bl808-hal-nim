"""Check MM version confirmation routing and payload against mm_task.o."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


def source() -> str:
    layout = (FW / "layout_types.nim").read_text()
    tasks = (FW / "task_handlers.nim").read_text()
    version = "  MmVersionCfmPayload" + layout.split("  MmVersionCfmPayload", 1)[1].split("\n\n", 1)[0]
    return "type\n" + version + "\n" + r'''
type
  KeMsgHdr {.packed.} = object
    next: pointer
    id: uint16
    destId, srcId: uint8
    paramLen: uint32
  Request = object
    header: KeMsgHdr
    payload: array[1, uint8]
const
  MM_VERSION_CFM = 5'u16
  MmVersionCfmPayloadSize = sizeof(MmVersionCfmPayload).uint32
  KeMsgConsumed = 0
  MACHW_BASE = 0x24B00000'u
var
  request: Request
  confirmation: MmVersionCfmPayload
  allocations: seq[tuple[id: uint16, dest, src: uint8, size: uint32]]
  reads: seq[uint]
  sent: seq[MmVersionCfmPayload]
  phyVersionCalls: int
  failAllocation: bool
proc keMsgHdrFromPayload(p: pointer): ptr KeMsgHdr =
  cast[ptr KeMsgHdr](cast[uint](p) - sizeof(KeMsgHdr).uint)
proc ke_msg_alloc(id: uint16; destId, srcId: uint8; paramLen: uint32): pointer =
  allocations.add((id, destId, srcId, paramLen))
  if failAllocation: return nil
  confirmation = default(MmVersionCfmPayload)
  addr confirmation
proc ke_msg_send(p: pointer) =
  doAssert p == addr confirmation
  sent.add(confirmation)
proc regRead(address: uint): uint32 =
  reads.add(address)
  case address
  of MACHW_BASE + 4: 0x12345678'u32
  of MACHW_BASE + 8: 0x87654321'u32
  else: raiseAssert("unexpected register read")
proc phy_get_version(first, second: ptr uint32) =
  inc phyVersionCalls
  first[] = 0xABCDEF01'u32
  second[] = 0x10203040'u32
proc reset(src = 9'u8; dest = 3'u8) =
  request = Request(header: KeMsgHdr(srcId: src, destId: dest, paramLen: 0))
  allocations.setLen(0)
  reads.setLen(0)
  sent.setLen(0)
  phyVersionCalls = 0
  failAllocation = false
proc payload(): pointer = addr request.payload[0]
''' + procedure(tasks, "mm_version_req_handler")


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_version_request(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
reset(11, 4)
doAssert mm_version_req_handler(payload()) == KeMsgConsumed
doAssert allocations == @[(MM_VERSION_CFM, 11'u8, 4'u8, 24'u32)]
doAssert reads == @[MACHW_BASE + 4, MACHW_BASE + 8]
doAssert phyVersionCalls == 1 and sent.len == 1
doAssert sent[0] == MmVersionCfmPayload(
  fwVersion: 0x05040000'u32, hwVersion0: 0x12345678'u32,
  hwVersion1: 0x87654321'u32, phyVersion0: 0xABCDEF01'u32,
  phyVersion1: 0x10203040'u32, features: 0x001089DF'u32)

reset()
doAssert mm_version_req_handler(nil) == KeMsgConsumed
doAssert allocations.len == 0 and reads.len == 0
doAssert phyVersionCalls == 0 and sent.len == 0

reset()
failAllocation = true
doAssert mm_version_req_handler(payload()) == KeMsgConsumed
doAssert allocations == @[(MM_VERSION_CFM, 9'u8, 3'u8, 24'u32)]
doAssert reads.len == 0 and phyVersionCalls == 0 and sent.len == 0
''')
