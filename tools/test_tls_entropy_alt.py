"""The TRNG entropy source of the BL808 Mbed TLS port (src/bl808/mbedtls/
entropy_alt.nim) on a fake TRNG: the poll callback alone, and the PSA random
generator of the vendored Mbed TLS seeded through it with the target's
entropy configuration (no platform source, MBEDTLS_ENTROPY_HARDWARE_ALT)."""

from pathlib import Path
import shutil
import subprocess

import pytest

from test_wifi_disconnect_tx import ROOT, procedure

FAKE_TRNG = r'''
type SecError = enum secOk, secBusy, secTimeout
var reads, failFrom: int            # failFrom: first failing read, 0 = never
proc trngReadAll(output: var array[8, uint32]; timeout: uint32 = 100_000): SecError =
  inc reads
  if failFrom != 0 and reads >= failFrom: return secBusy
  for i in 0 ..< 8:
    output[i] = 0x9E3779B9'u32 * uint32(8 * reads + i + 1)
  secOk
'''


def poll_source() -> str:
    return procedure((ROOT / "src/bl808/mbedtls/entropy_alt.nim").read_text(), "mbedtlsHardwarePoll")


def run(tmp_path: Path, code: str, *flags: str) -> None:
    nim = shutil.which("nim")
    if not nim or not (ROOT / "vendor/mbedtls/library/entropy.c").is_file():
        pytest.skip("needs Nim and the vendored Mbed TLS")
    path = tmp_path / "entropy.nim"
    path.write_text(code)
    result = subprocess.run(
        [nim, "c", "-r", "--skipParentCfg", "--skipProjCfg", "--skipUserCfg", "--hints:off",
         "--assertions:on", f"--path:{ROOT / 'src'}", f"--nimcache:{tmp_path / 'cache'}", *flags,
         str(path)],
        capture_output=True, text=True, timeout=300, cwd=ROOT)
    assert result.returncode == 0, result.stdout + result.stderr


def test_poll_returns_trng_words_in_order_and_never_overruns(tmp_path: Path) -> None:
    run(tmp_path, FAKE_TRNG + poll_source() + r'''
var buffer: array[140, uint8]
var produced: csize_t
let output = cast[ptr UncheckedArray[uint8]](addr buffer[4])

proc expectBytes(count: int) =
  for i in 0 ..< count:
    let word = 0x9E3779B9'u32 * uint32(8 * (i div 32 + 1) + (i mod 32) div 4 + 1)
    doAssert buffer[4 + i] == uint8(word shr (8 * (i mod 4)))
  for i in 0 ..< 4: doAssert buffer[i] == 0xEE
  for i in 4 + count ..< buffer.len: doAssert buffer[i] == 0xEE

for (length, expectedReads) in [(128, 4), (33, 2), (32, 1), (1, 1), (0, 0)]:
  for value in buffer.mitems: value = 0xEE
  reads = 0
  doAssert mbedtlsHardwarePoll(nil, output, length.csize_t, addr produced) == 0
  doAssert produced == length.csize_t and reads == expectedReads
  expectBytes(length)

# A TRNG that stops answering yields what it had, never an error or filler.
for (first, expected) in [(3, 64), (1, 0)]:
  for value in buffer.mitems: value = 0xEE
  reads = 0
  failFrom = first
  doAssert mbedtlsHardwarePoll(nil, output, 128, addr produced) == 0
  doAssert produced == expected.csize_t
  expectBytes(expected)
''')


def test_psa_random_generator_seeds_from_the_trng_only(tmp_path: Path) -> None:
    program = FAKE_TRNG + poll_source() + r'''
import bl808/mbedtls/tls_sources

proc psa_crypto_init(): int32 {.importc, cdecl, header: "<psa/crypto.h>".}
proc psa_generate_random(output: ptr uint8; size: csize_t): int32
  {.importc, cdecl, header: "<psa/crypto.h>".}
proc mbedtls_psa_crypto_free() {.importc, cdecl, header: "<psa/crypto.h>".}

when defined(trngDead):
  failFrom = 1
  doAssert psa_crypto_init() != 0          # refuses to run unseeded
  doAssert reads > 0
else:
  var first, second: array[48, uint8]
  doAssert psa_crypto_init() == 0
  let seedReads = reads
  doAssert seedReads >= 2                  # at least 48 bytes of seed
  doAssert psa_generate_random(addr first[0], 48) == 0
  doAssert psa_generate_random(addr second[0], 48) == 0
  doAssert first != second and first != default(typeof(first))
  mbedtls_psa_crypto_free()
'''
    run(tmp_path, program, "--passC:-DBL808_MBEDTLS_HW_ENTROPY")
    run(tmp_path, program, "--passC:-DBL808_MBEDTLS_HW_ENTROPY", "-d:trngDead")
