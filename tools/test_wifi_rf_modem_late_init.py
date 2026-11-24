"""Check BL808 demo crystal handoff and the port's later modem writes."""

import struct
from pathlib import Path

import pytest

from test_wifi_disconnect_tx import procedure
from test_wifi_message_allocation import run_program
from test_wifi_rf_power_replay import RF, array_constant, object_type


def modem_early_source() -> str:
    rf = RF.read_text()
    code = f'from "{RF.parents[3] / "radio_phy"}" import RadioPhyMode, wifiOnly, bleOnly, wifiBleCoex, apiFromRadioPhyMode\n'
    code += object_type(rf, "RfRegBlock")
    code += r'''
type RfcXtalConfig = object
  xtalHz, xtalCountWindowMin, xtalCountWindowMax: uint32
  xtalDividerConfig, xtalControlCode: uint32
const
  WlXtal24M = 24_000_000'u32
  WlXtal26M = 26_000_000'u32
  WlXtal32M = 32_000_000'u32
  WlXtal38P4M = 38_400_000'u32
  WlXtal40M = 40_000_000'u32
  WlXtal52M = 52_000_000'u32
var
  rfWords: array[(sizeof(RfRegBlock) + 3) div 4, uint32]
  events: seq[tuple[kind, value: uint32]]
  nimFwDbgRfApiMode: uint32
  stagedHz: uint32
proc rfRegs(): ptr RfRegBlock = cast[ptr RfRegBlock](addr rfWords[0])
proc volatileLoad(p: ptr uint32): uint32 = p[]
proc volatileStore(p: ptr uint32; value: uint32) =
  events.add((uint32(cast[uint](p) - cast[uint](addr rfWords[0])), value))
  p[] = value
proc updateReg32(p: ptr uint32; keep, value: uint32) =
  volatileStore(p, (volatileLoad(p) and keep) or value)
proc rf_pri_input_xtalfreq(hz: uint32) =
  stagedHz = hz
  events.add((0xF001'u32, hz))
proc rfPriLoadConfiguredDeviceInfo() = events.add((0xF002'u32, 0'u32))
proc rf_pri_init(cold, mode: uint32) =
  events.add((0xF003'u32, cold or (mode shl 8)))
proc programRfcVcoTable() = events.add((0xF004'u32, 0'u32))
proc programRfcModemLateInit() = events.add((0xF005'u32, 0'u32))
'''
    code += array_constant(rf, "RfcXtalConfigTable")
    return (code + procedure(rf, "xtalIndex") + procedure(rf, "rfcModemXtalConfig") +
            procedure(rf[rf.rindex("proc modemInitCoreMode"):], "modemInitCoreMode"))


def modem_late_source() -> str:
    rf = RF.read_text()
    code = "".join(object_type(rf, name) for name in (
        "RfRegBlock", "BbaAgcBlock", "PhyAgcBlock", "RfAuxCtrlBlock",
    ))
    code += r'''
var
  rfWords: array[(sizeof(RfRegBlock) + 3) div 4, uint32]
  bbaWords: array[(sizeof(BbaAgcBlock) + 3) div 4, uint32]
  phyWords: array[(sizeof(PhyAgcBlock) + 3) div 4, uint32]
  auxWords: array[(sizeof(RfAuxCtrlBlock) + 3) div 4, uint32]
  selected: seq[tuple[offset: int, value: uint32]]
  allWrites: seq[tuple[address, value: uint32]]
proc rfRegs(): ptr RfRegBlock = cast[ptr RfRegBlock](addr rfWords[0])
proc bbaAgcRegs(): ptr BbaAgcBlock = cast[ptr BbaAgcBlock](addr bbaWords[0])
proc phyRegs(): ptr PhyAgcBlock = cast[ptr PhyAgcBlock](addr phyWords[0])
proc rfAuxCtrlRegs(): ptr RfAuxCtrlBlock = cast[ptr RfAuxCtrlBlock](addr auxWords[0])
proc volatileLoad(p: ptr uint32): uint32 = p[]
proc volatileStore(p: ptr uint32; value: uint32) =
  let address = cast[uint](p)
  let rfBase = cast[uint](addr rfWords[0])
  let phyBase = cast[uint](addr phyWords[0])
  let bbaBase = cast[uint](addr bbaWords[0])
  let auxBase = cast[uint](addr auxWords[0])
  if address >= rfBase and address < rfBase + sizeof(rfWords).uint:
    let offset = int(address - rfBase)
    allWrites.add((0x20001000'u32 + offset.uint32, value))
    if offset in [0x260, 0x268, 0x26C]:
      selected.add((offset, value))
  elif address >= phyBase and address < phyBase + sizeof(phyWords).uint:
    let offset = int(address - phyBase)
    allWrites.add((0x20002800'u32 + offset.uint32, value))
    if offset == 0xA8:
      selected.add((0x28A8, value))
  elif address >= bbaBase and address < bbaBase + sizeof(bbaWords).uint:
    allWrites.add((0x24C0B000'u32 + uint32(address - bbaBase), value))
  elif address >= auxBase and address < auxBase + sizeof(auxWords).uint:
    allWrites.add((0x20000500'u32 + uint32(address - auxBase), value))
  else:
    doAssert false, "unmapped modem-init register write"
  p[] = value
proc updateReg32(p: ptr uint32; keep, value: uint32) =
  volatileStore(p, (volatileLoad(p) and keep) or value)
'''
    return code + procedure(rf, "programRfcModemLateInit")


