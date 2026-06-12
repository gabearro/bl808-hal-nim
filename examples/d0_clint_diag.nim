## D0 CLINT discovery probe.
##
## The tree disagrees on the D0 private CLINT base (clock.nim/memmap: 0xE4004000;
## d0_timer_minimal: 0xE0100000). Sample every candidate mtime address twice (with
## a fixed spin between) and publish the raw pairs to XRAM for the M0 to print. A
## plausible 1 MHz timer advances by only a few thousand counts over the spin;
## garbage/floating reads jump wildly or stick.
##
## Phase is bumped before AND after each individual read, so a bus-fault hang shows
## exactly which access killed us (odd phase = died during that read).

import bl808/startup
import bl808/mmio, bl808/memmap, bl808/core
import bl808/kernel/alloc
import bl808/panicoverride

const
  Phase   = XramBase + 0x3F18'u
  Slot0   = XramBase + 0x3F20'u   # candidate 0: A, B
  Slot1   = XramBase + 0x3F28'u   # candidate 1: A, B
  Slot2   = XramBase + 0x3F30'u   # candidate 2: A, B
  Ready   = XramBase + 0x3F40'u
  ReadyMagic = 0xD1A6_0000'u32
  # Candidate mtime addresses (64-bit, lo at +0).
  Cand0 = 0xE400_BFF8'u   # HAL kernel / memmap
  Cand1 = 0xE010_7FF8'u   # d0_timer_minimal
  Cand2 = 0xE000_BFF8'u   # M0/LP standard layout (shared clock?)

proc spin(n: uint32) =
  var d = 0'u32
  while d < n: inc d

proc setPhase(v: uint32) =
  regWrite(Phase, v); dcacheFlushAll(); fenceIo()

proc sampleInto(addrMt: uint, slot: uint, basePhase: uint32) =
  setPhase(basePhase + 1)           # about to do read A
  let a = regRead(addrMt)
  setPhase(basePhase + 2)           # read A survived
  spin(400_000)
  let b = regRead(addrMt)
  setPhase(basePhase + 3)           # read B survived
  regWrite(slot, a)
  regWrite(slot + 4, b)
  dcacheFlushAll(); fenceIo()

proc main() {.exportc, cdecl.} =
  systemInit(); heapInit()
  # Zero everything so stale XRAM from prior flashes can't masquerade as results.
  for off in [0x3F20'u, 0x3F24'u, 0x3F28'u, 0x3F2C'u, 0x3F30'u, 0x3F34'u]:
    regWrite(XramBase + off, 0xDEAD_DEAD'u32)
  regWrite(Ready, 0); setPhase(0)
  dcacheFlushAll(); fenceIo()

  # Test the two non-faulting candidates FIRST; 0xE400BFF8 faults D0, so do it
  # last (it aborts the run but we already captured the others).
  sampleInto(Cand1, Slot1, 20)
  sampleInto(Cand2, Slot2, 30)
  sampleInto(Cand0, Slot0, 10)
  setPhase(99)

  regWrite(Ready, ReadyMagic); dcacheFlushAll(); fenceIo()
  while true:
    wfi()
