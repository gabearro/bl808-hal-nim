## P-256 scalar multiplication policy for the BL808 PKA.
##
## Included by p256_alt.nim and by tools/test_tls_p256_alt.py. The includer
## provides pkaAvailable, pkaScalarMul, secIrqSave, secIrqRestore and
## softwareMul. Coordinates and scalars are 32 big-endian bytes.
##
## The PKA is a single, non-reentrant resource with per-block group ownership.
## A multiplication is attempted only when the block is free or already owned
## by this CPU group and no other multiplication of this provider is running;
## otherwise, and after any failed check, the caller computes in software.
## pkaScalarMul reports false for a PKA command that timed out as well (the
## driver's multiplication fails then): that retires the PKA like any fault.
## The first use compares one product with the software result, and every
## product is checked to lie on the curve (in ecp_p256_hook.c).

type
  P256Words = array[8, uint32]   # 32 bytes, aligned for the PKA
  P256Result = enum
    p256Fault, p256Deferred, p256Done

var
  ## [0] 0 unchecked, 1 probing, 2 usable, 3 unavailable;
  ## [1] hardware products; [2] software products; [3] hardware failures.
  p256Backend {.exportc: "nim_mbedtls_p256_backend".}: array[4, uint32]
  p256InFlight: bool

proc claimPka(): bool =
  let saved = secIrqSave()
  defer: secIrqRestore(saved)
  if p256InFlight or not pkaAvailable(): return false
  p256InFlight = true
  true

proc p256HardwareMul(scalar, px, py, rx, ry: ptr uint8): P256Result =
  if not claimPka(): return p256Deferred
  var k, x, y, outX, outY: P256Words
  copyMem(addr k, scalar, 32)
  copyMem(addr x, px, 32)
  copyMem(addr y, py, 32)
  if pkaScalarMul(addr k[0], addr x[0], addr y[0], addr outX[0], addr outY[0]):
    copyMem(rx, addr outX, 32)
    copyMem(ry, addr outY, 32)
    result = p256Done
  for word in k.mitems: word = 0
  for word in outX.mitems: word = 0
  for word in outY.mitems: word = 0
  p256InFlight = false

const
  Gx = [0x6B'u8, 0x17, 0xD1, 0xF2, 0xE1, 0x2C, 0x42, 0x47, 0xF8, 0xBC, 0xE6, 0xE5,
        0x63, 0xA4, 0x40, 0xF2, 0x77, 0x03, 0x7D, 0x81, 0x2D, 0xEB, 0x33, 0xA0,
        0xF4, 0xA1, 0x39, 0x45, 0xD8, 0x98, 0xC2, 0x96]
  Gy = [0x4F'u8, 0xE3, 0x42, 0xE2, 0xFE, 0x1A, 0x7F, 0x9B, 0x8E, 0xE7, 0xEB, 0x4A,
        0x7C, 0x0F, 0x9E, 0x16, 0x2B, 0xCE, 0x33, 0x57, 0x6B, 0x31, 0x5E, 0xCE,
        0xCB, 0xB6, 0x40, 0x68, 0x37, 0xBF, 0x51, 0xF5]

proc probeP256Backend() =
  ## A small multiple of G would pass with a mangled scalar: use a full-width
  ## scalar and compare both coordinates.
  if p256InFlight or not pkaAvailable(): return   # contention is not a failed check
  p256Backend[0] = 1
  var scalar, expectedX, expectedY, actualX, actualY: array[32, uint8]
  var px = Gx
  var py = Gy
  for i in 0 ..< scalar.len: scalar[i] = uint8(0x1D + 9 * i)
  if softwareMul(addr scalar[0], addr px[0], addr py[0],
                 addr expectedX[0], addr expectedY[0]) != 0:
    p256Backend[0] = 3
    return
  case p256HardwareMul(addr scalar[0], addr px[0], addr py[0], addr actualX[0], addr actualY[0])
  of p256Deferred: p256Backend[0] = 0
  of p256Fault: p256Backend[0] = 3
  of p256Done:
    p256Backend[0] = if actualX == expectedX and actualY == expectedY: 2'u32 else: 3'u32

proc p256Mul(scalar, px, py, rx, ry: ptr uint8): cint =
  ## 0 when the PKA produced the product, 1 when the caller must use software.
  # Multiples of the base point (key generation, half of a signature check)
  # stay in software: Mbed TLS has G's table built in, and on this chip that
  # takes 26 ms against the PKA's 41 ms. Any other point takes 73 ms in
  # software, so those go to the PKA.
  var gx = Gx
  var gy = Gy
  if equalMem(px, addr gx[0], 32) and equalMem(py, addr gy[0], 32):
    inc p256Backend[2]
    return 1
  if p256Backend[0] == 0:
    probeP256Backend()
  if p256Backend[0] == 2:
    case p256HardwareMul(scalar, px, py, rx, ry)
    of p256Done:
      inc p256Backend[1]
      return 0
    of p256Deferred: discard
    of p256Fault:
      inc p256Backend[3]
      p256Backend[0] = 3
  inc p256Backend[2]
  1

proc p256Reject() =
  ## The product just handed out was not a point on the curve (found by
  ## ecp_p256_hook.c, which then computed in software): retire the PKA.
  dec p256Backend[1]
  inc p256Backend[2]
  inc p256Backend[3]
  p256Backend[0] = 3
