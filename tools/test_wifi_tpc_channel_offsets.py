"""TPC offset forwarding and C-varargs behavior from the pinned WiFi object."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program
from test_wifi_rf_channel_entry import rf_procedure


PLATFORM = r'''
type Record = tuple[printer: int, message: string, cached: array[14, int8],
                    shadow: array[38, int8]]
var
  input: array[38, int8]
  tpcChannelOffsetTable: array[14, int8]
  tpcPowerTable: array[38, int8]
  trpcTxpwrVsRateTable: array[50, uint8]
  records: seq[Record]
  operations: seq[string]
  currentPrinter: pointer
  afterPrint: proc(printer: int)
  phyOffsets: array[14, int8]
  phyCalls, lookupCount: int
proc printerA(format: cstring) {.cdecl, varargs.}
proc printerB(format: cstring) {.cdecl, varargs.}
proc observe(printer: int; message: string) =
  records.add((printer, message, tpcChannelOffsetTable, tpcPowerTable))
  operations.add("print")
  if afterPrint != nil: afterPrint(printer)
{.emit: "#include <stdarg.h>\n#include <stdio.h>".}
template capturePrint(printer: static[int]; format: cstring) =
  var output: array[128, char]
  var length: cint
  {.emit: ["va_list args; va_start(args, ", format, "); ", length,
    " = vsnprintf((char*)", output, ", sizeof(", output, "), ",
    format, ", args); va_end(args);"].}
  doAssert length >= 0 and length < output.len.cint
  observe(printer, $cast[cstring](addr output[0]))
proc printerA(format: cstring) {.cdecl, varargs.} = capturePrint(1, format)
proc printerB(format: cstring) {.cdecl, varargs.} = capturePrint(2, format)
proc blOpsFunc(offset: int): pointer =
  doAssert offset == 4
  inc lookupCount
  operations.add("lookup")
  currentPrinter
proc phy_powroffset_set(p: ptr int8) {.exportc, cdecl.} =
  copyMem(addr phyOffsets[0], p, 14)
  inc phyCalls
  operations.add("phy")
proc setup(seed: int) =
  for i in 0 ..< input.len: input[i] = cast[int8](((seed + i * 13) and 255).uint8)
  for i in 0 ..< tpcPowerTable.len: tpcPowerTable[i] = cast[int8]((i + 0xA0).uint8)
  for i in 0 ..< 14: tpcChannelOffsetTable[i] = (50 + i).int8
  records.setLen(0)
  operations.setLen(0)
  currentPrinter = cast[pointer](printerA)
  afterPrint = nil
  phyCalls = 0
  lookupCount = 0
proc scaled(value: int8): int8 = cast[int8]((cast[uint8](value).uint32 * 4) and 255)
proc line(index: int; value: int8): string =
  "pwr chan[" & $index & "] offset:" & $scaled(value) & "\r\n"
'''


def source() -> str:
    tpc = (FW / "tx_power_control.nim").read_text()
    rf = (FW / "global_state/rf_bl808_core.nim").read_text()
    return (PLATFORM + procedure(tpc, "bl_tpc_update_power_table_channel_offset")
            + rf_procedure(rf, "trpc_get_power_idx")
            + rf_procedure(rf, "trpc_get_default_power_idx"))


CASES = {
    "signed_values_without_publication": r'''
for seed in 0 .. 255:
  setup(seed)
  let original = input
  let cached = tpcChannelOffsetTable
  let shadow = tpcPowerTable
  bl_tpc_update_power_table_channel_offset(addr input)
  doAssert records.len == 15 and phyCalls == 1 and input == original
  for i in 0 ..< 14:
    doAssert records[i].message == line(i, original[24 + i]),
      "logged PHY offset must be the signed low byte with CRLF: " & repr(records[i].message)
    doAssert records[i].printer == 1
    for j in 0 ..< 14:
      doAssert records[i].cached[j] == cached[j]
      doAssert records[i].shadow[24 + j] == shadow[24 + j]
    doAssert phyOffsets[i] == scaled(original[24 + i])
  doAssert tpcChannelOffsetTable == cached and tpcPowerTable == shadow
  for i in 0 ..< 24: doAssert tpcPowerTable[i] == shadow[i]
  doAssert records[^1].message == "dynamic update channel offset\r\n"
  doAssert operations[^2] == "print" and operations[^1] == "phy"
''',
    "callback_replacement": r'''
proc alternate(printer: int) =
  currentPrinter = if printer == 1: cast[pointer](printerB) else: cast[pointer](printerA)
setup(0)
for i in 0 ..< 14: input[24 + i] = (i - 7).int8
let original = input
afterPrint = alternate
bl_tpc_update_power_table_channel_offset(addr input)
doAssert lookupCount == 15, "reload the printer before every line and the completion message"
doAssert records.len == 15
for i in 0 ..< records.len:
  doAssert records[i].printer == 1 + i mod 2
  doAssert operations[i * 2] == "lookup" and operations[i * 2 + 1] == "print"
doAssert phyCalls == 1 and input == original and operations[^1] == "phy"
''',
    "callback_changes_later_input": r'''
proc changeInput(printer: int) =
  if records.len <= 14:
    let current = records.len - 1
    input[24 + current] = -27
    if current + 1 < 14: input[24 + current + 1] = (current - 10).int8
setup(0)
for i in 0 ..< 14: input[24 + i] = 3
let header = input
let cached = tpcChannelOffsetTable
let shadow = tpcPowerTable
afterPrint = changeInput
bl_tpc_update_power_table_channel_offset(addr input)
for i in 0 ..< 14:
  let sampled = (if i == 0: 3 else: i - 11).int8
  doAssert records[i].message == line(i, sampled), repr(records[i].message)
  doAssert tpcChannelOffsetTable[i] == cached[i]
  doAssert tpcPowerTable[24 + i] == shadow[24 + i]
  doAssert phyOffsets[i] == scaled(sampled)
  doAssert input[24 + i] == -27
for i in 0 ..< 24: doAssert input[i] == header[i]
doAssert phyCalls == 1 and records.len == 15
''',
    "missing_or_removed_logger": r'''
proc removeLogger(printer: int) = currentPrinter = nil
for initiallyMissing in [false, true]:
  setup(255)
  let original = input
  let cached = tpcChannelOffsetTable
  let shadow = tpcPowerTable
  if initiallyMissing: currentPrinter = nil
  afterPrint = removeLogger
  bl_tpc_update_power_table_channel_offset(addr input)
  doAssert records.len == (if initiallyMissing: 0 else: 1)
  doAssert lookupCount == 15 and phyCalls == 1 and operations[^1] == "phy"
  for i in 0 ..< 14:
    doAssert phyOffsets[i] == scaled(original[24 + i])
    doAssert tpcChannelOffsetTable[i] == cached[i]
    doAssert tpcPowerTable[24 + i] == shadow[24 + i]
  doAssert input == original
''',
    "nil_input": r'''
setup(17)
let cached = tpcChannelOffsetTable
let shadow = tpcPowerTable
bl_tpc_update_power_table_channel_offset(nil)
doAssert lookupCount == 0 and phyCalls == 0
doAssert records.len == 0 and operations.len == 0
doAssert tpcChannelOffsetTable == cached and tpcPowerTable == shadow
''',
    "rf_index_arithmetic": r'''
for raw in 0 .. 255:
  let expected = ((raw * 4) and 252).uint8
  for ignored in [0'u8, 1, 255]:
    let power = cast[int8](raw.uint8)
    doAssert trpc_get_power_idx(0, ignored, power) == expected
    doAssert trpc_get_power_idx(1, ignored, power) == expected
  for i in 0 ..< 50: trpcTxpwrVsRateTable[i] = ((raw + i * 7) and 255).uint8
  for group in 0'u32 .. 4:
    for index in 0'u8 .. 9:
      let expected = (trpcTxpwrVsRateTable[group.int * 10 + index.int].uint32 * 4) and 252
      doAssert cast[uint8](trpc_get_default_power_idx(group, index)).uint32 == expected
''',
}


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
@pytest.mark.parametrize("case", CASES)
def test_tpc_channel_offsets(tmp_path: Path, mode: str, case: str) -> None:
    run_program(tmp_path, mode, source() + CASES[case])
