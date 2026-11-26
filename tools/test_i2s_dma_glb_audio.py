"""Register-level checks of the I2S, DMA and GLB audio/SPI helpers.

The HAL modules are built for the host with `mmio`'s volatile accesses
replaced by a fake register file, so every expectation below is a register
value from the vendor headers (i2s_reg.h, dma_reg.h, glb_reg.h, cci_reg.h).
"""

from pathlib import Path
import shutil
import subprocess

import pytest


HAL = Path(__file__).resolve().parents[1] / "src/bl808"

BUS = """
import std/tables
var regs*: Table[uint, uint32]
var writes*: seq[tuple[address: uint, value: uint32]]
var delays*: seq[tuple[at: int, us: uint32]]   # (writes made so far, length)

proc volatileLoad*[T](p: ptr T): T = T(regs.getOrDefault(cast[uint](p)))
proc volatileStore*[T](p: ptr T, value: T) =
  regs[cast[uint](p)] = uint32(value)
  writes.add (cast[uint](p), uint32(value))

proc reg*(address: uint): uint32 = regs.getOrDefault(address)
proc reset*() =
  regs.clear()
  writes.setLen 0
  delays.setLen 0
"""

# glb.nim's other imports are RISC-V only (CSR inline assembly); the procs it
# takes from them are stood in for. `delayUs` records where each delay falls.
CORE = """
import bus
proc fence*() = discard
proc fenceIo*() = discard
proc delayUs*(us: uint32) = delays.add (writes.len, us)
"""

PDS = """
proc pdsConfigureLpMtimerClock*() = discard
"""

