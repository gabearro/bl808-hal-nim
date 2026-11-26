"""Known-answer tests for the SEC_ENG AES provider (src/bl808/mbedtls): the
vendored Mbed TLS built with MBEDTLS_AES_ENCRYPT_ALT encrypts through the Nim
engine code into a register-level fake of the AES block. Ciphertexts are
compared with FIPS-197 and with `openssl enc`. The fake encrypts with its own
AES, independent of Mbed TLS."""

from pathlib import Path
import random
import shutil
import subprocess

import pytest

ROOT = Path(__file__).resolve().parents[1]
PORT = ROOT / "src/bl808/mbedtls"
LIBRARY = ROOT / "vendor/mbedtls/library"

FAKE = r'''
import bl808/mbedtls/build
{.passC: "-DBL808_MBEDTLS_HW_AES".}
{.compile: "LIBRARY/aes.c".}
{.compile: "LIBRARY/platform.c".}
{.compile: "LIBRARY/platform_util.c".}
{.compile: "PORT/aes_software.c".}

const SecEngBase = 0x20004000'u
{.pragma: aesDma.}

type AesContext {.importc: "mbedtls_aes_context", header: "<mbedtls/aes.h>".} = object
  nr: cint
  rk_offset: csize_t
  buf: array[68, uint32]

proc softwareSetKey(ctx: ptr AesContext; key: ptr uint8; keyBits: cuint): cint
  {.importc: "bl808_software_aes_setkey_enc", cdecl.}
proc softwareEncrypt(ctx: ptr AesContext; input, output: ptr uint8): cint
  {.importc: "bl808_software_aes_encrypt", cdecl.}
proc aesInit(ctx: ptr AesContext) {.importc: "mbedtls_aes_init", cdecl, header: "<mbedtls/aes.h>".}
proc aesSetKeyEnc(ctx: ptr AesContext; key: ptr uint8; keyBits: cuint): cint
  {.importc: "mbedtls_aes_setkey_enc", cdecl, header: "<mbedtls/aes.h>".}
proc aesSetKeyDec(ctx: ptr AesContext; key: ptr uint8; keyBits: cuint): cint
  {.importc: "mbedtls_aes_setkey_dec", cdecl, header: "<mbedtls/aes.h>".}
proc aesCryptEcb(ctx: ptr AesContext; mode: cint; input, output: ptr uint8): cint
  {.importc: "mbedtls_aes_crypt_ecb", cdecl, header: "<mbedtls/aes.h>".}
proc aesCryptCbc(ctx: ptr AesContext; mode: cint; length: csize_t; iv, input, output: ptr uint8): cint
  {.importc: "mbedtls_aes_crypt_cbc", cdecl, header: "<mbedtls/aes.h>".}

const
  OriginalControl = 0'u32
  OriginalLink = 0x22031450'u32
  OriginalEndian = 0x10'u32

var
  controlValue = OriginalControl
  linkValue = OriginalLink
  endianValue = OriginalEndian
  irqsEnabled = true
  dmaOk = true
  inFlight: bool
  polls, started, completed, writesAtTrigger: int
  corruptAt, stuckAt: int                 # 1-based block numbers, 0 = never
  writes: seq[tuple[address: uint, value: uint32]]
  keySizesSeen: set[uint8]

proc secIrqSave(): uint32 =
  result = if irqsEnabled: 8'u32 else: 0'u32
  irqsEnabled = false
proc secIrqRestore(saved: uint32) = irqsEnabled = (saved and 8) != 0
proc fenceIo() = discard
proc regRead(address: uint): uint32
proc regWrite(address: uint; value: uint32)
proc dmaVisible(address, size: uint): bool

include "PORT/aes_engine.nim"

proc provider(ctx: ptr AesContext; input, output: ptr uint8): cint
    {.exportc: "bl808_mbedtls_aes_encrypt", cdecl.} =
  aesEncryptBlock(ctx, input, output)

proc dmaVisible(address, size: uint): bool =
  doAssert (address == cast[uint](addr aesDescriptor) and size == 60) or
    (address == cast[uint](addr aesSource) and size == 16) or
    (address == cast[uint](addr aesDestination) and size == 16)
  dmaOk

proc dmaWord(address: uint): bool =
  (address and 3) == 0 and (
    (address >= cast[uint](addr aesDescriptor) and address < cast[uint](addr aesDescriptor) + 60) or
    (address >= cast[uint](addr aesSource) and address < cast[uint](addr aesSource) + 16) or
    (address >= cast[uint](addr aesDestination) and address < cast[uint](addr aesDestination) + 16))

# ---- an independent AES (FIPS-197, byte oriented) ---------------------------
var sbox: array[256, uint8]

proc rotl8(x: uint8; n: int): uint8 = (x shl n) or (x shr (8 - n))
proc xtime(x: uint8): uint8 = (x shl 1) xor (if (x and 0x80) != 0: 0x1B'u8 else: 0'u8)

proc initSbox() =
  var p = 1'u8
  var q = 1'u8
  while true:
    p = p xor xtime(p)
    q = q xor (q shl 1)
    q = q xor (q shl 2)
    q = q xor (q shl 4)
    if (q and 0x80) != 0: q = q xor 0x09
    sbox[p] = q xor rotl8(q, 1) xor rotl8(q, 2) xor rotl8(q, 3) xor rotl8(q, 4) xor 0x63
    if p == 1: break
  sbox[0] = 0x63
initSbox()

proc referenceEncrypt(key: openArray[uint8]; input: array[16, uint8]): array[16, uint8] =
  let nk = key.len div 4
  let rounds = nk + 6
  var w: array[60, array[4, uint8]]
  for i in 0 ..< nk:
    for j in 0 ..< 4: w[i][j] = key[4 * i + j]
  var rcon = 1'u8
  for i in nk ..< 4 * (rounds + 1):
    var t = w[i - 1]
    if i mod nk == 0:
      let first = t[0]
      t[0] = sbox[t[1]] xor rcon
      t[1] = sbox[t[2]]
      t[2] = sbox[t[3]]
      t[3] = sbox[first]
      rcon = xtime(rcon)
    elif nk > 6 and i mod nk == 4:
      for j in 0 ..< 4: t[j] = sbox[t[j]]
    for j in 0 ..< 4: w[i][j] = w[i - nk][j] xor t[j]
  var s = input
  for i in 0 ..< 16: s[i] = s[i] xor w[i div 4][i mod 4]
  for round in 1 .. rounds:
    var t: array[16, uint8]
    for c in 0 ..< 4:
      for r in 0 ..< 4: t[4 * c + r] = sbox[s[4 * ((c + r) mod 4) + r]]
    if round < rounds:
      for c in 0 ..< 4:
        let a0 = t[4 * c]
        let a1 = t[4 * c + 1]
        let a2 = t[4 * c + 2]
        let a3 = t[4 * c + 3]
        t[4 * c] = xtime(a0) xor (xtime(a1) xor a1) xor a2 xor a3
        t[4 * c + 1] = a0 xor xtime(a1) xor (xtime(a2) xor a2) xor a3
        t[4 * c + 2] = a0 xor a1 xor xtime(a2) xor (xtime(a3) xor a3)
        t[4 * c + 3] = (xtime(a0) xor a0) xor a1 xor a2 xor xtime(a3)
    for i in 0 ..< 16: s[i] = t[i] xor w[4 * round + i div 4][i mod 4]
  s

proc engineRuns() =
  ## What the AES block does with a one-block ECB link descriptor in natural
  ## byte order: key, source and destination are plain byte strings.
  doAssert endianValue == 0x1F
  let control = aesDescriptor.control
  let keyBytes = case (control shr 3) and 3
    of 0: 16
    of 2: 24
    of 1: 32
    else: 0
  doAssert keyBytes != 0
  doAssert (control and not (3'u32 shl 3)) == ((1'u32 shl 9) or (1'u32 shl 16))
  doAssert aesDescriptor.iv == default(array[4, uint32])
  keySizesSeen.incl keyBytes.uint8
  var key: array[32, uint8]
  var plain: array[16, uint8]
  copyMem(addr key[0], addr aesDescriptor.key[0], 32)
  for i in keyBytes ..< 32: doAssert key[i] == 0
  copyMem(addr plain[0], addr aesSource[0], 16)
  var cipher = referenceEncrypt(key.toOpenArray(0, keyBytes - 1), plain)
  if started == corruptAt: cipher[5] = cipher[5] xor 0x40
  copyMem(addr aesDestination[0], addr cipher[0], 16)

proc regRead(address: uint): uint32 =
  if address == AesLinkAddress: return linkValue
  if address == AesEndianAddress: return endianValue
  if address == AesControl:
    if inFlight:
      inc polls
      if started == stuckAt or polls < 4: return controlValue or AesBusy
      engineRuns()
      inFlight = false
      inc completed
    return controlValue
  doAssert dmaWord(address), "unexpected MMIO read"
  doAssert not inFlight and completed == started, "output read before completion"
  cast[ptr uint32](address)[]

proc regWrite(address: uint; value: uint32) =
  doAssert not inFlight, "MMIO write while the engine owns the buffers"
  writes.add((address, value))
  if address == AesLinkAddress:
    linkValue = value
  elif address == AesEndianAddress:
    endianValue = value
  elif address == AesControl:
    if (value and AesTrigger) != 0:
      doAssert not irqsEnabled, "trigger with interrupts enabled"
      doAssert (value and (AesEnable or AesLinkMode or AesMaskIrq)) ==
        (AesEnable or AesLinkMode or AesMaskIrq)
      doAssert linkValue == cast[uint32](cast[uint](addr aesDescriptor))
      doAssert aesDescriptor.source == cast[uint32](cast[uint](addr aesSource))
      doAssert aesDescriptor.destination == cast[uint32](cast[uint](addr aesDestination))
      inc started
      polls = 0
      inFlight = true
      writesAtTrigger = writes.len
    controlValue = value and not (AesTrigger or AesBusy)
  else:
    doAssert dmaWord(address) and value == 0, "only the scrub may write DMA words"
    cast[ptr uint32](address)[] = value

proc engineAtRest(): bool =
  irqsEnabled and controlValue == OriginalControl and linkValue == OriginalLink and
    endianValue == OriginalEndian and aesDescriptor == default(AesLink) and
    aesSource == default(AesBlockWords) and aesDestination == default(AesBlockWords)

proc reset() =
  controlValue = OriginalControl
  linkValue = OriginalLink
  endianValue = OriginalEndian
  irqsEnabled = true
  dmaOk = true
  inFlight = false
  polls = 0; started = 0; completed = 0; writesAtTrigger = 0
  corruptAt = 0; stuckAt = 0
  writes.setLen(0)
  keySizesSeen = {}
  aesBackend = default(typeof(aesBackend))
  aesDescriptor = default(AesLink)
  aesSource = default(AesBlockWords)
  aesDestination = default(AesBlockWords)

proc hex(text: string): seq[uint8] =
  for i in countup(0, text.len - 2, 2):
    result.add uint8(("0123456789abcdef".find(text[i]) shl 4) or "0123456789abcdef".find(text[i + 1]))

proc ecb(key, plain: string; offset = 0): seq[uint8] =
  ## Encrypt block by block; `offset` misaligns the caller's buffers.
  var k = hex(key)
  var input = newSeq[uint8](offset) & hex(plain)
  var output = newSeq[uint8](input.len)
  var ctx: AesContext
  aesInit(addr ctx)
  doAssert aesSetKeyEnc(addr ctx, addr k[0], cuint(8 * k.len)) == 0
  for at in countup(offset, input.len - 16, 16):
    doAssert aesCryptEcb(addr ctx, 1, addr input[at], addr output[at]) == 0
  output[offset .. ^1]

proc ecbDecrypt(key, cipher: string): seq[uint8] =
  var k = hex(key)
  var input = hex(cipher)
  result = newSeq[uint8](input.len)
  var ctx: AesContext
  aesInit(addr ctx)
  doAssert aesSetKeyDec(addr ctx, addr k[0], cuint(8 * k.len)) == 0
  for at in countup(0, input.len - 16, 16):
    doAssert aesCryptEcb(addr ctx, 0, addr input[at], addr result[at]) == 0

proc cbc(key, iv, plain: string): seq[uint8] =
  var k = hex(key)
  var vector = hex(iv)
  var buffer = hex(plain)                      # encrypted in place
  var ctx: AesContext
  aesInit(addr ctx)
  doAssert aesSetKeyEnc(addr ctx, addr k[0], cuint(8 * k.len)) == 0
  doAssert aesCryptCbc(addr ctx, 1, buffer.len.csize_t, addr vector[0], addr buffer[0], addr buffer[0]) == 0
  buffer
'''

