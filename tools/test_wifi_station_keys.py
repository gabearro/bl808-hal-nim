"""Execute station key installation/deletion and HW deletion with host MMIO."""

from pathlib import Path
import re
import shutil
import subprocess

import pytest


ROOT = Path(__file__).resolve().parents[1]
FW = ROOT / "src/bl808/wifi/fw"

PLATFORM = r"""
const
  RC_PRNG_MULT = 0x41C64E6D'u32
  RC_PRNG_INCR = 0x3039'u32
  MAX_STAS = 7
  STA_ENTRY_SIZE = sizeof(StaInfoView)
var
  sta_info_tab: array[7, StaInfoView]
  rcPrngState = 0xBADC0FFE'u32
  staKeyPrngState = 1'u32
proc staInfoForIdx(i: uint8): ptr StaInfoView = addr sta_info_tab[i]
proc staInfoAt(p: pointer): ptr StaInfoView = cast[ptr StaInfoView](p)
proc staInfoAt(p: uint): ptr StaInfoView = cast[ptr StaInfoView](p)
proc machwKeyWriteParamView(p: pointer): ptr MachwKeyWriteParamView =
  cast[ptr MachwKeyWriteParamView](p)
proc machwKeyWriteKeyTailPtr(p: ptr MachwKeyWriteParamView): pointer =
  addr p.temporalKeyTail[0]
proc pointerAddrU32(p: pointer): uint32 = cast[uint32](cast[uint](p))
proc c_memset(p: pointer; value: cint; size: csize_t): pointer =
  let bytes = cast[ptr UncheckedArray[uint8]](p)
  for i in 0 ..< size.int: bytes[i] = value.uint8
  p
proc c_memcpy(dst, src: pointer; size: csize_t): pointer =
  copyMem(dst, src, size.int)
  dst
template rcPrngNext(): uint32 =
  rcPrngState = rcPrngState * RC_PRNG_MULT + RC_PRNG_INCR
  rcPrngState
proc assertBytes(actual, expected: pointer; size: int; label: string) =
  let a = cast[ptr UncheckedArray[uint8]](actual)
  let e = cast[ptr UncheckedArray[uint8]](expected)
  for i in 0 ..< size:
    doAssert a[i] == e[i], label & " at byte " & $i & ": " & $a[i] & " != " & $e[i]
"""

INSTALL_CHECKS = r"""
var expectedPrng = 1'u32
for index in 0'u8 .. 6'u8:
  for cipher in 0'u16 .. 255'u16:
    discard c_memset(addr sta_info_tab[0], 0xA5, sizeof(sta_info_tab).csize_t)
    var expected = sta_info_tab
    var req = MachwKeyWriteParamView(addrIdx: 3, keyType: index,
      cipherType: cipher.uint8, keyFlags: 1)
    for i in 0 ..< req.temporalKeyTail.len:
      req.temporalKeyTail[i] = (0x10 + i).uint8
    let beforeReq = req
    let sta = addr expected[index]
    sta.hwKeyIdx = index + 8
    sta.keyType = cipher.uint8
    sta.cipherSuite = req.addrIdx
    sta.keyFlags = req.keyFlags
    sta.keyArea = default(typeof(sta.keyArea))
    sta.pnLow = 0
    sta.pnHigh = 0
    case cipher
    of 0, 3:
      expectedPrng = expectedPrng * RC_PRNG_MULT + RC_PRNG_INCR
      sta.pnLow = expectedPrng shr 16
    of 1:
      sta.keyTail = req.temporalKeyTail
    else: discard
    sta.keyInstalled = 1
    sta.keyHolder = addr sta_info_tab[index].keyArea[0]
    sta_mgmt_add_key(addr req, index + 8)
    assertBytes(addr sta_info_tab, addr expected, sizeof(expected),
      "station " & $index & " cipher " & $cipher)
    doAssert req == beforeReq
    doAssert staKeyPrngState == expectedPrng
    doAssert rcPrngState == 0xBADC0FFE'u32, "key install consumed rate-control PRNG"

# Reinstalling keys must zero replay/PN state without erasing unrelated fields.
for cipher in [1'u8, 2'u8, 1'u8, 0'u8, 3'u8, 2'u8]:
  var req = MachwKeyWriteParamView(keyType: 2, cipherType: cipher)
  sta_info_tab[2].keyArea[87] = 0xEE
  sta_info_tab[2].pnLow = high(uint32)
  sta_info_tab[2].pnHigh = high(uint32)
  sta_info_tab[2].trafficFlags = 0x75
  sta_mgmt_add_key(addr req, 10)
  doAssert sta_info_tab[2].keyArea == default(typeof(sta_info_tab[2].keyArea))
  doAssert sta_info_tab[2].pnHigh == 0
  if cipher in [0'u8, 3'u8]:
    expectedPrng = expectedPrng * RC_PRNG_MULT + RC_PRNG_INCR
    doAssert sta_info_tab[2].pnLow == expectedPrng shr 16
  else: doAssert sta_info_tab[2].pnLow == 0
  doAssert sta_info_tab[2].trafficFlags == 0x75
"""

