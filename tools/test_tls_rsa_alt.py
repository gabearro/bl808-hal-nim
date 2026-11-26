"""Known-answer tests for the PKA RSA provider (src/bl808/mbedtls): the
vendored Mbed TLS bignum module, built through rsa_exp_mod_hook.c, raises
public values to public exponents via the Nim engine code and a fake of the
PKA. Results are compared with Python's pow().

The fake models the PKA as the engine's register program assumes it (the
conventions of Bouffalo's bignum_alt.c and of src/bl808/pka.nim): registers
addressed by index and size in one shared memory, big-endian contents,
modular multiplication and exponentiation in Montgomery form with the
constant -n^-1 mod R read from the register after the modulus. It does its
arithmetic with Mbed TLS numbers but never calls Mbed TLS's exponentiation."""

from pathlib import Path
import random
import shutil
import subprocess

import pytest

ROOT = Path(__file__).resolve().parents[1]
PORT = ROOT / "src/bl808/mbedtls"
LIBRARY = ROOT / "vendor/mbedtls/library"

HARNESS = r'''
import bl808/mbedtls/build
{.compile: "PORT/rsa_exp_mod_hook.c".}
{.compile: "LIBRARY/bignum_core.c".}
{.compile: "LIBRARY/constant_time.c".}
{.compile: "LIBRARY/platform.c".}
{.compile: "LIBRARY/platform_util.c".}

type Mpi {.importc: "mbedtls_mpi", header: "<mbedtls/bignum.h>".} = object

{.push importc, cdecl, header: "<mbedtls/bignum.h>".}
proc mbedtls_mpi_init(x: ptr Mpi)
proc mbedtls_mpi_free(x: ptr Mpi)
proc mbedtls_mpi_lset(x: ptr Mpi; value: int32): cint
proc mbedtls_mpi_read_binary(x: ptr Mpi; data: ptr uint8; len: csize_t): cint
proc mbedtls_mpi_write_binary(x: ptr Mpi; data: ptr uint8; len: csize_t): cint
proc mbedtls_mpi_size(x: ptr Mpi): csize_t
proc mbedtls_mpi_copy(x, y: ptr Mpi): cint
proc mbedtls_mpi_mul_mpi(x, a, b: ptr Mpi): cint
proc mbedtls_mpi_mod_mpi(r, a, b: ptr Mpi): cint
proc mbedtls_mpi_add_mpi(x, a, b: ptr Mpi): cint
proc mbedtls_mpi_sub_mpi(x, a, b: ptr Mpi): cint
proc mbedtls_mpi_shift_l(x: ptr Mpi; count: csize_t): cint
proc mbedtls_mpi_shift_r(x: ptr Mpi; count: csize_t): cint
proc mbedtls_mpi_cmp_mpi(a, b: ptr Mpi): cint
proc mbedtls_mpi_get_bit(x: ptr Mpi; position: csize_t): cint
proc mbedtls_mpi_bitlen(x: ptr Mpi): csize_t
proc mbedtls_mpi_exp_mod(x, a, e, n, rr: ptr Mpi): cint
{.pop.}
# Declared in the library's private bignum_internal.h.
proc mbedtls_mpi_exp_mod_unsafe(x, a, e, n, rr: ptr Mpi): cint {.importc, cdecl.}

proc softwareExpMod(n, a: ptr uint8; e: uint32; x: ptr uint8; length: csize_t): cint
  {.importc: "bl808_software_rsa_exp_mod", cdecl.}

# ---- What the includer provides: the PKA driver's names (src/bl808/pka.nim) ----

const
  PkaRegSize8 = 1'u8
  PkaRegSize64 = 4'u8
  PkaRegSize96 = 5'u8
  PkaRegSize128 = 6'u8
  PkaRegSize192 = 7'u8
  PkaRegSize256 = 8'u8
  PkaRegSize384 = 9'u8
  PkaRegSize512 = 10'u8
  SizeBytes = [0, 8, 16, 32, 64, 96, 128, 192, 256, 384, 512]
  PkaRamBytes = 2048        # eight 256-byte registers, as bignum_alt.c uses at most

type BflbDevice = object

var
  pkaDevice: BflbDevice
  rsaPka = addr pkaDevice
  pkaClaimed: bool
  irqsEnabled = true
  pkaFree = true
  pkaOpen: bool
  ram: array[PkaRamBytes, uint8]
  programs: int             # exponent commands run
  wrongAt, tooBigAt: int    # 1-based exponent commands, 0 = never
  timeoutAt: int            # the exponent command the PKA does not finish in time
  pkaTimeouts: uint32
  primeWritten: bool

proc secIrqSave(): uint32 =
  result = if irqsEnabled: 8'u32 else: 0'u32
  irqsEnabled = false
proc secIrqRestore(saved: uint32) = irqsEnabled = (saved and 8) != 0
proc pkaAvailable(): bool = pkaFree
proc pkaTimeoutCount(): uint32 = pkaTimeouts

proc span(index, size: uint8): (int, int) =
  let bytes = SizeBytes[size]
  doAssert bytes > 0 and index.int * bytes + bytes <= PkaRamBytes, "register outside the PKA memory"
  (index.int * bytes, bytes)

proc load(x: var Mpi; index, size: uint8) =
  let (at, bytes) = span(index, size)
  mbedtls_mpi_init(addr x)
  doAssert mbedtls_mpi_read_binary(addr x, addr ram[at], bytes.csize_t) == 0

proc store(x: var Mpi; index, size: uint8) =
  let (at, bytes) = span(index, size)
  doAssert mbedtls_mpi_size(addr x).int <= bytes, "result does not fit its register"
  doAssert mbedtls_mpi_write_binary(addr x, addr ram[at], bytes.csize_t) == 0

proc inUse() =
  doAssert pkaOpen and pkaClaimed and irqsEnabled, "PKA used without holding it"

proc bflb_pka_init(dev: ptr BflbDevice) =
  doAssert dev == rsaPka and pkaClaimed and not pkaOpen
  pkaOpen = true
  primeWritten = false
  for b in ram.mitems: b = 0xA5          # nothing may rely on old contents

proc bflb_pka_deinit(dev: ptr BflbDevice) =
  doAssert pkaOpen
  pkaOpen = false

proc bflb_pka_write(dev: ptr BflbDevice; regindex, regsize: uint8; data: ptr uint32;
                    size: uint16; lastop: uint8) =
  inUse()
  let (at, bytes) = span(regindex, regsize)
  doAssert size.int * 4 == bytes and (cast[uint](data) and 3) == 0
  copyMem(addr ram[at], data, bytes)      # big-endian mode: memory order
  if regindex == 1: primeWritten = true

proc bflb_pka_read(dev: ptr BflbDevice; regindex, regsize: uint8; data: ptr uint32; size: uint16) =
  inUse()
  let (at, bytes) = span(regindex, regsize)
  doAssert size.int * 4 == bytes and (cast[uint](data) and 3) == 0
  copyMem(data, addr ram[at], bytes)

proc bflb_pka_gf2mont(dev: ptr BflbDevice; sIdx, sSize, dIdx, dSize, tIdx, tSize, pIdx, pSize: uint8;
                      bitShift: uint32) =
  ## t = s * 2^bitShift (a long shift into the scratch register), d = t mod p.
  inUse()
  var s, p, d: Mpi
  load(s, sIdx, sSize)
  load(p, pIdx, pSize)
  doAssert SizeBytes[tSize] * 8 >= SizeBytes[sSize] * 8 + bitShift.int
  doAssert mbedtls_mpi_shift_l(addr s, bitShift.csize_t) == 0
  store(s, tIdx, tSize)
  mbedtls_mpi_init(addr d)
  doAssert mbedtls_mpi_mod_mpi(addr d, addr s, addr p) == 0
  store(d, dIdx, dSize)

proc montgomery(x: var Mpi; a, b, n, prime: var Mpi; bits: int) =
  ## x = a * b / R mod n by Montgomery reduction with prime = -n^-1 mod R.
  var t, m, r: Mpi
  for v in [addr t, addr m, addr r]: mbedtls_mpi_init(v)
  doAssert mbedtls_mpi_lset(addr r, 1) == 0 and mbedtls_mpi_shift_l(addr r, bits.csize_t) == 0
  doAssert mbedtls_mpi_mul_mpi(addr t, addr a, addr b) == 0
  doAssert mbedtls_mpi_mod_mpi(addr m, addr t, addr r) == 0
  doAssert mbedtls_mpi_mul_mpi(addr m, addr m, addr prime) == 0
  doAssert mbedtls_mpi_mod_mpi(addr m, addr m, addr r) == 0
  doAssert mbedtls_mpi_mul_mpi(addr m, addr m, addr n) == 0
  doAssert mbedtls_mpi_add_mpi(addr t, addr t, addr m) == 0
  doAssert mbedtls_mpi_shift_r(addr t, bits.csize_t) == 0
  if mbedtls_mpi_cmp_mpi(addr t, addr n) >= 0:
    doAssert mbedtls_mpi_sub_mpi(addr t, addr t, addr n) == 0
  doAssert mbedtls_mpi_copy(addr x, addr t) == 0
  for v in [addr t, addr m, addr r]: mbedtls_mpi_free(v)

proc bflb_pka_mmul(dev: ptr BflbDevice; s0Idx, s0Size, dIdx, dSize, s1Idx, s1Size, s2Idx, s2Size: uint8;
                   lastop: uint8) =
  inUse()
  doAssert primeWritten and lastop == 1
  var a, b, n, prime, x: Mpi
  load(a, s0Idx, s0Size)
  load(b, s1Idx, s1Size)
  load(n, s2Idx, s2Size)
  load(prime, s2Idx + 1, s2Size)
  mbedtls_mpi_init(addr x)
  montgomery(x, a, b, n, prime, 8 * SizeBytes[s2Size])
  store(x, dIdx, dSize)
  if programs == tooBigAt:
    # What comes back is no residue at all.
    let (at, bytes) = span(dIdx, dSize)
    for i in 0 ..< bytes: ram[at + i] = 0xFF

proc bflb_pka_mexp(dev: ptr BflbDevice; s0Idx, s0Size, dIdx, dSize, s1Idx, s1Size, s2Idx, s2Size: uint8;
                   lastop: uint8) =
  ## d = s0 ^ s1 in Montgomery form (s0 and d both carry the factor R).
  inUse()
  doAssert primeWritten and lastop == 1
  inc programs
  let bits = 8 * SizeBytes[s2Size]
  var base, e, n, prime, x: Mpi
  load(base, s0Idx, s0Size)
  load(e, s1Idx, s1Size)
  load(n, s2Idx, s2Size)
  load(prime, s2Idx + 1, s2Size)
  # Start from R mod n, the Montgomery form of 1.
  mbedtls_mpi_init(addr x)
  doAssert mbedtls_mpi_lset(addr x, 1) == 0 and mbedtls_mpi_shift_l(addr x, bits.csize_t) == 0
  doAssert mbedtls_mpi_mod_mpi(addr x, addr x, addr n) == 0
  for bit in countdown(mbedtls_mpi_bitlen(addr e).int - 1, 0):
    montgomery(x, x, x, n, prime, bits)
    if mbedtls_mpi_get_bit(addr e, bit.csize_t) == 1: montgomery(x, x, base, n, prime, bits)
  if programs == wrongAt:
    var one: Mpi
    mbedtls_mpi_init(addr one)
    doAssert mbedtls_mpi_lset(addr one, 1) == 0
    doAssert mbedtls_mpi_add_mpi(addr x, addr x, addr one) == 0     # still a residue, but wrong
    doAssert mbedtls_mpi_mod_mpi(addr x, addr x, addr n) == 0
  # The driver's wait gave up. The right value is stored all the same: the
  # engine must go by the count, not by how the registers look.
  if programs == timeoutAt: inc pkaTimeouts
  store(x, dIdx, dSize)

include "PORT/rsa_engine.nim"

proc provider(n, a: ptr uint8; e: uint32; x: ptr uint8; length: csize_t): cint
    {.exportc: "bl808_mbedtls_rsa_exp_mod", cdecl.} = rsaExpMod(n, a, e, x, length)

proc reset() =
  irqsEnabled = true
  pkaFree = true
  pkaOpen = false
  pkaClaimed = false
  programs = 0
  wrongAt = 0; tooBigAt = 0; timeoutAt = 0
  rsaBackend = default(typeof(rsaBackend))
  rsaSizeState = default(typeof(rsaSizeState))

proc number(x: var Mpi; hex: string) =
  var bytes = newSeq[uint8](hex.len div 2)
  for i in 0 ..< bytes.len:
    bytes[i] = uint8(("0123456789abcdef".find(hex[2 * i]) shl 4) or
                     "0123456789abcdef".find(hex[2 * i + 1]))
  mbedtls_mpi_init(addr x)
  doAssert mbedtls_mpi_read_binary(addr x, addr bytes[0], bytes.len.csize_t) == 0

proc text(x: var Mpi; digits: int): string =
  var bytes = newSeq[uint8](digits div 2)
  doAssert mbedtls_mpi_write_binary(addr x, addr bytes[0], bytes.len.csize_t) == 0
  for b in bytes:
    result.add "0123456789abcdef"[b shr 4]
    result.add "0123456789abcdef"[b and 15]

proc power(n, a, e: string; private = false; status: cint = 0): string =
  ## a^e mod n through Mbed TLS: the entry point for public values, or with
  ## `private` the constant-time one for secret exponents.
  var mn, ma, me, mx, rr: Mpi
  number(mn, n)
  number(ma, a)
  number(me, e)
  mbedtls_mpi_init(addr mx)
  mbedtls_mpi_init(addr rr)       # the caller's R^2 cache, as rsa.c passes one
  let rc = if private: mbedtls_mpi_exp_mod(addr mx, addr ma, addr me, addr mn, addr rr)
           else: mbedtls_mpi_exp_mod_unsafe(addr mx, addr ma, addr me, addr mn, addr rr)
  doAssert rc == status, $rc
  doAssert irqsEnabled and not pkaClaimed and not pkaOpen
  if rc == 0: result = text(mx, n.len)
'''


