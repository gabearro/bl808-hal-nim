"""Check real protected-header decoding and its receive-dispatch callers."""

from pathlib import Path
import re

import pytest

from test_wifi_auth_frames import layouts
from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program
import test_wifi_rx_decapsulation as rx


def decoder_source() -> tuple[str, str]:
    source = (FW / "rx_upper.nim").read_text()
    layout = (FW / "layout_types.nim").read_text()
    code = layouts("CcmpSecurityHeaderView", "TkipSecurityHeaderView")
    start = layout.index("proc rxSecurityHeaderAt[")
    code += layout[start:layout.index("\nproc ", start + 1)]
    code += procedure(source, "rxu_cntrl_protected_handle")
    names = sorted(set(re.findall(r"\bnimFwDbg\w+",
        code + procedure(source, "rxuTraceProtectedSlot"))))
    return "var\n" + "".join(f"  {name}: uint32\n" for name in names), code


def header_source() -> str:
    diagnostics, decoder = decoder_source()
    # Include the asterisk to distinguish CoList from its CoListHdr prefix.
    code = diagnostics + layouts("CoListHdr", "CoList*", "RxuCntrlEnvView",
                   "KeyReplayCounterView", "VifKeySlotView",
                   "VifRxProtectedKeyTableOverlay", "StaInfoView")
    code += r'''
type
  VifChannelView = object
    bytes: array[1512, uint8]
var
  env: RxuCntrlEnvView
  stations: array[7, StaInfoView]
  vifs: array[2, VifChannelView]
proc rxuCntrlEnvView(): ptr RxuCntrlEnvView = addr env
proc staInfoForIdx(i: uint8): ptr StaInfoView = addr stations[i]
proc vifChannelForIdx(i: uint8): ptr VifChannelView = addr vifs[i]
proc rxFrameBytes(p: pointer): ptr UncheckedArray[uint8] =
  cast[ptr UncheckedArray[uint8]](p)
proc pointerAddrU32(p: pointer): uint32 = cast[uint32](cast[uint](p))
'''
    layout = (FW / "layout_types.nim").read_text()
    start = layout.index("template vifRxProtectedKeySlot(")
    code += layout[start:layout.index("\ntemplate ", start + 1)]
    source = (FW / "rx_upper.nim").read_text()
    code += procedure(source, "rxuProtectedKey")
    code += procedure(source, "rxuTraceProtectedSlot")
    code += decoder
    return code + r'''
proc checkHeader(kind: uint32; header: array[8, uint8]; offset = 24;
                 alignment = 0; station = 0'u8; vif = 0'u8; group = false) =
  var storage: array[96, uint8]
  for b in storage.mitems: b = 0x5A
  for i, b in header: storage[alignment + offset + i] = b
  let before = storage
  let stationBefore = stations
  let vifBefore = vifs
  env = RxuCntrlEnvView(frameCtrl: 0x4288, seqCtrl: 0x1230, seqNum: 0x123,
    fragNum: 2, tid: 3, machdrLen: offset.uint8, staIdx: station,
    vifIdx: vif, dstIdx: 6, secInfo0: 0x12345678, secInfo1: 0x87654321'u32,
    secFlags: 0xA0, hwRxhdr: 0x31415926, meshFlag: 1, stripLen: 4,
    bssidSeq: 0x4321)
  var expected = env
  let flags = 0x20026000'u32 or kind or (if group: 0x400'u32 else: 0'u32)
  let accepted = kind in [20'u32, 24, 28]
  if kind == 20:
    expected.machdrLen += 4
  elif kind in [24'u32, 28]:
    expected.machdrLen += 8
    let low0 = if kind == 24: header[2] else: header[0]
    let low1 = if kind == 24: header[0] else: header[1]
    expected.secInfo0 = low0.uint32 or (low1.uint32 shl 8) or
      (header[4].uint32 shl 16) or (header[5].uint32 shl 24)
    expected.secInfo1 = header[6].uint32 or (header[7].uint32 shl 8)
    expected.secFlags = 0xA0'u8 or (if kind == 24: 3'u8 else: 2'u8)
    expected.secKeyPtr = if group:
      cast[pointer](cast[uint](addr vifs[vif]) + 528 +
                    (header[3].uint shr 6) * 160)
    else:
      cast[pointer](addr stations[station].keyArea[0])
  doAssert (rxu_cntrl_protected_handle(addr storage[alignment], flags) != 0) == accepted
  doAssert env == expected, "protected header changed unrelated RX state"
  doAssert storage == before and stations == stationBefore and vifs == vifBefore
  if kind in [24'u32, 28]:
    doAssert nimFwDbgRxuProtPnLo == expected.secInfo0
    doAssert nimFwDbgRxuProtPnHi == expected.secInfo1
    doAssert nimFwDbgRxuProtKey == pointerAddrU32(expected.secKeyPtr)
'''


