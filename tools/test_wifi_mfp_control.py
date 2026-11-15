"""Execute MFP classification and admission logic; stub only the BIP MIC."""

from pathlib import Path
import re
import shutil
import subprocess

import pytest


ROOT = Path(__file__).resolve().parents[1]
FW = ROOT / "src/bl808/wifi/fw"

PLATFORM = r"""
type
  KeyReplayCounterView = object
    pnLow, pnHigh: uint32
    bitmap: array[2, uint32]
  Key = object
    replayCounters: array[8, KeyReplayCounterView]
    installed: uint8
  Keys = object
    groupKeyPtr: uint32
  Vif = object
    keys: Keys
    slots: array[6, Key]
  Sta = object
    macAddr: array[6, uint8]
    capabilityFlags: uint32
  HostTxDescView = object
    vifIdx, staInfoIdx: uint8
  Ie {.packed.} = object
    id, len: uint8
  MmIeView {.packed.} = object
    ie: Ie
    keyId: uint16
    ipn: array[6, uint8]
    mic: array[8, uint8]
  MfpMgmtFramePolicyView {.packed.} = object
    frameCtrl: uint16
    prefix: array[6, uint8]
    bodyOffset, staIdx, vifIdx: uint8
    padding: array[25, uint8]
    flags: uint8
const
  STA_INFO_TAB_ENTRIES = 7
  MAX_VIFS = 2
var
  vifs: array[2, Vif]
  stations: array[7, Sta]
  computedMic: uint64
  micCalls: int
  micKey, micFrame: pointer
  micLength, micBodyOffset: uint32
proc vifChannelForIdx(i: uint8): ptr Vif = addr vifs[i]
proc vifKeyPointers(v: ptr Vif): ptr Keys = addr v.keys
proc vifKeySlot(v: ptr Vif; i: uint): ptr Key = addr v.slots[i]
proc staInfoForIdx(i: uint8): ptr Sta = addr stations[i]
proc hostTxDescAt(p: pointer): ptr HostTxDescView = cast[ptr HostTxDescView](p)
proc mfpMgmtFramePolicyView(p: pointer): ptr MfpMgmtFramePolicyView =
  cast[ptr MfpMgmtFramePolicyView](p)
proc mmieAt(p: pointer): ptr MmIeView = cast[ptr MmIeView](p)
proc mmieMicWords(p: ptr MmIeView): ptr UncheckedArray[uint32] =
  cast[ptr UncheckedArray[uint32]](addr p.mic[0])
proc ieCursorAfter(p: pointer; n: uint): pointer = cast[pointer](cast[uint](p) + n)
proc mac_ie_find(p: pointer; length: uint32; id: uint8): pointer =
  let bytes = cast[ptr UncheckedArray[uint8]](p)
  var at = 0'u32
  while at + 2 <= length:
    let size = bytes[at + 1].uint32 + 2
    if size > length - at: return nil
    if bytes[at] == id: return ieCursorAfter(p, at.uint)
    at += size
proc mfp_compute_bip(key, frame: pointer; length, offset: uint32): uint64 =
  inc micCalls
  micKey = key
  micFrame = frame
  micLength = length
  micBodyOffset = offset
  let mmie = mmieAt(ieCursorAfter(frame, length.uint - 18))
  doAssert mmie.mic == default(typeof(mmie.mic)), "MIC field must be zero while computing"
  computedMic
"""

KEY_CONTEXT = r"""
when not declared(rxKeyRevision):
  var rxKeyRevision = 1'u64
var rxKeyLastChanged: array[19, uint64]
proc rxMgtKeyIndex(key: pointer): int =
  for vif in 0..<MAX_VIFS:
    for slot in 0..<6:
      if key == (addr vifs[vif].slots[slot]): return 7 + vif * 6 + slot
  -1
proc rxKeyCurrent(desc, key: pointer): bool = true
when not declared(irqSave):
  var interrupts = true
  proc irqSave(): uint32 =
    result = interrupts.uint32 * 8
    interrupts = false
  proc irqRestore(saved: uint32) = interrupts = (saved and 8) != 0
"""

