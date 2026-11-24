"""Pair the owned DHCP host completion with its programmed inline rates."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_host_tx_status import CHECKS, HOST_TABLE, PLATFORM, TX
from test_wifi_message_allocation import run_program

PARSER = (TX.parent / "dhcp_flow_trace.nim").read_text()

TRACE_PLATFORM = r'''
type
  HostIpcMock = object
  Hardware = object
    head, chainedThd: pointer
    magic, retryLimitControl, ackPolicyControl, confirmStatus, status: uint32
  Rate = object
    magic, rateWord, retryRateControl0, retryRateControl1, retryRateControl2, policyWord: uint32
    txPower: int32
    retryTxPowerControl0, retryTxPowerControl1, retryTxPowerControl2: uint32
  HeaderThd = object
    magic, payloadStart, payloadEnd: uint32
  Desc = object
    cfmDst, hwDesc: pointer
    aggDescPtr: Hardware
    aggDescStorage: array[4, uint32]
    rate: Rate
    headerLen: uint32
    headerThd: HeaderThd
    macHeader: array[26, uint8]
  Wrapper = object
    txDesc: Desc
var
  hostIpc: HostIpcMock
  irqEnabled = true
  lockedWrapper: pointer
  wrapper: Wrapper
  nimFwDbgDhcpCfm, nimFwDbgDhcpCfmStatus, nimFwDbgDhcpCfmRingIdx: uint32
  nimFwDbgDhcpCfmStatusLog, nimFwDbgDhcpCfmMetaLog: array[8, uint32]
  nimFwDbgDhcpCfmAckOk, nimFwDbgDhcpCfmAckFail, nimFwDbgDhcpCfmOk, nimFwDbgDhcpCfmFail: uint32
proc ipcHostIrqSave(mock: HostIpcMock): bool =
  result = irqEnabled
  irqEnabled = false
proc ipcHostIrqRestore(mock: HostIpcMock; saved: bool) = irqEnabled = saved
proc ipcHostTxCompletionWrapper(mock: HostIpcMock; hostId: pointer): pointer =
  doAssert not irqEnabled and hostId == addr payload
  lockedWrapper
template byteView(p: pointer): ptr UncheckedArray[uint8] = cast[ptr UncheckedArray[uint8]](p)
template ipcHostTxWrapperAt(p: pointer): ptr Wrapper = cast[ptr Wrapper](p)
template hostTxHwDescAt(p: pointer): ptr Hardware = cast[ptr Hardware](p)
template hostTxHeadThd(hw: ptr Hardware): pointer = hw.head
template hostTxInlineBufferedLink(d: ptr Desc): ptr Desc = d
template hostTxRateTemplate(d: ptr Desc): ptr Rate = addr d.rate
proc pointerAddrU32(p: pointer): uint32 = cast[uint32](cast[uint](p))
'''


TRACE_CHECKS = r'''
proc startDhcp(): ptr TxHdrView =
  result = startPacket(1, 0xFF)
  result.len = 48 + 42
  let ip = addr payload[62]
  let bytes = byteView(ip)
  bytes[0] = 0x45
  bytes[3] = 28
  bytes[9] = 17
  bytes[21] = 68
  bytes[23] = 67
  bytes[25] = 8
  wrapper.txDesc.cfmDst = addr result.status
  wrapper.txDesc.hwDesc = addr wrapper.txDesc.aggDescPtr
  wrapper.txDesc.aggDescPtr = Hardware(head: addr wrapper.txDesc.aggDescStorage[0],
    chainedThd: addr wrapper.txDesc.rate, magic: 0xCAFEBABE'u32, retryLimitControl: 0x003F0000,
    ackPolicyControl: 0x2200, confirmStatus: acked and not 1'u32,
    status: pointerAddrU32(addr wrapper.txDesc.headerThd))
  wrapper.txDesc.rate = Rate(magic: 0xBADCAB1E'u32, rateWord: 0x80001207'u32,
    retryRateControl0: 0x80001007'u32, retryRateControl1: 0x80001004'u32,
    retryRateControl2: 0x80000400'u32, policyWord: 0x0704)
  wrapper.txDesc.headerLen = 26
  let start = pointerAddrU32(addr wrapper.txDesc.macHeader[0])
  wrapper.txDesc.headerThd =
    HeaderThd(magic: 0xCAFEFADE'u32, payloadStart: start, payloadEnd: start + 25)
  wrapper.txDesc.macHeader = default(typeof(wrapper.txDesc.macHeader))
  wrapper.txDesc.macHeader[0] = 0x88
  wrapper.txDesc.macHeader[1] = 0x41
  wrapper.txDesc.macHeader[22] = 0x30
  wrapper.txDesc.macHeader[23] = 0x12
  wrapper.txDesc.macHeader[24] = 5
  lockedWrapper = addr wrapper

let hdr = startDhcp()
hdr.status = failed
wrapper.txDesc.aggDescPtr.confirmStatus = failed and not 1'u32
doAssert bl_tx_cfm(nil, addr payload) == 0 and hdr.repush == 1
doAssert nimFwDbgDhcpCfmRingIdx == 1 and nimFwDbgDhcpCfmStatusLog[0] == failed
doAssert nimFwDbgDhcpCfmMetaLog[0] shr 24 == 0 and (nimFwDbgDhcpCfmMetaLog[0] and 0x20000) != 0
doAssert dhcpCfmAirLog[0] == 0x80051230'u32
doAssert dhcpCfmPolicyLog[0] == [0x80001207'u32, 0x80001007'u32, 0x80001004'u32,
  0x80000400'u32, 0x0704, 0x003F0000, 0x2200, 0x80010700'u32]

station.pendingList = nil
wrapper.txDesc.rate.rateWord = 0x80000400'u32
wrapper.txDesc.macHeader[22] = 0x40
wrapper.txDesc.aggDescPtr.confirmStatus = acked and not 1'u32
hdr.status = acked
doAssert bl_tx_cfm(nil, addr payload) == 1
doAssert nimFwDbgDhcpCfmRingIdx == 2 and nimFwDbgDhcpCfmStatusLog[1] == acked
doAssert nimFwDbgDhcpCfmMetaLog[1] shr 24 == 1 and (nimFwDbgDhcpCfmMetaLog[1] and 0x20000) != 0
doAssert dhcpCfmPolicyLog[1][0] == 0x80000400'u32 and dhcpCfmPolicyLog[0][0] == 0x80001207'u32
doAssert dhcpCfmAirLog[1] == 0x80051240'u32 and dhcpCfmAirLog[0] == 0x80051230'u32

let powerHdr = startDhcp()
wrapper.txDesc.rate.txPower = -2
wrapper.txDesc.rate.retryTxPowerControl0 = 0x02
wrapper.txDesc.rate.retryTxPowerControl1 = 0x03
wrapper.txDesc.rate.retryTxPowerControl2 = 0x04
var policyWords: array[8, uint32]
var powerWords: array[4, uint32]
doAssert bl808_wifi_copy_completed_tx_policy(addr wrapper, addr powerHdr.status,
  addr policyWords, addr powerWords)
doAssert powerWords == [0xFFFFFFFE'u32, 2, 3, 4]

for invalid in 0 .. 2:
  let next = startDhcp()
  next.status = acked
  case invalid
  of 0: next.status = softwareDropped
  of 1: wrapper.txDesc.cfmDst = nil
  else: wrapper.txDesc.aggDescPtr.chainedThd = nil
  nimFwDbgDhcpCfmRingIdx = 8 + invalid.uint32
  discard bl_tx_cfm(nil, addr payload)
  doAssert nimFwDbgDhcpCfmRingIdx == 9 + invalid.uint32
  doAssert (nimFwDbgDhcpCfmMetaLog[invalid] and 0x20000) == 0
  doAssert dhcpCfmPolicyLog[invalid] == default(array[8, uint32])
  doAssert dhcpCfmAirLog[invalid] == 0
  doAssert irqEnabled

for invalid in 0 .. 7:
  let next = startDhcp()
  next.status = acked
  case invalid
  of 0: inc wrapper.txDesc.headerThd.payloadStart
  of 1: dec wrapper.txDesc.headerThd.payloadEnd
  of 2: wrapper.txDesc.macHeader[0] = 0x08
  of 3: wrapper.txDesc.macHeader[1] = 0x42
  of 4: inc wrapper.txDesc.macHeader[22]
  of 5: wrapper.txDesc.macHeader[24] = 0x80
  of 6: inc wrapper.txDesc.aggDescPtr.status
  else: wrapper.txDesc.aggDescPtr.confirmStatus = failed and not 1'u32
  let ring = nimFwDbgDhcpCfmRingIdx and 7
  discard bl_tx_cfm(nil, addr payload)
  doAssert (nimFwDbgDhcpCfmMetaLog[ring] and 0x20000) != 0
  doAssert dhcpCfmAirLog[ring] == 0

for invalid in 0 .. 3:
  let next = startDhcp()
  next.status = acked
  case invalid
  of 0: payload[85] = 69 # not 68 -> 67
  of 1: payload[65] = 40 # IP length exceeds buffer
  of 2: payload[68] = 0x20 # more fragments
  else: next.len = 89
  let ring = nimFwDbgDhcpCfmRingIdx
  doAssert bl_tx_cfm(nil, addr payload) == 1 and nimFwDbgDhcpCfmRingIdx == ring

let full = startDhcp()
full.len = 48 + 286
full.status = acked
let ip = byteView(addr payload[62])
ip[2] = 1; ip[3] = 16 # IPv4 272 bytes
ip[25] = 252 # UDP 8 + 244 bytes
ip[28] = 1
ip[32] = 0x12; ip[33] = 0x34; ip[34] = 0x56; ip[35] = 0x78
ip[264] = 0x63; ip[265] = 0x82; ip[266] = 0x53; ip[267] = 0x63
ip[268] = 53; ip[269] = 1; ip[270] = 3; ip[271] = 255
let ring = nimFwDbgDhcpCfmRingIdx and 7
doAssert bl_tx_cfm(nil, addr payload) == 1
doAssert dhcpCfmXidLog[ring] == 0x12345678'u32
doAssert ((nimFwDbgDhcpCfmMetaLog[ring] shr 18) and 31) == 0x13
'''


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_dhcp_attempt_owns_programmed_policy(tmp_path: Path, mode: str) -> None:
    definitions = (TX / "types_parts/tx_descriptor_views.nim").read_text()
    code = "{.define: bl808WifiDiagDhcpTxAttempts.}\n" + HOST_TABLE
    code += definitions.split("  TxbufView", 1)[0] + "\n"
    code += (TX / "layout.nim").read_text().split("  BlHwIpcEnvOff", 1)[0]
    platform = PLATFORM.replace("array[80, uint8]", "array[400, uint8]")
    code += platform.replace(procedure(platform, "logDhcpTxConfirm"), "") + TRACE_PLATFORM
    code += (TX / "queue_parts/header_fields.nim").read_text()
    code += PARSER
    code += (FW / "tx_policy_trace.nim").read_text()
    code += (TX / "confirm_parts/dhcp_log.nim").read_text()
    for path in ["queue_parts/tx_status.nim", "confirm_parts/repush.nim", "confirm_parts/complete.nim"]:
        code += (TX / path).read_text()
    setup = CHECKS.split("for dest in", 1)[0]
    run_program(tmp_path, mode, code + setup + TRACE_CHECKS)
