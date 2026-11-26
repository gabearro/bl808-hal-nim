"""Known-answer tests for the PKA P-256 provider (src/bl808/mbedtls): the
vendored Mbed TLS ECP module, built through ecp_p256_hook.c, multiplies via
the Nim policy code and a stand-in for the PKA driver call. Products, sums of
products and ECDSA verdicts are compared with a Python implementation of the
curve. The stand-in is the HAL's
pure-Nim P-256 (src/bl808/p256.nim), independent of Mbed TLS. The PKA has no
register-level fake: its microprogram is the driver's (pka.nim), not this
provider's."""

from pathlib import Path
import random
import shutil
import subprocess

import pytest

ROOT = Path(__file__).resolve().parents[1]
PORT = ROOT / "src/bl808/mbedtls"
LIBRARY = ROOT / "vendor/mbedtls/library"

P = 0xFFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFF
N = 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551
B = 0x5AC635D8AA3A93E7B3EBBD55769886BC651D06B0CC53B0F63BCE3C3E27D2604B
G = (0x6B17D1F2E12C4247F8BCE6E563A440F277037D812DEB33A0F4A13945D898C296,
     0x4FE342E2FE1A7F9B8EE7EB4A7C0F9E162BCE33576B315ECECBB6406837BF51F5)
assert (G[1] ** 2 - G[0] ** 3 + 3 * G[0] - B) % P == 0


def add(p1, p2):
    if p1 is None: return p2
    if p2 is None: return p1
    (x1, y1), (x2, y2) = p1, p2
    if x1 == x2 and (y1 + y2) % P == 0: return None
    slope = ((3 * x1 * x1 - 3) * pow(2 * y1, -1, P) if p1 == p2
             else (y2 - y1) * pow(x2 - x1, -1, P)) % P
    x3 = (slope * slope - x1 - x2) % P
    return x3, (slope * (x1 - x3) - y1) % P


def mul(k, point):
    result = None
    while k:
        if k & 1: result = add(result, point)
        point = add(point, point)
        k >>= 1
    return result


