## MPEG-1/2/2.5 Layer III decoder: a Nim port of upstream's vendored
## `nanomp3-core` (itself a port of minimp3), including the "FreeNetRadio
## patch" that sums line energies into spectrum bands.
##
## Built as upstream builds it: Layer III only (Layer I/II frames are found
## and reported as `dsUnsupportedLayer`), scalar kernels, 16-bit output
## rounded half away from zero. Procedures keep minimp3's names and order so
## this file can be read next to `vendor/nanomp3-core/src/minimp3.rs`. Every
## float expression is evaluated in upstream's order, which keeps the output
## bit-identical (`tests/t_mp3dec.nim` checks that against the Rust decoder).
##
## Pure Nim, no HAL imports, no heap: one `Mp3Decoder` is about 22 KB and is
## allocated once by the audio task. `decode` uses under 1 KB of stack on the
## M0 (measured with -fstack-usage).

import ./mp3tables

# Upstream compiles the decoder at opt-level 3, and Rust never fuses a
# multiply and an add; a fused one would round differently.
{.localPassC: "-O3 -ffp-contract=off".}

const
  MaxSamplesPerFrame* = 1152 * 2
    ## Minimum length of the PCM buffer passed to `decode`, in samples.
  SpectrumBands* = 40

  HdrSize = 4
  MaxFreeFormatFrameSize = 2304
  MaxFrameSyncMatches = 10
  MaxBitreservoirBytes = 511
  MaxL3FramePayloadBytes = MaxFreeFormatFrameSize
  ShortBlockType = 2
  StopBlockType = 3
  MaxScfi = (255 - 4 - 210 + 3) and not 3
  SynFloats = (18 + 15) * 2 * 32
    ## The synthesis buffer (`lins`), as rows of 4 floats: [left even,
    ## right even, left odd, right odd].

  SpectrumEdges: array[SpectrumBands + 1, uint16] = [
    ## FreeNetRadio patch: band edges in spectral lines (576 per granule,
    ## each fs/1152 wide). The first 12 bands are one line each, the rest
    ## are spaced logarithmically up to line 480 (about 18 kHz at 44.1 kHz).
    1'u16, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 15, 17, 19, 22, 25, 28,
    32, 36, 41, 47, 54, 61, 69, 79, 90, 102, 116, 132, 150, 171, 195, 222,
    252, 287, 326, 371, 422, 480]

type
  DecodeStatus* = enum
    dsDecoded
    dsNoFrame               ## no complete frame in the input (junk skipped)
    dsReservoirUnavailable  ## needs bit-reservoir data that was not decoded
    dsCorrupt
    dsUnsupportedLayer      ## Layer I/II (not decoded, as upstream's build)

  FrameInfo* = object
    samplesProduced*: int   ## per channel; 0 when no audio came out
    channels*: int          ## 1 or 2
    sampleRate*: int        ## Hz
    bitrateKbps*: int       ## 0 for free-format streams
    layer*: int

  Mp3Decoder* = object
    # Persistent state (`mp3dec_t`), cleared on every resynchronisation.
    spec: array[SpectrumBands, float32]
    specN: uint32
    mdctOverlap: array[2 * 288, float32]
    qmfState: array[15 * 2 * 32, float32]
    reserv: int32
    freeFormatBytes: int32
    header: array[4, byte]
    reservBuf: array[MaxBitreservoirBytes, byte]
    # Working memory for one frame (`mp3dec_scratch_t`).
    grbuf: array[2 * 576, float32]    ## left lines, then right
    scf: array[40, float32]
    syn: array[SynFloats, float32]
    istPos: array[2, array[39, uint8]]
    maindata: array[MaxBitreservoirBytes + MaxL3FramePayloadBytes, byte]

  Header = array[4, byte]
  Bytes = ptr UncheckedArray[byte]

  GrInfo = object
    sfbRow: uint8           ## row of `SfbTab`
    part23Length: uint16
    bigValues: uint16
    scalefacCompress: uint16
    globalGain: uint8
    blockType: uint8
    mixedBlockFlag: uint8
    nLongSfb: uint8
    nShortSfb: uint8
    tableSelect: array[3, uint8]
    regionCount: array[3, uint8]
    subblockGain: array[3, uint8]
    preflag: uint8
    scalefacScale: uint8
    count1Table: uint8
    scfsi: uint8

  Bs = object
    ## Bit reader. `pos` keeps advancing past `limit` so callers can detect
    ## overruns; the limit of a malformed tiny frame can be negative.
    buf: Bytes
    len: int
    pos: int
    limit: int

# ---------------------------------------------------------------- bit reader

func byteAt(buf: Bytes; len, i: int): uint32 {.inline.} =
  ## Bytes outside the buffer read as zero.
  if i >= 0 and i < len: uint32(buf[i]) else: 0'u32

func initBs(buf: Bytes; len, bytes: int): Bs =
  Bs(buf: buf, len: len, pos: 0, limit: bytes * 8)

