"""Execute hardware key reads, GTK propagation, and coherent diagnostic dumps."""

from pathlib import Path
import re
import shutil
import subprocess

import pytest

from test_wifi_disconnect_tx import procedure

ROOT = Path(__file__).resolve().parents[1]
FW = ROOT / "src/bl808/wifi/fw"

PLATFORM = r'''
const MAX_VIFS = 2
type
  KeySlot = object
    installed, cipherType, keyIdx, staIdx: uint8
    keyMaterial: array[16, uint8]
  Vif = object
    index: uint8
    defaultKeyPtr: uint32
    keys: array[4, KeySlot]
  PlatformLogFunc = proc(level: uint32; tag, file: cstring; line: cint;
                         format: cstring) {.cdecl, varargs, raises: [Exception].}
  Regs = object
    keyCount, control, dataLow, dataHigh: uint32
    keyMaterial: array[4, uint32]
  Ops = object
    macAddrLow, macAddrHigh, adapterTimingConfig28: uint32
    beaconProbeCountdown, adapterTimingConfig36: uint32
    adapterTimingConfig40, adapterTimingConfig44: uint32
  LogRecord = object
    line: uint32
    count: int
    values: array[16, uint32]
var
  vifs: array[2, Vif]
  rxVifEpochs: array[2, uint32]
  rxKeyRevision: uint64
  rxKeyLastChanged: array[19, uint64]
  readHook: proc()
  regs: Regs
  ops: Ops
  bank: array[256, MmSecurityReadback]
  commands: seq[uint32]
  records: seq[LogRecord]
  irq, idleSucceeds, completionSucceeds, logging: bool
  failedIndex, timingCalls, lookupCalls: int
  keyIndex, lookupStatus: uint8
  debugFlag: uint32
  hook: proc(line: uint32)
  copyHook: proc()
proc irqSave(): uint32 =
  result = if irq: 8'u32 else: 0'u32
  irq = false
proc irqRestore(saved: uint32) = irq = (saved and 8) != 0
proc vifChannelForIdx(index: uint8): ptr Vif = addr vifs[index]
proc vifKeySlot(vif: ptr Vif; slot: uint): ptr KeySlot = addr vif.keys[slot]
proc vifKeySlotPtr(vif: ptr Vif; slot: uint): uint32 =
  cast[uint32](cast[uint](vifKeySlot(vif, slot)))
proc vifKeyPointers(vif: ptr Vif): ptr Vif = vif
proc rxMgtKeyIndex(key: pointer): int =
  for vif in 0..1:
    for slot in 0..3:
      if key == cast[pointer](addr vifs[vif].keys[slot]): return 7 + vif * 6 + slot
  -1
proc machwSecurityRegs(): ptr Regs = addr regs
proc machwSecurityKeyCount(): uint32 = regs.keyCount
proc machwSecurityControl(): uint32 = regs.control
proc machwSecurityWriteControl(value: uint32) =
  doAssert not irq
  commands.add(value)
  regs.control = value
proc waitMachwSecurityControlClear(mask: uint32): bool =
  doAssert not irq
  if mask == 0xE0000000'u32: return idleSucceeds
  doAssert mask == 0x80000000'u32
  let index = ((regs.control shr 16) and 0xFF).int
  if not completionSucceeds or index == failedIndex: return false
  let item = bank[index]
  regs.control = item.control
  regs.dataLow = item.macLow
  regs.dataHigh = item.macHigh
  regs.keyMaterial = item.words
  if readHook != nil: readHook()
  true
proc volatileLoad(p: ptr uint32): uint32 =
  if cast[uint](p) == 0x20005198'u: debugFlag else: p[]
proc volatileStore(p: ptr uint32; value: uint32) =
  if cast[uint](p) == 0x20005198'u: debugFlag = value
  else: p[] = value
proc c_memcpy(dst, src: pointer; length: csize_t): pointer =
  doAssert src != cast[pointer](addr regs.keyMaterial[0]), "live MMIO copied"
  doAssert length > 0 and length <= 32
  if copyHook != nil:
    let callback = copyHook
    copyHook = nil
    callback()
  copyMem(dst, src, length.int)
  dst
proc blOpsData(): ptr Ops = addr ops
proc beaconTimeoutConfigWord(p: ptr Ops): uint32 = 0
proc hal_machw_timing_info() = inc timingCalls
proc assert_err(a, b: cstring; line: cint) = doAssert false, "unexpected assertion"
proc sm_get_set_machwkey_index(getFlag, vif: uint32; output: pointer;
                              kind: uint32): uint8 =
  doAssert not irq and getFlag == 1 and vif < 2 and kind == 1
  inc lookupCalls
  cast[ptr uint8](output)[] = keyIndex
  lookupStatus
proc testObserveLog(line: uint32; data: ptr uint32; count: cint) {.exportc, cdecl.} =
  var record = LogRecord(line: line, count: count.int)
  let values = cast[ptr UncheckedArray[uint32]](data)
  for i in 0 ..< count.int: record.values[i] = values[i]
  records.add(record)
  if hook != nil: hook(line)
{.emit: """
#include <stdint.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <assert.h>
extern void testObserveLog(uint32_t, uint32_t *, int);
static void test_key_logger(uint32_t level, char *tag, char *file,
                            int line, char *format, ...) {
  assert(level == 2 && tag == NULL && file && strcmp(file, "mm.c") == 0);
  const char *expected = NULL;
  int n = 0;
  switch (line) {
    case 945: expected = "==========================  Keyram Config ========================\r\n"; break;
    case 946: expected = "  start %02u -->> end %02u; nVAP %02u; max %02u\r\n"; n = 4; break;
    case 972: expected = "==========================  Keyram Dump =========================\r\n"; break;
    case 977: expected = "[id]   MAC Address     Key Len  VLan ID  Default      \tKey Hexdump(16Bytes MAX)\r\n"; break;
    case 989: expected = "[%02d] %02X:%02X:%02X:%02X:%02X:%02X"; n = 7; break;
    case 998: expected = " %s"; n = 1; break;
    case 999: expected = "    %02u"; n = 1; break;
    case 1000: expected = "        %u"; n = 1; break;
    case 1007: expected = "     %02X%02X%02X%02X %02X%02X%02X%02X %02X%02X%02X%02X %02X%02X%02X%02X"; n = 16; break;
    case 1014: case 1037: case 1059: expected = "\r\n"; break;
    case 1016: expected = "==========================  MAC Address =========================\r\n"; break;
    case 1019: expected = "    MAC %02X:%02X:%02X:%02X:%02X:%02X"; n = 6; break;
    case 1029: case 1051: expected = " Mask %02X:%02X:%02X:%02X:%02X:%02X"; n = 6; break;
    case 1041: expected = "  BSSID %02X:%02X:%02X:%02X:%02X:%02X"; n = 6; break;
  }
  assert(expected && format && strcmp(format, expected) == 0);
  uint32_t values[16] = {0};
  va_list args;
  va_start(args, format);
  va_list render_args;
  va_copy(render_args, args);
  char output[256];
  int written = vsnprintf(output, sizeof(output), format, render_args);
  va_end(render_args);
  assert(written >= 0 && written < (int)sizeof(output));
  if (line == 998) {
    const char *length = va_arg(args, const char *);
    assert(length && (!strcmp(length, "128-Bit") || !strcmp(length, " 64-Bit")));
    values[0] = !strcmp(length, "128-Bit");
  } else {
    for (int i = 0; i < n; ++i)
      values[i] = line == 989 && i == 0 ? (uint32_t)va_arg(args, int)
                                       : va_arg(args, unsigned int);
  }
  va_end(args);
  testObserveLog(line, values, n);
}
""".}
proc test_key_logger(level: uint32; tag, file: cstring; line: cint;
                     format: cstring) {.importc, cdecl, varargs, nodecl.}
proc getLogFunc(offset: int): PlatformLogFunc =
  doAssert offset == 204
  if logging: cast[PlatformLogFunc](test_key_logger) else: nil
proc setup(last: uint8 = 14; top: uint8 = 14; longKey = true;
           incomingIrq = true) =
  regs = Regs(keyCount: (top.uint32 shl 24) or 0x005A00C3'u32 or (last.uint32 shl 8))
  for i in 0 ..< bank.len:
    bank[i] = MmSecurityReadback(control: (i.uint32 shl 16) or 0x26 or longKey.uint32,
      macLow: 0x12345600'u32 or i.uint32, macHigh: 0x9A78,
      words: [0x11000000'u32 or i.uint32, 0x22000000'u32 or i.uint32,
              0x33000000'u32 or i.uint32, 0x44000000'u32 or i.uint32])
  commands.setLen(0)
  records.setLen(0)
  irq = incomingIrq
  idleSucceeds = true
  completionSucceeds = true
  failedIndex = -1
  keyIndex = 0
  lookupStatus = 0
  timingCalls = 0
  lookupCalls = 0
  debugFlag = 0xFF
  logging = true
  hook = nil
  copyHook = nil
  readHook = nil
  rxVifEpochs = [1'u32, 2]
  rxKeyRevision = 1
  rxKeyLastChanged = default(typeof(rxKeyLastChanged))
  vifs = default(typeof(vifs))
  for vif in 0..1:
    vifs[vif].index = vif.uint8
    for slot in 0..3:
      vifs[vif].keys[slot] = KeySlot(installed: 1, cipherType: 2,
        keyIdx: (vif * 4 + slot).uint8, staIdx: slot.uint8)
    vifs[vif].defaultKeyPtr = vifKeySlotPtr(addr vifs[vif], (if vif == 0: 0'u else: 3'u))
proc expectData(bytes: openArray[uint8]; offset, size: int; index: uint8) =
  let expected = cast[ptr UncheckedArray[uint8]](addr bank[index].words[0])
  for i in 0 ..< bytes.len:
    doAssert bytes[i] == (if i >= offset and i < offset + size: expected[i - offset] else: 0xA5'u8),
      "read crossed output extent at " & $i
'''