HEADER_CASES = {
    "wire_bytes": r'''
for kind in [24'u32, 28]:
  for position in 0..<8:
    for value in 0..255:
      var header = [0x12'u8, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0]
      header[position] = value.uint8
      checkHeader(kind, header, group = (value and 1) != 0)
''',
    "key_and_header_location": r'''
for kind in [24'u32, 28]:
  for station in 0'u8..6:
    for vif in 0'u8..1:
      for keyId in 0'u8..3:
        for group in [false, true]:
          for offset in [24, 26, 28, 30, 32, 36]:
            for alignment in 0..3:
              checkHeader(kind, [0x80'u8, 0x7F, 0xA5,
                (keyId shl 6) or 0x3F, 0x01, 0x23, 0x45, 0x67],
                offset, alignment, station, vif, group)
''',
    "wep_and_unrecognized_status": r'''
for kind in countup(0'u32, 28'u32, 4'u32):
  if kind in [24'u32, 28]: continue
  for offset in [24, 26, 28, 30, 32, 36]:
    for alignment in 0..3:
      # WEP and unrecognized status values do not select a TKIP/CCMP key.
      checkHeader(kind, [0xFF'u8, 0xAA, 0x55, 0xFF, 1, 2, 3, 4],
                  offset, alignment, 255, 255, true)
''',
}


