## BL808 Inter-Processor Communication (IPC) driver.
##
## The BL808 has three IPC instances for communication between cores:
##   IPC0 (0x2000A800) — M0 mailbox
##   IPC1 (0x2000A840) — LP mailbox
##   IPC2 (0x30005000) — D0 mailbox
##
## Each IPC instance has 16 interrupt bits per direction.
## Shared data passes through XRAM (16 KB at 0x40000000).
##
## Communication model:
##   - Core A writes to Core B's IPC_ISWR to trigger an interrupt on Core B
##   - Core B reads its IPC_IRSRR, processes the message, then writes IPC_ICR
##   - Payloads are placed in XRAM before triggering the interrupt

import mmio, memmap, core

# =============================================================================
# IPC register offsets (relative to IPC base)
# =============================================================================
# Each IPC instance has two CPU interfaces:
#   CPU1 at offset 0x00 (incoming from the paired core)
#   CPU0 at offset 0x20 (outgoing to the paired core)
const
  IpcIswr*          = 0x00'u  # Interrupt Set Write (trigger interrupt)
  IpcIrsrr*         = 0x04'u  # Interrupt Raw Status Read
  IpcIcr*           = 0x08'u  # Interrupt Clear
  IpcIusr*          = 0x0C'u  # Interrupt Unmask Status Read
  IpcIucr*          = 0x10'u  # Interrupt Unmask Clear
  IpcIlslr*         = 0x14'u  # Interrupt Line Select Low
  IpcIlshr*         = 0x18'u  # Interrupt Line Select High
  IpcIsr*           = 0x1C'u  # Interrupt Status (masked)

  # CPU0 (outgoing) register set at +0x20
  IpcCpu0Offset*    = 0x20'u

# =============================================================================
# IPC addressing by core pairs
# =============================================================================
# The IPC register addresses for sending between cores:
#
# M0 -> D0: Write to IPC2 + 0x00 (CPU1 set of D0's mailbox)
# M0 -> LP: Write to IPC1 + 0x00 (CPU1 set of LP's mailbox)
# D0 -> M0: Write to IPC0 + 0x00 (CPU1 set of M0's mailbox)
# D0 -> LP: Write to IPC1 + 0x20 (CPU0 set of LP's mailbox — from D0 side)
# LP -> M0: Write to IPC0 + 0x20 (CPU0 set of M0's mailbox — from LP side)
# LP -> D0: Write to IPC2 + 0x20 (CPU0 set of D0's mailbox — from LP side)
#
# And for receiving (reading status, clearing):
# M0 receives from D0: Read IPC0 + 0x00
# M0 receives from LP: Read IPC0 + 0x20
# D0 receives from M0: Read IPC2 + 0x00
# D0 receives from LP: Read IPC2 + 0x20
# LP receives from M0: Read IPC1 + 0x00
# LP receives from D0: Read IPC1 + 0x20

type
  IpcTarget* = enum
    ipcM0
    ipcD0
    ipcLP

  IpcSignal* = range[0..15]
    ## 16 interrupt signal bits per direction

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
proc sendAddr(fromCore, toCore: IpcTarget): uint =
  ## Get the IPC register address to write ISWR for triggering an interrupt.
  case fromCore
  of ipcM0:
    case toCore
    of ipcD0: Ipc2Base + IpcIswr               # M0 -> D0
    of ipcLP: Ipc1Base + IpcIswr               # M0 -> LP
    of ipcM0: 0  # invalid
  of ipcD0:
    case toCore
    of ipcM0: Ipc0Base + IpcIswr               # D0 -> M0
    of ipcLP: Ipc1Base + IpcCpu0Offset + IpcIswr  # D0 -> LP
    of ipcD0: 0
  of ipcLP:
    case toCore
    of ipcM0: Ipc0Base + IpcCpu0Offset + IpcIswr  # LP -> M0
    of ipcD0: Ipc2Base + IpcCpu0Offset + IpcIswr  # LP -> D0
    of ipcLP: 0

proc recvStatusAddr(selfCore, fromCore: IpcTarget): uint =
  ## Get the IPC register address to read raw interrupt status.
  case selfCore
  of ipcM0:
    case fromCore
    of ipcD0: Ipc0Base + IpcIrsrr
    of ipcLP: Ipc0Base + IpcCpu0Offset + IpcIrsrr
    of ipcM0: 0
  of ipcD0:
    case fromCore
    of ipcM0: Ipc2Base + IpcIrsrr
    of ipcLP: Ipc2Base + IpcCpu0Offset + IpcIrsrr
    of ipcD0: 0
  of ipcLP:
    case fromCore
    of ipcM0: Ipc1Base + IpcIrsrr
    of ipcD0: Ipc1Base + IpcCpu0Offset + IpcIrsrr
    of ipcLP: 0

proc recvClearAddr(selfCore, fromCore: IpcTarget): uint =
  ## Get the IPC register address to clear an interrupt.
  case selfCore
  of ipcM0:
    case fromCore
    of ipcD0: Ipc0Base + IpcIcr
    of ipcLP: Ipc0Base + IpcCpu0Offset + IpcIcr
    of ipcM0: 0
  of ipcD0:
    case fromCore
    of ipcM0: Ipc2Base + IpcIcr
    of ipcLP: Ipc2Base + IpcCpu0Offset + IpcIcr
    of ipcD0: 0
  of ipcLP:
    case fromCore
    of ipcM0: Ipc1Base + IpcIcr
    of ipcD0: Ipc1Base + IpcCpu0Offset + IpcIcr
    of ipcLP: 0

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
  let addr = sendAddr(selfCore, target)
  if addr != 0:
    regWrite(addr, 1'u32 shl signal.uint32)

proc ipcReadSignals*(fromCore: IpcTarget): uint32 =
  ## Read pending IPC signals from a specific core.
  let addr = recvStatusAddr(selfCore, fromCore)
  if addr != 0:
    regRead(addr)
  else:
    0

proc ipcClearSignal*(fromCore: IpcTarget, signal: IpcSignal) =
  ## Clear a received IPC signal.
  let addr = recvClearAddr(selfCore, fromCore)
  if addr != 0:
    regWrite(addr, 1'u32 shl signal.uint32)

proc ipcClearAllSignals*(fromCore: IpcTarget) =
  let addr = recvClearAddr(selfCore, fromCore)
  if addr != 0:
    regWrite(addr, 0xFFFF'u32)

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

  # Memory fence before signaling
  fence()

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
  fence()

proc ipcIsReady*(target: IpcTarget): bool =
  ## Check if another core has signaled ready.
  let syncAddr = case target
    of ipcM0: XramSyncM0
    of ipcD0: XramSyncD0
    of ipcLP: XramSyncLP
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

proc ipcSharedRead32*(offset: uint): uint32 =
  ## Read a 32-bit value from the user shared memory region.
  if offset < XramUserSize:
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
  fence()

proc ipcSharedReadBuffer*(offset: uint, buf: var openArray[uint8]) =
  ## Read a buffer from user shared memory.
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
  ## Clears all pending signals and marks this core as ready.
  when defined(bl808m0):
    # Clear incoming signals from D0 and LP
    ipcClearAllSignals(ipcD0)
    ipcClearAllSignals(ipcLP)
  elif defined(bl808d0):
    ipcClearAllSignals(ipcM0)
    ipcClearAllSignals(ipcLP)
  elif defined(bl808lp):
    ipcClearAllSignals(ipcM0)
    ipcClearAllSignals(ipcD0)

  ipcSetReady()
