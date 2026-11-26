## Host test of `mp3dec`: bit-exact against upstream's Rust decoder.
##
## Every `data/mp3/<name>.mp3` has a `<name>.ref` written by a small harness
## around upstream's `nanomp3-core` (built as the firmware builds it:
## `default-features = false`, `Decoder::new()`, i16 output). A reference
## holds one trace per feeding mode, introduced by `# window <n>`: `decode`
## is called with the rest of the file (`0`) or with at most `n` bytes of
## it, like a stream buffer. A trace has
##   `<consumed> <status> <samples> <channels> <hz> <kbps> <layer> <fnv>`
## per call (FNV-1a 64 of that frame's little-endian PCM),
##   `S <n> <fnv>` after every fourth call (the spectrum sums taken then,
## hashed cumulatively as float bits followed by the count), and a final
##   `E <calls> <fnv of all PCM> <n> <spectrum fnv>`.
## `data/mp3/README` says how each clip was made.
##
## `t_mp3dec trace <file> <window>` prints the trace of a file.

import std/[os, strutils, algorithm]
import ../mp3dec

const DataDir = currentSourcePath().parentDir / "data" / "mp3"

type Fnv = uint64
const FnvInit = 0xcbf29ce484222325'u64

proc add(h: var Fnv; b: byte) =
  h = (h xor b) * 0x100000001b3'u64

proc add(h: var Fnv; v: uint32) =
  for i in 0 ..< 4:
    h.add byte((v shr (8 * i)) and 0xFF)

proc addSpectrum(h: var Fnv; d: var Mp3Decoder): uint32 =
  var energy: array[SpectrumBands, float32]
  result = d.takeSpectrum(energy)
  for e in energy:
    h.add cast[uint32](e)
  h.add result

proc trace(data: openArray[byte]; window: int): seq[string] =
  ## Decode `data` to the end and describe every call.
  var d = create(Mp3Decoder)
  defer: dealloc(d)
  initDecoder(d[])
  var pcm: array[MaxSamplesPerFrame, int16]
  var info: FrameInfo
  var pos = 0
  var calls = 0
  var total, spec = FnvInit
  while pos < data.len:
    let last = if window == 0: data.len else: min(pos + window, data.len)
    let (consumed, status) = d[].decode(data.toOpenArray(pos, last - 1), pcm, info)
    doAssert consumed >= 0 and pos + consumed <= last
    var frame = FnvInit
    if status == dsNoFrame:
      doAssert info == FrameInfo()
    else:
      doAssert info.channels in 1 .. 2
      doAssert (status == dsDecoded) == (info.samplesProduced > 0)
    for i in 0 ..< info.samplesProduced * info.channels:
      let s = cast[uint16](pcm[i])
      for b in [byte(s and 0xFF), byte(s shr 8)]:
        frame.add b
        total.add b
    result.add [$consumed, $ord(status), $info.samplesProduced, $info.channels,
                $info.sampleRate, $info.bitrateKbps, $info.layer,
                frame.toHex.toLowerAscii].join(" ")
    pos += consumed
    inc calls
    if calls mod 4 == 0:
      let n = spec.addSpectrum(d[])
      result.add "S " & $n & " " & spec.toHex.toLowerAscii
    if consumed == 0:
      break
  let n = spec.addSpectrum(d[])
  result.add "E " & $calls & " " & total.toHex.toLowerAscii & " " & $n & " " &
    spec.toHex.toLowerAscii

proc readBytes(path: string): seq[byte] =
  let s = readFile(path)
  result = newSeq[byte](s.len)
  for i, c in s:
    result[i] = byte(c)

proc decodeAll(data: openArray[byte]; counts: var array[DecodeStatus, int]): int =
  ## Decode to the end, tallying statuses; returns the PCM frames produced.
  var d = create(Mp3Decoder)
  defer: dealloc(d)
  initDecoder(d[])
  var pcm: array[MaxSamplesPerFrame, int16]
  var info: FrameInfo
  var pos = 0
  while pos < data.len:
    let (consumed, status) = d[].decode(data.toOpenArray(pos, data.high), pcm, info)
    inc counts[status]
    result += info.samplesProduced
    if consumed == 0:
      break
    pos += consumed

