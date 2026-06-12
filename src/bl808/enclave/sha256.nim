## Compact SHA-256 (FIPS 180-4) + HMAC-SHA256 + HKDF-SHA256.
##
## Pure Nim so it runs identically on host (for known-answer tests) and on the
## enclave core, with no DMA/cache coupling — used for key derivation and small
## measurements. Bulk hashing can still use the hardware SHA in sec.nim.

type
  Sha256Digest* = array[32, uint8]
  Sha256Ctx* = object
    h: array[8, uint32]
    buf: array[64, uint8]
    bufLen: int
    total: uint64

const K = [
  0x428a2f98'u32, 0x71374491'u32, 0xb5c0fbcf'u32, 0xe9b5dba5'u32,
  0x3956c25b'u32, 0x59f111f1'u32, 0x923f82a4'u32, 0xab1c5ed5'u32,
  0xd807aa98'u32, 0x12835b01'u32, 0x243185be'u32, 0x550c7dc3'u32,
  0x72be5d74'u32, 0x80deb1fe'u32, 0x9bdc06a7'u32, 0xc19bf174'u32,
  0xe49b69c1'u32, 0xefbe4786'u32, 0x0fc19dc6'u32, 0x240ca1cc'u32,
  0x2de92c6f'u32, 0x4a7484aa'u32, 0x5cb0a9dc'u32, 0x76f988da'u32,
  0x983e5152'u32, 0xa831c66d'u32, 0xb00327c8'u32, 0xbf597fc7'u32,
  0xc6e00bf3'u32, 0xd5a79147'u32, 0x06ca6351'u32, 0x14292967'u32,
  0x27b70a85'u32, 0x2e1b2138'u32, 0x4d2c6dfc'u32, 0x53380d13'u32,
  0x650a7354'u32, 0x766a0abb'u32, 0x81c2c92e'u32, 0x92722c85'u32,
  0xa2bfe8a1'u32, 0xa81a664b'u32, 0xc24b8b70'u32, 0xc76c51a3'u32,
  0xd192e819'u32, 0xd6990624'u32, 0xf40e3585'u32, 0x106aa070'u32,
  0x19a4c116'u32, 0x1e376c08'u32, 0x2748774c'u32, 0x34b0bcb5'u32,
  0x391c0cb3'u32, 0x4ed8aa4a'u32, 0x5b9cca4f'u32, 0x682e6ff3'u32,
  0x748f82ee'u32, 0x78a5636f'u32, 0x84c87814'u32, 0x8cc70208'u32,
  0x90befffa'u32, 0xa4506ceb'u32, 0xbef9a3f7'u32, 0xc67178f2'u32]

proc rotr(x: uint32, n: int): uint32 {.inline.} =
  (x shr n) or (x shl (32 - n))

proc sha256Init*(ctx: var Sha256Ctx) =
  ctx.h = [0x6a09e667'u32, 0xbb67ae85'u32, 0x3c6ef372'u32, 0xa54ff53a'u32,
           0x510e527f'u32, 0x9b05688c'u32, 0x1f83d9ab'u32, 0x5be0cd19'u32]
  ctx.bufLen = 0
  ctx.total = 0

proc sha256Block(ctx: var Sha256Ctx, p: ptr UncheckedArray[uint8], off: int) =
  var w: array[64, uint32]
  for i in 0 ..< 16:
    let o = off + i * 4
    w[i] = (p[o].uint32 shl 24) or (p[o+1].uint32 shl 16) or
           (p[o+2].uint32 shl 8) or p[o+3].uint32
  for i in 16 ..< 64:
    let s0 = rotr(w[i-15], 7) xor rotr(w[i-15], 18) xor (w[i-15] shr 3)
    let s1 = rotr(w[i-2], 17) xor rotr(w[i-2], 19) xor (w[i-2] shr 10)
    w[i] = w[i-16] + s0 + w[i-7] + s1
  var a = ctx.h[0]; var b = ctx.h[1]; var c = ctx.h[2]; var d = ctx.h[3]
  var e = ctx.h[4]; var f = ctx.h[5]; var g = ctx.h[6]; var h = ctx.h[7]
  for i in 0 ..< 64:
    let s1 = rotr(e, 6) xor rotr(e, 11) xor rotr(e, 25)
    let ch = (e and f) xor ((not e) and g)
    let t1 = h + s1 + ch + K[i] + w[i]
    let s0 = rotr(a, 2) xor rotr(a, 13) xor rotr(a, 22)
    let maj = (a and b) xor (a and c) xor (b and c)
    let t2 = s0 + maj
    h = g; g = f; f = e; e = d + t1
    d = c; c = b; b = a; a = t1 + t2
  ctx.h[0] += a; ctx.h[1] += b; ctx.h[2] += c; ctx.h[3] += d
  ctx.h[4] += e; ctx.h[5] += f; ctx.h[6] += g; ctx.h[7] += h