DELETE_PLATFORM = r"""
const
  MAX_VIFS = 2
  STA_INFO_TAB_ENTRIES = 7
type
  Vif = object
    index: uint8
    defaultKeyPtr: uint32
  Event = tuple[kind: string, a, b: uint32]
var
  vifs = [Vif(index: 0), Vif(index: 1)]
  events: seq[Event]
  topCount: uint32 = 14
  expectedStation = -1
  rxVifEpochs: array[2, uint32]
proc irqSave(): uint32 = 0
proc irqRestore(saved: uint32) = discard
proc staDeleteEpoch(index: uint8): uint32 = 0
proc vifKeyPointers(vif: ptr Vif): ptr Vif = vif
proc vifKeySlotPtr(vif: ptr Vif; index: uint): uint32 = 1
proc vifChannelForIdx(index: uint8): ptr Vif = addr vifs[index]
proc vif_mgmt_del_key(vif: pointer; slot: uint8) =
  events.add(("vif", cast[ptr Vif](vif).index.uint32, slot.uint32))
proc machwSecurityKeyCount(): uint32 = topCount shl 24
proc staMacWords(sta: ptr StaInfoView): tuple[lo, hi: uint32] =
  for i in 0 ..< 4: result.lo = result.lo or (sta.macAddr[i].uint32 shl (8 * i))
  for i in 0 ..< 2: result.hi = result.hi or (sta.macAddr[i + 4].uint32 shl (8 * i))
proc machwSecurityWriteAddress(lo, hi: uint32) = events.add(("address", lo, hi))
proc machwSecurityClearKeyMaterial() =
  if expectedStation >= 0:
    doAssert sta_info_tab[expectedStation].keyInstalled == 0
    doAssert sta_info_tab[expectedStation].keyHolder == nil
    doAssert sta_info_tab[expectedStation].controlPortState == 1
  events.add(("clear", 0'u32, 0'u32))
proc machwSecurityWriteControl(value: uint32) = events.add(("control", value, 0'u32))
proc waitMachwSecurityControlClear(mask: uint32): bool =
  events.add(("wait", mask, 0'u32))
  true
"""

