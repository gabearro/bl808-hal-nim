## BL808 Inter-Processor Communication (IPC) driver.
##
## The BL808 has three IPC instances for communication between cores:
##   IPC0 (0x2000A800) — M0 mailbox
##   IPC1 (0x2000A840) — LP mailbox
##   IPC2 (0x30005000) — D0 mailbox
##
## Each IPC instance exposes 32 interrupt channels.
## Shared data passes through XRAM (16 KB at 0x40000000).
##
## Communication model:
##   - Core A writes to Core B's CPU1_ISWR to trigger an interrupt on Core B
##   - Core B reads CPU0_IRSRR, processes the message, then writes CPU0_ICR
##   - Payloads are placed in XRAM before triggering the interrupt

import mmio, memmap, core

# =============================================================================
# IPC register offsets (relative to IPC base)
# =============================================================================
const
  IpcCpu1Iswr*      = 0x00'u  # Send/trigger interrupt toward this IPC core
  IpcCpu1Irsrr*     = 0x04'u  # CPU1-side raw pending status
  IpcCpu1Icr*       = 0x08'u  # CPU1-side clear pending bits
  IpcCpu1Iusr*      = 0x0C'u  # CPU1-side interrupt unmask
  IpcCpu1Iucr*      = 0x10'u  # CPU1-side interrupt mask
  IpcCpu1Ilslr*     = 0x14'u  # CPU1-side low security mask
  IpcCpu1Ilshr*     = 0x18'u  # CPU1-side high security mask
  IpcCpu1Isr*       = 0x1C'u  # CPU1-side masked pending status

  IpcCpu0Iswr*      = 0x20'u  # CPU0-side send/trigger
  IpcCpu0Irsrr*     = 0x24'u  # CPU0-side raw pending status
  IpcCpu0Icr*       = 0x28'u  # CPU0-side clear pending bits
  IpcCpu0Iusr*      = 0x2C'u  # CPU0-side interrupt unmask
  IpcCpu0Iucr*      = 0x30'u  # CPU0-side interrupt mask
  IpcCpu0Ilslr*     = 0x34'u  # CPU0-side low security mask
  IpcCpu0Ilshr*     = 0x38'u  # CPU0-side high security mask
  IpcCpu0Isr*       = 0x3C'u  # CPU0-side masked pending status

type
  IpcTarget* = enum
    ipcM0
    ipcD0
    ipcLP

  IpcSignal* = range[0..31]
    ## 32 interrupt signal bits per mailbox

# =============================================================================
# XRAM shared memory layout
# =============================================================================
# We divide the 16 KB XRAM into regions for each core-to-core channel.
# Layout:
#   0x40000000 - 0x40000003: Sync word 1 (M0 ready flag)
#   0x40000004 - 0x40000007: Sync word 2 (D0 ready flag)
#   0x40000008 - 0x4000000B: Sync word 3 (LP ready flag)
#   0x4000000C - 0x4000000F: Reserved
#   0x40000010 - 0x400007FF: M0 -> D0 message buffer (2032 bytes)
#   0x40000800 - 0x40000FFF: D0 -> M0 message buffer (2048 bytes)
#   0x40001000 - 0x400017FF: M0 -> LP message buffer (2048 bytes)
#   0x40001800 - 0x40001FFF: LP -> M0 message buffer (2048 bytes)
#   0x40002000 - 0x400027FF: D0 -> LP message buffer (2048 bytes)
#   0x40002800 - 0x40002FFF: LP -> D0 message buffer (2048 bytes)
#   0x40003000 - 0x40003FFF: User-defined shared memory (4096 bytes)

