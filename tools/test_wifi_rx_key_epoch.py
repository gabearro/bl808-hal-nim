"""Keep completed RX frames bound to the key revision they arrived under."""

from pathlib import Path

import pytest

from test_wifi_auth_frames import layouts
from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program
from test_wifi_rx_decapsulation import CHECKS, dispatch_source
from test_wifi_station_keys import WRITE_PLATFORM, harness, proc_body


def source() -> str:
    code = layouts("KeyReplayCounterView") + "var interrupts = true\n" + dispatch_source()
    code = code.replace("  Key = object\n",
                        "  Key = object\n    replayCounters: array[8, KeyReplayCounterView]\n"
                        "    installed: uint8\n", 1)
    code = code.replace("proc rxKeyCurrent(desc, key: pointer): bool = true\n", "", 1)
    code = code.replace(
        "proc rxStationCurrent(p: pointer): bool = sessionCurrent\n",
        "proc rxStationCurrent(desc: pointer): bool\n"
        "proc rxKeyCurrent(desc, key: pointer): bool\n",
        1,
    ).replace("proc irqSave(): uint32 = 0\n", r'''
proc irqSave(): uint32 =
  result = interrupts.uint32 * 8
  interrupts = false
''', 1).replace("proc irqRestore(flags: uint32) = discard\n",
                 "proc irqRestore(flags: uint32) = interrupts = (flags and 8) != 0\n", 1)
    code = code.replace(
        "template nimFwDbgRxuIpv4Preupload(args: varargs[untyped]) = discard\n",
        "proc nimFwDbgRxuIpv4Preupload(p: pointer; headerLen, tid: uint8; length: uint16)\n",
        1,
    )
    code += layouts("RxStationIdentity") + r'''
var
  rxStationIdentities: array[41, RxStationIdentity]
  rxUploadEpochs: array[41, uint32]
  rxVifEpochs: array[MAX_VIFS, uint32]
  stationEpochs: array[STA_INFO_TAB_ENTRIES, uint32]
  rxKeyRevision = 1'u64
  rxKeyLastChanged: array[19, uint64]
  rxMgtReplayStates: array[19, KeyReplayCounterView]
  rxMgtReplayValid: array[19, bool]
  otherKey: Key
  harvestCalls: int
  onHarvest: proc()
  changeDuringTrace: bool
type RxlEnv = object
  submittedHead: pointer
var lower: RxlEnv
proc rxlCntrlEnvView(): ptr RxlEnv = addr lower
proc rxMpduDescIndex(p: pointer): int = (if p == (addr mpdu): 0 else: -1)
proc staDeleteEpoch(i: uint8): uint32 = stationEpochs[i]
proc rxMgtKeyIndex(p: pointer): int =
  if p == (addr key): 0
  elif p == (addr otherKey): 1
  else: -1
proc rxl_timer_int_handler() =
  inc harvestCalls
  if onHarvest != nil:
    let callback = onHarvest
    onHarvest = nil
    callback()
'''
    lower = (FW / "rx_layer.nim").read_text()
    for name in ["rxCaptureStation", "rxIdentityCurrent", "rxStationCurrent"]:
        code += procedure(lower, name)
    upper = (FW / "rx_upper.nim").read_text()
    if "proc rxKeyChange(" in upper:
        code += procedure(upper, "rxKeyChange") + procedure(upper, "rxKeyCurrent")
        code += procedure(upper, "rxMgtReplayReset") + procedure(upper, "rxMgtReplayForget")
    else:
        code += r'''
proc rxKeyChange(p: pointer) =
  inc rxKeyRevision
  rxKeyLastChanged[rxMgtKeyIndex(p)] = rxKeyRevision
proc rxKeyCurrent(desc, key: pointer): bool = rxStationCurrent(desc)
'''
    code += r'''
proc nimFwDbgRxuIpv4Preupload(p: pointer; headerLen, tid: uint8; length: uint16) =
  if changeDuringTrace:
    changeDuringTrace = false
    rxKeyChange(addr key)
'''
    return code + CHECKS.split("# Unprotected IP", 1)[0] + r'''
proc prepare(fc: uint16) =
  let headerLen = rxu_cntrl_machdr_len_get(fc).int + (if (fc and 0x4000) != 0: 8 else: 0)
  setup(fc, headerLen, 40)
  key.installed = 1
  snapAt(headerLen, 0x0800)
  rxStationIdentities = default(typeof(rxStationIdentities))
  rxKeyLastChanged = default(typeof(rxKeyLastChanged))
  rxKeyRevision = 1
  harvestCalls = 0
  onHarvest = nil
  lower.submittedHead = addr mpdu
  changeDuringTrace = false
  interrupts = true
  rxCaptureStation(addr mpdu, sw.hwFlags)
'''