def dispatch_source() -> str:
    code = rx.dispatch_source()
    code = code.replace(rx.procedure(code, "rxu_cntrl_protected_handle"), r'''
proc rxuProtectedKey(env: ptr RxuCntrlEnvView; index: uint8; group: bool): ptr Key =
  inc keySelections
  selectedKeyId = index
  selectedGroup = group
  addr key
proc rxuTraceProtectedSlot(key: ptr Key; index: uint8; group: bool) = discard
proc pointerAddrU32(p: pointer): uint32 = cast[uint32](cast[uint](p))
''', 1)
    code = "var keySelections: int\nvar selectedKeyId: uint8\nvar selectedGroup: bool\n" + code
    diagnostics, body = decoder_source()
    code = diagnostics + code
    # The dispatcher is already declared; place the real decoder before it.
    start = code.index("proc rxu_cntrl_frame_handle*")
    code = code[:start] + body + code[start:]
    code += rx.CHECKS.split("proc checkFrame(", 1)[0]
    return code + r'''
proc prepareProtected(fc: uint16; kind: uint32; keyId: uint8; group: bool;
                      eapol: bool) =
  let macLength = rxu_cntrl_machdr_len_get(fc).int
  let headerLength = if kind == 20: 4 else: 8
  setup(fc, macLength + headerLength, 40)
  if eapol and (fc and 0x100) != 0:
    vifs[0].macAddr = macDataFrameAt(addr bytes[0]).addr3
  sw.hwFlags = (sw.hwFlags and not 0x41C'u32) or kind or
    (if group: 0x400'u32 else: 0'u32)
  let header = [0x12'u8, 0x34, 0x56, (keyId shl 6) or 0x20, 0x78, 0x9A, 0xBC, 0xDE]
  for i in 0..<headerLength: bytes[macLength + i] = header[i]
  snapAt(macLength + headerLength, if eapol: 0x888E else: 0x0800)
  if kind == 24:
    for i in 0..<8: bytes[sw.mpduLengthBytes.int - 8 + i] = (i + 1).uint8
    if eapol:
      # The EAPOL body length excludes the trailing Michael MIC.
      bytes[macLength + headerLength + 11] -= 8
  keySelections = 0
  selectedKeyId = 255
  selectedGroup = not group
'''


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("case", HEADER_CASES)
def test_protected_header(tmp_path: Path, mode: str, case: str) -> None:
    run_program(tmp_path, mode, header_source() + HEADER_CASES[case])


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_real_qos_field_location(tmp_path: Path, mode: str) -> None:
    layout = (FW / "layout_types.nim").read_text()
    code = layouts("MacDataFrameHeaderView", "MacQosDataFrameHeaderView",
                   "MacQos4AddrFrameHeaderView")
    for name in ["macQosDataFrameAt", "macQos4AddrFrameAt"]:
        start = layout.index("template " + name + "(")
        code += layout[start:layout.index("\n\n", start)] + "\n"
    code += procedure(layout, "rxMacHeaderLen")
    code += procedure(layout, "rxQosControl")
    run_program(tmp_path, mode, code + r'''
var storage: array[48, uint8]
for subtype in countup(0x88'u16, 0xF8'u16, 0x10'u16):
  for ds in [0'u16, 0x100, 0x200, 0x300]:
    for order in [0'u16, 0x8000]:
      for protectedBit in [0'u16, 0x4000]:
        let fc = subtype or ds or order or protectedBit
        let offset = if ds == 0x300: 30 else: 24
        for alignment in 0..3:
          for value in [0'u16, 0x80, 0xFF, 0x1234, 0xFFFF]:
            for index in 0..<storage.len: storage[index] = 0xA5
            storage[alignment] = fc.uint8
            storage[alignment + 1] = (fc shr 8).uint8
            storage[alignment + offset] = (value and 255).uint8
            storage[alignment + offset + 1] = (value shr 8).uint8
            let original = storage
            let frame = cast[ptr MacDataFrameHeaderView](addr storage[alignment])
            doAssert rxQosControl(frame, rxMacHeaderLen(fc)) == value
            doAssert storage == original
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("eapol", [False, True], ids=["data", "eapol"])
def test_dispatch_with_real_protected_header(tmp_path: Path, mode: str, eapol: bool) -> None:
    run_program(tmp_path, mode, dispatch_source() + f"const testEapol = {str(eapol).lower()}\n" + r'''
for fc in [0x4008'u16, 0x4108, 0x4208, 0x4308, 0x4088, 0x4388, 0xC388]:
  for kind in [20'u32, 24, 28]:
    for keyId in 0'u8..3:
      for group in [false, true]:
        prepareProtected(fc, kind, keyId, group, testEapol)
        let headerLength = rxu_cntrl_machdr_len_get(fc).int + (if kind == 20: 4 else: 8)
        let payloadLength = 40 - (if kind == 24: 8 else: 0)
        let original = bytes
        doAssert rxu_cntrl_frame_handle(addr mpdu) == (if testEapol: 0'u32 else: 1'u32)
        doAssert envState.machdrLen.int == headerLength
        doAssert replayCalls == (if kind == 20: 0 else: 1)
        doAssert micCalls == (if kind == 24: 1 else: 0)
        doAssert keySelections == (if kind == 20: 0 else: 1)
        if kind != 20:
          doAssert selectedKeyId == keyId and selectedGroup == group
          doAssert envState.secInfo0 == (if kind == 24: 0x9A781256'u32 else: 0x9A783412'u32)
          doAssert envState.secInfo1 == 0xDEBC
        if testEapol:
          doAssert eapolCalls == 1 and transferred == 0 and prepared == 0,
            "EAPOL dispatch: " & $fc & " " & $kind & " " & $keyId & " " & $group
          doAssert eapolLength.int == payloadLength - 8
          for i, b in eapolBytes: doAssert b == original[headerLength + 8 + i]
        else:
          doAssert eapolCalls == 0 and transferred == 1 and prepared == 1
          doAssert sw.bufferOffset.int == headerLength - 6
          doAssert sw.mpduLengthBytes.int == payloadLength + 6
          for i in 6..<payloadLength:
            doAssert bytes[headerLength + i] == original[headerLength + i]
''')
