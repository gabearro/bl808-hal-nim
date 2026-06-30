## BL808 Serial Flash (SF) controller driver.
##
## The SF controller at 0x2000B000 manages the SPI NOR flash.
## Flash is memory-mapped via XIP at 0x58000000.
##
## For the Pine64 Ox64, the flash is 128 Mbit (16 MB).
## Flash operations require careful sequencing: disable XIP, perform
## the operation, then re-enable XIP.

import mmio, memmap, flash_layout

when defined(bl808m0) or defined(bl808d0) or defined(bl808lp):
  {.pragma: flashRam, codegenDecl: "$# __attribute__((section(\".ramfunc\"), noinline, used)) $#$#".}
else:
  {.pragma: flashRam, codegenDecl: "$# __attribute__((noinline, used)) $#$#".}

# =============================================================================
# SF controller register offsets
# =============================================================================
const
  SfCtrlCfg*        = SfCtrlBase + 0x00'u   # SF control config
  SfCtrlCfg1*       = SfCtrlBase + 0x04'u   # SF control config 1
  SfCtrlIfSahb0*    = SfCtrlBase + 0x08'u   # SF AHB interface 0
  SfCtrlIfSahb1*    = SfCtrlBase + 0x0C'u   # SF AHB interface 1
  SfCtrlIfSahb2*    = SfCtrlBase + 0x10'u   # SF AHB interface 2
  SfCtrlProtEnRd*   = SfCtrlBase + 0x10'u   # Read protect enable
  SfCtrlProtEn*     = SfCtrlBase + 0x14'u   # Protect enable
  SfCtrlSfPad*      = SfCtrlBase + 0x20'u   # Pad configuration
  SfCtrlAesRegion*  = SfCtrlBase + 0x80'u   # AES region base
  SfCtrlSfId0*      = SfCtrlBase + 0x14C'u  # Flash ID offset 0
  SfCtrlSfId1*      = SfCtrlBase + 0x150'u  # Flash ID offset 1
  SfCtrlIfIoDelay0* = SfCtrlBase + 0x1C0'u  # IO delay 0

  SfCtrlCfg1OwnerIahb* = 1'u32 shl 28
  SfCtrlCfg1IfEn*      = 1'u32 shl 29
  SfCtrlCfg1Ahb2SifEn* = 1'u32 shl 30
  SfCtrlImageOffset0*  = SfCtrlBase + 0x0A0'u # Physical flash offset mapped at FlashXipBase
  SfCtrlImageOffset1*  = SfCtrlBase + 0x0A4'u # Group-1 physical flash offset mapped at FlashXipBase
  SfCtrlImageOffsetMask* = 0x0FFF_FFFF'u32

# =============================================================================
# Flash commands (SPI NOR standard)
# =============================================================================
const
  FlashCmdWriteEn*   = 0x06'u8  # Write enable
  FlashCmdWriteDis*  = 0x04'u8  # Write disable
  FlashCmdReadSr1*   = 0x05'u8  # Read status register 1
  FlashCmdReadSr2*   = 0x35'u8  # Read status register 2
  FlashCmdWriteSr*   = 0x01'u8  # Write status register
  FlashCmdRead*      = 0x03'u8  # Read data
  FlashCmdFastRead*  = 0x0B'u8  # Fast read
  FlashCmdDualRead*  = 0x3B'u8  # Dual output read
  FlashCmdQuadRead*  = 0x6B'u8  # Quad output read
  FlashCmdPageProg*  = 0x02'u8  # Page program
  FlashCmdSectorEr*  = 0x20'u8  # Sector erase (4 KB)
  FlashCmdBlock32Er* = 0x52'u8  # Block erase (32 KB)
  FlashCmdBlock64Er* = 0xD8'u8  # Block erase (64 KB)
  FlashCmdChipErase* = 0xC7'u8  # Chip erase
  FlashCmdReadId*    = 0x9F'u8  # Read JEDEC ID
  FlashCmdReadUid*   = 0x4B'u8  # Read unique ID
  FlashCmdRelPd*     = 0xAB'u8  # Release power-down
  FlashCmdPowerDn*   = 0xB9'u8  # Power down
  FlashCmdEn4b*      = 0xB7'u8  # Enable 4-byte address
  FlashCmdEx4b*      = 0xE9'u8  # Exit 4-byte address
  FlashCmdEnReset*   = 0x66'u8  # Enable reset
  FlashCmdReset*     = 0x99'u8  # Reset

