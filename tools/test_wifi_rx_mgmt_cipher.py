"""Management cipher/subtype admission before real replay-counter updates."""
from pathlib import Path
import re

import pytest

from test_wifi_auth_frames import layouts
from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program
from test_wifi_rx_protected_header import dispatch_source


def source() -> str:
    code = dispatch_source()
    old = ("  Key = object\n    keyMaterial: array[152, uint8]\n"
           "    cipherType, staIdx: uint8\n  VifKeySlotView = Key\n")
    assert code.count(old) == 1
    code = code.replace(old, layouts("KeyReplayCounterView", "VifKeySlotView").removeprefix("type\n")
                        + "  Key = VifKeySlotView\n  ReplayCounterStateView = KeyReplayCounterView\n", 1)
    if "    capabilityFlags: uint32\n" not in code:
        code = code.replace("    sequences: Sequences\n", "    sequences: Sequences\n    capabilityFlags: uint32\n", 1)
    code = code.replace("proc irqSave(): uint32 = 0\n", r'''
var interrupts = true
proc irqSave(): uint32 =
  result = interrupts.uint32 * 8
  interrupts = false
''', 1).replace("proc irqRestore(flags: uint32) = discard\n",
               "proc irqRestore(flags: uint32) = interrupts = (flags and 8) != 0\n", 1)
    code = code.replace(procedure(code, "rxu_mgt_frame_check"), r'''
var managementCalls: int
proc rxu_mgt_frame_check(p: pointer; station: uint8): uint32 =
  inc managementCalls
  0
''', 1)
    code = code.replace(procedure(code, "rxu_cntrl_check_pn"), "", 1)
    code = code.replace(procedure(code, "rxuPnFresh"), "", 1)
    rx = (FW / "rx_upper.nim").read_text()
    replay = procedure((FW / "mac_config_debug.nim").read_text(), "replay_counter_validate")
    replay += procedure(rx, "rxu_cntrl_check_pn") + procedure(rx, "rxuPnFresh")
    extras = "\nvar\n" + "".join(
        f"  {name}: uint32\n" for name in sorted(set(re.findall(r"\bnimFwDbg\w+", replay)))
        if not re.search(r"\b" + name + r"\s*:", code))
    extras += r'''
{.define: bl808WifiDiagPeerRxAdmission.}
type RxMgtProtection = enum
  rxMgtProtectionUnknown, rxMgtWithoutProtection, rxMgtVerifiedCcmp, rxMgtVerifiedBip
var lastProtection: RxMgtProtection
proc rxMgtNoteProtection(p: pointer; generation: uint32; protection: RxMgtProtection) =
  doAssert p == addr mpdu
  lastProtection = protection
var managementCounter: KeyReplayCounterView
proc replayCounterStateView(p: pointer): ptr ReplayCounterStateView =
  cast[ptr ReplayCounterStateView](p)
proc rxMgtReplayCounter(p: pointer): ptr KeyReplayCounterView = addr managementCounter
'''
    if "proc mfp_is_robust_frame" not in code:
        extras += procedure((FW / "kernel_mac_channel.nim").read_text(), "mfp_is_robust_frame")
    handler = procedure(code, "rxu_cntrl_frame_handle")
    code = code.replace(handler, extras + replay + handler, 1)
    return code + r'''
proc prepare(fc: uint16; cipher: uint32; associated, pmf, groupKey, groupDa, enabled: bool;
             category = 3'u8; bodyLength = 40; windowed = false) =
  prepareProtected(fc, cipher, 2, groupKey, false)
  if not associated: sw.hwFlags = sw.hwFlags and not 0x02000000'u32
  let macLength = rxMacHeaderLen(fc).int
  let securityLength = if cipher == 20: 4 else: 8
  bytes[macLength + securityLength] = category
  if groupDa: macDataFrameAt(addr bytes[0]).addr1[0] = 1
  stations[0].capabilityFlags = if pmf: 8 else: 0
  key.installed = 1
  key.staIdx = 2
  key.cipherType = if cipher == 20: 0 elif cipher == 24: 1 else: 2
  key.hasRxPn = windowed.uint8
  managementCounter = default(KeyReplayCounterView)
  managementCalls = 0
  lastProtection = rxMgtProtectionUnknown
  sw.mpduLengthBytes = (macLength + securityLength + bodyLength).uint16
  interrupts = enabled
proc checkRejected(enabled: bool) =
  let beforeKey = key
  let beforeCounter = managementCounter
  let beforeSequences = stations
  let beforeBssidSeq = envState.bssidSeq
  let beforeAddress = rxu_mgmt_dup_addr
  let before = bytes
  doAssert rxu_cntrl_frame_handle(addr mpdu) == 0
  doAssert key == beforeKey and managementCounter == beforeCounter,
    "ineligible management protection consumed replay state"
  doAssert managementCalls == 0 and keySelections == 0,
    "ineligible management protection reached key selection/publication"
  doAssert lastProtection == rxMgtProtectionUnknown
  doAssert stations == beforeSequences and bytes == before
  doAssert envState.bssidSeq == beforeBssidSeq and rxu_mgmt_dup_addr == beforeAddress,
    "ineligible management protection consumed the unassociated duplicate cache"
  doAssert transferred == 0 and prepared == 0 and eapolCalls == 0 and micCalls == 0
  doAssert interrupts == enabled
'''


