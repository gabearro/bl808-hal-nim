"""Execute security-table deletion and address search with modeled MMIO."""

from pathlib import Path
import re

import pytest

from test_wifi_station_keys import FW, harness, proc_body, run_nim


PLATFORM = r"""
const
  MAX_VIFS = 2
  STA_INFO_TAB_ENTRIES = 7
type
  Vif = object
    index: uint8
    defaultKeyPtr: uint32
    installed: array[6, bool]
  MacAddrView {.packed.} = object
    bytes: array[6, uint8]
  Command = tuple[control, low, high: uint32]
var
  vifs: array[2, Vif]
  rxVifEpochs: array[2, uint32]
  stationEpochs: array[5, uint32]
  commands: seq[Command]
  events: seq[string]
  irq, idleOk, doneOk: bool
  topCount, searchStatus, control, low, high: uint32
  material: array[4, uint32]
  hook: proc(stage: string)
proc irqSave(): uint32 =
  result = if irq: 8'u32 else: 0'u32
  irq = false
proc irqRestore(saved: uint32) = irq = (saved and 8) != 0
proc event(name: string) =
  doAssert not irq, "security operation enabled interrupts"
  events.add(name)
proc vifChannelForIdx(index: uint8): ptr Vif =
  doAssert index < 2
  addr vifs[index]
proc vifKeyPointers(vif: ptr Vif): ptr Vif = vif
proc vifKeySlotPtr(vif: ptr Vif; slot: uint): uint32 =
  doAssert slot < 6
  1 + vif.index.uint32 * 6 + slot.uint32
proc vif_mgmt_del_key(p: pointer; slot: uint8) =
  let vif = cast[ptr Vif](p)
  doAssert slot < 6
  event("vif")
  vif.installed[slot] = false
  if vif.defaultKeyPtr == vifKeySlotPtr(vif, slot.uint):
    vif.defaultKeyPtr = 0
    for other in 0 .. 3:
      if vif.installed[other]:
        vif.defaultKeyPtr = vifKeySlotPtr(vif, other.uint)
        break
proc staDeleteEpoch(index: uint8): uint32 =
  if index < 5: stationEpochs[index] else: 0
proc staMacWords(sta: ptr StaInfoView): tuple[lo, hi: uint32] =
  for i in 0 ..< 4: result.lo = result.lo or (sta.macAddr[i].uint32 shl (i * 8))
  for i in 0 ..< 2: result.hi = result.hi or (sta.macAddr[i + 4].uint32 shl (i * 8))
proc macAddrAt(p: pointer): ptr MacAddrView = cast[ptr MacAddrView](p)
proc machwSecurityKeyCount(): uint32 = topCount shl 24
proc machwSecurityControl(): uint32 = control
proc machwSecurityWriteAddress(lo, hi: uint32) =
  event("address")
  low = lo
  high = hi
proc machwSecurityClearKeyMaterial() =
  event("clear")
  material = default(typeof(material))
proc machwSecurityWriteControl(value: uint32) =
  event("command")
  control = value
  commands.add((value, low, high))
proc waitMachwSecurityControlClear(mask: uint32): bool =
  let idle = mask == 0xE0000000'u32
  event(if idle: "idle" else: "done")
  if hook != nil: hook(if idle: "idle" else: "done")
  if not idle and mask == 0x20000000'u32: control = searchStatus
  if idle: idleOk else: doneOk
proc setup(incomingIrq = true) =
  irq = incomingIrq
  idleOk = true
  doneOk = true
  topCount = 14
  searchStatus = 8'u32 shl 16
  control = 0
  low = 0xCAFECAFE'u32
  high = 0xBABE'u32
  material = [1'u32, 2, 3, 4]
  commands.setLen(0)
  events.setLen(0)
  hook = nil
  vifs = default(typeof(vifs))
  rxVifEpochs = [11'u32, 12]
  stationEpochs = [1'u32, 2, 3, 4, 5]
  for i in 0 .. 1:
    vifs[i].index = i.uint8
    for slot in 0 .. 5: vifs[i].installed[slot] = true
    vifs[i].defaultKeyPtr = vifKeySlotPtr(addr vifs[i], 0)
  sta_info_tab = default(typeof(sta_info_tab))
  for i in 0 ..< 7:
    sta_info_tab[i].instNbr = (if i < 5: i and 1 else: i - 5).uint8
    sta_info_tab[i].macAddr = [i.uint8, 0x12, 0x34, 0x56, 0x78, 0x9A]
    sta_info_tab[i].keyInstalled = 1
    sta_info_tab[i].keyHolder = addr sta_info_tab[i].keyArea[0]
    sta_info_tab[i].controlPortState = 2
"""