CASES = {
    "queued_frame": r'''
for fc in [0x4208'u16, 0x4288, 0x40D0]:
  prepare(fc)
  let before = stations[0].sequences
  rxKeyChange(addr key)
  doAssert rxu_cntrl_frame_handle(addr mpdu) == 0,
    "queued frame used replacement key state"
  doAssert replayCalls == 0 and transferred == 0 and prepared == 0
  doAssert stations[0].sequences == before
  doAssert interrupts
''',
    "unrelated_and_fresh": r'''
prepare(0x4208)
rxKeyChange(addr otherKey)
doAssert rxu_cntrl_frame_handle(addr mpdu) == 1
doAssert transferred == 1 and replayCalls == 1
prepare(0x4208)
rxKeyChange(addr key)
rxCaptureStation(addr mpdu, sw.hwFlags)
doAssert rxu_cntrl_frame_handle(addr mpdu) == 1
doAssert transferred == 1 and replayCalls == 1
''',
    "plaintext": r'''
prepare(0x0208)
rxKeyChange(addr key)
doAssert rxu_cntrl_frame_handle(addr mpdu) == 1
doAssert transferred == 1 and replayCalls == 0
''',
    "mid_receive_change": r'''
prepare(0x4208)
let before = stations[0].sequences
changeDuringTrace = true
doAssert rxu_cntrl_frame_handle(addr mpdu) == 0
doAssert replayCalls == 0 and transferred == 0
doAssert stations[0].sequences == before and interrupts
''',
    "harvest_order": r'''
prepare(0x4208)
rxStationIdentities = default(typeof(rxStationIdentities))
onHarvest = proc() = rxCaptureStation(addr mpdu, sw.hwFlags)
rxKeyChange(addr key)
doAssert harvestCalls == 1
doAssert rxStationCurrent(addr mpdu)
doAssert not rxKeyCurrent(addr mpdu, addr key),
  "completed descriptors were captured after key publication"
doAssert rxu_cntrl_frame_handle(addr mpdu) == 0
''',
    "wrap": r'''
prepare(0x4208)
rxKeyRevision = high(uint64)
rxCaptureStation(addr mpdu, sw.hwFlags)
rxKeyChange(addr otherKey)
doAssert rxKeyRevision == 1
doAssert not rxKeyCurrent(addr mpdu, addr key)
rxCaptureStation(addr mpdu, sw.hwFlags)
doAssert rxKeyCurrent(addr mpdu, addr key)
''',
    "key_lifecycle": r'''
prepare(0x4208)
rxMgtReplayReset(addr key)
doAssert not rxKeyCurrent(addr mpdu, addr key)
doAssert rxMgtReplayValid[0]
rxCaptureStation(addr mpdu, sw.hwFlags)
doAssert rxKeyCurrent(addr mpdu, addr key)
rxMgtReplayForget(addr key)
doAssert not rxMgtReplayValid[0]
doAssert not rxKeyCurrent(addr mpdu, addr key)
''',
    "inactive_key": r'''
for fc in [0x4208'u16, 0x40D0]:
  prepare(fc)
  rxKeyChange(addr key)
  key.installed = 0
  rxCaptureStation(addr mpdu, sw.hwFlags)
  doAssert not rxKeyCurrent(addr mpdu, addr key)
  doAssert rxu_cntrl_frame_handle(addr mpdu) == 0
  doAssert replayCalls == 0 and transferred == 0
''',
}


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("case", CASES)
def test_rx_key_revision(tmp_path: Path, mode: str, case: str) -> None:
    run_program(tmp_path, mode, source() + CASES[case])


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_hardware_key_revision_order(tmp_path: Path, mode: str) -> None:
    prefix = "var invalidateAtBoundary = false\nproc noteKeyChange(key: pointer)\n"
    note = r'''
proc noteKeyChange(key: pointer) =
  event("key", pointerAddrU32(key))
  if invalidateAtBoundary: inc rxVifEpochs[0]
'''
    code = harness(WRITE_PLATFORM, note,
                   proc_body((FW / "kernel_mac_channel.nim").read_text(), "mm_sec_machwkey_wr"))
    code = code.replace("proc rxKeyChange(key: pointer) = discard\n",
                        "proc rxKeyChange(key: pointer) = noteKeyChange(key)\n", 1)
    checks = r'''
for group in [false, true]:
  for enabled in [false, true]:
    setup(enabled)
    var req = requestFor(2, group)
    let expectedKey = if group:
      cast[pointer](vifKeySlotPtr(vifChannelForIdx(0), 0))
      else: cast[pointer](addr sta_info_tab[0].keyArea[0])
    doAssert mm_sec_machwkey_wr(addr req) != 0xFF
    doAssert events[0].kind == "wait"
    doAssert events[1] == ("key", pointerAddrU32(expectedKey), 0'u32)
    doAssert events[2].kind == "address" and events[3].kind == "material"
    doAssert irq == enabled
    setup(enabled)
    invalidateAtBoundary = true
    doAssert mm_sec_machwkey_wr(addr req) == 0xFF
    doAssert events.len == 2 and events[1].kind == "key"
    doAssert not installed and irq == enabled
    invalidateAtBoundary = false
'''
    run_program(tmp_path, mode, prefix + code + checks)
