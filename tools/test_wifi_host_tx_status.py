"""Exercise the host callback and repush ownership for MAC TX statuses."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import ROOT, procedure
from test_wifi_message_allocation import run_program


TX = ROOT / "src/bl808/wifi/tx"
HOST_TABLE = f'from "{TX.parent / "host_table_layout"}" import WifiHostStaTableCount\n'

PLATFORM = r'''
{.emit: """
volatile unsigned int nimfw_dbg_bl_tx_cfm, nimfw_dbg_bl_tx_cfm_cb;
volatile unsigned int nimfw_dbg_bl_tx_cfm_eapol;
""".}
type
  EthernetHeaderView {.packed.} = object
    dst, src: array[6, uint8]
    ethertype: uint16
  BlStaView = object
    pendingList: pointer
    staIdx, isUsed, fcPs: uint8
  Vif = object
    linksNum, fcChan: uint8
  TxCallback = proc(arg: pointer; ok: bool) {.cdecl.}

var
  payload: array[80, uint8]
  station: BlStaView
  vif: Vif
  txCntrlStaTriggerPending: uint32
  completions: seq[bool]
  freed: int

proc bufferAt(p: pointer; offset: uint): pointer =
  cast[pointer](cast[uint](p) + offset)
proc txbufHostBuf(host: pointer): pointer =
  doAssert host == addr payload
  addr payload[0]
proc alignPads(p: pointer): uint8 = 0
proc txHdrView(p: pointer): ptr TxHdrView = cast[ptr TxHdrView](p)
proc ethernetHeaderAt(p: pointer): ptr EthernetHeaderView =
  cast[ptr EthernetHeaderView](p)
proc isBcMc(octet: uint8): bool = (octet and 1) != 0
proc staAt(idx: int): pointer =
  doAssert idx == 2
  addr station
proc staView(p: pointer): ptr BlStaView = cast[ptr BlStaView](p)
proc staVif(p: pointer): pointer =
  doAssert p == addr station
  addr vif
proc vifView(p: pointer): ptr Vif = cast[ptr Vif](p)
proc bitSta(idx: uint8): uint32 = 1'u32 shl idx
proc listPushBack(list, item: pointer) =
  let owned = cast[ptr pointer](list)
  doAssert owned[] == nil
  owned[] = item
proc bl_os_printf(s: cstring) = discard
proc logDhcpTxConfirm(eth: ptr EthernetHeaderView; hdr: pointer; ret: int; status: uint32;
                      hostId: pointer) = discard
proc logEapolTxConfirm(eth: ptr EthernetHeaderView; hdr: pointer; cb: TxCallback;
                       proto: uint16; ret: int; status: uint32) = discard
proc ipc_host_txbuf_free(host: pointer) =
  doAssert host == addr payload
  doAssert station.pendingList == nil and freed == 0
  zeroMem(host, sizeof(payload))
  inc freed
proc txCallback(arg: pointer; ok: bool) {.cdecl.} =
  doAssert arg == (addr station) and freed == 1
  completions.add(ok)
'''


CHECKS = r"""
const
  failed = 0x80010701'u32
  acked = 0x80800001'u32
  noAckExpected = 0x80000001'u32
  softwareDropped = 0xC0020001'u32

proc startPacket(isSta, dest: uint8): ptr TxHdrView =
  payload = default(typeof(payload))
  station = BlStaView(staIdx: 2, isUsed: 1)
  vif = Vif(linksNum: 1)
  completions.setLen(0)
  freed = 0
  txCntrlStaTriggerPending = 0
  result = txHdrView(addr payload[0])
  result.cfmCb = cast[pointer](txCallback)
  result.cfmArg = addr station
  setTxHdrVifType(result, isSta)
  setTxHdrStaId(result, station.staIdx)
  let eth = ethernetHeaderAt(addr payload[PbufLinkEncapsulationHlen.int])
  eth.dst[0] = dest
  eth.ethertype = 0x0008

for dest in [0x00'u8, 0x01, 0xFF]:
  for role in [0'u8, 1]:
    for status in [acked, noAckExpected, softwareDropped, 0'u32]:
      let hdr = startPacket(role, dest)
      hdr.status = status
      let ok = status == acked or (status == noAckExpected and role == 0 and isBcMc(dest))
      doAssert bl_tx_cfm(nil, addr payload) == ok.cint
      doAssert freed == 1 and completions == @[ok] and station.pendingList == nil

for dest in [0x00'u8, 0x01, 0xFF]:
  for eventualAck in [false, true]:
    let hdr = startPacket(1, dest)
    for retryIndex in 0 ..< 3:
      hdr.status = failed
      doAssert bl_tx_cfm(nil, addr payload) == 0
      doAssert station.pendingList == hdr and hdr.repush == (retryIndex + 1).uint8
      doAssert freed == 0 and completions.len == 0
      doAssert txCntrlStaTriggerPending == bitSta(station.staIdx)
      # Model the scheduler taking ownership and submitting the same buffer.
      station.pendingList = nil
      txCntrlStaTriggerPending = 0
    hdr.status = if eventualAck: acked else: failed
    doAssert bl_tx_cfm(nil, addr payload) == eventualAck.cint
    doAssert freed == 1 and completions == @[eventualAck]

for linkGone in [false, true]:
  let hdr = startPacket(1, 0xFF)
  if linkGone: vif.linksNum = 0
  else: station.isUsed = 0
  hdr.status = failed
  doAssert bl_tx_cfm(nil, addr payload) == 0
  doAssert freed == 1 and completions == @[false] and station.pendingList == nil

# The AP may defer a group frame before transmitting it. Software done
# must not make the descriptor look like a completed group transmission.
for status in [0xC0080001'u32, 0xC0100001'u32]:
  let hdr = startPacket(0, 0xFF)
  hdr.status = status
  doAssert bl_tx_cfm(nil, addr payload) == 0
  doAssert station.pendingList == hdr and hdr.repush == 1
  doAssert freed == 0 and completions.len == 0
  doAssert station.fcPs == ((status and FrameRepushablePsBit) != 0).uint8
  doAssert vif.fcChan == ((status and FrameRepushableChanBit) != 0).uint8
"""


@pytest.mark.parametrize("mode", ["checked", "firmware", "asan"])
def test_sta_ethernet_group_tx_requires_mac_success(tmp_path: Path, mode: str) -> None:
    definitions = (TX / "types_parts/tx_descriptor_views.nim").read_text()
    code = HOST_TABLE + definitions.split("  TxbufView", 1)[0] + "\n"
    code += (TX / "layout.nim").read_text().split("  BlHwIpcEnvOff", 1)[0]
    code += PLATFORM + (TX / "queue_parts/header_fields.nim").read_text()
    for path, name in [
        ("queue_parts/tx_status.nim", "txCheckRet"),
        ("confirm_parts/repush.nim", "repushTxConfirmIfNeeded"),
        ("confirm_parts/complete.nim", "bl_tx_cfm"),
    ]:
        code += procedure((TX / path).read_text(), name)
    run_program(tmp_path, mode, code + CHECKS)