DELETE_CHECKS = r"""
# Explicit C ABI calls preserve the full station pointer, including local
# station objects which need not be members of the global station table.
let deleteKey: proc(sta: pointer) {.cdecl.} = sta_mgmt_del_key
for index in 0 ..< 7:
  discard c_memset(addr sta_info_tab, 0xA5, sizeof(sta_info_tab).csize_t)
  var expected = sta_info_tab
  expected[index].keyInstalled = 0
  expected[index].keyHolder = nil
  expected[index].controlPortState = 1
  deleteKey(addr sta_info_tab[index])
  assertBytes(addr sta_info_tab, addr expected, sizeof(expected), "delete slot " & $index)
var local: StaInfoView
local.keyInstalled = 1
local.keyHolder = addr local.keyArea[0]
deleteKey(addr local)
doAssert local.keyInstalled == 0 and local.keyHolder == nil and local.controlPortState == 1

for key in 0'u8 .. 18'u8:
  discard c_memset(addr sta_info_tab, 0xA5, sizeof(sta_info_tab).csize_t)
  for index in 0 ..< 7:
    sta_info_tab[index].instNbr = (index and 1).uint8
    sta_info_tab[index].macAddr = [index.uint8, 0x12, 0x34, 0x56, 0x78, 0x9A]
  var expectedStations = sta_info_tab
  var expectedEvents: seq[Event]
  expectedStation = -1
  if key > topCount.uint8:
    let offset = key.uint32 - topCount - 1
    expectedEvents.add(("vif", offset div 2, 4 + (offset and 1)))
  else:
    if key < 8:
      expectedEvents.add(("vif", key.uint32 shr 2, key.uint32 and 3))
      expectedEvents.add(("wait", 0xE0000000'u32, 0'u32))
      expectedEvents.add(("address", high(uint32), high(uint32)))
    else:
      expectedStation = (key - 8).int
      let sta = addr expectedStations[expectedStation]
      let mac = staMacWords(sta)
      expectedEvents.add(("wait", 0xE0000000'u32, 0'u32))
      expectedEvents.add(("address", mac.lo, mac.hi))
      sta.keyInstalled = 0
      sta.keyHolder = nil
      sta.controlPortState = 1
    expectedEvents.add(("clear", 0'u32, 0'u32))
    expectedEvents.add(("control", (key.uint32 shl 16) or 0x40000000'u32, 0'u32))
    expectedEvents.add(("wait", 0x40000000'u32, 0'u32))
  events.setLen(0)
  mm_sec_machwkey_del(key)
  doAssert events == expectedEvents, "HW delete order for key " & $key & ": " & $events
  assertBytes(addr sta_info_tab, addr expectedStations, sizeof(expectedStations),
    "HW delete station writes for key " & $key)
"""