const
  XramSyncM0*       = XramBase + 0x000'u  # M0 sync flag
  XramSyncD0*       = XramBase + 0x004'u  # D0 sync flag
  XramSyncLP*       = XramBase + 0x008'u  # LP sync flag

  XramBufM0toD0*    = XramBase + 0x010'u
  XramBufM0toD0Size* = 2032

  XramBufD0toM0*    = XramBase + 0x800'u
  XramBufD0toM0Size* = 2048

  XramBufM0toLP*    = XramBase + 0x1000'u
  XramBufM0toLPSize* = 2048

  XramBufLPtoM0*    = XramBase + 0x1800'u
  XramBufLPtoM0Size* = 2048

  XramBufD0toLP*    = XramBase + 0x2000'u
  XramBufD0toLPSize* = 2048

  XramBufLPtoD0*    = XramBase + 0x2800'u
  XramBufLPtoD0Size* = 2048

  XramUserBase*     = XramBase + 0x3000'u
  XramUserSize*     = 4096

# =============================================================================
# Message header (stored at the start of each XRAM buffer)
# =============================================================================
type
  IpcMsgHeader* {.packed.} = object
    tag*: uint16       ## Message type tag
    length*: uint16    ## Data length in bytes (after header)

const IpcMsgHeaderSize* = 4

# =============================================================================
# Send address resolution
# =============================================================================
proc ipcBase(core: IpcTarget): uint =
  case core
  of ipcM0: Ipc0Base
  of ipcLP: Ipc1Base
  of ipcD0: Ipc2Base

proc sendAddr(fromCore, toCore: IpcTarget): uint =
  ## Sender identity is not encoded by the hardware mailbox.
  ## Protocols that need per-sender distinction must reserve distinct channels.
  if fromCore == toCore:
    return 0
  ipcBase(toCore) + IpcCpu1Iswr

proc recvClearAddr(selfCore: IpcTarget): uint =
  ## Get the IPC clear register address for this core's receive bank.
  ipcBase(selfCore) + IpcCpu0Icr

proc recvRawStatusAddr(selfCore: IpcTarget): uint =
  ## Get the raw pending status register for this core's receive bank.
  ipcBase(selfCore) + IpcCpu0Irsrr

proc bufferAddr(fromCore, toCore: IpcTarget): (uint, uint32) =
  ## Get the XRAM buffer base address and size for a given direction.
  case fromCore
  of ipcM0:
    case toCore
    of ipcD0: (XramBufM0toD0, XramBufM0toD0Size.uint32)
    of ipcLP: (XramBufM0toLP, XramBufM0toLPSize.uint32)
    of ipcM0: (0'u, 0'u32)
  of ipcD0:
    case toCore
    of ipcM0: (XramBufD0toM0, XramBufD0toM0Size.uint32)
    of ipcLP: (XramBufD0toLP, XramBufD0toLPSize.uint32)
    of ipcD0: (0'u, 0'u32)
  of ipcLP:
    case toCore
    of ipcM0: (XramBufLPtoM0, XramBufLPtoM0Size.uint32)
    of ipcD0: (XramBufLPtoD0, XramBufLPtoD0Size.uint32)
    of ipcLP: (0'u, 0'u32)

proc sharedWriteBarrier() {.inline.} =
  ## Publish cached XRAM writes before signaling another core.
  core.dcacheFlushAll()
  core.fence()

proc sharedReadBarrier() {.inline.} =
  ## Refresh cached XRAM lines before consuming data from another core.
  core.dcacheFlushAll()
  core.dcacheInvalidateAll()
  core.fence()

# =============================================================================
# Compile-time self-core identification
# =============================================================================
when defined(bl808m0):
  const selfCore* = ipcM0
elif defined(bl808d0):
  const selfCore* = ipcD0
elif defined(bl808lp):
  const selfCore* = ipcLP
else:
  const selfCore* = ipcM0  # fallback, bl808.nim enforces core selection

