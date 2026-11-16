"""BBA public state, publication widths and mutable RF data from bba.c.o."""

from pathlib import Path
import re

import pytest

from test_wifi_message_allocation import run_program
from test_wifi_rf_channel_entry import rf_procedure
from test_wifi_rf_core_entry import wl_types
from test_wifi_rf_power_replay import RF, object_type


def source() -> str:
    rf = RF.read_text()
    code = "".join(object_type(rf, name) for name in
                   ("BbaRuntimeState", "BbaAgcBlock", "WifiModemBlock", "RfRegBlock"))
    code += rf[rf.index("var bbaEnv*"):].split("\nvar wlCfgGlobal", 1)[0] + "\n"
    code += r'''
type Event = tuple[address: uint32, width: int, value: uint32, irq: bool]
var
  alternate: array[3, BbaRuntimeState]
  rfBank: array[0x900 div 4, uint32]
  mdmBank: array[0xD000 div 4, uint32]
  events: seq[Event]
  irqEnabled = true
  mutateAfterDetect: bool
  randomState = 0x9E3779B9'u32
proc volatileLoad[T](p: ptr T): T = p[]
'''
    code += "template bbaState()" + rf.split("template bbaState()", 1)[1].split("\ntemplate", 1)[0] + "\n"
    code += r'''
proc active(): var BbaRuntimeState = bbaState()[]
proc address[T](p: ptr T): uint32 =
  let raw = cast[uint](p)
  for bank in [(cast[uint](addr rfBank[0]), sizeof(rfBank).uint, 0x20001000'u32),
               (cast[uint](addr mdmBank[0]), sizeof(mdmBank).uint, 0x24C00000'u32),
               (cast[uint](addr bbaEnv), sizeof(bbaEnv).uint, 0xF0000000'u32),
               (cast[uint](addr alternate[0]), sizeof(bbaEnv).uint, 0xF0000000'u32),
               (cast[uint](addr alternate[1]), sizeof(bbaEnv).uint, 0xF0000000'u32),
               (cast[uint](addr alternate[2]), sizeof(bbaEnv).uint, 0xF0000000'u32)]:
    if raw >= bank[0] and raw < bank[0] + bank[1]: return bank[2] + (raw - bank[0]).uint32
  doAssert false, "write outside selected BBA/register storage"
proc volatileStore[T](p: ptr T; value: T) =
  events.add((address(p), sizeof(T), value.uint32, irqEnabled))
  p[] = value
proc updateReg32(p: ptr uint32; keep, value: uint32) =
  volatileStore(p, (p[] and keep) or value)
  if address(p) == 0x24C0C830'u32 and mutateAfterDetect:
    active().pdRssiState = 4
    mutateAfterDetect = false
proc rfRegs(): ptr RfRegBlock = cast[ptr RfRegBlock](addr rfBank[0])
proc wifiModemRegs(): ptr WifiModemBlock = cast[ptr WifiModemBlock](addr mdmBank[0])
proc bbaAgcRegs(): ptr BbaAgcBlock = cast[ptr BbaAgcBlock](addr mdmBank[0xB000 div 4])
proc bbaIrqSave(): uint32 =
  result = if irqEnabled: 8'u32 else: 0'u32
  irqEnabled = false
proc bbaIrqRestore(saved: uint32) = irqEnabled = (saved and 8) != 0
proc randomWord(): uint32 =
  randomState = randomState xor (randomState shl 13)
  randomState = randomState xor (randomState shr 17)
  randomState = randomState xor (randomState shl 5)
  randomState
proc setup() =
  when declared(bbaRuntimeGlobal): bbaRuntimeGlobal = addr bbaEnv
  for word in rfBank.mitems: word = randomWord()
  for word in mdmBank.mitems: word = randomWord()
  let bytes = cast[ptr UncheckedArray[uint8]](addr bbaEnv)
  for i in 0 ..< sizeof(bbaEnv): bytes[i] = randomWord().uint8
  for item in alternate.mitems: item = bbaEnv
  events.setLen(0)
  irqEnabled = true
  mutateAfterDetect = false
'''
    for name in ("bbaProgramPdGain", "bba_get_pd_gain", "bba_get_pd_state", "bba_get_pd_mile",
                 "bba_set_pd_ofdm", "bba_set_pd_dsss", "bbaProgramPdLatchRegs", "bbaSetPdLatch",
                 "bba_set_pd_mile", "bba_set_pd_state", "bbaResetCeUpdatePeriod", "bba_init",
                 "bba_reset", "bba_ce_reset", "bba_pd_reset", "bbaUpdatePdComp", "bbaRunPowerDetectLoop"):
        if re.search(rf"^proc {name}\*?\(", rf, re.M):
            code += rf_procedure(rf, name)
    return code + r'''
proc fieldEvent(offset, width: int; value: uint32; irq: bool): Event =
  (0xF0000000'u32 + offset.uint32, width, value, irq)
proc wantedRmw(trace: var seq[Event]; bank: var array[0xD000 div 4, uint32];
               offset: int; keep, value: uint32; irq: bool) =
  bank[offset div 4] = (bank[offset div 4] and keep) or value
  trace.add((0x24C00000'u32 + offset.uint32, 4, bank[offset div 4], irq))
proc gainTrace(trace: var seq[Event]; bank: var array[0xD000 div 4, uint32];
               raw: uint32; irq: bool) =
  let gain = if raw in [1'u32, 2, 3]: raw else: 0'u32
  wantedRmw(trace, bank, 0xB390, if gain in [0'u32, 1]: 0xFFFFFEFF'u32 else: high(uint32),
            if gain in [2'u32, 3]: 0x100'u32 else: 0'u32, irq)
  wantedRmw(trace, bank, 0xB390, if gain in [0'u32, 2]: 0xFFFFFDFF'u32 else: high(uint32),
            if gain in [1'u32, 3]: 0x200'u32 else: 0'u32, irq)
  wantedRmw(trace, bank, 0xB3C0, 0xFFFF00FF'u32, [0xA300'u32, 0xB900, 0xC400, 0xD000][gain], irq)
  wantedRmw(trace, bank, 0xB3C0, 0xFFFFFF00'u32, [0xB0'u32, 0xB5, 0xBA, 0xBF][gain], irq)
  if gain in [2'u32, 3]:
    wantedRmw(trace, bank, 0xC044, 0xFFFF00FF'u32, if gain == 2: 0x400'u32 else: 0x200'u32, irq)
    wantedRmw(trace, bank, 0xB36C, 0xFFFFFF00'u32, 0x14, irq)
  wantedRmw(trace, bank, 0xB3AC, 0xFFFFFF00'u32, [0xC2'u32, 0xC2, 0xC8, 0xCC][gain], irq)
  wantedRmw(trace, bank, 0xB3AC, 0xFFF00FFF'u32, [0xBF000'u32, 0xBF000, 0xC5000, 0xC9000][gain], irq)
  if gain in [0'u32, 1]:
    wantedRmw(trace, bank, 0xC044, 0xFFFF00FF'u32, if gain == 0: 0x800'u32 else: 0x600'u32, irq)
    wantedRmw(trace, bank, 0xB36C, 0xFFFFFF00'u32, if gain == 0: 0x10'u32 else: 0x14'u32, irq)
  trace.add(fieldEvent(9, 1, gain, irq))
'''


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_bba_init_and_reset_state_publication_widths(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for reset in [false, true]:
  for vector in 0 ..< 200:
    setup()
    var trace: seq[Event]
    var expected = active()
    var bank = mdmBank
    let oldRf = rfBank
    if reset:
      trace.add(fieldEvent(8, 4, 0x10000, true))
      trace.add(fieldEvent(16, 2, 10, true))
      for offset in [0, 4]: trace.add(fieldEvent(offset, 4, 0, true))
      trace.add(fieldEvent(12, 1, 0, true))
      trace.add(fieldEvent(14, 2, 0, true))
      trace.add(fieldEvent(18, 1, 0, true))
    else:
      trace.add(fieldEvent(10, 1, 1, true))
      trace.add(fieldEvent(16, 2, 10, true))
      for offset in [0, 4]: trace.add(fieldEvent(offset, 4, 0, true))
      for offset in [8, 12, 18]: trace.add(fieldEvent(offset, 1, 0, true))
      trace.add(fieldEvent(14, 2, 0, true))
    gainTrace(trace, bank, 0, true)
    wantedRmw(trace, bank, 0xB390, 0xFFFFFF0F'u32, 0, true)
    wantedRmw(trace, bank, 0xC830, 0xFC0FFFFF'u32, 0x100000, true)
    trace.add(fieldEvent(11, 1, 0, true))
    trace.add((0x2000150C'u32, 4, oldRf[0x50C div 4] and 0xFFFFFEFF'u32, true))
    trace.add((0x2000150C'u32, 4, oldRf[0x50C div 4] and 0xFFFFFCFF'u32, true))
    expected.ceLoopScratch0 = 0
    expected.ceLoopScratch4 = 0
    expected.pdRssiState = 0
    expected.pdGainCode = 0
    expected.pdCompCurrent = 1
    expected.pdCompLatch = 0
    expected.pdLoopToCeAccumulatorPadding0 = 0
    expected.cePpmAccumulator = 0
    expected.ceUpdateInterval = 10
    expected.ceUpdateCount = 0
    expected.ceCapcodeHoldoff = 0
    if reset: bba_reset()
    else: bba_init()
    doAssert events == trace, "BBA reset/init publication widths or order differ"
    doAssert active() == expected and mdmBank == bank and irqEnabled
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_bba_carrier_reset_publishes_interval_and_count_together(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for vector in 0 ..< 1000:
  setup()
  var expected = active()
  expected.cePpmAccumulator = 0
  expected.ceUpdateInterval = 16
  expected.ceUpdateCount = 0
  bba_ce_reset()
  doAssert active() == expected
  doAssert events == @[fieldEvent(14, 2, 0, true), fieldEvent(16, 2, 16, true)],
    "CE interval/count reset was split into byte stores"
  events.setLen(0)
  bba_pd_reset()
  doAssert active() == expected and events.len == 0
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_bba_public_and_loop_latch_publication_order(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for value in [0'u32, 1, 2, 255, high(uint32)]:
  setup()
  let before = rfBank[0x50C div 4]
  bba_set_pd_mile(value)
  let first = if value == 0: before and 0xFFFFFEFF'u32 else: before or 0x100'u32
  doAssert events == @[fieldEvent(11, 1, (value != 0).uint32, true),
    (0x2000150C'u32, 4, first, true), (0x2000150C'u32, 4, first and 0xFFFFFDFF'u32, true)],
    "public MILE state must precede register changes"
for initialIrq in [false, true]:
  setup()
  irqEnabled = initialIrq
  active().pdRssiState = 2
  active().pdCompLatch = 0
  active().pdCompCurrent = 0
  let before = rfBank[0x50C div 4]
  bbaRunPowerDetectLoop(-10)
  doAssert events == @[(0x2000150C'u32, 4, before or 0x100'u32, false),
    (0x2000150C'u32, 4, (before or 0x100'u32) and 0xFFFFFDFF'u32, false),
    fieldEvent(11, 1, 1, false)], "loop MILE state must follow register changes"
  doAssert irqEnabled == initialIrq
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_bba_gain_profiles_match_all_ordered_vendor_stores(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for raw in [0'u32, 1, 2, 3, 4, 255, high(uint32)]:
  for vector in 0 ..< 100:
    setup()
    var expected = mdmBank
    var trace: seq[Event]
    gainTrace(trace, expected, raw, true)
    bbaProgramPdGain(raw)
    doAssert events == trace and mdmBank == expected
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_bba_public_state_samples_after_detect_writes_and_masks_all_updates(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for initialIrq in [false, true]:
  for old in [0'u8, 1, 2, 3, 4, 255]:
    for requested in [0'u32, 1, 2, 3, 4, 255, 256, 260, high(uint32)]:
      setup()
      irqEnabled = initialIrq
      active().pdRssiState = old
      let oldGain = active().pdGainCode
      bba_set_pd_state(requested)
      doAssert active().pdRssiState == requested.uint8 and irqEnabled == initialIrq
      doAssert active().pdGainCode == (case requested
        of 0, 1: 0'u8
        of 2: 1'u8
        of 3, 4: 2'u8
        else: oldGain)
      for event in events: doAssert not event.irq
      if old == 4 or requested == 4:
        let latch = (requested == 4).uint32
        let index = events.find(fieldEvent(11, 1, latch, false))
        doAssert index >= 0 and index + 1 < events.len
        doAssert events[index + 1].address == 0x2000150C'u32,
          "public detector state published the latch after MMIO"
  setup()
  active().pdRssiState = 3
  active().pdCompLatch = 1
  mutateAfterDetect = true
  bba_set_pd_state(0)
  doAssert active().pdCompLatch == 0, "old detector state was sampled before detect writes"
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_bba_state_pointer_export_selects_current_storage(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
when declared(bbaRuntimeGlobal):
  setup()
  let before = bbaEnv
  let neighbors = alternate
  bbaRuntimeGlobal = addr alternate[1]
  bba_reset()
  doAssert bbaEnv == before and alternate[0] == neighbors[0] and alternate[2] == neighbors[2]
  doAssert bba_get_pd_state() == 0 and bba_get_pd_gain() == 0 and bba_get_pd_mile() == 0
  alternate[1].pdRssiState = 99
  alternate[1].pdGainCode = 88
  alternate[1].pdCompLatch = 77
  doAssert bba_get_pd_state() == 99 and bba_get_pd_gain() == 88 and bba_get_pd_mile() == 77
else:
  doAssert false, "missing replaceable BBA state pointer export"
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_bba_mutable_signed_thresholds_preserve_branch_priority(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
when compiles(block:
    BbaPdThresholdAttack[1] = -60'i8
    BbaPdThresholdRelease[1] = -80'i8):
  for profile in 0 ..< 16:
    for index in 0 ..< 4:
      BbaPdThresholdAttack[index] = cast[int8](((profile * 31 + index * 77) mod 256).uint8)
      BbaPdThresholdRelease[index] = cast[int8](((profile * 53 + index * 33) mod 256).uint8)
    for initial in [0'u8, 1, 2, 3, 4, 255]:
      for rssi in -128 .. 127:
        setup()
        active().pdRssiState = initial
        active().pdCompLatch = 0
        active().pdCompCurrent = 0
        var wanted = initial
        case initial
        of 0:
          if rssi > BbaPdThresholdAttack[1].int: wanted = 1
        of 1:
          if rssi > BbaPdThresholdAttack[2].int: wanted = 2
          elif rssi < BbaPdThresholdRelease[1].int: wanted = 0
        of 2:
          if rssi < -14 and rssi <= BbaPdThresholdAttack[3].int:
            if rssi < BbaPdThresholdRelease[1].int: wanted = 0
            elif rssi < BbaPdThresholdRelease[2].int: wanted = 1
        of 3:
          if rssi < -14:
            if rssi < BbaPdThresholdRelease[1].int: wanted = 0
            elif rssi < BbaPdThresholdRelease[2].int: wanted = 1
            elif rssi < BbaPdThresholdRelease[3].int: wanted = 2
        else:
          if rssi > BbaPdThresholdAttack[1].int: wanted = 1
        bbaRunPowerDetectLoop(rssi.int32)
        doAssert active().pdRssiState == wanted, "custom signed thresholds changed branch priority"
else:
  doAssert false, "BBA threshold data is immutable"
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_bba_carrier_callbacks_reload_current_state_pointer(tmp_path: Path, mode: str) -> None:
    rf = RF.read_text()
    code = wl_types() + source() + r'''
var
  cfg: WlRfConfig
  wlCfgGlobal: pointer = addr cfg
  setterArgs: array[2, uint8]
proc getCurrent(a, b: ptr uint8) {.cdecl.} =
  doAssert a != b
  a[] = 31
  b[] = 42
  when declared(bbaRuntimeGlobal): bbaRuntimeGlobal = addr alternate[1]
proc setCurrent(a, b: uint8) {.cdecl.} =
  setterArgs = [a, b]
  doAssert not irqEnabled
  when declared(bbaRuntimeGlobal): bbaRuntimeGlobal = addr alternate[2]
'''
    code += rf_procedure(rf, "signExtend") + rf_procedure(rf, "bbaApplyCarrierErrorCapcode")
    run_program(tmp_path, mode, code + r'''
when declared(bbaRuntimeGlobal):
  setup()
  bbaEnv.cePpmAccumulator = 500
  alternate[1].cePpmAccumulator = 0xFE0C
  alternate[2].cePpmAccumulator = 12345
  alternate[2].ceCapcodeHoldoff = 0
  let before = bbaEnv
  let otherBefore = alternate
  cfg.capcodeGetCallback = cast[pointer](getCurrent)
  cfg.capcodeSetCallback = cast[pointer](setCurrent)
  bbaApplyCarrierErrorCapcode()
  doAssert setterArgs == [32'u8, 32], "getter rebinding did not affect current CE direction"
  doAssert bbaEnv == before and alternate[0] == otherBefore[0] and alternate[1] == otherBefore[1]
  var expected = otherBefore[2]
  expected.cePpmAccumulator = 0
  expected.ceCapcodeHoldoff = 1
  doAssert alternate[2] == expected and irqEnabled
  doAssert events == @[fieldEvent(14, 2, 0, false), fieldEvent(18, 1, 1, false)]
else:
  doAssert false, "missing replaceable BBA state pointer export"
''')
