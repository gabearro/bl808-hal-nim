"""Compare production VIF key lifecycle code with the vendor's state changes."""

from pathlib import Path
import re
import shutil
import subprocess

import pytest

from test_wifi_message_allocation import run_program


ROOT = Path(__file__).resolve().parents[1]
FW = ROOT / "src/bl808/wifi/fw"

PLATFORM = r"""
type RxEnv = object
  secInfo0, secInfo1: uint32
  secFlags: uint8
const
  RC_PRNG_MULT = 0x41C64E6D'u32
  RC_PRNG_INCR = 0x3039'u32
  RxuMgmtPnTid = 8'u8
  MAX_VIFS = 2
var
  vifs: array[2, VifChannelView]
  rcPrngState = 0xDEADBEEF'u32
  rxEnv: RxEnv
proc rxuCntrlEnvView(): ptr RxEnv = addr rxEnv
proc rxMgtReplayReset(key: pointer) = discard
proc rxMgtReplayForget(key: pointer) = discard
proc rxMgtReplayCounter(key: pointer): ptr KeyReplayCounterView = nil
proc vifChannelAt(p: pointer): ptr VifChannelView = cast[ptr VifChannelView](p)
proc vifChannelForIdx(index: uint8): ptr VifChannelView = addr vifs[index]
proc vifMgmtAddKeyParamView(p: pointer): ptr VifMgmtAddKeyParamView =
  cast[ptr VifMgmtAddKeyParamView](p)
proc vifMgmtAddKeyTkipMaterialPtr(req: ptr VifMgmtAddKeyParamView): pointer =
  addr req.tkipKeyMaterial[0]
proc c_memset(p: pointer; value: cint; size: csize_t): pointer =
  let bytes = cast[ptr UncheckedArray[uint8]](p)
  for i in 0 ..< size.int: bytes[i] = value.uint8
  p
proc c_memcpy(dst, src: pointer; size: csize_t): pointer =
  copyMem(dst, src, size.int)
  dst
proc le32(p: pointer): uint32 =
  let bytes = cast[ptr UncheckedArray[uint8]](p)
  for i in 0 ..< 4: result = result or (bytes[i].uint32 shl (i * 8))
proc replayCounterStateView(p: pointer): ptr ReplayCounterStateView =
  cast[ptr ReplayCounterStateView](p)
proc assertBytes(actual, expected: pointer; size: int; label: string) =
  if equalMem(actual, expected, size): return
  let a = cast[ptr UncheckedArray[uint8]](actual)
  let e = cast[ptr UncheckedArray[uint8]](expected)
  for i in 0 ..< size:
    doAssert a[i] == e[i], label & " byte " & $i & ": " & $a[i] & " != " & $e[i]
"""

