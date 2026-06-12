## LP RAM probe for the verified handoff (D, faithful LP variant).
##
## Built for RAM execution at 0x22050000 (bl808_lp_ram.ld, -d:bl808jtagram). M0
## verifies this image's NSB1 manifest, copies the verified bytes here, and boots
## LP via releaseLPAt(0x22050000). LP then writes a magic to shared XRAM. Minimal
## (no systemInit — M0 already brought clocks up) so the E902 just signals.

import bl808/startup
import bl808/mmio, bl808/memmap
import bl808/panicoverride

const
  LpRanAddr  = XramBase + 0x3F08'u
  LpRanMagic = 0x11335577'u32

proc main() {.exportc, cdecl.} =
  while true:
    regWrite(LpRanAddr, LpRanMagic)
