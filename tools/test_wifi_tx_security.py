"""Run the production TX PN/IV and management-protection code on the host."""

from pathlib import Path
import re
import shutil
import subprocess

import pytest

from test_wifi_disconnect_tx import procedure


ROOT = Path(__file__).resolve().parents[1]

PLATFORM = r"""
const
  STA_INFO_TAB_ENTRIES = 7
  MAX_VIFS = 2
type
  HostTxRateTemplateView = object
    prefix: array[3, uint32]
    pendingCount: uint32
    tail: array[3, uint32]
  HostTxLinkDescView = object
    rateTemplate: HostTxRateTemplateView
  HostTxDescView = object
    frameLen: uint16
    staInfoIdx, vifIdx, staIdx, hdrLen, secTailLen: uint8
    pnScratch: array[6, uint8]
    policy, bufDesc: pointer
  StaInfoView = object
    keyMat, keyHolder: pointer
    keyType, cipherSuite, hwKeyIdx, keyInstalled: uint8
    rateWord: uint16
  KeyList = object
    pairwiseKey: pointer
  Vif = object
    flags: uint32
    groupKeyPtr: pointer
  MacFrameControlView {.packed.} = object
    frameControl: uint16
var
  stations: array[7, StaInfoView]
  vifs: array[2, Vif]
  interrupts = true
  irqSaves, irqRestores: int
  onRestore: proc()
  rxKeyRevision = 1'u64
  rxKeyLastChanged: array[19, uint64]

proc irqSave(): uint32 =
  inc irqSaves
  result = interrupts.uint32 * 8
  interrupts = false
proc irqRestore(saved: uint32) =
  inc irqRestores
  interrupts = (saved and 8) != 0
  if interrupts and onRestore != nil:
    let callback = onRestore
    onRestore = nil
    callback()

proc staInfoForIdx(i: uint8): ptr StaInfoView = addr stations[i]
proc vifChannelForIdx(i: uint8): ptr Vif = addr vifs[i]
proc vifKeyPointers(v: ptr Vif): ptr Vif = v
proc txSecurityKeyListAt(p: pointer): ptr KeyList = cast[ptr KeyList](p)
proc hostTxDescAt(p: pointer): ptr HostTxDescView = cast[ptr HostTxDescView](p)
proc hostTxPnScratch(d: ptr HostTxDescView): ptr TxPnScratchView =
  cast[ptr TxPnScratchView](addr d.pnScratch[0])
proc hostTxRateTemplateAt(p: pointer): ptr HostTxRateTemplateView =
  cast[ptr HostTxRateTemplateView](p)
proc hostTxLinkDescAt(p: pointer): ptr HostTxLinkDescView = cast[ptr HostTxLinkDescView](p)
proc hostTxRateTemplate(p: ptr HostTxLinkDescView): ptr HostTxRateTemplateView =
  addr p.rateTemplate
proc macFrameControlAt(p: pointer): ptr MacFrameControlView = cast[ptr MacFrameControlView](p)
proc pointerAddrU32(p: pointer): uint32 = cast[uint32](cast[uint](p))
proc lmacGateHalfword(x: uint16): uint16 = (x shr 8) or (x shl 8)
proc rxMgtKeyIndex(key: pointer): int =
  if key == nil: -1 else: 0
proc c_memcpy(dst, src: pointer; count: csize_t): pointer =
  copyMem(dst, src, count.int)
  dst
"""

