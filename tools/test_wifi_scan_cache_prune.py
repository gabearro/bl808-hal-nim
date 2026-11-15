"""Exercise retained RX-frame pruning across free, logging, and IRQ hooks."""

from pathlib import Path
import re
import shutil
import subprocess

import pytest

from test_wifi_disconnect_tx import procedure

ROOT = Path(__file__).resolve().parents[1]
FW = ROOT / "src/bl808/wifi/fw"

PLATFORM = r"""
const
  SCANU_MAX_RESULT_ENTRIES = 6
  IE_ID_SSID = 0'u8
type
  ScanuResultEntry = object
    bssid: array[6, uint8]
    valid: uint8
    rssi: int8
    cachedRxuMgtInd: pointer
    ssid, channel: uint32
  Env = object
    entries: array[SCANU_MAX_RESULT_ENTRIES, ScanuResultEntry]
    filterSsidLen: uint8
    filterSsid: array[32, uint8]
  Frame = object
    frameLen: uint16
    ies: array[64, uint8]
  MacIeView {.packed.} = object
    id, len: uint8
  SsidIe = object
    ie: MacIeView
    ssidBytes: array[32, uint8]
  Ssid = object
    length: uint8
    ssidBytes: array[32, uint8]
  Log = proc(level, severity: uint32; file: pointer;
             line: uint32) {.cdecl, varargs.}
var
  scanu_env, replacement: Env
  oldFrames, newFrames: array[SCANU_MAX_RESULT_ENTRIES, Frame]
  freed: array[SCANU_MAX_RESULT_ENTRIES, int]
  filter: Ssid
  interruptsEnabled, incoming: bool
  hook: proc(point: string)
  comparisons: int

proc fire(point: string) =
  if hook != nil: hook(point)
proc irqSave(): uint32 =
  result = if interruptsEnabled: 8'u32 else: 0'u32
  interruptsEnabled = false
proc irqRestore(saved: uint32) =
  interruptsEnabled = (saved and 8) != 0
  if interruptsEnabled: fire("restore")
proc c_memset(p: pointer; c: cint; size: csize_t): pointer {.importc: "memset", header: "<string.h>".}
proc rawMemcmp(a, b: pointer; size: csize_t): cint {.importc: "memcmp", header: "<string.h>".}
proc c_memcmp(a, b: pointer; size: csize_t): cint =
  doAssert not interruptsEnabled and size <= 32
  inc comparisons
  rawMemcmp(a, b, size)
proc lengthPrefixedSsidView(p: pointer): ptr Ssid = cast[ptr Ssid](p)
proc scanuClearCachedSsid(entry: ptr ScanuResultEntry) =
  doAssert not interruptsEnabled
  entry.ssid = 0
proc scanuClearCachedChannel(entry: ptr ScanuResultEntry) =
  doAssert not interruptsEnabled
  entry.channel = 0
proc logHook(level: uint32; tag, file: cstring; line: cint;
             format: cstring) {.cdecl, varargs.} =
  doAssert level == 2 and tag == nil and file == cstring("scanu.c")
  doAssert format != nil
  doAssert interruptsEnabled == incoming
  fire("log" & $line)
proc getLogFunc(offset: int): Log =
  doAssert offset == 204, "vendor logger slot is 0xCC"
  cast[Log](logHook)
proc ke_msg_free_payload(p: pointer) =
  if p == nil: return
  doAssert interruptsEnabled == incoming
  for i in 0 ..< oldFrames.len:
    if p == addr oldFrames[i]:
      inc freed[i]
      doAssert freed[i] == 1, "old frame released twice"
      oldFrames[i] = default(Frame)
      fire("free" & $i)
      return
  doAssert false, "old pruning released a fresh frame"
proc macPtrIsSpecific(p: pointer): bool =
  doAssert not interruptsEnabled
  if p == nil: return false
  let bytes = cast[ptr array[6, uint8]](p)
  bytes[0] == 2
proc scanu_search_by_bssid(p: pointer): pointer =
  doAssert not interruptsEnabled
  let bytes = cast[ptr array[6, uint8]](p)
  for entry in scanu_env.entries.mitems:
    if entry.valid != 0 and entry.bssid == bytes[]: return addr entry
proc rxuMgtIndAt(p: pointer): ptr Frame =
  doAssert not interruptsEnabled
  cast[ptr Frame](p)
proc rxuMgtIndIeStart(p: pointer): pointer = addr cast[ptr Frame](p).ies[0]
proc macIeAt(p: uint): ptr MacIeView = cast[ptr MacIeView](p)
proc totalLen(ie: ptr MacIeView): uint = ie.len.uint + 2
proc ssidIeAt(p: pointer): ptr SsidIe = cast[ptr SsidIe](p)
"""

