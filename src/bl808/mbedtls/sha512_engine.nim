## SEC_ENG SHA-384/512 compression: one block per borrow of the shared engine.
##
## Included by sha512_alt.nim and by tools/test_tls_sha512_alt.py. The includer
## provides SecEngBase, regRead, regWrite, fenceIo, secIrqSave, secIrqRestore,
## dmaVisible, the sha512Dma storage pragma, Sha512Context (with `state`) and
## softwareProcess.
##
## The same engine, link descriptor and discipline as sha256_engine.nim (and
## the Wi-Fi SHA-1 provider): interrupts stay off for the one block, an engine
## that is busy, enabled or holding an unacknowledged result belongs to
## someone else, every register is put back, and a block the engine cannot
## take right now is hashed in software. What differs is the mode field of
## the descriptor (SHA-512), the 128-byte block and the eight 64-bit state
## words. SHA-384 is SHA-512 with other initial values, and the state is
## always preloaded here, so one mode serves both.

type
  Sha512State = array[8, uint64]
  Sha512Words = array[32, uint32]
  Sha512Link = object
    control, source: uint32
    digest: array[16, uint32]
  Sha512BlockResult = enum
    sha512BlockFault, sha512BlockDeferred, sha512BlockDone

static:
  doAssert offsetof(Sha512Link, digest) == 8
  doAssert sizeof(Sha512Link) == 72

const
  Sha512Control = SecEngBase
  Sha512LinkAddress = SecEngBase + 0x50'u
  Sha512Busy = 1'u32 shl 0
  Sha512Trigger = 1'u32 shl 1
  Sha512Mode = 4'u32 shl 2               # descriptor bits [4:2]: SHA-512
  Sha512Enable = 1'u32 shl 5
  Sha512Continue = 1'u32 shl 6
  Sha512Done = 1'u32 shl 8
  Sha512ClearDone = 1'u32 shl 9
  Sha512SignalDone = 1'u32 shl 10
  Sha512MaskIrq = 1'u32 shl 11
  Sha512LinkMode = 1'u32 shl 15
  Sha512OneBlock = 1'u32 shl 16          # the count is in blocks of the mode's size
  Sha512LinkControl = Sha512Mode or Sha512Continue or Sha512SignalDone or Sha512OneBlock
  Sha512PollLimit = 512
  Sha512BadInput = -0x0075.cint          # MBEDTLS_ERR_SHA512_BAD_INPUT_DATA

var
  sha512Descriptor {.sha512Dma.}: Sha512Link
  sha512Words {.sha512Dma.}: Sha512Words
  ## [0] 0 unchecked, 1 probing, 2 usable, 3 unavailable;
  ## [1] hardware blocks; [2] software blocks; [3] engine faults.
  sha512Backend {.exportc: "nim_mbedtls_sha512_backend".}: array[4, uint32]

