"""BL808 demo rf_pri.o: gain table data and rf_pri_gain_table_WR2REG."""

from pathlib import Path

import pytest

from test_wifi_message_allocation import run_program
from test_wifi_rf_power_replay import RF, object_type


GAIN = RF.with_name("rf_bl808_tx_gain.nim")

# Little-endian ELF section contents, including the unselected rows.
ROW_BYTES = (
    "00" * 56
    + "0000010007001a000000f8ffc800"
    "00000100070016000000f8ffbe00"
    "00000100070011000000fcffb400"
    "00000100070011000000f8ffaa00"
    "0000010007000c000000feffa000"
    "0000010007000c000000faff9600"
    "00000100070009000000feff8c00"
    "00000100070009000000faff8200"
    "00000100070007000000feff7800"
    "00000100070007000000faff6e00"
    "00000100060007000000faff6400"
    + "00" * 28
)
INDEX_BYTES = "0400050006000700080009000a000e00"


def harness() -> str:
    return object_type(RF.read_text(), "RfTxPowerCompTableBlock") + r'''
import std/strutils
var rf: RfTxPowerCompTableBlock
var trace: seq[tuple[store: bool, offset: int, value: uint32]]
proc rfTxPowerCompTableRegs(): ptr RfTxPowerCompTableBlock = addr rf
proc offset(p: ptr uint32): int = int(cast[uint](p) - cast[uint](addr rf))
proc volatileLoad(p: ptr uint32): uint32 =
  trace.add((false, offset(p), p[]))
  p[]
proc volatileStore(p: ptr uint32; value: uint32) =
  trace.add((true, offset(p), value))
  p[] = value
''' + f'include "{GAIN}"\n' + r'''
# Header stores +0x120/+0x18e; A stores +0x1de..+0x47a, slot 7 first.
const offsets = [0x704, 0x700, 0x740, 0x738, 0x730,
                 0x728, 0x720, 0x718, 0x710, 0x708]
proc checkPublisher(gainBits: array[10, uint32]) =
  for seed in [0'u32, 0xFFFFFFFF'u32, 0xA5A55A5A'u32]:
    for i in 0 ..< rf.txPowerCompWords700.len:
      rf.txPowerCompWords700[i] = seed xor (i.uint32 * 0x01010101'u32)
    var expectedWords = rf.txPowerCompWords700
    var expectedTrace: typeof(trace)
    for i, off in offsets:
      let index = (off - 0x700) div 4
      let live = expectedWords[index]
      let keep = if i < 2: 0xFF000000'u32 else: 0xC00007FF'u32
      let value = (live and keep) or gainBits[i]
      expectedTrace.add((false, off, live))
      expectedTrace.add((true, off, value))
      expectedWords[index] = value
    trace.setLen(0)
    programBl808TxGainTable()
    doAssert trace == expectedTrace, $trace
    doAssert rf.txPowerCompWords700 == expectedWords
'''


@pytest.mark.parametrize("mode", ["checked", "firmware"])
def test_demo_gain_defaults(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, harness() + r'''
proc wireHalf(x: int16): string =
  let u = cast[uint16](x)
  toHex(u and 255, 2) & toHex(u shr 8, 2)
var rows, indices: string
for row in bl808TxGainRows:
  for field in row: rows.add(wireHalf(field))
for slot, index in bl808TxGainIndices:
  indices.add(wireHalf(index))
  let row: Bl808TxGainRow = bl808TxGainRow(slot.int)
  doAssert row == bl808TxGainRows[index.int]
''' + f'doAssert rows == "{ROW_BYTES.upper()}"\n'
        + f'doAssert indices == "{INDEX_BYTES.upper()}"\n' + r'''
checkPublisher([0x0028E3D0'u32, 0x004524D4, 0xD0FBD000'u32, 0xD13FF000'u32,
  0xD19FD000'u32, 0xD19FF000'u32, 0xD23FC000'u32, 0xD23FE000'u32,
  0xD2DFC000'u32, 0xD35FC000'u32])
''')


def test_demo_gain_rows_available_before_nim_main(tmp_path: Path) -> None:
    run_program(tmp_path, "firmware", harness() + r'''
var gainRowsAtBoot {.exportc: "test_gain_rows_at_boot".}: cint

proc sampleGainRowsAtBoot(): cint {.exportc: "test_sample_gain_rows_at_boot", cdecl.} =
  const tones = [26'i16, 22, 17, 17, 12, 12, 9, 7]
  const powers = [20'i32, 19, 18, 17, 16, 15, 14, 10]
  for slot in 0 ..< tones.len:
    if bl808TxGainRow(slot)[3] != tones[slot] or bl808TxGainDb(slot) != powers[slot]:
      return 0
  1

{.emit: """
extern int test_gain_rows_at_boot;
extern int test_sample_gain_rows_at_boot(void);
static void __attribute__((constructor)) capture_gain_rows_at_boot(void) {
  test_gain_rows_at_boot = test_sample_gain_rows_at_boot();
}
""".}

doAssert gainRowsAtBoot == 1, "TX calibration would read empty gain rows before NimMain"
''')


@pytest.mark.parametrize("mode", ["checked", "firmware"])
def test_current_rows_signed_fields(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, harness() + r'''
# Exercise signed LH, DIV toward zero, and unmasked shifts. Each of the
# five A columns gets a negative value in isolation. Column 4 is ignored.
const inputs: array[8, Bl808TxGainRow] = [
  [0'i16,0,0,0,0,-1,19], [0'i16,0,0,-1,0,0,-29],
  [0'i16,0,-2,0,0,0,125], [0'i16,-2,0,0,0,0,89],
  [-3'i16,0,0,0,0,0,650], [0'i16,0,0,0,-32768,0,0],
  [16'i16,0,0,64,123,128,-9], [1'i16,2,3,4,5,6,37]]
for slot, row in inputs:
  bl808TxGainIndices[slot] = int16(16 - slot)
  bl808TxGainRows[16 - slot] = row
for slot, row in inputs:
  doAssert bl808TxGainRow(slot.int) == row
checkPublisher([0x000C0041'u32, 0xFFFFFF81'u32, 0x248C3000, 0x40000000,
  0, 0xF4000000'u32, 0xE0000000'u32, 0xC3F80000'u32, 0xC3E00000'u32,
  0xC003F800'u32])
''')