def h(value: int, bits: int) -> str:
    return f"{value:0{2 * ((bits + 7) // 8)}x}"


def modulus(rng: random.Random, bits: int) -> int:
    return rng.getrandbits(bits) | (1 << (bits - 1)) | 1


def power(n: int, a: int, e: int, bits: int, extra: str = "") -> str:
    return (f'doAssert power("{h(n, bits)}", "{h(a, bits)}", "{h(e, 64)}"{extra}) == '
            f'"{h(pow(a, e, n), bits)}"\n')


def run(tmp_path: Path, checks: str) -> None:
    nim = shutil.which("nim")
    if not nim or not (LIBRARY / "bignum.c").is_file():
        pytest.skip("needs Nim and the vendored Mbed TLS")
    path = tmp_path / "rsa_provider.nim"
    path.write_text(HARNESS.replace("LIBRARY", str(LIBRARY)).replace("PORT", str(PORT)) + checks)
    result = subprocess.run(
        [nim, "c", "-r", "--skipParentCfg", "--skipProjCfg", "--skipUserCfg", "--hints:off",
         "--assertions:on", f"--path:{ROOT / 'src'}", f"--nimcache:{tmp_path / 'cache'}", str(path)],
        capture_output=True, text=True, timeout=300, cwd=ROOT)
    assert result.returncode == 0, result.stdout + result.stderr