def modem_vco_source() -> str:
    rf = RF.read_text()
    code = object_type(rf, "RfRegBlock") + r'''
const RfCalibLoVcoHalfwordBase = 14
var
  rfCalibDataGlobal: pointer
  calib: array[40, uint16]
  rfWords: array[(sizeof(RfRegBlock) + 3) div 4, uint32]
  trace: seq[tuple[write: bool, offset, value: uint32]]
proc rfRegs(): ptr RfRegBlock = cast[ptr RfRegBlock](addr rfWords[0])
proc volatileLoad(p: ptr uint32): uint32 =
  trace.add((false, uint32(cast[uint](p) - cast[uint](addr rfWords[0])), p[]))
  p[]
proc volatileStore(p: ptr uint32; value: uint32) =
  trace.add((true, uint32(cast[uint](p) - cast[uint](addr rfWords[0])), value))
  # Model live reserved bits changing between stores.
  p[] = value xor 0x00200020'u32
proc updateReg32(p: ptr uint32; keep, value: uint32) =
  volatileStore(p, (volatileLoad(p) and keep) or value)
'''
    return code + rf[rf.index("proc rfPriVcoCalWord("):rf.index("proc rf_dump_status*(")]


@pytest.mark.parametrize("mode", ["checked", "firmware"])
def test_modem_vco_calibration_table_handoff(tmp_path: Path, mode: str) -> None:
    # BL808 demo rfc.o:rfc_init+0x246..0x74a, first four stores at
    # +0x25e/+0x27e/+0x29c/+0x2bc and final two at +0x72c/+0x74a.
    run_program(tmp_path, mode, modem_vco_source() + r'''
rfCalibDataGlobal = addr calib[0]
for index in 0 .. 20:
  calib[14 + index] = uint16(0x8400 + index * 0x400 + 0xE0 + index)
for item in rfWords.mitems: item = 0xA5A55A5A'u32
var wanted = rfWords
var expected: seq[tuple[write: bool, offset, value: uint32]]
for index in 0 .. 20:
  let slot = 0x13C div 4 + index div 2
  let offset = uint32(slot * 4)
  let shift = 16 * (index mod 2)
  let freq = uint32(0x84 + index * 4)
  let idac = uint32(index)
  for (mask, bits) in [(0xFF00'u32, freq shl 8), (0x001F'u32, idac)]:
    let live = wanted[slot]
    let next = (live and not (mask shl shift)) or (bits shl shift)
    expected.add((false, offset, live))
    expected.add((true, offset, next))
    wanted[slot] = next xor 0x00200020'u32
programRfcVcoTable()
doAssert trace == expected, "expected 42 alternating live loads and field stores"
doAssert rfWords == wanted
''')


def demo_xtal_vectors() -> str:
    # Git blob a9935b475d2198000ae7b67d141f00767176a81a,
    # rfc.o .rodata.cst8+0x10..0x3f; operations at rfc_init+0xde..0x23e.
    half, special, generic, scale, low, high = struct.unpack("<6d", bytes.fromhex(
        "000000000000e03f 00000040cf23e841 000000009651e841 "
        "0000000000005041 5555555555583441 abaaaaaa6a6e3941"
    ))
    nominal = (24_000_000, 26_000_000, 32_000_000, 38_400_000, 40_000_000, 52_000_000)
    frequencies = [hz + delta for hz in nominal for delta in (-101, -1, 0, 1, 101)]
    frequencies += [0, 1, 3_187_499, 3_187_500, 3_187_501, 0xFFFFFFFF]
    rows = []
    for hz in frequencies:
        # No demo field oracle for divide by zero / an overflowing conversion.
        # The port deliberately preserves its previous row-0 fields here.
        divisor = hz if hz > 3_187_500 else nominal[0]
        numerator = special if hz == 40_000_000 else generic
        fields = [int(n / divisor * scale + half) for n in (low, high, numerator)]
        values = [hz, *fields, 0x97E if hz == 40_000_000 else 0x990,
                  hz if hz in nominal else 40_000_000]
        rows.append("[" + ", ".join(f"{v}'u32" for v in values) + "]")
    return "const vectors = [\n" + ",\n".join(rows) + "\n]\n"


