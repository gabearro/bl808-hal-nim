## The rest of the vendored Mbed TLS library behind kernel/tls.nim: PSA
## Crypto, public-key and X.509 parsing, and the TLS 1.2/1.3 client. Hashes,
## HMAC and AES come from crypto.nim, which a Wi-Fi image already compiles.

import crypto, hw
export crypto, hw

when not MbedTlsHwP256:
  {.compile: MbedTlsLibrary & "/ecp.c".}   # otherwise through ecp_p256_hook.c

{.compile: MbedTlsLibrary & "/asn1parse.c".}
{.compile: MbedTlsLibrary & "/asn1write.c".}
when not MbedTlsHwRsa:
  {.compile: MbedTlsLibrary & "/bignum.c".}   # otherwise through rsa_exp_mod_hook.c
{.compile: MbedTlsLibrary & "/bignum_core.c".}
{.compile: MbedTlsLibrary & "/chacha20.c".}
{.compile: MbedTlsLibrary & "/chachapoly.c".}
{.compile: MbedTlsLibrary & "/cipher.c".}
{.compile: MbedTlsLibrary & "/cipher_wrap.c".}
{.compile: MbedTlsLibrary & "/ctr_drbg.c".}
{.compile: MbedTlsLibrary & "/ecdh.c".}
{.compile: MbedTlsLibrary & "/ecdsa.c".}
{.compile: MbedTlsLibrary & "/ecp_curves.c".}
{.compile: MbedTlsLibrary & "/entropy.c".}
{.compile: MbedTlsLibrary & "/entropy_poll.c".}
when not MbedTlsHwGcm:
  {.compile: MbedTlsLibrary & "/gcm.c".}   # otherwise through gcm_hook.c
{.compile: MbedTlsLibrary & "/hkdf.c".}
{.compile: MbedTlsLibrary & "/mps_reader.c".}
{.compile: MbedTlsLibrary & "/oid.c".}
{.compile: MbedTlsLibrary & "/pk.c".}
{.compile: MbedTlsLibrary & "/pk_ecc.c".}
{.compile: MbedTlsLibrary & "/pk_wrap.c".}
{.compile: MbedTlsLibrary & "/pkparse.c".}
{.compile: MbedTlsLibrary & "/poly1305.c".}
{.compile: MbedTlsLibrary & "/psa_crypto.c".}
{.compile: MbedTlsLibrary & "/psa_crypto_aead.c".}
{.compile: MbedTlsLibrary & "/psa_crypto_cipher.c".}
{.compile: MbedTlsLibrary & "/psa_crypto_client.c".}
{.compile: MbedTlsLibrary & "/psa_crypto_driver_wrappers_no_static.c".}
{.compile: MbedTlsLibrary & "/psa_crypto_ecp.c".}
{.compile: MbedTlsLibrary & "/psa_crypto_hash.c".}
{.compile: MbedTlsLibrary & "/psa_crypto_mac.c".}
{.compile: MbedTlsLibrary & "/psa_crypto_random.c".}
{.compile: MbedTlsLibrary & "/psa_crypto_rsa.c".}
{.compile: MbedTlsLibrary & "/psa_crypto_slot_management.c".}
{.compile: MbedTlsLibrary & "/psa_util.c".}
{.compile: MbedTlsLibrary & "/rsa.c".}
{.compile: MbedTlsLibrary & "/rsa_alt_helpers.c".}
{.compile: MbedTlsLibrary & "/ssl_ciphersuites.c".}
{.compile: MbedTlsLibrary & "/ssl_client.c".}
{.compile: MbedTlsLibrary & "/ssl_msg.c".}
{.compile: MbedTlsLibrary & "/ssl_tls.c".}
{.compile: MbedTlsLibrary & "/ssl_tls12_client.c".}
{.compile: MbedTlsLibrary & "/ssl_tls13_client.c".}
{.compile: MbedTlsLibrary & "/ssl_tls13_generic.c".}
{.compile: MbedTlsLibrary & "/ssl_tls13_keys.c".}
{.compile: MbedTlsLibrary & "/x509.c".}
{.compile: MbedTlsLibrary & "/x509_crt.c".}