CLASSIFICATION = r"""
proc robust(fc, category: uint32): bool =
  (fc and 12) == 0 and ((fc and 240) in [160'u32, 192'u32] or
    ((fc and 240) == 208 and category notin [4'u32, 7, 11, 15, 127]))

for fc in 0'u32 .. 65535'u32:
  for category in [0'u32, 3, 4, 7, 8, 9, 11, 15, 16, 126, 127, 128, 255, high(uint32)]:
    doAssert mfp_is_robust_frame(fc, category) == robust(fc, category),
      "classification fc=" & $fc & " category=" & $category

for vif in 0'u8 .. 1'u8:
  for index in 0'u8 .. 6'u8:
    for group in [false, true]:
      for flags in 0'u32 .. 15'u32:
        for hasKey in [false, true]:
          stations[index].macAddr[0] = if group: 1 else: 2
          stations[index].capabilityFlags = flags
          vifs[vif].keys.groupKeyPtr = if hasKey: 1 else: 0
          var desc = HostTxDescView(vifIdx: vif, staInfoIdx: index)
          for fc in [0xA0'u32, 0xC0, 0xD0, 0xB0, 0xD8]:
            for category in [3'u32, 4, 127, 128]:
              let expected = if not hasKey or not robust(fc, category): 0'u32
                elif group: 2'u32 else: (flags shr 3) and 1
              doAssert mfp_protect_mgmt_frame(addr desc, fc, category) == expected
"""

RECEIVE = r"""
proc setIpn(mmie: ptr MmIeView; pn: uint64) =
  for i in 0 ..< 6: mmie.ipn[i] = ((pn shr (i * 8)) and 255).uint8
proc setMic(mmie: ptr MmIeView; value: uint64) =
  for i in 0 ..< 8: mmie.mic[i] = ((value shr (i * 8)) and 255).uint8

var frame: array[96, uint8]
var status = MfpMgmtFramePolicyView(frameCtrl: 0xC0, bodyOffset: 24, staIdx: 0, vifIdx: 0)
var upload, flags: uint8
proc receive(length: uint16 = 44): bool =
  mfp_ignore_mgmt_frame(addr status, addr frame[0], length, addr upload, addr flags)
proc reset() =
  frame = default(typeof(frame))
  vifs = default(typeof(vifs))
  stations = default(typeof(stations))
  status = MfpMgmtFramePolicyView(frameCtrl: 0xC0, bodyOffset: 24, staIdx: 0, vifIdx: 0)
  upload = 1
  flags = 0xA0
  micCalls = 0
  computedMic = 0xA1B2C3D4E5F60718'u64
  vifs[0].keys.groupKeyPtr = 1

# Return means ignored, not accepted; no IGTK leaves ordinary handling intact.
reset()
status.frameCtrl = 0xB0
doAssert not receive() and upload == 1 and flags == 0xA0
reset()
vifs[0].keys.groupKeyPtr = 0
doAssert not receive() and upload == 1
for invalid in [7'u8, 254, 255]:
  for invalidSta in [true, false]:
    reset()
    if invalidSta: status.staIdx = invalid else: status.vifIdx = invalid
    doAssert receive() and upload == 0

# Unicast robust management: preserve Protected frames, mark reasons 6/7 for
# SA Query using the fifth ABI argument, and reject other unprotected reasons.
for subtype in [0xA0'u16, 0xC0'u16]:
  for reason in [1'u16, 6, 7, 8, 0x106]:
    reset()
    status.frameCtrl = subtype
    stations[0].capabilityFlags = 8
    frame[24] = (reason and 255).uint8
    frame[25] = (reason shr 8).uint8
    let saQuery = reason in [6'u16, 7'u16]
    doAssert receive() == not saQuery
    doAssert upload == (if saQuery: 1'u8 else: 0'u8)
    doAssert flags == (if saQuery: 0xA1'u8 else: 0xA0'u8)
reset()
stations[0].capabilityFlags = 8
status.frameCtrl = 0x40D0
frame[24] = 8
doAssert not receive() and upload == 1

# Classification uses the action category byte at bodyOffset, not the subtype.
for category in [4'u8, 7, 11, 15, 127]:
  reset()
  status.frameCtrl = 0xD0
  frame[24] = category
  doAssert not receive() and upload == 1

# Correct IGTK slot, full 48-bit little-endian IPN, and MIC-before-replay update.
for vif in 0'u8 .. 1'u8:
  for keyId in 4'u16 .. 5'u16:
    for pn in [1'u64, 255, 65535, 0xFFFFFF'u64, 0xFFFFFFFF'u64,
               0x100000000'u64, 0x010203040506'u64, 0xFFFFFFFFFFFF'u64]:
      reset()
      status.flags = 1
      status.vifIdx = vif
      vifs[vif].keys.groupKeyPtr = 1
      let key = addr vifs[vif].slots[keyId]
      key.installed = 1
      key.replayCounters[0].pnLow = (pn and 0xFFFFFFFF'u64).uint32
      key.replayCounters[0].pnHigh = (pn shr 32).uint32
      let previous = key.replayCounters[0]
      let mmie = mmieAt(addr frame[26])
      mmie.ie = Ie(id: 76, len: 16)
      mmie.keyId = keyId
      setIpn(mmie, pn)
      setMic(mmie, computedMic xor 1)
      let before = frame
      doAssert receive() and upload == 0 and micCalls == 1
      doAssert key.replayCounters[0] == previous
      doAssert frame == before
      upload = 1
      setMic(mmie, computedMic)
      let validFrame = frame
      doAssert not receive() and upload == 1 and micCalls == 2
      doAssert micKey == key and micFrame == (addr frame[0]) and micLength == 44 and micBodyOffset == 24
      doAssert key.replayCounters[0].pnLow == ((pn + 1) and 0xFFFFFFFF'u64).uint32
      doAssert key.replayCounters[0].pnHigh == ((pn + 1) shr 32).uint32
      doAssert frame == validFrame
      doAssert receive() and upload == 0 and micCalls == 2

# Short/truncated/malformed MMIEs must not call crypto or mutate any key state.
for length in 0'u16 .. 43'u16:
  reset()
  status.flags = 1
  doAssert receive(length) and upload == 0 and micCalls == 0
for badId in [0'u16, 3, 6, high(uint16)]:
  reset()
  status.flags = 1
  let mmie = mmieAt(addr frame[26])
  mmie.ie = Ie(id: 76, len: 16)
  mmie.keyId = badId
  doAssert receive() and upload == 0 and micCalls == 0
for badLength in [0'u8, 8, 15, 17, 255]:
  reset()
  status.flags = 1
  let mmie = mmieAt(addr frame[26])
  mmie.ie = Ie(id: 76, len: badLength)
  mmie.keyId = 4
  vifs[0].slots[4].installed = 1
  setIpn(mmie, 1)
  doAssert receive() and upload == 0 and micCalls == 0
reset()
status.flags = 1
let nonterminalMmie = mmieAt(addr frame[26])
nonterminalMmie.ie = Ie(id: 76, len: 16)
nonterminalMmie.keyId = 4
vifs[0].slots[4].installed = 1
setIpn(nonterminalMmie, 1)
doAssert receive(46) and upload == 0 and micCalls == 0
"""


