"""Keep BIP validation and its replay commit bound to the collected RX key."""

from pathlib import Path

import pytest

from test_wifi_auth_frames import layouts
from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program
from test_wifi_mfp_control import PLATFORM, RX_CONTEXT, RX_MIC_MODEL


def source() -> str:
    code = "var interrupts, expectedIrq: bool\nvar onMic: proc()\n" + PLATFORM
    code += layouts("RxStationIdentity") + r'''
type
  VifKeySlotView = Key
  RxlEnv = object
    submittedHead: pointer
var
  rxKeyRevision = 1'u64
  rxKeyLastChanged: array[19, uint64]
  rxStationIdentities: array[1, RxStationIdentity]
  descriptor: uint8
  sessionCurrent: bool
  lower: RxlEnv
proc irqSave(): uint32 =
  result = interrupts.uint32 * 8
  interrupts = false
proc irqRestore(saved: uint32) = interrupts = (saved and 8) != 0
proc rxMgtKeyIndex(key: pointer): int =
  for vif in 0..<MAX_VIFS:
    for slot in 0..<6:
      if key == (addr vifs[vif].slots[slot]): return 7 + vif * 6 + slot
  -1
proc rxMpduDescIndex(desc: pointer): int =
  if desc == (addr descriptor): 0 else: -1
proc rxStationCurrent(desc: pointer): bool = sessionCurrent
proc rxlCntrlEnvView(): ptr RxlEnv = addr lower
proc rxl_timer_int_handler() = discard
'''
    original_mic = procedure(code, "mfp_compute_bip")
    code = code.replace(original_mic, original_mic.replace("  computedMic\n", r'''
  doAssert interrupts == expectedIrq, "MIC calculation changed interrupt state"
  if onMic != nil:
    let callback = onMic
    onMic = nil
    callback()
  computedMic
'''), 1)
    upper = (FW / "rx_upper.nim").read_text()
    code += procedure(upper, "rxKeyChange") + procedure(upper, "rxKeyCurrent")
    code += procedure((FW / "kernel_mac_channel.nim").read_text(), "mfp_is_robust_frame")
    code += RX_CONTEXT + RX_MIC_MODEL
    policy = (FW / "crypto_mfp_hsu.nim").read_text()
    if "proc mfpIgnoreRxMgmtFrame(" in policy:
        code += procedure(policy, "mfpIgnoreRxMgmtFrame")
    code += procedure(policy, "mfp_ignore_mgmt_frame")
    if "proc mfpIgnoreRxMgmtFrame(" not in policy:
        code += r'''
proc mfpIgnoreRxMgmtFrame(desc, param, frame: pointer; length: uint16;
                          upload, flags: ptr uint8): bool =
  mfp_ignore_mgmt_frame(param, frame, length, upload, flags)
'''
    return code + r'''
var
  frame: array[44, uint8]
  policyEnv: MfpMgmtFramePolicyView
  upload, flags: uint8
  selectedVif, selectedKey: int
proc selected(): ptr Key = addr vifs[selectedVif].slots[selectedKey]
proc setup(vif, slot: int; enabled: bool) =
  vifs = default(typeof(vifs))
  frame = default(typeof(frame))
  selectedVif = vif
  selectedKey = slot
  vifs[vif].keys.groupKeyPtr = 1
  stations[0].capabilityFlags = 8
  selected().installed = 1
  sessionCurrent = true
  rxKeyRevision = 1
  rxKeyLastChanged = default(typeof(rxKeyLastChanged))
  rxStationIdentities[0].keyRevision = 1
  interrupts = enabled
  expectedIrq = enabled
  onMic = nil
  micCalls = 0
  computedMic = 0x0123456789ABCDEF'u64
  policyEnv = MfpMgmtFramePolicyView(frameCtrl: 0xC0, bodyOffset: 24,
                                    staIdx: 0, vifIdx: vif.uint8, flags: 1)
  mfpRxHeader = RxSwDescView(mpduLengthBytes: 44)
  mfpRxFrame = addr frame[0]
  let mmie = mmieAt(addr frame[26])
  mmie[] = MmIeView(ie: Ie(id: 76, len: 16), keyId: slot.uint16)
  mmie.ipn[0] = 3
  for i in 0..<8: mmie.mic[i] = ((computedMic shr (i * 8)) and 255).uint8
  upload = 1
  flags = 0xA0
proc receive(legacy = false): bool =
  if legacy:
    mfp_ignore_mgmt_frame(addr policyEnv, addr frame[0], 44, addr upload, addr flags)
  else:
    mfpIgnoreRxMgmtFrame(addr descriptor, addr policyEnv, addr frame[0],
                        44, addr upload, addr flags, rxUploadGeneration(addr descriptor))
'''