CHECKS = r"""
proc expectedHeader(cipher, keyId: uint8; bytes: array[6, uint8]): seq[uint8] =
  case cipher
  of 0, 3:
    @[bytes[0], bytes[1], bytes[2], (keyId and 3'u8) shl 6]
  of 1:
    @[bytes[1], (bytes[1] or 0x20'u8) and 0x7F'u8, bytes[0],
      (keyId shl 6) or 0x20'u8, bytes[2], bytes[3], bytes[4], bytes[5]]
  of 2:
    @[bytes[0], bytes[1], 0'u8, (keyId shl 6) or 0x20'u8,
      bytes[2], bytes[3], bytes[4], bytes[5]]
  else: @[]

proc check(cipher, keyId, hwKeyId: uint8; pn: uint64; update: uint32;
           skip = 0; management = false; cached = false;
           station = 3'u8; vif = 1'u8) =
  stations = default(typeof(stations))
  vifs = default(typeof(vifs))
  txSecurityReset()
  var key = VifKeySlotView(cipherType: cipher, staIdx: keyId, keyIdx: hwKeyId,
    installed: 1, pnLow: (pn and 0xFFFFFFFF'u64).uint32, pnHigh: (pn shr 32).uint32)
  var keyList = KeyList(pairwiseKey: addr key)
  stations[station].keyMat = addr keyList
  var primary, secondary: HostTxRateTemplateView
  primary.pendingCount = 0xA5A5D555'u32
  secondary.pendingCount = 0x33CCFFFF'u32
  var link: HostTxLinkDescView
  link.rateTemplate = secondary
  var desc = HostTxDescView(staInfoIdx: station, vifIdx: vif, frameLen: 0x0008,
    policy: addr primary, bufDesc: addr link,
    pnScratch: [0x5A'u8, 0x5A, 0x5A, 0x5A, 0x5A, 0x5A])
  case skip
  of 1: stations[station].keyMat = nil
  of 2: keyList.pairwiseKey = nil
  of 3:
    vifs[vif].flags = 2
    stations[station].rateWord = 0x0800
  else: discard
  var tail = 0xDEADBEEF'u32
  if skip == 0 and (cipher > 3 or
      (cipher in [1'u8, 2'u8] and pn >= 0xFFFFFFFFFFFF'u64)):
    let beforeKey = key
    let beforeDesc = desc
    doAssert txu_cntrl_sechdr_len_compute(addr desc, addr tail) == high(uint32)
    doAssert tail == 0 and key == beforeKey and desc == beforeDesc
    return
  let hdrLength = if skip != 0: 0'u32
    elif cipher in [0'u8, 3'u8]: 4'u32
    elif cipher in [1'u8, 2'u8]: 8'u32
    else: 0'u32
  let expectedTail = if hdrLength == 0: 0'u32
    elif cipher == 1: 12'u32 else: hdrLength
  if not management or cached:
    doAssert txu_cntrl_sechdr_len_compute(addr desc, addr tail) == hdrLength
    doAssert tail == expectedTail
  if management and cached:
    desc.hdrLen = hdrLength.uint8
    desc.secTailLen = tail.uint8

  var buffer: array[96, uint8]
  for b in buffer.mitems: b = 0x5A
  let start = if management: 40 else: 64 - hdrLength.int
  if management:
    cast[ptr uint16](addr buffer[16])[] = 0x00D0
  var expected = buffer
  let nextPn = if hdrLength == 0: pn else: pn + 1
  var pnBytes = desc.pnScratch
  if hdrLength != 0:
    for i in 0 ..< (if cipher in [0'u8, 3'u8]: 4 else: 6):
      pnBytes[i] = ((nextPn shr (8 * i)) and 0xFF'u64).uint8
  if management:
    txu_cntrl_protect_mgmt_frame(addr desc, addr buffer[16], 24)
    if hdrLength != 0: expected[17] = 0x40
    doAssert desc.hdrLen == hdrLength.uint8 and desc.secTailLen == expectedTail.uint8
  else:
    let returned = txu_cntrl_sec_hdr_append(addr desc, addr buffer[64], update)
    doAssert returned == cast[pointer](addr buffer[start]), "append pointer contract"
  doAssert key.pnLow == (nextPn and 0xFFFFFFFF'u64).uint32
  doAssert key.pnHigh == (nextPn shr 32).uint32
  doAssert desc.pnScratch == pnBytes, "PN scratch copy length/order"
  let header = if skip == 0: expectedHeader(cipher, keyId, pnBytes) else: @[]
  for i, value in header: expected[start + i] = value
  doAssert buffer == expected, "security header bytes or write bounds"

  if skip == 0:
    if management or update == 0:
      doAssert link.rateTemplate.pendingCount ==
        ((secondary.pendingCount and 0x000FFC00'u32) or hwKeyId.uint32)
      doAssert primary.pendingCount == 0xA5A5D555'u32
    else:
      doAssert primary.pendingCount == (0x0005D400'u32 or hwKeyId.uint32)
      doAssert link.rateTemplate == secondary
  else:
    doAssert primary.pendingCount == 0xA5A5D555'u32 and link.rateTemplate == secondary

for cipher in 0'u8 .. 5'u8:
  for keyId in 0'u8 .. 3'u8:
    for update in 0'u32 .. 1'u32:
      for pn in [0'u64, 0x7F, 0xFF, 0x7FFF, 0xFFFF, 0xFFFFFFFE'u64,
                 0xFFFFFFFF'u64, 0x100000000'u64, 0xFFFFFFFFFFFF'u64,
                 0xFFFFFFFFFFFFFFFF'u64]:
        check(cipher, keyId, 0x37, pn, update)
      for skip in 1 .. 3:
        check(cipher, keyId, 0x37, 0x010203040506'u64, update, skip)
    if cipher < 4:
      for cached in [false, true]:
        check(cipher, keyId, 0x37, 0x010203040506'u64, 0,
              management = true, cached = cached)

# Stress all TSC1 values, including the weak-IV avoidance mask's high bit.
for tsc1 in 0'u64 .. 255'u64:
  for keyId in 0'u8 .. 3'u8:
    check(1, keyId, 0x37, (tsc1 shl 8) or 0xA4'u64, 1)

# WEP uses three IV bytes; the following byte contains only the key selector.
for cipher in [0'u8, 3'u8]:
  for keyId in 0'u8 .. 3'u8:
    for fourthByte in 0'u64 .. 255'u64:
      for low in [0'u64, 0x123456, 0xFFFFFF]:
        for update in [0'u32, 1'u32]:
          check(cipher, keyId, 0x37, (fourthByte shl 24) or low, update)

for station in 0'u8 .. 6'u8:
  for vif in 0'u8 .. 1'u8:
    for cipher in 0'u8 .. 3'u8:
      check(cipher, 2, 17, 0xFFFFFFFE'u64, 0, station = station, vif = vif)
      for skip in 1 .. 3:
        check(cipher, 2, 17, 0xFFFFFFFE'u64, 0, skip,
              management = true, station = station, vif = vif)
"""


