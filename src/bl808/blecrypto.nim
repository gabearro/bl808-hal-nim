## Pure Nim AES-128, AES-CMAC, and Bluetooth key-derivation helpers.

const BleAesSbox: array[256, uint8] = [
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

const BleAesRcon: array[10, uint8] = [
  0x01'u8, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1B, 0x36
]

const
  MeshK2Salt: array[16, uint8] = [
    0xb1'u8, 0x10, 0x8d, 0x4d, 0x1f, 0x97, 0x16, 0xfd,
    0xbf, 0xbf, 0x71, 0x18, 0x0c, 0x48, 0x90, 0x4f
  ]
  MeshK3Salt: array[16, uint8] = [
    0x02'u8, 0xc3, 0x91, 0x62, 0x13, 0x6e, 0x71, 0x8a,
    0xcc, 0x95, 0xf1, 0x03, 0x35, 0x44, 0x36, 0x00
  ]
  MeshK4Salt: array[16, uint8] = [
    0xbe'u8, 0x49, 0x5f, 0xac, 0x54, 0xee, 0x97, 0x4c,
    0x87, 0x66, 0xfa, 0xce, 0xb7, 0xc1, 0x9a, 0x0e
  ]
  H9IsoKeyId: array[4, uint8] = [0x49'u8, 0x53, 0x4f, 0x43]
  SecureConnectionsF5Salt: array[16, uint8] = [
    0x6c'u8, 0x88, 0x83, 0x91, 0xaa, 0xf5, 0xa5, 0x38,
    0x60, 0x37, 0x0b, 0xdb, 0x5a, 0x60, 0x83, 0xbe
  ]
  MeshK3Id64: array[5, uint8] = [0x69'u8, 0x64, 0x36, 0x34, 0x01]
  MeshK4Id6: array[4, uint8] = [0x69'u8, 0x64, 0x36, 0x01]
  MeshK2MaxPLen = 238

proc reverseBytes(buf: ptr uint8, count: int) =
  if buf == nil or count <= 1:
    return
  let raw = cast[ptr UncheckedArray[uint8]](buf)
  for i in 0 ..< (count div 2):
    let j = count - 1 - i
    let t = raw[i]
    raw[i] = raw[j]
    raw[j] = t

proc copyBytes(dst: ptr uint8, src: ptr uint8, count: int) =
  if dst == nil or count <= 0:
    return
  let d = cast[ptr UncheckedArray[uint8]](dst)
  if src == nil:
    for i in 0 ..< count:
      d[i] = 0
    return
  let s = cast[ptr UncheckedArray[uint8]](src)
  for i in 0 ..< count:
    d[i] = s[i]

proc copyReversed(dst: ptr uint8, src: ptr uint8, count: int) =
  if dst == nil or count <= 0:
    return
  let d = cast[ptr UncheckedArray[uint8]](dst)
  if src == nil:
    for i in 0 ..< count:
      d[i] = 0
    return
  let s = cast[ptr UncheckedArray[uint8]](src)
  for i in 0 ..< count:
    d[i] = s[count - 1 - i]

proc copyAddrParam(dst: ptr uint8, src: ptr uint8) =
  if dst == nil:
    return
  let d = cast[ptr UncheckedArray[uint8]](dst)
  if src == nil:
    for i in 0 ..< 7:
      d[i] = 0
    return
  let s = cast[ptr UncheckedArray[uint8]](src)
  d[0] = s[0]
  for i in 0 ..< 6:
    d[1 + i] = s[1 + 5 - i]

proc zeroBytes(dst: ptr uint8, count: int) =
  if dst == nil:
    return
  let d = cast[ptr UncheckedArray[uint8]](dst)
  for i in 0 ..< count:
    d[i] = 0

proc aesXtime(x: uint8): uint8 {.inline.} =
  let v = x.uint16 shl 1
  if (x and 0x80'u8) != 0:
    uint8((v xor 0x1B'u16) and 0xFF'u16)
  else:
    uint8(v and 0xFF'u16)

proc aesExpandKey(key: ptr uint8, roundKeys: var array[176, uint8]) =
  let raw = cast[ptr UncheckedArray[uint8]](key)
  for i in 0 ..< 16:
    roundKeys[i] = raw[i]

  var bytes = 16
  var rconIdx = 0
  var temp: array[4, uint8]
  while bytes < roundKeys.len:
    for i in 0 ..< 4:
      temp[i] = roundKeys[bytes - 4 + i]
    if (bytes and 0x0F) == 0:
      let t = temp[0]
      temp[0] = BleAesSbox[temp[1].int] xor BleAesRcon[rconIdx]
      temp[1] = BleAesSbox[temp[2].int]
      temp[2] = BleAesSbox[temp[3].int]
      temp[3] = BleAesSbox[t.int]
      inc rconIdx
    for i in 0 ..< 4:
      roundKeys[bytes] = roundKeys[bytes - 16] xor temp[i]
      inc bytes

proc aesAddRoundKey(state: var array[16, uint8],
                    roundKeys: var array[176, uint8], round: int) =
  let base = round * 16
  for i in 0 ..< 16:
    state[i] = state[i] xor roundKeys[base + i]

proc aesSubShift(state: var array[16, uint8]) =
  var tmp: array[16, uint8]
  for i in 0 ..< 16:
    tmp[i] = BleAesSbox[state[i].int]
  state[0] = tmp[0]; state[4] = tmp[4]; state[8] = tmp[8]; state[12] = tmp[12]
  state[1] = tmp[5]; state[5] = tmp[9]; state[9] = tmp[13]; state[13] = tmp[1]
  state[2] = tmp[10]; state[6] = tmp[14]; state[10] = tmp[2]; state[14] = tmp[6]
  state[3] = tmp[15]; state[7] = tmp[3]; state[11] = tmp[7]; state[15] = tmp[11]

proc aesMixColumns(state: var array[16, uint8]) =
  for col in 0 ..< 4:
    let b = col * 4
    let a0 = state[b]
    let a1 = state[b + 1]
    let a2 = state[b + 2]
    let a3 = state[b + 3]
    state[b] = aesXtime(a0) xor aesXtime(a1) xor a1 xor a2 xor a3
    state[b + 1] = a0 xor aesXtime(a1) xor aesXtime(a2) xor a2 xor a3
    state[b + 2] = a0 xor a1 xor aesXtime(a2) xor aesXtime(a3) xor a3
    state[b + 3] = aesXtime(a0) xor a0 xor a1 xor a2 xor aesXtime(a3)

proc bleAesEncryptBlock*(key: ptr uint8, input: ptr uint8, output: ptr uint8) =
  if key == nil or input == nil or output == nil:
    return
  let src = cast[ptr UncheckedArray[uint8]](input)
  let dst = cast[ptr UncheckedArray[uint8]](output)
  var roundKeys: array[176, uint8]
  var state: array[16, uint8]
  for i in 0 ..< 16:
    state[i] = src[i]
  aesExpandKey(key, roundKeys)
  aesAddRoundKey(state, roundKeys, 0)
  for round in 1 .. 9:
    aesSubShift(state)
    aesMixColumns(state)
    aesAddRoundKey(state, roundKeys, round)
  aesSubShift(state)
  aesAddRoundKey(state, roundKeys, 10)
  for i in 0 ..< 16:
    dst[i] = state[i]

proc cmacShiftSubkey(dst: var array[16, uint8],
                     src: var array[16, uint8]) =
  let msb = (src[0] and 0x80'u8) != 0
  var carry = 0'u8
  for i in countdown(15, 0):
    let v = src[i]
    dst[i] = (v shl 1) or carry
    carry = (v shr 7) and 1
  if msb:
    dst[15] = dst[15] xor 0x87'u8

proc bleAesCmac*(key: ptr uint8, msg: ptr uint8, msgLen: uint16,
                 result: ptr uint8) =
  if key == nil or result == nil:
    return

  var zero: array[16, uint8]
  var l: array[16, uint8]
  var k1: array[16, uint8]
  var k2: array[16, uint8]
  var x: array[16, uint8]
  var y: array[16, uint8]
  var last: array[16, uint8]
  bleAesEncryptBlock(key, addr zero[0], addr l[0])
  cmacShiftSubkey(k1, l)
  cmacShiftSubkey(k2, k1)

  let length = msgLen.int
  let blockCount =
    if length == 0: 1
    else: (length + 15) div 16
  let completeLast = length != 0 and (length mod 16) == 0
  let data =
    if msg == nil: nil
    else: cast[ptr UncheckedArray[uint8]](msg)

  if completeLast and data != nil:
    let off = (blockCount - 1) * 16
    for i in 0 ..< 16:
      last[i] = data[off + i] xor k1[i]
  else:
    let rem = length mod 16
    let off = (blockCount - 1) * 16
    for i in 0 ..< rem:
      if data != nil:
        last[i] = data[off + i]
    last[rem] = 0x80'u8
    for i in 0 ..< 16:
      last[i] = last[i] xor k2[i]

  for blockIdx in 0 ..< blockCount - 1:
    for i in 0 ..< 16:
      let b =
        if data == nil: 0'u8
        else: data[blockIdx * 16 + i]
      y[i] = x[i] xor b
    bleAesEncryptBlock(key, addr y[0], addr x[0])

  for i in 0 ..< 16:
    y[i] = x[i] xor last[i]
  bleAesEncryptBlock(key, addr y[0], result)

proc bleAesK1*(n: ptr uint8, salt: ptr uint8, p: ptr uint8, pLen: uint16,
               result: ptr uint8) =
  if result == nil:
    return
  if n == nil or salt == nil:
    zeroBytes(result, 16)
    return
  var t: array[16, uint8]
  bleAesCmac(salt, n, 16, addr t[0])
  bleAesCmac(addr t[0], p, pLen, result)

proc bleAesK2*(n: ptr uint8, p: ptr uint8, pLen: uint16,
               result: ptr uint8) =
  if result == nil:
    return
  if n == nil or pLen.int > MeshK2MaxPLen:
    zeroBytes(result, 33)
    return

  var t: array[16, uint8]
  var t1: array[16, uint8]
  var t2: array[16, uint8]
  var t3: array[16, uint8]
  var msg: array[16 + MeshK2MaxPLen + 1, uint8]
  let plen = pLen.int

  bleAesCmac(unsafeAddr MeshK2Salt[0], n, 16, addr t[0])

  copyBytes(addr msg[0], p, plen)
  msg[plen] = 0x01'u8
  bleAesCmac(addr t[0], addr msg[0], (plen + 1).uint16, addr t1[0])

  copyBytes(addr msg[0], addr t1[0], 16)
  copyBytes(addr msg[16], p, plen)
  msg[16 + plen] = 0x02'u8
  bleAesCmac(addr t[0], addr msg[0], (17 + plen).uint16, addr t2[0])

  copyBytes(addr msg[0], addr t2[0], 16)
  copyBytes(addr msg[16], p, plen)
  msg[16 + plen] = 0x03'u8
  bleAesCmac(addr t[0], addr msg[0], (17 + plen).uint16, addr t3[0])

  let outp = cast[ptr UncheckedArray[uint8]](result)
  outp[0] = t1[15] and 0x7F'u8
  for i in 0 ..< 16:
    outp[1 + i] = t2[i]
    outp[17 + i] = t3[i]

proc bleAesK3*(n: ptr uint8, result: ptr uint8) =
  if result == nil:
    return
  if n == nil:
    zeroBytes(result, 8)
    return
  var t: array[16, uint8]
  var res: array[16, uint8]
  bleAesCmac(unsafeAddr MeshK3Salt[0], n, 16, addr t[0])
  bleAesCmac(addr t[0], unsafeAddr MeshK3Id64[0], MeshK3Id64.len.uint16,
             addr res[0])
  copyBytes(result, addr res[8], 8)

proc bleAesK4*(n: ptr uint8): uint8 =
  if n == nil:
    return 0
  var t: array[16, uint8]
  var res: array[16, uint8]
  bleAesCmac(unsafeAddr MeshK4Salt[0], n, 16, addr t[0])
  bleAesCmac(addr t[0], unsafeAddr MeshK4Id6[0], MeshK4Id6.len.uint16,
             addr res[0])
  res[15] and 0x3F'u8

proc bleAesH8*(k: ptr uint8, s: ptr uint8, keyId: ptr uint8,
               result: ptr uint8) =
  if result == nil:
    return
  if k == nil:
    zeroBytes(result, 16)
    return
  var t: array[16, uint8]
  bleAesCmac(k, s, 16, addr t[0])
  bleAesCmac(addr t[0], keyId, 4, result)

proc bleAesH9*(k: ptr uint8, keyId: ptr uint8, result: ptr uint8) =
  if result == nil:
    return
  if k == nil:
    zeroBytes(result, 16)
    return
  var t: array[16, uint8]
  bleAesCmac(k, unsafeAddr H9IsoKeyId[0], H9IsoKeyId.len.uint16, addr t[0])
  bleAesCmac(addr t[0], keyId, 4, result)

proc bleAesC1*(key: ptr uint8, r: ptr uint8, p1: ptr uint8,
               p2: ptr uint8, result: ptr uint8) =
  if result == nil:
    return
  if key == nil or r == nil or p1 == nil or p2 == nil:
    zeroBytes(result, 16)
    return

  let rand = cast[ptr UncheckedArray[uint8]](r)
  let p1b = cast[ptr UncheckedArray[uint8]](p1)
  let p2b = cast[ptr UncheckedArray[uint8]](p2)
  var tmp: array[16, uint8]
  for i in 0 ..< 16:
    tmp[i] = rand[i] xor p1b[i]
  bleAesEncryptBlock(key, addr tmp[0], addr tmp[0])
  for i in 0 ..< 16:
    tmp[i] = tmp[i] xor p2b[i]
  bleAesEncryptBlock(key, addr tmp[0], result)

proc bleAesS1*(msg: ptr uint8, msgLen: uint16, result: ptr uint8) =
  if result == nil:
    return
  var zero: array[16, uint8]
  bleAesCmac(addr zero[0], msg, msgLen, result)

proc bleAesF4*(u: ptr uint8, v: ptr uint8, x: ptr uint8, z: uint8,
               result: ptr uint8) =
  if result == nil:
    return
  if u == nil or v == nil or x == nil:
    zeroBytes(result, 16)
    return
  var key: array[16, uint8]
  var msg: array[65, uint8]
  copyReversed(addr msg[0], u, 32)
  copyReversed(addr msg[32], v, 32)
  msg[64] = z
  copyReversed(addr key[0], x, 16)
  bleAesCmac(addr key[0], addr msg[0], msg.len.uint16, result)
  reverseBytes(result, 16)

proc bleAesF5*(w: ptr uint8, n1: ptr uint8, n2: ptr uint8,
               a1: ptr uint8, a2: ptr uint8, result: ptr uint8) =
  if result == nil:
    return
  if w == nil or n1 == nil or n2 == nil or a1 == nil or a2 == nil:
    zeroBytes(result, 32)
    return

  var ws: array[32, uint8]
  var t: array[16, uint8]
  var msg: array[53, uint8]
  let outp = cast[ptr UncheckedArray[uint8]](result)
  msg[1] = 0x62'u8
  msg[2] = 0x74'u8
  msg[3] = 0x6c'u8
  msg[4] = 0x65'u8
  msg[51] = 0x01'u8
  msg[52] = 0x00'u8
  copyReversed(addr ws[0], w, 32)
  bleAesCmac(unsafeAddr SecureConnectionsF5Salt[0], addr ws[0],
             ws.len.uint16, addr t[0])
  copyReversed(addr msg[5], n1, 16)
  copyReversed(addr msg[21], n2, 16)
  copyAddrParam(addr msg[37], a1)
  copyAddrParam(addr msg[44], a2)
  msg[0] = 0
  bleAesCmac(addr t[0], addr msg[0], msg.len.uint16, addr outp[0])
  reverseBytes(addr outp[0], 16)
  msg[0] = 1
  bleAesCmac(addr t[0], addr msg[0], msg.len.uint16, addr outp[16])
  reverseBytes(addr outp[16], 16)

proc bleAesF6*(w: ptr uint8, n1: ptr uint8, n2: ptr uint8, r: ptr uint8,
               iocap: ptr uint8, a1: ptr uint8, a2: ptr uint8,
               result: ptr uint8) =
  if result == nil:
    return
  if w == nil or n1 == nil or n2 == nil or r == nil or iocap == nil or
      a1 == nil or a2 == nil:
    zeroBytes(result, 16)
    return
  var key: array[16, uint8]
  var msg: array[65, uint8]
  copyReversed(addr msg[0], n1, 16)
  copyReversed(addr msg[16], n2, 16)
  copyReversed(addr msg[32], r, 16)
  copyReversed(addr msg[48], iocap, 3)
  copyAddrParam(addr msg[51], a1)
  copyAddrParam(addr msg[58], a2)
  copyReversed(addr key[0], w, 16)
  bleAesCmac(addr key[0], addr msg[0], msg.len.uint16, result)
  reverseBytes(result, 16)

proc bleAesG2Raw*(u: ptr uint8, v: ptr uint8, x: ptr uint8, y: ptr uint8,
                  result: ptr uint8) =
  if result == nil:
    return
  if u == nil or v == nil or x == nil or y == nil:
    zeroBytes(result, 16)
    return
  var key: array[16, uint8]
  var msg: array[80, uint8]
  copyReversed(addr msg[0], u, 32)
  copyReversed(addr msg[32], v, 32)
  copyReversed(addr msg[64], y, 16)
  copyReversed(addr key[0], x, 16)
  bleAesCmac(addr key[0], addr msg[0], msg.len.uint16, result)

proc bleAesG2*(u: ptr uint8, v: ptr uint8, x: ptr uint8, y: ptr uint8): uint32 =
  if u == nil or v == nil or x == nil or y == nil:
    return 0
  var res: array[16, uint8]
  bleAesG2Raw(u, v, x, y, addr res[0])
  let passkey =
    (res[12].uint32 shl 24) or (res[13].uint32 shl 16) or
    (res[14].uint32 shl 8) or res[15].uint32
  passkey mod 1_000_000'u32

proc bleAesH6*(w: ptr uint8, keyId: ptr uint8, result: ptr uint8) =
  if result == nil:
    return
  if w == nil or keyId == nil:
    zeroBytes(result, 16)
    return
  var key: array[16, uint8]
  var msg: array[4, uint8]
  copyReversed(addr key[0], w, 16)
  copyReversed(addr msg[0], keyId, 4)
  bleAesCmac(addr key[0], addr msg[0], msg.len.uint16, result)
  reverseBytes(result, 16)

proc bleAesH7*(salt: ptr uint8, w: ptr uint8, result: ptr uint8) =
  if result == nil:
    return
  if salt == nil or w == nil:
    zeroBytes(result, 16)
    return
  var key: array[16, uint8]
  var msg: array[16, uint8]
  copyReversed(addr key[0], salt, 16)
  copyReversed(addr msg[0], w, 16)
  bleAesCmac(addr key[0], addr msg[0], msg.len.uint16, result)
  reverseBytes(result, 16)

proc ccmCounterBlock(nonce: ptr uint8, counter: uint16,
                     counterBlock: var array[16, uint8]) =
  counterBlock[0] = 0x01'u8
  copyBytes(addr counterBlock[1], nonce, 13)
  counterBlock[14] = uint8(counter shr 8)
  counterBlock[15] = uint8(counter and 0xFF)

proc ccmMacBlock(key: ptr uint8, macBlock: var array[16, uint8],
                 y: var array[16, uint8]) =
  for i in 0 ..< 16:
    macBlock[i] = macBlock[i] xor y[i]
  bleAesEncryptBlock(key, addr macBlock[0], addr y[0])

proc ccmComputeMic(key: ptr uint8, nonce: ptr uint8, msg: ptr uint8,
                   msgLen: uint16, micLen: uint8,
                   encryptedMic: ptr uint8) =
  var macBlock: array[16, uint8]
  var y: array[16, uint8]
  var ctr0: array[16, uint8]
  var s0: array[16, uint8]
  let raw =
    if msg == nil: nil
    else: cast[ptr UncheckedArray[uint8]](msg)
  let length = msgLen.int

  macBlock[0] = uint8((((micLen - 2'u8) div 2'u8) shl 3) or 0x01'u8)
  copyBytes(addr macBlock[1], nonce, 13)
  macBlock[14] = uint8(msgLen shr 8)
  macBlock[15] = uint8(msgLen and 0xFF)
  bleAesEncryptBlock(key, addr macBlock[0], addr y[0])

  var offset = 0
  while offset < length:
    for i in 0 ..< 16:
      if raw != nil and offset + i < length:
        macBlock[i] = raw[offset + i]
      else:
        macBlock[i] = 0
    ccmMacBlock(key, macBlock, y)
    offset += 16

  ccmCounterBlock(nonce, 0'u16, ctr0)
  bleAesEncryptBlock(key, addr ctr0[0], addr s0[0])
  let outp = cast[ptr UncheckedArray[uint8]](encryptedMic)
  for i in 0 ..< micLen.int:
    outp[i] = y[i] xor s0[i]

proc ccmCrypt(key: ptr uint8, nonce: ptr uint8, input: ptr uint8,
              output: ptr uint8, msgLen: uint16) =
  if msgLen == 0:
    return
  let inp = cast[ptr UncheckedArray[uint8]](input)
  let outp = cast[ptr UncheckedArray[uint8]](output)
  var ctr: array[16, uint8]
  var stream: array[16, uint8]
  var offset = 0
  var counter = 1'u16
  let length = msgLen.int
  while offset < length:
    ccmCounterBlock(nonce, counter, ctr)
    bleAesEncryptBlock(key, addr ctr[0], addr stream[0])
    let chunk = min(16, length - offset)
    for i in 0 ..< chunk:
      outp[offset + i] = inp[offset + i] xor stream[i]
    inc counter
    offset += chunk

proc bleAesCcm*(key: ptr uint8, nonce: ptr uint8, input: ptr uint8,
                output: ptr uint8, msgLen: uint16, mic: ptr uint8,
                micLen: uint8, encrypt: bool): bool =
  if key == nil or nonce == nil or output == nil:
    return false
  if msgLen != 0 and input == nil:
    return false
  if micLen != 0 and (mic == nil or micLen < 4'u8 or micLen > 16'u8 or
      (micLen and 1'u8) != 0):
    return false

  var calcMic: array[16, uint8]
  if encrypt:
    if micLen != 0:
      ccmComputeMic(key, nonce, input, msgLen, micLen, addr calcMic[0])
    ccmCrypt(key, nonce, input, output, msgLen)
    if micLen != 0:
      copyBytes(mic, addr calcMic[0], micLen.int)
    return true

  ccmCrypt(key, nonce, input, output, msgLen)
  if micLen == 0:
    return true
  ccmComputeMic(key, nonce, output, msgLen, micLen, addr calcMic[0])
  let rawMic = cast[ptr UncheckedArray[uint8]](mic)
  var diff = 0'u8
  for i in 0 ..< micLen.int:
    diff = diff or (rawMic[i] xor calcMic[i])
  diff == 0'u8
