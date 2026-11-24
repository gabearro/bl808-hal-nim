"""Check active-VIF beacon statistics and bounded callback-independent reads."""
from pathlib import Path
from textwrap import dedent

import pytest

from test_wifi_auth_frames import layouts
from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program

VIF = FW / "vif_management.nim"

PLATFORM = r'''
type
  CoListHdr = object
    next: ptr CoListHdr
  CoList = object
    first, last: ptr CoListHdr
''' + layouts("MmTimerView", "ChanTbttNodeView", "VifChannelView", "VifMgmtEnvView") + r'''
const
  MAX_VIFS = 2
  VIF_TYPE_STA = 0'u8
  VIF_TYPE_AP = 2'u8
type Record = tuple[kind: char, secondary: bool, message: string]
var
  env: VifMgmtEnvView
  vifs: array[3, VifChannelView]
  records: seq[Record]
  reads: seq[int]
  printEnabled, putsEnabled, secondary, interruptsEnabled, expectedIrq, snapshotActive: bool
  action: proc()
proc vifMgmtEnvView(): ptr VifMgmtEnvView = addr env
proc vifChannelAt(p: pointer): ptr VifChannelView =
  doAssert snapshotActive
  for index in 0 ..< vifs.len:
    if p == cast[pointer](addr vifs[index]):
      doAssert index < 2, "free VIF was sampled"
      reads.add(index)
      return addr vifs[index]
  raiseAssert "non-pool VIF"
proc irqSave(): uint32 =
  result = interruptsEnabled.uint32 * 8
  interruptsEnabled = false
  snapshotActive = true
proc irqRestore(saved: uint32) =
  interruptsEnabled = (saved and 8) != 0
  snapshotActive = false
{.emit: "#include <stdarg.h>\n#include <stdio.h>".}
template printBody(format: cstring; replacement: bool) =
  doAssert not snapshotActive and interruptsEnabled == expectedIrq
  var output: array[192, char]
  var count: cint
  {.emit: ["va_list args; va_start(args, ", format, "); ", count,
    " = vsnprintf((char*)", output, ", sizeof(", output, "), ",
    format, ", args); va_end(args);"].}
  doAssert count >= 0 and count < output.len.cint
  records.add(('p', replacement, $cast[cstring](addr output[0])))
  if action != nil:
    let callback = action
    action = nil
    callback()
proc printer(format: cstring) {.cdecl, varargs.} = printBody(format, false)
proc replacement(format: cstring) {.cdecl, varargs.} = printBody(format, true)
proc putter(text: cstring) {.cdecl.} =
  doAssert not snapshotActive and interruptsEnabled == expectedIrq
  records.add(('s', false, $text))
proc blOpsFunc(slot: int): pointer =
  case slot
  of 4:
    if not printEnabled: nil
    elif secondary: cast[pointer](replacement)
    else: cast[pointer](printer)
  of 8: (if putsEnabled: cast[pointer](putter) else: nil)
  else: raiseAssert "unexpected statistics slot"
proc snprintf(output: pointer; capacity: csize_t; format: cstring): cint
  {.importc, header: "<stdio.h>", varargs.}
proc pointerText(p: pointer): string =
  var output: array[64, char]
  discard snprintf(addr output[0], output.len.csize_t, "%p", p)
  $cast[cstring](addr output[0])
proc setup(irq = true) =
  env = default(typeof(env))
  vifs = default(typeof(vifs))
  env.activeList.first = cast[ptr CoListHdr](addr vifs[0])
  env.activeList.last = cast[ptr CoListHdr](addr vifs[1])
  env.freeList.first = cast[ptr CoListHdr](addr vifs[2])
  env.freeList.last = env.freeList.first
  vifs[0].next = addr vifs[1]
  vifs[0].vifType = 0
  vifs[0].beaconLossCount = high(uint32)
  vifs[0].beaconRxCount = 9
  vifs[0].tbttCount = 0x80000000'u32
  vifs[0].beaconLossWindow = 0x80000400'u32
  vifs[0].lastBeaconMacTime = high(uint32)
  vifs[1].vifType = 2
  vifs[2].vifType = 4
  records.setLen(0)
  reads.setLen(0)
  printEnabled = true
  putsEnabled = true
  secondary = false
  interruptsEnabled = irq
  expectedIrq = irq
  snapshotActive = false
  action = nil
proc expected(indices: openArray[int]): seq[Record] =
  for index in indices:
    let vif = vifs[index]
    if printEnabled:
      let name = if vif.vifType == 0: "STA" elif vif.vifType == 2: "AP" else: "Unknown"
      result.add(('p', false, "======== Vif " & pointerText(addr vifs[index]) & ": " & name & "========\r\n"))
      if vif.vifType == 0:
        result.add(('p', false, "    bcn_timeout:" & $vif.beaconLossCount & "\r\n"))
        result.add(('p', false, "    bcn_received:" & $vif.beaconRxCount & "\r\n"))
        let total = ((vif.beaconLossCount.uint64 + vif.beaconRxCount.uint64) and 0xFFFFFFFF'u64).uint32
        result.add(('p', false, "    bcn_received && timeout counter:" & $total & "\r\n"))
        result.add(('p', false, "    bcn_tbtt counter:" & $vif.tbttCount & "\r\n"))
        result.add(('p', false, "    bcn_lost_max_interval:" & $(vif.beaconLossWindow div 1024) & "ms\r\n"))
        result.add(('p', false, "    bcn_last_received:" & $(vif.lastBeaconMacTime div 1024) & "ms\r\n"))
    if putsEnabled:
      result.add(('s', false, "------------------------------------\r\n"))
'''