# =============================================================================
# IPC signal operations
# =============================================================================
proc ipcSendSignal*(target: IpcTarget, signal: IpcSignal) =
  ## Send an interrupt signal to another core.
  let regAddr = sendAddr(selfCore, target)
  if regAddr != 0:
    regWrite(regAddr, 1'u32 shl signal.uint32)

proc ipcReadSignals*(fromCore: IpcTarget): uint32 =
  ## Read pending IPC signals for this core.
  ## The hardware mailbox does not preserve sender identity in the status word.
  discard fromCore
  regRead(recvRawStatusAddr(selfCore))

proc ipcClearSignal*(fromCore: IpcTarget, signal: IpcSignal) =
  ## Clear a received IPC signal.
  discard fromCore
  let regAddr = recvClearAddr(selfCore)
  regWrite(regAddr, 1'u32 shl signal.uint32)

proc ipcClearAllSignals*(fromCore: IpcTarget) =
  discard fromCore
  let regAddr = recvClearAddr(selfCore)
  regWrite(regAddr, 0xFFFF_FFFF'u32)

# =============================================================================
# Message-based IPC (using XRAM)
# =============================================================================
const
  IpcSignalMsg*     = 0  ## Signal bit 0: message available in XRAM
  IpcSignalAck*     = 1  ## Signal bit 1: message acknowledged
  IpcSignalSync*    = 2  ## Signal bit 2: synchronization/handshake

proc ipcSendMessage*(target: IpcTarget, tag: uint16, data: openArray[uint8]): bool =
  ## Send a tagged message to another core via XRAM.
  ## Returns false if the data doesn't fit in the buffer.
  let (bufBase, bufSize) = bufferAddr(selfCore, target)
  if bufBase == 0: return false
  if data.len.uint32 + IpcMsgHeaderSize.uint32 > bufSize: return false

  # Write message header
  let header = (data.len.uint16.uint32 shl 16) or tag.uint32
  regWrite(bufBase, header)

  # Write message data (4 bytes at a time)
  var offset = IpcMsgHeaderSize.uint
  var i = 0
  while i + 3 < data.len:
    let word = data[i].uint32 or
               (data[i+1].uint32 shl 8) or
               (data[i+2].uint32 shl 16) or
               (data[i+3].uint32 shl 24)
    regWrite(bufBase + offset, word)
    offset += 4
    i += 4

  # Write remaining bytes
  if i < data.len:
    var word = 0'u32
    for j in 0 ..< data.len - i:
      word = word or (data[i+j].uint32 shl (j * 8))
    regWrite(bufBase + offset, word)

  # Publish shared-memory writes before signaling.
  sharedWriteBarrier()

  # Signal the target core
  ipcSendSignal(target, IpcSignalMsg)
  true

proc ipcRecvMessage*(fromCore: IpcTarget, tag: var uint16,
                     buf: var openArray[uint8]): int =
  ## Receive a message from another core.
  ## Returns the number of data bytes received, or -1 if no message.
  let signals = ipcReadSignals(fromCore)
  if (signals and (1'u32 shl IpcSignalMsg)) == 0:
    return -1

  let (bufBase, _) = bufferAddr(fromCore, selfCore)
  if bufBase == 0: return -1

  sharedReadBarrier()

  # Read message header
  let header = regRead(bufBase)
  tag = (header and 0xFFFF).uint16
  let length = (header shr 16).int

  # Read data
  let copyLen = min(length, buf.len)
  var offset = IpcMsgHeaderSize.uint
  var i = 0
  while i + 3 < copyLen:
    let word = regRead(bufBase + offset)
    buf[i]   = (word and 0xFF).uint8
    buf[i+1] = ((word shr 8) and 0xFF).uint8
    buf[i+2] = ((word shr 16) and 0xFF).uint8
    buf[i+3] = ((word shr 24) and 0xFF).uint8
    offset += 4
    i += 4

  if i < copyLen:
    let word = regRead(bufBase + offset)
    for j in 0 ..< copyLen - i:
      buf[i+j] = ((word shr (j * 8)) and 0xFF).uint8

  # Clear the signal
  ipcClearSignal(fromCore, IpcSignalMsg)

  # Send acknowledgment
  ipcSendSignal(fromCore, IpcSignalAck)

  copyLen

# =============================================================================
# Synchronization
# =============================================================================
proc ipcSetReady*() =
  ## Mark this core as ready (write sync flag to XRAM).
  let syncAddr = case selfCore
    of ipcM0: XramSyncM0
    of ipcD0: XramSyncD0
    of ipcLP: XramSyncLP
  regWrite(syncAddr, IpcSyncFlag)
  sharedWriteBarrier()

proc ipcIsReady*(target: IpcTarget): bool =
  ## Check if another core has signaled ready.
  let syncAddr = case target
    of ipcM0: XramSyncM0
    of ipcD0: XramSyncD0
    of ipcLP: XramSyncLP
  sharedReadBarrier()
  regRead(syncAddr) == IpcSyncFlag

proc ipcWaitReady*(target: IpcTarget, timeout: uint32 = 10_000_000): bool =
  ## Wait for another core to become ready. Returns false on timeout.
  var countdown = timeout
  while not ipcIsReady(target):
    countdown.dec
    if countdown == 0: return false
  true

# =============================================================================
# Shared memory access (user region at XRAM + 0x3000)
# =============================================================================
proc ipcSharedWrite32*(offset: uint, value: uint32) =
  ## Write a 32-bit value to the user shared memory region.
  if offset < XramUserSize:
    regWrite(XramUserBase + offset, value)
    sharedWriteBarrier()

proc ipcSharedRead32*(offset: uint): uint32 =
  ## Read a 32-bit value from the user shared memory region.
  if offset < XramUserSize:
    sharedReadBarrier()
    regRead(XramUserBase + offset)
  else:
    0

proc ipcSharedWriteBuffer*(offset: uint, data: openArray[uint8]) =
  ## Write a buffer to user shared memory.
  var i = 0
  var off = offset
  while i + 3 < data.len and off + 3 < XramUserSize:
    let word = data[i].uint32 or
               (data[i+1].uint32 shl 8) or
               (data[i+2].uint32 shl 16) or
               (data[i+3].uint32 shl 24)
    regWrite(XramUserBase + off, word)
    i += 4
    off += 4
  if i < data.len and off < XramUserSize:
    var word = 0'u32
    for j in 0 ..< min(data.len - i, (XramUserSize - off.int)):
      word = word or (data[i+j].uint32 shl (j * 8))
    regWrite(XramUserBase + off, word)
  sharedWriteBarrier()

proc ipcSharedReadBuffer*(offset: uint, buf: var openArray[uint8]) =
  ## Read a buffer from user shared memory.
  sharedReadBarrier()
  var i = 0
  var off = offset
  while i + 3 < buf.len and off + 3 < XramUserSize:
    let word = regRead(XramUserBase + off)
    buf[i]   = (word and 0xFF).uint8
    buf[i+1] = ((word shr 8) and 0xFF).uint8
    buf[i+2] = ((word shr 16) and 0xFF).uint8
    buf[i+3] = ((word shr 24) and 0xFF).uint8
    i += 4
    off += 4
  if i < buf.len and off < XramUserSize:
    let word = regRead(XramUserBase + off)
    for j in 0 ..< min(buf.len - i, (XramUserSize - off.int)):
      buf[i+j] = ((word shr (j * 8)) and 0xFF).uint8

# =============================================================================
# IPC initialization
# =============================================================================
proc ipcInit*() =
  ## Initialize IPC for the current core.
  ## Enables all interrupt bits, clears pending signals, and marks this core as ready.

  # Unmask all interrupt bits on our receive bank.
  regWrite(ipcBase(selfCore) + IpcCpu0Iusr, 0xFFFF_FFFF'u32)

  # Clear all pending signals
  let clearAddr = recvClearAddr(selfCore)
  regWrite(clearAddr, 0xFFFF_FFFF'u32)

  ipcSetReady()