@pytest.mark.parametrize("mode", ["checked", "firmware"])
def test_modem_early_xtal_table_and_handoff(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, modem_early_source() + demo_xtal_vectors() + r'''
for row in vectors:
  let frequency = row[0]
  for seed in [0'u32, high(uint32), 0xA5A55A5A'u32]:
    for restore in [0'u32, 1'u32, 2'u32]:
      for radioMode in [wifiOnly, bleOnly, wifiBleCoex]:
        for word in rfWords.mitems: word = seed
        events.setLen(0)
        stagedHz = WlXtal26M
        modemInitCoreMode(frequency, restore, radioMode)
        let api = apiFromRadioPhyMode(radioMode).uint32
        let first220 = seed and 0xFBFFFFFF'u32
        let second220 = (first220 and 0xF7FFFFFF'u32) or 0x08000000'u32
        var expected = @[
          (0x220'u32, first220),
          (0x220'u32, second220),
        ]
        if restore == 0:
          expected.add((0xF001'u32, row[5]))
        expected.add(@[
          (0xF002'u32, 0'u32),
          (0xF003'u32, (if restore == 0: 1'u32 else: 0'u32) or (api shl 8)),
          (0x1C0'u32, (seed and 0xFFFFF000'u32) or (row[4] and 0xFFF'u32)),
          (0x1C4'u32, (seed and 0xE0000000'u32) or (row[3] and 0x1FFFFFFF'u32)),
          (0x1C8'u32, (seed and 0xFFF00000'u32) or (row[1] and 0xFFFFF'u32)),
          (0x1CC'u32, (seed and 0xFFF00000'u32) or (row[2] and 0xFFFFF'u32)),
          (0xF004'u32, 0'u32),
          (0xF005'u32, 0'u32),
          (0x504'u32, seed or 0x10'u32),
          (0x514'u32, seed or 0x10'u32),
        ])
        doAssert events == expected, "early modem-init register/call order differs"
        doAssert nimFwDbgRfApiMode == api
        doAssert stagedHz == (if restore == 0: row[5] else: WlXtal26M)
''')


@pytest.mark.parametrize("mode", ["checked", "firmware"])
def test_modem_restore_uses_raw_hz_without_new_selection(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, modem_early_source() + r'''
modemInitCoreMode(51_999_999, 0, wifiOnly)
doAssert stagedHz == WlXtal40M
doAssert rfRegs().xtalDividerConfig1c4 == 0x0FB13B19'u32
events.setLen(0)
modemInitCoreMode(WlXtal26M, 1, wifiOnly)
for event in events: doAssert event.kind != 0xF001
doAssert stagedHz == WlXtal40M
doAssert rfRegs().xtalDividerConfig1c4 == 0x1F627627'u32
''')


@pytest.mark.parametrize("mode", ["checked", "firmware"])
def test_modem_late_channel_sequencer_fields(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, modem_late_source() + r'''
for seed in [0'u32, high(uint32), 0xA5A55A5A'u32, 0x12345678'u32]:
  rfWords = default(typeof(rfWords))
  bbaWords = default(typeof(bbaWords))
  phyWords = default(typeof(phyWords))
  auxWords = default(typeof(auxWords))
  selected.setLen(0)
  allWrites.setLen(0)
  rfWords[0x260 div 4] = seed
  rfWords[0x268 div 4] = seed
  rfWords[0x26C div 4] = seed
  let first268 = (seed and 0xFFFF0000'u32) or 0x1040'u32
  let first26c = seed and 0xFFFFFFF7'u32
  let first260 = (seed and 0xBFFFFFFF'u32) or 0x40000000'u32
  let second260 = (first260 and 0xDFFFFFFF'u32) or 0x20000000'u32
  # rfc.c.o modem_init_core+0x308..0x390; the timer store is at +0x332.
  let expected = @[
    (0x26C, first26c),
    (0x268, first268),
    (0x260, first260),
    (0x260, second260),
    (0x28A8, 0xC8'u32),
    (0x26C, (first26c and 0xFFF003FF'u32) or 0x00014000'u32),
    (0x268, (first268 and 0xC00FFFFF'u32) or 0x0F000000'u32),
  ]
  programRfcModemLateInit()
  doAssert selected == expected
  doAssert rfWords[0x260 div 4] == second260
  doAssert rfWords[0x26C div 4] == expected[5][1]
  doAssert rfWords[0x268 div 4] == expected[6][1]
''')


