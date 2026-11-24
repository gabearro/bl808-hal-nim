"""Keep modem/RC interrupt effects separate from channel programming."""

import json
from pathlib import Path
import re
import shutil
import subprocess

import pytest

from test_wifi_disconnect_tx import FW, ROOT, procedure
from test_wifi_message_allocation import run_program
from test_wifi_sta_tx_channel import object_type


def source() -> str:
    rf = (FW / "global_state/rf_bl808_core.nim").read_text()
    code = object_type(rf, "WifiModemBlock") + r'''
var
  modem: WifiModemBlock
  reads: seq[int]
  writes: seq[tuple[offset: int, value: uint32]]
  mappings, notifications, irqAssertions, status1Reads: int
  slot: uint32
  platformStatus0, platformStatus1: uint32
  intc_handler_tab: array[64, pointer]
proc wifiModemRegs(): ptr WifiModemBlock =
  inc mappings
  addr modem
proc offset(p: pointer): int = cast[int](p) - cast[int](addr modem)
proc volatileLoad(p: ptr uint32): uint32 =
  reads.add(offset(p))
  p[]
proc volatileStore(p: ptr uint32; value: uint32) =
  writes.add((offset(p), value))
  p[] = value
proc setup(status: uint32) =
  let bytes = cast[ptr UncheckedArray[uint8]](addr modem)
  for i in 0..<sizeof(modem): bytes[i] = (i and 255).uint8
  modem.intStatusB41c = status
  modem.intAckB420 = 0x12345678
  modem.phyChannelPulse888 = 0x87654321'u32
  mappings = 0
  notifications = 0
  irqAssertions = 0
  status1Reads = 0
  platformStatus0 = 1
  platformStatus1 = 0
  reads.setLen(0)
  writes.setLen(0)
static:
  doAssert offsetof(WifiModemBlock, intStatusB41c) == 0xB41C
  doAssert offsetof(WifiModemBlock, intAckB420) == 0xB420
  doAssert offsetof(WifiModemBlock, phyChannelPulse888) == 0x888
'''
    for name in ["phy_mdm_isr", "phy_rc_isr"]:
        code += procedure(rf, name)
    code += r'''
proc rxl_timer_int_handler() {.cdecl.} = discard
proc txl_transmit_trigger() {.cdecl.} = discard
proc hal_machw_gen_handler() {.cdecl.} = discard
proc intc_spurious() {.cdecl.} = discard
proc ipc_emb_msg_irq() {.cdecl.} = discard
proc ipc_emb_cfmback_irq() {.cdecl.} = discard
proc ipc_emb_tx_irq() {.cdecl.} = discard
const
  MAC_PL_IRQ_STATUS0 = 0x24910000'u
  MAC_PL_IRQ_STATUS1 = 0x24910004'u
  MAC_PL_IRQ_HANDLER = 0x24910040'u
  MACHW_INTC_STATUS_RAW = 0x24B0806C'u
  MACHW_INTC_GEN_RAW = 0x24B08084'u
  MACHW_RX_CNTRL_REG = 0x24B00060'u
proc regRead(address: uint): uint32 =
  case address
  of MAC_PL_IRQ_STATUS0: platformStatus0
  of MAC_PL_IRQ_STATUS1:
    inc status1Reads
    platformStatus1
  of MAC_PL_IRQ_HANDLER: slot
  of MACHW_INTC_STATUS_RAW,
      MACHW_INTC_GEN_RAW, MACHW_RX_CNTRL_REG: 0'u32
  else: raise newException(ValueError, "unexpected MAC read")
proc machwRxHdSubmittedHead(): uint32 = 0
proc machwRxPdSubmittedHead(): uint32 = 0
proc assert_err(condition, file: cstring; line: cint) =
  doAssert $condition == "intc.c" and $file == "intc.c" and line == 154
  inc irqAssertions
proc ipc_emb_notify(status: uint32) =
  doAssert status == 0
  inc notifications
template nimFwTrace2U32(args: varargs[untyped]) = discard
'''
    code += procedure((FW / "coex_intc_sysctrl.nim").read_text(), "intc_handlers_init")
    dispatch = procedure((FW / "mac_config_debug.nim").read_text(), "mac_irq")
    names = sorted(set(re.findall(r"\bnimFwDbg\w+", dispatch)))
    code += "var\n" + "".join(f"  {name}: uint32\n" for name in names)
    return code + dispatch


