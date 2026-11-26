## SEC_ENG SHA-224/256 compression: one block per borrow of the shared engine.
##
## Included by sha256_alt.nim and by tools/test_tls_sha256_alt.py. The includer
## provides SecEngBase, regRead, regWrite, fenceIo, secIrqSave, secIrqRestore,
## dmaVisible, the sha256Dma storage pragma, Sha256Context (with `state`) and
## softwareProcess.
##
## The discipline is the Wi-Fi SHA-1 provider's (wifi/mbedtls_sha1_alt.nim):
## interrupts stay off for the one block, an engine that is busy, enabled or
## holding an unacknowledged result belongs to someone else (the SHA-1 lease
## keeps it enabled), every register is put back, and a block the engine
## cannot take right now is hashed in software.

type
  Sha256State = array[8, uint32]
  Sha256Words = array[16, uint32]
  Sha256Link = object
    control, source: uint32
    digest: array[16, uint32]
  Sha256BlockResult = enum
    sha256BlockFault, sha256BlockDeferred, sha256BlockDone

static:
  doAssert offsetof(Sha256Link, digest) == 8
  doAssert sizeof(Sha256Link) == 72

const
  Sha256Control = SecEngBase
  Sha256LinkAddress = SecEngBase + 0x50'u
  Sha256Busy = 1'u32 shl 0
  Sha256Trigger = 1'u32 shl 1
  Sha256Enable = 1'u32 shl 5
  Sha256Continue = 1'u32 shl 6
  Sha256Done = 1'u32 shl 8
  Sha256ClearDone = 1'u32 shl 9
  Sha256SignalDone = 1'u32 shl 10
  Sha256MaskIrq = 1'u32 shl 11
  Sha256LinkMode = 1'u32 shl 15
  Sha256OneBlock = 1'u32 shl 16
  # Mode field [4:2] is zero for SHA-256; SHA-224 shares its compression.
  Sha256LinkControl = Sha256Continue or Sha256SignalDone or Sha256OneBlock
  Sha256PollLimit = 256
  Sha256BadInput = -0x0074.cint          # MBEDTLS_ERR_SHA256_BAD_INPUT_DATA

var
  sha256Descriptor {.sha256Dma.}: Sha256Link
  sha256Words {.sha256Dma.}: Sha256Words
  ## [0] 0 unchecked, 1 probing, 2 usable, 3 unavailable;
  ## [1] hardware blocks; [2] software blocks; [3] engine faults.
  sha256Backend {.exportc: "nim_mbedtls_sha256_backend".}: array[4, uint32]

proc sha256ByteSwap(word: uint32): uint32 {.inline.} =
  (word shl 24) or ((word and 0x0000FF00'u32) shl 8) or
    ((word and 0x00FF0000'u32) shr 8) or (word shr 24)

proc sha256LoadWords(destination: var Sha256Words; data: ptr uint8) {.inline.} =
  ## Mbed TLS accepts unaligned input; only the aligned DMA words see word
  ## accesses.
  let source = cast[ptr UncheckedArray[uint8]](data)
  for i in 0 ..< destination.len:
    let j = 4 * i
    destination[i] = source[j].uint32 or (source[j + 1].uint32 shl 8) or
      (source[j + 2].uint32 shl 16) or (source[j + 3].uint32 shl 24)

proc sha256ClearWords(address: uint; count: int) {.inline.} =
  for i in 0 ..< count:
    regWrite(address + 4'u * i.uint, 0)

proc sha256HardwareBlock(state: var Sha256State; data: ptr uint8): Sha256BlockResult =
  let descriptor = cast[uint](addr sha256Descriptor)
  let source = cast[uint](addr sha256Words[0])
  if not dmaVisible(descriptor, sizeof(sha256Descriptor).uint) or
      not dmaVisible(source, sizeof(sha256Words).uint): return sha256BlockFault
  let saved = secIrqSave()
  defer: secIrqRestore(saved)
  let original = regRead(Sha256Control)
  if (original and (Sha256Busy or Sha256Enable or Sha256Done)) != 0:
    return sha256BlockDeferred
  let originalLink = regRead(Sha256LinkAddress)
  sha256LoadWords(sha256Words, data)
  sha256Descriptor.control = Sha256LinkControl
  sha256Descriptor.source = source.uint32
  for i, word in state: sha256Descriptor.digest[i] = sha256ByteSwap(word)
  fenceIo()
  let active = Sha256Enable or Sha256LinkMode or Sha256MaskIrq
  regWrite(Sha256LinkAddress, descriptor.uint32)
  regWrite(Sha256Control, active)
  regWrite(Sha256Control, active or Sha256Trigger)
  var status: uint32
  for _ in 0 ..< Sha256PollLimit:
    status = regRead(Sha256Control)
    if (status and (Sha256Busy or Sha256Done)) == Sha256Done:
      result = sha256BlockDone
      break
  if (status and Sha256Busy) != 0:
    # A timed-out DMA can still refer to the private static buffers. Retire
    # the provider without recycling or rewriting either buffer; the enabled
    # engine keeps every other borrower away.
    inc sha256Backend[3]
    return sha256BlockFault
  fenceIo()
  if result == sha256BlockDone:
    for i in 0 ..< state.len:
      state[i] = sha256ByteSwap(
        regRead(descriptor + offsetof(Sha256Link, digest).uint + 4'u * i.uint))
  else:
    inc sha256Backend[3]
  regWrite(Sha256Control, active or Sha256ClearDone)
  regWrite(Sha256Control, original)
  regWrite(Sha256LinkAddress, originalLink)
  sha256ClearWords(descriptor, sizeof(Sha256Link) div 4)
  sha256ClearWords(source, sha256Words.len)

proc probeSha256Backend() =
  sha256Backend[0] = 1
  var sample: array[64, uint8]
  for i in 0 ..< sample.len: sample[i] = i.uint8
  # A non-default chaining state distinguishes this from a one-shot test.
  const initial = [0x01234567'u32, 0x89abcdef'u32, 0x76543210'u32, 0xfedcba98'u32,
                   0xa5a55a5a'u32, 0x0f1e2d3c'u32, 0x4b5a6978'u32, 0x8796a5b4'u32]
  var reference: Sha256Context
  reference.state = initial
  var actual = initial
  if softwareProcess(addr reference, addr sample[0]) != 0:
    sha256Backend[0] = 3
    return
  case sha256HardwareBlock(actual, addr sample[0])
  of sha256BlockDeferred: sha256Backend[0] = 0   # contention is not a failed check
  of sha256BlockFault: sha256Backend[0] = 3
  of sha256BlockDone:
    sha256Backend[0] = if actual == reference.state: 2'u32 else: 3'u32

proc sha256Process(ctx: ptr Sha256Context; data: ptr uint8): cint =
  if ctx == nil or data == nil: return Sha256BadInput
  if sha256Backend[0] == 0:
    probeSha256Backend()
  if sha256Backend[0] == 2:
    var state {.noinit.}: Sha256State
    for i in 0 ..< state.len: state[i] = ctx.state[i]
    case sha256HardwareBlock(state, data)
    of sha256BlockDone:
      for i in 0 ..< state.len: ctx.state[i] = state[i]
      inc sha256Backend[1]
      return 0
    of sha256BlockDeferred: discard
    of sha256BlockFault: sha256Backend[0] = 3
  inc sha256Backend[2]
  softwareProcess(ctx, data)