proc checkReferences(): int =
  ## Compare every fixture with its reference; returns how many were checked.
  var names: seq[string]
  for f in walkFiles(DataDir / "*.mp3"):
    names.add f.splitFile.name
  names.sort()
  for name in names:
    let data = readBytes(DataDir / name & ".mp3")
    var window = -1
    var want: seq[string]
    var modes = 0
    template finish() =
      if window >= 0:
        let got = trace(data, window)
        for i in 0 ..< min(got.len, want.len):
          doAssert got[i] == want[i], name & " window " & $window & " line " &
            $(i + 1) & ": got '" & got[i] & "', upstream '" & want[i] & "'"
        doAssert got.len == want.len, name & " window " & $window & ": " &
          $got.len & " lines, upstream " & $want.len
        inc modes
    for line in lines(DataDir / name & ".ref"):
      if line.startsWith("# window "):
        finish()
        window = parseInt(line[9 .. ^1])
        want.setLen 0
      elif line.len > 0:
        want.add line
    finish()
    doAssert modes >= 1, name & ": empty reference"
    inc result

proc statusCounts(name: string): array[DecodeStatus, int] =
  discard decodeAll(readBytes(DataDir / name & ".mp3"), result)

proc testApi() =
  var d = create(Mp3Decoder)
  defer: dealloc(d)
  doAssert sizeof(Mp3Decoder) < 24 * 1024
  doAssert SpectrumBands == 40 and MaxSamplesPerFrame == 2304
  initDecoder(d[])
  var pcm: array[MaxSamplesPerFrame, int16]
  var info: FrameInfo
  var energy: array[SpectrumBands, float32]

  # Nothing in, nothing consumed.
  doAssert d[].decode([], pcm, info) == (0, dsNoFrame)
  # Junk is skipped whole; up to four bytes are never examined.
  var junk: array[300, byte]
  for i, b in junk.mpairs: b = byte(i * 7)
  doAssert d[].decode(junk, pcm, info) == (300, dsNoFrame)
  doAssert d[].decode(junk.toOpenArray(0, 3), pcm, info) == (4, dsNoFrame)
  doAssert d[].takeSpectrum(energy) == 0

  # A whole stream: the first call skips the ID3 tag and decodes frame one.
  let data = readBytes(DataDir / "m1_44k_js128_id3.mp3")
  doAssert data[0] == byte('I') and data[1] == byte('D') and data[2] == byte('3')
  var (consumed, status) = d[].decode(data, pcm, info)
  doAssert status == dsDecoded
  doAssert info == FrameInfo(samplesProduced: 1152, channels: 2,
                             sampleRate: 44100, bitrateKbps: 128, layer: 3)
  let tagLen = 10 + (int(data[6]) shl 21 or int(data[7]) shl 14 or
                     int(data[8]) shl 7 or int(data[9]))
  doAssert data[tagLen] == 0xFF, "the first frame follows the tag"
  doAssert consumed == tagLen + 1152 * 128 * 125 div 44100 + int((data[tagLen + 2] shr 1) and 1)

  # takeSpectrum returns the sums of the two granules x two channels of
  # each frame decoded since the last call, and clears them.
  doAssert d[].takeSpectrum(energy) == 4
  let second = consumed
  var pos = second
  for frame in 0 ..< 5:
    (consumed, status) = d[].decode(data.toOpenArray(pos, data.high), pcm, info)
    doAssert status == dsDecoded and consumed in 417 .. 418
    pos += consumed
  doAssert d[].takeSpectrum(energy) == 20
  var some = false
  for e in energy:
    doAssert e >= 0
    some = some or e > 0
  doAssert some
  doAssert d[].takeSpectrum(energy) == 0
  for e in energy: doAssert e == 0

  # A frame cut off at the end of the input is junk, not a frame: with one
  # complete frame and half of the next, the complete one still decodes
  # (nothing contradicts it) and the half is then skipped.
  initDecoder(d[])
  (consumed, status) = d[].decode(data.toOpenArray(second, data.high), pcm, info)
  let frameLen = consumed
  doAssert status == dsDecoded and frameLen in 417 .. 418
  initDecoder(d[])
  let cut = second + frameLen + 200
  (consumed, status) = d[].decode(data.toOpenArray(second, cut - 1), pcm, info)
  doAssert (consumed, status) == (frameLen, dsDecoded)
  (consumed, status) = d[].decode(data.toOpenArray(second + frameLen, cut - 1), pcm, info)
  doAssert (consumed, status) == (200, dsNoFrame)

  # initDecoder forgets the stream: the same bytes decode the same again.
  var first: array[MaxSamplesPerFrame, int16]
  initDecoder(d[])
  discard d[].decode(data, first, info)
  initDecoder(d[])
  discard d[].decode(data, pcm, info)
  doAssert first == pcm