CHECKS = r'''
for last in 0'u16 .. 255:
  for top in [0'u8, 14, 255]:
    for longKey in [false, true]:
      for incomingIrq in [false, true]:
        for index in [0'u8, last.uint8, 255'u8]:
          setup(last.uint8, top, longKey, incomingIrq)
          var output: array[48, uint8]
          for b in output.mitems: b = 0xA5
          var size = 0xA6'u8
          let status = mm_sec_machwkey_get(index, addr output[16], addr size)
          doAssert irq == incomingIrq
          if index <= last.uint8:
            let expectedSize = if longKey: 16 else: 8
            doAssert status == nil and size == expectedSize.uint8
            expectData(output, 16, expectedSize, index)
            doAssert commands == @[(index.uint32 shl 16) or 0x80000000'u32]
          else:
            doAssert status != nil and size == 0xA6 and commands.len == 0
            for b in output: doAssert b == 0xA5

for failure in 0 .. 1:
  setup()
  idleSucceeds = failure != 0
  completionSucceeds = failure != 1
  var output: array[16, uint8]
  for b in output.mitems: b = 0xA5
  var size = 0xA6'u8
  doAssert mm_sec_machwkey_get(0, addr output[0], addr size) != nil
  doAssert size == 0xA6 and irq
  for b in output: doAssert b == 0xA5
  doAssert commands.len == failure
  var unchanged = bank[9]
  doAssert not mmReadSecurityEntry(0, unchanged)
  doAssert unchanged == bank[9]

setup()
var output: array[16, uint8]
var size = 0xA6'u8
doAssert mm_sec_machwkey_get(0, nil, addr size) != nil
doAssert mm_sec_machwkey_get(0, addr output[0], nil) != nil
doAssert commands.len == 0 and size == 0xA6

setup()
copyHook = proc() =
  regs.keyMaterial = [9'u32, 8, 7, 6]
doAssert mm_sec_machwkey_get(0, addr output[0], addr size) == nil
let expected = cast[ptr UncheckedArray[uint8]](addr bank[0].words[0])
for i in 0 ..< 16: doAssert output[i] == expected[i]

for incomingIrq in [false, true]:
  for status in [0'u8, 1, 255]:
    setup(incomingIrq = incomingIrq)
    lookupStatus = status
    keyIndex = 7
    size = 0xA6
    let result = bl_wifi_get_sta_gtk(1, addr output[0], addr size)
    doAssert irq == incomingIrq and lookupCalls == 1
    doAssert (result == 0) == (status == 0)
    if status != 0: doAssert commands.len == 0 and size == 0xA6
  for failure in 0 .. 2:
    setup(incomingIrq = incomingIrq)
    if failure == 0: keyIndex = 15
    elif failure == 1: idleSucceeds = false
    else: completionSucceeds = false
    size = 0xA6
    doAssert bl_wifi_get_sta_gtk(0, addr output[0], addr size) == -1
    doAssert irq == incomingIrq and size == 0xA6
for invalid in 2'u16 .. 255:
  setup()
  doAssert bl_wifi_get_sta_gtk(invalid.uint8, addr output[0], addr size) == -1
  doAssert lookupCalls == 0 and commands.len == 0
setup()
doAssert bl_wifi_get_sta_gtk(0, nil, addr size) == -1
doAssert bl_wifi_get_sta_gtk(0, addr output[0], nil) == -1
doAssert lookupCalls == 0

proc expectDump(last: int) =
  var entry = 0
  for record in records:
    if record.line == 989:
      doAssert entry <= last and record.count == 7
      doAssert record.values[0] == entry.uint32
      for i in 0 ..< 4:
        doAssert record.values[i + 1] == ((bank[entry].macLow shr (8 * i)) and 0xFF)
      doAssert record.values[5] == (bank[entry].macHigh and 0xFF)
      doAssert record.values[6] == (bank[entry].macHigh shr 8)
    if record.line == 998: doAssert record.values[0] == (bank[entry].control and 1)
    if record.line == 999: doAssert record.values[0] == ((bank[entry].control shr 1) and 0x7FFF)
    if record.line == 1000: doAssert record.values[0] == (bank[entry].control shr 16)
    if record.line == 1007:
      doAssert entry <= last and record.count == 16
      let bytes = cast[ptr UncheckedArray[uint8]](addr bank[entry].words[0])
      for i in 0 ..< 16:
        doAssert record.values[i] == bytes[i].uint32,
          "entry " & $entry & " byte " & $i & ": got " & $record.values[i] & " expected " & $bytes[i]
      inc entry
  doAssert entry == last + 1
for last in [0'u8, 1, 14, 255]:
  setup(last, 255)
  mm_sec_keydump()
  doAssert commands.len == last.int + 1 and timingCalls == 1 and irq
  doAssert debugFlag == 0xFE
  expectDump(last.int)

setup(0, longKey = false)
mm_sec_keydump()
expectDump(0)

setup(0)
logging = false
mm_sec_keydump()
doAssert records.len == 0 and commands.len == 1 and timingCalls == 1

for point in [989'u32, 998, 999, 1000, 1007, 1014]:
  setup(4, 255)
  var reentered = false
  hook = proc(line: uint32) =
    if reentered or line != point: return
    reentered = true
    var nested: array[16, uint8]
    var nestedSize: uint8
    doAssert mm_sec_machwkey_get(3, addr nested[0], addr nestedSize) == nil
  mm_sec_keydump()
  doAssert reentered and commands.len == 6 and irq
  expectDump(4)
  for record in records:
    if record.line == 1000:
      doAssert record.values[0] <= 4
  doAssert commands[0] == 0x80000000'u32 and commands[1] == 0x80030000'u32

for failure in 0 .. 1:
  setup(4)
  if failure == 0: idleSucceeds = false
  else: failedIndex = 2
  mm_sec_keydump()
  doAssert irq and timingCalls == 1
  expectDump(if failure == 0: -1 else: 1)

setup(4, 255)
hook = proc(line: uint32) =
  if line == 989: regs.keyCount = regs.keyCount and not 0x0000FF00'u32
mm_sec_keydump()
doAssert commands.len == 1 and irq
expectDump(0)
'''


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("mutation", [None, "limit", "inclusive", "length", "idle", "done", "irq", "dump_limit", "dump_live", "gtk_status", "logger"])
def test_security_readback(tmp_path: Path, mode: str, mutation: str | None) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("Nim is required")
    source = (FW / "kernel_mac_channel.nim").read_text()
    typedef = re.search(r"(?ms)^type\n  MmSecurityReadback = object.*?(?=^proc mmReadSecurityEntry)", source).group(0)
    parts = {name: procedure(source, name) for name in
             ["mmReadSecurityEntry", "mm_sec_machwkey_get", "mm_sec_keydump"]}
    parts["gtk"] = procedure((FW / "platform_bl.nim").read_text(), "bl_wifi_get_sta_gtk")
    if mutation == "limit":
        parts["mmReadSecurityEntry"] = parts["mmReadSecurityEntry"].replace("((keyCount shr 8) and 0xFF).uint8", "(keyCount shr 24).uint8")
    elif mutation == "inclusive":
        parts["mmReadSecurityEntry"] = parts["mmReadSecurityEntry"].replace("if keyIdx > maxIdx:", "if keyIdx >= maxIdx:")
    elif mutation == "length":
        parts["mm_sec_machwkey_get"] = parts["mm_sec_machwkey_get"].replace("keySize.csize_t", "16.csize_t")
    elif mutation in ["idle", "done"]:
        mask = "0xE0000000" if mutation == "idle" else "0x80000000"
        parts["mmReadSecurityEntry"] = parts["mmReadSecurityEntry"].replace(f"if not waitMachwSecurityControlClear({mask}'u32):", "if false:")
    elif mutation == "irq":
        parts["mmReadSecurityEntry"] = parts["mmReadSecurityEntry"].replace("  let saved = irqSave()\n  defer: irqRestore(saved)\n", "")
    elif mutation == "dump_limit":
        parts["mm_sec_keydump"] = parts["mm_sec_keydump"].replace("((volatileLoad(addr regs.keyCount) shr 8) and 0xFF).int32", "3'i32")
    elif mutation == "dump_live":
        parts["mm_sec_keydump"] = parts["mm_sec_keydump"].replace("let kw0 = entry.words[0]", "let kw0 = volatileLoad(addr regs.keyMaterial[0])")
    elif mutation == "gtk_status":
        parts["gtk"] = parts["gtk"].replace("if not mmReadSecurityEntry(keyIdx, entry) or not current():", "if false:")
    elif mutation == "logger":
        parts["mm_sec_keydump"] = parts["mm_sec_keydump"].replace("getLogFunc(204)", "getLogFunc(76)")
    path = tmp_path / "readback.nim"
    path.write_text(typedef + PLATFORM + "\n".join(parts.values()) + CHECKS)
    flags = {"checked": [], "release": ["-d:release", "--assertions:on"],
             "asan": ["--cc:clang", "--passC:-fsanitize=address", "--passL:-fsanitize=address"]}
    result = subprocess.run([nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on", "--skipUserCfg:on",
        f"--nimcache:{tmp_path / 'cache'}", f"-o:{tmp_path / 'test'}", *flags[mode], str(path)],
        cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=120)
    if mutation is None:
        assert result.returncode == 0, result.stdout
    else:
        assert result.returncode != 0 and any(reason in result.stdout for reason in
            ["AssertionDefect", "IndexDefect", "AddressSanitizer", "SIGSEGV"]), result.stdout
