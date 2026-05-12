## Retained boot health record for reset/fault recovery.
##
## Stored in HBN retention RAM so the next boot can inspect the previous
## boot's health without depending on heap, logging, or initialized drivers.

import ../memmap
import ../mmio
import ./fault

const
  BootHealthMagic* = 0x424F_4F54'u32 ## "BOOT"
  BootHealthVersion* = 1'u32
  BootHealthRecordBytes* = 80'u32

  BootHealthAddr* = HbnRamBase + 0x0C00'u
    ## Retained boot-health record. The clock config block starts at 0x0E00.

  BootCauseUnknown* = 0'u32

  BootHealthFlagPreviousFault* = 1'u32 shl 0

type
  BootHealthRecord* = object
    magic*: uint32
    version*: uint32
    recordBytes*: uint32
    checksum*: uint32
    bootCount*: uint32
    core*: uint32
    bootCause*: uint32
    flags*: uint32
    previousFaultCore*: uint32
    previousFaultReason*: uint32
    previousFaultCauseLo*, previousFaultCauseHi*: uint32
    previousFaultEpcLo*, previousFaultEpcHi*: uint32
    previousFaultTvalLo*, previousFaultTvalHi*: uint32
    previousFaultSpLo*, previousFaultSpHi*: uint32
    previousFaultFlags*: uint32

proc currentCoreCode(): uint32 {.inline.} =
  when defined(bl808m0):
    0'u32
  elif defined(bl808d0):
    1'u32
  elif defined(bl808lp):
    2'u32
  else:
    0xFFFF_FFFF'u32

proc recordWrite(offset: uint, value: uint32) {.inline.} =
  regWrite(BootHealthAddr + offset, value)

proc recordRead(offset: uint): uint32 {.inline.} =
  regRead(BootHealthAddr + offset)

proc checksumWord(offset: uint): uint32 {.inline.} =
  if offset == 12'u: 0'u32 else: recordRead(offset)

proc bootHealthChecksum(): uint32 =
  ## A small integrity check for cold/random retention RAM contents.
  result = 0xB007_C0DE'u32
  for off in countup(0'u, (BootHealthRecordBytes - 4).uint, 4'u):
    result = result xor checksumWord(off)
    result = (result shl 5) or (result shr 27)

proc bootHealthRecordValid*(): bool =
  recordRead(0) == BootHealthMagic and
    recordRead(4) == BootHealthVersion and
    recordRead(8) == BootHealthRecordBytes and
    recordRead(12) == bootHealthChecksum()

proc bootHealthSnapshot*(): BootHealthRecord =
  ## Read the retained boot-health record.
  BootHealthRecord(
    magic: recordRead(0),
    version: recordRead(4),
    recordBytes: recordRead(8),
    checksum: recordRead(12),
    bootCount: recordRead(16),
    core: recordRead(20),
    bootCause: recordRead(24),
    flags: recordRead(28),
    previousFaultCore: recordRead(32),
    previousFaultReason: recordRead(36),
    previousFaultCauseLo: recordRead(40),
    previousFaultCauseHi: recordRead(44),
    previousFaultEpcLo: recordRead(48),
    previousFaultEpcHi: recordRead(52),
    previousFaultTvalLo: recordRead(56),
    previousFaultTvalHi: recordRead(60),
    previousFaultSpLo: recordRead(64),
    previousFaultSpHi: recordRead(68),
    previousFaultFlags: recordRead(72),
  )

proc bootHealthCommit() =
  recordWrite(12, 0)
  recordWrite(12, bootHealthChecksum())

proc bootHealthClearPreviousFault() =
  recordWrite(28, recordRead(28) and not BootHealthFlagPreviousFault)
  for off in countup(32'u, 72'u, 4'u):
    recordWrite(off, 0)

proc bootHealthCaptureFaultSnapshot*() =
  ## Capture the current fault record into the retained boot-health record.
  if faultRecordValid():
    let rec = faultRecordSnapshot()
    recordWrite(28, recordRead(28) or BootHealthFlagPreviousFault)
    recordWrite(32, rec.core)
    recordWrite(36, rec.reason)
    recordWrite(40, rec.causeLo)
    recordWrite(44, rec.causeHi)
    recordWrite(48, rec.epcLo)
    recordWrite(52, rec.epcHi)
    recordWrite(56, rec.tvalLo)
    recordWrite(60, rec.tvalHi)
    recordWrite(64, rec.spLo)
    recordWrite(68, rec.spHi)
    recordWrite(72, rec.flags)
  else:
    bootHealthClearPreviousFault()
  bootHealthCommit()

proc bootHealthInit*() =
  ## Initialize/update the retained boot record for the current boot.
  let previousBootCount =
    if bootHealthRecordValid(): recordRead(16) else: 0'u32

  recordWrite(0, BootHealthMagic)
  recordWrite(4, BootHealthVersion)
  recordWrite(8, BootHealthRecordBytes)
  recordWrite(12, 0)
  recordWrite(16, previousBootCount + 1'u32)
  recordWrite(20, currentCoreCode())
  recordWrite(24, BootCauseUnknown)
  recordWrite(28, 0)
  for off in countup(32'u, 76'u, 4'u):
    recordWrite(off, 0)

  bootHealthCaptureFaultSnapshot()

proc bootHealthClear*() =
  ## Clear the retained boot-health record. Intended for tests/debug shell use.
  for off in countup(0'u, (BootHealthRecordBytes - 4).uint, 4'u):
    recordWrite(off, 0)