PROBE = """
import std/tables
import bus, i2s, dma, glb

const
  I2sReg = 0x2000_AB00'u
  Glb = 0x2000_0000'u
  Cci = 0x2000_8000'u
  Dma0 = 0x2000_C000'u

# ---- I2S: DMA request enables (i2s_reg.h: TX bit 0, RX bit 1) ----
block:
  reset()
  let s = I2s()
  s.enableDmaTx()
  doAssert reg(I2sReg + 0x80) == 0x1
  s.enableDmaRx()
  doAssert reg(I2sReg + 0x80) == 0x3
  s.disableDmaTx()
  doAssert reg(I2sReg + 0x80) == 0x2
  s.disableDmaRx()
  doAssert reg(I2sReg + 0x80) == 0x0

# ---- I2S: BCLK divider ----
block:
  # 24.576 MHz / (64 x 48 kHz) = 8 clocks per BCLK: 4 low, 4 high
  doAssert bclkDividers(24_576_000, 64 * 48_000) == (3'u32, 3'u32)
  doAssert bclkHz(24_576_000, 3, 3) == 64 * 48_000
  # 22.5792 MHz / (64 x 44.1 kHz) = 8
  doAssert bclkDividers(22_579_200, 64 * 44_100) == (3'u32, 3'u32)
  # 24.576 MHz / (64 x 32 kHz) = 12; 16 kHz = 24; 8 kHz = 48
  doAssert bclkDividers(24_576_000, 64 * 32_000) == (5'u32, 5'u32)
  doAssert bclkDividers(24_576_000, 64 * 8_000) == (23'u32, 23'u32)
  # odd division: the extra clock goes to the high time
  doAssert bclkDividers(9, 3) == (0'u32, 1'u32)
  # limits: never less than 2 clocks, never more than both 12-bit fields
  doAssert bclkDividers(1_000, 1_000_000) == (0'u32, 0'u32)
  doAssert bclkDividers(4_000_000_000'u32, 1) == (0xFFF'u32, 0xFFF'u32)
  doAssert bclkDividers(1_000, 0) == (499'u32, 499'u32)

  reset()
  let s = I2s()
  regs[I2sReg + 0x10] = 0xF000_F000'u32            # reserved bits are kept
  s.setBclk(24_576_000, 64 * 48_000)
  doAssert reg(I2sReg + 0x10) == 0xF003_F003'u32
  s.setBclkDiv(0x1234, 0x5678)                  # masked to 12 bits each
  doAssert reg(I2sReg + 0x10) == 0xF678_F234'u32

# ---- I2S: init ----
block:
  reset()
  regs[I2sReg + 0x00] = 0xFFFF_FFFF'u32
  regs[I2sReg + 0x80] = 0x0000_0703'u32            # DMA on, merged, exchanged, 24b LJ
  regs[I2sReg + 0xFC] = 0x0000_00FF'u32
  discard initI2s(format = i2sStandard, dataSize = i2sData16bit, role = i2sMaster,
                  bclkDiv = 3, slotSize = i2sData32bit)
  # master | slot 32 (3 << 12) | data 16 (1 << 14) | mode 0 | offset enable, count 0
  doAssert reg(I2sReg + 0x00) == (1'u32 or (3'u32 shl 12) or (1'u32 shl 14) or (1'u32 shl 25))
  doAssert reg(I2sReg + 0x10) == 0x0003_0003'u32
  # DMA requests and format bits cleared, both FIFO clears written
  doAssert reg(I2sReg + 0x80) == 0x0000_000C'u32
  # inversions and deglitch enable off, deglitch count untouched
  doAssert reg(I2sReg + 0xFC) == 0x0000_0070'u32
  # the block is not enabled before it is configured
  var sawConfig = false
  for w in writes:
    if w.address == I2sReg + 0x10: sawConfig = true
    if w.address == I2sReg + 0x00 and not sawConfig:
      doAssert (w.value and 0xF) == 0, "enabled before BCLK was set"

  # ...and with start = false it is left off
  reset()
  regs[I2sReg + 0x00] = 0x0000_000F'u32
  discard initI2s(format = i2sStandard, slotSize = i2sData32bit, start = false)
  doAssert reg(I2sReg + 0x00) == ((3'u32 shl 12) or (1'u32 shl 14) or (1'u32 shl 25))
  for w in writes:
    if w.address == I2sReg + 0x00: doAssert (w.value and 0xF) == 0

  reset()
  discard initI2s(format = i2sLeftJustified, role = i2sSlave)
  doAssert reg(I2sReg + 0x00) == (2'u32 or (1'u32 shl 12) or (1'u32 shl 14))
  doAssert reg(I2sReg + 0x10) == 0x0008_0008'u32
  reset()
  discard initI2s(format = i2sRightJustified, dataSize = i2sData24bit, slotSize = i2sData32bit)
  doAssert reg(I2sReg + 0x00) == (1'u32 or (3'u32 shl 12) or (2'u32 shl 14) or (1'u32 shl 16))
  reset()
  discard initI2s(format = i2sDspMode)
  doAssert reg(I2sReg + 0x00) == (1'u32 or (1'u32 shl 12) or (1'u32 shl 14) or (2'u32 shl 16))

# ---- I2S: role, FIFO format, thresholds, flags ----
block:
  reset()
  let s = I2s()
  regs[I2sReg + 0x00] = 0x0000_500F'u32
  s.disable()
  doAssert reg(I2sReg + 0x00) == 0x0000_5000'u32
  s.enable(i2sSlave)
  doAssert reg(I2sReg + 0x00) == 0x0000_5002'u32
  s.enable()
  doAssert reg(I2sReg + 0x00) == 0x0000_5001'u32

  regs[I2sReg + 0x80] = 0x0000_0603'u32
  s.setFifoFormat(lrMerge = true)
  doAssert reg(I2sReg + 0x80) == 0x0000_0103'u32
  s.setFifoFormat(lrMerge = false, lrExchange = true, leftJustify24 = true)
  doAssert reg(I2sReg + 0x80) == 0x0000_0603'u32

  regs[I2sReg + 0x84] = 0x0F0F_1F1F'u32
  s.setFifoThresholds(tx = 0, rx = 0)
  doAssert reg(I2sReg + 0x84) == 0x0000_1F1F'u32
  s.setFifoThresholds(tx = 7, rx = 0x1A)
  doAssert reg(I2sReg + 0x84) == 0x0A07_1F1F'u32
  doAssert s.txFifoCount == 0x1F and s.rxFifoCount == 0x1F

  regs[I2sReg + 0x80] = 1'u32 shl 5
  doAssert s.txUnderflow and not s.txOverflow and not s.rxOverflow and not s.rxUnderflow
  regs[I2sReg + 0x80] = (1'u32 shl 4) or (1'u32 shl 6) or (1'u32 shl 7)
  doAssert not s.txUnderflow and s.txOverflow and s.rxOverflow and s.rxUnderflow
  regs[I2sReg + 0x80] = 0x100
  s.clearTxFifo()
  doAssert reg(I2sReg + 0x80) == 0x104
  s.clearRxFifo()
  doAssert reg(I2sReg + 0x80) == 0x10C

# ---- DMA: list item bursts, channel addresses ----
block:
  # default: what buildLli always produced (burst 4 on both sides)
  let old = buildLli(0x1000, 0x2000, 100)
  doAssert old.control == (100'u32 or (1'u32 shl 12) or (1'u32 shl 15) or (2'u32 shl 18) or
                           (2'u32 shl 21) or (1'u32 shl 26) or (1'u32 shl 27))
  let one = buildLli(0x1000, 0x2000, 4095, dstIncr = false, nextLli = 0x3000,
                     srcBurst = burst1, dstBurst = burst1)
  doAssert one.control == (4095'u32 or (2'u32 shl 18) or (2'u32 shl 21) or (1'u32 shl 26))
  doAssert one.srcAddr == 0x1000 and one.dstAddr == 0x2000 and one.nextLli == 0x3000
  let mixed = buildLli(0, 0, 1, srcWidth = width8, dstWidth = width16, srcIncr = false,
                       dstIncr = false, tcInt = true, srcBurst = burst16, dstBurst = burst8)
  doAssert mixed.control == (1'u32 or (3'u32 shl 12) or (2'u32 shl 15) or (1'u32 shl 21) or
                             (1'u32 shl 31))

  reset()
  let d = initDma(dma0)
  regs[Dma0 + 0x100] = 0x5000_0040'u32          # channel 0 source
  regs[Dma0 + 0x104] = 0x2000_AB88'u32
  regs[Dma0 + 0x300] = 0x5000_1000'u32          # channel 2 source
  regs[Dma0 + 0x304] = 0x1234_5678'u32
  let before = writes.len
  doAssert d.channelSrcAddr(0) == 0x5000_0040'u32
  doAssert d.channelDstAddr(0) == 0x2000_AB88'u32
  doAssert d.channelSrcAddr(2) == 0x5000_1000'u32
  doAssert d.channelDstAddr(2) == 0x1234_5678'u32
  doAssert writes.len == before, "reading a channel address must not write"

# ---- GLB: SPI clock, SPI0 pad role ----
block:
  doAssert ord(spiClkPll160m) == 0 and ord(spiClkXclk) == 1
  reset()
  regs[Glb + 0x1B0] = 0x000F_0000'u32           # spi_swap_set is kept
  setSpiClockSource(spiClkXclk)
  doAssert reg(Glb + 0x1B0) == 0x000F_0200'u32
  setSpiClockSource(spiClkPll160m)
  doAssert reg(Glb + 0x1B0) == 0x000F_0000'u32

  regs[Glb + 0x1B0] = 0x000F_031F'u32
  writes.setLen 0
  setSpiClock(true, spiClkXclk, 3)
  doAssert reg(Glb + 0x1B0) == 0x000F_0303'u32
  doAssert (writes[0].value and 0x100) == 0, "clock must be gated while it changes"
  doAssert (writes[^2].value and 0x100) == 0
  setSpiClock(false, spiClkPll160m, 0x3F)       # divider masked to 5 bits
  doAssert reg(Glb + 0x1B0) == 0x000F_001F'u32

  regs[Glb + 0x510] = 0x0000_0904'u32
  setSpi0MasterMode(true)
  doAssert reg(Glb + 0x510) == 0x0000_1904'u32
  swapSpi0MosiMiso(true)
  doAssert reg(Glb + 0x510) == 0x0000_3904'u32
  setSpi0MasterMode(false)
  doAssert reg(Glb + 0x510) == 0x0000_2904'u32
  swapSpi0MosiMiso(false)
  doAssert reg(Glb + 0x510) == 0x0000_0904'u32

# ---- GLB: clock gates ----
block:
  reset()
  enablePeriphClock(periphI2s)
  enablePeriphClock(periphDma)
  doAssert reg(Glb + 0x584) == ((1'u32 shl 27) or (1'u32 shl 12))
  doAssert ord(periphSpi) == 18 and ord(periphUart2) == 26

  # DMA0 (GLB_PER_Clock_UnGate, GLB_Set_DMA_CLK): cgen_m_dma, cgen_s1_dma and
  # its eight channel gates in DMA_CFG0[31:24].
  reset()
  regs[Glb + 0x130] = 0x0000_1234'u32
  enableDma0Clock()
  doAssert reg(Glb + 0x580) == (1'u32 shl 3)
  doAssert reg(Glb + 0x584) == (1'u32 shl 12)
  doAssert reg(Glb + 0x130) == 0xFF00_1234'u32
  doAssert reg(Glb + 0x134) == 0
  # DMA1: the shared gate, and channel gates in DMA_CFG1, not DMA_CFG0.
  reset()
  enableDma1Clock()
  doAssert reg(Glb + 0x580) == (1'u32 shl 3)
  doAssert reg(Glb + 0x134) == 0xFF00_0000'u32
  doAssert reg(Glb + 0x130) == 0 and reg(Glb + 0x584) == 0

# ---- GLB: I2S reference clock ----
block:
  reset()
  regs[Glb + 0x190] = 0xFFFF_FFFF'u32
  setI2sRefClock(true)
  doAssert reg(Glb + 0x190) == 0xFFFF_FE80'u32
  setI2sRefClock(true, divider = 0x45, diPinRefOut = true)
  doAssert reg(Glb + 0x190) == 0xFFFF_FEC5'u32
  setI2sRefClock(false, doPinRefOut = true)
  doAssert reg(Glb + 0x190) == 0xFFFF_FF00'u32

# ---- GLB: audio PLL ----
block:
  doAssert audioPllFor(44_100) == auPll451M584
  doAssert audioPllFor(22_050) == auPll451M584 and audioPllFor(11_025) == auPll451M584
  for rate in [8_000'u32, 12_000, 16_000, 24_000, 32_000, 48_000, 96_000]:
    doAssert audioPllFor(rate) == auPll442M368
  # every crystal lands within 20 ppm of the nominal master clock
  for xtal in xtal24m .. xtalRc32m:
    for (vco, nominal) in [(auPll442M368, 24_576_000), (auPll451M584, 22_579_200)]:
      let hz = audioPllHz(vco, xtal).int
      doAssert abs(hz - nominal) * 1_000_000 div nominal <= 20, $xtal & " " & $vco & " " & $hz
  doAssert audioPllHz(auPll442M368, xtalNone) == 0
  # 40 MHz: 10 MHz x 0x161E5 / 2048 / 18, 10 MHz x 0x16944 / 2048 / 20
  doAssert audioPllHz(auPll442M368) == 24_576_009
  doAssert audioPllHz(auPll451M584) == 22_579_101
  # and the I2S dividers from that give the sample rate to the hertz
  let d = bclkDividers(audioPllHz(auPll451M584), 64 * 44_100)
  doAssert d == (3'u32, 3'u32)

  reset()
  doAssert not configAudioPll(auPll451M584, xtalNone)
  doAssert writes.len == 0

  for (vco, sdmin, postDiv) in [(auPll451M584, 0x16944'u32, 0x14'u32),
                                (auPll442M368, 0x161E5'u32, 0x12'u32)]:
    reset()
    # every field starts wrong, and the other bits start set
    for off in [0x750'u, 0x754, 0x758, 0x75C, 0x760, 0x764, 0x768]:
      regs[Cci + off] = 0xFFFF_FFFF'u32
    doAssert configAudioPll(vco)
    # cfg0: powered, resets released; untouched bits kept
    doAssert reg(Cci + 0x750) == 0xFFFF_FFFF'u32
    # cfg1: refclk = crystal (0), refdiv 4, post divider
    doAssert reg(Cci + 0x754) == (0xFFFC_F080'u32 or 0x0400'u32 or postDiv)
    # cfg2: int_frac_sw 1, icp_1u 1, icp_5u 0
    doAssert reg(Cci + 0x758) == 0xFFFF_FF4F'u32
    # cfg3: rz 5, cz 2, c3 2, r4_short 0, c4_en 1
    doAssert reg(Cci + 0x75C) == 0xFFFD_AEFF'u32
    doAssert reg(Cci + 0x760) == 0xFFFF_FFFD'u32      # sel_sample_clk 1
    doAssert reg(Cci + 0x764) == 0xFFFF_FFFB'u32      # vco_speed 3
    doAssert reg(Cci + 0x768) == (0xFEF8_0000'u32 or sdmin)   # sdm_bypass 0
    doAssert reg(Cci + 0x770) == 0x67                 # div1, 2, 2.5, 5, 6

    # Order (GLB_Power_On_WAC_PLL): power down, parameters, regulator, PLL,
    # SDM reset pulse, FBDV reset pulse, post divider, outputs.
    var cfg0: seq[uint32]
    var firstParam, lastParam, postDivAt, outputsAt = -1
    var cfg0At: seq[int]
    for i, w in writes:
      if w.address == Cci + 0x750:
        cfg0.add w.value and 0x605
        cfg0At.add i
      elif w.address == Cci + 0x770: outputsAt = i
      elif w.address == Cci + 0x754 and (w.value and 0x7F) == postDiv and lastParam >= 0 and
           cfg0.len > 2: postDivAt = i
      elif w.address >= Cci + 0x754 and w.address <= Cci + 0x768:
        if firstParam < 0: firstParam = i
        lastParam = i
    doAssert cfg0 == @[0x205'u32, 0x005,                 # pu off, sfreg off
                       0x205, 0x605,                     # sfreg on, pu on
                       0x605, 0x604, 0x605,              # SDM reset pulse
                       0x605, 0x601, 0x605], $cfg0       # FBDV reset pulse
    doAssert cfg0At[1] < firstParam and lastParam < cfg0At[2]
    doAssert cfg0At[^1] < postDivAt and postDivAt < outputsAt
    # a delay after the regulator, after power-up, inside and after each
    # reset's low pulse, and a last one once the outputs are on
    var delayAt: seq[int]
    for d in delays:
      doAssert d.us >= 20
      delayAt.add d.at - 1                       # index of the write before it
    doAssert delayAt == @[cfg0At[2], cfg0At[3], cfg0At[4], cfg0At[5],
                          cfg0At[7], cfg0At[8], outputsAt], $delayAt
    doAssert delays[^1].us >= 450

  # 24 MHz crystal: reference divider 2; RC32M: reference select 3
  reset()
  doAssert configAudioPll(auPll442M368, xtal24m)
  doAssert reg(Cci + 0x754) == 0x0000_0212'u32
  doAssert reg(Cci + 0x768) == 0x126E9
  reset()
  doAssert configAudioPll(auPll451M584, xtalRc32m)
  doAssert reg(Cci + 0x754) == 0x0003_0414'u32
  doAssert reg(Cci + 0x768) == 0x1C395

"""


def test_i2s_dma_glb_registers(tmp_path):
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("Nim is required")

    # Replace only the volatile loads/stores; the HAL modules are the real
    # ones, copied so that their imports resolve next to them.
    mmio = (HAL / "mmio.nim").read_text()
    assert "from std/volatile import" in mmio
    (tmp_path / "mmio.nim").write_text(mmio.replace("from std/volatile import", "from bus import"))
    for module in ("memmap.nim", "i2s.nim", "dma.nim", "glb.nim"):
        shutil.copyfile(HAL / module, tmp_path / module)
    (tmp_path / "bus.nim").write_text(BUS)
    (tmp_path / "core.nim").write_text(CORE)
    (tmp_path / "pds.nim").write_text(PDS)
    (tmp_path / "probe.nim").write_text(PROBE)
    subprocess.run(
        [nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on", "--skipUserCfg:on",
         "--hints:off", f"--nimcache:{tmp_path / 'cache'}",
         f"--out:{tmp_path / 'probe'}", str(tmp_path / "probe.nim")],
        cwd=tmp_path, check=True,
    )
