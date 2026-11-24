"""Check the MAC timing diagnostic against the pinned hal_machw.o fields."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


def source() -> str:
    timing_dump = procedure((FW / "kernel_mac_channel.nim").read_text(),
                            "hal_machw_timing_info")
    return r'''
import std/[tables, sequtils]
const MACHW_BASE = 0x24B00000'u
var
  registers = initTable[uint, uint32]()
  reads: seq[uint]
  slots: seq[int]
  headers: seq[string]
  fields: seq[tuple[format: string, hexValue, decValue: uint32]]
  printers: seq[char]
  useSecondPrinter = false
  switchAfter = high(int)

proc regRead(address: uint): uint32 =
  reads.add(address)
  registers[address]

proc headerPrinter(line: cstring) {.cdecl.} = headers.add($line)
proc fieldPrinterA(format: cstring; a, b: uint32) {.cdecl.} =
  fields.add(($format, a, b))
  printers.add('A')
  if fields.len == switchAfter: useSecondPrinter = true
proc fieldPrinterB(format: cstring; a, b: uint32) {.cdecl.} =
  fields.add(($format, a, b))
  printers.add('B')
proc blOpsFunc(slot: int): pointer =
  slots.add(slot)
  if slot == 8: return cast[pointer](headerPrinter)
  if slot == 4:
    return if useSecondPrinter: cast[pointer](fieldPrinterB)
      else: cast[pointer](fieldPrinterA)
  nil
''' + timing_dump + r'''
registers[MACHW_BASE + 0xE4] = (0x155'u32 shl 18) or (0x2AA'u32 shl 8) or 0x5C
registers[MACHW_BASE + 0xE8] = (0xA55A'u32 shl 8) or 0x7D
registers[MACHW_BASE + 0xEC] = (0x155'u32 shl 20) or (0x2AA'u32 shl 10) or 0x3C
registers[MACHW_BASE + 0xF0] = (0x2A5'u32 shl 22) or (0x155'u32 shl 12) or 3
registers[MACHW_BASE + 0xF4] = (0xA55A'u32 shl 8) or 0x55
registers[MACHW_BASE + 0xF8] = (0x5AA5'u32 shl 8) or 0xAA
registers[MACHW_BASE + 0xFC] = (0xB'u32 shl 8) or 0xC3
registers[MACHW_BASE + 0x100] = 0x12345678'u32
registers[MACHW_BASE + 0x104] = (0x123'u32 shl 20) or (0x2AB'u32 shl 10) or 0x3CC

let expected = @[
  ("[Timing1]     txchaindelayinmacclk     0x%04X          %u\r\n", 0x155'u32),
  ("              txrfdelayinmacclk        0x%04X          %u\r\n", 0x2AA'u32),
  ("              maccoreclkfreq           0x%04X          %u\r\n", 0x5C'u32),
  ("[Timing2]     slotTimeInMACClk         0x%04X          %u\r\n", 0xA55A'u32),
  ("              slottime                 0x%04X          %u\r\n", 0x7D'u32),
  ("[Timing3]     rxrfdelayinmacclk        0x%04X          %u\r\n", 0x155'u32),
  ("              txdelayrfoninmacclk      0x%04X          %u\r\n", 0x2AA'u32),
  ("              macprocdelayinmacclk     0x%04X          %u\r\n", 0x3C'u32),
  ("[Timing4]     radiowakeuptime          0x%04X          %u\r\n", 0x2A5'u32),
  ("              radiochirptime           0x%04X          %u\r\n", 0x155'u32),
  ("              wt2cryptclkratio         0x%04X          %u\r\n", 3'u32),
  ("[Timing5]     sifsbinmacclk            0x%04X          %u\r\n", 0xA55A'u32),
  ("              sifsb                    0x%04X          %u\r\n", 0x55'u32),
  ("[Timing6]     sifsainmacclk            0x%04X          %u\r\n", 0x5AA5'u32),
  ("              sifsa                    0x%04X          %u\r\n", 0xAA'u32),
  ("[Timing7]     rxccadelay               0x%04X          %u\r\n", 0xB'u32),
  ("              rifs                     0x%04X          %u\r\n", 0xC3'u32),
  ("[Timing8]     rxstartdelaymimo         0x%04X          %u\r\n", 0x12'u32),
  ("              rxstartdelayshort        0x%04X          %u\r\n", 0x34'u32),
  ("              rxstartdelaylong         0x%04X          %u\r\n", 0x56'u32),
  ("              rxstartdelayofdm         0x%04X          %u\r\n", 0x78'u32),
  ("[Timing9]     rifstoinmacclk           0x%04X          %u\r\n", 0x123'u32),
  ("              rifsinmacclk             0x%04X          %u\r\n", 0x2AB'u32),
  ("              txdmaprocdlyinmacclk     0x%04X          %u\r\n", 0x3CC'u32),
]

hal_machw_timing_info()
doAssert headers == @[
  "==========================  Timing Dump =========================\r\n",
  "[Register]    [ValueName]            [Value(HEX]    [Value(DEC)]\r\n"]
doAssert reads == @[0x24B000E4'u, 0x24B000E8'u, 0x24B000EC'u,
  0x24B000F0'u, 0x24B000F4'u, 0x24B000F8'u, 0x24B000FC'u,
  0x24B00100'u, 0x24B00104'u]
doAssert slots == @[8, 8] & newSeqWith(expected.len, 4)
doAssert fields.len == expected.len
for i, entry in expected:
  doAssert fields[i] == (entry[0], entry[1], entry[1]), $i
doAssert printers == newSeqWith(expected.len, 'A')

headers.setLen(0)
fields.setLen(0)
printers.setLen(0)
reads.setLen(0)
slots.setLen(0)
switchAfter = 1
hal_machw_timing_info()
doAssert fields.len == expected.len
doAssert printers[0] == 'A'
for i in 1 ..< expected.len: doAssert printers[i] == 'B'
doAssert slots == @[8, 8] & newSeqWith(expected.len, 4)
'''


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_mac_timing_dump(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source())