CHECKS = r"""
proc setup(irq: bool) =
  hook = nil
  incoming = irq
  interruptsEnabled = irq
  scanu_env = default(Env)
  oldFrames = default(typeof(oldFrames))
  newFrames = default(typeof(newFrames))
  freed = default(typeof(freed))
  comparisons = 0
  filter = Ssid(length: 1)
  filter.ssidBytes[0] = 120
  scanu_env.filterSsidLen = 1
  scanu_env.filterSsid[0] = 120
  for i in 0 ..< oldFrames.len:
    oldFrames[i].frameLen = 39
    oldFrames[i].ies[0] = 0
    oldFrames[i].ies[1] = 1
    oldFrames[i].ies[2] = 120
    scanu_env.entries[i] = ScanuResultEntry(valid: 1, rssi: (-60 + i).int8,
      cachedRxuMgtInd: addr oldFrames[i], ssid: i.uint32 + 1, channel: 2412)
    scanu_env.entries[i].bssid = [2'u8, 0, 0, 0, 0, i.uint8]

proc run(route: string) =
  case route
  of "all": wifi_nimfw_release_scan_raw_cache()
  of "bssid": scanu_prune_scanresult_raw_frames_except_bssid(addr scanu_env.entries[2].bssid[0])
  of "ssid": wifi_nimfw_prune_scan_raw_cache_for_ssid(cast[cstring](addr filter.ssidBytes[0]), filter.length.uint32)
  of "remove": scanu_rm_exist_ssid(addr filter, 3)
  else: doAssert false

proc isRemoved(route: string; i: int): bool =
  case route
  of "all": true
  of "bssid": i != 2
  of "ssid": i != SCANU_MAX_RESULT_ENTRIES - 1
  else: i == 3

proc installReplacement(point: string) =
  for i in 0 ..< oldFrames.len:
    scanu_env.entries[i] = ScanuResultEntry(valid: 1, rssi: -10,
      cachedRxuMgtInd: addr newFrames[i], ssid: 99, channel: 2462)
    if point == "free" & $i:
      # The allocator may hand the just-freed address to the new cache.
      scanu_env.entries[i].cachedRxuMgtInd = addr oldFrames[i]
  scanu_env.filterSsidLen = 31
  filter.length = 255
  replacement = scanu_env

for route in ["all", "bssid", "ssid", "remove"]:
  var points: seq[string]
  for i in 0 ..< SCANU_MAX_RESULT_ENTRIES:
    if isRemoved(route, i): points.add("free" & $i)
  points.add("restore")
  if route == "remove": points.add(@["log1032", "log1043", "log1046"])
  for irq in [false, true]:
    for trigger in points:
      if trigger == "restore" and not irq: continue
      for recursive in [false, true]:
        setup(irq)
        let original = scanu_env
        var fired = false
        hook = proc(point: string) =
          if fired or point != trigger: return
          fired = true
          doAssert interruptsEnabled == incoming
          for i, entry in scanu_env.entries:
            if isRemoved(route, i): doAssert entry.cachedRxuMgtInd == nil
            else: doAssert entry == original.entries[i]
            if route != "remove":
              var expected = original.entries[i]
              expected.cachedRxuMgtInd = entry.cachedRxuMgtInd
              doAssert entry == expected, "pruning changed structured results"
          if route == "remove":
            doAssert scanu_env.entries[3] == default(ScanuResultEntry)
          if recursive: run(route)
          installReplacement(point)
        run(route)
        hook = nil
        doAssert fired and interruptsEnabled == irq
        doAssert scanu_env == replacement, "old pruning erased replacement cache"
        for i, count in freed: doAssert count == isRemoved(route, i).int

for irq in [false, true]:
  for index in [6, 7, 127, 128, 255]:
    setup(irq)
    let before = scanu_env
    scanu_rm_exist_ssid(addr filter, index.uint8)
    doAssert scanu_env == before and comparisons == 0
    for count in freed: doAssert count == 0
  for length in [0, 1, 32, 33, 255]:
    setup(irq)
    filter.length = length.uint8
    scanu_env.filterSsidLen = length.uint8
    for b in filter.ssidBytes.mitems: b = 120
    for b in scanu_env.filterSsid.mitems: b = 120
    let before = scanu_env
    scanu_rm_exist_ssid(addr filter, 3)
    doAssert freed[3] == (length <= 32).int
    if length <= 32:
      doAssert scanu_env.entries[3] == default(ScanuResultEntry)
    else:
      doAssert scanu_env == before and comparisons == 0
  setup(irq)
  let before = scanu_env
  scanu_rm_exist_ssid(nil, 3)
  doAssert before == scanu_env and comparisons == 0
  setup(irq)
  filter.ssidBytes[0] = 121
  let mismatch = scanu_env
  scanu_rm_exist_ssid(addr filter, 3)
  doAssert mismatch == scanu_env and freed[3] == 0
  setup(irq)
  scanu_env.entries[3].cachedRxuMgtInd = nil
  scanu_rm_exist_ssid(addr filter, 3)
  doAssert scanu_env.entries[3] == default(ScanuResultEntry)
  for count in freed: doAssert count == 0
  setup(irq)
  scanu_env.entries[3].valid = 0
  let invalid = scanu_env
  scanu_rm_exist_ssid(addr filter, 3)
  doAssert scanu_env == invalid and comparisons == 0
  setup(irq)
  for entry in scanu_env.entries.mitems: entry.cachedRxuMgtInd = nil
  let empty = scanu_env
  run("all")
  doAssert scanu_env == empty
  for count in freed: doAssert count == 0

  # A missing BSSID or unmatched SSID prunes all raw frames, not the records.
  setup(irq)
  scanu_prune_scanresult_raw_frames_except_bssid(nil)
  for i, entry in scanu_env.entries:
    doAssert freed[i] == 1 and entry.cachedRxuMgtInd == nil and entry.valid == 1
  setup(irq)
  filter.ssidBytes[0] = 121
  run("ssid")
  for count in freed: doAssert count == 1

  # First-entry tie breaking, 32-byte SSIDs, and malformed/truncated IEs.
  for length in [1, 32]:
    setup(irq)
    filter.length = length.uint8
    for b in filter.ssidBytes.mitems: b = 120
    for i in 0 ..< oldFrames.len:
      oldFrames[i].frameLen = (38 + length).uint16
      oldFrames[i].ies[1] = length.uint8
      for j in 0 ..< length: oldFrames[i].ies[j + 2] = 120
      scanu_env.entries[i].rssi = -30
    run("ssid")
    doAssert freed[0] == 0 and scanu_env.entries[0].cachedRxuMgtInd != nil
    for i in 1 ..< freed.len: doAssert freed[i] == 1
  for malformed in [0, 1, 2]:
    setup(irq)
    for frame in oldFrames.mitems:
      frame.frameLen = (if malformed == 0: 35 elif malformed == 1: 37 else: 39)
      frame.ies[1] = 63
    run("ssid")
    for count in freed: doAssert count == 1
  for length in [0, 33]:
    setup(irq)
    let beforeInvalid = scanu_env
    wifi_nimfw_prune_scan_raw_cache_for_ssid(cast[cstring](addr filter.ssidBytes[0]), length.uint32)
    doAssert scanu_env == beforeInvalid
  setup(irq)
  let beforeNil = scanu_env
  wifi_nimfw_prune_scan_raw_cache_for_ssid(nil, 1)
  doAssert scanu_env == beforeNil
"""


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("mutation", [None, "detach", "partial", "remove_detach",
                                      "index", "length", "logger", "unlocked", "keep"])