HARNESS = r'''
import bl808/mbedtls/build
import bl808/p256
{.compile: "PORT/ecp_p256_hook.c".}
{.compile: "LIBRARY/ecp_curves.c".}
{.compile: "LIBRARY/ecdsa.c".}
{.compile: "LIBRARY/asn1parse.c".}
{.compile: "LIBRARY/asn1write.c".}
{.compile: "LIBRARY/bignum.c".}
{.compile: "LIBRARY/bignum_core.c".}
{.compile: "LIBRARY/constant_time.c".}
{.compile: "LIBRARY/platform.c".}
{.compile: "LIBRARY/platform_util.c".}

type
  Mpi {.importc: "mbedtls_mpi", header: "<mbedtls/bignum.h>".} = object
  EcpPoint {.importc: "mbedtls_ecp_point", header: "<mbedtls/ecp.h>".} = object
    X, Y, Z: Mpi
  EcpGroup {.importc: "mbedtls_ecp_group", header: "<mbedtls/ecp.h>".} = object
    G: EcpPoint
  Rng = proc(state: pointer; output: ptr uint8; len: csize_t): cint {.cdecl.}

{.push importc, cdecl, header: "<mbedtls/ecp.h>".}
proc mbedtls_ecp_group_init(grp: ptr EcpGroup)
proc mbedtls_ecp_group_load(grp: ptr EcpGroup; id: cint): cint
proc mbedtls_ecp_point_init(point: ptr EcpPoint)
proc mbedtls_ecp_mul(grp: ptr EcpGroup; r: ptr EcpPoint; m: ptr Mpi; p: ptr EcpPoint;
                     rng: Rng; state: pointer): cint
proc mbedtls_ecp_muladd(grp: ptr EcpGroup; r: ptr EcpPoint; m: ptr Mpi; p: ptr EcpPoint;
                        n: ptr Mpi; q: ptr EcpPoint): cint
proc mbedtls_mpi_init(x: ptr Mpi)
proc mbedtls_mpi_lset(x: ptr Mpi; value: clong): cint
proc mbedtls_mpi_read_binary(x: ptr Mpi; data: ptr uint8; len: csize_t): cint
proc mbedtls_mpi_write_binary(x: ptr Mpi; data: ptr uint8; len: csize_t): cint
{.pop.}
proc mbedtls_ecdsa_verify(grp: ptr EcpGroup; hash: ptr uint8; len: csize_t; q: ptr EcpPoint;
                          r, s: ptr Mpi): cint {.importc, cdecl, header: "<mbedtls/ecdsa.h>".}
var MBEDTLS_ECP_DP_SECP256R1 {.importc, nodecl, header: "<mbedtls/ecp.h>".}: cint

proc softwareMul(scalar, px, py, rx, ry: ptr uint8): cint
  {.importc: "bl808_software_p256_mul", cdecl.}

type Coordinate = array[32, uint8]

var
  irqsEnabled = true
  pkaFree = true
  pkaCalls: int
  wrongPointAt, offCurveAt, failAt, reenterAt: int    # 1-based PKA calls, 0 = never
  reentered: cint = -1

proc secIrqSave(): uint32 =
  result = if irqsEnabled: 8'u32 else: 0'u32
  irqsEnabled = false
proc secIrqRestore(saved: uint32) = irqsEnabled = (saved and 8) != 0
proc pkaAvailable(): bool = pkaFree
proc pkaScalarMul(scalar, px, py, outX, outY: ptr uint32): bool

include "PORT/p256_engine.nim"

proc provider(scalar, px, py, rx, ry: ptr uint8): cint
    {.exportc: "bl808_mbedtls_p256_mul", cdecl.} = p256Mul(scalar, px, py, rx, ry)
proc reject() {.exportc: "bl808_mbedtls_p256_reject", cdecl.} = p256Reject()

proc reversed(data: ptr uint32): Coordinate =
  let bytes = cast[ptr Coordinate](data)
  for i in 0 ..< 32: result[i] = bytes[31 - i]

proc pkaScalarMul(scalar, px, py, outX, outY: ptr uint32): bool =
  ## The PKA driver call: big-endian operands in word-aligned buffers.
  doAssert irqsEnabled and p256InFlight
  for operand in [scalar, px, py, outX, outY]: doAssert (cast[uint](operand) and 3) == 0
  inc pkaCalls
  if pkaCalls == failAt: return false
  if pkaCalls == reenterAt:
    # An interrupt handler asks for a product while this one is running.
    var x, y: Coordinate
    reentered = p256Mul(cast[ptr uint8](scalar), cast[ptr uint8](px), cast[ptr uint8](py),
                        addr x[0], addr y[0])
  var k = reversed(scalar)
  var x = reversed(px)
  var y = reversed(py)
  if pkaCalls == wrongPointAt: k[0] = k[0] xor 1        # another point of the curve
  var rx, ry: Coordinate
  if not p256ScalarMultLe(addr k[0], addr x[0], addr y[0], addr rx[0], addr ry[0]): return false
  if pkaCalls == offCurveAt: rx[7] = rx[7] xor 0x10
  let x32 = cast[ptr Coordinate](outX)
  let y32 = cast[ptr Coordinate](outY)
  for i in 0 ..< 32:
    x32[i] = rx[31 - i]
    y32[i] = ry[31 - i]
  true

proc reset() =
  irqsEnabled = true
  pkaFree = true
  pkaCalls = 0
  wrongPointAt = 0; offCurveAt = 0; failAt = 0; reenterAt = 0
  reentered = -1
  p256Backend = default(typeof(p256Backend))
  p256InFlight = false

proc testRng(state: pointer; output: ptr uint8; len: csize_t): cint {.cdecl.} =
  let bytes = cast[ptr UncheckedArray[uint8]](output)
  for i in 0 ..< len.int: bytes[i] = uint8(0x3D + 7 * i)
  0

proc hex(text: string): Coordinate =
  doAssert text.len == 64
  for i in 0 ..< 32:
    result[i] = uint8(("0123456789abcdef".find(text[2 * i]) shl 4) or
                      "0123456789abcdef".find(text[2 * i + 1]))

var group: EcpGroup
mbedtls_ecp_group_init(addr group)
doAssert mbedtls_ecp_group_load(addr group, MBEDTLS_ECP_DP_SECP256R1) == 0

proc load(point: var EcpPoint; x, y: string) =
  var bx = hex(x)
  var by = hex(y)
  mbedtls_ecp_point_init(addr point)
  doAssert mbedtls_mpi_read_binary(addr point.X, addr bx[0], 32) == 0
  doAssert mbedtls_mpi_read_binary(addr point.Y, addr by[0], 32) == 0
  doAssert mbedtls_mpi_lset(addr point.Z, 1) == 0

proc store(point: var EcpPoint): (Coordinate, Coordinate) =
  doAssert mbedtls_mpi_write_binary(addr point.X, addr result[0][0], 32) == 0
  doAssert mbedtls_mpi_write_binary(addr point.Y, addr result[1][0], 32) == 0

proc product(k, x, y: string; status: cint = 0): (Coordinate, Coordinate) =
  ## mbedtls_ecp_mul, with the result written over the input point.
  var scalar: Mpi
  var point: EcpPoint
  var bk = hex(k)
  mbedtls_mpi_init(addr scalar)
  doAssert mbedtls_mpi_read_binary(addr scalar, addr bk[0], 32) == 0
  load(point, x, y)
  doAssert mbedtls_ecp_mul(addr group, addr point, addr scalar, addr point, testRng, nil) == status
  if status == 0: result = store(point)

proc combination(m, n, x, y: string): (Coordinate, Coordinate) =
  ## mbedtls_ecp_muladd: m * G + n * (x, y), the ECDSA verification shape.
  var sm, sn: Mpi
  var point, sum: EcpPoint
  var bm = hex(m)
  var bn = hex(n)
  mbedtls_mpi_init(addr sm)
  mbedtls_mpi_init(addr sn)
  doAssert mbedtls_mpi_read_binary(addr sm, addr bm[0], 32) == 0
  doAssert mbedtls_mpi_read_binary(addr sn, addr bn[0], 32) == 0
  load(point, x, y)
  mbedtls_ecp_point_init(addr sum)
  doAssert mbedtls_ecp_muladd(addr group, addr sum, addr sm, addr group.G, addr sn, addr point) == 0
  store(sum)

proc verdict(hash, r, s, x, y: string): cint =
  ## mbedtls_ecdsa_verify of (r, s) over a 32-byte hash with public key (x, y).
  var mr, ms: Mpi
  var key: EcpPoint
  var bh = hex(hash)
  var br = hex(r)
  var bs = hex(s)
  mbedtls_mpi_init(addr mr)
  mbedtls_mpi_init(addr ms)
  doAssert mbedtls_mpi_read_binary(addr mr, addr br[0], 32) == 0
  doAssert mbedtls_mpi_read_binary(addr ms, addr bs[0], 32) == 0
  load(key, x, y)
  mbedtls_ecdsa_verify(addr group, addr bh[0], 32, addr key, addr mr, addr ms)
'''