CASES = {
    "modem_has_no_register_side_effects": r'''
for status in [0'u32, 1, 0x100, 0x101, 0x80000100'u32, 0xFFFFFFFF'u32]:
  setup(status)
  let before = modem
  phy_mdm_isr()
  doAssert mappings == 0 and reads.len == 0 and writes.len == 0,
    "modem IRQ accessed RC/channel registers"
  doAssert modem == before
''',
    "rc_only_acknowledges_its_status": r'''
for status in [0'u32, 1, 0x100, 0x101, 0x80000100'u32, 0xFFFFFFFF'u32]:
  setup(status)
  var expected = modem
  expected.intAckB420 = status
  phy_rc_isr()
  doAssert mappings == 1 and reads == @[0xB41C]
  doAssert writes == @[(0xB420, status)]
  doAssert modem == expected
''',
    "registered_modem_then_rc": r'''
intc_handlers_init()
for status in [0'u32, 0x100, 0xFFFFFFFF'u32]:
  setup(status)
  let before = modem
  slot = 10
  mac_irq()
  doAssert notifications == 1
  doAssert modem == before and reads.len == 0 and writes.len == 0,
    "registered modem IRQ consumed the RC completion"
  slot = 11
  mac_irq()
  var expected = before
  expected.intAckB420 = status
  doAssert notifications == 2 and modem == expected
  doAssert reads == @[0xB41C] and writes == @[(0xB420, status)]
''',
    "invalid_handler_index_does_not_alias": r'''
intc_handlers_init()
setup(0x100)
let before = modem
slot = 74 # Previously wrapped to modem ISR slot 10.
mac_irq()
doAssert irqAssertions == 1 and notifications == 0
doAssert mappings == 0 and reads.len == 0 and writes.len == 0
doAssert modem == before
slot = 12 # In range, but no handler is registered.
mac_irq()
doAssert irqAssertions == 2 and notifications == 0
doAssert mappings == 0 and modem == before
slot = 10
mac_irq()
doAssert irqAssertions == 2 and notifications == 1
doAssert mappings == 0 and modem == before
''',
    "mac_irq_reads_platform_status_once": r'''
intc_handlers_init()
for firstStatus in [0'u32, 1'u32]:
  setup(0)
  platformStatus0 = firstStatus
  platformStatus1 = 2
  slot = 10
  mac_irq()
  doAssert status1Reads == (if firstStatus == 0: 1 else: 0)
  doAssert notifications == 1
  doAssert (nimFwDbgMacIrqLast shr 16) ==
    (if firstStatus == 0: 2'u32 else: 0'u32)
setup(0)
platformStatus0 = 0
slot = 10
mac_irq()
doAssert status1Reads == 1 and notifications == 0
''',
}


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("case", CASES)
def test_phy_irq(tmp_path: Path, mode: str, case: str) -> None:
    run_program(tmp_path, mode, source() + CASES[case])


def test_irq_dispatch_table_matches_vendor_relocations(tmp_path: Path) -> None:
    r2 = shutil.which("r2")
    ar = shutil.which("llvm-ar") or shutil.which("riscv64-unknown-elf-ar")
    if not r2 or not ar:
        pytest.skip("radare2 and a RISC-V archive tool are required")

    archive = ROOT / "tools/ref/libwifi_bl808.a"
    member = subprocess.run([ar, "p", str(archive), "intc.o"], capture_output=True)
    assert member.returncode == 0, member.stderr.decode()
    obj = tmp_path / "intc.o"
    obj.write_bytes(member.stdout)
    result = subprocess.run(
        [r2, "-q", "-c", "iSj;irj;q", str(obj)],
        text=True, capture_output=True,
    )
    assert result.returncode == 0, result.stderr
    sections, relocations = [json.loads(line) for line in result.stdout.splitlines()]
    section = next(entry for entry in sections
                   if entry["name"] == ".rodata.intc_irq_handlers")
    assert section["size"] == 64 * 4
    start = section["paddr"]
    assert not any(member.stdout[start:start + section["size"]])

    vendor = {}
    for relocation in relocations:
        offset = relocation["paddr"] - start
        if 0 <= offset < section["size"]:
            assert offset % 4 == 0
            index = offset // 4
            assert index not in vendor
            vendor[index] = relocation["name"].removeprefix("imp.")
    assert len(vendor) == 28

    entries = [f"cast[pointer]({vendor[index]})" if index in vendor else "nil"
               for index in range(64)]
    expected = ",\n  ".join(entries)
    run_program(tmp_path, "checked", source() + f"""
let expected: array[64, pointer] = [
  {expected}]
intc_handlers_init()
for index in 0 ..< expected.len:
  doAssert intc_handler_tab[index] == expected[index], "IRQ slot " & $index
""")
