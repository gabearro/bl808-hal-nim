"""Ordered register and cached RX gain transactions from pinned BL808 phy.o."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import procedure
from test_wifi_message_allocation import run_program
from test_wifi_rf_power_replay import RF, object_type


def agc_source() -> str:
    core = RF.read_text()
    return (object_type(core, "WifiModemBlock") + object_type(core, "BbaAgcBlock")
            + MOCK + procedure((RF.parents[3] / "radio_phy.nim").read_text(), "updateReg32")
            + RF.with_name("rf_bl808_phy_agc.nim").read_text() + ORACLE)


MOCK = r'''
type Event = tuple[kind: char, offset: int, value: uint32]
var
  mmio: array[0xD000 div 4, uint32]
  trace, wanted: seq[Event]
  cache: ptr int8
  mutateAfterFirstLane: bool
proc wifiModemRegs(): ptr WifiModemBlock = cast[ptr WifiModemBlock](addr mmio[0])
proc bbaAgcRegs(): ptr BbaAgcBlock = cast[ptr BbaAgcBlock](addr mmio[0xB000 div 4])
proc offset(p: ptr uint32): int =
  result = int(cast[uint](p) - cast[uint](addr mmio[0]))
  doAssert result in 0 ..< sizeof(mmio) and (result and 3) == 0
proc volatileLoad(p: ptr uint32): uint32 =
  trace.add(('r', offset(p), p[]))
  p[]
proc volatileStore(p: ptr uint32; value: uint32) =
  trace.add(('w', offset(p), value))
  p[] = value
  if mutateAfterFirstLane and offset(p) == 0xC080:
    cache[] = -40
    mutateAfterFirstLane = false
proc volatileLoad(p: ptr int8): int8 =
  doAssert p == cache
  trace.add(('r', -1, cast[uint8](p[]).uint32))
  p[]
proc volatileStore(p: ptr int8; value: int8) =
  doAssert p == cache
  trace.add(('w', -1, cast[uint8](value).uint32))
  p[] = value
'''


# Each tuple is (store PC in agc_config, offset from 0x24C00000, lsb, width,
# unshifted field). These are bus transactions, not just final register values.
ORACLE = r'''
const BeforeRxGain = [
  (0x026, 0xB390, 16, 1, 0x0),
  (0x03A, 0xB390, 10, 1, 0x0),
  (0x04A, 0xB3A4, 0, 8, 0x0),
  (0x05E, 0xB3A4, 8, 8, 0x0),
  (0x074, 0xB394, 16, 8, 0xF8),
  (0x088, 0xB398, 8, 8, 0x9E),
  (0x09E, 0xB3C4, 0, 8, 0xCE),
  (0x0B2, 0xB364, 24, 5, 0x8),
  (0x0C8, 0xB364, 16, 6, 0x3C),
  (0x0DA, 0xB364, 8, 6, 0x38),
  (0x0F0, 0xB364, 0, 6, 0x39),
  (0x108, 0xB368, 12, 10, 0x70),
  (0x120, 0xB368, 0, 10, 0x70),
  (0x136, 0xB36C, 0, 8, 0x10),
  (0x14C, 0xB36C, 8, 3, 0x5),
  (0x162, 0xB36C, 16, 8, 0x28),
  (0x178, 0xB36C, 24, 3, 0x7),
  (0x18E, 0xB370, 16, 7, 0x58),
  (0x1A4, 0xB3C0, 24, 8, 0x18),
  (0x1B6, 0xB380, 14, 6, 0x3E),
  (0x1CC, 0xB380, 20, 6, 0x37),
  (0x1DC, 0xB380, 26, 6, 0x1),
  (0x1EE, 0xB380, 13, 1, 0x0),
  (0x204, 0xB380, 10, 3, 0x1),
  (0x212, 0xB384, 26, 6, 0x39),
  (0x224, 0xB384, 20, 6, 0x37),
  (0x234, 0xB384, 14, 6, 0x14),
  (0x240, 0xB384, 13, 1, 0x0),
  (0x250, 0xB384, 10, 3, 0x2),
  (0x260, 0xB388, 26, 6, 0xF),
  (0x272, 0xB388, 20, 6, 0x17),
  (0x284, 0xB388, 14, 6, 0x2A),
  (0x290, 0xB388, 13, 1, 0x0),
  (0x2A4, 0xB388, 10, 3, 0x5),
  (0x2B4, 0xB38C, 26, 6, 0x19),
  (0x2C4, 0xB38C, 20, 6, 0x0),
  (0x2D4, 0xB38C, 14, 6, 0xE),
  (0x2E4, 0xB38C, 10, 3, 0x2),
  (0x2F8, 0xC830, 26, 6, 0x3F),
  (0x30C, 0xC830, 20, 6, 0x1),
  (0x31C, 0xC830, 14, 6, 0x36),
  (0x32A, 0xC830, 10, 3, 0x5),
  (0x334, 0xC814, 0, 2, 0x0),
  (0x34A, 0xC814, 2, 4, 0x2),
  (0x35A, 0xC814, 2, 4, 0x2),
  (0x368, 0xC040, 20, 5, 0xC),
  (0x378, 0xC040, 15, 5, 0x3),
  (0x382, 0xC044, 8, 8, 0x8),
  (0x38A, 0xC044, 0, 8, 0x0)
]
const AfterRxGain = [
  (0x3A8, 0xB3A0, 0, 8, 0x9E),
  (0x3C0, 0xB3C0, 0, 8, 0xB0),
  (0x3D0, 0xB3C0, 8, 8, 0xA3),
  (0x3DE, 0xC838, 31, 1, 0x1),
  (0x3EC, 0xC838, 0, 19, 0x40),
  (0x3FE, 0xC83C, 31, 1, 0x1),
  (0x40C, 0xC83C, 0, 20, 0x40),
  (0x41E, 0xC840, 31, 1, 0x1),
  (0x42C, 0xC840, 0, 22, 0x40),
  (0x442, 0xC82C, 15, 9, 0x40),
  (0x452, 0xC850, 24, 8, 0x8),
  (0x462, 0xC850, 16, 8, 0x3C),
  (0x474, 0xB304, 8, 7, 0x42),
  (0x488, 0xC85C, 16, 8, 0x30)
]
var expected: typeof(mmio)
var seed = 0x873153'u32
proc setup(seedMode: int) =
  for word in mmio.mitems:
    seed = seed * 1664525'u32 + 1013904223'u32
    word = case seedMode
      of 0: 0'u32
      of 1: 0xffffffff'u32
      else: seed
  expected = mmio
  cache = addr bl808PhyRxGainOffset
  trace.setLen(0)
  wanted.setLen(0)
proc field(offset, lsb, width, value: int) =
  let mask = (1'u32 shl width) - 1
  let prior = expected[offset div 4]
  let next = (prior and not (mask shl lsb)) or ((value.uint32 and mask) shl lsb)
  wanted.add(('r', offset, prior))
  wanted.add(('w', offset, next))
  expected[offset div 4] = next
proc expectRxGain(previous: int8; request: int32; mutate = false) =
  wanted.add(('r', -1, cast[uint8](previous).uint32))
  if previous.int32 == request: return
  var delta = int((request and 255) xor 128) - 128
  wanted.add(('w', -1, uint32(delta and 255)))
  for i, base in [8, 15, 22, 29, 35, 42, 48, 54, 60]:
    if i > 0: wanted.add(('r', -1, uint32(delta and 255)))
    field(0xC080 + 4 * (i div 4), 8 * (i mod 4), 8, (base + delta) and 255)
    if i == 0 and mutate: delta = -40
proc checkTrace() =
  doAssert trace.len == wanted.len, "unexpected number of bus transactions"
  for i in 0 ..< wanted.len:
    doAssert trace[i] == wanted[i], "event " & $i & ": " & $trace[i] & " != " & $wanted[i]
  doAssert mmio == expected
'''


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_agc_startup_order_and_repeat(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, agc_source() + r'''
doAssert bl808PhyRxGainOffset == -128 # phy.o .data.rxgain_offset_vs_temperature = 0x80
for seedMode in 0 .. 5:
  bl808PhyRxGainOffset = -128
  for warm in [false, true]:
    setup(seedMode)
    for (pc, o, lsb, width, value) in BeforeRxGain:
      field(o, lsb, width, value)
    expectRxGain((if warm: 0'i8 else: -128'i8), 0)
    for (pc, o, lsb, width, value) in AfterRxGain:
      field(o, lsb, width, value)
    programBl808PhyAgcRegisters()
    checkTrace()
    doAssert bl808PhyRxGainOffset == 0
    if not warm:
      doAssert mmio[0xC080 div 4] == 0x1D160F08'u32
      doAssert mmio[0xC084 div 4] == 0x36302A23'u32
      doAssert (mmio[0xC088 div 4] and 255) == 60
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_rxgain_signed_cache_and_lane_reloads(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, agc_source() + r'''
for request in [-128'i32, 0, 256, 256, -1, 255, -128, 128, -257, 127,
                high(int32), low(int32)]:
  setup(2)
  expectRxGain(bl808PhyRxGainOffset, request)
  configureBl808PhyRxGain(request)
  checkTrace()
  doAssert bl808PhyRxGainOffset == cast[int8](request)

setup(2)
mutateAfterFirstLane = true
expectRxGain(bl808PhyRxGainOffset, -9, true)
configureBl808PhyRxGain(-9)
checkTrace()
doAssert bl808PhyRxGainOffset == -40
''')
