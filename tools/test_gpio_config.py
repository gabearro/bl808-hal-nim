"""Check the BL808 GPIO pin configuration writes against a register log."""

from pathlib import Path
import shutil
import subprocess

import pytest


HAL = Path(__file__).resolve().parents[1] / "src/bl808"

BUS = r'''
import std/tables
export tables

var
  mem*: Table[uint, uint32]
  writes*: seq[(uint, uint32)]

proc volatileLoad*[T](p: ptr T): T = T(mem.getOrDefault(cast[uint](p)))
proc volatileStore*[T](p: ptr T, value: T) =
  mem[cast[uint](p)] = uint32(value)
  writes.add (cast[uint](p), uint32(value))
'''

CHECKS = r'''
import gpio, bus

const
  Pin = 5'u32
  Cfg = 0x2000_08C4'u + 5 * 4          # GLB GPIO_CFG0 + pin * 4
  SetClr = 1'u32 shl 30
  IntClr = 1'u32 shl 20
doAssert gpioCfgAddr(Pin) == Cfg

# An output is put in set/clear mode whatever mode the pin was left in, and
# gpioSet / gpioClear then write the bits that mode acts on.
mem[Cfg] = 0x8000_0001'u32             # mode 2, input enabled
gpioInitOutput(Pin, drive2)
doAssert mem[Cfg] == (SetClr or (11'u32 shl 8) or (1 shl 6) or (2 shl 2) or (1 shl 1))
gpioSet(Pin)
doAssert writes[^1] == (Cfg, mem[Cfg]) and (mem[Cfg] and (1'u32 shl 25)) != 0
mem[Cfg] = mem[Cfg] and not (1'u32 shl 25)   # the hardware bit reads back 0
gpioClear(Pin)
doAssert (writes[^1][1] and (1'u32 shl 26)) != 0

# gpioToggle goes by the output-value bit, which every write keeps in step
# with the level it drives. This register model, like a plain read/write bit,
# does not change it on a set or clear pulse.
proc pulsed(): uint32 =
  ## The set / clear bits of the last write; they read back 0 afterwards.
  result = (writes[^1][1] shr 25) and 3
  mem[Cfg] = mem[Cfg] and not (3'u32 shl 25)
const (High, Low) = (1'u32, 2'u32)
doAssert pulsed() == Low
gpioToggle(Pin); doAssert pulsed() == High
gpioToggle(Pin); doAssert pulsed() == Low
gpioSet(Pin); doAssert pulsed() == High
gpioToggle(Pin); doAssert pulsed() == Low
gpioWrite(Pin, true); doAssert pulsed() == High
gpioWrite(Pin, false); doAssert pulsed() == Low
gpioToggle(Pin); doAssert pulsed() == High
gpioClear(Pin); doAssert pulsed() == Low
# only the level bits change: mode, function, enable and drive stay
doAssert mem[Cfg] == (SetClr or (11'u32 shl 8) or (1 shl 6) or (2 shl 2) or (1 shl 1))

# Display pad functions (bl808_gpio.h: DBI_B 22, DBI_C 23, DPI 24).
doAssert ord(funcDbiB) == 22 and ord(funcDbiC) == 23 and ord(funcDpi) == 24
doAssert ord(funcMmUart) == 21 and ord(funcJtagLp) == 25

# Clearing an interrupt pulses the clear bit and leaves the rest alone.
mem[Cfg] = 0x4001_0B01'u32
writes.setLen(0)
gpioClearInterrupt(Pin)
doAssert writes == @[(Cfg, 0x4001_0B01'u32 or IntClr), (Cfg, 0x4001_0B01'u32)]

# SPI pins: the vendor's alternate-function setup, the same for every signal.
const SpiPin = (1'u32 shl 22) or (1 shl 0) or (1 shl 1) or (1 shl 2) or SetClr
mem[gpioCfgAddr(27)] = 0xFFFF_FFFF'u32
gpioSetupSpiPin(27)
doAssert mem[gpioCfgAddr(27)] == (SpiPin or (1'u32 shl 8))
gpioSetupSpi(sclkPin = 23, mosiPin = 21, misoPin = 22, csPin = 20)
for pin in 20'u32 .. 23'u32:
  doAssert mem[gpioCfgAddr(pin)] == (SpiPin or (1'u32 shl 8))
gpioSetupSpi(sclkPin = 23, mosiPin = 21, misoPin = 22, csPin = 20, isMm = true)
doAssert mem[gpioCfgAddr(20)] == (SpiPin or (18'u32 shl 8))
'''


def test_gpio_pin_configuration(tmp_path: Path) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("Nim is required")
    mmio = (HAL / "mmio.nim").read_text()
    assert "from std/volatile import" in mmio
    (tmp_path / "mmio.nim").write_text(mmio.replace("from std/volatile import", "from bus import"))
    (tmp_path / "bus.nim").write_text(BUS)
    for name in ("memmap.nim", "gpio.nim"):
        shutil.copyfile(HAL / name, tmp_path / name)
    probe = tmp_path / "probe.nim"
    probe.write_text(CHECKS)
    subprocess.run(
        [nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on", "--skipUserCfg:on",
         f"--path:{tmp_path}", f"--nimcache:{tmp_path / 'cache'}", str(probe)],
        cwd=tmp_path, check=True,
    )
