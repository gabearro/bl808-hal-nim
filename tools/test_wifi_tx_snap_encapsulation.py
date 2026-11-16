"""Keep Ethernet-II AARP/IPX distinct from native RFC1042 LLC payloads."""

from pathlib import Path

import pytest

from test_wifi_auth_frames import layouts
from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program
from test_wifi_rx_decapsulation import CHECKS as RX_CHECKS, dispatch_source
from test_wifi_tx_sequence import CHECKS as TX_CHECKS, program_source


def writer_source() -> str:
    layout = (FW / "layout_types.nim").read_text()
    return (layouts("LlcSnapHeaderView") + """
type TxFrameBuildLayout = object
  snap: ptr LlcSnapHeaderView
""" + procedure(layout, "lmacGateHalfword")
            + procedure(layout, "txFrameSnapLen")
            + procedure(layout, "txFrameWriteSnap"))


@pytest.mark.parametrize("mode", ["checked", "release", "asan", "firmware"])
def test_snap_writer_all_ethertypes(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, writer_source() + r'''
for protocol in 0'u32 .. 65535'u32:
  var buffer: array[40, uint8]
  for value in buffer.mitems: value = 0xA5
  var expected = buffer
  let size = txFrameSnapLen(protocol.uint16)
  let header = cast[ptr LlcSnapHeaderView](addr buffer[16])
  let frame = TxFrameBuildLayout(snap: if size == 0: nil else: header)
  txFrameWriteSnap(frame, lmacGateHalfword(protocol.uint16))
  if protocol >= 1536:
    doAssert size == 8
    expected[16] = 0xAA
    expected[17] = 0xAA
    expected[18] = 3
    expected[19] = 0
    expected[20] = 0
    expected[21] = if protocol in [0x80F3'u32, 0x8137]: 0xF8'u8 else: 0'u8
    expected[22] = (protocol shr 8).uint8
    expected[23] = (protocol and 255).uint8
  else:
    doAssert size == 0
  doAssert buffer == expected, "incorrect SNAP encoding for EtherType " & $protocol
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan", "firmware"])
def test_frame_builder_snap_protocols(tmp_path: Path, mode: str) -> None:
    setup = TX_CHECKS.split("\nreset()\n", 1)[0]
    checks = r'''
for protocol in [0x80F3'u16, 0x8137, 0xF380, 0x3781, 0x0800, 0x0806, 0x86DD,
                 0x888E, 1500, 1535, 1536]:
  for vifIndex in 0'u8 .. 1'u8:
    for vifType in [0'u8, 1, 2, 3]:
      for tid in [0'u8, 3, 7, 8, 0xFF]:
        for security in [0'u32, 4, 8]:
          for enabled in [false, true]:
            reset()
            interrupts = enabled
            vifs[vifIndex].vifType = vifType
            securityHeaderLen = security
            securityTailLen = security
            pushResult = 1
            checkTx(0, tid, vifIndex, protocol)
            doAssert interrupts == enabled
'''
    run_program(tmp_path, mode, program_source() + setup + checks)


def roundtrip_source() -> str:
    layout = (FW / "layout_types.nim").read_text()
    code = dispatch_source()
    old = "  LlcSnapHeaderView {.packed.} = object\n    prefix: array[6, uint8]\n    ethertype: uint16\n"
    assert code.count(old) == 1
    code = code.replace(old, layouts("LlcSnapHeaderView").removeprefix("type\n"), 1)
    code = code.replace(procedure(code, "rxSnapIsRfc1042"),
        procedure(layout, "rxSnapPrefixIs") + procedure(layout, "rxSnapIsRfc1042"), 1)
    code = code.replace(procedure(code, "rxSnapIsBridgeTunnel"),
        procedure(layout, "rxSnapIsBridgeTunnel"), 1)
    code += "\ntype TxFrameBuildLayout = object\n  snap: ptr LlcSnapHeaderView\n"
    code += procedure(layout, "txFrameWriteSnap")
    return code + procedure(RX_CHECKS, "setup")


@pytest.mark.parametrize("mode", ["checked", "release", "asan", "firmware"])
def test_tx_snap_rx_ethernet_roundtrip(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, roundtrip_source() + r'''
for protocol in [0x80F3'u16, 0x8137, 0xF380, 0x3781, 0x0800, 0x0806, 0x86DD]:
  for fc in [0x0008'u16, 0x0108, 0x0208, 0x0288, 0x0308, 0x0388, 0x8288]:
    let headerLen = rxMacHeaderLen(fc).int
    setup(fc, headerLen, 40)
    let snap = cast[ptr LlcSnapHeaderView](addr bytes[headerLen])
    txFrameWriteSnap(TxFrameBuildLayout(snap: snap), lmacGateHalfword(protocol))
    let before = bytes
    doAssert rxu_cntrl_frame_handle(addr mpdu) == 1
    doAssert transferred == 1 and prepared == 1 and eapolCalls == 0
    doAssert sw.bufferOffset == (headerLen - 6).uint32,
      "TX SNAP did not recover an Ethernet-II frame"
    doAssert sw.mpduLengthBytes == 46
    let eth = rxEthernetRewriteHeader(addr bytes[0], sw.bufferOffset.uint8)
    doAssert eth.ethertype == lmacGateHalfword(protocol), "EtherType did not round-trip"
    for i in headerLen + 8 ..< bytes.len:
      doAssert bytes[i] == before[i], "RX altered payload or trailing storage"
''')
