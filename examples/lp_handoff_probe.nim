## LP side of the verified-core-release test (D, LP variant).
##
## A normal Nim LP firmware: M0 verifies its manifest, releases the E902, and it
## writes a magic to shared XRAM. Relies on the fixed minimal E902 _start
## (startup.nim) that omits the E907-only MXSTATUS/CLIC CSRs the E902 traps on.

import bl808/startup
import bl808/mmio
import bl808/memmap
import bl808/panicoverride

const
  LpRanAddr  = XramBase + 0x3F08'u
  LpRanMagic = 0x11335577'u32

proc main() {.exportc, cdecl.} =
  while true:
    regWrite(LpRanAddr, LpRanMagic)