# =============================================================================
# Status register bits
# =============================================================================
const
  FlashSrBusy*       = 0       # Write in progress
  FlashSrWel*        = 1       # Write enable latch

# =============================================================================
# SF IF_SAHB command bits
# =============================================================================
const
  Sahb0Busy*          = 1'u32 shl 0
  Sahb0Trigger*       = 1'u32 shl 1
  Sahb0DataBytesShift* = 2
  Sahb0AddrBytesShift* = 17
  Sahb0CmdBytesShift*  = 20
  Sahb0DataRw*        = 1'u32 shl 23
  Sahb0DataEn*        = 1'u32 shl 24
  Sahb0AddrEn*        = 1'u32 shl 26
  Sahb0CmdEn*         = 1'u32 shl 27

# =============================================================================
# Flash size constants
# =============================================================================
const
  FlashPageSize*     = 256'u32
  FlashSectorSize*   = 4096'u32
  FlashBlock32Size*  = 32'u32 * 1024'u32
  FlashBlock64Size*  = 64'u32 * 1024'u32

# =============================================================================
# Types
# =============================================================================
type
  FlashError* = enum
    flashOk
    flashBusy
    flashTimeout
    flashAlignError
    flashSizeError

  FlashId* = object
    manufacturerId*: uint8
    memoryType*: uint8
    capacity*: uint8

# =============================================================================
# XIP access (read-only, memory-mapped)
# =============================================================================
proc flashXipAddr*(offset: uint32): uint {.inline.} =
  ## Return the current XIP address for a physical flash offset.
  when defined(bl808d0) or defined(bl808lp):
    let mappedOffset = regRead(SfCtrlImageOffset1) and SfCtrlImageOffsetMask
  else:
    let mappedOffset = regRead(SfCtrlImageOffset0) and SfCtrlImageOffsetMask
  flashXipAddrForCore(offset, mappedOffset)

proc flashReadXip*(offset: uint32): uint32 {.inline.} =
  ## Read a 32-bit word from flash via XIP (memory-mapped read).
  regRead(flashXipAddr(offset))

