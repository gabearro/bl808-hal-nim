"""Validate TKIP/CCMP ExtIV at RX admission, not in the raw header decoder."""

from pathlib import Path

import pytest

from test_wifi_message_allocation import run_program
from test_wifi_rx_protected_header import dispatch_source


MODES = ["checked", "release", "asan", "firmware"]
FRAMES = "[0x4008'u16, 0x4108, 0x4208, 0x4308, 0x4088, 0x4188, 0x4288, 0x4388, 0xC088, 0xC188, 0xC288, 0xC388]"


@pytest.mark.parametrize("mode", MODES)
@pytest.mark.parametrize("kind", [24, 28], ids=["tkip", "ccmp"])
@pytest.mark.parametrize("eapol", [False, True], ids=["data", "eapol"])
def test_extiv_before_key_selection(tmp_path: Path, mode: str, kind: int, eapol: bool) -> None:
    code = dispatch_source() + f"const kind = {kind}'u32\nconst eapol = {str(eapol).lower()}\n"
    code += f"for fc in {FRAMES}:\n" + r'''
  for group in [false, true]:
    for octet in 0'u16 .. 255'u16:
      for reserved in [0'u8, 0x5A, 0xFF]:
        prepareProtected(fc, kind, (octet shr 6).uint8, group, eapol)
        let macLength = rxMacHeaderLen(fc).int
        bytes[macLength + 2] = reserved
        bytes[macLength + 3] = octet.uint8
        let before = bytes
        let beforeKey = key
        let beforeSequences = stations[0].sequences
        let accepted = (octet and 0x20) != 0
        let result = rxu_cntrl_frame_handle(addr mpdu)
        if not accepted:
          doAssert keySelections == 0, "missing ExtIV reached key selection"
          doAssert result == 0 and replayCalls == 0 and micCalls == 0,
            "missing ExtIV reached replay or MIC processing"
          doAssert transferred == 0 and prepared == 0 and eapolCalls == 0
          doAssert envState.secFlags == 0 and envState.secKeyPtr == nil
          doAssert envState.machdrLen.int == macLength
          doAssert bytes == before and key == beforeKey
          doAssert stations[0].sequences == beforeSequences
        else:
          doAssert keySelections == 1 and selectedKeyId == (octet shr 6).uint8
          doAssert selectedGroup == group and replayCalls == 1
          doAssert micCalls == (if kind == 24: 1 else: 0)
          if eapol:
            doAssert result == 0 and eapolCalls == 1 and transferred == 0 and prepared == 0
            doAssert eapolLength == (if kind == 24: 24'u32 else: 32'u32)
            for i, b in eapolBytes: doAssert b == before[macLength + 16 + i]
          else:
            doAssert result == 1 and eapolCalls == 0 and transferred == 1 and prepared == 1
            doAssert sw.mpduLengthBytes == (if kind == 24: 38'u16 else: 46'u16)
'''
    run_program(tmp_path, mode, code)


@pytest.mark.parametrize("mode", MODES)
def test_ccmp_management_extiv_before_replay(tmp_path: Path, mode: str) -> None:
    code = dispatch_source().replace(
        "proc rxu_mgt_frame_check(p: pointer; sta: uint8): uint32 = 0",
        "var managementCalls: int\nproc rxu_mgt_frame_check(p: pointer; sta: uint8): uint32 =\n"
        "  inc managementCalls\n  0")
    assert "inc managementCalls" in code
    run_program(tmp_path, mode, code + r'''
for fc in [0x40A0'u16, 0x40C0, 0x40D0, 0xC0D0]:
  for octet in 0'u16 .. 255'u16:
    prepareProtected(fc, 28, (octet shr 6).uint8, false, false)
    bytes[rxMacHeaderLen(fc).int + 3] = octet.uint8
    managementCalls = 0
    let before = bytes
    let beforeKey = key
    let beforeSequences = stations[0].sequences
    doAssert rxu_cntrl_frame_handle(addr mpdu) == 0
    let accepted = (octet and 0x20) != 0
    doAssert keySelections == accepted.int, "management ExtIV gate changed key selection"
    doAssert replayCalls == accepted.int and managementCalls == accepted.int
    doAssert micCalls == 0 and transferred == 0 and prepared == 0 and eapolCalls == 0
    doAssert bytes == before and key == beforeKey and stations[0].sequences == beforeSequences
''')


@pytest.mark.parametrize("mode", MODES)
def test_extiv_header_truncation(tmp_path: Path, mode: str) -> None:
    code = dispatch_source() + f"for fc in {FRAMES}:\n" + r'''
  for kind in [24'u32, 28]:
    for octet in [0'u8, 0x20, 0xFF]:
      for exposed in 0 ..< 8:
        for alignment in 0 ..< 4:
          prepareProtected(fc, kind, octet shr 6, false, false)
          let length = rxMacHeaderLen(fc).int + exposed
          bytes[rxMacHeaderLen(fc).int + 3] = octet
          let storage = alloc(length + alignment)
          let packet = cast[pointer](cast[uint](storage) + alignment.uint)
          copyMem(packet, addr bytes[0], length)
          chain.frameData = packet
          sw.mpduLengthBytes = length.uint16
          let beforeSequences = stations[0].sequences
          doAssert rxu_cntrl_frame_handle(addr mpdu) == 0
          doAssert keySelections == 0 and replayCalls == 0 and micCalls == 0
          doAssert eapolCalls == 0 and transferred == 0 and prepared == 0
          doAssert stations[0].sequences == beforeSequences
          doAssert cmpMem(packet, addr bytes[0], length) == 0
          dealloc(storage)
'''
    run_program(tmp_path, mode, code)


@pytest.mark.parametrize("mode", MODES)
def test_wep_without_extiv_is_unchanged(tmp_path: Path, mode: str) -> None:
    code = dispatch_source() + f"for fc in {FRAMES}:\n" + r'''
  for octet in 0'u16 .. 255'u16:
    prepareProtected(fc, 20, (octet shr 6).uint8, false, false)
    bytes[rxMacHeaderLen(fc).int + 3] = octet.uint8
    doAssert rxu_cntrl_frame_handle(addr mpdu) == 1
    doAssert keySelections == 0 and replayCalls == 0 and micCalls == 0
    doAssert transferred == 1 and prepared == 1 and eapolCalls == 0
'''
    run_program(tmp_path, mode, code)
