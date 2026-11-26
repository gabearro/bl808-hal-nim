## Mbed TLS RSA public-key operations on the BL808 PKA, through the HAL's own
## driver (pka.nim). rsa_exp_mod_hook.c routes the modular exponentiations
## Mbed TLS makes with public exponents here, which is every RSA signature
## check (the server's CertificateVerify or ServerKeyExchange, and certificate
## chains when the peer is verified), and keeps the stock implementation as
## the fallback. Moduli of 512 to 2048 bits and exponents up to 23 bits (3,
## 65537) go to the PKA, as in Bouffalo's own port; anything else, and every
## private-key operation, stays in the constant-time software of Mbed TLS.

import ../[pka, sec]
import build, sec_borrow
when MbedTlsHwP256:
  import p256_alt

static: doAssert MbedTlsHwRsa, "rsa_alt is the BL808 M0 hardware provider"

{.compile: MbedTlsPortDir & "/rsa_exp_mod_hook.c".}

proc softwareExpMod(n, a: ptr uint8; e: uint32; x: ptr uint8; length: csize_t): cint
  {.importc: "bl808_software_rsa_exp_mod", cdecl.}

template rsaPka: ptr BflbDevice = pka.pka    # the HAL's one PKA device

proc pkaAvailable(): bool {.inline.} =
  when MbedTlsHwP256:
    if mbedTlsP256InFlight(): return false
  secBlockOwner(secBlkPka) in [SecOwnerGroup0, SecOwnerFree]

include rsa_engine

proc mbedtlsRsaExpMod(n, a: ptr uint8; e: uint32; x: ptr uint8; length: csize_t): cint
    {.exportc: "bl808_mbedtls_rsa_exp_mod", cdecl.} =
  rsaExpMod(n, a, e, x, length)

proc mbedTlsRsaBackend*(): array[4, uint32] =
  ## State of the size last used, hardware results, software results,
  ## hardware failures.
  rsaBackend