proc testStatuses() =
  # Starting in the middle of a stream: the first frames need reservoir
  # bytes that were never seen, then decoding recovers.
  var c = statusCounts("m1_44k_js128_midstart")
  doAssert c[dsReservoirUnavailable] >= 1 and c[dsDecoded] > 10 and c[dsCorrupt] == 0
  # Layer II is recognised, sized and skipped frame by frame.
  c = statusCounts("layer2_44k_192")
  doAssert c[dsUnsupportedLayer] > 10 and c[dsDecoded] == 0
  # Damaged side info is reported and the decoder resynchronises.
  c = statusCounts("m1_44k_js128_damaged")
  doAssert c[dsCorrupt] >= 1 and c[dsDecoded] > 10
  # A truncated file ends with the partial frame skipped as junk.
  c = statusCounts("m1_44k_s192_truncated")
  doAssert c[dsNoFrame] == 1 and c[dsDecoded] > 10

proc testRobustness() =
  ## No input may crash the decoder or make it index out of bounds (the
  ## firmware runs without bounds checks; this test runs with them). Damage
  ## every fixture at random and decode it; also the one stream upstream
  ## cannot decode (it panics): mixed blocks at 8 kHz.
  var seed = 0x2545F491'u32
  proc rnd(): uint32 =
    seed = seed xor (seed shl 13)
    seed = seed xor (seed shr 17)
    seed = seed xor (seed shl 5)
    seed
  var counts: array[DecodeStatus, int]
  var files = 0
  for f in walkFiles(DataDir / "*.mp3"):
    let clean = readBytes(f)
    for round in 0 ..< 12:
      var data = clean
      let hits = 1 + int(rnd() mod 40)
      for h in 0 ..< hits:
        let at = int(rnd() mod uint32(data.len))
        case rnd() mod 3
        of 0: data[at] = byte(rnd())
        of 1: data[at] = data[at] xor byte(1 shl (rnd() mod 8))
        else: # keep the header, damage the side info after it
          let k = min(at + 4 + int(rnd() mod 32), data.high)
          data[k] = byte(rnd())
      discard decodeAll(data, counts)
    inc files
  doAssert files > 0 and counts[dsDecoded] > 1000 and counts[dsCorrupt] > 0
  for name in ["m25_8k_mixed", "m25_8k_mixed_stereo"]:
    var c: array[DecodeStatus, int]
    let frames = decodeAll(readBytes(DataDir / "noref" / name & ".mp3"), c)
    doAssert frames > 0 and c[dsDecoded] > 5, name

when isMainModule:
  if paramCount() == 3 and paramStr(1) == "trace":
    for line in trace(readBytes(paramStr(2)), parseInt(paramStr(3))):
      echo line
  else:
    let n = checkReferences()
    doAssert n >= 20, "fixtures missing"
    testApi()
    testStatuses()
    testRobustness()
    echo "t_mp3dec: ok"