def test_scan_cache_pruning(tmp_path: Path, mode: str, mutation: str | None) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("Nim is required")
    scan = (FW / "scan_station_ap_me.nim").read_text()
    names = ["scanu_rm_exist_ssid", "scanuDetachRawScanFrames",
             "scanu_prune_scanresult_raw_frames", "scanu_prune_scanresult_raw_frames_except_bssid",
             "wifi_nimfw_release_scan_raw_cache", "wifi_nimfw_prune_scan_raw_cache_for_ssid"]
    bodies = {name: procedure(scan, name) for name in names}
    if mutation == "detach":
        bodies[names[1]] = bodies[names[1]].replace("      scanResultEntry.cachedRxuMgtInd = nil\n", "")
    elif mutation == "partial":
        bodies[names[2]] = """
proc scanu_prune_scanresult_raw_frames() =
  for entry in scanu_env.entries.mitems:
    let frame = entry.cachedRxuMgtInd
    entry.cachedRxuMgtInd = nil
    ke_msg_free_payload(frame)
"""
    elif mutation == "remove_detach":
        old = "          discard c_memset(ssidIndexResultEntry, 0, sizeof(ScanuResultEntry).csize_t)\n"
        assert old in bodies[names[0]]
        bodies[names[0]] = bodies[names[0]].replace(old, "")
    elif mutation == "index":
        bodies[names[0]] = bodies[names[0]].replace("ssidResultEntryIndex.int < SCANU_MAX_RESULT_ENTRIES", "true")
    elif mutation == "length":
        bodies[names[0]] = bodies[names[0]].replace("inputSsidLen <= 32 and ", "")
    elif mutation == "logger":
        bodies[names[0]] = bodies[names[0]].replace("getLogFunc(204)", "getLogFunc(4)")
    elif mutation == "unlocked":
        bodies[names[1]] = bodies[names[1]].replace("  let saved = irqSave()\n  defer: irqRestore(saved)\n", "")
    elif mutation == "keep":
        bodies[names[5]] = bodies[names[5]].replace("scanuDetachRawScanFrames(bestScanResultEntry)", "scanuDetachRawScanFrames()")
    layout = (FW / "layout_types.nim").read_text()
    count = int(re.search(r"(?m)^const SCANU_MAX_RESULT_ENTRIES\* = (\d+)$", layout).group(1))
    platform = PLATFORM.replace("SCANU_MAX_RESULT_ENTRIES = 6", f"SCANU_MAX_RESULT_ENTRIES = {count}")
    mac = procedure((FW / "mac_config_debug.nim").read_text(), "mac_ie_find")
    program = tmp_path / "prune.nim"
    program.write_text(platform + mac + "\n".join(bodies.values()) + CHECKS)
    flags = {"checked": [], "release": ["-d:release", "--assertions:on"],
             "asan": ["--cc:clang", "--passC:-fsanitize=address", "--passL:-fsanitize=address"]}
    result = subprocess.run([nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on", "--skipUserCfg:on",
        f"--nimcache:{tmp_path / 'cache'}", f"-o:{tmp_path / 'test'}", *flags[mode], str(program)],
        cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=120)
    if mutation is None:
        assert result.returncode == 0, result.stdout
    else:
        assert result.returncode != 0 and any(reason in result.stdout for reason in
            ["AssertionDefect", "IndexDefect"]), result.stdout