def h(value: int) -> str:
    return f"{value:064x}"


def expect(k: int, point) -> str:
    x, y = mul(k, point)
    return f'(hex("{h(x)}"), hex("{h(y)}"))'


def call(k: int, point) -> str:
    return f'product("{h(k)}", "{h(point[0])}", "{h(point[1])}")'


def run(tmp_path: Path, checks: str) -> None:
    nim = shutil.which("nim")
    if not nim or not (LIBRARY / "ecp.c").is_file():
        pytest.skip("needs Nim and the vendored Mbed TLS")
    path = tmp_path / "p256_provider.nim"
    path.write_text(HARNESS.replace("LIBRARY", str(LIBRARY)).replace("PORT", str(PORT)) + checks)
    result = subprocess.run(
        [nim, "c", "-r", "--skipParentCfg", "--skipProjCfg", "--skipUserCfg", "--hints:off",
         "--assertions:on", f"--path:{ROOT / 'src'}", f"--nimcache:{tmp_path / 'cache'}", str(path)],
        capture_output=True, text=True, timeout=300, cwd=ROOT)
    assert result.returncode == 0, result.stdout + result.stderr


def test_p256_products_through_the_provider_match_the_curve(tmp_path: Path) -> None:
    rng = random.Random(808)
    checks = ""
    count = 0       # products on the PKA
    base = 0        # multiples of G, which stay in software
    peer = mul(rng.randrange(1, N), G)
    for k in [1, 2, 3, N - 1, 1 << 255, rng.randrange(1, N), rng.randrange(1, N)]:
        for point in (G, peer):
            checks += f"doAssert {call(k, point)} == {expect(k, point)}\n"
            if point is G:
                base += 1
            else:
                count += 1
    # An ECDH exchange: both sides reach the same point.
    a, b = rng.randrange(1, N), rng.randrange(1, N)
    checks += f"doAssert {call(a, mul(b, G))} == {call(b, mul(a, G))}\n"
    count += 2
    m, n = rng.randrange(1, N), rng.randrange(1, N)
    total = add(mul(m, G), mul(n, peer))
    checks += f"""
# The first use compared one product with software. Multiples of the base
# point are left to software (its table is built in); the rest ran on the PKA.
doAssert p256Backend == [2'u32, {count}'u32, {base}'u32, 0'u32] and pkaCalls == {count} + 1
doAssert irqsEnabled and not p256InFlight
# Invalid scalars are refused before the PKA sees them, as in software.
discard product("{h(0)}", "{h(G[0])}", "{h(G[1])}", -0x4C80)
discard product("{h(N)}", "{h(G[0])}", "{h(G[1])}", -0x4C80)
discard product("{h(5)}", "{h(G[0])}", "{h(G[1] ^ 1)}", -0x4C80)
doAssert pkaCalls == {count} + 1
"""
    run(tmp_path, checks)