def program_source() -> str:
    base = ROOT / "src/bl808/wifi/fw"
    layout = (base / "layout_types.nim").read_text()
    tasks = (base / "task_handlers.nim").read_text()
    tx = (base / "tx_upper.nim").read_text()
    types = "  KeyReplayCounterView" + layout.split("  KeyReplayCounterView", 1)[1].split(
        "\n  RxMicWordsView", 1
    )[0]
    for first, end in [("TxSecurityHeaderView", "LlcSnapHeaderView"),
                       ("CcmpSecurityHeaderView", "RxlCntrlEnvView")]:
        types += "\n  " + first + layout.split("  " + first, 1)[1].split(
            "\n  " + end, 1
        )[0]
    helpers = "".join(procedure(tasks, name) for name in [
        "txSecKeyFor", "txSecKeyUsable", "txSecBumpPn", "writeTxCcmpHeader", "writeTxTkipHeader",
        "txSecControlTemplate", "patchTxSecControlWord",
        "txu_cntrl_sec_hdr_append", "txu_cntrl_sechdr_len_compute",
    ])
    protect = "proc txu_cntrl_protect_mgmt_frame*" + tx.split(
        "proc txu_cntrl_protect_mgmt_frame*", 1
    )[1]
    debug_vars = "\nvar\n" + "".join(
        f"  {name}: uint32\n" for name in sorted(set(re.findall(r"\bnimFwDbg\w+", helpers)))
    )
    bindings = (base / "tx_security.nim").read_text().replace("{.wifiCtrl.}", "")
    return "type\n" + types + "\n" + PLATFORM + debug_vars + bindings + helpers + "\n" + protect


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_tx_security_headers(tmp_path: Path, mode: str) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("nim is not installed")
    source = tmp_path / "tx_security_test.nim"
    source.write_text(program_source() + CHECKS)
    command = [nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on", "--skipUserCfg:on",
               f"--nimcache:{tmp_path / 'nimcache'}", f"-o:{tmp_path / 'test'}"]
    if mode == "release": command += ["-d:release", "--checks:off", "--assertions:on"]
    else: command += ["--checks:on"]
    if mode == "asan":
        command += ["--cc:clang", "--passC:-fsanitize=address", "--passL:-fsanitize=address"]
    result = subprocess.run(command + [str(source)], cwd=ROOT, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    assert result.returncode == 0, result.stdout