WRITE_PLATFORM = r"""
const
  MAX_VIFS = 2
  STA_INFO_TAB_ENTRIES = 7
  STA_MGMT_FREE_STAS = 5
type
  Vif = object
    index: uint8
  SecurityRegs = object
    keyMaterial: array[4, uint32]
  Event = tuple[kind: string, value, extra: uint32]
var
  vifs = [Vif(index: 0), Vif(index: 1)]
  rxVifEpochs: array[2, uint32]
  stationEpochs: array[5, uint32]
  regs: SecurityRegs
  events: seq[Event]
  irq, idleSucceeds, completionSucceeds: bool
  keyCount: uint32
  installed: bool
  published: MachwKeyWriteParamView
  hook: proc(stage: string)
proc irqSave(): uint32 =
  result = if irq: 8'u32 else: 0'u32
  irq = false
proc irqRestore(saved: uint32) = irq = (saved and 8) != 0
proc staDeleteEpoch(index: uint8): uint32 =
  if index < 5: stationEpochs[index] else: 0
proc vifChannelForIdx(index: uint8): ptr Vif = addr vifs[index]
proc vifKeySlotPtr(vif: ptr Vif; slot: uint): uint32 =
  1 + vif.index.uint32 * 6 + slot.uint32
proc staMacWords(sta: ptr StaInfoView): tuple[lo, hi: uint32] =
  for i in 0 ..< 4: result.lo = result.lo or (sta.macAddr[i].uint32 shl (8 * i))
  for i in 0 ..< 2: result.hi = result.hi or (sta.macAddr[i + 4].uint32 shl (8 * i))
proc event(kind: string; value = 0'u32; extra = 0'u32) =
  doAssert not irq, "interrupts enabled in key transaction"
  events.add((kind, value, extra))
proc sta_mgmt_add_key(req: pointer; index: uint8) =
  published = machwKeyWriteParamView(req)[]
  installed = true
  event("sta", index.uint32)
proc vif_mgmt_add_key(req: pointer; index: uint8) =
  published = machwKeyWriteParamView(req)[]
  installed = true
  event("vif", index.uint32)
proc sta_mgmt_del_key(sta: pointer) =
  event("delSta")
  installed = false
proc vif_mgmt_del_key(vif: pointer; slot: uint8) =
  event("delVif", cast[ptr Vif](vif).index.uint32, slot.uint32)
  installed = false
proc machwSecurityKeyCount(): uint32 = keyCount shl 24
proc machwSecurityWriteAddress(lo, hi: uint32) = event("address", lo, hi)
proc machwSecurityWriteKeyMaterial(words: array[4, uint32]) =
  regs.keyMaterial = words
  event("material", words[0], words[3])
proc machwSecurityRegs(): ptr SecurityRegs = addr regs
proc volatileLoad(p: ptr uint32): uint32 = p[]
proc machwSecurityControl(): uint32 = 0
proc machwSecurityWriteControl(value: uint32) = event("control", value)
proc waitMachwSecurityControlClear(mask: uint32): bool =
  event("wait", mask)
  if hook != nil: hook(if mask == 0xE0000000'u32: "idle" else: "done")
  if mask == 0xE0000000'u32: idleSucceeds else: completionSucceeds
proc setup(incomingIrq = true) =
  sta_info_tab = default(typeof(sta_info_tab))
  for i in 0 ..< 7:
    sta_info_tab[i].instNbr = if i < 5: (i and 1).uint8 else: (i - 5).uint8
    sta_info_tab[i].valid = (i < 5).uint8
    sta_info_tab[i].controlPortState = 2
    sta_info_tab[i].macAddr = [i.uint8, 0x12, 0x34, 0x56, 0x78, 0x9A]
  stationEpochs = [1'u32, 2, 3, 4, 5]
  rxVifEpochs = [11'u32, 12]
  regs = default(SecurityRegs)
  events.setLen(0)
  installed = false
  published = default(MachwKeyWriteParamView)
  irq = incomingIrq
  idleSucceeds = true
  completionSucceeds = true
  keyCount = 14
  hook = nil
proc requestFor(cipher = 2'u8; group = false): MachwKeyWriteParamView =
  result = MachwKeyWriteParamView(keyType: (if group: 0xFF'u8 else: 0'u8),
    cipherType: cipher, keyLen: (case cipher
      of 0: 5'u8
      of 1: 32'u8
      of 3: 13'u8
      else: 16'u8),
    addrIdx: (if cipher == 5: 4'u8 else: 0'u8),
    keyWords: [0x12345678'u32, 0xDEADBEEF'u32, 0xADDEBAAD'u32, 0x87654321'u32])
"""