proc sha256Update*(ctx: var Sha256Ctx, data: openArray[uint8]) =
  ctx.total += data.len.uint64
  var i = 0
  while i < data.len:
    let take = min(64 - ctx.bufLen, data.len - i)
    for j in 0 ..< take:
      ctx.buf[ctx.bufLen + j] = data[i + j]
    ctx.bufLen += take
    i += take
    if ctx.bufLen == 64:
      sha256Block(ctx, cast[ptr UncheckedArray[uint8]](addr ctx.buf[0]), 0)
      ctx.bufLen = 0

proc sha256Final*(ctx: var Sha256Ctx): Sha256Digest =
  let bits = ctx.total * 8
  var pad: array[72, uint8]
  pad[0] = 0x80
  var padLen = if ctx.bufLen < 56: 56 - ctx.bufLen else: 120 - ctx.bufLen
  for i in 0 ..< 8:
    pad[padLen + i] = ((bits shr ((7 - i) * 8)) and 0xFF).uint8
  sha256Update(ctx, toOpenArray(pad, 0, padLen + 8 - 1))
  for i in 0 ..< 8:
    result[i*4]   = ((ctx.h[i] shr 24) and 0xFF).uint8
    result[i*4+1] = ((ctx.h[i] shr 16) and 0xFF).uint8
    result[i*4+2] = ((ctx.h[i] shr 8) and 0xFF).uint8
    result[i*4+3] = (ctx.h[i] and 0xFF).uint8

proc sha256*(data: openArray[uint8]): Sha256Digest =
  var ctx: Sha256Ctx
  sha256Init(ctx)
  sha256Update(ctx, data)
  sha256Final(ctx)

# --- HMAC-SHA256 ---
proc hmacSha256*(key, msg: openArray[uint8]): Sha256Digest =
  var k0: array[64, uint8]
  if key.len > 64:
    let kh = sha256(key)
    for i in 0 ..< 32: k0[i] = kh[i]
  else:
    for i in 0 ..< key.len: k0[i] = key[i]
  var ipad, opad: array[64, uint8]
  for i in 0 ..< 64:
    ipad[i] = k0[i] xor 0x36
    opad[i] = k0[i] xor 0x5c
  var inner: Sha256Ctx
  sha256Init(inner)
  sha256Update(inner, ipad)
  sha256Update(inner, msg)
  let innerDig = sha256Final(inner)
  var outer: Sha256Ctx
  sha256Init(outer)
  sha256Update(outer, opad)
  sha256Update(outer, innerDig)
  sha256Final(outer)

# --- HKDF-SHA256 (RFC 5869) ---
proc hkdfExtract*(salt, ikm: openArray[uint8]): Sha256Digest =
  hmacSha256(salt, ikm)

proc hkdfExpand*(prk, info: openArray[uint8], outLen: int, output: var openArray[uint8]) =
  var t: Sha256Digest
  var tLen = 0
  var produced = 0
  var counter = 1'u8
  while produced < outLen:
    var msg: array[32 + 64 + 1, uint8]
    var m = 0
    for i in 0 ..< tLen: msg[m] = t[i]; inc m
    for i in 0 ..< info.len: msg[m] = info[i]; inc m
    msg[m] = counter; inc m
    t = hmacSha256(prk, toOpenArray(msg, 0, m - 1))
    tLen = 32
    let take = min(32, outLen - produced)
    for i in 0 ..< take:
      output[produced + i] = t[i]
    produced += take
    inc counter

proc hkdf*(salt, ikm, info: openArray[uint8], outLen: int, output: var openArray[uint8]) =
  let prk = hkdfExtract(salt, ikm)
  hkdfExpand(prk, info, outLen, output)