proc flashReadXipByte*(offset: uint32): uint8 {.inline.} =
  ## Read a single byte from flash via XIP.
  let word = flashReadXip(offset and not 3'u32)
  let bytePos = offset and 3
  ((word shr (bytePos * 8)) and 0xFF).uint8

proc flashReadXipBuffer*(offset: uint32, buf: var openArray[uint8]) =
  ## Read a buffer from flash via XIP.
  for i in 0 ..< buf.len:
    buf[i] = flashReadXipByte(offset + i.uint32)

# =============================================================================
# SF controller command interface
# =============================================================================
# The SF controller uses a buffer at SfCtrlBufBase to stage commands and data.
# Commands are issued by configuring the IF_SAHB registers.

proc sfCtrlRestoreXip*() {.flashRam.} =
  var cfg1 = regRead(SfCtrlCfg1)
  cfg1 = cfg1 or SfCtrlCfg1IfEn or SfCtrlCfg1OwnerIahb or SfCtrlCfg1Ahb2SifEn
  regWrite(SfCtrlCfg1, cfg1)

proc sfCtrlMirrorImageOffsetToGroup1*() {.flashRam.} =
  let offset = regRead(SfCtrlImageOffset0) and SfCtrlImageOffsetMask
  regWrite(SfCtrlImageOffset1, offset)

proc sfCtrlSetLpImageOffsetToGroup1*() {.flashRam.} =
  let offset = (LpRuntimeFlashOffset - Ox64LPBootOffset.uint32) and
    SfCtrlImageOffsetMask
  regWrite(SfCtrlImageOffset1, offset)

proc flashIrqSave(): uint {.flashRam.} =
  when defined(bl808m0) or defined(bl808d0) or defined(bl808lp):
    {.emit: "`result` = __csr_read_mstatus(); __csr_clear_mstatus_mie();".}
  else:
    0'u

proc flashIrqRestore(saved: uint) {.flashRam.} =
  when defined(bl808m0) or defined(bl808d0) or defined(bl808lp):
    if (saved and 0x8'u) != 0:
      {.emit: "__csr_set_mstatus_mie();".}
  else:
    discard saved

proc sfCtrlSendCmd(cmd: uint8, flashAddr: uint32 = 0, hasAddr: bool = false,
                   addrLen: uint32 = 3, dataLen: uint32 = 0,
                   dataWrite: bool = false, dummyClocks: uint32 = 0) {.flashRam.} =
  ## Send a command via the SF controller.
  var cmd0 = cmd.uint32 shl 24
  var cmd1 = 0'u32

  if hasAddr:
    let alen = min(addrLen, 4'u32)
    for i in 0 ..< alen.int:
      let shift = ((alen.int - 1 - i) * 8).uint32
      let byteVal = (flashAddr shr shift) and 0xFF'u32
      let streamIndex = 1 + i
      if streamIndex < 4:
        cmd0 = cmd0 or (byteVal shl ((3 - streamIndex) * 8).uint32)
      else:
        cmd1 = cmd1 or (byteVal shl ((7 - streamIndex) * 8).uint32)

  var sahb0 = Sahb0CmdEn
  sahb0 = sahb0 or (0'u32 shl Sahb0CmdBytesShift)  # 1 command byte
  if hasAddr:
    let alen = min(addrLen, 4'u32)
    sahb0 = sahb0 or Sahb0AddrEn
    sahb0 = sahb0 or ((alen - 1'u32) shl Sahb0AddrBytesShift)
  if dataLen > 0:
    sahb0 = sahb0 or Sahb0DataEn
    sahb0 = sahb0 or ((dataLen - 1'u32) shl Sahb0DataBytesShift)
    if dataWrite:
      sahb0 = sahb0 or Sahb0DataRw

  discard regWaitClear(SfCtrlIfSahb0, Sahb0Busy)
  var cfg1 = regRead(SfCtrlCfg1)
  cfg1 = cfg1 and not (SfCtrlCfg1OwnerIahb or SfCtrlCfg1Ahb2SifEn)
  cfg1 = cfg1 or SfCtrlCfg1IfEn
  regWrite(SfCtrlCfg1, cfg1)
  regWrite(SfCtrlIfSahb0, regRead(SfCtrlIfSahb0) and not Sahb0Trigger)
  regWrite(SfCtrlIfSahb1, cmd0)
  regWrite(SfCtrlIfSahb2, cmd1)
  regWrite(SfCtrlIfSahb0, sahb0)
  regWrite(SfCtrlIfSahb0, sahb0 or Sahb0Trigger)
  discard regWaitClear(SfCtrlIfSahb0, Sahb0Busy or Sahb0Trigger)

proc sfCtrlWaitBusy(timeout: uint32 = 1_000_000): FlashError {.flashRam.} =
  var countdown = timeout
  while countdown > 0:
    sfCtrlSendCmd(FlashCmdReadSr1, dataLen = 1)
    let sr = regRead(SfCtrlBufBase) and 0xFF
    if (sr and (1'u32 shl FlashSrBusy)) == 0:
      return flashOk
    countdown.dec
  flashTimeout

# =============================================================================
# Flash operations
# =============================================================================
proc flashWriteEnable*(): FlashError {.flashRam.} =
  ## Send write enable command (WREN).
  sfCtrlSendCmd(FlashCmdWriteEn)
  sfCtrlRestoreXip()
  flashOk

proc flashWaitReady*(timeout: uint32 = 5_000_000): FlashError {.flashRam.} =
  ## Wait for flash to become ready (not busy).
  sfCtrlWaitBusy(timeout)

proc flashReadId*(): FlashId {.flashRam.} =
  ## Read the JEDEC flash ID (manufacturer, memory type, capacity).
  let irqState = flashIrqSave()
  sfCtrlSendCmd(FlashCmdReadId, dataLen = 3)
  let id0 = regRead(SfCtrlBufBase)
  result.manufacturerId = ((id0 shr 0) and 0xFF).uint8
  result.memoryType = ((id0 shr 8) and 0xFF).uint8
  result.capacity = ((id0 shr 16) and 0xFF).uint8
  sfCtrlRestoreXip()
  flashIrqRestore(irqState)

proc flashReadRawByte*(offset: uint32): uint8 {.flashRam.} =
  ## Read a byte by issuing a raw SPI READ command, bypassing XIP remapping.
  let irqState = flashIrqSave()
  sfCtrlSendCmd(FlashCmdRead, offset, hasAddr = true, dataLen = 1)
  result = (regRead(SfCtrlBufBase) and 0xFF).uint8
  sfCtrlRestoreXip()
  flashIrqRestore(irqState)

proc flashRawMatches*(offset: uint32, data: openArray[uint8]): bool {.flashRam.} =
  ## Compare flash contents by issuing raw SPI READ commands, bypassing XIP remap.
  let irqState = flashIrqSave()
  result = true
  var base = 0
  while base < data.len:
    var n = data.len - base
    if n > FlashPageSize.int:
      n = FlashPageSize.int
    var expected: array[FlashPageSize.int, uint8]
    for i in 0 ..< n:
      expected[i] = data[base + i]
    sfCtrlSendCmd(FlashCmdRead, offset + base.uint32, hasAddr = true, dataLen = n.uint32)
    sfCtrlRestoreXip()
    for i in 0 ..< n:
      let word = regRead(SfCtrlBufBase + ((i and not 3).uint))
      let got = ((word shr ((i and 3) * 8)) and 0xFF).uint8
      if got != expected[i]:
        result = false
        break
    if not result:
      break
    base += n
  flashIrqRestore(irqState)

proc flashEraseSector*(address: uint32): FlashError {.flashRam.} =
  ## Erase a 4 KB sector. Address must be sector-aligned.
  if (address and (FlashSectorSize - 1)) != 0:
    return flashAlignError

  let irqState = flashIrqSave()
  result = flashWriteEnable()
  if result != flashOk:
    flashIrqRestore(irqState)
    return

  sfCtrlSendCmd(FlashCmdSectorEr, address, hasAddr = true)
  result = flashWaitReady(5_000_000)
  sfCtrlRestoreXip()
  flashIrqRestore(irqState)

proc flashEraseBlock64*(address: uint32): FlashError {.flashRam.} =
  ## Erase a 64 KB block. Address must be block-aligned.
  if (address and (FlashBlock64Size - 1)) != 0:
    return flashAlignError

  let irqState = flashIrqSave()
  result = flashWriteEnable()
  if result != flashOk:
    flashIrqRestore(irqState)
    return

  sfCtrlSendCmd(FlashCmdBlock64Er, address, hasAddr = true)
  result = flashWaitReady(10_000_000)
  sfCtrlRestoreXip()
  flashIrqRestore(irqState)

proc flashProgramRaw(address: uint32, data: openArray[uint8]): FlashError {.flashRam.} =
  ## Program up to 256 bytes starting at any address within a page.
  ## The caller must ensure data does not cross a page boundary.
  if data.len == 0: return flashOk
  if data.len > FlashPageSize.int: return flashSizeError

  let irqState = flashIrqSave()
  result = flashWriteEnable()
  if result != flashOk:
    flashIrqRestore(irqState)
    return

  # Load data into SF buffer
  var bufOffset = 0'u
  var i = 0
  while i + 3 < data.len:
    let word = data[i].uint32 or
               (data[i+1].uint32 shl 8) or
               (data[i+2].uint32 shl 16) or
               (data[i+3].uint32 shl 24)
    regWrite(SfCtrlBufBase + bufOffset, word)
    bufOffset += 4
    i += 4

  if i < data.len:
    var word = 0'u32
    for j in 0 ..< data.len - i:
      word = word or (data[i+j].uint32 shl (j * 8))
    regWrite(SfCtrlBufBase + bufOffset, word)

  sfCtrlSendCmd(FlashCmdPageProg, address, hasAddr = true,
                dataLen = data.len.uint32, dataWrite = true)
  result = flashWaitReady()
  sfCtrlRestoreXip()
  flashIrqRestore(irqState)

proc flashProgramPage*(address: uint32, data: openArray[uint8]): FlashError {.flashRam.} =
  ## Program up to 256 bytes at a page-aligned address.
  if (address and (FlashPageSize - 1)) != 0: return flashAlignError
  flashProgramRaw(address, data)

proc flashWrite*(address: uint32, data: openArray[uint8]): FlashError {.flashRam.} =
  ## Write arbitrary data to flash at any address. Handles page boundary crossing.
  var offset = 0
  var writeAddr = address
  var chunk: array[FlashPageSize.int, uint8]

  while offset < data.len:
    # Calculate bytes remaining in current page
    let pageOffset = writeAddr and (FlashPageSize - 1)
    let pageRemain = (FlashPageSize - pageOffset).int
    let chunkLen = min(pageRemain, data.len - offset)
    for i in 0 ..< chunkLen:
      chunk[i] = data[offset + i]

    result = flashProgramRaw(writeAddr, chunk.toOpenArray(0, chunkLen - 1))
    if result != flashOk: return

    offset += chunkLen
    writeAddr += chunkLen.uint32

proc flashReset*() =
  ## Issue a software reset to the flash chip.
  sfCtrlSendCmd(FlashCmdEnReset)
  sfCtrlSendCmd(FlashCmdReset)
  # Wait ~100us for reset to complete
  for i in 0 ..< 1000:
    discard regRead(SfCtrlCfg)
