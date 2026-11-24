# ###########################################################################
#                  MFP: Management Frame Protection
# ###########################################################################

proc mfpIgnoreRxMgmtFrame(desc, param, frameBodyPtr: pointer,
    frameTotalLen: uint16, upload: ptr uint8, flags: ptr uint8,
    generation: uint32; verifiedBip: ptr bool = nil): bool =
  ## True means ignored. The optional verdict reports only a committed BIP check.
  if verifiedBip != nil: verifiedBip[] = false
  template reject(): untyped =
    if upload != nil: upload[] = 0
    return true
  if param == nil or frameBodyPtr == nil:
    reject()
  let mgmt = mfpMgmtFramePolicyView(param)
  let frameCtrl = mgmt.frameCtrl
  let staIdx = mgmt.staIdx
  let bodyOff = mgmt.bodyOffset
  if bodyOff.uint16 >= frameTotalLen:
    reject()
  let frameBytes = cast[ptr UncheckedArray[uint8]](frameBodyPtr)
  let action = frameBytes[bodyOff.int]
  if not mfp_is_robust_frame(frameCtrl.uint32, action.uint32):
    return false
  let vifIdx = mgmt.vifIdx
  if staIdx.int >= STA_INFO_TAB_ENTRIES or vifIdx.int >= MAX_VIFS:
    reject()
  let vif = vifChannelForIdx(vifIdx)
  let keyPtrs = vifKeyPointers(vif)
  if cast[pointer](keyPtrs.groupKeyPtr) == nil:
    # A missing IGTK must not disable group protection for a PMF peer.
    if (mgmt.flags and 1) == 0:
      # Handshake deauth/disassoc remain usable, but robust Actions must wait
      # for key establishment, whether or not their Protected bit is set.
      if (frameCtrl and 0xFC'u16) == 0xD0'u16 and
          (staInfoForIdx(staIdx).capabilityFlags and 8) != 0:
        reject()
      return false
    if (staInfoForIdx(staIdx).capabilityFlags and 8) == 0:
      return false
  # Offset 36 aliases the first destination-address byte in RX status.
  if (mgmt.flags and 1) != 0:
    if (bodyOff.int + 19) >= frameTotalLen.int:
      reject()
    let identity = if desc == nil: default(RxFrameIdentity) else: rxCaptureFrame(desc)
    let rx = cast[ptr RxSwDescView](identity.header)
    if desc != nil and (identity.frame != frameBodyPtr or
        identity.length != frameTotalLen or identity.generation != generation):
      reject()
    template frameCurrent(): bool =
      desc == nil or rxFrameCurrent(identity)
    if not frameCurrent(): reject()
    # The terminal MMIE follows arbitrary subtype-specific fields, not just IEs.
    var receivedMmie: MmIeView
    let mmieOffset = frameTotalLen.uint32 - sizeof(MmIeView).uint32
    if rx == nil:
      discard c_memcpy(addr receivedMmie, ieCursorAfter(frameBodyPtr, mmieOffset.uint),
                        sizeof(receivedMmie).csize_t)
    elif not rxuCopyFrameBytes(rx, mmieOffset, sizeof(receivedMmie).uint32, addr receivedMmie):
      reject()
    if not frameCurrent(): reject()
    let mmie = addr receivedMmie
    if mmie.ie.id != 76 or mmie.ie.len != 16:
      reject()
    let keyId = mmie.keyId
    if keyId < 4 or keyId > 5:
      reject()
    let bipKey = vifKeySlot(vif, keyId.uint)
    let keyIndex = rxMgtKeyIndex(cast[pointer](bipKey))
    if keyIndex < 0:
      reject()
    var receivedIpn = 0'u64
    for i in 0 ..< 6:
      receivedIpn = receivedIpn or (mmie.ipn[i].uint64 shl (8 * i))
    let nextIpn = receivedIpn + 1'u64
    let replay = addr bipKey.replayCounters[0]
    var keyRevision, keyClock: uint64
    block:
      let saved = irqSave()
      defer: irqRestore(saved)
      if bipKey.installed == 0:
        reject()
      if desc != nil and not rxKeyCurrent(desc, cast[pointer](bipKey)):
        reject()
      if not frameCurrent(): reject()
      keyRevision = rxKeyLastChanged[keyIndex]
      keyClock = rxKeyRevision
      let storedNext = replay.pnLow.uint64 or (replay.pnHigh.uint64 shl 32)
      if nextIpn <= storedNext:
        reject()
    let expectedMic = mmie.mic
    var actualMic: uint64
    if rx == nil:
      actualMic = mfp_compute_bip(cast[pointer](bipKey), frameBodyPtr,
                                  frameTotalLen.uint32, bodyOff.uint32)
    elif not mfpComputeRxBip(cast[pointer](bipKey), frameBodyPtr,
        frameTotalLen.uint32, bodyOff.uint32, rx, actualMic):
      reject()
    var difference = 0'u8
    for i in 0 ..< 8:
      difference = difference or (expectedMic[i] xor
        ((actualMic shr (8 * i)) and 0xFF'u64).uint8)
    if difference != 0:
      reject()
    # MIC work may overlap key replacement or another accepted frame.
    block:
      let saved = irqSave()
      defer: irqRestore(saved)
      if bipKey.installed == 0 or rxKeyRevision < keyClock or
          rxKeyLastChanged[keyIndex] != keyRevision:
        reject()
      if desc != nil and not rxKeyCurrent(desc, cast[pointer](bipKey)):
        reject()
      if not frameCurrent(): reject()
      let storedNext = replay.pnLow.uint64 or (replay.pnHigh.uint64 shl 32)
      if nextIpn <= storedNext:
        reject()
      replay.pnLow = (nextIpn and 0xFFFFFFFF'u64).uint32
      replay.pnHigh = (nextIpn shr 32).uint32
    if verifiedBip != nil: verifiedBip[] = true
    return false
  else:
    let sta = staInfoForIdx(staIdx)
    if (sta.capabilityFlags and 0x08) == 0 or (frameCtrl and 0x4000) != 0:
      return false
    let subtypeBits = frameCtrl and 0xFC'u16
    if subtypeBits notin [0xA0'u16, 0xC0'u16] or
        bodyOff.int + 2 > frameTotalLen.int:
      reject()
    let reason = action.uint16 or (frameBytes[bodyOff.int + 1].uint16 shl 8)
    if reason notin [6'u16, 7'u16]:
      reject()
    if flags != nil: flags[] = flags[] or 1'u8
    return false

proc mfp_ignore_mgmt_frame*(param: pointer, frameBodyPtr: pointer,
    frameTotalLen: uint16, upload: ptr uint8, flags: ptr uint8): bool {.exportc, cdecl.} =
  mfpIgnoreRxMgmtFrame(nil, param, frameBodyPtr, frameTotalLen, upload, flags, 0)

proc mfp_protect_mgmt_frame*(frameDesc: pointer, fc: uint32, action: uint32 = 0): uint32 {.exportc, cdecl, noinline.} =
  ## Return 0 for no protection, 1 for pairwise CCMP, or 2 for group BIP.
  let desc = hostTxDescAt(frameDesc)
  let vifIdx = desc.vifIdx
  if vifIdx.int >= MAX_VIFS:
    return 0
  let vif = vifChannelForIdx(vifIdx)
  let secCtx = cast[pointer](vifKeyPointers(vif).groupKeyPtr)
  if not mfp_is_robust_frame(fc, action):
    return 0
  let staIdx = desc.staInfoIdx
  if staIdx.int >= STA_INFO_TAB_ENTRIES:
    return 0
  let sta = staInfoForIdx(staIdx)
  if (sta.macAddr[0] and 1) != 0:
    return (if secCtx == nil: 0'u32 else: 2'u32)
  # Robust Actions require pairwise protection even before an IGTK exists.
  # The caller cancels the frame if the pairwise header cannot be built.
  if secCtx == nil and (fc and 0xFC'u32) != 0xD0'u32:
    return 0
  return (sta.capabilityFlags shr 3) and 1

proc mfp_add_mgmt_mic*(frameDesc: pointer, frame: pointer, frameLen: uint32): uint32 {.exportc, cdecl.} =
  ## Append an 18-byte MMIE. The caller supplies a frame buffer with tailroom.
  ## Return zero without changing the frame if no IPN can be reserved.
  ## Key/lease changes during MIC work also fail; a reserved IPN is not reused.
  if frameDesc == nil or frame == nil or frameLen < 24 or frameLen > 65517:
    return 0
  let desc = hostTxDescAt(frameDesc)
  let vifIdx = desc.vifIdx
  if vifIdx.int >= MAX_VIFS:
    return 0
  let vif = vifChannelForIdx(vifIdx)
  let staIdx = desc.staInfoIdx
  let mmie = mmieAt(ieCursorAfter(frame, frameLen.uint))
  var secCtx: pointer
  var keySnapshot: VifKeySlotView
  var keyId: uint16
  var keyIndex = -1
  var keyRevision, keyClock: uint64
  var frameLease: uint32
  var nextPn: uint64
  template frameCurrent(): bool =
    txlFrameLeaseMatches(desc, frameLease) and txlFrameSessionCurrent(desc) and
      desc.vifIdx == vifIdx and desc.staInfoIdx == staIdx
  block:
    let saved = irqSave()
    {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
    defer:
      {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
      irqRestore(saved)
    frameLease = txlFrameLeaseToken(desc)
    if not frameCurrent():
      return 0
    secCtx = cast[pointer](vifKeyPointers(vif).groupKeyPtr)
    if secCtx == nil:
      return 0
    let sec = cast[ptr VifKeySlotView](secCtx)
    keyId = sec.staIdx.uint16
    if sec.installed == 0 or sec.cipherType != 5 or keyId notin [4'u16, 5'u16]:
      return 0
    if secCtx != cast[pointer](vifKeySlot(vif, keyId.uint)):
      return 0
    keyIndex = rxMgtKeyIndex(secCtx)
    if keyIndex < 0:
      return 0
    let currentPn = sec.pnLow.uint64 or (sec.pnHigh.uint64 shl 32)
    # The on-wire IPN is six bytes, even though storage is eight bytes.
    if currentPn >= 0xFFFFFFFFFFFF'u64:
      return 0
    if not txSecurityBind(desc, sec, true):
      return 0
    nextPn = currentPn + 1'u64
    sec.pnLow = (nextPn and 0xFFFFFFFF'u64).uint32
    sec.pnHigh = (nextPn shr 32).uint32
    keySnapshot.keyMaterial = sec.keyMaterial
    keyRevision = rxKeyLastChanged[keyIndex]
    keyClock = rxKeyRevision
    mmie.ie.id = 76
    mmie.ie.len = 16
    mmie.keyId = keyId
    for ipnByteIndex in 0 ..< 6:
      mmie.ipn[ipnByteIndex] = ((nextPn shr (ipnByteIndex * 8)) and 255).uint8
    mmie.mic = default(typeof(mmie.mic))
  let mic = mfp_compute_bip(addr keySnapshot, frame, frameLen + 18, 24)
  block:
    let saved = irqSave()
    {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
    defer:
      {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
      irqRestore(saved)
    if not frameCurrent() or cast[pointer](vifKeyPointers(vif).groupKeyPtr) != secCtx:
      return 0
    let sec = cast[ptr VifKeySlotView](secCtx)
    if sec.installed == 0 or sec.cipherType != 5 or sec.staIdx.uint16 != keyId or
        rxKeyRevision < keyClock or rxKeyLastChanged[keyIndex] != keyRevision:
      return 0
    for micByteIndex in 0 ..< 8:
      mmie.mic[micByteIndex] = ((mic shr (micByteIndex * 8)) and 255).uint8
  return 18

# ###########################################################################
#                  AES Encryption (mfp_bip.o)
# ###########################################################################

# AES S-Box
const AES_SBOX = [
  0x63'u8,0x7c,0x77,0x7b,0xf2,0x6b,0x6f,0xc5,0x30,0x01,0x67,0x2b,0xfe,0xd7,0xab,0x76,
  0xca,0x82,0xc9,0x7d,0xfa,0x59,0x47,0xf0,0xad,0xd4,0xa2,0xaf,0x9c,0xa4,0x72,0xc0,
  0xb7,0xfd,0x93,0x26,0x36,0x3f,0xf7,0xcc,0x34,0xa5,0xe5,0xf1,0x71,0xd8,0x31,0x15,
  0x04,0xc7,0x23,0xc3,0x18,0x96,0x05,0x9a,0x07,0x12,0x80,0xe2,0xeb,0x27,0xb2,0x75,
  0x09,0x83,0x2c,0x1a,0x1b,0x6e,0x5a,0xa0,0x52,0x3b,0xd6,0xb3,0x29,0xe3,0x2f,0x84,
  0x53,0xd1,0x00,0xed,0x20,0xfc,0xb1,0x5b,0x6a,0xcb,0xbe,0x39,0x4a,0x4c,0x58,0xcf,
  0xd0,0xef,0xaa,0xfb,0x43,0x4d,0x33,0x85,0x45,0xf9,0x02,0x7f,0x50,0x3c,0x9f,0xa8,
  0x51,0xa3,0x40,0x8f,0x92,0x9d,0x38,0xf5,0xbc,0xb6,0xda,0x21,0x10,0xff,0xf3,0xd2,
  0xcd,0x0c,0x13,0xec,0x5f,0x97,0x44,0x17,0xc4,0xa7,0x7e,0x3d,0x64,0x5d,0x19,0x73,
  0x60,0x81,0x4f,0xdc,0x22,0x2a,0x90,0x88,0x46,0xee,0xb8,0x14,0xde,0x5e,0x0b,0xdb,
  0xe0,0x32,0x3a,0x0a,0x49,0x06,0x24,0x5c,0xc2,0xd3,0xac,0x62,0x91,0x95,0xe4,0x79,
  0xe7,0xc8,0x37,0x6d,0x8d,0xd5,0x4e,0xa9,0x6c,0x56,0xf4,0xea,0x65,0x7a,0xae,0x08,
  0xba,0x78,0x25,0x2e,0x1c,0xa6,0xb4,0xc6,0xe8,0xdd,0x74,0x1f,0x4b,0xbd,0x8b,0x8a,
  0x70,0x3e,0xb5,0x66,0x48,0x03,0xf6,0x0e,0x61,0x35,0x57,0xb9,0x86,0xc1,0x1d,0x9e,
  0xe1,0xf8,0x98,0x11,0x69,0xd9,0x8e,0x94,0x9b,0x1e,0x87,0xe9,0xce,0x55,0x28,0xdf,
  0x8c,0xa1,0x89,0x0d,0xbf,0xe6,0x42,0x68,0x41,0x99,0x2d,0x0f,0xb0,0x54,0xbb,0x16,
]

const AES_RCON = [
  0x01'u32, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1b, 0x36,
]

proc aes_encrypt_block*(roundKeys: pointer, state: pointer) {.exportc, cdecl.} =
  ## AES-128 block encryption (in-place on 16-byte state).
  ## From blob (mfp_bip.o, 261 instrs): standard AES-128 with 10 rounds.
  ## SubBytes, ShiftRows, MixColumns (9 rounds), final round no MixColumns.
  ## Blob calls add_round_key as a separate function (not inlined).
  let stateBytes = cast[ptr array[16, uint8]](state)

  # Blob structure: initial add_round_key, 9-round loop with MixColumns +
  # add_round_key, then final round 10 (no MixColumns) tail-calling
  # add_round_key — 3 separate call sites to match the blob.
  template subBytesShiftRows(shifted: var array[16, uint8]) =
    var substituted {.noinit.}: array[16, uint8]
    for substitutionByteIndex in 0 ..< 16:
      substituted[substitutionByteIndex] = AES_SBOX[stateBytes[substitutionByteIndex].int]
    shifted[0] = substituted[0]; shifted[4] = substituted[4]; shifted[8] = substituted[8]; shifted[12] = substituted[12]
    shifted[1] = substituted[5]; shifted[5] = substituted[9]; shifted[9] = substituted[13]; shifted[13] = substituted[1]
    shifted[2] = substituted[10]; shifted[6] = substituted[14]; shifted[10] = substituted[2]; shifted[14] = substituted[6]
    shifted[3] = substituted[15]; shifted[7] = substituted[3]; shifted[11] = substituted[7]; shifted[15] = substituted[11]

  template xtime(x: uint8): uint8 =
    let xv = x
    let doubled = xv.uint16 shl 1
    (if (xv and 0x80'u8) != 0: (doubled xor 0x1B).uint8 else: doubled.uint8)

  add_round_key(roundKeys, state, 0)

  for round in 1 .. 9:
    var shifted {.noinit.}: array[16, uint8]
    subBytesShiftRows(shifted)
    # MixColumns
    for col in 0 ..< 4:
      let columnByteOffset = col * 4
      let col0 = shifted[columnByteOffset]
      let col1 = shifted[columnByteOffset + 1]
      let col2 = shifted[columnByteOffset + 2]
      let col3 = shifted[columnByteOffset + 3]
      stateBytes[columnByteOffset] =
        xtime(col0) xor xtime(col1) xor col1 xor col2 xor col3
      stateBytes[columnByteOffset + 1] =
        col0 xor xtime(col1) xor xtime(col2) xor col2 xor col3
      stateBytes[columnByteOffset + 2] =
        col0 xor col1 xor xtime(col2) xor xtime(col3) xor col3
      stateBytes[columnByteOffset + 3] =
        xtime(col0) xor col0 xor col1 xor col2 xor xtime(col3)
    add_round_key(roundKeys, state, round.uint32)

  # Round 10: SubBytes + ShiftRows (no MixColumns) then tail add_round_key
  var shifted {.noinit.}: array[16, uint8]
  subBytesShiftRows(shifted)
  for finalStateByteIndex in 0 ..< 16:
    stateBytes[finalStateByteIndex] = shifted[finalStateByteIndex]
  add_round_key(roundKeys, state, 10)

proc aes128_expand_key*(key: pointer; roundKeys: pointer) {.exportc, cdecl.} =
  let rk = cast[ptr UncheckedArray[uint8]](roundKeys)
  let keyBytes = cast[ptr UncheckedArray[uint8]](key)
  for keyByteIndex in 0 ..< 16:
    rk[keyByteIndex] = keyBytes[keyByteIndex]
  for roundKeyWordIndex in 4'u32 ..< 44:
    var scheduleWord: array[4, uint8]
    let previousWordByteOffset = (roundKeyWordIndex - 1) * 4
    for wordByteIndex in 0 ..< 4:
      scheduleWord[wordByteIndex] =
        rk[previousWordByteOffset.int + wordByteIndex]
    if (roundKeyWordIndex mod 4) == 0:
      let rotatedFirstByte = scheduleWord[0]
      scheduleWord[0] =
        AES_SBOX[scheduleWord[1].int] xor
          cast[uint8](AES_RCON[(roundKeyWordIndex div 4 - 1).int])
      scheduleWord[1] = AES_SBOX[scheduleWord[2].int]
      scheduleWord[2] = AES_SBOX[scheduleWord[3].int]
      scheduleWord[3] = AES_SBOX[rotatedFirstByte.int]
    let roundKeyWordByteOffset = roundKeyWordIndex * 4
    let previousRoundKeyWordByteOffset = (roundKeyWordIndex - 4) * 4
    for wordByteIndex in 0 ..< 4:
      rk[roundKeyWordByteOffset.int + wordByteIndex] =
        rk[previousRoundKeyWordByteOffset.int + wordByteIndex] xor
          scheduleWord[wordByteIndex]

type AesCmacContext = object
  roundKeys: array[176, uint8]
  subkey, state, pending: array[16, uint8]
  pendingLen: int

proc aesCmacInit(ctx: var AesCmacContext; key: pointer) =
  ctx = default(AesCmacContext)
  aes128_expand_key(key, addr ctx.roundKeys[0])
  aes_encrypt_block(addr ctx.roundKeys[0], addr ctx.subkey[0])
  aes_cmac_shift_sub_key(addr ctx.subkey[0])

proc aesCmacUpdate(ctx: var AesCmacContext; data: pointer; length: uint32) =
  let bytes = cast[ptr UncheckedArray[uint8]](data)
  var offset = 0'u32
  while offset < length:
    # A full pending block may be the final block, so encrypt it only when
    # another input byte arrives, even across separate update calls.
    if ctx.pendingLen == 16:
      for i in 0 ..< 16:
        ctx.state[i] = ctx.state[i] xor ctx.pending[i]
      aes_encrypt_block(addr ctx.roundKeys[0], addr ctx.state[0])
      ctx.pendingLen = 0
    let count = min((16 - ctx.pendingLen).uint32, length - offset).int
    for i in 0 ..< count:
      ctx.pending[ctx.pendingLen + i] = bytes[offset + i.uint32]
    ctx.pendingLen += count
    offset += count.uint32

proc aesCmacFinish(ctx: var AesCmacContext; mac: pointer) =
  if ctx.pendingLen != 16:
    aes_cmac_shift_sub_key(addr ctx.subkey[0])
  for i in 0 ..< 16:
    let finalByte =
      if i < ctx.pendingLen: ctx.pending[i]
      elif i == ctx.pendingLen: 0x80'u8
      else: 0'u8
    ctx.state[i] = ctx.state[i] xor finalByte xor ctx.subkey[i]
  aes_encrypt_block(addr ctx.roundKeys[0], addr ctx.state[0])
  discard c_memcpy(mac, addr ctx.state[0], 16.csize_t)

proc mfp_compute_bip*(key: pointer, frame: pointer, frameLen: uint32,
    headerLen: uint32): uint64 {.exportc, cdecl.} =
  ## BIP-CMAC-128: masked FC || A1 || A2 || A3 || body, with MIC zeroed.
  if key == nil or frame == nil or headerLen < 24 or headerLen > frameLen or
      frameLen - headerLen < 18:
    return 0
  let bytes = cast[ptr UncheckedArray[uint8]](frame)
  let slot = cast[ptr VifKeySlotView](key)
  var aad: array[20, uint8]
  aad[0] = bytes[0]
  aad[1] = bytes[1] and 0xC7'u8
  for i in 0 ..< 18:
    aad[i + 2] = bytes[i + 4]
  var ctx: AesCmacContext
  aesCmacInit(ctx, addr slot.keyMaterial[0])
  aesCmacUpdate(ctx, addr aad[0], aad.len.uint32)
  aesCmacUpdate(ctx, addr bytes[headerLen], frameLen - headerLen - 8)
  var zeroMic: array[8, uint8]
  aesCmacUpdate(ctx, addr zeroMic[0], zeroMic.len.uint32)
  var mac: array[16, uint8]
  aesCmacFinish(ctx, addr mac[0])
  for i in 0 ..< 8:
    result = result or (mac[i].uint64 shl (8 * i))

proc mfpComputeRxBip(key, frame: pointer; frameLen, headerLen: uint32;
    rx: ptr RxSwDescView; mic: var uint64): bool =
  if key == nil or frame == nil or rx == nil or headerLen < 24 or headerLen > frameLen or
      frameLen - headerLen < 18:
    return false
  var header: array[22, uint8]
  if not rxuCopyFrameBytes(rx, 0, header.len.uint32, addr header[0]):
    return false
  var aad: array[20, uint8]
  aad[0] = header[0]
  aad[1] = header[1] and 0xC7'u8
  for i in 0 ..< 18:
    aad[i + 2] = header[i + 4]
  var ctx: AesCmacContext
  aesCmacInit(ctx, addr cast[ptr VifKeySlotView](key).keyMaterial[0])
  aesCmacUpdate(ctx, addr aad[0], aad.len.uint32)
  var chunk: array[64, uint8]
  var offset = headerLen
  let bodyEnd = frameLen - 8
  while offset < bodyEnd:
    let count = min(chunk.len.uint32, bodyEnd - offset)
    if not rxuCopyFrameBytes(rx, offset, count, addr chunk[0]):
      return false
    aesCmacUpdate(ctx, addr chunk[0], count)
    offset += count
  # Mask the MIC in local state; never write into the received frame.
  var zeroMic: array[8, uint8]
  aesCmacUpdate(ctx, addr zeroMic[0], zeroMic.len.uint32)
  var mac: array[16, uint8]
  aesCmacFinish(ctx, addr mac[0])
  mic = 0
  for i in 0 ..< 8:
    mic = mic or (mac[i].uint64 shl (8 * i))
  true

proc aes128_encrypt_copy(roundKeys: pointer; input: ptr array[16, uint8];
                         output: ptr array[16, uint8]) {.inline.} =
  for aesCopyByteIndex in 0 ..< 16:
    output[aesCopyByteIndex] = input[aesCopyByteIndex]
  aes_encrypt_block(roundKeys, output)

proc ccmpLoadLe16(bytes: ptr UncheckedArray[uint8]; off: int): uint16 {.inline.} =
  bytes[off].uint16 or (bytes[off + 1].uint16 shl 8)

proc ccmpPutLe16(dst: var array[30, uint8]; off: int; value: uint16) {.inline.} =
  dst[off] = (value and 0xFF'u16).uint8
  dst[off + 1] = (value shr 8).uint8

proc ccmpBuildAadNonce(hdr: pointer; data: pointer;
                       aad: var array[30, uint8]; aadLen: var uint32;
                       nonce: var array[13, uint8]) =
  let h = cast[ptr UncheckedArray[uint8]](hdr)
  let d = cast[ptr UncheckedArray[uint8]](data)
  var fc = ccmpLoadLe16(h, 0)
  let stype = (fc shr 4) and 0x0F'u16
  let ftype = (fc shr 2) and 0x03'u16
  let addr4 = (fc and 0x0300'u16) == 0x0300'u16
  var qos = false
  for i in 0 ..< 30:
    aad[i] = 0
  for i in 0 ..< 13:
    nonce[i] = 0

  if ftype == 2'u16:
    fc = fc and not 0x0070'u16
    if (stype and 0x08'u16) != 0:
      qos = true
      fc = fc and not 0x8000'u16
      let qosOff = 24 + (if addr4: 6 else: 0)
      nonce[0] = h[qosOff] and 0x0F'u8
  elif ftype == 0'u16:
    nonce[0] = nonce[0] or 0x10'u8

  fc = fc and not (0x0800'u16 or 0x1000'u16 or 0x2000'u16)
  fc = fc or 0x4000'u16
  ccmpPutLe16(aad, 0, fc)
  var pos = 2
  for i in 0 ..< 18:
    aad[pos + i] = h[4 + i]
  pos += 18
  let seq = ccmpLoadLe16(h, 22) and not 0xFFF0'u16
  ccmpPutLe16(aad, pos, seq)
  pos += 2
  if addr4:
    for i in 0 ..< 6:
      aad[pos + i] = h[24 + i]
    pos += 6
  if qos:
    let qosOff = 24 + (if addr4: 6 else: 0)
    aad[pos] = h[qosOff] and not (0x70'u8 or 0x80'u8)
    aad[pos + 1] = 0
    pos += 2
  aadLen = pos.uint32

  for i in 0 ..< 6:
    nonce[1 + i] = h[10 + i]
  nonce[7] = d[7]
  nonce[8] = d[6]
  nonce[9] = d[5]
  nonce[10] = d[4]
  nonce[11] = d[1]
  nonce[12] = d[0]

proc ccmpXorEncryptBlock(roundKeys: pointer; x: var array[16, uint8];
                         macBlock: var array[16, uint8]) {.inline.} =
  for i in 0 ..< 16:
    x[i] = x[i] xor macBlock[i]
  aes_encrypt_block(roundKeys, addr x[0])

proc ccmpCtrBlock(nonce: var array[13, uint8]; counter: uint16;
                  outBlock: var array[16, uint8]) {.inline.} =
  outBlock[0] = 0x01'u8
  for i in 0 ..< 13:
    outBlock[1 + i] = nonce[i]
  outBlock[14] = (counter shr 8).uint8
  outBlock[15] = (counter and 0xFF'u16).uint8

proc nim_ccmp_decrypt*(tk: pointer; hdr: pointer; data: pointer;
                       dataLen: uint32; outPlain: pointer;
                       outLen: ptr uint32): bool =
  if tk == nil or hdr == nil or data == nil or outPlain == nil or
      outLen == nil:
    return false
  if dataLen < 16'u32:
    return false
  let mlen = dataLen - 16'u32
  let d = cast[ptr UncheckedArray[uint8]](data)
  let plain = cast[ptr UncheckedArray[uint8]](outPlain)
  var roundKeys {.noinit.}: array[176, uint8]
  aes128_expand_key(tk, addr roundKeys[0])

  var aad {.noinit.}: array[30, uint8]
  var nonce {.noinit.}: array[13, uint8]
  var aadLen: uint32 = 0
  ccmpBuildAadNonce(hdr, data, aad, aadLen, nonce)

  var ctr {.noinit.}: array[16, uint8]
  var stream {.noinit.}: array[16, uint8]
  var pos = 0'u32
  var counter = 1'u16
  while pos < mlen:
    ccmpCtrBlock(nonce, counter, ctr)
    aes128_encrypt_copy(addr roundKeys[0], addr ctr, addr stream)
    let chunk =
      if mlen - pos >= 16'u32: 16'u32
      else: mlen - pos
    for i in 0 ..< chunk.int:
      plain[pos + i.uint32] = d[8 + pos + i.uint32] xor stream[i]
    pos += chunk
    inc counter

  var x {.noinit.}: array[16, uint8]
  var macBlock {.noinit.}: array[16, uint8]
  for i in 0 ..< 16:
    x[i] = 0
    macBlock[i] = 0
  macBlock[0] = 0x59'u8
  for i in 0 ..< 13:
    macBlock[1 + i] = nonce[i]
  macBlock[14] = (mlen shr 8).uint8
  macBlock[15] = (mlen and 0xFF'u32).uint8
  ccmpXorEncryptBlock(addr roundKeys[0], x, macBlock)

  if aadLen != 0:
    for i in 0 ..< 16:
      macBlock[i] = 0
    macBlock[0] = (aadLen shr 8).uint8
    macBlock[1] = (aadLen and 0xFF'u32).uint8
    var aadPos = 0'u32
    var blockPos = 2
    while aadPos < aadLen:
      macBlock[blockPos] = aad[aadPos.int]
      inc aadPos
      inc blockPos
      if blockPos == 16:
        ccmpXorEncryptBlock(addr roundKeys[0], x, macBlock)
        for i in 0 ..< 16:
          macBlock[i] = 0
        blockPos = 0
    if blockPos != 0:
      ccmpXorEncryptBlock(addr roundKeys[0], x, macBlock)

  pos = 0
  while pos < mlen:
    for i in 0 ..< 16:
      macBlock[i] = 0
    let chunk =
      if mlen - pos >= 16'u32: 16'u32
      else: mlen - pos
    for i in 0 ..< chunk.int:
      macBlock[i] = plain[pos + i.uint32]
    ccmpXorEncryptBlock(addr roundKeys[0], x, macBlock)
    pos += chunk

  ccmpCtrBlock(nonce, 0'u16, ctr)
  aes128_encrypt_copy(addr roundKeys[0], addr ctr, addr stream)
  var micOk = true
  for i in 0 ..< 8:
    let expected = x[i] xor stream[i]
    if expected != d[8 + mlen + i.uint32]:
      micOk = false
  if not micOk:
    return false
  outLen[] = mlen
  true

# ###########################################################################
#                  HSU: Hardware Security Unit
# ###########################################################################

var hsuMichaelCtx: array[16, uint8]

proc hsu_init*() {.exportc, cdecl.} =
  ## Initialize hardware security unit.
  discard c_memset(addr hsuMichaelCtx[0], 0, hsuMichaelCtx.len.csize_t)

proc hsu_aes_cmac*(key: pointer, msg: pointer, msgLen: uint32, mac: pointer) {.exportc, cdecl.} =
  ## One-shot wrapper over the same streaming core used by BIP.
  var ctx: AesCmacContext
  aesCmacInit(ctx, key)
  aesCmacUpdate(ctx, msg, msgLen)
  aesCmacFinish(ctx, mac)

proc hsu_michael_init*(key: pointer) {.exportc, cdecl.} =
  ## Initialize the HSU Michael MIC streaming context with an 8-byte key.
  discard c_memset(addr hsuMichaelCtx[0], 0, hsuMichaelCtx.len.csize_t)
  if key == nil:
    return
  discard c_memcpy(addr hsuMichaelCtx[0], key, 8.csize_t)

proc hsu_michael_calc*(data: pointer, dataLen: uint32) {.exportc, cdecl.} =
  ## Process data for the HSU Michael MIC streaming context.
  if data == nil or dataLen == 0:
    return
  me_mic_calc(addr hsuMichaelCtx[0], data, dataLen)

proc hsu_michael_end*(mic: pointer) {.exportc, cdecl.} =
  ## Finalize the HSU Michael MIC and write the 8-byte result.
  if mic == nil:
    return
  me_mic_end(addr hsuMichaelCtx[0])
  discard c_memcpy(mic, addr hsuMichaelCtx[0], 8.csize_t)