INSTALL_CHECKS = r"""
var expectedPrng = 1'u32
proc checkInstall(vifIdx, keyId, cipher, pairwise: uint8; pn: uint64) =
  discard c_memset(addr vifs, 0xA5, sizeof(vifs).csize_t)
  var expected = vifs
  var req = VifMgmtAddKeyParamView(staIdx: keyId, keySlot: vifIdx,
                                 cipherType: cipher, hasRxPn: pairwise)
  for i in 0 ..< 16:
    req.ccmpKeyMaterial[i] = (0x40 + i).uint8
    req.tkipKeyMaterial[i] = (0x90 + i).uint8
  for i in 0 ..< 4:
    req.pnLowBytes[i] = ((pn shr (i * 8)) and 255).uint8
    req.pnHighBytes[i] = ((pn shr (32 + i * 8)) and 255).uint8
  let originalReq = req
  let slot = vifKeySlot(addr expected[vifIdx], keyId.uint)
  slot.replayCounters = default(typeof(slot.replayCounters))
  slot.keyIdx = 17 + keyId
  slot.cipherType = cipher
  slot.staIdx = keyId
  slot.hasRxPn = pairwise
  slot.pnLow = 0
  slot.pnHigh = 0
  case cipher
  of 0, 3:
    expectedPrng = expectedPrng * RC_PRNG_MULT + RC_PRNG_INCR
    slot.pnLow = expectedPrng shr 16
  of 1: slot.keyMaterial = req.tkipKeyMaterial
  of 5: slot.keyMaterial = req.ccmpKeyMaterial
  else: discard
  if cipher notin [0'u8, 3'u8] and (pn != 0 or cipher == 5):
    let nextPn = pn + 1'u64
    for counter in slot.replayCounters.mitems:
      counter.pnLow = (nextPn and 0xFFFFFFFF'u64).uint32
      counter.pnHigh = (nextPn shr 32).uint32
      if pairwise != 0 and cipher != 5:
        counter.bitmap[((nextPn shr 5) and 1).int] = 1'u32 shl (nextPn and 31).int
  slot.installed = 1
  let keys = vifKeyPointers(addr expected[vifIdx])
  let actualSlot = vifKeySlotPtr(addr vifs[vifIdx], keyId.uint)
  if cipher == 5: keys.groupKeyPtr = actualSlot
  else: keys.defaultKeyPtr = actualSlot
  vif_mgmt_add_key(addr req, 17 + keyId)
  assertBytes(addr vifs, addr expected, sizeof(vifs),
    "install vif=" & $vifIdx & " key=" & $keyId & " cipher=" & $cipher &
    " pairwise=" & $pairwise & " pn=" & $pn)
  doAssert req == originalReq
  doAssert vifKeyPrngState == expectedPrng
  doAssert rcPrngState == 0xDEADBEEF'u32

for vifIdx in 0'u8 .. 1'u8:
  for keyId in 0'u8 .. 5'u8:
    for cipher in 0'u16 .. 255'u16:
      checkInstall(vifIdx, keyId, cipher.uint8, 0, 0)
    for cipher in [0'u8, 1, 2, 3, 4, 5, 255]:
      for pairwise in [0'u8, 1, 255]:
        for pn in [0'u64, 1, 30, 31, 32, 63, 0xFFFFFFFF'u64, 0x100000000'u64,
                   0x22001234'u64, 0x62004567'u64, 0xFFFFFFFFFFFF'u64,
                   0xFFFFFFFFFFFFFFFF'u64]:
          checkInstall(vifIdx, keyId, cipher, pairwise, pn)
"""

DELETE_CHECKS = r"""
proc ptrFor(vifIdx: int; keyId: int): uint32 =
  if keyId < 0: 0'u32 else: vifKeySlotPtr(addr vifs[vifIdx], keyId.uint)

for vifIdx in 0 .. 1:
  for validMask in 0 .. 63:
    for deleted in 0 .. 5:
      for defaultKey in -1 .. 5:
        for groupKey in -1 .. 5:
          discard c_memset(addr vifs, 0xA5, sizeof(vifs).csize_t)
          for i in 0 .. 5:
            vifKeySlot(addr vifs[vifIdx], i.uint).installed =
              ((validMask shr i) and 1).uint8
          let keys = vifKeyPointers(addr vifs[vifIdx])
          keys.defaultKeyPtr = ptrFor(vifIdx, defaultKey)
          keys.groupKeyPtr = ptrFor(vifIdx, groupKey)
          var expected = vifs
          let expectedKeys = vifKeyPointers(addr expected[vifIdx])
          var remaining = validMask and not (1 shl deleted)
          vifKeySlot(addr expected[vifIdx], deleted.uint).installed = 0
          var candidate = deleted
          var replacedDefault = false
          if defaultKey == deleted:
            expectedKeys.defaultKeyPtr = 0
            for i in 0 .. 3:
              candidate = i
              if (remaining and (1 shl i)) != 0:
                expectedKeys.defaultKeyPtr = ptrFor(vifIdx, i)
                replacedDefault = true
                break
          if not replacedDefault and groupKey == candidate:
            expectedKeys.groupKeyPtr = 0
            for i in 4 .. 5:
              if (remaining and (1 shl i)) != 0:
                expectedKeys.groupKeyPtr = ptrFor(vifIdx, i)
                break
          vif_mgmt_del_key(addr vifs[vifIdx], deleted.uint8)
          assertBytes(addr vifs, addr expected, sizeof(vifs),
            "delete vif=" & $vifIdx & " mask=" & $validMask & " key=" & $deleted &
            " default=" & $defaultKey & " group=" & $groupKey)
"""

