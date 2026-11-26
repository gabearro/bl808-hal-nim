"""Host checks for flashReadRaw and the flash partition constants.

flash.nim runs unmodified against a register-level model of the SF
controller: a strobed READ command copies bytes from a fake flash array into
the controller's 256-byte buffer.
"""

from pathlib import Path
import shutil
import subprocess

import pytest


HAL = Path(__file__).resolve().parents[1] / "src/bl808"

NIM_FLAGS = ["--skipParentCfg:on", "--skipProjCfg:on", "--skipUserCfg:on", "--hints:off"]


def run_nim(tmp_path, source, *paths, command=("c", "-r")):
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("Nim is required")
    probe = tmp_path / "probe.nim"
    probe.write_text(source)
    subprocess.run(
        [nim, *command, *NIM_FLAGS, *[f"--path:{p}" for p in paths],
         f"--nimcache:{tmp_path / 'cache'}", str(probe)],
        cwd=tmp_path, check=True,
    )


def test_raw_read_returns_flash_bytes_in_page_sized_commands(tmp_path):
    mmio = (HAL / "mmio.nim").read_text()
    assert "from std/volatile import" in mmio
    (tmp_path / "mmio.nim").write_text(mmio.replace("from std/volatile import", "from bus import"))
    shutil.copyfile(HAL / "flash.nim", tmp_path / "flash.nim")
    (tmp_path / "bus.nim").write_text("""
const
  Cfg1 = 0x2000B004'u
  Sahb0 = 0x2000B008'u
  Sahb1 = 0x2000B00C'u
  Buf = 0x2000B600'u
  XipOwner = (1'u32 shl 28) or (1'u32 shl 30)   # IAHB owner, AHB2SIF

type Command* = tuple[address: uint32, count: int]

var
  flashImage*: array[0x2000, uint8]
  commands*: seq[Command]
  cfg1* = XipOwner or (1'u32 shl 29)
  sahb0, sahb1: uint32
  buffer: array[256, uint8]
  bufferValid: bool

proc strobe(control: uint32) =
  doAssert (cfg1 and XipOwner) == 0, "command issued while XIP owns the pads"
  doAssert (control shr 27 and 1) == 1 and (control shr 26 and 1) == 1 and
    (control shr 24 and 1) == 1 and (control shr 23 and 1) == 0, "not an addressed read"
  doAssert sahb1 shr 24 == 0x03, "not a READ command"
  doAssert (control shr 17 and 7) == 2, "address is not three bytes"
  let address = sahb1 and 0x00FF_FFFF'u32
  let count = int(control shr 2 and 0x3FF) + 1
  doAssert count <= buffer.len, "command longer than the controller buffer"
  for i in 0 ..< buffer.len:
    buffer[i] = if i < count: flashImage[address.int + i] else: 0xEE
  bufferValid = true
  commands.add (address, count)

proc volatileLoad*[T](p: ptr T): T =
  let address = cast[uint](p)
  if address == Cfg1: T(cfg1)
  elif address == Sahb0: T(sahb0 and not 1'u32)        # never busy
  elif address >= Buf and address < Buf + 256:
    doAssert bufferValid and (cfg1 and XipOwner) == 0, "buffer read outside a command"
    let i = int(address - Buf)
    T(buffer[i].uint32 or buffer[i + 1].uint32 shl 8 or
      buffer[i + 2].uint32 shl 16 or buffer[i + 3].uint32 shl 24)
  else:
    doAssert false, "unexpected read"
    T(0)

proc volatileStore*[T](p: ptr T, value: T) =
  let address = cast[uint](p)
  let v = uint32(value)
  if address == Cfg1:
    cfg1 = v
    if (v and XipOwner) != 0: bufferValid = false
  elif address == Sahb0:
    if (v and 2) != 0 and (sahb0 and 2) == 0: strobe(v)
    sahb0 = v
  elif address == Sahb1: sahb1 = v
  elif address == 0x2000B010'u: discard
  else: doAssert false, "unexpected write"
""")
    run_nim(tmp_path, """
import flash, bus

for i in 0 ..< flashImage.len:
  flashImage[i] = uint8((i * 7 + i shr 8) and 0xFF)

proc check(offset: uint32, len: int, expectCommands: seq[Command]) =
  var buf = newSeq[uint8](len + 2)
  buf[0] = 0xA5
  buf[len + 1] = 0x5A
  commands.setLen(0)
  if len > 0:
    flashReadRaw(offset, buf.toOpenArray(1, len))
  else:
    var empty: array[0, uint8]
    flashReadRaw(offset, empty)
  doAssert buf[0] == 0xA5 and buf[len + 1] == 0x5A, "wrote outside the buffer"
  for i in 0 ..< len:
    doAssert buf[1 + i] == flashImage[offset.int + i], "byte " & $i & " of " & $len
  doAssert commands == expectCommands, $commands
  # XIP is handed back: interface enabled, owned by the AHB side.
  doAssert (cfg1 and (SfCtrlCfg1IfEn or SfCtrlCfg1OwnerIahb or SfCtrlCfg1Ahb2SifEn)) ==
    (SfCtrlCfg1IfEn or SfCtrlCfg1OwnerIahb or SfCtrlCfg1Ahb2SifEn)

check(0x100, 0, @[])
check(0x100, 1, @[(0x100'u32, 1)])
check(0x1FD, 3, @[(0x1FD'u32, 3)])
check(0x103, 255, @[(0x103'u32, 255)])
check(0x000, 256, @[(0x000'u32, 256)])
check(0x0FF, 257, @[(0x0FF'u32, 256), (0x1FF'u32, 1)])
check(0x777, 700, @[(0x777'u32, 256), (0x877'u32, 256), (0x977'u32, 188)])

# Agrees with the existing single-byte and compare helpers.
doAssert flashReadRawByte(0x1234) == flashImage[0x1234]
doAssert flashRawMatches(0x777, flashImage.toOpenArray(0x777, 0x777 + 699))
""", HAL)


def test_partitions_do_not_overlap_and_filesystem_fits_the_chip(tmp_path):
    # Compile-time only: flashblk needs the LittleFS headers to generate C.
    run_nim(tmp_path, """
import bl808/[memmap, flash_layout]
import bl808/kernel/flashblk

static:
  # What tools/hw_validate.py flashes ends below the application data.
  const HarnessEnd = 0x20_0000'u32       # D0 at 0x10_0000, 1 MB in its linker profile
  doAssert AppDataFlashOffset == 0x68_0000'u32 and AppDataFlashLen == 512 * 1024
  doAssert HarnessEnd <= AppDataFlashOffset
  doAssert AppDataFlashEnd == WasmRepositoryFlashOffset
  doAssert WasmRepositoryFlashEnd == FlashFsFlashOffset
  doAssert appDataRawFlashSpan().base == AppDataFlashOffset.uint
  doAssert appDataRawFlashSpan().len == AppDataFlashLen

  doAssert FlashFsOffset == 0x80_0000'u32
  doAssert FlashFsSize == 8 * 1024 * 1024
  doAssert FlashFsBlockCount == 2048
  doAssert FlashFsOffset + FlashFsBlockCount * FlashFsBlockSize == Ox64FlashSize.uint32
""", HAL.parent, command=("check",))

    harness = (HAL.parents[1] / "tools/hw_validate.py").read_text()
    for constant in ("JTAG_FLASH_D0_OFFSET = 0x100000", "JTAG_FLASH_LP_OFFSET = 0x0C0000",
                     "BL808_FLASH_OFFSET_FW = 0x010000", "BL808_FLASH_FW_MAX_LEN = 0x0F0000"):
        assert constant in harness