CASES = {
    "active_list_and_types": r'''
for irq in [false, true]:
  for kind in [0'u8, 1, 2, 4, 255]:
    setup(irq)
    vifs[1].vifType = kind
    let wanted = expected([0, 1])
    vif_mgmt_statistic_dump()
    doAssert records == wanted and reads == @[0, 1]
    doAssert interruptsEnabled == irq and not snapshotActive
setup()
env.activeList.first = nil
vif_mgmt_statistic_dump()
doAssert records.len == 0 and reads.len == 0
''',
    "snapshot_and_callback_reload": r'''
for irq in [false, true]:
  setup(irq)
  var wanted = expected([0, 1])
  var first = true
  for record in wanted.mitems:
    if record.kind == 'p':
      record.secondary = not first
      first = false
  proc mutate() =
    doAssert not snapshotActive
    vifs = default(typeof(vifs))
    env.activeList.first = nil
    secondary = true
  action = mutate
  vif_mgmt_statistic_dump()
  doAssert records == wanted and reads == @[0, 1]
''',
    "missing_callbacks_and_bounded_cycles": r'''
for printing in [false, true]:
  for putting in [false, true]:
    setup()
    printEnabled = printing
    putsEnabled = putting
    let wanted = expected([0, 1])
    vif_mgmt_statistic_dump()
    doAssert records == wanted and reads == @[0, 1]
setup()
vifs[0].next = addr vifs[0]
let wanted = expected([0])
vif_mgmt_statistic_dump()
doAssert records == wanted and reads == @[0]
''',
}

STA_EVIDENCE = r'''
const STA_MGMT_FREE_STAS = 4
var
  peers: array[STA_MGMT_FREE_STAS, tuple[valid, instNbr: uint8]]
  mmBeaconProbeEpochs: array[MAX_VIFS, uint32]
  macReads: int
proc vifChannelForIdx(index: uint8): ptr VifChannelView =
  doAssert snapshotActive and not interruptsEnabled
  addr vifs[index]
proc staInfoForIdx(index: uint8): ptr typeof(peers[0]) =
  doAssert snapshotActive and not interruptsEnabled
  addr peers[index]
proc macTimeNow(): uint32 =
  doAssert snapshotActive and not interruptsEnabled
  inc macReads
  42
'''

EVIDENCE_CHECKS = r'''
setup()
vifs[0].state = 1
vifs[0].staIdx = 2
vifs[0].probeCount = 17
vifs[0].chanCtxt = cast[pointer](1)
vifs[1].state = 1
vifs[1].vifIdx = 1
vifs[1].staIdx = 3
vifs[1].chanCtxt = cast[pointer](2)
peers[2] = (valid: 1'u8, instNbr: 0'u8)
peers[3] = (valid: 1'u8, instNbr: 1'u8)
mmBeaconProbeEpochs = [14'u32, 99'u32]
let sample = nimFwSnapshotStaBeaconEvidence()
doAssert interruptsEnabled and not snapshotActive and macReads == 1
doAssert sample.valid and sample.vifIndex == 0 and sample.stationIndex == 2
doAssert sample.received == 9 and sample.lastBeaconUs == high(uint32)
doAssert sample.sampleUs == 42 and sample.probeEpoch == 14 and sample.missed == 17

vifs[1].vifType = VIF_TYPE_STA
doAssert not nimFwSnapshotStaBeaconEvidence().valid # ambiguous active peer
vifs[1].state = 0
peers[2].instNbr = 1
doAssert not nimFwSnapshotStaBeaconEvidence().valid # replaced station owner
peers[2].instNbr = 0
vifs[0].chanCtxt = nil
doAssert not nimFwSnapshotStaBeaconEvidence().valid # already detached
vifs[0].chanCtxt = cast[pointer](1)
vifs[0].staIdx = 255
doAssert not nimFwSnapshotStaBeaconEvidence().valid # no station slot
doAssert interruptsEnabled and not snapshotActive and macReads == 1
'''


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_station_beacon_evidence(tmp_path: Path, mode: str) -> None:
    vif_source = VIF.read_text()
    start = vif_source.index("  type NimFwStaBeaconEvidence")
    end = vif_source.index("\nproc vif_mgmt_statistic_dump", start)
    run_program(tmp_path, mode, PLATFORM + STA_EVIDENCE +
                dedent(vif_source[start:end]) + EVIDENCE_CHECKS)


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
@pytest.mark.parametrize("case", CASES)
def test_vif_statistics(tmp_path: Path, mode: str, case: str) -> None:
    run_program(tmp_path, mode, PLATFORM + procedure(VIF.read_text(), "vif_mgmt_statistic_dump") + CASES[case])
