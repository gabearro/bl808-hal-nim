# ###########################################################################
#                  MFP: Management Frame Protection
# ###########################################################################

proc mfp_ignore_mgmt_frame*(param: pointer): bool {.exportc, cdecl.} =
  ## Check if a management frame should be ignored (MFP/PMF policy).
  ##
  ## From blob disassembly (172 instructions):
  ## ABI: a0=rxu_mgt_ind payload, a1=frame_body_ptr, a2=frame_total_len, a3=out_flag_ptr
  ## Hidden args: a1=frame body pointer, a2=frame total length, a3=output flag pointer
  ##
  ## param layout:
  ##   offset 0:  uint16 - frame_ctrl (FC field)
  ##   offset 8:  uint8  - body_offset (IE start within frame)
  ##   offset 9:  uint8  - sta_idx (0xFF = unknown)
  ##   offset 10: uint8  - vif_idx (0xFF = unknown)
  ##   offset 36: uint8  - flags (bit 0 = protected)
  ##
  ## Returns: true if frame should be processed, false if should be ignored.
  let mgmt = mfpMgmtFramePolicyView(param)
  let frameCtrl = mgmt.frameCtrl
  let staIdx = mgmt.staIdx
  let bodyOff = mgmt.bodyOffset

  # Capture hidden ABI args (a1=frame_body, a2=frame_len, a3=out_flag)
  var frameBodyPtr {.noinit.}: pointer
  var frameTotalLen {.noinit.}: uint32
  var outFlagPtr {.noinit.}: ptr uint8
  {.emit: ["""
  register void* _fb __asm__("a1");
  register unsigned int _fl __asm__("a2");
  register unsigned char* _of __asm__("a3");
  """, frameBodyPtr, " = _fb; ", frameTotalLen, " = _fl; ", outFlagPtr, " = _of;"].}

  # Blob: pre-validate with mfp_is_robust_frame(frameCtrl, subtype)
  # T-Head custom insn extracts subtype field; we use standard shift/mask
  let subtypeField = (frameCtrl shr 4) and 0x0F'u16
  let isRobust = mfp_is_robust_frame(frameCtrl.uint32, subtypeField.uint32)
  if not isRobust:
    # Blob returns immediately for ordinary management frames without
    # touching the caller's acceptance byte.
    return false

  # Check valid STA and VIF indices
  let vifIdx = mgmt.vifIdx
  if staIdx == 0xFF'u8:
    if outFlagPtr != nil:
      outFlagPtr[] = 0
    return false
  if vifIdx == 0xFF'u8:
    if outFlagPtr != nil:
      outFlagPtr[] = 0
    return false

  # Check VIF security context.
  let vif = vifChannelForIdx(vifIdx)
  let keyPtrs = vifKeyPointers(vif)
  let secCtxPtr = keyPtrs.groupKeyPtr
  if secCtxPtr == 0:
    if outFlagPtr != nil:
      outFlagPtr[] = 0
    return false

  let flags36 = mgmt.flags

  if (flags36 and 1) != 0:
    # Protected frame: validate MMIE replay counter (BIP)
    # Check minimum frame length: bodyOff + 19 bytes minimum
    if (bodyOff.int + 19) >= frameTotalLen.int:
      if outFlagPtr != nil:
        outFlagPtr[] = 0
      return false

    # Compute IE search region: body starts at frame_body + bodyOff + 2, length = frameTotalLen - bodyOff - 2
    let ieSearchLen = frameTotalLen.int - bodyOff.int - 2
    let ieSearchStart = ieCursorAfter(frameBodyPtr, bodyOff.uint + 2)

    # Find MMIE (IE_ID=76) in the frame
    let mmiePtr = mac_ie_find(ieSearchStart, ieSearchLen.uint32, 76)
    if mmiePtr == nil:
      if outFlagPtr != nil:
        outFlagPtr[] = 0
      return false

    let mmie = mmieAt(mmiePtr)
    # MMIE structure: [0]=IE_ID(76), [1]=len(16), [2..3]=keyID, [4..9]=IPN, [10..17]=MIC
    # Blob: reads keyID from MMIE[2..3] as LE16, checks (keyID - 4) <= 1
    # Valid MMIE keyIDs are 4 and 5 (IGTK key slots)
    let keyId = mmie.keyId
    if (keyId - 4) > 1:
      if outFlagPtr != nil:
        outFlagPtr[] = 0
      return false

    # Look up IGTK key in VIF entry: offset 160 * keyIdAdj + sec base + 683
    # Blob: li a5,160; madd a5,s8,s3,a5 -> offset = keyIdAdj * 160 + vifBase + 683
    let keyIdAdj = keyId - 4  # 0 or 1
    if vifKeySlot(vif, keyIdAdj.uint).installed == 0:
      if outFlagPtr != nil:
        outFlagPtr[] = 0
      return false

    # Extract IPN (6 bytes) from MMIE[4..9]
    let ipnLo = mmie.ipn[1].uint16 or (mmie.ipn[0].uint16 shl 8)
    let ipnMid = mmie.ipn[3].uint16 or (mmie.ipn[2].uint16 shl 8)
    let ipnByte4 = mmie.ipn[4].uint32
    let ipnByte5 = mmie.ipn[5].uint32

    # Build 48-bit IPN as two 32-bit words
    let ipnW0 = ipnLo.uint32 or (ipnMid.uint32 shl 16)
    let ipnW1 = ipnByte4 or (ipnByte5 shl 8)

    # Compare against stored IPN at VIF secCtx offsets 528/532
    let bipKey = vifKeySlot(vif, 0)
    let storedIpnLo = bipKey.replayCounters[0].pnLow
    let storedIpnHi = bipKey.replayCounters[0].pnHigh

    # 48-bit comparison: new IPN must be > stored IPN
    if ipnW1 < storedIpnHi:
      if outFlagPtr != nil:
        outFlagPtr[] = 0
      return false
    if ipnW1 == storedIpnHi and ipnW0 <= storedIpnLo:
      if outFlagPtr != nil:
        outFlagPtr[] = 0
      return false

    # IPN is fresh: update stored IPN
    bipKey.replayCounters[0].pnLow = ipnW0
    bipKey.replayCounters[0].pnHigh = ipnW1

    # Compute and verify BIP MIC
    # Blob: addi a0,a0,528 -> key is at vifEntry+528 (IGTK key in sec context)
    let micResult = mfp_compute_bip(
      cast[pointer](bipKey),  # IGTK key at vif+528
      frameBodyPtr, frameTotalLen, bodyOff.uint32)
    # Compare 8-byte MIC at MMIE[10..17]
    let expectedMic = mmieMicWords(mmie)
    let expectedMicLo = expectedMic[0]
    let expectedMicHi = expectedMic[1]
    let resultLo = (micResult and 0xFFFFFFFF'u64).uint32
    let resultHi = (micResult shr 32).uint32
    if resultLo != expectedMicLo or resultHi != expectedMicHi:
      if outFlagPtr != nil:
        outFlagPtr[] = 0
      return false

    return true
  else:
    # Unprotected frame: check if PMF requires protection
    let sta = staInfoForIdx(staIdx)
    if (sta.capabilityFlags and 0x08) == 0:
      if outFlagPtr != nil:
        outFlagPtr[] = 0
      return false

    # PMF enabled: check if group-addressed (bit 14 of FC)
    if (frameCtrl and 0x4000'u16) != 0:
      if outFlagPtr != nil:
        outFlagPtr[] = 0
      return false

    # Check frame subtype: deauth=0xC0, disassoc=0xA0 are robust mgmt
    let subtypeBits = (frameCtrl and 0xFC'u16).uint8
    # Blob: (subtypeBits - 0xA0) with bit 5 masked -> check both 0xA0 and 0xC0
    let adjusted = (subtypeBits.int - 160) and (not 0x20)
    if adjusted != 0:
      if outFlagPtr != nil:
        outFlagPtr[] = 0
      return false

    # Unprotected robust mgmt frame when PMF required -> accept with SA query flag
    if outFlagPtr != nil:
      outFlagPtr[] = 1  # signal SA query needed
    return true

proc mfp_protect_mgmt_frame*(frameDesc: pointer, fc: uint32, action: uint32 = 0): uint32 {.exportc, cdecl, noinline.} =
  ## Blob (110 bytes, 41 instrs, mfp.c.o):
  ##   a0 = frameDesc, a1 = fc, a2 = action category
  ##   vifIdx = frameDesc[47]
  ##   secCtx = vif_info_tab[vifIdx].secCtx (at +1484)
  ##   if secCtx == NULL: return 0
  ##   if !mfp_is_robust_frame(fc, action): return 0
  ##   staIdx = frameDesc[49]
  ##   if staIdx == 0xFF: return 2                     # broadcast → BIP
  ##   if (sta_info_tab[staIdx].flags308 & 1) == 0: return 2  # no PMF cap → BIP
  ##   return CCMP_from_vif_crypto (via T-Head bit extract on sta[308])
  {.emit: ["asm volatile(\"\" ::: \"memory\");"].}
  let desc = hostTxDescAt(frameDesc)
  let vifIdx = desc.vifIdx
  let vif = vifChannelForIdx(vifIdx)
  let secCtx = cast[pointer](vifKeyPointers(vif).groupKeyPtr)
  if secCtx == nil:
    return 0
  if not mfp_is_robust_frame(fc, action):
    return 0
  let staIdx = desc.staInfoIdx
  if staIdx == 0xFF:
    return 2
  let sta = staInfoForIdx(staIdx)
  if (sta.capabilityFlags and 1) == 0:
    return 2
  return 1

proc mfp_add_mgmt_mic*(frameDesc: pointer, bodyLen: uint32, totalLen: uint32): uint32 {.exportc, cdecl.} =
  ## Add Management MIC IE (MMIE) to a management frame for PMF (802.11w).
  ## From blob (86 instrs): builds MMIE with IE_ID=76, length=16.
  ## Contains key ID, IPN (packet number), and 8-byte MIC via AES-CMAC.
  ## Returns 18 (MMIE size) or 0 if no security context.
  let desc = hostTxDescAt(frameDesc)
  let vifIdx = desc.vifIdx
  # Check security context at VIF+1484
  let vif = vifChannelForIdx(vifIdx)
  let secCtx = cast[pointer](vifKeyPointers(vif).groupKeyPtr)
  if secCtx == nil:
    return 0
  let sec = cast[ptr VifKeySlotView](secCtx)
  # Compute MMIE write position: frameDesc body + bodyLen
  let mmie = mmieAt(ieCursorAfter(frameDesc, bodyLen.uint))
  # Write MMIE header
  mmie.ie.id = 76   # MMIE IE ID
  mmie.ie.len = 16  # length
  # Key ID from sec_ctx+153
  mmie.keyId = sec.staIdx.uint16
  # Copy and increment IPN (6 bytes from sec_ctx+128..133)
  let ipnLo = sec.pnLow
  let ipnHi = sec.pnHigh
  # Increment IPN by 1
  let newIpnLo = ipnLo + 1
  let newIpnHi = if newIpnLo < ipnLo: ipnHi + 1 else: ipnHi
  sec.pnLow = newIpnLo
  sec.pnHigh = newIpnHi
  # Store IPN in MMIE[4..9] (6 bytes, little-endian)
  var idx = 0'u32
  while idx < 6:
    let ipnByte = if idx < 4:
        ((newIpnLo shr (idx * 8)) and 0xFF).uint8
      else:
        ((newIpnHi shr ((idx - 4) * 8)) and 0xFF).uint8
    mmie.ipn[idx.int] = ipnByte
    inc idx
  # Clear MIC area and nonce — blob inlines two zero-word stores.
  let micWords = mmieMicWords(mmie)
  micWords[0] = 0
  micWords[1] = 0
  # Compute BIP MIC using mfp_compute_bip
  # Blob passes secCtx directly as key (IGTK at start of sec context)
  let mic = mfp_compute_bip(secCtx, frameDesc, bodyLen + 18, 24)
  # Store 8-byte MIC. Blob splits lo/hi halves into two 4-byte loops —
  # each emits a runtime 64-bit shift (__lshrdi3 call). Volatile barrier
  # keeps GCC from merging them back into one.
  var micV {.volatile.}: uint64 = mic
  idx = 0
  while idx < 4:
    mmie.mic[idx.int] = ((micV shr (idx * 8)) and 0xFF'u64).uint8
    inc idx
  {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
  var micV2 {.volatile.}: uint64 = mic
  idx = 4
  while idx < 8:
    mmie.mic[idx.int] = ((micV2 shr (idx * 8)) and 0xFF'u64).uint8
    inc idx
  return 18

# Forward declaration for aes_encrypt_block (defined later in AES section)
proc aes_encrypt_block*(roundKeys: pointer, state: pointer) {.exportc, cdecl.}

proc mfp_compute_bip*(key: pointer, frame: pointer, frameLen: uint32,
    extraParam: uint32): uint64 {.exportc, cdecl.} =
  ## Compute BIP (Broadcast Integrity Protocol) MIC for PMF (558 bytes in blob).
  ## AES-CMAC-128 per IEEE 802.11w. Blob does inline CBC-MAC on stack.
  ## a0=key (with expanded schedule at +128), a1=frame, a2=frameLen,
  ## a3=extraParam (halved for MMIE offset). Returns 64-bit MIC in (a0,a1).

  if frameLen <= 41:
    assert_warn("mfp.c", "mfp.c", 428)
    return 0'u64

  let keyU = cast[uint](key)
  let frameU = cast[uint](frame)

  # Mask frame control: clear Protected/MoreData/PwrMgmt/Retry bits
  # Blob: 0xFFFFC7FF mask (lhu from frame+2, custom extract, mask)
  let origFc = cast[ptr uint16](frameU + 2)[]
  let maskedFc = origFc and 0xC7FF'u16

  # Build AAD header on stack: masked FC (2 bytes) + addresses from frame+4 (18 bytes)
  var aadHdr {.noinit.}: array[20, uint8]
  cast[ptr uint16](addr aadHdr[0])[] = maskedFc
  discard c_memcpy(addr aadHdr[2], cast[pointer](frameU + 4), 18.csize_t)

  # AES key expansion is at key+128 in blob
  # Blob runs 10-round AES encrypt inline using T-Head custom instructions.
  # We delegate to aes_encrypt_block instead (same logical result).

  # Compute data offset: extraParam >> 1 gives MMIE half-offset
  let halfParam = extraParam shr 1
  let dataStart = frameU + halfParam.uint + (halfParam.uint * 0)  # blob: s2 = frame + mul(halfParam, ???)
  # Blob: s0 = frameLen - 12 - extraParam = data length (excluding MMIE)
  var dataLen = cast[int32](frameLen) - 12 - cast[int32](extraParam)

  # Initialize CBC-MAC state and subkey buffer
  var cbcState {.noinit.}: array[16, uint8]
  var subKey {.noinit.}: array[16, uint8]
  discard c_memset(addr cbcState[0], 0, 16.csize_t)
  discard c_memset(addr subKey[0], 0, 16.csize_t)

  # XOR first 8 bytes of AAD into CBC-MAC state (blob: xor at 0x130, len=8)
  xor_bytes(addr cbcState[0], addr aadHdr[0], 8)
  # Encrypt state block
  aes_encrypt_block(key, addr cbcState[0])

  # XOR next 2 bytes of AAD (bytes 8-9) (blob: xor at 0x14a, len=2)
  xor_bytes(addr cbcState[0], cast[pointer](cast[uint](addr aadHdr[0]) + 8), 2)
  # XOR 6 more bytes (bytes 10-15) into state+4 (blob: xor at 0x158, len=6)
  xor_bytes(cast[pointer](cast[uint](addr cbcState[0]) + 4),
           cast[pointer](frameU + halfParam.uint), 6)
  # Encrypt
  aes_encrypt_block(key, addr cbcState[0])

  # Advance data pointer past initial 6 bytes consumed, adjust remaining
  var dataPtr = frameU + halfParam.uint + 12  # blob: s2 += 12
  dataLen = dataLen + cast[int32](extraParam) - 12  # adjust for consumed bytes

  # Main loop: process 16-byte blocks
  while dataLen > 16:
    xor_bytes(addr cbcState[0], cast[pointer](dataPtr), 8)
    aes_encrypt_block(key, addr cbcState[0])
    dataLen -= 16
    dataPtr += 16

  # Final block: generate CMAC subkey(s)
  aes_encrypt_block(key, addr subKey[0])
  aes_cmac_shift_sub_key(addr subKey[0])  # K1

  if dataLen.uint32 == 16:
    # Exact last block: XOR with K1, then encrypt
    xor_bytes(addr subKey[0], cast[pointer](dataPtr), 8)
  else:
    # Partial last block: generate K2, XOR partial data + padding
    aes_cmac_shift_sub_key(addr subKey[0])  # K2
    let halfLen = dataLen.uint32 shr 1
    xor_bytes(addr subKey[0], cast[pointer](dataPtr), halfLen)
  # Padding: set 0x80 byte after data (if odd length, adjust)
    let isOdd = (dataLen and 1) != 0
    if isOdd:
      let padByte = 0x80'u8 or 0x80'u8  # blob builds padding value
      let byteIdx = halfLen
      subKey[byteIdx.int] = subKey[byteIdx.int] xor padByte

  # Final: XOR subkey into CBC-MAC state and encrypt
  xor_bytes(addr cbcState[0], addr subKey[0], 8)
  aes_encrypt_block(key, addr cbcState[0])

  # Return first 8 bytes of CBC-MAC as (lo, hi) uint64
  let micLo = cast[ptr uint32](addr cbcState[0])[]
  let micHi = cast[ptr uint32](addr cbcState[4])[]
  return cast[uint64](micLo) or (cast[uint64](micHi) shl 32)

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
  let s = cast[ptr array[16, uint8]](state)

  # Blob structure: initial add_round_key, 9-round loop with MixColumns +
  # add_round_key, then final round 10 (no MixColumns) tail-calling
  # add_round_key — 3 separate call sites to match the blob.
  template subBytesShiftRows(shifted: var array[16, uint8]) =
    var tmp {.noinit.}: array[16, uint8]
    for i in 0 ..< 16:
      tmp[i] = AES_SBOX[s[i].int]
    shifted[0] = tmp[0]; shifted[4] = tmp[4]; shifted[8] = tmp[8]; shifted[12] = tmp[12]
    shifted[1] = tmp[5]; shifted[5] = tmp[9]; shifted[9] = tmp[13]; shifted[13] = tmp[1]
    shifted[2] = tmp[10]; shifted[6] = tmp[14]; shifted[10] = tmp[2]; shifted[14] = tmp[6]
    shifted[3] = tmp[15]; shifted[7] = tmp[3]; shifted[11] = tmp[7]; shifted[15] = tmp[11]

  template xtime(x: uint8): uint8 =
    let xv = x
    let r = xv.uint16 shl 1
    (if (xv and 0x80'u8) != 0: (r xor 0x1B).uint8 else: r.uint8)

  add_round_key(roundKeys, state, 0)

  for round in 1 .. 9:
    var shifted {.noinit.}: array[16, uint8]
    subBytesShiftRows(shifted)
    # MixColumns
    for col in 0 ..< 4:
      let b = col * 4
      let a0 = shifted[b]
      let a1 = shifted[b+1]
      let a2 = shifted[b+2]
      let a3 = shifted[b+3]
      s[b]   = xtime(a0) xor xtime(a1) xor a1 xor a2 xor a3
      s[b+1] = a0 xor xtime(a1) xor xtime(a2) xor a2 xor a3
      s[b+2] = a0 xor a1 xor xtime(a2) xor xtime(a3) xor a3
      s[b+3] = xtime(a0) xor a0 xor a1 xor a2 xor xtime(a3)
    add_round_key(roundKeys, state, round.uint32)

  # Round 10: SubBytes + ShiftRows (no MixColumns) then tail add_round_key
  var shifted {.noinit.}: array[16, uint8]
  subBytesShiftRows(shifted)
  for i in 0 ..< 16:
    s[i] = shifted[i]
  add_round_key(roundKeys, state, 10)

# ###########################################################################
#                  HSU: Hardware Security Unit
# ###########################################################################

var hsuMichaelCtx: array[16, uint8]

proc hsu_init*() {.exportc, cdecl.} =
  ## Initialize hardware security unit.
  discard c_memset(addr hsuMichaelCtx[0], 0, hsuMichaelCtx.len.csize_t)

proc hsu_aes_cmac*(key: pointer, msg: pointer, msgLen: uint32, mac: pointer) {.exportc, cdecl.} =
  ## Compute AES-CMAC-128 per RFC 4493.
  ## Steps: expand key, derive K1/K2, process blocks with CBC-MAC, output 16-byte MAC.
  # 1. AES key expansion (10 rounds -> 176 bytes of round keys)
  var roundKeys: array[176, uint8]
  discard c_memcpy(addr roundKeys[0], key, 16.csize_t)
  # Expand key schedule
  for i in 4'u32 ..< 44:
    var tmp: array[4, uint8]
    let prevOff = (i - 1) * 4
    for j in 0 ..< 4:
      tmp[j] = roundKeys[prevOff.int + j]
    if (i mod 4) == 0:
      # RotWord + SubWord + Rcon
      let t0 = tmp[0]
      tmp[0] = AES_SBOX[tmp[1].int] xor cast[uint8](AES_RCON[(i div 4 - 1).int])
      tmp[1] = AES_SBOX[tmp[2].int]
      tmp[2] = AES_SBOX[tmp[3].int]
      tmp[3] = AES_SBOX[t0.int]
    let off = i * 4
    let prevWordOff = (i - 4) * 4
    for j in 0 ..< 4:
      roundKeys[off.int + j] = roundKeys[prevWordOff.int + j] xor tmp[j]
  # 2. Generate subkeys K1, K2
  var k1: array[16, uint8]
  var k2: array[16, uint8]
  # Encrypt zero block to get L
  discard c_memset(addr k1[0], 0, 16.csize_t)
  aes_encrypt_block(addr roundKeys[0], addr k1[0])
  # K1 = shift(L), K2 = shift(K1)
  aes_cmac_shift_sub_key(addr k1[0])
  discard c_memcpy(addr k2[0], addr k1[0], 16.csize_t)
  aes_cmac_shift_sub_key(addr k2[0])
  # 3. CBC-MAC: process complete 16-byte blocks
  var state: array[16, uint8]
  discard c_memset(addr state[0], 0, 16.csize_t)
  var pos = 0'u32
  let nBlocks = if msgLen > 0: ((msgLen - 1) div 16) + 1 else: 1'u32
  let lastBlockComplete = (msgLen > 0) and ((msgLen mod 16) == 0)
  # Process all but last block
  if nBlocks > 1:
    for blk in 0'u32 ..< (nBlocks - 1):
      let src = cast[ptr UncheckedArray[uint8]](msg)
      for j in 0 ..< 16:
        state[j] = state[j] xor src[pos + j.uint32]
      aes_encrypt_block(addr roundKeys[0], addr state[0])
      pos += 16
  # Process last block with K1 or K2
  var lastBlock: array[16, uint8]
  let remaining = msgLen - pos
  if lastBlockComplete and remaining == 16:
    # Complete last block: XOR with K1
    let src = cast[ptr UncheckedArray[uint8]](msg)
    for j in 0 ..< 16:
      lastBlock[j] = src[pos + j.uint32] xor k1[j]
  else:
    # Incomplete last block: pad with 0x80 then zeros, XOR with K2
    discard c_memset(addr lastBlock[0], 0, 16.csize_t)
    if remaining > 0:
      let src = cast[ptr UncheckedArray[uint8]](msg)
      discard c_memcpy(addr lastBlock[0], cast[pointer](cast[uint](msg) + pos), remaining.csize_t)
    lastBlock[remaining.int] = 0x80'u8
    for j in 0 ..< 16:
      lastBlock[j] = lastBlock[j] xor k2[j]
  # XOR last block with state and encrypt
  for j in 0 ..< 16:
    state[j] = state[j] xor lastBlock[j]
  aes_encrypt_block(addr roundKeys[0], addr state[0])
  # 4. Output MAC
  discard c_memcpy(mac, addr state[0], 16.csize_t)

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