def procedure(source: str, name: str) -> str:
    start = re.search(rf"^proc {name}\*?\(", source, re.M)
    assert start
    end = re.search(r"^(?:proc|template|func) ", source[start.end():], re.M)
    return source[start.start():start.end() + end.start() if end else len(source)]


@pytest.mark.parametrize("receive", [False, True], ids=["classification", "receive"])
def test_mfp_control(receive: bool, tmp_path: Path) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("nim is not installed")
    mac = (FW / "kernel_mac_channel.nim").read_text()
    mfp = (FW / "crypto_mfp_hsu.nim").read_text()
    source = PLATFORM + procedure(mac, "mfp_is_robust_frame")
    if receive:
        source += KEY_CONTEXT + procedure(mfp, "mfpIgnoreRxMgmtFrame")
        source += procedure(mfp, "mfp_ignore_mgmt_frame") + RECEIVE
        tasks = (FW / "task_handlers.nim").read_text()
        assert "if mfpIgnoreRxMgmtFrame(param, envPtr, frameHdr, bodyLen," in tasks
        assert "return rxuMgtUpload(param, mfpAcceptedFlag)" in tasks
        assert "discard mfpIgnoreRxMgmtFrame(" not in tasks
        assert "register unsigned char* _a4" not in tasks
    else:
        source += procedure(mfp, "mfp_protect_mgmt_frame") + CLASSIFICATION
    path = tmp_path / "mfp_control.nim"
    path.write_text(source)
    result = subprocess.run(
        [nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on", "--skipUserCfg:on",
         "--checks:on", f"--nimcache:{tmp_path / 'nimcache'}", f"-o:{tmp_path / 'check'}", str(path)],
        cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
    )
    assert result.returncode == 0, result.stdout
