"""Check BIP's wire counter limit and interrupt-safe reservation in production code."""

from pathlib import Path

import pytest

from test_wifi_auth_frames import layouts
from test_wifi_aes_cmac import procedure
from test_wifi_disconnect_tx import FW
from test_wifi_message_allocation import run_program


PLATFORM = r'''
type
  HostTxDescView = object
    vifIdx, staInfoIdx: uint8
  Keys = object
    groupKeyPtr: pointer
  Vif = object
    keys: Keys
    slots: array[6, VifKeySlotView]
const MAX_VIFS = 2
var
  vifs: array[MAX_VIFS, Vif]
  interrupts, expectedIrq: bool
  saves, restores, micCalls: int
  onRestore: proc()
  onMic: proc()
  lease: uint32
  sessionCurrent: bool
  rxKeyRevision = 1'u64
  rxKeyLastChanged: array[19, uint64]
proc irqSave(): uint32 =
  inc saves
  result = interrupts.uint32 * 8
  interrupts = false
proc irqRestore(saved: uint32) =
  inc restores
  interrupts = (saved and 8) != 0
  if interrupts and onRestore != nil:
    let callback = onRestore
    onRestore = nil
    callback()
proc hostTxDescAt(p: pointer): ptr HostTxDescView = cast[ptr HostTxDescView](p)
proc txSecurityBind(d: ptr HostTxDescView; key: ptr VifKeySlotView; bip: bool): bool = true
proc vifChannelForIdx(i: uint8): ptr Vif = addr vifs[i]
proc vifKeyPointers(v: ptr Vif): ptr Keys = addr v.keys
proc vifKeySlot(v: ptr Vif; i: uint): ptr VifKeySlotView = addr v.slots[i]
proc rxMgtKeyIndex(key: pointer): int =
  for vif in 0..<MAX_VIFS:
    for slot in 0..<6:
      if key == (addr vifs[vif].slots[slot]): return 7 + vif * 6 + slot
  -1
proc txlFrameLeaseToken(desc: ptr HostTxDescView): uint32 = lease
proc txlFrameLeaseMatches(desc: ptr HostTxDescView; token: uint32): bool = lease == token
proc txlFrameSessionCurrent(desc: ptr HostTxDescView): bool = sessionCurrent
proc mmieAt(p: pointer): ptr MmIeView = cast[ptr MmIeView](p)
proc ieCursorAfter(p: pointer; n: uint): pointer = cast[pointer](cast[uint](p) + n)
proc mfp_compute_bip(key, frame: pointer; length, header: uint32): uint64 =
  inc micCalls
  doAssert interrupts == expectedIrq, "MIC calculation extended the IRQ critical section"
  doAssert key != nil and frame != nil and header == 24 and length >= 42
  let before = cast[ptr VifKeySlotView](key).keyMaterial
  if onMic != nil:
    let callback = onMic
    onMic = nil
    callback()
  doAssert cast[ptr VifKeySlotView](key).keyMaterial == before,
    "BIP MIC read a mutable key instead of its captured material"
  0x0123456789ABCDEF'u64
'''

CHECKS = r'''
const MaxIpn = 0xFFFFFFFFFFFF'u64
var
  descriptor: HostTxDescView
  frame: array[76, uint8]
  selectedVif, selectedSlot: int
proc selected(): ptr VifKeySlotView = addr vifs[selectedVif].slots[selectedSlot]
proc setup(vif, slot: int; enabled: bool; pn: uint64) =
  vifs = default(typeof(vifs))
  selectedVif = vif
  selectedSlot = slot
  selected().installed = 1
  selected().cipherType = 5
  selected().staIdx = slot.uint8
  selected().pnLow = (pn and 0xFFFFFFFF'u64).uint32
  selected().pnHigh = (pn shr 32).uint32
  for i in 0..<16: selected().keyMaterial[i] = (i + 16).uint8
  vifs[vif].keys.groupKeyPtr = selected()
  descriptor.vifIdx = vif.uint8
  for b in frame.mitems: b = 0x5A
  interrupts = enabled
  expectedIrq = enabled
  saves = 0
  restores = 0
  micCalls = 0
  onRestore = nil
  onMic = nil
  lease = 1
  sessionCurrent = true
  rxKeyRevision = 1
  rxKeyLastChanged = default(typeof(rxKeyLastChanged))
proc counter(): uint64 = selected().pnLow.uint64 or (selected().pnHigh.uint64 shl 32)
proc wireIpn(bytes: var array[76, uint8]): uint64 =
  let mmie = mmieAt(addr bytes[42])
  for i in 0..<6: result = result or (mmie.ipn[i].uint64 shl (8 * i))
proc append(): uint32 = mfp_add_mgmt_mic(addr descriptor, addr frame[16], 26)
proc replaceKey() =
  inc rxKeyRevision
  rxKeyLastChanged[rxMgtKeyIndex(selected())] = rxKeyRevision
  for i in 0..<16: selected().keyMaterial[i] = (i + 64).uint8
  selected().pnLow = 77
  selected().pnHigh = 0
proc checkFrame(pn: uint64) =
  let mmie = mmieAt(addr frame[42])
  doAssert mmie.ie.id == 76 and mmie.ie.len == 16
  doAssert mmie.keyId == selectedSlot.uint16 and wireIpn(frame) == pn
  for i in 0..<8:
    doAssert mmie.mic[i] == ((0x0123456789ABCDEF'u64 shr (8 * i)) and 255).uint8
  for i in 0..<42: doAssert frame[i] == 0x5A
  for i in 60..<frame.len: doAssert frame[i] == 0x5A
'''

