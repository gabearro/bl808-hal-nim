## One-shot AES-GCM on SEC_ENG: the AES block in CTR mode for the data and
## the GMAC block for GHASH, a chunk of whole blocks per borrow of the engines.
##
## Included by gcm_alt.nim. The includer provides SecEngBase, regRead,
## regWrite, fenceIo, secIrqSave, secIrqRestore, dmaVisible, the gcmDma
## storage pragma, AesContext (nr, rk_offset, buf), aesBlock (one block
## through the AES provider) and softwareOneshot (the stock GCM, for the
## first-use check).
##
## The engines' DMA only reaches uncached RAM, so the data goes through two
## bounce buffers there, `ChunkBlocks` blocks at a time. Per chunk, with
## interrupts off: AES-CTR from one buffer to the other, GHASH over the
## ciphertext, and the GHASH state carried in the GMAC descriptor. The
## borrow rules are the other providers': an engine that is busy or enabled
## belongs to someone else, every register is put back, keys and data are
## scrubbed from the buffers, and whatever the hardware cannot take right
## now is left to the software implementation.

type
  GcmAesLink = object
    control, source, destination: uint32
    iv: array[4, uint32]
    key: array[8, uint32]
  GcmMacLink = object
    control, source: uint32
    key: array[4, uint32]         # the hash subkey H
    result: array[4, uint32]      # GHASH state, carried from run to run
  GcmOutcome = enum
    gcmFault, gcmDeferred, gcmDone

const
  ChunkBlocks = 32
  ChunkBytes = ChunkBlocks * 16

  GcmAesControl = SecEngBase + 0x100'u
  GcmAesEndian = SecEngBase + 0x148'u
  GcmAesLinkAddress = SecEngBase + 0x150'u
  GcmAesBusy = 1'u32 shl 0
  GcmAesTrigger = 1'u32 shl 1
  GcmAesEnable = 1'u32 shl 2
  GcmAesMaskIrq = 1'u32 shl 11
  GcmAesLinkMode = 1'u32 shl 15
  GcmAesNaturalOrder = 0x1F'u32     # bytes as they sit in memory; 4-byte counter
  GcmAesClearDone = 1'u32 shl 9
  GcmAesCtr = 1'u32 shl 12          # descriptor [13:12]: 1 = CTR

  GcmMacControl = SecEngBase + 0x500'u
  GcmMacLinkAddress = SecEngBase + 0x504'u
  GcmMacBusy = 1'u32 shl 0
  GcmMacTrigger = 1'u32 shl 1
  GcmMacEnable = 1'u32 shl 2
  GcmMacClearDone = 1'u32 shl 9
  GcmMacMaskIrq = 1'u32 shl 11
  GcmMacNaturalOrder = 7'u32 shl 12 # tag, key and data as bytes in memory

  GcmPollLimit = 20_000

static:
  doAssert sizeof(GcmAesLink) == 60 and sizeof(GcmMacLink) == 40

var
  gcmAesLink {.gcmDma.}: GcmAesLink
  gcmMacLink {.gcmDma.}: GcmMacLink
  gcmSource {.gcmDma.}: array[ChunkBytes div 4, uint32]
  gcmDestination {.gcmDma.}: array[ChunkBytes div 4, uint32]
  ## [0..2] provider state for 128/192/256-bit keys: 0 unchecked, 1 probing,
  ## 2 usable, 3 unavailable; [3] records on hardware; [4] records left to
  ## software; [5] engine faults; [6] 16-byte blocks on hardware.
  gcmBackend {.exportc: "nim_mbedtls_gcm_backend".}: array[7, uint32]

template srcBytes: untyped = cast[ptr UncheckedArray[uint8]](addr gcmSource[0])
template dstBytes: untyped = cast[ptr UncheckedArray[uint8]](addr gcmDestination[0])

proc gcmKeyMode(keyWords: int): uint32 {.inline.} =
  case keyWords
  of 6: 2'u32 shl 3
  of 8: 1'u32 shl 3
  else: 0'u32