FIPS197 = [  # Appendix C: key, plaintext, ciphertext
    ("000102030405060708090a0b0c0d0e0f", "00112233445566778899aabbccddeeff",
     "69c4e0d86a7b0430d8cdb78070b4c55a"),
    ("000102030405060708090a0b0c0d0e0f1011121314151617", "00112233445566778899aabbccddeeff",
     "dda97ca4864cdfe06eaf70a0ec0d7191"),
    ("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f",
     "00112233445566778899aabbccddeeff", "8ea2b7ca516745bfeafc49904b496089"),
]


def openssl_enc(tmp_path: Path, cipher: str, key: bytes, plain: bytes, iv: bytes | None = None) -> bytes:
    openssl = shutil.which("openssl")
    if not openssl:
        pytest.skip("needs openssl for reference ciphertexts")
    (tmp_path / "plain.bin").write_bytes(plain)
    command = [openssl, "enc", f"-{cipher}", "-nopad", "-K", key.hex(), "-in", str(tmp_path / "plain.bin")]
    if iv is not None:
        command += ["-iv", iv.hex()]
    result = subprocess.run(command, capture_output=True, timeout=30)
    assert result.returncode == 0, result.stderr
    return result.stdout


def run(tmp_path: Path, checks: str) -> None:
    nim = shutil.which("nim")
    if not nim or not (LIBRARY / "aes.c").is_file():
        pytest.skip("needs Nim and the vendored Mbed TLS")
    path = tmp_path / "aes_provider.nim"
    path.write_text(FAKE.replace("LIBRARY", str(LIBRARY)).replace("PORT", str(PORT)) + checks)
    result = subprocess.run(
        [nim, "c", "-r", "--skipParentCfg", "--skipProjCfg", "--skipUserCfg", "--hints:off",
         "--assertions:on", f"--path:{ROOT / 'src'}", f"--nimcache:{tmp_path / 'cache'}", str(path)],
        capture_output=True, text=True, timeout=180, cwd=ROOT)
    assert result.returncode == 0, result.stdout + result.stderr


