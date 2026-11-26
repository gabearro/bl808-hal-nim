## RSA public-key exponentiation (x = a^e mod n) on the BL808 PKA.
##
## Included by rsa_alt.nim and by tools/test_tls_rsa_alt.py. The includer
## provides the PKA driver (the bflb_pka_* calls of pka.nim with the
## PkaRegSize* codes and pkaTimeoutCount, and the device as `rsaPka`),
## pkaAvailable, the shared `pkaClaimed` flag,
## secIrqSave, secIrqRestore and softwareExpMod. Numbers are big-endian byte
## strings as long as the PKA register they go into: 64, 96, 128, 192 or 256
## bytes (512- to 2048-bit moduli).
##
## The register program is the one of Bouffalo's own Mbed TLS port
## (bignum_alt.c, the branch for exponents up to 23 bits, which covers 3 and
## 65537): the modulus in register 0 and its Montgomery constant -n^-1 mod R
## in register 1, where the PKA looks for it; the base taken into Montgomery
## form; one modular-exponent command; one multiplication by 1 to come back.
##
## Only public exponents arrive here (rsa_exp_mod_hook.c wraps the function
## Mbed TLS uses for public values), so nothing secret is in the PKA: the
## ladder is not constant-time. That is every RSA signature check of a TLS
## handshake and of a certificate chain.
##
## The PKA is a single, non-reentrant resource: an exponentiation is attempted
## only when the block is free or owned by this CPU group and no other
## provider is using it. The first use of each register size compares the
## result with software, and every result is checked to be below the modulus.
## A command the PKA does not finish in time (pkaTimeoutCount moves) is a
## failure like a wrong result: software computes, and the size is retired.

const
  RsaMaxBytes = 256                 # the largest register the program fits in
  RsaMaxWords = RsaMaxBytes div 4
  RsaMaxExponentBits = 23
  # Registers, in units of the modulus size (as bignum_alt.c numbers them).
  RsaRegModulus = 0'u8
  RsaRegPrime = 1'u8
  RsaRegBase = 2'u8                 # as a double-size register, the conversion's scratch
  RsaRegMont = 3'u8
  RsaRegResult = 4'u8

type
  RsaWords = array[RsaMaxWords, uint32]   # aligned for the PKA
  RsaResult = enum
    rsaFault, rsaDeferred, rsaDone

var
  ## [0] state of the size last used: 0 unchecked, 1 probing, 2 usable,
  ## 3 unavailable; [1] hardware results; [2] software results;
  ## [3] hardware failures.
  rsaBackend {.exportc: "nim_mbedtls_rsa_backend".}: array[4, uint32]
  rsaSizeState: array[5, uint8]     # per register size, the values of [0]

proc rsaSizeIndex(bytes: int): int =
  case bytes
  of 64: 0
  of 96: 1
  of 128: 2
  of 192: 3
  of 256: 4
  else: -1

proc rsaRegSize(bytes: int): uint8 =
  ## The PKA size code of a `bytes`-byte register.
  case bytes
  of 8: PkaRegSize8
  of 64: PkaRegSize64
  of 96: PkaRegSize96
  of 128: PkaRegSize128
  of 192: PkaRegSize192
  of 256: PkaRegSize256
  of 384: PkaRegSize384
  else: PkaRegSize512

