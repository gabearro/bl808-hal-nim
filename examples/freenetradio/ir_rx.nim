## The IR receiver's edges (the interrupt half of upstream `src/ir.rs`).
## Firmware only.
##
## A VS1838B-type 38 kHz receiver on `board.IrPin`: its output idles high
## and goes low during each IR burst. Timing is measured in the GPIO
## interrupt, not in a task: MP3 decoding holds the scheduler for
## milliseconds at a time, which would wreck sub-millisecond pulse
## measurements. The interrupt timestamps each edge and queues the length of
## the period that just ended; `irPoll` (from the controls task) decodes at
## leisure.

import std/volatile
import bl808/[gpio, irq]
import bl808/kernel/clock
import ./board, ./diag, ./ir_nec

const
  QueueLen = 128
    ## Interrupt -> task. 128 periods is two full frames.
  LowFlag = 0x8000_0000'u32
    ## Set in a queued period when the line was low (a burst) during it.

var
  # Single producer (the interrupt), single consumer (the task): `head` is
  # only written by the interrupt, `tail` only by the task.
  periods: array[QueueLen, uint32]
  head: uint32
  tail: uint32
  lastEdgeUs: uint32
  decoder: NecDecoder

proc irIsr() {.cdecl.} =
  if not gpioInterruptActive(IrPin.uint32):
    return
  gpioClearInterrupt(IrPin.uint32)
  let now = uint32(ticksToUs(readTick()) and 0xFFFF_FFFF'u64)
  let then = lastEdgeUs
  lastEdgeUs = now
  # The pin's level now is the opposite of the period that just ended.
  let highNow = gpioRead(IrPin.uint32)
  let h = head
  if h - volatileLoad(addr tail) < QueueLen:      # full: drop it
    let us = min(now - then, LowFlag - 1)
    periods[h mod QueueLen] = us or (if highNow: LowFlag else: 0)
    volatileStore(addr head, h + 1)

proc irInit*() =
  ## Configure the pin as a pulled-up input and interrupt on both edges.
  head = 0
  tail = 0
  decoder = NecDecoder()
  lastEdgeUs = uint32(ticksToUs(readTick()) and 0xFFFF_FFFF'u64)
  gpioInitInput(IrPin.uint32, pullUp)
  gpioDisableInterrupt(IrPin.uint32)
  registerTrapHandler(IrqM0GpioInt0, irIsr)
  gpioSetInterrupt(IrPin.uint32, intBothEdges)
  gpioClearInterrupt(IrPin.uint32)
  irqClearPending(IrqM0GpioInt0)
  irqSetLevel(IrqM0GpioInt0, 1)
  irqEnable(IrqM0GpioInt0)

proc irPoll*(onPress: proc(press: Press) {.nimcall.}) =
  ## Decode what the interrupt has queued, calling `onPress` for each press
  ## and repeat.
  while tail != volatileLoad(addr head):
    let p = periods[tail mod QueueLen]
    volatileStore(addr tail, tail + 1)
    var press: Press
    case decoder.feed(p and not LowFlag, (p and LowFlag) != 0, press)
    of neNone: discard
    of neError: inc stats.irErrors
    of nePress:
      if not press.repeat:
        inc stats.irFrames
        stats.irLastCode = (press.address.uint32 shl 8) or press.command.uint32
      onPress(press)
