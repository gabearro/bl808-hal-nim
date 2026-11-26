## SEC_ENG AES block encryption: one 16-byte block per borrow of the engine.
##
## Included by aes_alt.nim and by tools/test_tls_aes_alt.py. The includer
## provides SecEngBase, regRead, regWrite, fenceIo, secIrqSave, secIrqRestore,
## dmaVisible, the aesDma storage pragma, AesContext (nr, rk_offset, buf),
## softwareSetKey and softwareEncrypt.
##
## This is the granularity of Bouffalo's own Mbed TLS port (aes_alt.c over
## bl_aes_transform): the key travels in a link descriptor, the engine runs
## ECB over one block in natural byte order, and CBC/CTR/GCM stay in Mbed TLS.
## The borrow rules are the SHA providers': interrupts off for the block, an
## engine that is busy, enabled or in link mode belongs to someone else, every
## register is put back, the key is scrubbed, and a block the engine cannot
## take is encrypted in software.

type
  AesLink = object
    control, source, destination: uint32
    iv: array[4, uint32]
    key: array[8, uint32]
  AesBlockWords = array[4, uint32]
  AesBlockResult = enum
    aesBlockFault, aesBlockDeferred, aesBlockDone

static:
  doAssert offsetof(AesLink, key) == 28
  doAssert sizeof(AesLink) == 60

const
  AesControl = SecEngBase + 0x100'u
  AesEndianAddress = SecEngBase + 0x148'u
  AesLinkAddress = SecEngBase + 0x150'u
  AesBusy = 1'u32 shl 0
  AesTrigger = 1'u32 shl 1
  AesEnable = 1'u32 shl 2
  AesMaskIrq = 1'u32 shl 11
  AesLinkMode = 1'u32 shl 15
  AesNaturalByteOrder = 0x1F'u32       # Sec_Eng_AES_Enable_BE
  # Descriptor word 0: [4:3] key size, [5] decrypt, [6] reuse last key,
  # [9] clear the done flag, [13:12] block mode (0 = ECB), [31:16] blocks.
  AesLinkClearDone = 1'u32 shl 9
  AesLinkOneBlock = 1'u32 shl 16
  AesPollLimit = 256
  AesBadInput = -0x0021.cint            # MBEDTLS_ERR_AES_BAD_INPUT_DATA

var
  aesDescriptor {.aesDma.}: AesLink
  aesSource {.aesDma.}: AesBlockWords
  aesDestination {.aesDma.}: AesBlockWords
  ## [0..2] provider state for 128/192/256-bit keys: 0 unchecked, 1 probing,
  ## 2 usable, 3 unavailable; [3] hardware blocks; [4] software blocks;
  ## [5] engine faults.
  aesBackend {.exportc: "nim_mbedtls_aes_backend".}: array[6, uint32]

proc aesKeyMode(keyWords: int): uint32 {.inline.} =
  ## SEC_ENG encodes AES-256 as 1 and AES-192 as 2.
  case keyWords
  of 6: 2'u32 shl 3
  of 8: 1'u32 shl 3
  else: 0'u32

proc aesLoadWords(destination: var AesBlockWords; data: ptr uint8) {.inline.} =
  let source = cast[ptr UncheckedArray[uint8]](data)
  for i in 0 ..< destination.len:
    let j = 4 * i
    destination[i] = source[j].uint32 or (source[j + 1].uint32 shl 8) or
      (source[j + 2].uint32 shl 16) or (source[j + 3].uint32 shl 24)