CASES = {
    "key_change_during_mic": r'''
setup(vif, slot, enabled, 41)
onMic = replaceKey
doAssert append() == 0, "BIP accepted a key replacement during MIC calculation"
doAssert counter() == 77 and micCalls == 1 and interrupts == enabled
''',
    "key_change_at_restore": r'''
if enabled:
  setup(vif, slot, enabled, 41)
  onRestore = replaceKey
  doAssert append() == 0, "BIP accepted a key replaced after counter reservation"
  doAssert counter() == 77 and interrupts
''',
    "key_deleted_during_mic": r'''
setup(vif, slot, enabled, 41)
onMic = proc() =
  replaceKey()
  selected().installed = 0
  vifs[vif].keys.groupKeyPtr = nil
doAssert append() == 0 and selected().installed == 0 and counter() == 77
''',
    "unrelated_key_change": r'''
setup(vif, slot, enabled, 41)
onMic = proc() =
  inc rxKeyRevision
  rxKeyLastChanged[7 + (1 - vif) * 6 + slot] = rxKeyRevision
doAssert append() == 18 and counter() == 42
checkFrame(42)
''',
    "key_clock_wrap": r'''
setup(vif, slot, enabled, 41)
rxKeyRevision = high(uint64)
rxKeyLastChanged[rxMgtKeyIndex(selected())] = 1
onMic = proc() =
  rxKeyRevision = 1
  for changed in rxKeyLastChanged.mitems: changed = 1
doAssert append() == 0, "BIP accepted a wrapped key revision"
doAssert counter() == 42
''',
    "frame_reused_during_mic": r'''
setup(vif, slot, enabled, 41)
onMic = proc() =
  inc lease
  for byte in frame.mitems: byte = 0xB7
doAssert append() == 0, "BIP accepted a replacement frame lease"
for byte in frame: doAssert byte == 0xB7, "BIP wrote into a replacement frame"
''',
    "frame_reused_at_restore": r'''
if enabled:
  setup(vif, slot, enabled, 41)
  onRestore = proc() =
    inc lease
    for byte in frame.mitems: byte = 0xB7
  doAssert append() == 0
  for byte in frame: doAssert byte == 0xB7
''',
    "frame_session_retired": r'''
setup(vif, slot, enabled, 41)
onMic = proc() = sessionCurrent = false
doAssert append() == 0, "BIP accepted a retired frame session"
''',
    "invalid_key_context": r'''
for invalid in 0..<4:
  setup(vif, slot, enabled, 41)
  case invalid
  of 0: selected().installed = 0
  of 1: selected().cipherType = 2
  of 2: selected().staIdx = 3
  else: selected().staIdx = (9 - slot).uint8
  let beforeFrame = frame
  let beforeKey = selected()[]
  doAssert append() == 0, "BIP reserved a counter from invalid key metadata"
  doAssert frame == beforeFrame and selected()[] == beforeKey and micCalls == 0
''',
    "boundaries": r'''
for pn in [0'u64, 255'u64, 0xFFFFFFFE'u64, 0xFFFFFFFF'u64, 0x100000000'u64,
           MaxIpn - 2, MaxIpn - 1, MaxIpn, MaxIpn + 1, high(uint64)]:
  setup(vif, slot, enabled, pn)
  let beforeFrame = frame
  var expectedVifs = vifs
  if pn < MaxIpn:
    doAssert append() == 18
    checkFrame(pn + 1)
    expectedVifs[vif].slots[slot].pnLow = ((pn + 1) and 0xFFFFFFFF'u64).uint32
    expectedVifs[vif].slots[slot].pnHigh = ((pn + 1) shr 32).uint32
    doAssert micCalls == 1
  else:
    doAssert append() == 0, "BIP exhausted the 48-bit wire counter"
    doAssert frame == beforeFrame and micCalls == 0
  doAssert vifs == expectedVifs
  let sections = if pn < MaxIpn: 2 else: 1
  doAssert saves == sections and restores == sections and interrupts == enabled
''',
    "last_value_once": r'''
setup(vif, slot, enabled, MaxIpn - 1)
doAssert append() == 18
checkFrame(MaxIpn)
let beforeFrame = frame
let beforeKey = selected()[]
for attempt in 0..<3:
  doAssert append() == 0, "BIP reused the exhausted wire counter"
  doAssert selected()[] == beforeKey and frame == beforeFrame
doAssert micCalls == 1 and saves == 5 and restores == 5
doAssert interrupts == enabled
''',
    "pending_interrupt": r'''
if enabled:
  setup(vif, slot, enabled, MaxIpn - 2)
  var other: array[76, uint8]
  for b in other.mitems: b = 0x5A
  var nestedResult: uint32
  var fired = false
  onRestore = proc() =
    fired = true
    doAssert counter() == MaxIpn - 1, "interrupt observed an unreserved counter"
    nestedResult = mfp_add_mgmt_mic(addr descriptor, addr other[16], 26)
  doAssert append() == 18
  doAssert fired and nestedResult == 18
  checkFrame(MaxIpn - 1)
  doAssert wireIpn(other) == MaxIpn and counter() == MaxIpn
  doAssert micCalls == 2 and saves == 4 and restores == 4 and interrupts
''',
    "invalid_input": r'''
setup(vif, slot, enabled, 41)
let beforeKey = selected()[]
let beforeFrame = frame
for length in [0'u32, 23, 65518, high(uint32)]:
  doAssert mfp_add_mgmt_mic(addr descriptor, addr frame[16], length) == 0
doAssert mfp_add_mgmt_mic(nil, addr frame[16], 26) == 0
doAssert mfp_add_mgmt_mic(addr descriptor, nil, 26) == 0
descriptor.vifIdx = MAX_VIFS.uint8
doAssert append() == 0
descriptor.vifIdx = vif.uint8
vifs[vif].keys.groupKeyPtr = nil
doAssert append() == 0
doAssert frame == beforeFrame and selected()[] == beforeKey and micCalls == 0
doAssert saves == 1 and restores == 1 and interrupts == enabled
''',
}