proc sha512ByteSwap(word: uint32): uint32 {.inline.} =
  (word shl 24) or ((word and 0x0000FF00'u32) shl 8) or
    ((word and 0x00FF0000'u32) shr 8) or (word shr 24)

proc sha512LoadWords(destination: var Sha512Words; data: ptr uint8) {.inline.} =
  ## Mbed TLS accepts unaligned input; only the aligned DMA words see word
  ## accesses.
  let source = cast[ptr UncheckedArray[uint8]](data)
  for i in 0 ..< destination.len:
    let j = 4 * i
    destination[i] = source[j].uint32 or (source[j + 1].uint32 shl 8) or
      (source[j + 2].uint32 shl 16) or (source[j + 3].uint32 shl 24)

proc sha512ClearWords(address: uint; count: int) {.inline.} =
  for i in 0 ..< count:
    regWrite(address + 4'u * i.uint, 0)

proc sha512HardwareBlock(state: var Sha512State; data: ptr uint8): Sha512BlockResult =
  let descriptor = cast[uint](addr sha512Descriptor)
  let source = cast[uint](addr sha512Words[0])
  if not dmaVisible(descriptor, sizeof(sha512Descriptor).uint) or
      not dmaVisible(source, sizeof(sha512Words).uint): return sha512BlockFault
  let saved = secIrqSave()
  defer: secIrqRestore(saved)
  let original = regRead(Sha512Control)
  if (original and (Sha512Busy or Sha512Enable or Sha512Done)) != 0:
    return sha512BlockDeferred
  let originalLink = regRead(Sha512LinkAddress)
  sha512LoadWords(sha512Words, data)
  sha512Descriptor.control = Sha512LinkControl
  sha512Descriptor.source = source.uint32
  # The descriptor holds the digest as its big-endian bytes in memory order:
  # each 64-bit state word is its high half, then its low half.
  for i, word in state:
    sha512Descriptor.digest[2 * i] = sha512ByteSwap(uint32(word shr 32))
    sha512Descriptor.digest[2 * i + 1] = sha512ByteSwap(uint32(word and 0xFFFF_FFFF'u64))
  fenceIo()
  let active = Sha512Enable or Sha512LinkMode or Sha512MaskIrq
  regWrite(Sha512LinkAddress, descriptor.uint32)
  regWrite(Sha512Control, active)
  regWrite(Sha512Control, active or Sha512Trigger)
  var status: uint32
  for _ in 0 ..< Sha512PollLimit:
    status = regRead(Sha512Control)
    if (status and (Sha512Busy or Sha512Done)) == Sha512Done:
      result = sha512BlockDone
      break
  if (status and Sha512Busy) != 0:
    # A timed-out DMA can still refer to the private static buffers. Retire
    # the provider without recycling or rewriting either buffer; the enabled
    # engine keeps every other borrower away.
    inc sha512Backend[3]
    return sha512BlockFault
  fenceIo()
  if result == sha512BlockDone:
    let digest = descriptor + offsetof(Sha512Link, digest).uint
    for i in 0 ..< state.len:
      state[i] = (sha512ByteSwap(regRead(digest + 8'u * i.uint)).uint64 shl 32) or
        sha512ByteSwap(regRead(digest + 8'u * i.uint + 4'u)).uint64
  else:
    inc sha512Backend[3]
  regWrite(Sha512Control, active or Sha512ClearDone)
  regWrite(Sha512Control, original)
  regWrite(Sha512LinkAddress, originalLink)
  sha512ClearWords(descriptor, sizeof(Sha512Link) div 4)
  sha512ClearWords(source, sha512Words.len)

proc probeSha512Backend() =
  sha512Backend[0] = 1
  var sample: array[128, uint8]
  for i in 0 ..< sample.len: sample[i] = uint8(i * 3 + 1)
  # A non-default chaining state distinguishes this from a one-shot test, and
  # different halves in every word catch a swapped pair.
  const initial = [0x0123456789abcdef'u64, 0xfedcba9876543210'u64,
                   0xa5a55a5a0f1e2d3c'u64, 0x4b5a69788796a5b4'u64,
                   0x1122334455667788'u64, 0x99aabbccddeeff00'u64,
                   0x0f0e0d0c0b0a0908'u64, 0x8070605040302010'u64]
  var reference: Sha512Context
  reference.state = initial
  var actual = initial
  if softwareProcess(addr reference, addr sample[0]) != 0:
    sha512Backend[0] = 3
    return
  case sha512HardwareBlock(actual, addr sample[0])
  of sha512BlockDeferred: sha512Backend[0] = 0   # contention is not a failed check
  of sha512BlockFault: sha512Backend[0] = 3
  of sha512BlockDone:
    sha512Backend[0] = if actual == reference.state: 2'u32 else: 3'u32

proc sha512Process(ctx: ptr Sha512Context; data: ptr uint8): cint =
  if ctx == nil or data == nil: return Sha512BadInput
  if sha512Backend[0] == 0:
    probeSha512Backend()
  if sha512Backend[0] == 2:
    var state {.noinit.}: Sha512State
    for i in 0 ..< state.len: state[i] = ctx.state[i]
    case sha512HardwareBlock(state, data)
    of sha512BlockDone:
      for i in 0 ..< state.len: ctx.state[i] = state[i]
      inc sha512Backend[1]
      return 0
    of sha512BlockDeferred: discard
    of sha512BlockFault: sha512Backend[0] = 3
  inc sha512Backend[2]
  softwareProcess(ctx, data)