proc aesClearWords(address: uint; count: int) {.inline.} =
  for i in 0 ..< count:
    regWrite(address + 4'u * i.uint, 0)

proc aesHardwareBlock(key: ptr UncheckedArray[uint32]; keyWords: int;
                      input, output: ptr uint8): AesBlockResult =
  ## `key` holds the raw key as Mbed TLS loads it: little-endian words of the
  ## key bytes, which is the byte stream itself on this little-endian core.
  let descriptor = cast[uint](addr aesDescriptor)
  let source = cast[uint](addr aesSource[0])
  let destination = cast[uint](addr aesDestination[0])
  if not dmaVisible(descriptor, sizeof(aesDescriptor).uint) or
      not dmaVisible(source, sizeof(aesSource).uint) or
      not dmaVisible(destination, sizeof(aesDestination).uint): return aesBlockFault
  let saved = secIrqSave()
  defer: secIrqRestore(saved)
  let original = regRead(AesControl)
  if (original and (AesBusy or AesEnable or AesLinkMode)) != 0: return aesBlockDeferred
  let originalLink = regRead(AesLinkAddress)
  let originalEndian = regRead(AesEndianAddress)
  aesLoadWords(aesSource, input)
  aesDescriptor.control = aesKeyMode(keyWords) or AesLinkClearDone or AesLinkOneBlock
  aesDescriptor.source = source.uint32
  aesDescriptor.destination = destination.uint32
  for i in 0 ..< aesDescriptor.key.len:
    aesDescriptor.key[i] = if i < keyWords: key[i] else: 0'u32
  fenceIo()
  let active = AesEnable or AesLinkMode or AesMaskIrq
  regWrite(AesEndianAddress, AesNaturalByteOrder)
  regWrite(AesLinkAddress, descriptor.uint32)
  regWrite(AesControl, active)
  regWrite(AesControl, active or AesTrigger)
  # The vendor driver waits two instructions before it trusts BUSY.
  var status = regRead(AesControl)
  for _ in 0 ..< AesPollLimit:
    status = regRead(AesControl)
    if (status and AesBusy) == 0:
      result = aesBlockDone
      break
  if result != aesBlockDone:
    # A timed-out DMA can still refer to the private static buffers, key
    # included. Retire the provider without recycling or rewriting them; the
    # enabled engine keeps every other borrower away.
    inc aesBackend[5]
    return aesBlockFault
  fenceIo()
  let cipher = cast[ptr UncheckedArray[uint8]](output)
  for i in 0 ..< aesDestination.len:
    let word = regRead(destination + 4'u * i.uint)
    for j in 0 ..< 4: cipher[4 * i + j] = uint8(word shr (8 * j))
  regWrite(AesControl, original)
  regWrite(AesLinkAddress, originalLink)
  regWrite(AesEndianAddress, originalEndian)
  aesClearWords(descriptor, sizeof(AesLink) div 4)
  aesClearWords(source, aesSource.len)
  aesClearWords(destination, aesDestination.len)

proc aesContextKey(ctx: ptr AesContext; keyWords: var int): ptr UncheckedArray[uint32] {.inline.} =
  ## An encryption key schedule starts with the raw key (FIPS-197 5.2).
  keyWords = ctx.nr.int - 6
  let offset = ctx.rk_offset.int
  if keyWords notin [4, 6, 8] or offset < 0 or offset + keyWords > ctx.buf.len:
    return nil
  cast[ptr UncheckedArray[uint32]](addr ctx.buf[offset])

proc probeAesBackend(slot, keyWords: int) =
  ## Compare the engine with the software block function on a scratch key of
  ## this size before any caller's data depends on it.
  aesBackend[slot] = 1
  var schedule: AesContext
  var scratch: array[32, uint8]
  var plain, expected, actual: array[16, uint8]
  for i in 0 ..< scratch.len: scratch[i] = uint8(0x3C + 7 * i)
  for i in 0 ..< plain.len: plain[i] = uint8(0xA5 xor (17 * i))
  if softwareSetKey(addr schedule, addr scratch[0], cuint(32 * keyWords)) != 0 or
      softwareEncrypt(addr schedule, addr plain[0], addr expected[0]) != 0:
    aesBackend[slot] = 3
    return
  var words: int
  let key = aesContextKey(addr schedule, words)
  if key == nil or words != keyWords:
    aesBackend[slot] = 3
    return
  case aesHardwareBlock(key, keyWords, addr plain[0], addr actual[0])
  of aesBlockDeferred: aesBackend[slot] = 0      # contention is not a failed check
  of aesBlockFault: aesBackend[slot] = 3
  of aesBlockDone: aesBackend[slot] = if actual == expected: 2'u32 else: 3'u32

proc aesEncryptBlock(ctx: ptr AesContext; input, output: ptr uint8): cint =
  if ctx == nil or input == nil or output == nil: return AesBadInput
  var keyWords: int
  let key = aesContextKey(ctx, keyWords)
  if key != nil:
    let slot = (keyWords - 4) div 2
    if aesBackend[slot] == 0:
      probeAesBackend(slot, keyWords)
    if aesBackend[slot] == 2:
      case aesHardwareBlock(key, keyWords, input, output)
      of aesBlockDone:
        inc aesBackend[3]
        return 0
      of aesBlockDeferred: discard
      of aesBlockFault:
        # One engine serves every key size.
        for other in 0 .. 2: aesBackend[other] = 3
  inc aesBackend[4]
  softwareEncrypt(ctx, input, output)