func getBits(bs: var Bs; n: int): uint32 =
  let s = bs.pos and 7
  var p = bs.pos shr 3
  bs.pos += n
  if bs.pos > bs.limit:
    return 0
  var shift = n + s
  var next = byteAt(bs.buf, bs.len, p) and (255'u32 shr s)
  inc p
  var cache = 0'u32
  while true:
    shift -= 8
    if shift <= 0:
      break
    cache = cache or (next shl shift)
    next = byteAt(bs.buf, bs.len, p)
    inc p
  cache or (next shr (-shift))

# -------------------------------------------------------------- frame header

func readHeader(buf: Bytes; at: int): Header {.inline.} =
  [buf[at], buf[at + 1], buf[at + 2], buf[at + 3]]

func isMono(h: Header): bool {.inline.} = (h[3] and 0xC0) == 0xC0
func isMsStereo(h: Header): bool {.inline.} = (h[3] and 0xE0) == 0x60
func isFreeFormat(h: Header): bool {.inline.} = (h[2] and 0xF0) == 0
func isCrc(h: Header): bool {.inline.} = (h[1] and 1) == 0
func testPadding(h: Header): bool {.inline.} = (h[2] and 0x2) != 0
func testMpeg1(h: Header): bool {.inline.} = (h[1] and 0x8) != 0
func testNotMpeg25(h: Header): bool {.inline.} = (h[1] and 0x10) != 0
func testIStereo(h: Header): bool {.inline.} = (h[3] and 0x10) != 0
func testMsStereo(h: Header): bool {.inline.} = (h[3] and 0x20) != 0
func getLayer(h: Header): int {.inline.} = int(h[1] shr 1) and 3
func getBitrate(h: Header): int {.inline.} = int(h[2] shr 4)
func getSampleRate(h: Header): int {.inline.} = int(h[2] shr 2) and 3
func getMySampleRate(h: Header): int {.inline.} =
  h.getSampleRate + (int((h[1] shr 3) and 1) + int((h[1] shr 4) and 1)) * 3
func isFrame576(h: Header): bool {.inline.} = (h[1] and 14) == 2
func isLayer1(h: Header): bool {.inline.} = (h[1] and 6) == 6

func valid(h: Header): bool =
  h[0] == 0xff and
    ((h[1] and 0xF0) == 0xf0 or (h[1] and 0xFE) == 0xe2) and
    h.getLayer != 0 and h.getBitrate != 15 and h.getSampleRate != 3

func compare(h1, h2: Header): bool =
  ## `hdr_compare`: is `h2` a valid header for the same stream as `h1`?
  h2.valid and
    ((h1[1] xor h2[1]) and 0xFE) == 0 and
    ((h1[2] xor h2[2]) and 0x0C) == 0 and
    h1.isFreeFormat == h2.isFreeFormat

# The header accessors below are only used on valid headers (layer 1..3,
# bitrate index below 15, sample-rate index below 3).
func bitrateKbps(h: Header): int =
  2 * int(HdrBitrateKbpsHalfrate[ord(h.testMpeg1)][h.getLayer - 1][h.getBitrate])

func sampleRateHz(h: Header): int =
  int(HdrSampleRateHz[h.getSampleRate]) shr ord(not h.testMpeg1) shr
    ord(not h.testNotMpeg25)

func frameSamples(h: Header): int =
  if h.isLayer1: 384 else: 1152 shr ord(h.isFrame576)

func frameBytes(h: Header; freeFormatSize: int): int =
  result = h.frameSamples * h.bitrateKbps * 125 div h.sampleRateHz
  if h.isLayer1:
    result = result and not 3 # slot align
  if result == 0:
    result = freeFormatSize

func padding(h: Header): int =
  if h.testPadding: (if h.isLayer1: 4 else: 1) else: 0

# ----------------------------------------------------------------- side info

func l3ReadSideInfo(bs: var Bs; gr: var array[4, GrInfo]; hdr: Header): int =
  ## Returns `main_data_begin`, or -1 when the side info is invalid.
  var scfsi = 0'u32
  var part23Sum = 0
  var srIdx = hdr.getMySampleRate
  srIdx -= ord(srIdx != 0)
  var grCount = if hdr.isMono: 1 else: 2
  var mainDataBegin: int
  if hdr.testMpeg1:
    grCount *= 2
    mainDataBegin = int(bs.getBits(9))
    scfsi = bs.getBits(7 + grCount)
  else:
    mainDataBegin = int(bs.getBits(8 + grCount) shr grCount)

  for g in 0 ..< grCount:
    template gi: untyped = gr[g]
    if hdr.isMono:
      scfsi = scfsi shl 4
    gi.part23Length = uint16(bs.getBits(12))
    part23Sum += int(gi.part23Length)
    gi.bigValues = uint16(bs.getBits(9))
    if gi.bigValues > 288:
      return -1
    gi.globalGain = uint8(bs.getBits(8))
    gi.scalefacCompress = uint16(bs.getBits(if hdr.testMpeg1: 4 else: 9))
    gi.sfbRow = uint8(SfbLong + srIdx)
    gi.nLongSfb = 22
    gi.nShortSfb = 0
    var tables: uint32
    if bs.getBits(1) != 0:
      gi.blockType = uint8(bs.getBits(2))
      if gi.blockType == 0:
        return -1
      gi.mixedBlockFlag = uint8(bs.getBits(1))
      gi.regionCount[0] = 7
      gi.regionCount[1] = 255
      if gi.blockType == ShortBlockType:
        scfsi = scfsi and 0x0F0F
        if gi.mixedBlockFlag == 0:
          gi.regionCount[0] = 8
          gi.sfbRow = uint8(SfbShort + srIdx)
          gi.nLongSfb = 0
          gi.nShortSfb = 39
        else:
          gi.sfbRow = uint8(SfbMixed + srIdx)
          gi.nLongSfb = if hdr.testMpeg1: 8 else: 6
          gi.nShortSfb = 30
      tables = bs.getBits(10) shl 5
      gi.subblockGain[0] = uint8(bs.getBits(3))
      gi.subblockGain[1] = uint8(bs.getBits(3))
      gi.subblockGain[2] = uint8(bs.getBits(3))
    else:
      gi.blockType = 0
      gi.mixedBlockFlag = 0
      tables = bs.getBits(15)
      gi.regionCount[0] = uint8(bs.getBits(4))
      gi.regionCount[1] = uint8(bs.getBits(3))
      gi.regionCount[2] = 255
    gi.tableSelect[0] = uint8(tables shr 10)
    gi.tableSelect[1] = uint8((tables shr 5) and 31)
    gi.tableSelect[2] = uint8(tables and 31)
    gi.preflag =
      if hdr.testMpeg1: uint8(bs.getBits(1))
      else: uint8(ord(gi.scalefacCompress >= 500))
    gi.scalefacScale = uint8(bs.getBits(1))
    gi.count1Table = uint8(bs.getBits(1))
    gi.scfsi = uint8((scfsi shr 12) and 15)
    scfsi = scfsi shl 4

  if part23Sum + bs.pos > bs.limit + mainDataBegin * 8:
    return -1
  mainDataBegin

# -------------------------------------------------------------- scalefactors

func l3ReadScalefactors(scf: var array[40, uint8]; istPos: var array[39, uint8];
                        scfSize: array[4, uint8]; partRow, partOff: int;
                        bitbuf: var Bs; scfsiIn: int) =
  var scfsi = scfsiIn
  var pos = 0
  for i in 0 ..< 4:
    let cnt = int(ScfPartitions[partRow][partOff + i])
    if cnt == 0:
      break
    if (scfsi and 8) != 0:
      for j in pos ..< pos + cnt:
        scf[j] = istPos[j]
    else:
      let bits = int(scfSize[i])
      if bits == 0:
        for j in pos ..< pos + cnt:
          scf[j] = 0
          istPos[j] = 0
      else:
        let maxScf = if scfsi < 0: (1 shl bits) - 1 else: -1
        for j in pos ..< pos + cnt:
          let s = int(bitbuf.getBits(bits))
          istPos[j] = if s == maxScf: 255'u8 else: uint8(s and 0xFF)
          scf[j] = uint8(s and 0xFF)
    pos += cnt
    scfsi *= 2
  scf[pos] = 0
  scf[pos + 1] = 0
  scf[pos + 2] = 0

func l3LdexpQ2(y0: float32; expQ2In: int): float32 =
  var y = y0
  var expQ2 = expQ2In
  while true:
    let e = min(30 * 4, expQ2)
    y = y * (LdexpQ2Expfrac[e and 3] * float32((1 shl 30) shr (e shr 2)))
    expQ2 -= e
    if expQ2 <= 0:
      return y

func l3DecodeScalefactors(hdr: Header; istPos: var array[39, uint8];
                          bs: var Bs; gr: GrInfo; scf: var array[40, float32];
                          ch: int) =
  let partRow = ord(gr.nShortSfb != 0) + ord(gr.nLongSfb == 0)
  var partOff = 0
  var scfSize: array[4, uint8]
  var iscf: array[40, uint8]
  let scfShift = int(gr.scalefacScale) + 1
  var scfsi = int(gr.scfsi)

  if hdr.testMpeg1:
    let part = ScfcDecode[gr.scalefacCompress and 15]
    scfSize[0] = part shr 2
    scfSize[1] = scfSize[0]
    scfSize[2] = part and 3
    scfSize[3] = scfSize[2]
  else:
    let ist = ord(hdr.testIStereo and ch != 0)
    var sfc = int(gr.scalefacCompress) shr ist
    var k = ist * 3 * 4
    while sfc >= 0:
      var modprod = 1
      for i in countdown(3, 0):
        let m = int(ScfMod[k + i])
        scfSize[i] = uint8(sfc div modprod mod m)
        modprod *= m
      sfc -= modprod
      k += 4
    partOff = k
    scfsi = -16
  l3ReadScalefactors(iscf, istPos, scfSize, partRow, partOff, bs, scfsi)

  let nLong = int(gr.nLongSfb)
  let nShort = int(gr.nShortSfb)
  if nShort != 0:
    let sh = 3 - scfShift
    for i in countup(0, nShort - 1, 3):
      for j in 0 ..< 3:
        iscf[nLong + i + j] = iscf[nLong + i + j] + (gr.subblockGain[j] shl sh)
  elif gr.preflag != 0:
    for i in 0 ..< 10:
      iscf[11 + i] = iscf[11 + i] + ScfPreamp[i]

  let gainExp = int(gr.globalGain) - 4 - 210 - (if hdr.isMsStereo: 2 else: 0)
  let gain = l3LdexpQ2(float32(1 shl (MaxScfi div 4)), MaxScfi - gainExp)
  for i in 0 ..< nLong + nShort:
    scf[i] = l3LdexpQ2(gain, int(iscf[i]) shl scfShift)

# ------------------------------------------------------------------- Huffman

func l3Pow43(xIn: int): float32 =
  var x = xIn
  var mult = 256
  if x < 129:
    return Pow43[16 + x]
  if x < 1024:
    mult = 16
    x = x shl 3
  let sign = (2 * x) and 64
  let frac = float32((x and 63) - sign) / float32((x and not 63) + sign)
  # 4/3 and 2/9 as float32.
  Pow43[16 + ((x + sign) shr 6)] *
    (1.0'f32 + frac * (1.3333334'f32 + frac * 0.22222222'f32)) * float32(mult)

func l3Huffman(dst: var array[2 * 576, float32]; base: int; bs: var Bs;
               gr: GrInfo; scf: array[40, float32]; layer3grLimit: int) =
  ## Dequantised lines of one granule-channel into `dst[base ..< base + 576]`.
  var one = 0.0'f32
  var ireg = 0
  var bigValCnt = int(gr.bigValues)
  let sfbRow = int(gr.sfbRow)
  var sfb = 0
  var scfIdx = 0
  var d = base

  # The 32-bit look-ahead cache. Bytes past the end of the buffer read as
  # zero: a corrupt `big_values` can run past the granule's data.
  let buf = bs.buf
  let bufLen = bs.len
  let start = bs.pos div 8
  var next = start + 4
  var sh = (bs.pos and 7) - 8
  var cache = (((byteAt(buf, bufLen, start) * 256 + byteAt(buf, bufLen, start + 1)) * 256 +
    byteAt(buf, bufLen, start + 2)) * 256 + byteAt(buf, bufLen, start + 3)) shl (bs.pos and 7)

  template peek(n: int): int = int(cache shr (32 - n))
  template flush(n: int) =
    cache = cache shl n
    sh += n
  template check() =
    while sh >= 0:
      cache = cache or (byteAt(buf, bufLen, next) shl sh)
      inc next
      sh -= 8
  template negative(): bool = (cache and 0x8000_0000'u32) != 0

  while bigValCnt > 0:
    let tabNum = int(gr.tableSelect[ireg])
    var sfbCnt = int(gr.regionCount[ireg])
    inc ireg
    let codebook = int(HuffTabIndex[tabNum])
    let linbits = int(HuffLinbits[tabNum])
    while true:
      let np = int(SfbTab[sfbRow][sfb]) div 2
      inc sfb
      one = scf[scfIdx]
      inc scfIdx
      # C's do/while always decodes at least one pair; np is never 0 here
      # because big_values <= 288 and every table covers 288 pairs.
      for pair in 0 ..< max(min(bigValCnt, np), 1):
        var w = 5
        var leaf = int(HuffTabs[codebook + peek(w)])
        while leaf < 0:
          flush(w)
          w = leaf and 7
          leaf = int(HuffTabs[codebook + peek(w) - ashr(leaf, 3)])
        flush(leaf shr 8)

        for v in 0 ..< 2:
          var lsb = leaf and 0x0F
          if linbits != 0 and lsb == 15:
            lsb += peek(linbits)
            flush(linbits)
            check()
            dst[d + v] = one * l3Pow43(lsb) * (if negative(): -1.0'f32 else: 1.0'f32)
          else:
            dst[d + v] = Pow43[16 + lsb - 16 * int(cache shr 31)] * one
          flush(ord(lsb != 0))
          leaf = leaf shr 4
        check()
        d += 2
      bigValCnt -= np
      if bigValCnt <= 0:
        break
      dec sfbCnt
      if sfbCnt < 0:
        break

  let tab33 = gr.count1Table != 0
  template count1(i: int): int =
    (if tab33: int(HuffTab33[i]) else: int(HuffTab32[i]))
  var np = 1 - bigValCnt
  block quads:
    while true:
      var leaf = count1(peek(4))
      if (leaf and 8) == 0:
        leaf = count1((leaf shr 3) + int((cache shl 4) shr (32 - (leaf and 3))))
      flush(leaf and 7)
      if next * 8 - 24 + sh > layer3grLimit:
        break
      for half in 0 ..< 2:
        dec np
        if np == 0:
          np = int(SfbTab[sfbRow][sfb]) div 2
          inc sfb
          if np == 0:
            break quads
          one = scf[scfIdx]
          inc scfIdx
        for s in 2 * half .. 2 * half + 1:
          if (leaf and (128 shr s)) != 0:
            dst[d + s] = if negative(): -one else: one
            flush(1)
      check()
      d += 4
  bs.pos = layer3grLimit

# -------------------------------------------------------------------- stereo

func l3MidsideStereo(buf: var array[2 * 576, float32]; start, n: int) =
  for i in start ..< start + n:
    let a = buf[i]
    let b = buf[576 + i]
    buf[i] = a + b
    buf[576 + i] = a - b

func l3IntensityStereoBand(buf: var array[2 * 576, float32]; start, n: int;
                           kl, kr: float32) =
  for i in start ..< start + n:
    buf[576 + i] = buf[i] * kr
    buf[i] = buf[i] * kl

func l3StereoTopBand(buf: array[2 * 576, float32]; sfbRow, nbands: int;
                     maxBand: var array[3, int]) =
  maxBand = [-1, -1, -1]
  var off = 576
  for i in 0 ..< nbands:
    let n = int(SfbTab[sfbRow][i])
    for j in countup(0, n - 2, 2):
      if buf[off + j] != 0.0'f32 or buf[off + j + 1] != 0.0'f32:
        maxBand[i mod 3] = i
        break
    off += n

func l3StereoProcess(buf: var array[2 * 576, float32]; istPos: array[39, uint8];
                     sfbRow: int; hdr: Header; maxBand: array[3, int];
                     mpeg2Sh: int) =
  let maxPos = if hdr.testMpeg1: 7 else: 64
  var off = 0
  var i = 0
  while i < 39 and SfbTab[sfbRow][i] != 0:
    let n = int(SfbTab[sfbRow][i])
    let ipos = int(istPos[i])
    if i > maxBand[i mod 3] and ipos < maxPos:
      let s = if hdr.testMsStereo: 1.41421356'f32 else: 1.0'f32
      var kl, kr: float32
      if hdr.testMpeg1:
        kl = StereoPan[2 * ipos]
        kr = StereoPan[2 * ipos + 1]
      else:
        let k = l3LdexpQ2(1.0'f32, ((ipos + 1) shr 1) shl mpeg2Sh)
        if (ipos and 1) != 0:
          kl = k
          kr = 1.0'f32
        else:
          kl = 1.0'f32
          kr = k
      l3IntensityStereoBand(buf, off, n, kl * s, kr * s)
    elif hdr.testMsStereo:
      l3MidsideStereo(buf, off, n)
    off += n
    inc i

func l3IntensityStereo(buf: var array[2 * 576, float32]; istPos: var array[39, uint8];
                       gr0: GrInfo; mpeg2Sh: int; hdr: Header) =
  var maxBand: array[3, int]
  let sfbRow = int(gr0.sfbRow)
  let nSfb = int(gr0.nLongSfb) + int(gr0.nShortSfb)
  let maxBlocks = if gr0.nShortSfb != 0: 3 else: 1

  l3StereoTopBand(buf, sfbRow, nSfb, maxBand)
  if gr0.nLongSfb != 0:
    let m = max(max(maxBand[0], maxBand[1]), maxBand[2])
    maxBand = [m, m, m]
  for i in 0 ..< maxBlocks:
    let defaultPos = if hdr.testMpeg1: 3'u8 else: 0'u8
    let itop = nSfb - maxBlocks + i
    let prev = itop - maxBlocks
    istPos[itop] = if maxBand[i] >= prev: defaultPos else: istPos[prev]
  l3StereoProcess(buf, istPos, sfbRow, hdr, maxBand, mpeg2Sh)

# ----------------------------------------------------- reorder and antialias

func l3Reorder(grbuf: var array[2 * 576, float32]; base, lines: int;
               scratch: var array[SynFloats, float32]; sfbRow, firstSfb: int) =
  ## Interleave the three windows of each short band of
  ## `grbuf[base ..< base + lines]`.
  var src = 0
  var dst = 0
  var i = firstSfb
  while i < 40:
    let len = int(SfbTab[sfbRow][i])
    # The bands always fit, except in an 8 kHz MPEG-2.5 mixed block, which no
    # encoder produces: its table disagrees with the long/short split, so
    # the last band would run past the granule (upstream panics there).
    if len == 0 or src + 3 * len > lines:
      break
    for j in 0 ..< len:
      scratch[dst] = grbuf[base + src + j]
      scratch[dst + 1] = grbuf[base + src + j + len]
      scratch[dst + 2] = grbuf[base + src + j + 2 * len]
      dst += 3
    src += 3 * len
    i += 3
  for j in 0 ..< dst:
    grbuf[base + j] = scratch[j]

func l3Antialias(grbuf: var array[2 * 576, float32]; base, nbands: int) =
  for b in 0 ..< nbands:
    let hi = base + 18 * b + 18
    for i in 0 ..< 8:
      let u = grbuf[hi + i]
      let d = grbuf[hi - 1 - i]
      grbuf[hi + i] = u * AntialiasAa[0][i] - d * AntialiasAa[1][i]
      grbuf[hi - 1 - i] = u * AntialiasAa[1][i] + d * AntialiasAa[0][i]

# --------------------------------------------------------------------- IMDCT

func l3Dct39(y: var array[9, float32]) =
  var s0 = y[0]
  var s2 = y[2]
  var s4 = y[4]
  var s6 = y[6]
  var s8 = y[8]
  var t0 = s0 + s6 * 0.5'f32
  s0 = s0 - s6
  var t4 = (s4 + s2) * 0.93969262'f32
  var t2 = (s8 + s2) * 0.76604444'f32
  s6 = (s4 - s8) * 0.17364818'f32
  s4 = s4 + (s8 - s2)

  s2 = s0 - s4 * 0.5'f32
  y[4] = s4 + s0
  s8 = t0 - t2 + s6
  s0 = t0 - t4 + t2
  s4 = t0 + t4 - s6

  var s1 = y[1]
  var s3 = y[3]
  var s5 = y[5]
  var s7 = y[7]

  s3 = s3 * 0.86602540'f32
  t0 = (s5 + s1) * 0.98480775'f32
  t4 = (s5 - s7) * 0.34202014'f32
  t2 = (s1 + s7) * 0.64278761'f32
  s1 = (s1 - s5 - s7) * 0.86602540'f32

  s5 = t0 - s3 - t2
  s7 = t4 - s3 - t0
  s3 = t4 + s3 - t2

  y[0] = s4 - s7
  y[1] = s2 + s1
  y[2] = s0 - s3
  y[3] = s8 + s5
  y[5] = s8 - s5
  y[6] = s0 + s3
  y[7] = s2 - s1
  y[8] = s4 + s7

func l3Imdct36(grbuf: var array[2 * 576, float32]; g: int;
               overlap: var array[2 * 288, float32]; o: int;
               window: array[18, float32]; nbands: int) =
  ## IMDCT-36 of `nbands` bands starting at `grbuf[g]` / `overlap[o]`.
  for j in 0 ..< nbands:
    let gb = g + 18 * j
    let ob = o + 9 * j
    var co, si: array[9, float32]
    co[0] = -grbuf[gb]
    si[0] = grbuf[gb + 17]
    for i in 0 ..< 4:
      si[8 - 2 * i] = grbuf[gb + 4 * i + 1] - grbuf[gb + 4 * i + 2]
      co[1 + 2 * i] = grbuf[gb + 4 * i + 1] + grbuf[gb + 4 * i + 2]
      si[7 - 2 * i] = grbuf[gb + 4 * i + 4] - grbuf[gb + 4 * i + 3]
      co[2 + 2 * i] = -(grbuf[gb + 4 * i + 3] + grbuf[gb + 4 * i + 4])
    l3Dct39(co)
    l3Dct39(si)

    si[1] = -si[1]
    si[3] = -si[3]
    si[5] = -si[5]
    si[7] = -si[7]

    for i in 0 ..< 9:
      let ovl = overlap[ob + i]
      let sum = co[i] * Imdct36Twid9[9 + i] + si[i] * Imdct36Twid9[i]
      overlap[ob + i] = co[i] * Imdct36Twid9[i] - si[i] * Imdct36Twid9[9 + i]
      grbuf[gb + i] = ovl * window[i] - sum * window[9 + i]
      grbuf[gb + 17 - i] = ovl * window[9 + i] + sum * window[i]

func l3Idct3(x0, x1, x2: float32; dst: var array[3, float32]) =
  let m1 = x1 * 0.86602540'f32
  let a1 = x0 - x2 * 0.5'f32
  dst[1] = x0 + x2
  dst[0] = a1 + m1
  dst[2] = a1 - m1

func l3Imdct12(x: array[18, float32]; xo: int; dst: var openArray[float32];
               dstOff: int; overlap: var array[2 * 288, float32]; ov: int) =
  var co, si: array[3, float32]
  l3Idct3(-x[xo], x[xo + 6] + x[xo + 3], x[xo + 12] + x[xo + 9], co)
  l3Idct3(x[xo + 15], x[xo + 12] - x[xo + 9], x[xo + 6] - x[xo + 3], si)
  si[1] = -si[1]

  for i in 0 ..< 3:
    let ovl = overlap[ov + i]
    let sum = co[i] * Imdct12Twid3[3 + i] + si[i] * Imdct12Twid3[i]
    overlap[ov + i] = co[i] * Imdct12Twid3[i] - si[i] * Imdct12Twid3[3 + i]
    dst[dstOff + i] = ovl * Imdct12Twid3[2 - i] - sum * Imdct12Twid3[5 - i]
    dst[dstOff + 5 - i] = ovl * Imdct12Twid3[5 - i] + sum * Imdct12Twid3[2 - i]

func l3ImdctShort(grbuf: var array[2 * 576, float32]; g: int;
                  overlap: var array[2 * 288, float32]; o: int; nbands: int) =
  for j in 0 ..< nbands:
    let gb = g + 18 * j
    let ob = o + 9 * j
    var tmp: array[18, float32]
    for i in 0 ..< 18:
      tmp[i] = grbuf[gb + i]
    for i in 0 ..< 6:
      grbuf[gb + i] = overlap[ob + i]
    # The last three floats of a band's overlap carry the window state; the
    # first six receive the third window's output.
    l3Imdct12(tmp, 0, grbuf, gb + 6, overlap, ob + 6)
    l3Imdct12(tmp, 1, grbuf, gb + 12, overlap, ob + 6)
    var tail: array[6, float32]
    l3Imdct12(tmp, 2, tail, 0, overlap, ob + 6)
    for i in 0 ..< 6:
      overlap[ob + i] = tail[i]

func l3ChangeSign(grbuf: var array[2 * 576, float32]; base: int) =
  for b in countup(1, 31, 2):
    for i in countup(1, 17, 2):
      grbuf[base + 18 * b + i] = -grbuf[base + 18 * b + i]

func l3ImdctGr(grbuf: var array[2 * 576, float32]; g: int;
               overlap: var array[2 * 288, float32]; o: int;
               blockType: uint8; nLongBands: int) =
  if nLongBands != 0:
    l3Imdct36(grbuf, g, overlap, o, MdctWindow[0], nLongBands)
  if blockType == ShortBlockType:
    l3ImdctShort(grbuf, g + 18 * nLongBands, overlap, o + 9 * nLongBands,
                 32 - nLongBands)
  else:
    l3Imdct36(grbuf, g + 18 * nLongBands, overlap, o + 9 * nLongBands,
              MdctWindow[ord(blockType == StopBlockType)], 32 - nLongBands)

# ------------------------------------------------------------- bit reservoir

func l3SaveReservoir(d: var Mp3Decoder; bs: Bs) =
  var pos = (bs.pos + 7) div 8
  var remains = bs.limit div 8 - pos
  if remains > MaxBitreservoirBytes:
    pos += remains - MaxBitreservoirBytes
    remains = MaxBitreservoirBytes
  if remains > 0:
    for i in 0 ..< remains:
      d.reservBuf[i] = byte(byteAt(bs.buf, bs.len, pos + i))
  d.reserv = int32(remains)

func l3RestoreReservoir(d: var Mp3Decoder; bs: Bs; mainDataBegin: int;
                        ok: var bool): Bs =
  ## The main data of this frame, preceded by the reservoir bytes it needs,
  ## gathered in `d.maindata`.
  let frameBytes = (bs.limit - bs.pos) div 8
  let reserv = int(d.reserv)
  let bytesHave = min(reserv, mainDataBegin)
  let reservOff = max(reserv - mainDataBegin, 0)
  for i in 0 ..< bytesHave:
    d.maindata[i] = d.reservBuf[reservOff + i]
  let frameStart = bs.pos div 8
  for i in 0 ..< frameBytes:
    d.maindata[bytesHave + i] = byte(byteAt(bs.buf, bs.len, frameStart + i))
  # Bounding the reader to the valid bytes makes Huffman over-reads on
  # corrupt streams see zeros without having to clear the buffer.
  let len = bytesHave + frameBytes
  ok = reserv >= mainDataBegin
  initBs(cast[Bytes](addr d.maindata[0]), len, len)

# ------------------------------------------------------------ granule decode

func l3Decode(d: var Mp3Decoder; bs: var Bs; gr: array[4, GrInfo];
              first, nch: int) =
  ## One granule; its channels' side info is `gr[first ..< first + nch]`.
  let hdr = d.header
  for ch in 0 ..< nch:
    let layer3grLimit = bs.pos + int(gr[first + ch].part23Length)
    l3DecodeScalefactors(hdr, d.istPos[ch], bs, gr[first + ch], d.scf, ch)
    l3Huffman(d.grbuf, 576 * ch, bs, gr[first + ch], d.scf, layer3grLimit)

  # As upstream (and minimp3), keyed on the header bits alone, so a mono
  # frame with the intensity bit set is processed too.
  if hdr.testIStereo:
    l3IntensityStereo(d.grbuf, d.istPos[1], gr[first],
                      int(gr[first + 1].scalefacCompress and 1), hdr)
  elif hdr.isMsStereo:
    l3MidsideStereo(d.grbuf, 0, 576)

  # FreeNetRadio patch: add this granule's line energies to the band sums
  # (before antialiasing / the inverse transform, so the lines are in
  # frequency order; short blocks are interleaved by window and so come
  # out slightly smeared, which doesn't matter for a display).
  for ch in 0 ..< nch:
    for b in 0 ..< SpectrumBands:
      var e = 0.0'f32
      for i in int(SpectrumEdges[b]) ..< int(SpectrumEdges[b + 1]):
        let x = d.grbuf[576 * ch + i]
        e = e + x * x
      d.spec[b] = d.spec[b] + e
    inc d.specN

  for ch in 0 ..< nch:
    let g = gr[first + ch]
    var aaBands = 31
    let nLongBands =
      (if g.mixedBlockFlag != 0: 2 else: 0) shl ord(hdr.getMySampleRate == 2)

    if g.nShortSfb != 0:
      aaBands = max(nLongBands - 1, 0)
      l3Reorder(d.grbuf, 576 * ch + nLongBands * 18, 576 - nLongBands * 18,
                d.syn, int(g.sfbRow), int(g.nLongSfb))

    l3Antialias(d.grbuf, 576 * ch, aaBands)
    l3ImdctGr(d.grbuf, 576 * ch, d.mdctOverlap, 288 * ch, g.blockType, nLongBands)
    l3ChangeSign(d.grbuf, 576 * ch)

# ---------------------------------------------------------------- filterbank

func mp3dDctII(grbuf: var array[2 * 576, float32]; base, n: int) =
  ## DCT-II over each of the first `n` columns of the 18x32 subband matrix.
  for k in base ..< base + n:
    var t: array[4, array[8, float32]]
    for i in 0 ..< 8:
      let x0 = grbuf[k + i * 18]
      let x1 = grbuf[k + (15 - i) * 18]
      let x2 = grbuf[k + (16 + i) * 18]
      let x3 = grbuf[k + (31 - i) * 18]
      let t0 = x0 + x3
      let t1 = x1 + x2
      let t2 = (x1 - x2) * DctIiSec[3 * i]
      let t3 = (x0 - x3) * DctIiSec[3 * i + 1]
      t[0][i] = t0 + t1
      t[1][i] = (t0 - t1) * DctIiSec[3 * i + 2]
      t[2][i] = t3 + t2
      t[3][i] = (t3 - t2) * DctIiSec[3 * i + 2]
    for r in 0 ..< 4:
      var x0 = t[r][0]
      var x1 = t[r][1]
      var x2 = t[r][2]
      var x3 = t[r][3]
      var x4 = t[r][4]
      var x5 = t[r][5]
      var x6 = t[r][6]
      var x7 = t[r][7]
      var xt = x0 - x7
      x0 = x0 + x7
      x7 = x1 - x6
      x1 = x1 + x6
      x6 = x2 - x5
      x2 = x2 + x5
      x5 = x3 - x4
      x3 = x3 + x4
      x4 = x0 - x3
      x0 = x0 + x3
      x3 = x1 - x2
      x1 = x1 + x2
      t[r][0] = x0 + x1
      t[r][4] = (x0 - x1) * 0.70710677'f32
      x5 = x5 + x6
      x6 = (x6 + x7) * 0.70710677'f32
      x7 = x7 + xt
      x3 = (x3 + x4) * 0.70710677'f32
      x5 = x5 - x7 * 0.198912367'f32 # rotate by PI/8
      x7 = x7 + x5 * 0.382683432'f32
      x5 = x5 - x7 * 0.198912367'f32
      x0 = xt - x6
      xt = xt + x6
      t[r][1] = (xt + x7) * 0.50979561'f32
      t[r][2] = (x4 + x3) * 0.54119611'f32
      t[r][3] = (x0 - x5) * 0.60134488'f32
      t[r][5] = (x0 + x5) * 0.89997619'f32
      t[r][6] = (x4 - x3) * 1.30656302'f32
      t[r][7] = (xt - x7) * 2.56291556'f32
    for i in 0 ..< 7:
      let y = k + i * 4 * 18
      grbuf[y] = t[0][i]
      grbuf[y + 18] = t[2][i] + t[3][i] + t[3][i + 1]
      grbuf[y + 2 * 18] = t[1][i] + t[1][i + 1]
      grbuf[y + 3 * 18] = t[2][i + 1] + t[3][i] + t[3][i + 1]
    let y = k + 7 * 4 * 18
    grbuf[y] = t[0][7]
    grbuf[y + 18] = t[2][7] + t[3][7]
    grbuf[y + 2 * 18] = t[1][7]
    grbuf[y + 3 * 18] = t[3][7]

func toPcm16(x: float32): int16 {.inline.} =
  ## Round half away from zero and clip (nanomp3's default conversion, not
  ## minimp3's, which maps (-1.5, -0.5] to 0). NaN becomes 0.
  if x != x:
    return 0
  if x >= 32767.0'f32:
    return 32767
  if x <= -32768.0'f32:
    return -32768
  let t = int32(x) # truncates toward zero
  let frac = x - float32(t)
  if frac >= 0.5'f32: int16(t + 1)
  elif frac <= -0.5'f32: int16(t - 1)
  else: int16(t)

func mp3dSynthPair(lins: array[SynFloats, float32]; row: int;
                   first, second: var float32) {.inline.} =
  ## `mp3d_synth_pair`: `row` is the float index of lane `lane` in the first
  ## of 15 rows taken 16 apart; the second sample uses the lane two on.
  template x(m: int): float32 = lins[row + 64 * m]
  var a: float32
  a = (x(14) - x(0)) * 29.0'f32
  a = a + (x(1) + x(13)) * 213.0'f32
  a = a + (x(12) - x(2)) * 459.0'f32
  a = a + (x(3) + x(11)) * 2037.0'f32
  a = a + (x(10) - x(4)) * 5153.0'f32
  a = a + (x(5) + x(9)) * 6574.0'f32
  a = a + (x(8) - x(6)) * 37489.0'f32
  a = a + x(7) * 75038.0'f32
  first = a

  template z(m: int): float32 = lins[row + 2 + 64 * m]
  a = z(14) * 104.0'f32
  a = a + z(12) * 1567.0'f32
  a = a + z(10) * 9727.0'f32
  a = a + z(8) * 64019.0'f32
  a = a + z(6) * -9975.0'f32
  a = a + z(4) * -45.0'f32
  a = a + z(2) * 146.0'f32
  a = a + z(0) * -5.0'f32
  second = a

func mp3dSynth(grbuf: array[2 * 576, float32]; xl, xr: int;
               pcm: var openArray[int16]; dst, nch: int;
               lins: var array[SynFloats, float32]; lb: int) =
  ## Two subband samples (`grbuf[xl..]` left, `grbuf[xr..]` right) into 64
  ## PCM frames at `pcm[dst]`. `lb` is the float index of the first row of
  ## `lins` this call works on. A mono frame leaves the right lanes alone:
  ## their output is unused and their history must not advance.
  let step = 3 - nch # lanes 0..3 for stereo, 0 and 2 for mono
  template row(r: int): int = lb + 4 * r

  for c in 0 ..< nch:
    let x = if c == 0: xl else: xr
    lins[row(240 + 15) + c] = grbuf[x + 18 * 16]
    lins[row(240 + 15) + 2 + c] = grbuf[x]
    lins[row(240 + 31) + c] = grbuf[x + 1 + 18 * 16]
    lins[row(240 + 31) + 2 + c] = grbuf[x + 1]

  for c in countdown(nch - 1, 0):
    var a, b: float32
    mp3dSynthPair(lins, row(15) + c, a, b)
    pcm[dst + c] = toPcm16(a)
    pcm[dst + c + 16 * nch] = toPcm16(b)
    mp3dSynthPair(lins, row(31) + c, a, b)
    pcm[dst + c + 32 * nch] = toPcm16(a)
    pcm[dst + c + 48 * nch] = toPcm16(b)

  for i in countdown(14, 0):
    for c in 0 ..< nch:
      let x = if c == 0: xl else: xr
      lins[row(240 + i) + c] = grbuf[x + 18 * (31 - i)]
      lins[row(240 + i) + 2 + c] = grbuf[x + 1 + 18 * (31 - i)]
      lins[row(240 + 16 + i) + c] = grbuf[x + 1 + 18 * (1 + i)]
      lins[row(240 - 16 + i) + 2 + c] = grbuf[x + 18 * (1 + i)]

    let w = (14 - i) * 16
    for lane in countup(0, 3, step):
      template vz(k: int): float32 = lins[row(240 + i - 16 * k) + lane]
      template vy(k: int): float32 = lins[row(i + 16 * k) + lane]
      template w0(k: int): float32 = SynthWin[w + 2 * k]
      template w1(k: int): float32 = SynthWin[w + 2 * k + 1]
      var b = vz(0) * w1(0) + vy(0) * w0(0)
      var a = vz(0) * w0(0) - vy(0) * w1(0)
      for k in countup(1, 7, 2):
        b = b + (vz(k) * w1(k) + vy(k) * w0(k))
        a = a + (vy(k) * w1(k) - vz(k) * w0(k))
        if k < 7:
          b = b + (vz(k + 1) * w1(k + 1) + vy(k + 1) * w0(k + 1))
          a = a + (vz(k + 1) * w0(k + 1) - vy(k + 1) * w1(k + 1))
      # Lanes 0/1 are the even samples, 2/3 the odd ones, 32 frames later.
      let c = lane and (nch - 1)
      let half = 32 * (lane shr 1)
      pcm[dst + c + (15 - i + half) * nch] = toPcm16(a)
      pcm[dst + c + (17 + i + half) * nch] = toPcm16(b)

func mp3dSynthGranule(d: var Mp3Decoder; nbands, nch: int;
                      pcm: var openArray[int16]; dst: int) =
  for ch in 0 ..< nch:
    mp3dDctII(d.grbuf, 576 * ch, nbands)

  for i in 0 ..< 15 * 64:
    d.syn[i] = d.qmfState[i]

  for i in countup(0, nbands - 1, 2):
    mp3dSynth(d.grbuf, i, 576 * (nch - 1) + i, pcm, dst + 32 * nch * i, nch,
              d.syn, 64 * i)

  # Standard (not MINIMP3_NONSTANDARD_BUT_LOGICAL) behaviour: a mono frame
  # only advances the left channel's filterbank history, so a later switch
  # to stereo starts the right channel from its old state.
  for i in countup(0, 15 * 64 - 1, 3 - nch):
    d.qmfState[i] = d.syn[nbands * 64 + i]

# ---------------------------------------------------------------- frame sync

func mp3dMatchFrame(hdr: Bytes; len, frameBytes: int): bool =
  let first = readHeader(hdr, 0)
  var i = 0
  for nmatch in 0 ..< MaxFrameSyncMatches:
    let h = readHeader(hdr, i)
    i += h.frameBytes(frameBytes) + h.padding
    if i + HdrSize > len:
      return nmatch > 0
    if not first.compare(readHeader(hdr, i)):
      return false
  true

func mp3dFindFrame(mp3: Bytes; mp3Bytes: int; freeFormatBytes: var int32):
    tuple[offset, frameBytes: int] =
  ## `frameBytes` is 0 when no frame was found.
  var i = 0
  while i + HdrSize < mp3Bytes:
    let h = readHeader(mp3, i)
    if h.valid:
      var frameBytes = h.frameBytes(int(freeFormatBytes))
      var frameAndPadding = frameBytes + h.padding

      var k = HdrSize
      while frameBytes == 0 and k < MaxFreeFormatFrameSize and
          i + 2 * k + HdrSize < mp3Bytes:
        let next = readHeader(mp3, i + k)
        if h.compare(next):
          let fb = k - h.padding
          let nextfb = fb + next.padding
          if i + k + nextfb + HdrSize <= mp3Bytes and
              h.compare(readHeader(mp3, i + k + nextfb)):
            frameAndPadding = k
            frameBytes = fb
            freeFormatBytes = int32(fb)
        inc k

      if (frameBytes != 0 and i + frameAndPadding <= mp3Bytes and
          mp3dMatchFrame(cast[Bytes](addr mp3[i]), mp3Bytes - i, frameBytes)) or
          (i == 0 and frameAndPadding == mp3Bytes):
        return (i, frameAndPadding)
      freeFormatBytes = 0
    inc i
  (mp3Bytes, 0)

# ---------------------------------------------------------------- public API

proc initDecoder*(d: var Mp3Decoder) =
  ## Reset to the state before any frame (upstream `Decoder::new()`).
  zeroMem(addr d, sizeof(d))

proc resetState(d: var Mp3Decoder) =
  ## `State::new()`: what a resynchronisation clears. That includes the
  ## spectrum sums, as upstream.
  zeroMem(addr d.spec, sizeof(d.spec))
  d.specN = 0
  zeroMem(addr d.mdctOverlap, sizeof(d.mdctOverlap))
  zeroMem(addr d.qmfState, sizeof(d.qmfState))
  d.reserv = 0
  d.freeFormatBytes = 0
  d.header = [0'u8, 0, 0, 0]
  zeroMem(addr d.reservBuf, sizeof(d.reservBuf))

proc decode*(d: var Mp3Decoder; mp3: openArray[byte]; pcm: var openArray[int16];
             info: var FrameInfo): tuple[consumed: int, status: DecodeStatus] =
  ## Find and decode the next frame of `mp3` into interleaved `pcm`.
  ## Always advance the input by `consumed`, whatever the status. `info` is
  ## filled for every status except `dsNoFrame`. Rounding is nanomp3's
  ## default (half away from zero), not minimp3's.
  ##
  ## A frame only counts once the frames after it are seen to be consistent,
  ## and a frame cut off at the end of the input is skipped as junk, so keep
  ## several frames of input available.
  doAssert pcm.len >= MaxSamplesPerFrame
  info = FrameInfo()
  let mp3Bytes = mp3.len
  if mp3Bytes == 0:
    resetState(d)
    return (0, dsNoFrame)
  let buf = cast[Bytes](unsafeAddr mp3[0])
  var i = 0
  var frameSize = 0

  if mp3Bytes > 4 and d.header[0] == 0xff and d.header.compare(readHeader(buf, 0)):
    let h = readHeader(buf, 0)
    frameSize = h.frameBytes(int(d.freeFormatBytes)) + h.padding
    if frameSize != mp3Bytes and (frameSize + HdrSize > mp3Bytes or
        not h.compare(readHeader(buf, frameSize))):
      frameSize = 0
  if frameSize == 0:
    resetState(d)
    (i, frameSize) = mp3dFindFrame(buf, mp3Bytes, d.freeFormatBytes)
    if frameSize == 0 or i + frameSize > mp3Bytes:
      return (i, dsNoFrame)

  let hdr = readHeader(buf, i)
  d.header = hdr
  result.consumed = i + frameSize
  info.channels = if hdr.isMono: 1 else: 2
  info.sampleRate = hdr.sampleRateHz
  info.layer = 4 - hdr.getLayer
  info.bitrateKbps = hdr.bitrateKbps

  let bodyLen = max(frameSize - HdrSize, 0)
  var bsFrame = initBs(cast[Bytes](addr buf[i + min(HdrSize, frameSize)]), bodyLen,
                       frameSize - HdrSize)
  if hdr.isCrc:
    discard bsFrame.getBits(16)

  if info.layer != 3:
    result.status = dsUnsupportedLayer
    return

  let nch = info.channels
  var grInfo: array[4, GrInfo]
  let mainDataBegin = l3ReadSideInfo(bsFrame, grInfo, hdr)
  if mainDataBegin < 0 or bsFrame.pos > bsFrame.limit:
    d.header[0] = 0 # mp3dec_init: resynchronise on the next call
    result.status = dsCorrupt
    return

  var ok: bool
  var bs = l3RestoreReservoir(d, bsFrame, mainDataBegin, ok)
  if ok:
    # C leaves these uninitialised and corrupt streams can read them before
    # writing; clearing them keeps results deterministic.
    zeroMem(addr d.scf, sizeof(d.scf))
    zeroMem(addr d.istPos, sizeof(d.istPos))
    let granules = if hdr.testMpeg1: 2 else: 1
    for igr in 0 ..< granules:
      zeroMem(addr d.grbuf, sizeof(d.grbuf))
      l3Decode(d, bs, grInfo, igr * nch, nch)
      mp3dSynthGranule(d, 18, nch, pcm, igr * 576 * nch)
    info.samplesProduced = d.header.frameSamples
    result.status = dsDecoded
  else:
    result.status = dsReservoirUnavailable
  l3SaveReservoir(d, bs)

proc takeSpectrum*(d: var Mp3Decoder; energy: var array[SpectrumBands, float32]): uint32 =
  ## The summed squares of the dequantised lines per band over the frames
  ## decoded since the last call, and how many granule-channels were summed
  ## (0 = no data). Resets the sums (upstream `spectrum` + `reset_spectrum`).
  energy = d.spec
  result = d.specN
  d.spec = default(array[SpectrumBands, float32])
  d.specN = 0