def source(mode: str, actual_leases: bool = False) -> str:
    code = layouts("KeyReplayCounterView", "VifKeySlotView", "MacIeView", "MmIeView")
    code += PLATFORM
    if actual_leases:
        for name in ["txlFrameLeaseToken", "txlFrameLeaseMatches", "txlFrameSessionCurrent"]:
            code = code.replace(procedure(code, name), "", 1)
        code += "\nconst STA_MGMT_FREE_STAS = 5\n" + layouts("TxFrameIdentity")
        code += r'''
const InvalidFrameDescIndex = high(uint32)
var
  ownedDescriptor: pointer
  mmBcnGeneration: uint32
  rxVifEpochs: array[MAX_VIFS, uint32]
  stationEpochs: array[STA_MGMT_FREE_STAS, uint32]
  txFrameIdentities: array[1, TxFrameIdentity]
proc txl_frame_desc_index(p: pointer): uint32 =
  if p == ownedDescriptor: 0'u32 else: InvalidFrameDescIndex
proc staDeleteEpoch(i: uint8): uint32 =
  if i < STA_MGMT_FREE_STAS.uint8: stationEpochs[i] else: 0
'''
        tx = (FW / "tx_layer.nim").read_text()
        for name in ["txlFrameLeaseToken", "txlFrameLeaseMatches", "txlFrameIdentityCurrent",
                     "txlFrameSessionCurrent"]:
            code += procedure(tx, name)
    if mode == "release":
        code += "\n{.push checks: off.}\n"
    code += procedure((FW / "crypto_mfp_hsu.nim").read_text(), "mfp_add_mgmt_mic")
    if mode == "release":
        code += "\n{.pop.}\n"
    return code + CHECKS


@pytest.mark.parametrize("case", CASES)
@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_bip_tx_counter(tmp_path: Path, case: str, mode: str) -> None:
    code = source(mode)
    code += "\nfor vif in 0..<2:\n  for slot in 4..5:\n    for enabled in [false, true]:\n"
    code += "".join("      " + line + "\n" for line in CASES[case].strip().splitlines())
    run_program(tmp_path, mode, code)


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_bip_tx_actual_frame_lease(tmp_path: Path, mode: str) -> None:
    checks = r'''
for enabled in [false, true]:
  for change in 0..<5:
    setup(0, 4, enabled, 41)
    descriptor.staInfoIdx = 0
    ownedDescriptor = addr descriptor
    rxVifEpochs = [11'u32, 12'u32]
    stationEpochs = [21'u32, 22, 23, 24, 25]
    txFrameIdentities[0] = TxFrameIdentity(leased: true, generation: 3,
      vifEpochs: rxVifEpochs, stationEpochs: stationEpochs)
    onMic = proc() =
      case change
      of 0:
        inc txFrameIdentities[0].generation
        for byte in frame.mitems: byte = 0xB7
      of 1: txFrameIdentities[0].leased = false
      of 2: inc rxVifEpochs[0]
      of 3: inc stationEpochs[0]
      else: inc rxVifEpochs[1]
    let accepted = append() == 18
    doAssert accepted == (change == 4), "BIP ignored the production frame-lease check"
    doAssert counter() == 42 and interrupts == enabled
    if change == 0:
      for byte in frame: doAssert byte == 0xB7
    elif change == 4:
      checkFrame(42)
    else:
      doAssert mmieAt(addr frame[42]).mic == default(array[8, uint8])
'''
    run_program(tmp_path, mode, source(mode, actual_leases=True) + checks)