def test_rsa_public_powers_through_the_pka_match_pow(tmp_path: Path) -> None:
    rng = random.Random(4096)
    checks = ""
    hardware = software = 0
    # One modulus per PKA register size, and sizes that do not fill theirs.
    seen = set()
    for bits in [512, 768, 1024, 1536, 2048, 2047, 1000, 300]:
        n = modulus(rng, bits)
        register = min(size for size in (64, 96, 128, 192, 256) if size * 8 >= bits)
        for e in [65537, 3, 17, (1 << 23) - 1]:
            for a in [rng.randrange(2, n), 0, 1, n - 1]:
                checks += power(n, a, e, bits)
                # The first use of a register size is computed both ways and
                # answered by software.
                software += register not in seen
                hardware += register in seen
                seen.add(register)
    checks += f"""
doAssert rsaBackend == [2'u32, {hardware}'u32, {software}'u32, 0'u32]
doAssert programs == {hardware + software}
"""
    run(tmp_path, checks)


def test_rsa_leaves_everything_else_to_software(tmp_path: Path) -> None:
    rng = random.Random(8192)
    n = modulus(rng, 2048)
    a = rng.randrange(2, n)
    big = modulus(rng, 4096)
    small = modulus(rng, 256)
    d = rng.getrandbits(2048)
    run(tmp_path, f"""
# The largest key a server may use here, the smallest numbers, exponents the
# single-command program is not used for, and a base that is not reduced.
{power(big, rng.randrange(2, big), 65537, 4096)}{power(small, rng.randrange(2, small), 65537, 256)}\
{power(n, a, 1, 2048)}{power(n, a, 2, 2048)}{power(n, a, 1 << 23, 2048)}{power(n, a, (1 << 32) + 1, 2048)}\
{power(n, n + 5, 65537, 2056)}doAssert programs == 0 and rsaBackend == [0'u32, 0'u32, 0'u32, 0'u32]
# A private exponent never reaches the PKA, whatever its size.
{power(n, a, d, 2048, ", private = true")}{power(n, a, 65537, 2048, ", private = true")}\
doAssert programs == 0
# Invalid moduli are reported as the stock code reports them.
discard power("{h(n - 1, 2048)}", "{h(a, 2048)}", "{h(65537, 64)}", status = -0x0004)
discard power("{h(0, 2048)}", "{h(a, 2048)}", "{h(65537, 64)}", status = -0x0004)
doAssert programs == 0
""")


