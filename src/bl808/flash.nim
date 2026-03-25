## BL808 Serial Flash (SF) controller driver.
##
## The SF controller at 0x2000B000 manages the SPI NOR flash.
## Flash is memory-mapped via XIP at 0x58000000.
##
## For the Pine64 Ox64, the flash is 128 Mbit (16 MB).
## Flash operations require careful sequencing: disable XIP, perform
## the operation, then re-enable XIP.

import mmio, memmap

# =============================================================================
# SF controller register offsets
# =============================================================================
const
  SfCtrlCfg*        = SfCtrlBase + 0x00'u   # SF control config
  SfCtrlIfSahb0*    = SfCtrlBase + 0x04'u   # SF AHB interface 0
  SfCtrlIfSahb1*    = SfCtrlBase + 0x08'u   # SF AHB interface 1
  SfCtrlIfSahb2*    = SfCtrlBase + 0x0C'u   # SF AHB interface 2
  SfCtrlProtEnRd*   = SfCtrlBase + 0x10'u   # Read protect enable
  SfCtrlProtEn*     = SfCtrlBase + 0x14'u   # Protect enable
  SfCtrlSfPad*      = SfCtrlBase + 0x20'u   # Pad configuration
  SfCtrlAesRegion*  = SfCtrlBase + 0x80'u   # AES region base
  SfCtrlSfId0*      = SfCtrlBase + 0x14C'u  # Flash ID offset 0
  SfCtrlSfId1*      = SfCtrlBase + 0x150'u  # Flash ID offset 1
  SfCtrlIfIoDelay0* = SfCtrlBase + 0x1C0'u  # IO delay 0

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
proc flashReadXip*(offset: uint32): uint32 {.inline.} =
  ## Read a 32-bit word from flash via XIP (memory-mapped read).
  regRead(FlashXipBase + offset)

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

proc sfCtrlSendCmd(cmd: uint8, addr: uint32 = 0, hasAddr: bool = false,
                   addrLen: uint32 = 3, dummyClocks: uint32 = 0) =
  ## Send a command via the SF controller.
  # Write command to buffer
  regWrite(SfCtrlBufBase, cmd.uint32 shl 24)

  # Configure command phase
  var sahb0 = 0'u32
  sahb0 = sahb0 or (1'u32 shl 2)    # Command phase enable
  sahb0 = sahb0 or (7'u32 shl 17)   # 8-bit command (cmd_bit_cnt = 7)
  if hasAddr:
    sahb0 = sahb0 or (1'u32 shl 5)  # Address phase enable
    sahb0 = sahb0 or (((addrLen * 8 - 1) and 0x1F) shl 20)  # Address bit count
  regWrite(SfCtrlIfSahb0, sahb0)

  if hasAddr:
    regWrite(SfCtrlIfSahb1, addr)

  # Trigger the command
  regSet(SfCtrlCfg, 1'u32 shl 2)
  regWaitClear(SfCtrlCfg, 1'u32 shl 2)

proc sfCtrlWaitBusy(timeout: uint32 = 1_000_000): FlashError =
  var countdown = timeout
  while countdown > 0:
    sfCtrlSendCmd(FlashCmdReadSr1)
    let sr = regRead(SfCtrlBufBase + 4) and 0xFF
    if (sr and (1'u32 shl FlashSrBusy)) == 0:
      return flashOk
    countdown.dec
  flashTimeout

# =============================================================================
# Flash operations
# =============================================================================
proc flashWriteEnable*(): FlashError =
  ## Send write enable command (WREN).
  sfCtrlSendCmd(FlashCmdWriteEn)
  flashOk

proc flashWaitReady*(timeout: uint32 = 5_000_000): FlashError =
  ## Wait for flash to become ready (not busy).
  sfCtrlWaitBusy(timeout)

proc flashReadId*(): FlashId =
  ## Read the JEDEC flash ID (manufacturer, memory type, capacity).
  sfCtrlSendCmd(FlashCmdReadId)
  let id0 = regRead(SfCtrlBufBase + 4)
  result.manufacturerId = ((id0 shr 0) and 0xFF).uint8
  result.memoryType = ((id0 shr 8) and 0xFF).uint8
  result.capacity = ((id0 shr 16) and 0xFF).uint8

proc flashEraseSector*(address: uint32): FlashError =
  ## Erase a 4 KB sector. Address must be sector-aligned.
  if (address and (FlashSectorSize - 1)) != 0:
    return flashAlignError

  result = flashWriteEnable()
  if result != flashOk: return

  sfCtrlSendCmd(FlashCmdSectorEr, address, hasAddr = true)
  result = flashWaitReady(5_000_000)

proc flashEraseBlock64*(address: uint32): FlashError =
  ## Erase a 64 KB block. Address must be block-aligned.
  if (address and (FlashBlock64Size - 1)) != 0:
    return flashAlignError

  result = flashWriteEnable()
  if result != flashOk: return

  sfCtrlSendCmd(FlashCmdBlock64Er, address, hasAddr = true)
  result = flashWaitReady(10_000_000)

proc flashProgramRaw(address: uint32, data: openArray[uint8]): FlashError =
  ## Program up to 256 bytes starting at any address within a page.
  ## The caller must ensure data does not cross a page boundary.
  if data.len == 0: return flashOk
  if data.len > FlashPageSize.int: return flashSizeError

  result = flashWriteEnable()
  if result != flashOk: return

  # Load data into SF buffer
  var bufOffset = 4'u  # Skip command/address bytes in buffer
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

  sfCtrlSendCmd(FlashCmdPageProg, address, hasAddr = true)
  result = flashWaitReady()

proc flashProgramPage*(address: uint32, data: openArray[uint8]): FlashError =
  ## Program up to 256 bytes at a page-aligned address.
  if (address and (FlashPageSize - 1)) != 0: return flashAlignError
  flashProgramRaw(address, data)

proc flashWrite*(address: uint32, data: openArray[uint8]): FlashError =
  ## Write arbitrary data to flash at any address. Handles page boundary crossing.
  var offset = 0
  var addr = address

  while offset < data.len:
    # Calculate bytes remaining in current page
    let pageOffset = addr and (FlashPageSize - 1)
    let pageRemain = (FlashPageSize - pageOffset).int
    let chunkLen = min(pageRemain, data.len - offset)

    result = flashProgramRaw(addr, data.toOpenArray(offset, offset + chunkLen - 1))
    if result != flashOk: return

    offset += chunkLen
    addr += chunkLen.uint32

proc flashReset*() =
  ## Issue a software reset to the flash chip.
  sfCtrlSendCmd(FlashCmdEnReset)
  sfCtrlSendCmd(FlashCmdReset)
  # Wait ~100us for reset to complete
  for i in 0 ..< 1000:
    discard regRead(SfCtrlCfg)