# Ordered stores from rfc.c.o:modem_init_core+0x1a2..0x3b6.
MODEM_LATE_WRITES = (
    (0x20001004, 0xFFFFF7FF, 0),
    (0x2000126C, 0xFFFFFFF7, 0),
    (0x20001268, 0xFFFF0000, 0x1040),
    (0x20001004, 0xFFFFFFFF, 0x2),
    (0x2000102C, 0xFFFFFFFF, 0x4),
    (0x2000163C, 0xFFFFFFFF, 0x80),
    (0x2000163C, 0xFFFF7FFF, 0x8000),
    (0x2000163C, 0xFFFFFF80, 0),
    (0x2000163C, 0xFFFF80FF, 0),
    (0x2000102C, 0xFFFFFFFF, 0x2),
    (0x2000102C, 0xFFFFBFFF, 0x4000),
    (0x2000102C, 0xFFFFFFFF, 0x20),
    (0x20001400, 0xFF7FFFFF, 0x800000),
    (0x20001400, 0xFFFF7FFF, 0x8000),
    (0x20001400, 0xFFFFBFFF, 0x4000),
    (0x20001400, 0xFFFFFFFF, 0x200),
    (0x20001400, 0xFFFFFFFF, 0x100),
    (0x20000540, 0xFFFFFCFF, 0xC00),
    (0x20000544, 0xFFFFFFFB, 0),
    (0x20001220, 0xF7FFFFFF, 0),
    (0x20001004, 0xFFFFFFFF, 0x2),
    (0x2000102C, 0xFFFFFFDF, 0),
    (0x20001094, 0xFFFEFFFF, 0x10000),
    (0x20001080, 0xBFFFFFFF, 0x40000000),
    (0x20001260, 0xBFFFFFFF, 0x40000000),
    (0x20001260, 0xDFFFFFFF, 0x20000000),
    (0x200028A8, 0x00000000, 0xC8),
    (0x200012C4, 0xFFFFFFFF, 0x2),
    (0x200012C4, 0xFFFFFFFE, 0),
    (0x24C0C01C, 0xFFFFFC00, 0x50),
    (0x24C0C020, 0xFFFFFC00, 0x50),
    (0x2000126C, 0xFFF003FF, 0x14000),
    (0x20001268, 0xC00FFFFF, 0x0F000000),
    (0x24C0C01C, 0xFC00FFFF, 0x10000),
    (0x24C0C020, 0xFC00FFFF, 0x10000),
    (0x24C0C02C, 0xFFFFFF00, 0x1),
)


@pytest.mark.parametrize("mode", ["checked", "firmware"])
def test_modem_late_full_register_sequence(tmp_path: Path, mode: str) -> None:
    rows = ",\n".join(
        f"(0x{address:08X}'u32, 0x{keep:08X}'u32, 0x{value:08X}'u32)"
        for address, keep, value in MODEM_LATE_WRITES
    )
    run_program(tmp_path, mode, modem_late_source() + "\nconst vendor = [\n" + rows + r'''
]
for seed in [0'u32, high(uint32), 0xA5A55A5A'u32, 0x12345678'u32]:
  for item in rfWords.mitems: item = seed
  for item in bbaWords.mitems: item = seed
  for item in phyWords.mitems: item = seed
  for item in auxWords.mitems: item = seed
  selected.setLen(0)
  allWrites.setLen(0)
  var expected: seq[tuple[address, value: uint32]]
  var values: seq[tuple[address, value: uint32]]
  for row in vendor:
    var oldValue = seed
    for item in values:
      if item.address == row[0]:
        oldValue = item.value
        break
    let nextValue = (oldValue and row[1]) or row[2]
    expected.add((row[0], nextValue))
    var found = false
    for item in values.mitems:
      if item.address == row[0]:
        item.value = nextValue
        found = true
        break
    if not found: values.add((row[0], nextValue))
  programRfcModemLateInit()
  doAssert allWrites == expected, "modem-init write sequence differs from archive"
''')