def sign(d: int, z: int, k: int) -> tuple[int, int]:
    r = mul(k, G)[0] % N
    return r, pow(k, -1, N) * (z + r * d) % N


def test_p256_ecdsa_verification_multiplies_on_the_pka(tmp_path: Path) -> None:
    """m*G + n*Q, the shape of ECDSA verification: n*Q comes from the PKA,
    m*G from software (the base point's table is built in), and the sum is
    right, also where the two points are equal or one scalar is outside what
    the PKA is given."""
    rng = random.Random(1111)
    peer = mul(rng.randrange(1, N), G)
    m, n = rng.randrange(1, N), rng.randrange(1, N)

    def combined(m: int, n: int, point) -> str:
        x, y = add(mul(m, G), mul(n, point))
        return (f'doAssert combination("{h(m)}", "{h(n)}", "{h(point[0])}", "{h(point[1])}") == '
                f'(hex("{h(x)}"), hex("{h(y)}"))\n')

    d, z = rng.randrange(1, N), rng.randrange(1, 1 << 256)
    q = mul(d, G)
    r, s = sign(d, z, rng.randrange(1, N))
    key = f'"{h(q[0])}", "{h(q[1])}"'
    run(tmp_path, f"""
{combined(m, n, peer)}doAssert p256Backend[0] == 2 and p256Backend[1] == 1 and p256Backend[3] == 0 and pkaCalls == 2
{combined(m, m, G)}doAssert p256Backend[1] == 1       # m*G + m*G: the addition is a doubling
{combined(1, n, peer)}doAssert p256Backend[1] == 2
# 0*G is left to the stock code like any multiple of G; n*Q is still the PKA's.
{combined(0, n, peer)}doAssert p256Backend[0] == 2 and p256Backend[1] == 3 and p256Backend[3] == 0
doAssert pkaCalls == 4

# A real signature: accepted, and refused for another hash, signature or key.
let before = pkaCalls
doAssert verdict("{h(z)}", "{h(r)}", "{h(s)}", {key}) == 0
doAssert pkaCalls == before + 1
doAssert verdict("{h(z ^ 1)}", "{h(r)}", "{h(s)}", {key}) == -0x4E00
doAssert verdict("{h(z)}", "{h(r)}", "{h(s ^ 2)}", {key}) == -0x4E00
doAssert verdict("{h(z)}", "{h(r)}", "{h(s)}", "{h(peer[0])}", "{h(peer[1])}") == -0x4E00
doAssert pkaCalls == before + 4 and irqsEnabled and not p256InFlight

# With the PKA owned elsewhere the same checks run in software.
pkaFree = false
doAssert verdict("{h(z)}", "{h(r)}", "{h(s)}", {key}) == 0
doAssert verdict("{h(z ^ 1)}", "{h(r)}", "{h(s)}", {key}) == -0x4E00
{combined(m, n, peer)}doAssert pkaCalls == before + 4

# A product that is not on the curve is caught; the verdict is still right.
reset()
offCurveAt = 2
doAssert verdict("{h(z)}", "{h(r)}", "{h(s)}", {key}) == 0
doAssert p256Backend[0] == 3 and p256Backend[3] == 1 and pkaCalls == 2
doAssert verdict("{h(z)}", "{h(r)}", "{h(s)}", {key}) == 0 and pkaCalls == 2
""")


