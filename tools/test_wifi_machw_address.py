"""Exercise the real MAC address writer across diagnostics and HW failures."""

from pathlib import Path
import shutil
import subprocess

import pytest

from test_wifi_disconnect_tx import procedure

ROOT = Path(__file__).resolve().parents[1]
FW = ROOT / "src/bl808/wifi/fw"

PLATFORM = r"""
const
  MAX_VIFS = 2
  STA_MGMT_FREE_STAS = 5
  STA_INFO_TAB_ENTRIES = 7
type
  Sta = object
    valid, instNbr: uint8
    macAddr: array[6, uint8]
  MacWords = tuple[lo, hi: uint32]
  Commit = tuple[mac: MacWords, control: uint32]
var
  stations: array[STA_INFO_TAB_ENTRIES, Sta]
  stationEpochs: array[STA_MGMT_FREE_STAS, uint32]
  rxVifEpochs: array[MAX_VIFS, uint32]
  registers: MacWords
  commits: seq[Commit]
  events: seq[string]
  addresses, clears: int
  irq, idleSucceeds, completionSucceeds: bool
  hook: proc(stage: string)
proc fire(stage: string) =
  doAssert not irq, "interrupts enabled inside an address operation"
  events.add(stage)
  if hook != nil: hook(stage)
proc irqSave(): uint32 =
  result = if irq: 8'u32 else: 0'u32
  irq = false
proc irqRestore(saved: uint32) = irq = (saved and 8) != 0
proc staInfoForIdx(index: uint8): ptr Sta =
  doAssert index < STA_INFO_TAB_ENTRIES
  addr stations[index]
proc staDeleteEpoch(index: uint8): uint32 =
  if index < STA_MGMT_FREE_STAS: stationEpochs[index] else: 0
proc staMacWords(sta: ptr Sta): MacWords =
  for i in 0 ..< 4: result.lo = result.lo or (sta.macAddr[i].uint32 shl (i * 8))
  for i in 0 ..< 2: result.hi = result.hi or (sta.macAddr[i + 4].uint32 shl (i * 8))
proc nimFwConnectTrace2U32(label: cstring; a, b: uint32) =
  fire(if $label == "[WIFI-CT] machwaddr ": "trace1" else: "trace2")
proc machwSecurityWriteAddress(lo, hi: uint32) =
  doAssert not irq
  inc addresses
  registers = (lo, hi)
  events.add("address")
proc machwSecurityClearKeyMaterial() =
  doAssert not irq
  inc clears
  events.add("clear")
proc machwSecurityWriteControl(value: uint32) =
  doAssert not irq
  commits.add((registers, value))
  events.add("control")
proc waitMachwSecurityControlClear(mask: uint32): bool =
  if mask == 0xE0000000'u32:
    fire("idle")
    idleSucceeds
  else:
    doAssert mask == 0x40000000'u32
    fire("done")
    completionSucceeds
proc setup(incomingIrq = true) =
  stations = default(typeof(stations))
  for i in 0 ..< STA_INFO_TAB_ENTRIES:
    stations[i].instNbr = if i < 5: (i and 1).uint8 else: (i - 5).uint8
    stations[i].valid = (i < 5).uint8
    stations[i].macAddr = [i.uint8, 0x12, 0x34, 0x56, 0x78, 0x9A]
  stationEpochs = [1'u32, 2, 3, 4, 5]
  rxVifEpochs = [11'u32, 12]
  registers = (0xCAFECAFE'u32, 0xBABE'u32)
  commits.setLen(0)
  events.setLen(0)
  addresses = 0
  clears = 0
  irq = incomingIrq
  idleSucceeds = true
  completionSucceeds = true
  hook = nil
"""

