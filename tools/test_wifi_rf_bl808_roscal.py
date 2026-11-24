"""Native ROSCAL traces from the BL808 demo rf_pri.o, not the legacy archive."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import procedure
from test_wifi_message_allocation import run_program
from test_wifi_rf_power_replay import RF, object_type


def native_source() -> str:
    core = RF.read_text()
    code = object_type(core, "RfRegBlock") + object_type(core, "RfDfeInitBlock")
    constants = ("RfMeasureTriggerClearMask", "RfMeasureModeKeepMask",
                 "RfMeasureRoscalMode", "RfMeasureStartMask", "RfMeasureReadyMask",
                 "RfRoscalCapabilityMask", "RfRoscalModeMask", "RfRoscalStartMode",
                 "RfRoscalDoneMode", "RfRoscalCodeMask", "RfRoscalWaitLimit")
    code += "const\n" + "".join(
        next(line for line in core.splitlines() if line.startswith(f"  {name} = ")) + "\n"
        for name in constants
    )
    code += MOCK
    code += procedure((RF.parents[3] / "radio_phy.nim").read_text(), "updateReg32")
    for name in ("programRfPriModeRegisters", "startRfPriTxDfeForCal",
                 "signedRfAverageMeasurement", "waitRfRoscalMeasurementReady"):
        code += procedure(core, name)
    code += core[core.index("type\n  RfRoscalSample ="):core.index("proc chooseRfRoscalCode(")]
    # Use the actual native 27-register snapshot, without unrelated TXCAL stages.
    code += RF.with_name("rf_bl808_calibration_snapshot.nim").read_text()
    return code + RF.with_name("rf_bl808_roscal.nim").read_text()


MOCK = r'''
type
  Event = tuple[op: char, offset: int, value: uint32]
  Adc = tuple[offset: int, value: uint32, latency: int]
var
  mem: array[0x2200 div 4, uint32]  # RF at 0, DFE at 0x1000, records at 0x2000.
  seen, wanted: seq[Event]
  adc: seq[Adc]
  sampleIndex, polls, latency: int
  pending: bool
  rfCalibDataGlobal: pointer
  nim_wifi_rf_pri_roscal_count, nim_wifi_rf_roscal_wait_timeout_count: uint32
  nim_wifi_rf_last_roscal_i, nim_wifi_rf_last_roscal_q: uint32
  nim_wifi_rf_roscal_search_log: array[16, uint32]
proc rfRegs(): ptr RfRegBlock = cast[ptr RfRegBlock](addr mem[0])
proc rfDfeInitRegs(): ptr RfDfeInitBlock = cast[ptr RfDfeInitBlock](addr mem[0x1000 div 4])
proc offset(p: ptr uint32): int = int(cast[uint](p) - cast[uint](addr mem[0]))
proc waitBl808RfCalUs(us: uint32) = seen.add(('d', 0, us))
proc volatileLoad(p: ptr uint32): uint32 =
  let o = offset(p)
  if o == 0x618 and pending:
    inc polls
    doAssert polls <= latency + 2, "ROSCAL failed to recognize READY"
    if polls > latency: p[] = p[] or 0x10000000'u32
  if o in [0x620, 0x624]:
    doAssert pending and polls > latency, "ADC consumed before real READY"
    doAssert sampleIndex < adc.len and adc[sampleIndex].offset == o
    result = adc[sampleIndex].value
    inc sampleIndex
  else:
    result = p[]
  seen.add(('r', o, result))
proc volatileStore(p: ptr uint32; value: uint32) =
  let o = offset(p)
  seen.add(('w', o, value))
  p[] = value
  if o == 0x618:
    pending = (value and 0x20000000'u32) != 0
    if pending:
      doAssert sampleIndex < adc.len, "unexpected measurement"
      polls = 0
      latency = adc[sampleIndex].latency
      p[] = p[] and not 0x10000000'u32
'''


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_native_roscal_transactions(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, native_source() + r'''
const Snapshot = [4, 0x2c, 0x1c, 0x30, 0xb8, 0xc0, 0xc4, 0x1030,
  0x84, 0x8c, 0x600, 0x60c, 0x618, 0x61c, 0x48, 0x20c, 0x214, 0x218,
  0x23c, 0x240, 0x244, 0xf0, 0x64, 0x58, 0x220, 0x70, 0xa4]
var seed = 197'u32
for trial in 0 .. 4:
  for word in mem.mitems:
    seed = seed * 1664525'u32 + 1013904223'u32
    word = seed
  mem[0x618 div 4] = mem[0x618 div 4] and not 0x30000000'u32
  mem[0x20 div 4] = (mem[0x20 div 4] and not 0x100'u32) or
    (if trial == 0: 0'u32 else: 0x100'u32)
  rfCalibDataGlobal = if trial == 1: nil else: addr mem[0x2000 div 4]
  seen.setLen(0)
  wanted.setLen(0)
  adc.setLen(0)
  pending = false
  sampleIndex = 0
  let before = mem
  var expected = mem
  let oldCount = nim_wifi_rf_pri_roscal_count
  let oldTimeouts = nim_wifi_rf_roscal_wait_timeout_count
  template rd(o: int) =
    wanted.add(('r', o, expected[o div 4]))
  template wr(o: int; value: uint32) =
    expected[o div 4] = value
    wanted.add(('w', o, expected[o div 4]))
  template rmw(o: int; keep, bits: uint32) =
    rd(o)
    wr(o, (expected[o div 4] and keep) or bits)
  rd(0x20)
  if trial == 0:
    rmw(0x14, 0xffff3fff'u32, 0)
  elif trial != 1:
    rmw(0x14, 0xffff3fff'u32, 0x4000)
    for o in Snapshot: rd(o)
    rmw(4, 0xfffffffd'u32, 0)
    wr(0x2c, 0)
    rmw(0x30, 0xffffffff'u32, 2)
    rmw(0x30, 0x21f0feff'u32, 0x21f06e00)
    wanted.add(('d', 0, 0'u32))
    rmw(0x220, 0xfffffe7f'u32, 0)
    rmw(0x220, 0xffffe7ff'u32, 0x1082)
    rmw(0x220, 0xffffffef'u32, 0x100)
    rmw(0x220, 0xffffff9f'u32, 0)
    rmw(0x220, 0xffffffff'u32, 0x21)
    rmw(0x220, 0xffffffff'u32, 0x40)
    rmw(0x1c, 0xffffffff'u32, 0x200)
    rmw(0x48, 0xffff8cff'u32, 0x3137)
    rmw(0x7c, 0x7fffffff'u32, 0)

    for iBranch in [true, false]:
      proc measure(code: int32; signed: int32) =
        let raw = cast[uint32](code)
        if iBranch: rmw(0x7c, 0xffffc0ff'u32, raw shl 8)
        else: rmw(0x7c, 0xffffffc0'u32, raw)
        rmw(0x618, 0xdfefffff'u32, 0)
        rmw(0x61c, 0xffff'u32, 0x04000000)
        rmw(0x618, 0xffffffff'u32, 0x20000000)
        let delay = if adc.len == 0: 10001 else: adc.len mod 3
        let o = if iBranch: 0x620 else: 0x624
        let word = 0xaa000000'u32 or (cast[uint32](signed) and 0x1ffffff)
        adc.add((o, word, delay))
        expected[0x618 div 4] = expected[0x618 div 4] and not 0x10000000'u32
        for _ in 0 ..< delay: rd(0x618)
        expected[0x618 div 4] = expected[0x618 div 4] or 0x10000000'u32
        rd(0x618)
        wanted.add(('r', o, word))
        rmw(0x618, 0xdfefffff'u32, 0)

      var winner: int32
      if trial == 2:
        # Explicit candidate transcripts for both fine-history exits (5 and 10).
        if iBranch:
          for k, c in [32, 16, 24, 20, 18, 19, 18, 19, 18, 19]:
            measure(c.int32, [1'i32, 0, 1, 1, -16777216, 1, 0, 1, -1, 16777215][k])
          winner = 18
        else:
          for k, c in [32, 48, 40, 44, 42, 41, 41, 40, 39, 40, 39]:
            measure(c.int32, [0'i32, 1, -1, 1, 1, 0, 1, 1, -1, 1, 0][k])
          winner = 40
      elif iBranch == (trial == 3):
        for c in [32, 16, 8, 4, 2, 1]: measure(c.int32, 1)
        for k in 0 ..< 63: measure(-k.int32, 1)
        winner = -63
      else:
        for c in [32, 48, 56, 60, 62, 63]: measure(c.int32, 0)
        for k in 0 ..< 63: measure((63 + k).int32, 0)
        winner = 126
      let raw = cast[uint32](winner)
      for k, record in [0x2060, 0x2058, 0x2050, 0x2048]:
        if iBranch: rmw(record, 0xffffffc0'u32, raw and 63)
        else: rmw(record, 0xfffff03f'u32, (raw and 63) shl 6)
        let lane = if k < 2: 0x16c else: 0x168
        let shift = (if k mod 2 == 0: 16 else: 0) + (if iBranch: 0 else: 8)
        rmw(lane, not (63'u32 shl shift), raw shl shift)
    for o in Snapshot: wr(o, before[o div 4])
    rmw(0x14, 0xffffffff'u32, 0xc000)
  runBl808Roscal()
  doAssert seen.len == wanted.len
  for i in 0 ..< wanted.len:
    doAssert seen[i] == wanted[i], "event " & $i & ": " & $seen[i] & " != " & $wanted[i]
  doAssert mem == expected and sampleIndex == adc.len and not pending
  doAssert nim_wifi_rf_pri_roscal_count == oldCount + uint32(trial >= 2)
  doAssert nim_wifi_rf_roscal_wait_timeout_count == oldTimeouts + uint32(trial >= 2)
''')