CHECKS = r"""
for incomingIrq in [false, true]:
  for key in 0'u8 .. 18:
    setup(incomingIrq)
    let mac = if key in 8'u8 .. 14'u8: staMacWords(addr sta_info_tab[key - 8])
      else: (0xFFFFFFFF'u32, 0xFFFFFFFF'u32)
    doAssert mmDeleteSecurityKey(key)
    doAssert irq == incomingIrq
    if key > 14:
      let vif = (key - 15) div 2
      let slot = 4 + ((key - 15) and 1)
      doAssert events == @["vif"] and commands.len == 0
      doAssert not vifs[vif].installed[slot]
      doAssert material == [1'u32, 2, 3, 4]
    else:
      doAssert commands == @[(0x40000000'u32 or (key.uint32 shl 16), mac[0], mac[1])]
      doAssert material == [0'u32, 0, 0, 0]
      if key < 8:
        doAssert events == @["vif", "idle", "address", "clear", "command", "done"]
        doAssert not vifs[key shr 2].installed[key and 3]
      else:
        doAssert events == @["idle", "address", "clear", "command", "done"]
        let sta = addr sta_info_tab[key - 8]
        doAssert sta.keyInstalled == 0 and sta.keyHolder == nil
        doAssert sta.controlPortState == 1

# Exercise every command index and every capacity byte independently.
for key in 0'u16 .. 255:
  setup()
  let accepted = mmDeleteSecurityKey(key.uint8)
  doAssert accepted == (key <= 18)
  if not accepted: doAssert events.len == 0 and commands.len == 0
for count in 0'u32 .. 255:
  for key in [0'u8, 7, 8, 14, 15, 18, 19, 254, 255]:
    setup()
    topCount = count
    let valid = key != 255 and
      (if key.uint32 <= count: key <= 14
       else: count in 14'u32 .. 250'u32 and key.uint32 - count <= 4)
    doAssert mmDeleteSecurityKey(key) == valid
for invalidVif in 2'u16 .. 255:
  setup()
  sta_info_tab[0].instNbr = invalidVif.uint8
  doAssert not mmDeleteSecurityKey(8)
  doAssert events.len == 0 and sta_info_tab[0].keyInstalled == 1

# Retire an active GTK before waiting. Do not close another VIF, or close the
# port when a valid replacement key remains available.
for vif in 0'u8 .. 1:
  for fallback in [false, true]:
    for phase in ["idle", "done"]:
      setup()
      vifs[vif].installed = [false, true, fallback, false, false, false]
      vifs[vif].defaultKeyPtr = vifKeySlotPtr(addr vifs[vif], 1)
      if phase == "idle": idleOk = false
      else: doneOk = false
      doAssert not mmDeleteSecurityKey(vif * 4 + 1)
      doAssert not vifs[vif].installed[1]
      for sta in sta_info_tab:
        let closed = sta.instNbr == vif and not fallback
        doAssert sta.controlPortState == (if closed: 1'u8 else: 2'u8)
      doAssert commands.len == (phase == "done").int
      if phase == "idle":
        doAssert material == [1'u32, 2, 3, 4] and low == 0xCAFECAFE'u32

for phase in ["idle", "done"]:
  for change in 0 .. 3:
    setup()
    if phase == "idle": idleOk = false
    else: doneOk = false
    doAssert not mmDeleteSecurityKey(8)
    doAssert sta_info_tab[0].keyInstalled == 0 and sta_info_tab[0].keyHolder == nil
    doAssert sta_info_tab[0].controlPortState == 1
    doAssert commands.len == (phase == "done").int
    setup()
    hook = proc(stage: string) =
      if stage != phase: return
      case change
      of 0: inc rxVifEpochs[0]
      of 1: inc stationEpochs[0]
      of 2: sta_info_tab[0].macAddr[0] = 0xEE
      else: sta_info_tab[0].instNbr = 1
      sta_info_tab[0].keyInstalled = 1
      sta_info_tab[0].controlPortState = 2
    doAssert not mmDeleteSecurityKey(8)
    doAssert sta_info_tab[0].keyInstalled == 1 and sta_info_tab[0].controlPortState == 2
    doAssert commands.len == (phase == "done").int

for incomingIrq in [false, true]:
  for index in 0'u16 .. 255:
    setup(incomingIrq)
    doAssert mmDeleteSecurityAddress(index.uint8) == (index < 7)
    doAssert irq == incomingIrq
    if index < 7:
      doAssert commands == @[(0x40000000'u32 or ((index.uint32 + 8) shl 16),
        0xFFFFFFFF'u32, 0xFFFFFFFF'u32)]
    else: doAssert events.len == 0 and commands.len == 0
  for phase in ["idle", "done"]:
    setup(incomingIrq)
    if phase == "idle": idleOk = false
    else: doneOk = false
    doAssert not mmDeleteSecurityAddress(0) and irq == incomingIrq
    doAssert commands.len == (phase == "done").int

var query = [0'u8, 0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC]
let expectedLow = 0x78563412'u32
let expectedHigh = 0xBC9A'u32
for incomingIrq in [false, true]:
  for hwIndex in 0'u32 .. 255:
    for missing in [false, true]:
      setup(incomingIrq)
      searchStatus = (hwIndex shl 16) or (if missing: 0x10000000'u32 else: 0'u32)
      let expected = if not missing and hwIndex in 8'u32 .. 14'u32: hwIndex - 8 else: 0xFF'u32
      doAssert hal_machw_search_addr(addr query[1], 99) == expected
      doAssert irq == incomingIrq
      doAssert commands == @[(0x20000000'u32, expectedLow, expectedHigh)]
      doAssert material == [1'u32, 2, 3, 4]
  for phase in ["idle", "done"]:
    setup(incomingIrq)
    if phase == "idle": idleOk = false
    else: doneOk = false
    doAssert hal_machw_search_addr(addr query[1], 0) == 0xFF
    doAssert irq == incomingIrq and commands.len == (phase == "done").int

setup()
doAssert hal_machw_search_addr(nil, 0) == 0xFF and events.len == 0 and irq
setup()
hook = proc(stage: string) =
  if stage == "idle": query = [0'u8, 1, 2, 3, 4, 5, 6]
doAssert hal_machw_search_addr(addr query[1], 0) == 0
doAssert commands == @[(0x20000000'u32, expectedLow, expectedHigh)]

# The vendor-facing void wrappers still execute exactly one checked operation.
setup()
mm_sec_machwkey_del(8)
doAssert commands.len == 1
setup()
mm_sec_machwaddr_del(0)
doAssert commands.len == 1
"""


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("mutation", [None, "irq", "bip_bound", "physical_bound", "vif_bound", "address_bound",
    "search_bound", "key_idle", "key_done", "address_idle", "address_done", "search_idle",
    "search_done", "port_gate", "epoch", "mac", "snapshot"])
