"""Run the BL808 SPI driver and its async front end against a register model."""

from pathlib import Path
import shutil
import subprocess

import pytest


HAL = Path(__file__).resolve().parents[1] / "src/bl808"

# SPI0 as the driver sees it: a 32-entry FIFO each way, level-triggered
# "TX has room" / "RX has data" / "FIFO error" flags, a latched end-of-transfer
# flag, and `shift` to clock bytes out (and their echoes in).
BUS = r'''
import std/tables
export tables

const
  Spi0 = 0x2000_A200'u
  Depth = 32

var
  mem*: Table[uint, uint32]
  writes*: seq[(uint, uint32)]
  txFifo, rxFifo: seq[uint8]
  wire*: seq[uint8]             ## every byte clocked out
  endLatched*, rxOverflow*: bool
  endPerFrame*: bool            ## the end flag is raised after every byte
  busyReads*: int               ## the bus reads busy this many more times
  intEnable, intMask, txTh, rxTh: uint32

proc status(): uint32 =
  if endLatched: result = result or 1
  if uint32(Depth - txFifo.len) > txTh: result = result or 2
  if uint32(rxFifo.len) > rxTh: result = result or 4
  if rxOverflow: result = result or 32

proc spiIrqPending*(): bool = (status() and intEnable and not intMask) != 0
proc spiMasked*(): bool = intMask == 0x3F
proc txQueued*(): int = txFifo.len

proc shift*(count: int) =
  for _ in 0 ..< count:
    if txFifo.len == 0: return
    let b = txFifo[0]
    txFifo.delete(0)
    wire.add b
    if rxFifo.len < Depth: rxFifo.add(not b) else: rxOverflow = true
    if txFifo.len == 0 or endPerFrame: endLatched = true

proc volatileLoad*[T](p: ptr T): T =
  let a = cast[uint](p)
  var v: uint32
  case a
  of Spi0 + 0x04: v = status() or (intMask shl 8) or (intEnable shl 24)
  of Spi0 + 0x08:
    if busyReads > 0:
      dec busyReads
      v = 1
  of Spi0 + 0x84:
    v = uint32(Depth - txFifo.len) or (uint32(rxFifo.len) shl 8) or
        (txTh shl 16) or (rxTh shl 24)
  of Spi0 + 0x8C:
    doAssert rxFifo.len > 0, "read from an empty RX FIFO"
    v = rxFifo[0]
    rxFifo.delete(0)
  else: v = mem.getOrDefault(a)
  T(v)

proc volatileStore*[T](p: ptr T, value: T) =
  let a = cast[uint](p)
  let v = uint32(value)
  writes.add (a, v)
  case a
  of Spi0 + 0x04:
    intMask = (v shr 8) and 0x3F
    intEnable = (v shr 24) and 0x3F
    if ((v shr 16) and 1) != 0: endLatched = false
  of Spi0 + 0x80:
    if (v and 4) != 0: txFifo.setLen(0)
    if (v and 8) != 0:
      rxFifo.setLen(0)
      rxOverflow = false
    mem[a] = v and not 12'u32
  of Spi0 + 0x84:
    txTh = (v shr 16) and 0x1F
    rxTh = (v shr 24) and 0x1F
  of Spi0 + 0x88:
    doAssert txFifo.len < Depth, "write to a full TX FIFO"
    txFifo.add uint8(v and 0xFF)
  else: mem[a] = v
'''

CORE = r'''
var mie*: uint
proc csrReadMie*(): uint = mie
proc csrWriteMie*(v: uint) = mie = v
template withInterruptsDisabled*(body: untyped) = body
'''

IRQ = r'''
type TrapHandler* = proc() {.cdecl.}
const
  IrqM0Spi0* = 43'u32
  IrqD0Spi1* = 23'u32
var handlers*: array[64, TrapHandler]
proc registerTrapHandler*(irq: uint32, handler: TrapHandler) = handlers[irq] = handler
proc irqEnable*(irq: uint32) = discard
proc irqSetLevel*(irq: uint32, level: uint8) = discard
proc irqClearPending*(irq: uint32) = discard
'''