def test_aes_ciphertexts_through_the_engine_match_fips197_and_openssl(tmp_path: Path) -> None:
    rng = random.Random(808)
    checks = "var expectedBlocks = 0\n"
    for key, plain, cipher in FIPS197:
        checks += f'doAssert ecb("{key}", "{plain}") == hex("{cipher}")\n'
        checks += f'doAssert ecbDecrypt("{key}", "{cipher}") == hex("{plain}")\n'
        checks += "expectedBlocks += 1\ndoAssert engineAtRest()\n"
    for bits in (128, 192, 256):
        for offset in range(4):
            key, plain = rng.randbytes(bits // 8), rng.randbytes(16 * 5)
            cipher = openssl_enc(tmp_path, f"aes-{bits}-ecb", key, plain)
            checks += f'doAssert ecb("{key.hex()}", "{plain.hex()}", {offset}) == hex("{cipher.hex()}")\n'
            checks += "expectedBlocks += 5\ndoAssert engineAtRest()\n"
        key, iv, plain = rng.randbytes(bits // 8), rng.randbytes(16), rng.randbytes(16 * 7)
        cipher = openssl_enc(tmp_path, f"aes-{bits}-cbc", key, plain, iv)
        checks += f'doAssert cbc("{key.hex()}", "{iv.hex()}", "{plain.hex()}") == hex("{cipher.hex()}")\n'
        checks += "expectedBlocks += 7\ndoAssert engineAtRest()\n"
    checks += r'''
# One probe block per key size, then every block on the engine. Decryption
# never reaches it.
doAssert aesBackend == [2'u32, 2'u32, 2'u32, expectedBlocks.uint32, 0'u32, 0'u32]
doAssert started == expectedBlocks + 3 and completed == started
doAssert keySizesSeen == {16'u8, 24'u8, 32'u8}
var ctx: AesContext
var data: array[16, uint8]
doAssert aesEncryptBlock(nil, addr data[0], addr data[0]) == -0x0021
ctx.nr = 11
doAssert aesEncryptBlock(addr ctx, addr data[0], addr data[0]) == 0   # software's business
doAssert started == expectedBlocks + 3
'''
    run(tmp_path, checks)


def test_aes_leaves_a_claimed_engine_alone(tmp_path: Path) -> None:
    key, plain, cipher = FIPS197[0]
    run(tmp_path, f'const key = "{key}"\nconst plain = "{plain}"\nconst cipher = "{cipher}"\n' + r'''
for flag in [AesBusy, AesEnable, AesLinkMode]:
  reset()
  controlValue = OriginalControl or flag
  doAssert ecb(key, plain) == hex(cipher)
  doAssert writes.len == 0 and started == 0 and irqsEnabled
  doAssert aesBackend == [0'u32, 0'u32, 0'u32, 0'u32, 1'u32, 0'u32]
  controlValue = OriginalControl
  doAssert ecb(key, plain) == hex(cipher)
  doAssert aesBackend == [2'u32, 0'u32, 0'u32, 1'u32, 1'u32, 0'u32]
  doAssert engineAtRest()
''')


def test_aes_engine_that_fails_the_probe_is_never_used(tmp_path: Path) -> None:
    lines = ""
    for key, plain, cipher in FIPS197:
        lines += f'  doAssert ecb("{key}", "{plain}") == hex("{cipher}")\n'
    run(tmp_path, r'''
reset()
corruptAt = 3            # 128-bit probe and block, then the 192-bit probe
for pass in 0 .. 1:
''' + lines + r'''
doAssert aesBackend == [2'u32, 3'u32, 2'u32, 4'u32, 2'u32, 0'u32]
doAssert started == 3 + 4 and engineAtRest()

reset()
dmaOk = false
for pass in 0 .. 1:
''' + lines + r'''
doAssert aesBackend == [3'u32, 3'u32, 3'u32, 0'u32, 6'u32, 0'u32]
doAssert writes.len == 0 and started == 0
''')


def test_aes_timeout_keeps_the_ciphertext_right_and_retires_the_engine(tmp_path: Path) -> None:
    key, plain, cipher = FIPS197[2]
    run(tmp_path, f'const key = "{key}"\nconst plain = "{plain}"\nconst cipher = "{cipher}"\n' + r'''
reset()
stuckAt = 3              # probe, one good block, then the engine hangs
for round in 0 .. 3:
  doAssert ecb(key, plain) == hex(cipher)
doAssert aesBackend == [3'u32, 3'u32, 3'u32, 1'u32, 3'u32, 1'u32]
doAssert started == 3 and completed == 2 and irqsEnabled
doAssert inFlight and writes.len == writesAtTrigger
doAssert (controlValue and AesEnable) != 0      # still claimed: nobody may borrow it
doAssert aesDescriptor != default(AesLink)      # a DMA that may still run keeps its buffers
''')