WRITE_CHECKS = r"""
for vif in 0'u8 .. 1'u8:
  for station in 0'u8 .. 7'u8:
    if station >= 5 and station < 7 and station != 5 + vif: continue
    for cipher in [0'u8, 1, 2, 3, 5]:
      if cipher == 5 and station != 7: continue
      for pairwise in [0'u8, 1'u8]:
        for keyId in 0'u8 .. 5'u8:
          if (cipher == 5 and keyId < 4) or (cipher != 5 and keyId > 3): continue
          setup()
          if station < 5: sta_info_tab[station].instNbr = vif
          var req = requestFor(cipher, station == 7)
          req.keyType = if station == 7: 0xFF'u8 else: station
          req.addrIdx = keyId
          req.keyIdx = vif
          req.keyFlags = pairwise
          req.spp = 3
          let original = req
          var expected: seq[Event]
          var hardwareIndex: uint8
          let management = station == 7 and cipher == 5
          if management:
            hardwareIndex = keyId + 11 + 2 * vif
            expected.add(("vif", hardwareIndex.uint32, 0'u32))
          else:
            expected.add(("wait", 0xE0000000'u32, 0'u32))
            if station == 7:
              hardwareIndex = keyId + 4 * vif
              expected.add(("address", high(uint32), high(uint32)))
            else:
              hardwareIndex = station + 8
              let mac = staMacWords(addr sta_info_tab[station])
              expected.add(("address", mac.lo, mac.hi))
            var length, mode: uint32
            case cipher
            of 0: (length, mode) = (0'u32, 1'u32)
            of 1: (length, mode) = (1'u32, 2'u32)
            of 2: (length, mode) = (0'u32, 3'u32)
            of 3: (length, mode) = (1'u32, 1'u32)
            else: doAssert false
            expected.add(("material", req.keyWords[0], req.keyWords[3]))
            let control = 0x40000000'u32 or (hardwareIndex.uint32 shl 16) or
              (length shl 11) or (mode shl 8) or (vif.uint32 shl 4) or 12'u32
            expected.add(("control", control, 0'u32))
            expected.add(("wait", 0x40000000'u32, 0'u32))
            expected.add(((if station == 7: "vif" else: "sta"), hardwareIndex.uint32, 0'u32))
          doAssert mm_sec_machwkey_wr(addr req) == hardwareIndex, "returned key index"
          doAssert events == expected, "write events " & $events & " != " & $expected
          doAssert req == original and published == original and installed and irq

# Every byte-sized selector and length is checked before MMIO or publication.
for field in 0 .. 7:
  for value in 0'u16 .. 255:
    setup()
    var req = requestFor()
    case field
    of 0: req.keyIdx = value.uint8
    of 1: req.keyType = value.uint8
    of 2: req.addrIdx = value.uint8
    of 3: req.spp = value.uint8
    of 4: req.macLen = value.uint8
    of 5: req.keyLen = value.uint8
    of 6: req.cipherType = value.uint8
    else: sta_info_tab[0].instNbr = value.uint8
    let valid = case field
      of 0, 7: value == 0
      of 1: value in [0'u16, 2, 4, 5, 255]
      of 2, 3: value <= 3
      of 4: value <= 8
      of 5: value == 16
      else: value == 2
    let index = mm_sec_machwkey_wr(addr req)
    doAssert (index != 0xFF) == valid, "field " & $field & " value " & $value
    doAssert irq
    if not valid: doAssert events.len == 0 and not installed

for group in [false, true]:
  for incomingIrq in [false, true]:
    for phase in ["idle", "done"]:
      setup(incomingIrq)
      installed = true
      var req = requestFor(2, group)
      if phase == "idle": idleSucceeds = false
      else: completionSucceeds = false
      doAssert mm_sec_machwkey_wr(addr req) == 0xFF
      doAssert irq == incomingIrq
      if phase == "idle":
        doAssert installed and events == @[("wait", 0xE0000000'u32, 0'u32)]
      else:
        doAssert not installed and events.len == 6
        doAssert events[^1].kind == (if group: "delVif" else: "delSta")
        doAssert events[^2] == ("wait", 0x40000000'u32, 0'u32)
      for station in sta_info_tab:
        let shouldClose = group and phase == "done" and station.instNbr == req.keyIdx
        doAssert station.controlPortState == (if shouldClose: 1'u8 else: 2'u8)

for phase in ["idle", "done"]:
  for change in 0 .. 4:
    setup()
    var req = requestFor()
    installed = true
    hook = proc(stage: string) =
      if stage != phase: return
      case change
      of 0: inc rxVifEpochs[0]
      of 1: inc stationEpochs[0]
      of 2: sta_info_tab[0].macAddr[0] = 0xEE
      of 3: sta_info_tab[0].valid = 0
      else: sta_info_tab[0].instNbr = 1
    doAssert mm_sec_machwkey_wr(addr req) == 0xFF
    doAssert installed and published == default(MachwKeyWriteParamView)
    doAssert events.len == (if phase == "idle": 1 else: 5)

setup()
completionSucceeds = false
var failedVifOne = requestFor(2, true)
failedVifOne.keyIdx = 1
doAssert mm_sec_machwkey_wr(addr failedVifOne) == 0xFF
for station in sta_info_tab:
  doAssert station.controlPortState == (if station.instNbr == 1: 1'u8 else: 2'u8)

# The descriptor is private even if its caller's storage changes during a wait.
for phase in ["idle", "done"]:
  setup()
  var req = requestFor()
  let original = req
  hook = proc(stage: string) =
    if stage == phase: req = requestFor(1, true)
  doAssert mm_sec_machwkey_wr(addr req) == 8
  doAssert published == original and regs.keyMaterial == original.keyWords

for count in 0'u32 .. 255:
  setup()
  keyCount = count
  var req = requestFor()
  doAssert (mm_sec_machwkey_wr(addr req) != 0xFF) == (count >= 8)
  setup()
  keyCount = count
  req = requestFor(5, true)
  req.keyIdx = 1
  req.addrIdx = 5
  let index = mm_sec_machwkey_wr(addr req)
  doAssert (index != 0xFF) == (count in 14'u32 .. 250'u32)
  if index != 0xFF:
    doAssert index.uint32 == count + 4 and events == @[("vif", index.uint32, 0'u32)]

for slot in 0'u16 .. 255:
  setup()
  var req = requestFor(5, true)
  req.addrIdx = slot.uint8
  doAssert (mm_sec_machwkey_wr(addr req) != 0xFF) == (slot in [4'u16, 5'u16])
  if slot notin [4'u16, 5'u16]: doAssert events.len == 0 and not installed

setup()
doAssert mm_sec_machwkey_wr(nil) == 0xFF and events.len == 0 and irq
setup()
var pairwiseBip = requestFor(5)
doAssert mm_sec_machwkey_wr(addr pairwiseBip) == 0xFF and events.len == 0
setup()
sta_info_tab[0].valid = 0
var req = requestFor()
doAssert mm_sec_machwkey_wr(addr req) == 0xFF and events.len == 0
setup()
req = requestFor()
req.keyType = 6
doAssert mm_sec_machwkey_wr(addr req) == 0xFF and events.len == 0
"""