def test_rsa_hardware_that_cannot_be_trusted_is_retired(tmp_path: Path) -> None:
    rng = random.Random(12288)
    n, m = modulus(rng, 2048), modulus(rng, 1024)
    good = power(n, rng.randrange(2, n), 65537, 2048)
    other = power(m, rng.randrange(2, m), 65537, 1024)
    run(tmp_path, f"""
reset()
wrongAt = 1                          # the first use sees a wrong residue
{good}{good}doAssert rsaBackend == [3'u32, 0'u32, 2'u32, 0'u32] and programs == 1
# Each register size is judged by itself.
{other}{other}doAssert rsaBackend == [2'u32, 1'u32, 3'u32, 0'u32] and programs == 3
{good}doAssert rsaBackend == [3'u32, 1'u32, 4'u32, 0'u32] and programs == 3

reset()
tooBigAt = 3                         # later, something that is not a residue comes back
{good}{good}{good}{good}doAssert rsaBackend == [3'u32, 1'u32, 3'u32, 1'u32] and programs == 3

reset()
tooBigAt = 1                         # ... or already at the first use
{good}{good}doAssert rsaBackend == [3'u32, 0'u32, 2'u32, 1'u32] and programs == 1

reset()
timeoutAt = 3                        # a command the PKA does not finish in time
{good}{good}{good}{good}doAssert rsaBackend == [3'u32, 1'u32, 3'u32, 1'u32] and programs == 3

reset()
timeoutAt = 1                        # ... or already at the first use
{good}{good}doAssert rsaBackend == [3'u32, 0'u32, 2'u32, 1'u32] and programs == 1
# Timeouts counted before a program started are not held against it.
{other}{other}doAssert rsaBackend == [2'u32, 1'u32, 3'u32, 1'u32] and programs == 3
""")


def test_rsa_defers_while_the_pka_is_owned_or_in_use(tmp_path: Path) -> None:
    rng = random.Random(16384)
    n = modulus(rng, 2048)
    good = power(n, rng.randrange(2, n), 65537, 2048)
    run(tmp_path, f"""
reset()
pkaFree = false                      # another CPU group, or the P-256 provider, has it
{good}doAssert rsaBackend == [0'u32, 0'u32, 0'u32, 0'u32] and programs == 0
pkaFree = true
{good}{good}doAssert rsaBackend == [2'u32, 1'u32, 1'u32, 0'u32] and programs == 2
pkaFree = false
{good}doAssert rsaBackend == [2'u32, 1'u32, 2'u32, 0'u32] and programs == 2
pkaFree = true
pkaClaimed = true                    # a program of this provider is already running
doAssert provider(nil, nil, 65537, nil, 256) == 1 and programs == 2
pkaClaimed = false
""")