REGISTERS = r'''
import bl808/[spi, memmap, bus]

const
  Glb = 0x2000_0510'u
  Pol = 1'u32 shl SpiSclkPol
  Ph = 1'u32 shl SpiSclkPh

proc config(mode: SpiMode, role = spiMaster, id = spi0): uint32 =
  let s = initSpi(id, SpiConfig(mode: mode, frameSize: frame8bit, role: role,
                                prescaler: 7, deglitch: false))
  mem[s.baseAddr() + SpiConfigReg]

# Every period field, and only the interval field of PRD_1.
mem[Spi0Base + SpiPrd1] = 0xAB00_0000'u32
mem[Glb] = 0x0000_2001'u32
discard config(spiMode0)
doAssert mem[Spi0Base + SpiPrd0] == 0x0707_0707'u32
doAssert mem[Spi0Base + SpiPrd1] == 0xAB00_0007'u32

# The vendor driver's table: the phase bit is set for CPHA=0.
doAssert (config(spiMode0) and (Pol or Ph)) == Ph
doAssert (config(spiMode1) and (Pol or Ph)) == 0
doAssert (config(spiMode2) and (Pol or Ph)) == (Pol or Ph)
doAssert (config(spiMode3) and (Pol or Ph)) == Pol

# The pads follow the role; the other GLB bits are left alone.
doAssert mem[Glb] == 0x0000_3001'u32
discard config(spiMode0, spiSlave)
doAssert mem[Glb] == 0x0000_2001'u32
discard config(spiMode0, spiMaster, spi1)
doAssert mem[Glb] == 0x0800_2001'u32

let s = initSpi(spi0, DefaultSpiConfig)
s.setFifoThresholds(15, 3)
doAssert writes[^1] == (Spi0Base + SpiFifoConfig1, 0x030F_0020'u32)   # counts are read-only

# DMA request enables (spi_reg.h: SPI_DMA_TX_EN bit 0, SPI_DMA_RX_EN bit 1).
mem[Spi0Base + SpiFifoConfig0] = 0
s.enableDmaTx()
doAssert mem[Spi0Base + SpiFifoConfig0] == 0x1
s.enableDmaRx()
doAssert mem[Spi0Base + SpiFifoConfig0] == 0x3
'''

