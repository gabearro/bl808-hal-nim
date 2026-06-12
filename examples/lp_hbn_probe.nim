## LP (E902) 0.90 V deep hibernate.
##
## The LP executes from RAM (no flash XIP), so it doesn't get its fetch path pulled out
## from under it like the M0 does. It sets up RC32K + arms the HBN RTC at the boot
## voltage, then drops the AON LDO11 (AON + RT) to 0.90 V AND sets HBN_MODE in a SINGLE
## register write -- so the HBN power-down sequence starts the instant the rail drops and
## the LP never has to execute an instruction at 0.90 V. The whole chip powers down; the
## RTC POR-wakes it and the M0 cold-boots. lp status is mirrored to XRAM for the M0.

import bl808/startup
import bl808/mmio, bl808/memmap, bl808/core
import bl808/panicoverride

const
  LpStatus   = XramBase + 0x3F10'u
  HbnBase    = 0x2000_F000'u
  HbnCtl     = HbnBase + 0x00'u
  HbnTimL    = HbnBase + 0x04'u
  HbnTimH    = HbnBase + 0x08'u
  HbnRtcTimL = HbnBase + 0x0C'u
  HbnRtcTimH = HbnBase + 0x10'u
  HbnIrqClr  = HbnBase + 0x1C'u
  HbnGlb     = HbnBase + 0x30'u
  HbnRsv0    = HbnBase + 0x100'u
  HbnRsv1    = HbnBase + 0x104'u
  HbnRc32k0  = HbnBase + 0x200'u
  PuRc32k    = 1'u32 shl 21
  F32kSelMask = 0x3'u32 shl 3
  HbnModeBit = 1'u32 shl 7
  RtcEnBit   = 1'u32 shl 0
  Ldo0p90    = 6'u32
  SleepSec   = 8'u64
  Rc32kHz    = 32768'u64

proc rdRtc(): uint64 =
  regSet(HbnRtcTimH, 1'u32 shl 31)        # latch
  regClear(HbnRtcTimH, 1'u32 shl 31)
  fenceIo()
  let lo = regRead(HbnRtcTimL)
  let hi = regRead(HbnRtcTimH) and 0xFF'u32
  (hi.uint64 shl 32) or lo.uint64

proc main() {.exportc, cdecl.} =
  regWrite(LpStatus, 0xC0DE_0001'u32); dcacheFlushAll(); fenceIo()   # LP booted

  # Clean cold boot on wake: RSV0 non-magic + non-zero.
  regWrite(HbnRsv0, 0x5A5A_0000'u32); regWrite(HbnRsv1, 0x5A5A_0001'u32)
  regWrite(HbnIrqClr, 0xFFFF_FFFF'u32); regWrite(HbnIrqClr, 0); fenceIo()

  # RC32K (RTC clock) on + select.
  regSet(HbnRc32k0, PuRc32k); fenceIo(); delayUs(900)
  regModify(HbnGlb, F32kSelMask, 0); fenceIo()

  # Arm the RTC comparator = now + SleepSec (the wake).
  regClear(HbnCtl, RtcEnBit)
  let comp = rdRtc() + SleepSec * Rc32kHz
  regWrite(HbnTimL, (comp and 0xFFFF_FFFF'u64).uint32)
  regWrite(HbnTimH, ((comp shr 32) and 0xFF'u64).uint32)
  var ctl = regRead(HbnCtl)
  ctl = ctl or (1'u32 shl 4)              # HBN_RTC_INT_DELAY_0T
  ctl = ctl or (0x01'u32 shl 1)           # HBN_RTC_COMP_BIT0_39
  regWrite(HbnCtl, ctl)
  regSet(HbnCtl, RtcEnBit)
  fenceIo()
  regWrite(LpStatus, 0xC0DE_0002'u32); dcacheFlushAll(); fenceIo()   # RTC armed

  # SINGLE write: AON LDO11 (AON [22:19] + RT [18:15]) = 0.90 V, AND HBN_MODE, together.
  var c = regRead(HbnCtl)
  c = (c and not (0xF'u32 shl 19)) or (Ldo0p90 shl 19)
  c = (c and not (0xF'u32 shl 15)) or (Ldo0p90 shl 15)
  c = c or HbnModeBit
  regWrite(HbnCtl, c)
  while true:
    discard