def proc_body(source: str, name: str) -> str:
    match = re.search(rf"^proc {name}\*?\([^\n]*", source, re.MULTILINE)
    assert match is not None, name
    end = re.search(r"^(?:proc|template|func) ", source[match.end():], re.MULTILINE)
    stop = match.end() + end.start() if end else len(source)
    return source[match.start():stop]


def harness(*bodies: str, replay_stubs: bool = True, tx_update_stubs: bool = True) -> str:
    layout = (FW / "layout_types.nim").read_text()
    types = "type\n  CoListHdr = object\n    next: ptr CoListHdr\n"
    types += "  CoList = object\n    first, last: ptr CoListHdr\n"
    for name in ["StaInfoView", "MachwKeyWriteParamView"]:
        types += re.search(rf"^  {name} .*?(?=\n  \w|\Z)", layout, re.M | re.S)[0] + "\n"
    debug_names = sorted(set(re.findall(r"\bnimFwDbg\w+", "\n".join(bodies))))
    debug_vars = "\n" + "".join(f"var {name}: uint32\n" for name in debug_names)
    lifecycle = ""
    if replay_stubs:
        # The full private counter lifecycle is covered by test_wifi_rx_mgt_counter.
        lifecycle = ("proc rxMgtReplayReset(key: pointer) = discard\n"
                     "proc rxMgtReplayForget(key: pointer) = discard\n"
                     "proc rxKeyChange(key: pointer) = discard\n")
    if tx_update_stubs:
        lifecycle += ("proc txSecurityBeginUpdate(key: pointer): bool = true\n"
                      "proc txSecurityEndUpdate(key: pointer) = discard\n")
    if not any("proc txSecurityKeyUpdatePending(" in body for body in bodies):
        lifecycle += "proc txSecurityKeyUpdatePending(key: pointer): bool = false\n"
    if not any("proc vifReuseBipKey(" in body for body in bodies):
        lifecycle += "proc vifReuseBipKey(param: pointer; hwKeyIdx: uint8): bool = false\n"
    return types + PLATFORM + lifecycle + debug_vars + "\n".join(bodies)