ASYNC = r'''
import bl808/[spi, bus, irq]
import bl808/kernel/[runtime, isrbridge, asyncspi]

isrBridgeInit()
let aspi = initAsyncSpi(spi0, SpiConfig(mode: spiMode0, frameSize: frame8bit,
                                        role: spiMaster, prescaler: 1, deglitch: false))
var isrRuns: int

proc isr() =
  handlers[IrqM0Spi0]()
  inc isrRuns

proc run(fut: CpsFuture[SpiError], perStep = 1): SpiError =
  ## Let the bus and the handler take turns until the transfer is reported.
  isrRuns = 0
  for _ in 0 ..< 2000:
    if spiIrqPending(): isr()
    drainIsrCompletions()
    if fut.finished: break
    shift(perStep)
  doAssert fut.finished, "transfer never completed"
  doAssert spiMasked() and not aspi.active and isrBridgeActiveSlotsCount() == 0
  fut.read()

proc bytes(n: int): seq[uint8] =
  for i in 0 ..< n: result.add uint8(i * 7 + 3)
proc p(s: var seq[uint8]): ptr UncheckedArray[uint8] =
  cast[ptr UncheckedArray[uint8]](addr s[0])

# Full duplex still returns what was clocked in.
block:
  var tx = bytes(40)
  var rx = newSeq[uint8](40)
  wire.setLen(0)
  doAssert run(aspi.transferPtr(p(tx), p(rx), 40)) == spiOk
  doAssert wire == tx
  for i in 0 ..< 40: doAssert rx[i] == not tx[i]

block:
  var rx = newSeq[uint8](5)
  wire.setLen(0)
  doAssert run(aspi.recvPtr(p(rx), 5)) == spiOk
  doAssert wire == @[0xFF'u8, 0xFF, 0xFF, 0xFF, 0xFF] and rx == @[0'u8, 0, 0, 0, 0]

# A send is refilled half a FIFO at a time and ends with the bus.
block:
  var tx = bytes(200)
  wire.setLen(0)
  doAssert run(aspi.sendPtr(p(tx), 200)) == spiOk
  doAssert wire == tx
  doAssert isrRuns <= 200 div 16 + 2, $isrRuns

# The same when the bus raises its end flag after every byte (each one is a
# frame of its own): no interrupt per byte while there is more to queue, only
# for the last FIFO-full once everything is.
block:
  var tx = bytes(200)
  wire.setLen(0)
  endPerFrame = true
  doAssert run(aspi.sendPtr(p(tx), 200)) == spiOk
  endPerFrame = false
  doAssert wire == tx
  doAssert isrRuns <= 200 div 16 + 2 + 32, $isrRuns

# It does not depend on the bytes clocked in: an RX overrun (interrupts held
# off for a while) neither stalls it nor leaves an interrupt asserted.
block:
  var tx = bytes(100)
  wire.setLen(0)
  let fut = aspi.sendPtr(p(tx), 100)
  shift(32)
  rxOverflow = true
  doAssert run(fut, perStep = 5) == spiOk
  doAssert wire == tx and isrRuns < 20

# An end-of-transfer latched before the last byte was queued is not the end.
block:
  var tx = bytes(33)
  wire.setLen(0)
  let fut = aspi.sendPtr(p(tx), 33)
  shift(32)                     # the FIFO ran dry: end latched early
  isr()                         # queues the last byte
  doAssert txQueued() == 1
  endLatched = true             # ...and an end from before it
  isr()
  drainIsrCompletions()
  doAssert not fut.finished and aspi.active
  shift(1)
  busyReads = 3                 # the last byte is still on the wire
  isr()
  doAssert busyReads == 0
  drainIsrCompletions()
  doAssert fut.finished and fut.read() == spiOk and wire == tx

# Nothing to send is done at once.
doAssert aspi.sendPtr(nil, 0).read() == spiOk

# Cancelling the future (what withTimeout does) frees the slot every time:
# more abandoned transfers than there are slots, then one that works.
block:
  var tx = bytes(100)
  for _ in 0 ..< MaxIsrSlots + 8:
    let fut = aspi.sendPtr(p(tx), 100)
    doAssert aspi.active and isrBridgeActiveSlotsCount() == 1
    shift(3)
    cancel(fut)
    doAssert fut.isCancelled and not aspi.active
    doAssert isrBridgeActiveSlotsCount() == 0 and spiMasked() and not spiIrqPending()
    doAssert txQueued() == 0
  let rxFut = aspi.transferPtr(p(tx), p(tx), 100)   # full duplex, no clock
  cancel(rxFut)
  doAssert isrBridgeActiveSlotsCount() == 0
  tx = bytes(100)
  wire.setLen(0)
  doAssert run(aspi.sendPtr(p(tx), 100)) == spiOk
  doAssert wire == tx

# cancel() reports the transfer as cancelled; so does starting the next one.
block:
  var tx = bytes(50)
  let first = aspi.sendPtr(p(tx), 50)
  aspi.cancel()
  doAssert first.read() == spiCancelled and isrBridgeActiveSlotsCount() == 0
  aspi.cancel()                 # nothing running: no effect

  let second = aspi.sendPtr(p(tx), 50)
  wire.setLen(0)
  let third = aspi.sendPtr(p(tx), 50)
  doAssert second.read() == spiCancelled and isrBridgeActiveSlotsCount() == 1
  doAssert run(third) == spiOk and wire == tx

# A transfer the handler already finished is not undone by a late cancel.
block:
  var tx = bytes(4)
  let fut = aspi.sendPtr(p(tx), 4)
  shift(4)
  isr()
  aspi.cancel()
  drainIsrCompletions()
  doAssert fut.read() == spiOk and isrBridgeActiveSlotsCount() == 0
'''


def build_tree(tmp_path: Path) -> None:
    hal = tmp_path / "bl808"
    (hal / "kernel").mkdir(parents=True)
    mmio = (HAL / "mmio.nim").read_text()
    assert "from std/volatile import" in mmio
    (hal / "mmio.nim").write_text(mmio.replace("from std/volatile import", "from bus import"))
    (hal / "bus.nim").write_text(BUS)
    (hal / "core.nim").write_text(CORE)
    (hal / "irq.nim").write_text(IRQ)
    for name in ("memmap.nim", "spi.nim", "kernel/runtime.nim", "kernel/isrbridge.nim",
                 "kernel/asyncspi.nim"):
        shutil.copyfile(HAL / name, hal / name)


@pytest.mark.parametrize("program", [REGISTERS, ASYNC], ids=["registers", "async"])
def test_spi_driver(tmp_path: Path, program: str) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("Nim is required")
    build_tree(tmp_path)
    probe = tmp_path / "probe.nim"
    probe.write_text(program)
    subprocess.run(
        [nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on", "--skipUserCfg:on",
         "--mm:arc", f"--path:{tmp_path}", f"--nimcache:{tmp_path / 'cache'}", str(probe)],
        cwd=tmp_path, check=True,
    )
