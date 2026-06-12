## LP (E902) AON-LDO 0.90 V survival probe.
##
## Validates that the 0.90 V HBN AON LDO level is the LP / low-power domain's level.
## The LP lowers the shared AON LDO11 (AON + RT) to 0.90 V and keeps running, bumping
## an XRAM counter. The E907/M0 dies when it does this (it executes from flash XIP and
## browns out); if the LP keeps counting at 0.90 V, that confirms 0.90 V deep-hibernate
## is survivable in the LP domain. The supervising M0 watches the counter over XRAM.

import bl808/startup
import bl808/mmio, bl808/memmap, bl808/core
import bl808/panicoverride

const
  LpCounter = XramBase + 0x3F10'u
  HbnCtl    = 0x2000_F000'u        # HBN_CTL holds the LDO11 VOUT_SEL fields
  Ldo0p90V  = 6'u32                # HBN_LDO_LEVEL_0P90V
  BootMark  = 0xAAAA_0000'u32      # written before the LDO drop (proves boot)
  RunBase   = 0xBBBB_0000'u32      # OR'd with the counter after the drop (proves survival)

proc spin(n: uint32) =
  var d = 0'u32
  while d < n:
    inc d
    fenceIo()

proc main() {.exportc, cdecl.} =
  regWrite(LpCounter, BootMark); dcacheFlushAll(); fenceIo()   # prove boot to M0
  spin(300_000)                                                # let M0 see the boot mark

  # Lower the AON LDO11 (AON [22:19] + RT [18:15]) to 0.90 V.
  var ctl = regRead(HbnCtl)
  ctl = (ctl and not (0xF'u32 shl 19)) or (Ldo0p90V shl 19)
  ctl = (ctl and not (0xF'u32 shl 15)) or (Ldo0p90V shl 15)
  regWrite(HbnCtl, ctl)
  fenceIo()

  # If the LP survived the 0.90 V drop, keep counting.
  var c = 0'u32
  while true:
    inc c
    regWrite(LpCounter, RunBase or (c and 0xFFFF'u32))
    dcacheFlushAll(); fenceIo()
    spin(150_000)