def run_nim(tmp_path: Path, source: str, mode: str = "checked", mutation: str | None = None) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("nim is not installed")
    path = tmp_path / "station_keys.nim"
    path.write_text(source)
    flags = {"checked": [], "release": ["-d:release", "--assertions:on"],
             "asan": ["--cc:clang", "--passC:-fsanitize=address", "--passL:-fsanitize=address"]}
    result = subprocess.run(
        [nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on", "--skipUserCfg:on",
         "--checks:on", f"--nimcache:{tmp_path / 'nimcache'}", f"-o:{tmp_path / 'check'}",
         *flags[mode], str(path)],
        cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        timeout=120,
    )
    if mutation is None:
        assert result.returncode == 0, result.stdout
    else:
        assert result.returncode != 0 and any(reason in result.stdout for reason in
            ["AssertionDefect", "IndexDefect", "AddressSanitizer", "SIGSEGV"]), result.stdout


def test_station_key_install_matches_vendor(tmp_path: Path) -> None:
    sta = (FW / "sta_management.nim").read_text()
    run_nim(tmp_path, harness(proc_body(sta, "sta_mgmt_add_key")) + INSTALL_CHECKS)
    storage = (FW / "global_state/storage.nim").read_text()
    assert re.search(r"staKeyPrngState.*uint32\s*=\s*1(?:'u32)?", storage)


def test_station_and_hardware_key_delete(tmp_path: Path) -> None:
    sta = (FW / "sta_management.nim").read_text()
    mm = (FW / "kernel_mac_channel.nim").read_text()
    run_nim(tmp_path, harness(DELETE_PLATFORM, proc_body(sta, "sta_mgmt_del_key"),
                             proc_body(mm, "mmDeleteSecurityKey"),
                             proc_body(mm, "mm_sec_machwkey_del")) + DELETE_CHECKS)


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("mutation", [None, "irq", "snapshot", "vif", "station", "length",
    "slot", "bip_slot", "spp", "pn_length", "idle", "done", "invalidate", "port_gate", "epoch", "mac", "limit"])
def test_hardware_key_slots_and_return(tmp_path: Path, mode: str, mutation: str | None) -> None:
    mm = (FW / "kernel_mac_channel.nim").read_text()
    body = proc_body(mm, "mm_sec_machwkey_wr")
    before = body
    if mutation == "irq":
        body = body.replace("  let saved = irqSave()\n  defer: irqRestore(saved)\n", "")
    elif mutation == "snapshot":
        body = body.replace("  var request = machwKeyWriteParamView(param)[]\n  let req = addr request",
                            "  let req = machwKeyWriteParamView(param)")
    elif mutation == "vif":
        body = body.replace("keyIdx >= MAX_VIFS.uint8", "false")
    elif mutation == "station":
        body = body.replace("keyType >= STA_INFO_TAB_ENTRIES.uint8", "false")
    elif mutation == "length":
        body = body.replace("req.keyLen != expectedLength", "false")
    elif mutation == "slot":
        body = body.replace("req.addrIdx > 3", "false")
    elif mutation == "bip_slot":
        body = body.replace("req.addrIdx notin [4'u8, 5'u8]", "false")
    elif mutation == "spp":
        body = body.replace("req.spp > 3", "false")
    elif mutation == "pn_length":
        body = body.replace("req.macLen > 8", "false")
    elif mutation == "idle":
        body = body.replace("if not idleReady or not current():", "if not current():")
    elif mutation == "done":
        body = body.replace("if not completed:", "if false:")
    elif mutation == "invalidate":
        body = body.replace("sta_mgmt_del_key(cast[pointer](staInfoForIdx(keyType)))", "discard")
    elif mutation == "port_gate":
        body = body.replace("station.controlPortState = 1", "discard")
    elif mutation == "epoch":
        body = body.replace("rxVifEpochs[keyIdx] == vifEpoch", "true")
    elif mutation == "mac":
        body = body.replace("staMacWords(staInfoForIdx(keyType)) == mac", "true")
    elif mutation == "limit":
        body = body.replace("if hwIdx > topCount:", "if false:")
    if mutation is not None:
        assert body != before, mutation
    run_nim(tmp_path, harness(WRITE_PLATFORM, body) + WRITE_CHECKS, mode, mutation)