def test_security_transactions(tmp_path: Path, mode: str, mutation: str | None) -> None:
    source = (FW / "kernel_mac_channel.nim").read_text()
    names = ["mmDeleteSecurityKey", "mm_sec_machwkey_del", "mmDeleteSecurityAddress",
             "mm_sec_machwaddr_del", "hal_machw_search_addr"]
    parts = {name: proc_body(source, name) for name in names}
    before = dict(parts)
    key, address, search = names[0], names[2], names[4]
    if mutation == "irq":
        for name in [key, address, search]:
            parts[name] = parts[name].replace("  let saved = irqSave()\n  defer: irqRestore(saved)\n", "")
    elif mutation == "bip_bound":
        parts[key] = parts[key].replace("pairwiseKeySlotOffset >= 2 * MAX_VIFS", "false")
    elif mutation == "physical_bound":
        parts[key] = parts[key].replace("keyIdx >= 8 + STA_INFO_TAB_ENTRIES.uint8", "false")
    elif mutation == "vif_bound":
        parts[key] = parts[key].replace("vifIdx >= MAX_VIFS.uint8", "false")
    elif mutation == "address_bound":
        parts[address] = parts[address].replace("staIdx >= STA_INFO_TAB_ENTRIES.uint8", "false")
    elif mutation == "search_bound":
        parts[search] = parts[search].replace("hwIdx < 8 or hwIdx >= 8 + STA_INFO_TAB_ENTRIES.uint32", "false")
    elif mutation in ["key_idle", "address_idle", "search_idle"]:
        name = {"key_idle": key, "address_idle": address, "search_idle": search}[mutation]
        parts[name] = parts[name].replace("not waitMachwSecurityControlClear(0xE0000000'u32)", "false")
    elif mutation == "key_done":
        parts[key] = parts[key].replace("completed and current()", "current()")
    elif mutation == "address_done":
        parts[address] = parts[address].replace("  waitMachwSecurityControlClear(0x40000000'u32)", "  true")
    elif mutation == "search_done":
        parts[search] = parts[search].replace("not waitMachwSecurityControlClear(0x20000000'u32)", "false")
    elif mutation == "port_gate":
        parts[key] = parts[key].replace("station.controlPortState = 1", "discard")
    elif mutation == "epoch":
        parts[key] = parts[key].replace("rxVifEpochs[vifIdx] == vifEpoch", "true")
    elif mutation == "mac":
        parts[key] = parts[key].replace("staMacWords(staInfoForIdx(staIdx)) == mac", "true")
    elif mutation == "snapshot":
        capture = "  let macLow = addrView.lowLe\n  let macHigh = addrView.highLe\n"
        parts[search] = parts[search].replace(capture, "")
        parts[search] = parts[search].replace("  machwSecurityWriteAddress(macLow, macHigh)",
                                             capture + "  machwSecurityWriteAddress(macLow, macHigh)")
    if mutation is not None:
        assert parts != before, mutation
    layout = (FW / "layout_types.nim").read_text()
    mac_helpers = proc_body(layout, "lowLe") + proc_body(layout, "highLe")
    sta = proc_body((FW / "sta_management.nim").read_text(), "sta_mgmt_del_key")
    # proc_body also includes intervening type blocks; the wrappers' readback
    # type is harmless, but do not bring in unrelated layout templates.
    mac_helpers = re.sub(r"\ntemplate tdEntryAt.*", "", mac_helpers, flags=re.S)
    run_nim(tmp_path, harness(PLATFORM, mac_helpers, sta, *parts.values()) + CHECKS,
            mode, mutation)