CASES = {
    "tkip-management": r'''
for associated in [false, true]:
  for fc in [0x40A0'u16, 0x40B0, 0x40C0, 0x40D0, 0xC0D0]:
    for windowed in [false, true]:
      for enabled in [false, true]:
        prepare(fc, 24, associated, true, false, false, enabled, windowed = windowed)
        checkRejected(enabled)
''',
    "wep-subtype": r'''
for associated in [false, true]:
  for subtype in countup(0'u16, 0xF0'u16, 0x10'u16):
    if subtype == 0xB0: continue
    for enabled in [false, true]:
      prepare(0x4000'u16 or subtype, 20, associated, false, false, false, enabled)
      checkRejected(enabled)
''',
    "ccmp-category": r'''
for fc in [0x4000'u16, 0x4010, 0x4020, 0x4030, 0x4040, 0x4050, 0x4080, 0x40B0]:
  for enabled in [false, true]:
    prepare(fc, 28, true, true, false, false, enabled)
    checkRejected(enabled)
for category in [4'u8, 7, 11, 15, 127]:
  for fc in [0x40D0'u16, 0xC0D0]:
    for enabled in [false, true]:
      prepare(fc, 28, true, true, false, false, enabled, category)
      checkRejected(enabled)
''',
    "ccmp-peer-and-key": r'''
for fc in [0x40A0'u16, 0x40C0, 0x40D0, 0xC0D0]:
  for invalid in 0..2:
    for enabled in [false, true]:
      prepare(fc, 28, true, invalid != 0, invalid == 1, invalid == 2, enabled)
      checkRejected(enabled)
''',
    "ccmp-empty-body": r'''
for fc in [0x40A0'u16, 0x40C0, 0x40D0, 0xC0D0]:
  for enabled in [false, true]:
    prepare(fc, 28, true, true, false, false, enabled, bodyLength = 0)
    let length = sw.mpduLengthBytes.int
    let packet = alloc(length)
    copyMem(packet, addr bytes[0], length)
    chain.frameData = packet
    try:
      checkRejected(enabled)
      doAssert cmpMem(packet, addr bytes[0], length) == 0
    finally: dealloc(packet)
''',
    "valid-protection": r'''
for associated in [false, true]:
  for fc in [0x40B0'u16, 0xC0B0]:
    for enabled in [false, true]:
      prepare(fc, 20, associated, false, false, false, enabled)
      let before = bytes
      let beforeKey = key
      doAssert rxu_cntrl_frame_handle(addr mpdu) == 0
      doAssert managementCalls == 1 and keySelections == 0 and micCalls == 0
      doAssert key == beforeKey and managementCounter == default(KeyReplayCounterView)
      doAssert bytes == before and interrupts == enabled
for fc in [0x40A0'u16, 0x40C0, 0x40D0, 0xC0D0]:
  for category in [0'u8, 3, 5, 6, 8, 9, 10, 126]:
    for windowed in [false, true]:
      for enabled in [false, true]:
        prepare(fc, 28, true, true, false, false, enabled, category, windowed = windowed)
        let before = bytes
        let beforeKey = key
        doAssert rxu_cntrl_frame_handle(addr mpdu) == 0
        doAssert managementCalls == 1 and keySelections == 1
        doAssert lastProtection == (if (fc and 0xFC) in [0xA0'u16, 0xC0'u16]:
          rxMgtVerifiedCcmp else: rxMgtProtectionUnknown)
        doAssert managementCounter.pnLow != 0 or managementCounter.pnHigh != 0
        doAssert key == beforeKey and bytes == before and interrupts == enabled
''',
}


@pytest.mark.parametrize("mode", ["checked", "release", "asan", "firmware"])
@pytest.mark.parametrize("case", CASES)
def test_management_protection(case: str, mode: str, tmp_path: Path) -> None:
    run_program(tmp_path, mode, source() + CASES[case])