def test_key_write_timing_keeps_outcomes_and_handles_wrap(tmp_path: Path) -> None:
    mm = (FW / "kernel_mac_channel.nim").read_text()
    body = proc_body(mm, "mm_sec_machwkey_wr")
    platform = r'''
const ClicMtimeBase = 0xE000BFF8'u
var fakeUs: uint32
var wifiKeyWriteTiming: array[2, array[6, uint32]]
proc regRead(addrReg: uint): uint32 =
  doAssert addrReg == ClicMtimeBase and not irq
  fakeUs
'''
    run_nim(tmp_path, "{.define: bl808WifiDiagKeyWriteTiming.}\n" +
            harness(WRITE_PLATFORM, platform, proc_body(mm, "recordKeyWriteTiming"), body) + r'''
setup()
fakeUs = high(uint32) - 2
hook = proc(phase: string) =
  fakeUs += (if phase == "idle": 4'u32 else: 7'u32)
var req = requestFor()
doAssert mm_sec_machwkey_wr(addr req) == 8 and irq
doAssert wifiKeyWriteTiming[0] == [1'u32, 4, 7, 11, 0, 0]

setup()
idleSucceeds = false
hook = proc(phase: string) =
  doAssert phase == "idle"
  fakeUs += 20
req = requestFor(2, true)
doAssert mm_sec_machwkey_wr(addr req) == 0xFF and irq
doAssert wifiKeyWriteTiming[1] == [1'u32, 20, 0, 20, 1, 0]

setup()
completionSucceeds = false
hook = proc(phase: string) =
  fakeUs += (if phase == "idle": 3'u32 else: 18'u32)
doAssert mm_sec_machwkey_wr(addr req) == 0xFF and irq
doAssert wifiKeyWriteTiming[1] == [2'u32, 20, 18, 21, 1, 1]
doAssert wifiKeyWriteTiming[0] == [1'u32, 4, 7, 11, 0, 0]
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_hardware_key_rejects_oversized_receive_pn(tmp_path: Path, mode: str) -> None:
    mm = (FW / "kernel_mac_channel.nim").read_text()
    body = proc_body(mm, "mm_sec_machwkey_wr")
    checks = r'''
for cipher in [1'u8, 2'u8, 5'u8]:
  for group in [false, true]:
    if cipher == 5 and not group: continue
    for highByte in 0 .. 1:
      setup()
      var req = requestFor(cipher, group)
      req.macAddrCipherPadding[highByte] = 1
      let original = req
      doAssert mm_sec_machwkey_wr(addr req) == 0xFF
      doAssert req == original and events.len == 0 and not installed and irq
    setup()
    var req = requestFor(cipher, group)
    req.macLen = 8
    req.macAddr[5] = 0xFF
    doAssert mm_sec_machwkey_wr(addr req) != 0xFF,
      "eight-byte replay field with zero upper bytes was rejected"
'''
    run_nim(tmp_path, harness(WRITE_PLATFORM, body) + checks, mode)
