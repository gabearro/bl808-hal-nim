## BL808 hardware backends for the vendored Mbed TLS: SHA-224/256, SHA-384/512
## and AES on SEC_ENG, P-256 and RSA public-key operations on the PKA, entropy
## from the TRNG. Importing this module switches them on for the whole image
## (build.nim lists the compile-time software selectors); every backend keeps
## the stock software implementation as its run-time fallback. On the host
## this module is empty.
##
## SHA-1 is not switched on from here: its SEC_ENG provider belongs to the
## Wi-Fi build (wifi/mbedtls_sha1_alt.nim, -d:bl808WifiMbedTlsSha1Hardware),
## where WPA2 key derivation is its user; TLS handshakes do not hash with it.
## AES-GCM records as a whole (CTR on the AES block, GHASH on the GMAC block)
## come with AES. Not on the chip at all: ChaCha20-Poly1305, MD5, curves
## other than P-256, RSA keys above 2048 bits and every private-key RSA
## operation.

import build
export build

when MbedTlsHwSha256:
  {.passC: "-DBL808_MBEDTLS_HW_SHA256".}
  import sha256_alt
  export mbedTlsSha256Backend
when MbedTlsHwSha512:
  {.passC: "-DBL808_MBEDTLS_HW_SHA512".}
  import sha512_alt
  export mbedTlsSha512Backend
when MbedTlsHwAes:
  {.passC: "-DBL808_MBEDTLS_HW_AES".}
  import aes_alt
  export mbedTlsAesBackend
when MbedTlsHwGcm:
  import gcm_alt
  export mbedTlsGcmBackend
when MbedTlsHwP256:
  {.passC: "-DBL808_MBEDTLS_HW_P256".}
  import p256_alt
  export mbedTlsP256Backend
when MbedTlsHwRsa:
  {.passC: "-DBL808_MBEDTLS_HW_RSA".}
  import rsa_alt
  export mbedTlsRsaBackend
when MbedTlsHwEntropy:
  {.passC: "-DBL808_MBEDTLS_HW_ENTROPY".}
  import entropy_alt
