"""MMIO contracts of the BL808 and legacy pre-calibration RF profiles."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import procedure
from test_wifi_message_allocation import run_program
from test_wifi_rf_power_replay import RF, object_type


def fixed_io_source() -> str:
    source = RF.read_text()
    code = "".join(object_type(source, name) for name in (
        "RfRegBlock", "RfPllBlock", "RfDfeInitBlock",
    ))
    code += """
var
  rf: RfRegBlock
  pll: RfPllBlock
  dfe: RfDfeInitBlock
  accesses: seq[tuple[reg: ptr uint32, write: bool]]
  writeValues: seq[uint32]
proc rfRegs(): ptr RfRegBlock = addr rf
proc rfPllRegs(): ptr RfPllBlock = addr pll
proc rfDfeInitRegs(): ptr RfDfeInitBlock = addr dfe
proc volatileLoad(reg: ptr uint32): uint32 =
  accesses.add((reg, false))
  reg[]
proc volatileStore(reg: ptr uint32, value: uint32) =
  accesses.add((reg, true))
  writeValues.add(value)
  reg[] = value
proc updateReg32(reg: ptr uint32, keep, bits: uint32) =
  volatileStore(reg, (volatileLoad(reg) and keep) or bits)
"""
    return code


@pytest.mark.parametrize("mode", ["checked", "firmware"])
def test_fixed_default_transactions(tmp_path: Path, mode: str) -> None:
    source = RF.read_text()
    code = fixed_io_source()
    code += procedure(source, "writeRfPriFixedCommonPreBranch")
    code += procedure(source, "writeRfPriFixedCommonPostBranch")
    run_program(tmp_path, mode, code + """
rf.synthDfePathControl63c = high(uint32)
writeRfPriFixedCommonPreBranch()
# +0x46 is a single store of zero, not a read-modify-write.
doAssert (addr rf.synthDfePathControl63c, false) notin accesses
doAssert (addr rf.synthDfePathControl63c, true) in accesses
doAssert rf.synthDfePathControl63c == 0

for seed in [0'u32, high(uint32), 0x0C00C088'u32, 0xC00C0088'u32]:
  accesses.setLen(0)
  rf.txcalGain68 = seed
  writeRfPriFixedCommonPostBranch()
  # +0x134..+0x13c: write, read back the same register, then read RF[B0].
  let i = accesses.find((addr dfe.dfeRfFixedDefault884, true))
  doAssert i >= 0
  doAssert accesses[i + 1] == (addr dfe.dfeRfFixedDefault884, false)
  doAssert accesses[i + 2] == (addr rf.channelCalStrobeB0, false)
  # +0x224..+0x24c: lui 0xc00c; addi 0x88, then AND before OR.
  doAssert rf.txcalGain68 == ((seed and 0x0C00C088'u32) or 0xE17E0244'u32)
""")


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_bl808_cold_defaults_match_mmio_trace(tmp_path: Path, mode: str) -> None:
    code = fixed_io_source() + procedure(RF.read_text(), "prepareBl808RfColdRegisters")
    run_program(tmp_path, mode, code + r'''
for seed in [0'u32, high(uint32), 0xAAAAAAAA'u32, 0x55555555'u32]:
  for vector in 0 ..< 64:
    var rng = seed xor vector.uint32
    template seedBank(bank: untyped) =
      let words = cast[ptr UncheckedArray[uint32]](addr bank)
      for i in 0 ..< sizeof(bank) div sizeof(uint32):
        words[i] = rng
        if vector != 0:
          rng = rng * 1664525'u32 + 1013904223'u32
    seedBank(rf)
    seedBank(pll)
    seedBank(dfe)
    var expectedRf = rf
    var expectedPll = pll
    var expectedDfe = dfe
    var expectedAccesses: typeof(accesses)
    var expectedValues: seq[uint32]
    template put(bank, expected: untyped; offset: int;
                 keep, bits: uint32; readBefore = true) =
      let i = offset div sizeof(uint32)
      let word = addr cast[ptr UncheckedArray[uint32]](addr bank)[i]
      let expectWord = addr cast[ptr UncheckedArray[uint32]](addr expected)[i]
      if readBefore: expectedAccesses.add((word, false))
      expectWord[] = (expectWord[] and keep) or bits
      expectedAccesses.add((word, true))
      expectedValues.add(expectWord[])
    # BL808 demo rf_pri.o:rf_pri_init+0x0a..0x36, GLB PLL output gates.
    put(pll, expectedPll, 0x30, 0xFFFFF9FF'u32, 0x1FC)
    put(pll, expectedPll, 0x30, 0xFFFFFFFF'u32, 2)
    put(pll, expectedPll, 0x30, 0xFFFFFFFF'u32, 1)
    # +0x14e..0x29a. Omit the preceding printf-only reads.
    put(rf, expectedRf, 0x220, 0xFFFFE67D'u32, 0)
    put(rf, expectedRf, 0x220, 0xFFFFFF9E'u32, 0)
    put(dfe, expectedDfe, 0x820, 0xFF0FFFFF'u32, 0x300000)
    put(dfe, expectedDfe, 0x030, 0xF0FFFFFF'u32, 0x8000000)
    put(rf, expectedRf, 0x030, 0xFFFFFFFF'u32, 0x1003)
    put(dfe, expectedDfe, 0x884, 0xF000FFFF'u32, 0x082000F4)
    put(rf, expectedRf, 0x0CC, 0xFFFFFFFF'u32, 0x10000000)
    put(rf, expectedRf, 0x63C, 0, 0, false)
    put(rf, expectedRf, 0x064, 0xFFFE0008'u32, 0x4C2C)
    put(rf, expectedRf, 0x128, 0xFF800800'u32, 0x4C2491)
    put(rf, expectedRf, 0x12C, 0xFF800800'u32, 0x4C24C2)
    put(rf, expectedRf, 0x130, 0xFF800FFF'u32, 0x491000)
    put(rf, expectedRf, 0x0D4, 0xFFF0F00F'u32, 0xF013C1)
    put(rf, expectedRf, 0x090, 0xFFFFFFFF'u32, 0x10000)
    put(rf, expectedRf, 0x0B8, 0xFFFFFFFF'u32, 0x10)
    put(rf, expectedRf, 0x138, 0xFFFFFFFF'u32, 3)
    put(rf, expectedRf, 0x130, 0xFFFFFE92'u32, 0x92)
    put(rf, expectedRf, 0x08C, 0xFFFFFFF8'u32, 2)
    put(rf, expectedRf, 0x618, 0x3FFFFFFF'u32, 0)
    put(rf, expectedRf, 0x220, 0xFFFFFFEF'u32, 0)
    accesses.setLen(0)
    writeValues.setLen(0)
    prepareBl808RfColdRegisters()
    doAssert accesses == expectedAccesses and writeValues == expectedValues
    doAssert rf == expectedRf and pll == expectedPll and dfe == expectedDfe
''')
