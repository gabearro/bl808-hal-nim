## Host fuzzer for the NSB1 container parser (src/bl808/secureboot/container.nim).
##
## parseNsb1 runs in mm:none on fully untrusted flash bytes, so it must never
## read out of bounds or crash on ANY input. Compiled with --checks:on, any OOB
## read trips a Nim defect and fails the run. We throw a large mix of random and
## structured-adversarial buffers at it and assert: (1) it always returns, (2) a
## reported nsbOk implies the declared fields are self-consistent and the read
## window stayed inside the buffer.
##
## Build/run:
##   nim c -r --path:src/bl808/secureboot --checks:on tools/fuzz_nsb1.nim

import ../src/bl808/secureboot/container

# Tiny deterministic xorshift PRNG (Math.random is unavailable / nondeterministic;
# a fixed seed makes failures reproducible).
var rngState: uint64 = 0x243F6A8885A308D3'u64
proc rnd(): uint32 =
  var x = rngState
  x = x xor (x shl 13)
  x = x xor (x shr 7)
  x = x xor (x shl 17)
  rngState = x
  (x and 0xFFFFFFFF'u64).uint32

proc rndByte(): uint8 = (rnd() and 0xFF).uint8

proc checkParse(buf: seq[uint8]): bool =
  ## Returns false (failure) only if a result is internally inconsistent.
  var hdr: Nsb1Header
  let raw = if buf.len == 0: @[] else: buf
  let err = parseNsb1(raw, hdr)
  if err == nsbOk:
    # parseNsb1 only reads the fixed 256-byte header; a buffer that parses must
    # be at least that big, and the type must be in range.
    if raw.len < Nsb1HeaderSize: return false
    if hdr.imageType < 1 or hdr.imageType > 4: return false
    if hdr.hdrVersion != 1: return false
  true

proc validHeaderTemplate(): seq[uint8] =
  ## A structurally valid 256-byte header (magic+version+type), zero elsewhere.
  result = newSeq[uint8](Nsb1HeaderSize)
  result[0] = 'N'.uint8; result[1] = 'S'.uint8
  result[2] = 'B'.uint8; result[3] = '1'.uint8
  result[OffHdrVer] = 1
  result[OffImgType] = 1

proc main() =
  var iters = 0
  var oks = 0

  # 1. Pure random buffers of every length 0..520.
  for trial in 0 ..< 200_000:
    let n = (rnd() mod 521).int
    var buf = newSeq[uint8](n)
    for i in 0 ..< n: buf[i] = rndByte()
    doAssert checkParse(buf), "inconsistent parse on random buffer len=" & $n
    inc iters

  # 2. Structured: valid header, then mutate one field to an adversarial value.
  #    Especially payloadLen near 0xFFFFFFFF (the overflow-bait field) and a
  #    truncated buffer, which downstream length checks must survive.
  let badLens = [0xFFFFFFFF'u32, 0xFFFFFF00'u32, 0x80000000'u32, 0x7FFFFFFF'u32,
                 0xFFFFFE00'u32, Nsb1HeaderSize.uint32, 0'u32, 1'u32]
  let truncs = [0, 1, 4, 8, 255, 256, 257, 320, 512]
  for pl in badLens:
    for tlen in truncs:
      var buf = validHeaderTemplate()
      buf[OffPayloadLen]   = (pl and 0xFF).uint8
      buf[OffPayloadLen+1] = ((pl shr 8) and 0xFF).uint8
      buf[OffPayloadLen+2] = ((pl shr 16) and 0xFF).uint8
      buf[OffPayloadLen+3] = ((pl shr 24) and 0xFF).uint8
      if tlen < buf.len: buf.setLen(tlen)
      doAssert checkParse(buf), "inconsistent parse: pl=" & $pl & " tlen=" & $tlen
      inc iters
      var hdr: Nsb1Header
      if parseNsb1(buf, hdr) == nsbOk: inc oks

  # 3. Every imageType byte 0..255 against a valid header.
  for t in 0 ..< 256:
    var buf = validHeaderTemplate()
    buf[OffImgType] = t.uint8
    doAssert checkParse(buf), "inconsistent parse: imageType=" & $t
    inc iters

  echo "fuzz_nsb1: ", iters, " iterations, no OOB / no inconsistency (", oks,
       " structurally-valid headers)"
  echo "PASS"

main()