CHECKS = r"""
proc invoke(index: uint8 = 0; slot: uint = 0): uint8 =
  mm_sec_machwaddr_wr(index, cast[pointer](slot), 99)

for index in 0'u8 .. 6:
  for vif in 0'u8 .. 1:
    if index >= 5 and index != 5 + vif: continue
    for slot in 0'u .. 15:
      for incomingIrq in [false, true]:
        setup(incomingIrq)
        stations[index].instNbr = vif
        let before = stations
        let mac = staMacWords(addr stations[index])
        doAssert invoke(index, slot) == index + 8
        doAssert irq == incomingIrq and stations == before
        doAssert addresses == 1 and clears == 1 and commits.len == 1
        doAssert commits[0] == (mac, 0x40000002'u32 or ((index.uint32 + 8) shl 16) or (slot.uint32 shl 4))
        doAssert events == @["trace1", "trace2", "idle", "address", "clear", "control", "done"]

for invalid in 7'u16 .. 255:
  setup()
  doAssert invoke(invalid.uint8) == 0xFF and events.len == 0 and irq
for invalid in 2'u16 .. 255:
  setup()
  stations[0].instNbr = invalid.uint8
  doAssert invoke() == 0xFF and events.len == 0 and irq
for invalid in 16'u .. 255:
  setup()
  doAssert invoke(0, invalid) == 0xFF and events.len == 0 and irq
when sizeof(uint) > 4:
  setup()
  doAssert invoke(0, 0x100000000'u) == 0xFF and events.len == 0
for index in 0'u8 .. 4:
  setup()
  stations[index].valid = 0
  doAssert invoke(index) == 0xFF and events.len == 0
for index in 5'u8 .. 6:
  setup()
  stations[index].instNbr = stations[index].instNbr xor 1
  doAssert invoke(index) == 0xFF and events.len == 0

for stage in ["trace1", "trace2", "idle", "done"]:
  for action in 0 .. 4:
    for incomingIrq in [false, true]:
      setup(incomingIrq)
      var fired = false
      hook = proc(point: string) =
        if fired or point != stage: return
        fired = true
        case action
        of 0: inc rxVifEpochs[0]
        of 1: inc stationEpochs[0]
        of 2: stations[0].instNbr = 1
        of 3: stations[0].valid = 0
        else: stations[0].macAddr[0] = 0xE7
      doAssert invoke() == 0xFF and fired and irq == incomingIrq
      doAssert commits.len == (stage == "done").int
      doAssert addresses == (stage == "done").int

for incomingIrq in [false, true]:
  setup(incomingIrq)
  idleSucceeds = false
  doAssert invoke() == 0xFF and irq == incomingIrq
  doAssert addresses == 0 and clears == 0 and commits.len == 0
  setup(incomingIrq)
  completionSucceeds = false
  doAssert invoke() == 0xFF and irq == incomingIrq
  doAssert addresses == 1 and clears == 1 and commits.len == 1

# A nested operation must not substitute its address into the outer command.
for stage in ["trace1", "trace2"]:
  setup()
  let outerMac = staMacWords(addr stations[0])
  let innerMac = staMacWords(addr stations[1])
  var entered = false
  hook = proc(point: string) =
    if entered or point != stage: return
    entered = true
    doAssert invoke(1, 1) == 9
  doAssert invoke() == 8 and entered and commits.len == 2
  doAssert commits[0] == (innerMac, 0x40090012'u32)
  doAssert commits[1] == (outerMac, 0x40080002'u32)
  doAssert irq

# A nested command left busy must prevent the outer register writes entirely.
setup()
var enteredBusy = false
hook = proc(point: string) =
  if enteredBusy or point != "trace1": return
  enteredBusy = true
  completionSucceeds = false
  doAssert invoke(1, 1) == 0xFF
  idleSucceeds = false
doAssert invoke() == 0xFF and commits.len == 1 and addresses == 1 and irq
"""


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("mutation", [None, "irq", "station", "selector", "epoch", "mac", "idle", "done", "trace"])
def test_machw_address(tmp_path: Path, mode: str, mutation: str | None) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("Nim is required")
    body = procedure((FW / "kernel_mac_channel.nim").read_text(), "mm_sec_machwaddr_wr")
    if mutation == "irq":
        body = body.replace("  let saved = irqSave()\n  defer: irqRestore(saved)\n", "")
    elif mutation == "station":
        body = body.replace("staIdx >= STA_INFO_TAB_ENTRIES.uint8", "false")
    elif mutation == "selector":
        body = body.replace("cast[uint](keySlotRaw) > 15", "false")
    elif mutation == "epoch":
        body = body.replace("rxVifEpochs[vifIdx] == vifEpoch", "true")
    elif mutation == "mac":
        body = body.replace("staMacWords(sta) == mac", "true")
    elif mutation == "idle":
        body = body.replace("not waitMachwSecurityControlClear(0xE0000000'u32)", "false")
    elif mutation == "done":
        body = body.replace("not waitMachwSecurityControlClear(0x40000000'u32)", "false")
    elif mutation == "trace":
        writes = "  machwSecurityWriteAddress(mac.lo, mac.hi)\n  machwSecurityClearKeyMaterial()\n"
        body = body.replace(writes, "")
        start = body.index("  nimFwConnectTrace2U32(")
        body = body[:start] + writes + body[start:]
    path = tmp_path / "address.nim"
    path.write_text(PLATFORM + body + CHECKS)
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
