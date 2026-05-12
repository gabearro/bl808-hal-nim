## D0-side MM power-cycle regression image.
##
## Writes a boot counter and a heartbeat into shared XRAM so M0 can observe
## whether the MM subsystem really powers down and restarts this core.
##
## Build:
##   nim c -d:bl808d0 examples/d0_mm_power_cycle_test.nim

import bl808/startup
import bl808/core
import bl808/mmio, bl808/memmap

const
  SharedBootCount = XramBase + 0x3FE0'u
  SharedHeartbeat = XramBase + 0x3FE4'u

proc main() {.exportc, cdecl.} =
  systemInit()

  let bootCount = regRead(SharedBootCount) + 1'u32
  regWrite(SharedBootCount, bootCount)
  regWrite(SharedHeartbeat, 0'u32)

  var heartbeat = 0'u32
  while true:
    heartbeat += 1
    regWrite(SharedHeartbeat, heartbeat)
    delayMs(100)