RX_CHECKS = r"""
for vifIdx in 0'u8 .. 1'u8:
  for keyId in 0'u8 .. 3'u8:
    for cipher in [1'u8, 2'u8]:
      for pairwise in [0'u8, 1'u8]:
        for pn in [1'u64, 31, 32, 0xFFFFFFFF'u64, 0x100000000'u64,
                   0x22001234'u64, 0x62004567'u64]:
          var req = VifMgmtAddKeyParamView(staIdx: keyId, keySlot: vifIdx,
            cipherType: cipher, hasRxPn: pairwise)
          for i in 0 ..< 4:
            req.pnLowBytes[i] = ((pn shr (i * 8)) and 255).uint8
            req.pnHighBytes[i] = ((pn shr (32 + i * 8)) and 255).uint8
          vif_mgmt_add_key(addr req, keyId)
          let key = vifKeySlot(addr vifs[vifIdx], keyId.uint)
          for tid in 0'u8 .. 7'u8:
            rxEnv.secInfo0 = (pn and 0xFFFFFFFF'u64).uint32
            rxEnv.secInfo1 = (pn shr 32).uint32
            doAssert rxu_cntrl_check_pn(key, tid) == 0, "installed PN was replayed"
            rxEnv.secInfo0 = ((pn + 1) and 0xFFFFFFFF'u64).uint32
            rxEnv.secInfo1 = ((pn + 1) shr 32).uint32
            doAssert rxu_cntrl_check_pn(key, tid) == 1, "fresh PN was rejected"
            doAssert rxu_cntrl_check_pn(key, tid) == 0, "duplicate PN was accepted"
"""

WIDE_RX_CHECKS = r"""
for vifIdx in 0'u8 .. 1'u8:
  for keyId in 0'u8 .. 3'u8:
    for cipher in [1'u8, 2'u8]:
      for seed in [1'u64, 30, 31, 32, 63, 0xFFFFFFFF'u64, 0x100000000'u64]:
        for multiple in [1'u64, 2, 1023]:
          for extra in [0'u64, 32]:
            discard c_memset(addr vifs, 0xA5, sizeof(vifs).csize_t)
            var req = VifMgmtAddKeyParamView(staIdx: keyId, keySlot: vifIdx,
              cipherType: cipher, hasRxPn: 1)
            for i in 0 ..< 4:
              req.pnLowBytes[i] = ((seed shr (i * 8)) and 255).uint8
              req.pnHighBytes[i] = ((seed shr (32 + i * 8)) and 255).uint8
            let beforeReq = req
            vif_mgmt_add_key(addr req, keyId)
            let key = vifKeySlot(addr vifs[vifIdx], keyId.uint)
            let high = seed + multiple * (1'u64 shl 37) + extra
            doAssert high < (1'u64 shl 48)
            for tid in 0'u8 .. 7'u8:
              var expected = vifs
              let counter = addr vifKeySlot(addr expected[vifIdx], keyId.uint).replayCounters[tid]
              counter.pnLow = ((high + 1) and 0xFFFFFFFF'u64).uint32
              counter.pnHigh = ((high + 1) shr 32).uint32
              counter.bitmap = default(typeof(counter.bitmap))
              let bank = (((high + 1) shr 5) and 1).int
              counter.bitmap[bank] = 1'u32 shl ((high + 1) and 31).int
              rxEnv.secInfo0 = (high and 0xFFFFFFFF'u64).uint32
              rxEnv.secInfo1 = (high shr 32).uint32
              doAssert rxu_cntrl_check_pn(key, tid) == 1,
                "fresh PN after key installation collided with seeded history"
              assertBytes(addr vifs, addr expected, sizeof(vifs), "seeded forward jump")
              if extra != 0:
                let late = high - 32
                rxEnv.secInfo0 = (late and 0xFFFFFFFF'u64).uint32
                rxEnv.secInfo1 = (late shr 32).uint32
                doAssert rxu_cntrl_check_pn(key, tid) == 1,
                  "unseen in-window PN collided with installation history"
                counter.bitmap[bank xor 1] = 1'u32 shl ((late + 1) and 31).int
                assertBytes(addr vifs, addr expected, sizeof(vifs), "seeded late arrival")
              for rejected in [high, seed, high - 33]:
                rxEnv.secInfo0 = (rejected and 0xFFFFFFFF'u64).uint32
                rxEnv.secInfo1 = (rejected shr 32).uint32
                doAssert rxu_cntrl_check_pn(key, tid) == 0
                assertBytes(addr vifs, addr expected, sizeof(vifs), "seeded replay rejection")
            doAssert req == beforeReq
"""