def test_p256_hardware_that_cannot_be_trusted_is_retired(tmp_path: Path) -> None:
    rng = random.Random(909)
    k, peer = rng.randrange(1, N), mul(rng.randrange(1, N), G)
    good = f"doAssert {call(k, peer)} == {expect(k, peer)}\n"
    run(tmp_path, f"""
reset()
wrongPointAt = 1                     # the probe sees a valid but wrong point
{good}{good}doAssert p256Backend == [3'u32, 0'u32, 2'u32, 0'u32] and pkaCalls == 1

reset()
offCurveAt = 3                       # a later product is not on the curve
{good}{good}{good}doAssert p256Backend == [3'u32, 1'u32, 2'u32, 1'u32] and pkaCalls == 3

reset()
failAt = 2                           # the driver reports failure
{good}{good}doAssert p256Backend == [3'u32, 0'u32, 2'u32, 1'u32] and pkaCalls == 2
doAssert irqsEnabled and not p256InFlight
""")


def test_p256_defers_while_the_pka_is_owned_or_running(tmp_path: Path) -> None:
    rng = random.Random(1010)
    k, peer = rng.randrange(1, N), mul(rng.randrange(1, N), G)
    good = f"doAssert {call(k, peer)} == {expect(k, peer)}\n"
    run(tmp_path, f"""
reset()
pkaFree = false                      # another CPU group owns the block
{good}doAssert p256Backend == [0'u32, 0'u32, 1'u32, 0'u32] and pkaCalls == 0
pkaFree = true
{good}doAssert p256Backend[0] == 2 and p256Backend[1] == 1 and p256Backend[3] == 0 and pkaCalls == 2
pkaFree = false
{good}doAssert p256Backend == [2'u32, 1'u32, 2'u32, 0'u32] and pkaCalls == 2

reset()
reenterAt = 2                        # a second request arrives mid-product
{good}doAssert reentered == 1          # it was told to use software
doAssert p256Backend[0] == 2 and p256Backend[1] == 1 and p256Backend[3] == 0 and pkaCalls == 2
""")
