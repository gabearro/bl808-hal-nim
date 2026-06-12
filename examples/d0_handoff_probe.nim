## D0 side of the verified-core-release test (D).
##
## M0 releases this only after an NSB1 manifest verifies. On release it writes a
## "D0 ran" magic to the shared XRAM slot M0 polls, proving the verified handoff
## actually started the secondary core.

import bl808/startup
import bl808/core, bl808/mmio, bl808/memmap
import bl808/panicoverride

const
  D0RanAddr  = XramBase + 0x3F00'u
  D0RanMagic = 0xD0D0D0D0'u32

proc main() {.exportc, cdecl.} =
  systemInit()
  regWrite(D0RanAddr, D0RanMagic)
  dcacheFlushAll(); fenceIo()
  while true:
    wfi()
