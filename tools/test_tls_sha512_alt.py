"""Known-answer tests for the SEC_ENG SHA-384/512 provider (src/bl808/mbedtls):
the vendored Mbed TLS built with MBEDTLS_SHA512_PROCESS_ALT hashes through the
Nim engine code into a register-level fake of the SHA block, and the digests
are compared with hashlib. The fake computes the compression function with
its own implementation, independent of Mbed TLS."""

import hashlib
from pathlib import Path
import shutil
import subprocess

import pytest

ROOT = Path(__file__).resolve().parents[1]
PORT = ROOT / "src/bl808/mbedtls"
LIBRARY = ROOT / "vendor/mbedtls/library"


def icbrt(value: int) -> int:
    low, high = 0, 1 << (value.bit_length() // 3 + 2)
    while low < high:
        mid = (low + high + 1) // 2
        if mid ** 3 <= value: low = mid
        else: high = mid - 1
    return low


PRIMES = [n for n in range(2, 420) if all(n % d for d in range(2, int(n ** 0.5) + 1))][:80]
ROUND_CONSTANTS = [icbrt(p << 192) & 0xFFFFFFFFFFFFFFFF for p in PRIMES]
assert ROUND_CONSTANTS[0] == 0x428A2F98D728AE22 and ROUND_CONSTANTS[79] == 0x6C44198C4A475817

FAKE = r"""
import bl808/mbedtls/build
{.passC: "-DBL808_MBEDTLS_HW_SHA512".}
{.compile: "LIBRARY/sha512.c".}
{.compile: "LIBRARY/platform.c".}
{.compile: "LIBRARY/platform_util.c".}
{.compile: "PORT/sha512_software.c".}

const SecEngBase = 0x20004000'u
{.pragma: sha512Dma.}

type Sha512Context {.importc: "mbedtls_sha512_context", header: "<mbedtls/sha512.h>".} = object
  state: array[8, uint64]

proc softwareProcess(ctx: ptr Sha512Context; data: ptr uint8): cint
  {.importc: "bl808_software_sha512_process", cdecl.}
proc sha512(data: ptr uint8; length: csize_t; digest: ptr uint8; is384: cint): cint
  {.importc: "mbedtls_sha512", cdecl, header: "<mbedtls/sha512.h>".}

const
  OriginalControl = 0'u32
  OriginalLink = 0x22031230'u32
  RoundConstants = [ROUND_CONSTANTS]

var
  controlValue = OriginalControl
  linkValue = OriginalLink
  irqsEnabled = true
  dmaOk = true
  inFlight, donePending: bool
  polls, started, completed, writesAtTrigger: int
  corruptAt, stuckAt, silentAt: int       # 1-based block numbers, 0 = never
  writes: seq[tuple[address: uint, value: uint32]]

proc secIrqSave(): uint32 =
  result = if irqsEnabled: 8'u32 else: 0'u32
  irqsEnabled = false
proc secIrqRestore(saved: uint32) = irqsEnabled = (saved and 8) != 0
proc fenceIo() = discard
proc regRead(address: uint): uint32
proc regWrite(address: uint; value: uint32)
proc dmaVisible(address, size: uint): bool

include "PORT/sha512_engine.nim"

proc provider(ctx: ptr Sha512Context; data: ptr uint8): cint
    {.exportc: "bl808_mbedtls_sha512_process", cdecl.} =
  sha512Process(ctx, data)

proc dmaVisible(address, size: uint): bool =
  doAssert (address == cast[uint](addr sha512Descriptor) and size == 72) or
    (address == cast[uint](addr sha512Words) and size == 128)
  dmaOk

proc dmaWord(address: uint): bool =
  let descriptor = cast[uint](addr sha512Descriptor)
  let words = cast[uint](addr sha512Words)
  (address and 3) == 0 and ((address >= descriptor and address < descriptor + 72) or
                            (address >= words and address < words + 128))

proc rotr(x: uint64; n: int): uint64 = (x shr n) or (x shl (64 - n))

proc referenceCompress(state: var array[8, uint64]; data: array[128, uint8]) =
  var w: array[80, uint64]
  for i in 0 ..< 16:
    for k in 0 ..< 8: w[i] = (w[i] shl 8) or data[8 * i + k].uint64
  for i in 16 ..< 80:
    let s0 = rotr(w[i-15], 1) xor rotr(w[i-15], 8) xor (w[i-15] shr 7)
    let s1 = rotr(w[i-2], 19) xor rotr(w[i-2], 61) xor (w[i-2] shr 6)
    w[i] = w[i-16] + s0 + w[i-7] + s1
  var v = state
  for i in 0 ..< 80:
    let t1 = v[7] + (rotr(v[4], 14) xor rotr(v[4], 18) xor rotr(v[4], 41)) +
             ((v[4] and v[5]) xor ((not v[4]) and v[6])) + RoundConstants[i] + w[i]
    let t2 = (rotr(v[0], 28) xor rotr(v[0], 34) xor rotr(v[0], 39)) +
             ((v[0] and v[1]) xor (v[0] and v[2]) xor (v[1] and v[2]))
    for j in countdown(7, 1): v[j] = v[j - 1]
    v[4] += t1
    v[0] = t1 + t2
  for i in 0 ..< 8: state[i] += v[i]

proc engineRuns() =
  ## What the SHA block does with a one-block SHA-512 link descriptor:
  ## continue from the digest in the descriptor, hash the 128 bytes the
  ## source address points at, store the digest back. The descriptor holds
  ## the digest as the 64 big-endian digest bytes in memory order (the
  ## vendor driver copies them out as the result).
  doAssert sha512Descriptor.control ==
    ((4'u32 shl 2) or (1'u32 shl 6) or (1'u32 shl 10) or (1'u32 shl 16))
  let digest = cast[ptr array[64, uint8]](addr sha512Descriptor.digest[0])
  var state: array[8, uint64]
  var data: array[128, uint8]
  for i in 0 ..< 8:
    for k in 0 ..< 8: state[i] = (state[i] shl 8) or digest[8 * i + k].uint64
  copyMem(addr data[0], addr sha512Words[0], 128)
  referenceCompress(state, data)
  if started == corruptAt: state[3] = state[3] xor 0x0001000000000000'u64
  for i in 0 ..< 8:
    for k in 0 ..< 8: digest[8 * i + k] = uint8((state[i] shr (56 - 8 * k)) and 0xFF)

proc regRead(address: uint): uint32 =
  if address == Sha512LinkAddress: return linkValue
  if address == Sha512Control:
    if inFlight:
      inc polls
      if started == stuckAt: return controlValue or Sha512Busy
      if started == silentAt:
        inFlight = false
        return controlValue
      if polls < 3: return controlValue or Sha512Busy
      if polls == 3: return controlValue or Sha512Busy or Sha512Done
      engineRuns()
      inFlight = false
      donePending = true
      inc completed
    return controlValue or (if donePending: Sha512Done else: 0'u32)
  doAssert dmaWord(address), "unexpected MMIO read"
  doAssert not inFlight and completed == started, "digest read before completion"
  cast[ptr uint32](address)[]

proc regWrite(address: uint; value: uint32) =
  doAssert not inFlight, "MMIO write while the engine owns the buffers"
  writes.add((address, value))
  if address == Sha512LinkAddress:
    linkValue = value
  elif address == Sha512Control:
    if (value and Sha512ClearDone) != 0: donePending = false
    if (value and Sha512Trigger) != 0:
      doAssert not irqsEnabled, "trigger with interrupts enabled"
      doAssert not donePending
      doAssert (value and (Sha512Enable or Sha512LinkMode or Sha512MaskIrq)) ==
        (Sha512Enable or Sha512LinkMode or Sha512MaskIrq)
      doAssert linkValue == cast[uint32](cast[uint](addr sha512Descriptor))
      doAssert sha512Descriptor.source == cast[uint32](cast[uint](addr sha512Words))
      inc started
      polls = 0
      inFlight = true
      writesAtTrigger = writes.len
    controlValue = value and not (Sha512Trigger or Sha512ClearDone or Sha512Busy or Sha512Done)
  else:
    doAssert dmaWord(address) and value == 0, "only the scrub may write DMA words"
    cast[ptr uint32](address)[] = value

proc engineAtRest(): bool =
  irqsEnabled and controlValue == OriginalControl and linkValue == OriginalLink and
    sha512Descriptor == default(Sha512Link) and sha512Words == default(Sha512Words)

proc reset() =
  controlValue = OriginalControl
  linkValue = OriginalLink
  irqsEnabled = true
  dmaOk = true
  inFlight = false
  donePending = false
  polls = 0; started = 0; completed = 0; writesAtTrigger = 0
  corruptAt = 0; stuckAt = 0; silentAt = 0
  writes.setLen(0)
  sha512Backend = default(typeof(sha512Backend))
  sha512Descriptor = default(Sha512Link)
  sha512Words = default(Sha512Words)

var input: array[4 + MAX_LENGTH, uint8]
for i in 0 ..< input.len: input[i] = uint8((i * 131 + 89) and 255)   # matches the Python side

proc hash(offset, length: int): array[64, uint8] =
  doAssert sha512(addr input[offset], length.csize_t, addr result[0], 0) == 0

proc hash384(offset, length: int): array[48, uint8] =
  var whole: array[64, uint8]     # Mbed TLS writes 48 bytes
  doAssert sha512(addr input[offset], length.csize_t, addr whole[0], 1) == 0
  for i in 0 ..< 48: result[i] = whole[i]

proc blocks(length: int): int = (length + 17 + 127) div 128
"""


def run(tmp_path: Path, checks: str, vectors: list[tuple[int, int]]) -> None:
    nim = shutil.which("nim")
    if not nim or not (LIBRARY / "sha512.c").is_file():
        pytest.skip("needs Nim and the vendored Mbed TLS")
    data = bytes((i * 131 + 89) & 255 for i in range(4 + max(length for _, length in vectors)))

    def table(name: str, digest) -> str:
        return "\n".join(
            f"const {name}_{offset}_{length} = ["
            + ", ".join(f"{byte}'u8" for byte in digest(data[offset:offset + length]).digest()) + "]"
            for offset, length in vectors)

    source = (FAKE.replace("LIBRARY", str(LIBRARY)).replace("PORT", str(PORT))
              .replace("ROUND_CONSTANTS", ", ".join(f"0x{k:016x}'u64" for k in ROUND_CONSTANTS))
              .replace("MAX_LENGTH", str(max(length for _, length in vectors)))
              + table("digest", hashlib.sha512) + "\n" + table("digest384", hashlib.sha384)
              + "\n" + checks)
    path = tmp_path / "sha512_provider.nim"
    path.write_text(source)
    result = subprocess.run(
        [nim, "c", "-r", "--skipParentCfg", "--skipProjCfg", "--skipUserCfg", "--hints:off",
         "--assertions:on", f"--path:{ROOT / 'src'}", f"--nimcache:{tmp_path / 'cache'}", str(path)],
        capture_output=True, text=True, timeout=180, cwd=ROOT)
    assert result.returncode == 0, result.stdout + result.stderr


LENGTHS = [0, 1, 111, 112, 127, 128, 129, 239, 240, 256, 1000]
VECTORS = [(offset, length) for offset in range(4) for length in LENGTHS]


def test_sha512_digests_through_the_engine_match_hashlib(tmp_path: Path) -> None:
    checks = "var expectedBlocks = 0\n"
    for offset, length in VECTORS:
        checks += f"doAssert hash({offset}, {length}) == digest_{offset}_{length}\n"
        checks += f"doAssert hash384({offset}, {length}) == digest384_{offset}_{length}\n"
        checks += f"expectedBlocks += 2 * blocks({length})\n"
        checks += "doAssert engineAtRest()\n"
    checks += r"""
# One probe block, then every block of every message on the engine: SHA-384
# runs through the same mode with its own initial values.
doAssert sha512Backend == [2'u32, expectedBlocks.uint32, 0'u32, 0'u32]
doAssert started == expectedBlocks + 1 and completed == started
doAssert sha512Process(nil, addr input[0]) == -0x0075
"""
    run(tmp_path, checks, VECTORS)


def test_sha512_leaves_a_claimed_engine_alone(tmp_path: Path) -> None:
    """Busy, enabled (the SHA-1 lease, or a SHA-256 block's owner) or holding
    a result: hash in software without a single register write, and come
    back when it is free."""
    run(tmp_path, r"""
for flag in [Sha512Busy, Sha512Enable, Sha512Done]:
  reset()
  controlValue = OriginalControl or flag
  doAssert hash(1, 1000) == digest_1_1000
  doAssert writes.len == 0 and started == 0 and irqsEnabled
  doAssert sha512Backend == [0'u32, 0'u32, blocks(1000).uint32, 0'u32]
  controlValue = OriginalControl
  doAssert hash(1, 1000) == digest_1_1000
  doAssert sha512Backend == [2'u32, blocks(1000).uint32, blocks(1000).uint32, 0'u32]
  doAssert engineAtRest()
""", [(1, 1000)])


def test_sha512_engine_that_fails_the_probe_is_never_used(tmp_path: Path) -> None:
    run(tmp_path, r"""
reset()
corruptAt = 1
doAssert hash(0, 1000) == digest_0_1000
doAssert sha512Backend == [3'u32, 0'u32, blocks(1000).uint32, 0'u32]
doAssert started == 1 and engineAtRest()
doAssert hash384(0, 1000) == digest384_0_1000
doAssert started == 1

reset()
dmaOk = false
doAssert hash(0, 1000) == digest_0_1000
doAssert sha512Backend == [3'u32, 0'u32, blocks(1000).uint32, 0'u32]
doAssert writes.len == 0 and started == 0
""", [(0, 1000)])


@pytest.mark.parametrize("stuck", [True, False], ids=["busy-quarantine", "idle-cleanup"])
def test_sha512_timeout_keeps_the_digest_right(tmp_path: Path, stuck: bool) -> None:
    """The fifth block (probe included) never completes. The message is still
    hashed correctly; a busy engine keeps its buffers, an idle one is cleaned."""
    run(tmp_path, f"const stuck = {str(stuck).lower()}\n" + r"""
reset()
if stuck: stuckAt = 5 else: silentAt = 5
doAssert hash(2, 1000) == digest_2_1000
doAssert sha512Backend == [3'u32, 3'u32, (blocks(1000) - 3).uint32, 1'u32]
doAssert started == 5 and completed == 4 and irqsEnabled
if stuck:
  doAssert inFlight and writes.len == writesAtTrigger
  doAssert (controlValue and Sha512Enable) != 0      # still claimed: nobody may borrow it
  doAssert sha512Descriptor != default(Sha512Link)
else:
  doAssert engineAtRest()
let triggers = started
inFlight = false
doAssert hash(2, 1000) == digest_2_1000 and started == triggers
""", [(2, 1000)])