proc rsaMulLow(a, b: RsaWords; limbs: int): RsaWords =
  ## a * b mod 2^(32 * limbs), little-endian limbs.
  for i in 0 ..< limbs:
    var carry = 0'u64
    for j in 0 ..< limbs - i:
      let t = a[i].uint64 * b[j].uint64 + result[i + j].uint64 + carry
      result[i + j] = uint32(t and 0xFFFF_FFFF'u64)
      carry = t shr 32

proc rsaMontConstant(n: RsaWords; limbs: int): RsaWords =
  ## -n^-1 mod 2^(32 * limbs) for odd n, little-endian limbs. Newton's
  ## iteration x <- x * (2 - n * x) doubles the number of correct low bits;
  ## x = 1 is right to one bit.
  var x: RsaWords
  x[0] = 1
  var bits = 1
  while bits < 32 * limbs:
    bits *= 2
    let have = min((bits + 31) div 32, limbs)
    var t = rsaMulLow(n, x, have)             # n * x
    var borrow = 0'u64                        # t <- 2 - t
    for i in 0 ..< have:
      let d = (if i == 0: 2'u64 else: 0'u64) - t[i].uint64 - borrow
      t[i] = uint32(d and 0xFFFF_FFFF'u64)
      borrow = (d shr 32) and 1
    x = rsaMulLow(x, t, have)
  var borrow = 0'u64                          # result <- 0 - x
  for i in 0 ..< limbs:
    let d = 0'u64 - x[i].uint64 - borrow
    result[i] = uint32(d and 0xFFFF_FFFF'u64)
    borrow = (d shr 32) and 1

proc rsaBytes(words: var RsaWords): ptr UncheckedArray[uint8] {.inline.} =
  cast[ptr UncheckedArray[uint8]](addr words[0])

proc rsaBelow(a, b: ptr UncheckedArray[uint8]; bytes: int): bool =
  ## a < b, both big-endian.
  for i in 0 ..< bytes:
    if a[i] != b[i]: return a[i] < b[i]
  false

proc claimPkaForRsa(): bool =
  let saved = secIrqSave()
  defer: secIrqRestore(saved)
  if pkaClaimed or not pkaAvailable(): return false
  pkaClaimed = true
  true

proc rsaHardwareExpMod(n, a: ptr uint8; e: uint32; x: ptr uint8; bytes: int): RsaResult =
  if not claimPkaForRsa(): return rsaDeferred
  let words = bytes div 4
  let size = rsaRegSize(bytes)
  let nBytes = cast[ptr UncheckedArray[uint8]](n)
  var modulus, prime, work: RsaWords
  var exponent: array[2, uint32]
  copyMem(addr modulus, n, bytes)
  # The Montgomery constant, from and to the big-endian layout the PKA takes.
  for i in 0 ..< words:
    let at = bytes - 4 * i
    work[i] = nBytes[at - 1].uint32 or (nBytes[at - 2].uint32 shl 8) or
      (nBytes[at - 3].uint32 shl 16) or (nBytes[at - 4].uint32 shl 24)
  work = rsaMontConstant(work, words)
  for i in 0 ..< words:
    let at = bytes - 4 * i
    rsaBytes(prime)[at - 1] = uint8(work[i] and 0xFF)
    rsaBytes(prime)[at - 2] = uint8((work[i] shr 8) and 0xFF)
    rsaBytes(prime)[at - 3] = uint8((work[i] shr 16) and 0xFF)
    rsaBytes(prime)[at - 4] = uint8(work[i] shr 24)
  let exponentBytes = cast[ptr UncheckedArray[uint8]](addr exponent[0])
  for i in 0 ..< 4: exponentBytes[7 - i] = uint8((e shr (8 * i)) and 0xFF)
  # The exponent goes into an 8-byte register just above the four registers
  # in use by then; indices count in units of the register's own size.
  let exponentReg = uint8(RsaRegResult.int * bytes div 8)
  let timeouts = pkaTimeoutCount()

  bflb_pka_init(rsaPka)
  bflb_pka_write(rsaPka, RsaRegModulus, size, addr modulus[0], words.uint16, 1)
  copyMem(addr work, a, bytes)
  bflb_pka_write(rsaPka, RsaRegBase, size, addr work[0], words.uint16, 1)
  bflb_pka_gf2mont(rsaPka, RsaRegBase, size, RsaRegMont, size,
                   RsaRegBase, rsaRegSize(2 * bytes), RsaRegModulus, size, uint32(8 * bytes))
  bflb_pka_write(rsaPka, RsaRegPrime, size, addr prime[0], words.uint16, 1)
  bflb_pka_write(rsaPka, exponentReg, PkaRegSize8, addr exponent[0], 2, 1)
  bflb_pka_mexp(rsaPka, RsaRegMont, size, RsaRegBase, size, exponentReg, PkaRegSize8,
                RsaRegModulus, size, 1)
  zeroMem(addr work, bytes)                 # the number 1
  rsaBytes(work)[bytes - 1] = 1
  bflb_pka_write(rsaPka, RsaRegMont, size, addr work[0], words.uint16, 1)
  bflb_pka_mmul(rsaPka, RsaRegBase, size, RsaRegResult, size, RsaRegMont, size,
                RsaRegModulus, size, 1)
  bflb_pka_read(rsaPka, RsaRegResult, size, addr work[0], words.uint16)
  bflb_pka_deinit(rsaPka)
  pkaClaimed = false

  # A command that timed out left no result to read. Whatever else went
  # wrong inside the PKA, a residue is below the modulus.
  if pkaTimeoutCount() == timeouts and rsaBelow(rsaBytes(work), nBytes, bytes):
    copyMem(x, addr work, bytes)
    result = rsaDone

proc rsaExpMod(n, a: ptr uint8; e: uint32; x: ptr uint8; length: csize_t): cint =
  ## 0 when `x` holds a^e mod n, 1 when the caller must compute it.
  let bytes = length.int
  let index = rsaSizeIndex(bytes)
  if index < 0 or e < 3 or (e shr RsaMaxExponentBits) != 0: return 1
  rsaBackend[0] = rsaSizeState[index]
  if rsaSizeState[index] == 0:
    # First use of this register size: both ways, with the caller's numbers.
    if pkaClaimed or not pkaAvailable(): return 1   # contention is not a failed check
    var expected: array[RsaMaxBytes, uint8]
    rsaSizeState[index] = 1
    rsaBackend[0] = 1
    if softwareExpMod(n, a, e, addr expected[0], length) != 0:
      rsaSizeState[index] = 0
      rsaBackend[0] = 0
      return 1
    case rsaHardwareExpMod(n, a, e, x, bytes)
    of rsaDeferred: rsaSizeState[index] = 0
    of rsaFault:
      inc rsaBackend[3]
      rsaSizeState[index] = 3
    of rsaDone:
      rsaSizeState[index] = if equalMem(x, addr expected[0], bytes): 2 else: 3
    rsaBackend[0] = rsaSizeState[index]
    copyMem(x, addr expected[0], bytes)     # this one is software's answer
    inc rsaBackend[2]
    return 0
  if rsaSizeState[index] == 2:
    case rsaHardwareExpMod(n, a, e, x, bytes)
    of rsaDone:
      inc rsaBackend[1]
      return 0
    of rsaDeferred: discard
    of rsaFault:
      inc rsaBackend[3]
      rsaSizeState[index] = 3
      rsaBackend[0] = 3
  inc rsaBackend[2]
  1
