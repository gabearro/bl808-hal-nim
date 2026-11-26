## Mbed TLS P-256 scalar multiplication on the BL808 PKA, through the HAL's
## own driver (pka.nim, the path BLE Secure Connections uses). ecp_p256_hook.c
## routes here the ECDH multiplications of a TLS key exchange and the two
## multiplications of an ECDSA signature check (the server's CertificateVerify
## or ServerKeyExchange, and certificate chains when the peer is verified),
## and keeps the stock Mbed TLS implementation as the fallback.
##
## The PKA ladder is not constant-time and takes no blinding. That suits the
## one-shot ephemeral scalars of ECDHE and the public values of a signature
## check; build with -d:bl808MbedTlsP256Software if a long-term P-256 private
## key is ever used on this device.

import ../[pka, sec]
import build, sec_borrow

static: doAssert MbedTlsHwP256, "p256_alt is the BL808 M0 hardware provider"

{.compile: MbedTlsPortDir & "/ecp_p256_hook.c".}

proc softwareMul(scalar, px, py, rx, ry: ptr uint8): cint
  {.importc: "bl808_software_p256_mul", cdecl.}

proc pkaAvailable(): bool {.inline.} =
  not pkaClaimed and secBlockOwner(secBlkPka) in [SecOwnerGroup0, SecOwnerFree]

proc pkaScalarMul(scalar, px, py, outX, outY: ptr uint32): bool =
  ## False for bad inputs and when a PKA command timed out (pka.nim fails the
  ## multiplication then instead of handing back what was in the registers).
  var handle = BflbEcdh(ecpId: EcpSecp256r1)
  bflb_sec_ecdh_get_encrypt_key(addr handle, px, py, scalar, outX, outY) == 0

include p256_engine

proc mbedtlsP256Mul(scalar, px, py, rx, ry: ptr uint8): cint
    {.exportc: "bl808_mbedtls_p256_mul", cdecl.} =
  p256Mul(scalar, px, py, rx, ry)

proc mbedtlsP256Reject() {.exportc: "bl808_mbedtls_p256_reject", cdecl.} =
  p256Reject()

proc mbedTlsP256InFlight*(): bool {.inline.} =
  ## A multiplication of this provider is on the PKA right now.
  p256InFlight

proc mbedTlsP256Backend*(): array[4, uint32] =
  ## State, hardware products, software products, hardware failures.
  p256Backend