def procedure(source: str, name: str) -> str:
    start = re.search(rf"^proc {name}\*?\(", source, re.M)
    assert start is not None
    end = re.search(r"^(?:proc|template|func) ", source[start.end():], re.M)
    return source[start.start():start.end() + end.start() if end else len(source)]


def build_source(body: str, checks: str) -> str:
    layout = (FW / "layout_types.nim").read_text()
    source = "type\n  VifChannelView = object\n    bytes: array[1512, uint8]\n"
    names = ["KeyReplayCounterView", "VifKeySlotView", "VifKeyPointersView",
             "VifKeySlotTableOverlay", "VifMgmtAddKeyParamView"]
    for name in names:
        source += re.search(rf"^  {name} .*?(?=\n  \w|\Z)", layout, re.M | re.S)[0] + "\n"
    source += "  ReplayCounterStateView = KeyReplayCounterView\n"
    source += PLATFORM
    storage = (FW / "global_state/storage.nim").read_text()
    seed = re.search(r"^  vifKeyPrngState[^\n]*", storage, re.M)
    assert seed is not None, "VIF keys must own their PRNG state"
    source += "\nvar " + seed[0].strip() + "\n"
    source += "static:\n  doAssert sizeof(VifKeySlotView) == 160\n"
    source += "  doAssert sizeof(VifMgmtAddKeyParamView) == 56\n"
    helpers = layout.split("template vifKeySlotTable(", 1)[1].split(
        "template vifRxProtectedKeySlot(", 1)[0]
    source += "template vifKeySlotTable(" + helpers
    helpers = layout.split("template vifKeyPointersAt(", 1)[1].split(
        "template txSecurityKeyListAt(", 1)[0]
    source += "template vifKeyPointersAt(" + helpers
    source += (FW / "key_install_policy.nim").read_text()
    source += procedure((FW / "mac_config_debug.nim").read_text(), "replay_counter_validate")
    rx = procedure((FW / "rx_upper.nim").read_text(), "rxu_cntrl_check_pn")
    source += "\n" + "".join(
        f"var {name}: uint32\n" for name in sorted(set(re.findall(r"\bnimFwDbg\w+", rx)))
    )
    source += rx
    if "proc vifReuseBipKey(" not in body:
        source += procedure((FW / "vif_management.nim").read_text(), "vifReuseBipKey")
    return source + body + checks


@pytest.mark.parametrize("name,checks", [
    ("vif_mgmt_add_key", INSTALL_CHECKS),
    ("vif_mgmt_del_key", DELETE_CHECKS),
    ("vif_mgmt_add_key", RX_CHECKS),
], ids=["install", "delete", "rx-replay"])
def test_vif_key_lifecycle(name: str, checks: str, tmp_path: Path) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("nim is not installed")
    body = procedure((FW / "vif_management.nim").read_text(), name)
    path = tmp_path / "vif_keys.nim"
    path.write_text(build_source(body, checks))
    result = subprocess.run(
        [nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on", "--skipUserCfg:on",
         "--checks:on", f"--nimcache:{tmp_path / 'nimcache'}", f"-o:{tmp_path / 'check'}", str(path)],
        cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
    )
    assert result.returncode == 0, result.stdout


@pytest.mark.parametrize("mode", ["checked", "release", "asan", "firmware"])
def test_installed_key_forward_jumps(tmp_path: Path, mode: str) -> None:
    body = procedure((FW / "vif_management.nim").read_text(), "vif_mgmt_add_key")
    run_program(tmp_path, mode, build_source(body, WIDE_RX_CHECKS))