proc gcmScrub() =
  zeroMem(addr gcmAesLink, sizeof(gcmAesLink))
  zeroMem(addr gcmMacLink, sizeof(gcmMacLink))
  zeroMem(addr gcmSource[0], ChunkBytes)
  zeroMem(addr gcmDestination[0], ChunkBytes)

proc gcmEnginesFree(): bool {.inline.} =
  (regRead(GcmAesControl) and (GcmAesBusy or GcmAesEnable or GcmAesLinkMode)) == 0 and
    (regRead(GcmMacControl) and (GcmMacBusy or GcmMacEnable)) == 0

proc gcmRunCtr(blocks: int): bool =
  ## AES-CTR over `blocks` blocks from the source to the destination buffer,
  ## with the key and counter block already in the descriptor.
  let original = regRead(GcmAesControl)
  let originalLink = regRead(GcmAesLinkAddress)
  let originalEndian = regRead(GcmAesEndian)
  gcmAesLink.control = (gcmAesLink.control and 0xFFFF'u32) or (blocks.uint32 shl 16)
  fenceIo()
  let active = GcmAesEnable or GcmAesLinkMode or GcmAesMaskIrq
  regWrite(GcmAesEndian, GcmAesNaturalOrder)
  regWrite(GcmAesLinkAddress, cast[uint32](addr gcmAesLink))
  regWrite(GcmAesControl, active)
  regWrite(GcmAesControl, active or GcmAesTrigger)
  var status = regRead(GcmAesControl)
  for _ in 0 ..< GcmPollLimit:
    status = regRead(GcmAesControl)
    if (status and GcmAesBusy) == 0:
      result = true
      break
  if not result: return false       # leave the engine enabled: nobody may reuse it
  fenceIo()
  regWrite(GcmAesControl, original)
  regWrite(GcmAesLinkAddress, originalLink)
  regWrite(GcmAesEndian, originalEndian)

proc gcmRunHash(buffer: pointer; blocks: int): bool =
  ## GHASH `blocks` blocks of `buffer` into the state in the descriptor.
  let original = regRead(GcmMacControl)
  let originalLink = regRead(GcmMacLinkAddress)
  gcmMacLink.control = GcmMacClearDone or (blocks.uint32 shl 16)
  gcmMacLink.source = cast[uint32](buffer)
  fenceIo()
  let active = GcmMacEnable or GcmMacMaskIrq or GcmMacNaturalOrder
  regWrite(GcmMacLinkAddress, cast[uint32](addr gcmMacLink))
  regWrite(GcmMacControl, active)
  regWrite(GcmMacControl, active or GcmMacTrigger)
  var status = regRead(GcmMacControl)
  for _ in 0 ..< GcmPollLimit:
    status = regRead(GcmMacControl)
    if (status and GcmMacBusy) == 0:
      result = true
      break
  if not result: return false
  fenceIo()
  regWrite(GcmMacControl, active or GcmMacClearDone)
  regWrite(GcmMacControl, original)
  regWrite(GcmMacLinkAddress, originalLink)

proc gcmHardware(key: ptr UncheckedArray[uint32]; keyWords: int; h, j0: array[16, uint8];
                 encrypt: bool; length: int; add: ptr UncheckedArray[uint8]; addLen: int;
                 input, output: ptr UncheckedArray[uint8];
                 ghash: var array[16, uint8]): GcmOutcome =
  ## Everything but the two single-block encryptions (H and the tag mask).
  if not dmaVisible(cast[uint](addr gcmAesLink), sizeof(gcmAesLink).uint) or
      not dmaVisible(cast[uint](addr gcmMacLink), sizeof(gcmMacLink).uint) or
      not dmaVisible(cast[uint](addr gcmSource[0]), ChunkBytes) or
      not dmaVisible(cast[uint](addr gcmDestination[0]), ChunkBytes): return gcmFault

  var state: array[4, uint32]       # the GHASH state between borrows
  var counter = 2'u32               # J0 + 1 encrypts the first data block
  var done = 0                      # data bytes handled
  var addDone = 0
  var lengthsDone = false
  result = gcmDone
  while result == gcmDone and not lengthsDone:
    let saved = secIrqSave()
    if not gcmEnginesFree():
      secIrqRestore(saved)
      # Nothing has been written out for a record that has not started.
      return (if done == 0 and addDone == 0: gcmDeferred else: gcmFault)
    copyMem(addr gcmMacLink.key[0], unsafeAddr h[0], 16)
    gcmMacLink.result = state
    var ok = true
    if addDone < addLen:
      let n = min(addLen - addDone, ChunkBytes)
      let blocks = (n + 15) div 16
      zeroMem(addr gcmSource[0], blocks * 16)
      copyMem(addr gcmSource[0], addr add[addDone], n)
      ok = gcmRunHash(addr gcmSource[0], blocks)
      addDone += n
    elif done < length:
      let n = min(length - done, ChunkBytes)
      let blocks = (n + 15) div 16
      zeroMem(addr gcmSource[0], blocks * 16)
      copyMem(addr gcmSource[0], addr input[done], n)
      # Ciphertext is hashed: before decrypting, after encrypting.
      if not encrypt: ok = gcmRunHash(addr gcmSource[0], blocks)
      if ok:
        gcmAesLink.control = gcmKeyMode(keyWords) or GcmAesClearDone or GcmAesCtr
        gcmAesLink.source = cast[uint32](addr gcmSource[0])
        gcmAesLink.destination = cast[uint32](addr gcmDestination[0])
        copyMem(addr gcmAesLink.iv[0], unsafeAddr j0[0], 12)
        gcmAesLink.iv[3] = (counter shl 24) or ((counter and 0xFF00) shl 8) or
                           ((counter shr 8) and 0xFF00) or (counter shr 24)
        for i in 0 ..< gcmAesLink.key.len:
          gcmAesLink.key[i] = if i < keyWords: key[i] else: 0'u32
        ok = gcmRunCtr(blocks)
      if ok and encrypt:
        zeroMem(addr dstBytes[n], blocks * 16 - n)     # the padding is hashed as zeros
        ok = gcmRunHash(addr gcmDestination[0], blocks)
      if ok:
        copyMem(addr output[done], addr gcmDestination[0], n)
        gcmBackend[6] += blocks.uint32
      counter += blocks.uint32
      done += n
    else:
      # The closing block: both lengths in bits, big-endian.
      let addBits = addLen.uint64 * 8
      let dataBits = length.uint64 * 8
      for i in 0 ..< 8:
        srcBytes[i] = uint8(addBits shr (56 - 8 * i))
        srcBytes[8 + i] = uint8(dataBits shr (56 - 8 * i))
      ok = gcmRunHash(addr gcmSource[0], 1)
      lengthsDone = true
    if ok:
      state = gcmMacLink.result
      gcmScrub()
    else:
      # A run that did not finish may still be using the buffers.
      inc gcmBackend[5]
      result = gcmFault
    secIrqRestore(saved)
  if result == gcmDone:
    copyMem(addr ghash[0], addr state[0], 16)

proc gcmContextKey(ctx: ptr AesContext; keyWords: var int): ptr UncheckedArray[uint32] {.inline.} =
  ## An encryption key schedule starts with the raw key (FIPS-197 5.2).
  keyWords = ctx.nr.int - 6
  let offset = ctx.rk_offset.int
  if keyWords notin [4, 6, 8] or offset < 0 or offset + keyWords > ctx.buf.len:
    return nil
  cast[ptr UncheckedArray[uint32]](addr ctx.buf[offset])

proc gcmCompute(ctx: ptr AesContext; encrypt: bool; length: int; iv: ptr UncheckedArray[uint8];
                add: ptr UncheckedArray[uint8]; addLen: int;
                input, output: ptr UncheckedArray[uint8];
                tag: var array[16, uint8]): GcmOutcome =
  var keyWords: int
  let key = gcmContextKey(ctx, keyWords)
  if key == nil: return gcmDeferred
  var zero, h, j0, mask, ghash: array[16, uint8]
  copyMem(addr j0[0], iv, 12)
  j0[15] = 1
  if aesBlock(ctx, addr zero[0], addr h[0]) != 0 or
      aesBlock(ctx, addr j0[0], addr mask[0]) != 0: return gcmDeferred
  result = gcmHardware(key, keyWords, h, j0, encrypt, length, add, addLen, input, output, ghash)
  if result == gcmDone:
    for i in 0 ..< 16: tag[i] = ghash[i] xor mask[i]
  zeroMem(addr h[0], 16)
  zeroMem(addr mask[0], 16)

proc probeGcmBackend(slot, keyWords: int) =
  ## Compare a record that spans two chunks, with associated data and a
  ## partial last block, against the stock implementation, in both
  ## directions and in place, before any caller's data depends on the
  ## engines. Kept to about a kilobyte of stack: this runs on its caller's.
  const
    DataLen = ChunkBytes + 37
    AddLen = 21
  template pattern(i: int): uint8 = uint8(i * 13 + (i shr 5))
  gcmBackend[slot] = 1
  var keyBytes: array[32, uint8]
  var iv: array[12, uint8]
  var add: array[AddLen, uint8]
  var work, expected: array[DataLen, uint8]
  var expectedTag, tag: array[16, uint8]
  for i in 0 ..< keyBytes.len: keyBytes[i] = uint8(0x51 + 11 * i)
  for i in 0 ..< iv.len: iv[i] = uint8(0xC3 xor (29 * i))
  for i in 0 ..< add.len: add[i] = uint8(7 * i + 3)
  for i in 0 ..< work.len: work[i] = pattern(i)
  var schedule: AesContext
  if softwareOneshot(addr keyBytes[0], cuint(32 * keyWords), DataLen, addr iv[0],
                     addr add[0], AddLen, addr work[0], addr expected[0],
                     addr expectedTag[0], addr schedule) != 0:
    gcmBackend[slot] = 3
    return
  template bytes(a: untyped): untyped = cast[ptr UncheckedArray[uint8]](addr a[0])
  case gcmCompute(addr schedule, true, DataLen, bytes(iv), bytes(add), AddLen,
                  bytes(work), bytes(work), tag)
  of gcmDeferred:
    gcmBackend[slot] = 0            # contention is not a failed check
    return
  of gcmFault:
    gcmBackend[slot] = 3
    return
  of gcmDone: discard
  if work != expected or tag != expectedTag:
    gcmBackend[slot] = 3
    return
  if gcmCompute(addr schedule, false, DataLen, bytes(iv), bytes(add), AddLen,
                bytes(work), bytes(work), tag) != gcmDone or tag != expectedTag:
    gcmBackend[slot] = 3
    return
  for i in 0 ..< work.len:
    if work[i] != pattern(i):
      gcmBackend[slot] = 3
      return
  gcmBackend[slot] = 2

proc gcmOneshot(ctx: ptr AesContext; encrypt: bool; length: int; iv: ptr UncheckedArray[uint8];
                ivLen: int; add: ptr UncheckedArray[uint8]; addLen: int;
                input, output: ptr UncheckedArray[uint8]; tag: var array[16, uint8]): cint =
  ## 0: the record was done on the engines. 1: it is left, untouched, to the
  ## software implementation. 2: the engines failed part-way through a record
  ## processed in place, so the input is gone and the caller must fail.
  if ctx == nil or ivLen != 12 or length < 16 or input == nil or output == nil or
      (addLen > 0 and add == nil):
    return 1
  var keyWords: int
  if gcmContextKey(ctx, keyWords) == nil: return 1
  let slot = (keyWords - 4) div 2
  if gcmBackend[slot] == 0: probeGcmBackend(slot, keyWords)
  if gcmBackend[slot] == 2:
    case gcmCompute(ctx, encrypt, length, iv, add, addLen, input, output, tag)
    of gcmDone:
      inc gcmBackend[3]
      return 0
    of gcmDeferred: discard
    of gcmFault:
      # The record may be half written. Software can redo all of it from the
      # input, unless the caller works in place (TLS does).
      for other in 0 .. 2: gcmBackend[other] = 3
      if input == output:
        zeroMem(output, length)
        return 2
  inc gcmBackend[4]
  1