CASES = {
    "legacy_revision_wrap": r'''
rxKeyRevision = high(uint64)
rxKeyLastChanged[rxMgtKeyIndex(selected())] = 1
onMic = proc() = rxKeyChange(selected())
doAssert receive(true), "legacy BIP accepted a wrapped key revision"
doAssert upload == 0 and selected().replayCounters[0].pnLow == 0
''',
    "queued_key_delete": r'''
rxKeyChange(selected())
selected().installed = 0
vifs[selectedVif].keys.groupKeyPtr = 0
doAssert receive(), "missing IGTK bypassed protection for a PMF peer"
doAssert upload == 0 and micCalls == 0
doAssert selected().replayCounters[0].pnLow == 0
''',
    "queued_key_change": r'''
rxKeyChange(selected())
let before = frame
doAssert receive(), "queued BIP frame used a replacement key"
doAssert upload == 0 and micCalls == 0
doAssert selected().replayCounters[0].pnLow == 0 and frame == before
''',
    "unrelated_key": r'''
rxKeyChange(addr vifs[1 - selectedVif].slots[selectedKey])
doAssert not receive() and upload == 1 and micCalls == 1
doAssert selected().replayCounters[0].pnLow == 4
''',
    "fresh_capture": r'''
rxKeyChange(selected())
rxStationIdentities[0].keyRevision = rxKeyRevision
doAssert not receive() and upload == 1 and micCalls == 1
doAssert selected().replayCounters[0].pnLow == 4
''',
    "key_change_during_mic": r'''
let before = frame
onMic = proc() =
  rxKeyChange(selected())
  selected().replayCounters[0].pnLow = 77
doAssert receive(), "BIP committed after its key changed"
doAssert upload == 0 and micCalls == 1 and frame == before
doAssert selected().replayCounters[0].pnLow == 77
''',
    "delete_during_mic": r'''
onMic = proc() =
  rxKeyChange(selected())
  selected().installed = 0
doAssert receive() and upload == 0 and micCalls == 1
doAssert selected().replayCounters[0].pnLow == 0
''',
    "session_change_during_mic": r'''
onMic = proc() = sessionCurrent = false
doAssert receive() and upload == 0 and micCalls == 1
doAssert selected().replayCounters[0].pnLow == 0
''',
    "replay_advance_during_mic": r'''
onMic = proc() = selected().replayCounters[0].pnLow = 9
doAssert receive(), "BIP replay commit moved the counter backwards"
doAssert upload == 0 and micCalls == 1
doAssert selected().replayCounters[0].pnLow == 9
''',
    "legacy_key_change": r'''
onMic = proc() = rxKeyChange(selected())
doAssert receive(true), "legacy BIP entry committed after its key changed"
doAssert upload == 0 and selected().replayCounters[0].pnLow == 0
''',
}


@pytest.mark.parametrize("case", CASES)
@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_bip_key_revision(tmp_path: Path, case: str, mode: str) -> None:
    checks = "\nfor vif in 0..<2:\n  for slot in 4..5:\n    for enabled in [false, true]:\n"
    checks += "      setup(vif, slot, enabled)\n"
    checks += "".join("      " + line + "\n" for line in CASES[case].strip().splitlines())
    checks += "      doAssert interrupts == enabled and flags == 0xA0\n"
    run_program(tmp_path, mode, source() + checks)
