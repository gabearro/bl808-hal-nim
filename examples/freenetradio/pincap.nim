## Pin self-test for diag builds (`-d:radioDiag`): the board watches its own
## pads, so the I2S, OLED and IR wiring can be checked with nothing attached.
##
## Capture: a spare DMA0 channel copies the GPIO input register (pins 0..31
## in one word) to memory as fast as the bus allows, with no CPU involved.
## That is a logic analyser on every pin this firmware drives, running while
## the real drivers do their work. `tools/pincheck.nim` decodes the result.
##
##   POST /selftest/capture?t=now    capture at once with interrupts off; also
##                                   measures the sampling rate and saves the
##                                   audio ring around the DMA's position
##   POST /selftest/capture?t=slow   same with the I2S clock 8 times slower,
##                                   so every bit is sampled several times
##   POST /selftest/capture?t=frame  capture from the start of the next
##                                   display frame
##   POST /selftest/capture?t=fast   the next frame at the normal SPI clock
##   POST /selftest/capture?t=init   as t=frame, but the panel's init sequence is
##                                   sent again first
##   GET  /selftest/capture          the finished capture (binary, see `Header`)
##   GET  /selftest/i2s              the I2S registers and the measured frame rate
##   GET  /selftest/crypto           Mbed TLS: operations on hardware and in software
##   GET  /selftest/pins             pad configuration words
##   GET  /selftest/pulls            which unused pins follow their pull resistors
##   POST /selftest/ir               play an NEC frame on the IR pin by
##                                   switching its pull resistor; the decoded
##                                   code then shows in /stats
##
## Firmware only.

import bl808/[dma, gpio, core, mmio, i2s, timer, irq]
import bl808/dmablock
import bl808/kernel/cps
when defined(radioDiag):
  import bl808/wifi
  import bl808/wifi/wpa2_pmk
  import bl808/kernel/sched
  proc bl808_wifi_backend_phase_timing_snapshot(
      snapshot: ptr array[11, uint32]) {.importc, cdecl.}
  proc bl808_wifi_backend_phase_timing_reset() {.importc, cdecl.}
  proc bl808_wifi_backend_drain_timing_snapshot(
      snapshot: ptr array[6, uint32]) {.importc, cdecl.}
  proc bl808_wifi_backend_drain_timing_reset() {.importc, cdecl.}
  proc bl808_wifi_backend_cps_compat_counts(
      snapshot: ptr array[3, uint32]) {.importc, cdecl.}
  proc bl808_wifi_backend_cps_compat_reset() {.importc, cdecl.}
  proc wifi_fw_main_phase_snapshot(
      snapshot: ptr array[4, uint32]) {.importc, cdecl.}
  proc wifi_fw_event_timing_snapshot(
      snapshot: ptr array[5, uint32]) {.importc, cdecl.}
  proc wifi_fw_sta_add_phase_snapshot(
      snapshot: ptr array[4, uint32]) {.importc, cdecl.}
import ./board, ./text, ./timebase, ./i2s_out, ./i2s_ring, ./httpd, ./diag

const
  Items {.intdefine: "pincapItems".} = 16
    ## DMA list items of 4095 samples each.
  PerItem = 4095
  Samples = Items * PerItem
  Channel = 1                       # channel 0 is the audio ring's
  GpioInputs = 0x2000_0AC4'u32      # GLB gpio_cfg128: input levels of pins 0..31
  ExcerptFrames = 256
  ExcerptLead = 64                  # frames before the DMA's position
  HeaderWords = 16
  PrefixBytes = HeaderWords * 4 + ExcerptFrames * 4
  CacheLine = 32'u

  SynthAddress = 0x00'u8
  SynthCommand = 0x45'u8

type
  State = enum
    psIdle, psArmedFrame, psArmedInit, psArmedFast, psRunning, psDone

  Header = object
    ## The first 64 bytes of GET /selftest/capture, little-endian words.
    ## Then `ExcerptFrames` stereo frames of the audio ring (only meaningful
    ## after t=now), then `samples` words of pin levels.
    magic: uint32           # "PCP1"
    samples: uint32
    elapsedUs: uint32       # t=now only: how long the samples took
    rateHz: uint32          # sampling rate measured by the last t=now
    trigger: uint32         # 0 now, 1 frame, 2 init, 3 full-speed frame
    ringFrame: uint32       # t=now: the frame the DMA was about to read
    excerptStart: uint32    # ring frame of the first excerpt frame
    ringFrames: uint32
    pins: array[8, uint8]   # BCK, LCK, DIN, SCLK, SDIN, CS, D/C, RES
    irPin: uint32
    reserved: array[5, uint32]

  Capture = object
    block0: pointer         # header, excerpt, samples
    lli: ptr array[Items, DmaLli]
    dma: Dma
    state: State
    header: ptr Header

static: doAssert sizeof(Header) == HeaderWords * 4 and PrefixBytes mod CacheLine.int == 0

var cap: Capture

proc alignedAlloc(bytes: uint): pointer =
  let size = (bytes + CacheLine - 1) and not (CacheLine - 1)
  let raw = cast[uint](allocShared0(size + CacheLine))
  cast[pointer]((raw + CacheLine - 1) and not (CacheLine - 1))

proc samplesAddr(): uint {.inline.} = cast[uint](cap.block0) + PrefixBytes.uint

proc watch(pin: int) =
  ## Let the pad's level be read back; the output side is not touched.
  regSet(gpioCfgAddr(pin.uint32), 1'u32 shl GpioIe)

proc setUp(): bool =
  if cap.block0 != nil: return true
  cap.block0 = alignedAlloc(uint(PrefixBytes + Samples * 4))
  cap.lli = cast[ptr array[Items, DmaLli]](alignedAlloc(sizeof(cap.lli[]).uint))
  if cap.block0 == nil or cap.lli == nil: return false
  cap.header = cast[ptr Header](cap.block0)
  cap.header.magic = 0x31504350'u32
  cap.header.samples = Samples
  cap.header.ringFrames = RingFrames
  cap.header.pins = [I2sBclkPin.uint8, I2sFsPin.uint8, I2sDoPin.uint8, OledSclkPin.uint8,
                     OledSdinPin.uint8, OledCsPin.uint8, OledDcPin.uint8, OledResPin.uint8]
  cap.header.irPin = IrPin
  for i in 0 ..< Items:
    cap.lli[i] = buildLli(
      srcAddr = GpioInputs,
      dstAddr = uint32(samplesAddr()) + uint32(i * PerItem * 4),
      transferSize = PerItem,
      srcIncr = false, dstIncr = true,
      nextLli = (if i + 1 < Items: cast[uint32](addr cap.lli[i + 1]) else: 0),
      srcBurst = burst1, dstBurst = burst1)
  dcacheCleanRange(cast[uint](cap.lli), sizeof(cap.lli[]).uint)
  for pin in [I2sBclkPin, I2sFsPin, I2sDoPin, OledSclkPin, OledSdinPin, OledCsPin,
              OledDcPin, OledResPin]:
    watch(pin)
  true

proc load() =
  ## Point the stopped channel at the start of the buffer. The buffer's
  ## cache lines are dropped so nothing stale is written over the samples.
  cap.dma.stopChannel(Channel)
  cap.dma.clearTcInterrupt(Channel)
  cap.dma.clearErrInterrupt(Channel)
  dcacheCleanInvalidateRange(samplesAddr(), uint(Samples * 4))
  cap.dma.configureChannelLli(Channel, addr cap.lli[0], DmaTransferConfig(flow: flowM2M_Dma))

proc running(): bool =
  cap.dma.channelEnabled(Channel) and
    cap.dma.channelDstAddr(Channel) < uint32(samplesAddr()) + uint32(Samples * 4)

proc finish() =
  cap.dma.stopChannel(Channel)
  dcacheInvalidateRange(samplesAddr(), uint(Samples * 4))
  cap.state = psDone

proc captureNow(stretch: uint32) =
  ## The whole capture with interrupts off, timed: the audio DMA keeps
  ## feeding the I2S block by itself, so its pins are seen undisturbed.
  load()
  let wasOn = (csrReadMstatus() and 8) != 0
  disableInterrupts()
  if stretch > 1:
    # Slow the I2S clock and let the frames already in the FIFO at the old
    # rate go out before sampling.
    stretchClock(stretch)
    let settle = nowUs() + 2000
    while nowUs() < settle: discard
  let frame = readPos() div 2
  let t0 = nowUs()
  cap.dma.startChannel(Channel)
  var guard = 0
  while running() and guard < 20_000_000: inc guard
  let t1 = nowUs()
  if stretch > 1: stretchClock(1)
  if wasOn: enableInterrupts()
  finish()
  let h = cap.header
  h.trigger = 0
  h.reserved[0] = stretch
  h.elapsedUs = uint32(t1 - t0)
  h.rateHz = if t1 > t0: uint32(Samples.uint64 * 1_000_000 div (t1 - t0)) else: 0
  h.ringFrame = frame.uint32
  let start = (frame + RingFrames - ExcerptLead) mod RingFrames
  h.excerptStart = start.uint32
  let ring = ringBuffer()
  let excerpt = cast[ptr UncheckedArray[int16]](cast[uint](cap.block0) + uint(HeaderWords * 4))
  for i in 0 ..< ExcerptFrames:
    let f = (start + i) mod RingFrames
    excerpt[2 * i] = ring[2 * f]
    excerpt[2 * i + 1] = ring[2 * f + 1]

type Want* = enum pwNone, pwFrame, pwInit, pwFast

proc pincapWants*(): Want {.inline.} =
  ## For the display task, just before it starts a frame: a capture is armed
  ## for a slow frame, for the init sequence and a slow frame, or for a
  ## frame at the normal clock.
  case cap.state
  of psArmedFrame: pwFrame
  of psArmedInit: pwInit
  of psArmedFast: pwFast
  else: pwNone

proc pincapBegin*() =
  ## Start the armed capture (the display task calls this, then sends).
  cap.header.trigger = (case cap.state
    of psArmedInit: 2'u32
    of psArmedFast: 3
    else: 1)
  cap.header.elapsedUs = 0
  load()
  cap.dma.startChannel(Channel)
  cap.state = psRunning

# ---- IR ----------------------------------------------------------------------

proc irSynth(t: var Text[960]) =
  ## An NEC frame on the IR pin, made by switching between the pad's
  ## pull-down (a burst: the receiver pulls low) and pull-up (idle). Only
  ## works with nothing driving the pin; says so otherwise.
  var deadline = nowUs()
  var lows, highs, wrong = 0
  template hold(low: bool; us: int) =
    gpioSetPull(IrPin.uint32, if low: pullDown else: pullUp)
    deadline += us.uint64
    while nowUs() < deadline: discard
    if gpioRead(IrPin.uint32) == low: inc wrong
    if low: inc lows else: inc highs
  hold(false, 2000)
  hold(true, 9000)
  hold(false, 4500)
  let frame = SynthAddress.uint32 or ((not SynthAddress).uint32 shl 8) or
              (SynthCommand.uint32 shl 16) or ((not SynthCommand).uint32 shl 24)
  for bit in 0 ..< 32:
    hold(true, 560)
    hold(false, if ((frame shr bit) and 1) != 0: 1690 else: 560)
  hold(true, 560)
  hold(false, 2000)
  t.add "ir synth: addr 0x00 cmd 0x45, "
  t.addInt lows + highs
  t.add " periods, "
  t.addInt wrong
  t.add " where the pin did not follow its pull resistor\n"
  if wrong > 0:
    t.add "the pin is driven by something else (a receiver?): press a remote key instead\n"
  else:
    t.add "now read /stats: \"ir: last code addr 0x00 cmd 0x45\" and frames +1\n"

# ---- HTTP --------------------------------------------------------------------

func has(path: openArray[char]; needle: string): bool =
  for start in 0 .. path.len - needle.len:
    var same = true
    for i in 0 ..< needle.len:
      if path[start + i] != needle[i]:
        same = false
        break
    if same: return true

proc addHex(t: var Text[960]; v: uint32) =
  const Digits = "0123456789abcdef"
  for shift in countdown(28, 0, 4): t.add Digits[int((v shr shift) and 0xF)]

proc pinDump(t: var Text[960]) =
  ## Each pad's configuration word, and the input-level word.
  for pin in [ConsoleTxPin.int, ConsoleRxPin.int, IrPin, I2sBclkPin, I2sFsPin, I2sDoPin,
              OledCsPin, OledSdinPin, OledSclkPin, OledDcPin, OledResPin]:
    t.add "gpio"
    t.addInt pin
    t.add " cfg "
    t.addHex regRead(gpioCfgAddr(pin.uint32))
    t.add '\n'
  t.add "inputs "
  t.addHex regRead(GpioInputs.uint)
  t.add '\n'

proc pullScan(t: var Text[960]) =
  ## Which pins follow their pull resistors (nothing else drives them)?
  ## Each pin not in use is briefly a GPIO input pulled down, then up.
  for pin in [0, 1, 2, 3, 4, 5, 8, 9, 10, 11, 16, 17, 18, 19, 22, 26, 30, 31, 32, 33]:
    let cfgAddr = gpioCfgAddr(pin.uint32)
    let saved = regRead(cfgAddr)
    var levels: array[2, bool]
    for i, pull in [pullDown, pullUp]:
      gpioInitInput(pin.uint32, pull)
      let until = nowUs() + 300
      while nowUs() < until: discard
      levels[i] = gpioRead(pin.uint32)
    regWrite(cfgAddr, saved or (1'u32 shl GpioIntMask))
    regWrite(cfgAddr, saved)
    t.addInt pin
    t.add (if not levels[0] and levels[1]: ":free "
           elif levels[0] and levels[1]: ":high "
           elif not levels[0]: ":low " else: ":odd ")
  t.add '\n'

proc i2sReport(t: var Text[960]) =
  ## The I2S block's registers, and the rate at which it really takes
  ## frames from the ring: with interrupts off, how far the audio DMA moves
  ## in 60 ms (the ring is 93 ms long). One FIFO word is one stereo frame,
  ## so this is the LCK frequency the block's clock produces.
  for (name, reg) in [("config ", I2sCfg), ("bclk   ", I2sBclkCfg), ("fifo0  ", I2sFifoCfg0),
                      ("fifo1  ", I2sFifoCfg1), ("io     ", I2sIoCfg)]:
    t.add "i2s "
    t.add name
    t.addHex regRead(reg)
    t.add '\n'
  const WindowUs = 60_000'u64
  let wasOn = (csrReadMstatus() and 8) != 0
  disableInterrupts()
  # Start on a frame boundary of the DMA's position, for a sharp edge.
  var p0 = readPos()
  var guard = 0
  while readPos() == p0 and guard < 1_000_000: inc guard
  p0 = readPos()
  let t0 = nowUs()
  while nowUs() - t0 < WindowUs: discard
  var p1 = readPos()
  guard = 0
  while readPos() == p1 and guard < 1_000_000: inc guard
  p1 = readPos()
  let t1 = nowUs()
  if wasOn: enableInterrupts()
  let frames = ((p1 - p0 + RingLen) mod RingLen) div 2
  t.add "i2s frames taken: "
  t.addInt frames
  t.add " in "
  t.addInt t1 - t0
  t.add " us = "
  t.addInt uint64(frames) * 1_000_000_000'u64 div (t1 - t0)
  t.add " mHz\n"

const HasTls = not defined(radioNoTls)
when HasTls:
  import bl808/mbedtls/hw
const HasHwCrypto = (when HasTls: MbedTlsHardware else: false)

when defined(bl808WifiMbedTlsSha1Hardware):
  var sha1Backend {.importc: "nim_mbedtls_sha1_backend".}: array[4, uint32]
    ## The Wi-Fi build's SHA-1 provider: state, hardware blocks, software
    ## blocks, faults.

proc cryptoReport(t: var Text[960]) =
  ## Which Mbed TLS backends ran on the chip's crypto hardware: each one's
  ## state (2 = checked against software and in use, 3 = retired) and how
  ## many operations went to hardware and to software since boot.
  when HasTls:
    template backend(name: string; counters: untyped; state, hw, sw, faults: int) =
      block:
        let c = counters
        t.add name
        t.add ": state "
        t.addInt c[state]
        t.add ", hardware "
        t.addInt c[hw]
        t.add ", software "
        t.addInt c[sw]
        t.add ", faults "
        t.addInt c[faults]
        t.add '\n'
    when defined(bl808WifiMbedTlsSha1Hardware):
      backend("sha1 blocks (WPA2 key derivation)", sha1Backend, 0, 1, 2, 3)
    else: t.add "sha1: software build\n"
    when MbedTlsHwSha256: backend("sha256 blocks", mbedTlsSha256Backend(), 0, 1, 2, 3)
    else: t.add "sha256: software build\n"
    when MbedTlsHwSha512: backend("sha512 blocks", mbedTlsSha512Backend(), 0, 1, 2, 3)
    else: t.add "sha512: software build\n"
    when MbedTlsHwAes:
      backend("aes blocks (state is for 128-bit keys)", mbedTlsAesBackend(), 0, 3, 4, 5)
      backend("aes blocks (state is for 256-bit keys)", mbedTlsAesBackend(), 2, 3, 4, 5)
    else: t.add "aes: software build\n"
    when MbedTlsHwGcm:
      backend("aes-gcm records (state is for 128-bit keys)", mbedTlsGcmBackend(), 0, 3, 4, 5)
      backend("aes-gcm records (state is for 256-bit keys)", mbedTlsGcmBackend(), 2, 3, 4, 5)
    else: t.add "aes-gcm: block by block\n"
    when MbedTlsHwP256: backend("p256 products", mbedTlsP256Backend(), 0, 1, 2, 3)
    else: t.add "p256: software build\n"
    when MbedTlsHwRsa: backend("rsa public ops", mbedTlsRsaBackend(), 0, 1, 2, 3)
    else: t.add "rsa: software build\n"
  else:
    t.add "built without TLS\n"

when HasHwCrypto:
  type
    GcmContext {.importc: "mbedtls_gcm_context", header: "<mbedtls/gcm.h>".} = object
    AesCtx {.importc: "mbedtls_aes_context", header: "<mbedtls/aes.h>".} = object
    Sha256Ctx {.importc: "mbedtls_sha256_context", header: "<mbedtls/sha256.h>".} = object
    Sha512Ctx {.importc: "mbedtls_sha512_context", header: "<mbedtls/sha512.h>".} = object

  proc mbedtls_gcm_init(ctx: ptr GcmContext) {.importc, header: "<mbedtls/gcm.h>".}
  proc mbedtls_gcm_free(ctx: ptr GcmContext) {.importc, header: "<mbedtls/gcm.h>".}
  proc mbedtls_gcm_setkey(ctx: ptr GcmContext; cipher: cint; key: ptr uint8; bits: cuint): cint
    {.importc, header: "<mbedtls/gcm.h>".}
  proc mbedtls_gcm_crypt_and_tag(ctx: ptr GcmContext; mode: cint; length: csize_t;
    iv: ptr uint8; ivLen: csize_t; ad: ptr uint8; adLen: csize_t; input, output: ptr uint8;
    tagLen: csize_t; tag: ptr uint8): cint {.importc, header: "<mbedtls/gcm.h>".}
  proc mbedtls_aes_init(ctx: ptr AesCtx) {.importc, header: "<mbedtls/aes.h>".}
  proc mbedtls_aes_setkey_enc(ctx: ptr AesCtx; key: ptr uint8; bits: cuint): cint
    {.importc, header: "<mbedtls/aes.h>".}
  proc hwAes(ctx: ptr AesCtx; input, output: ptr uint8): cint {.importc: "bl808_mbedtls_aes_encrypt", cdecl.}
  proc swAes(ctx: ptr AesCtx; input, output: ptr uint8): cint {.importc: "bl808_software_aes_encrypt", cdecl.}
  proc hwSha256(ctx: ptr Sha256Ctx; data: ptr uint8): cint {.importc: "bl808_mbedtls_sha256_process", cdecl.}
  proc swSha256(ctx: ptr Sha256Ctx; data: ptr uint8): cint {.importc: "bl808_software_sha256_process", cdecl.}
  proc hwSha512(ctx: ptr Sha512Ctx; data: ptr uint8): cint {.importc: "bl808_mbedtls_sha512_process", cdecl.}
  proc swSha512(ctx: ptr Sha512Ctx; data: ptr uint8): cint {.importc: "bl808_software_sha512_process", cdecl.}
  proc hwP256(scalar, px, py, rx, ry: ptr uint8): cint {.importc: "bl808_mbedtls_p256_mul", cdecl.}
  proc swP256(scalar, px, py, rx, ry: ptr uint8): cint {.importc: "bl808_software_p256_mul", cdecl.}

  const
    P256Gx = [0x6B'u8, 0x17, 0xD1, 0xF2, 0xE1, 0x2C, 0x42, 0x47, 0xF8, 0xBC, 0xE6, 0xE5, 0x63, 0xA4,
              0x40, 0xF2, 0x77, 0x03, 0x7D, 0x81, 0x2D, 0xEB, 0x33, 0xA0, 0xF4, 0xA1, 0x39, 0x45,
              0xD8, 0x98, 0xC2, 0x96]
    P256Gy = [0x4F'u8, 0xE3, 0x42, 0xE2, 0xFE, 0x1A, 0x7F, 0x9B, 0x8E, 0xE7, 0xEB, 0x4A, 0x7C, 0x0F,
              0x9E, 0x16, 0x2B, 0xCE, 0x33, 0x57, 0x6B, 0x31, 0x5E, 0xCE, 0xCB, 0xB6, 0x40, 0x68,
              0x37, 0xBF, 0x51, 0xF5]

  proc benchReport(t: var Text[960]; path: openArray[char]) =
    ## Microseconds per operation on the chip's hardware and in software,
    ## and what AES-256-GCM manages end to end as TLS uses it.
    template line(name: string; n: int; hw, sw: untyped) =
      block:
        var t0 = nowUs()
        for _ in 0 ..< n: discard hw
        let hwUs = nowUs() - t0
        t0 = nowUs()
        for _ in 0 ..< n: discard sw
        let swUs = nowUs() - t0
        t.add name
        t.add ": hardware "
        t.addInt hwUs * 1000 div n.uint64
        t.add " ns, software "
        t.addInt swUs * 1000 div n.uint64
        t.add " ns\n"
    var data: array[128, uint8]
    for i in 0 ..< data.len: data[i] = uint8(i * 7 + 1)
    var s256: Sha256Ctx
    var s512: Sha512Ctx
    zeroMem(addr s256, sizeof(s256))
    zeroMem(addr s512, sizeof(s512))
    template wanted(name: string): bool = not path.has("only=") or path.has("only=" & name)
    if wanted("sha256"): line("sha256 block", 2000, hwSha256(addr s256, addr data[0]), swSha256(addr s256, addr data[0]))
    if wanted("sha512"): line("sha512 block", 1000, hwSha512(addr s512, addr data[0]), swSha512(addr s512, addr data[0]))
    var aes: AesCtx
    var outBlock: array[16, uint8]
    mbedtls_aes_init(addr aes)
    discard mbedtls_aes_setkey_enc(addr aes, addr data[0], 256)
    if wanted("aes"):
      line("aes-256 block", 4000, hwAes(addr aes, addr data[16], addr outBlock[0]),
           swAes(addr aes, addr data[16], addr outBlock[0]))
    var gx = P256Gx
    var gy = P256Gy
    var rx, ry: array[32, uint8]
    if wanted("p256"):
      # The provider leaves multiples of the base point to software (Mbed
      # TLS has G's table built in); any other point, as for a shared secret
      # or a signature check, goes to the PKA.
      var qx, qy: array[32, uint8]
      var t0 = nowUs()
      discard swP256(addr data[40], addr gx[0], addr gy[0], addr qx[0], addr qy[0])
      t.add "p256 base point multiplication: software "
      t.addInt (nowUs() - t0) div 1000
      t.add " ms\n"
      discard hwP256(addr data[1], addr qx[0], addr qy[0], addr rx[0], addr ry[0])   # first-use check
      line("p256 point multiplication", 2,
           hwP256(addr data[1], addr qx[0], addr qy[0], addr rx[0], addr ry[0]),
           swP256(addr data[1], addr qx[0], addr qy[0], addr rx[0], addr ry[0]))
    # A 4 KB record of AES-256-GCM as built.
    const RecordLen = 4096
    let buf = if wanted("gcm"): cast[ptr UncheckedArray[uint8]](allocShared0(RecordLen)) else: nil
    if buf != nil:
      var gcm: GcmContext
      var tag: array[16, uint8]
      mbedtls_gcm_init(addr gcm)
      discard mbedtls_gcm_setkey(addr gcm, 2, addr data[0], 256)    # MBEDTLS_CIPHER_ID_AES
      let t0 = nowUs()
      for _ in 0 ..< 8:
        discard mbedtls_gcm_crypt_and_tag(addr gcm, 1, RecordLen, addr data[32], 12, addr data[48],
                                          13, addr buf[0], addr buf[0], 16, addr tag[0])
      let us = nowUs() - t0
      mbedtls_gcm_free(addr gcm)
      deallocShared(buf)
      t.add "aes-256-gcm: "
      t.addInt 8'u64 * RecordLen * 1_000_000 div 1024 div us
      t.add " KB/s ("
      t.addInt us * 1000 div (8 * RecordLen div 16)
      t.add " ns per 16-byte block)\n"

# ---- Profiler ------------------------------------------------------------------
# A timer interrupt about 2000 times a second notes where the processor was.
# `POST /selftest/profile` starts a run of `ProfileSamples`; `GET` returns the
# program counters as little-endian words once it is full. With `?stall` the
# run keeps the newest samples and stops when the stall probe (start it too)
# sees a stall of 40 ms: `GET ...?info` then says which sample is the last. Match them to
# functions with `riscv64-unknown-elf-nm -S` on the firmware's ELF. Code
# that runs with interrupts off shows up at the point where they come back on.

const
  ProfileSamples = 16384
  ProfilePeriod = 19_937'u32        # timer ticks at the 40 MHz crystal: 2006 Hz

var
  profile: ptr UncheckedArray[uint32]
  profileCount: uint32
  profileTimer: Timer
  profileRunning: bool
  profileCircular: bool     ## keep the newest samples until a stall freezes the run
  profileStallUs: uint32    ## the stall that froze it

proc profileIsr() {.cdecl.} =
  profileTimer.clearInterrupt(timerCh2, 0)
  if profileCircular:
    profile[profileCount mod ProfileSamples] = csrReadMepc().uint32
    inc profileCount
  elif profileCount < ProfileSamples:
    profile[profileCount] = csrReadMepc().uint32
    inc profileCount
  else:
    profileTimer.disable(timerCh2)
    profileRunning = false

proc profileFreeze(stallUs: uint32) =
  ## The stall probe saw a long stall: keep what led up to it.
  if profileRunning and profileCircular:
    profileTimer.disable(timerCh2)
    profileRunning = false
    profileStallUs = stallUs

proc profileStart(circular: bool): bool =
  if profile == nil:
    profile = cast[ptr UncheckedArray[uint32]](allocShared0(ProfileSamples * 4))
    if profile == nil: return false
    profileTimer = initTimer(timer0)
    registerTrapHandler(IrqM0Timer0Ch0, profileIsr)
  if profileRunning: return false
  profileCount = 0
  profileCircular = circular
  profileStallUs = 0
  profileRunning = true
  profileTimer.setupPeriodic(timerCh2, ProfilePeriod, timerClkXtal)
  irqClearPending(IrqM0Timer0Ch0)
  irqSetLevel(IrqM0Timer0Ch0, 1)
  irqEnable(IrqM0Timer0Ch0)
  true

# ---- Stall probe ---------------------------------------------------------------
# A task that does nothing but yield: the time between two of its turns is
# how long everything else together (tasks, the kernel's poll hooks, the
# Wi-Fi stack, interrupts) kept the processor. Turns further apart than
# `StallUs` are logged with the time they ended.

const
  ProfileStallUs = 40_000'u64     # a stall this long freezes a `?stall` profile
  StallUs = 15_000'u64
  StallLog = 24

var
  probeOn: bool
  stallAtMs: array[StallLog, uint32]
  stallUs: array[StallLog, uint32]
  stallCount: uint32
  probeTurns: uint32
  probeSinceMs: uint64

proc probeTask(): CpsVoidFuture {.cps.} =
  var last = nowUs()
  var now = last
  while probeOn:
    await yieldNow()
    now = nowUs()
    inc probeTurns
    if now - last > ProfileStallUs: profileFreeze(uint32(now - last))
    if now - last > StallUs:
      stallAtMs[stallCount mod StallLog] = uint32(now div 1000)
      stallUs[stallCount mod StallLog] = uint32(now - last)
      inc stallCount
    last = now

proc stallReport(t: var Text[960]; start: bool) =
  if start and not probeOn:
    probeOn = true
    stallCount = 0
    probeTurns = 0
    probeSinceMs = nowMs()
    discard probeTask()
    t.add "probe started\n"
    return
  t.add "stalls over 15 ms: "
  t.addInt stallCount
  t.add " in "
  t.addInt (nowMs() - probeSinceMs) div 1000
  t.add " s, "
  t.addInt probeTurns
  t.add " turns; at ms / lasting us:\n"
  let shown = min(stallCount, StallLog.uint32)
  for i in 0'u32 ..< shown:
    let k = (stallCount - shown + i) mod StallLog
    t.addInt stallAtMs[k]
    t.add '/'
    t.addInt stallUs[k]
    t.add ' '
  t.add '\n'
  if not start: probeOn = false

var sliceSinceUs: uint64

proc sliceReport(t: var Text[960]) =
  ## The longest each task has held the processor since the last read, and
  ## the longest the audio task was kept waiting (`/stats` shows that too).
  const Names: array[TaskSlice, string] = ["audio step", "display draw", "display frame start",
    "display frame end", "stream step", "http step", "controls step", "ntp step", "network step"]
  let now = nowUs()
  let span = max(now - sliceSinceUs, 1)
  sliceSinceUs = now
  var accounted = 0'u64
  for slice in TaskSlice:
    t.add Names[slice]
    t.add ": longest "
    t.addInt sliceMaxUs[slice]
    t.add " us, "
    t.addInt sliceTotalUs[slice] * 1000 div span
    t.add " permille of the time\n"
    accounted += sliceTotalUs[slice]
    sliceMaxUs[slice] = 0
    sliceTotalUs[slice] = 0
  t.add "everything else (kernel, Wi-Fi, idle): "
  t.addInt (span - min(accounted, span)) * 1000 div span
  t.add " permille over "
  t.addInt span div 1_000_000
  t.add " s\n"

proc route(isPost: bool; path: openArray[char]; t: var Text[960]; blob: var Chunk): bool {.nimcall.} =
  when defined(radioDiag):
    if path.has("/selftest/cpu"):
      if isPost:
        schedulerCpuTimingReset()
      let cpu = schedulerCpuTimingSnapshot()
      t.add "window-us "
      t.addInt cpu.elapsedUs
      t.add " wfi-us "
      t.addInt cpu.wfiUs
      t.add " wfi-calls "
      t.addInt cpu.wfiCalls
      t.add '\n'
      t.add "wfi-permille "
      t.addInt min(cpu.wfiUs, cpu.elapsedUs) * 1000 div max(cpu.elapsedUs, 1'u64)
      t.add '\n'
      return true
    if path.has("/selftest/wifi-pmk"):
      let pmk = wpa2PmkTimingSnapshot()
      t.add "slices "
      t.addInt pmk.slices
      t.add " max-slice-us "
      t.addInt pmk.maxSliceUs
      t.add '\n'
      t.add "prepared-hits "
      t.addInt pmk.preparedHits
      t.add " fallback-calls "
      t.addInt pmk.fallbackCalls
      t.add '\n'
      return true
    if path.has("/selftest/wifi-main"):
      var phases: array[4, uint32]
      var event: array[5, uint32]
      var staAdd: array[4, uint32]
      wifi_fw_main_phase_snapshot(addr phases)
      wifi_fw_event_timing_snapshot(addr event)
      wifi_fw_sta_add_phase_snapshot(addr staAdd)
      const names = ["control", "sleep", "wait", "dispatch"]
      for i in 0 ..< phases.len:
        t.add names[i]
        t.add ' '
        t.addInt phases[i]
        t.add '\n'
      t.add "event-index "
      t.addInt event[0]
      t.add " event-us "
      t.addInt event[1]
      t.add '\n'
      t.add "message-id "
      t.addInt event[2]
      t.add " destination "
      t.addInt event[3]
      t.add " message-us "
      t.addInt event[4]
      t.add '\n'
      const staNames = ["key-plan", "register", "hardware-address", "key-setup"]
      for i in 0 ..< staAdd.len:
        t.add staNames[i]
        t.add ' '
        t.addInt staAdd[i]
        t.add '\n'
      return true
    if path.has("/selftest/wifi-compat"):
      if isPost:
        bl808_wifi_backend_cps_compat_reset()
      var counts: array[3, uint32]
      bl808_wifi_backend_cps_compat_counts(addr counts)
      t.add "nested-wait-polls "
      t.addInt counts[0]
      t.add " sleep-polls "
      t.addInt counts[1]
      t.add " legacy-poll-calls "
      t.addInt counts[2]
      t.add '\n'
      return true
    if path.has("/selftest/wifi-drain"):
      if isPost:
        bl808_wifi_backend_drain_timing_reset()
      var drain: array[6, uint32]
      bl808_wifi_backend_drain_timing_snapshot(addr drain)
      const names = ["irq", "firmware", "host", "step", "total", "steps"]
      for i in 0 ..< drain.len:
        t.add names[i]
        t.add ' '
        t.addInt drain[i]
        t.add '\n'
      return true
    if path.has("/selftest/audio-sched"):
      if isPost:
        stats.audioYieldWaitMaxUs = 0
        stats.audioSleepOvershootMaxUs = 0
        stats.audioYieldWaitOver15ms = 0
        stats.audioSleepOver15ms = 0
      t.add "yield-wait-us "
      t.addInt stats.audioYieldWaitMaxUs
      t.add " over-15ms "
      t.addInt stats.audioYieldWaitOver15ms
      t.add '\n'
      t.add "sleep-overshoot-us "
      t.addInt stats.audioSleepOvershootMaxUs
      t.add " over-15ms "
      t.addInt stats.audioSleepOver15ms
      t.add '\n'
      return true
    if path.has("/selftest/wifi-phases"):
      if isPost:
        bl808_wifi_backend_phase_timing_reset()
      var phaseUs: array[11, uint32]
      bl808_wifi_backend_phase_timing_snapshot(addr phaseUs)
      const names = ["emb", "mac", "main", "scheduled", "mgmr", "host",
                     "timer", "events", "delayed", "pending", "poll"]
      for i in 0 ..< phaseUs.len:
        t.add names[i]
        t.add ' '
        t.addInt phaseUs[i]
        t.add '\n'
      return true
    if path.has("/selftest/wifi-sched"):
      if isPost:
        wifiServiceTimingReset()
      let s = wifiServiceTimingSnapshot()
      t.add "callbacks "
      t.addInt s.callbacks
      t.add " full-budget "
      t.addInt s.fullBudgetCallbacks
      t.add " over-15ms "
      t.addInt s.slowCallbacks
      t.add '\n'
      t.add "max rounds "
      t.addInt s.maxRounds
      t.add " callback-us "
      t.addInt s.maxCallbackUs
      t.add " backend-us "
      t.addInt s.maxBackendUs
      t.add " tx-us "
      t.addInt s.maxTxUs
      t.add " completion-us "
      t.addInt s.maxCompletionUs
      t.add '\n'
      t.add "total callback-us "
      t.addInt s.totalCallbackUs
      t.add " backend-us "
      t.addInt s.totalBackendUs
      t.add '\n'
      return true
    if path.has("/selftest/scheduler"):
      if isPost:
        schedulerTimingReset()
      let s = schedulerTimingSnapshot()
      t.add "iteration-us "
      t.addInt s.maxIterationUs
      t.add " long-iterations "
      t.addInt s.longIterations
      t.add " batch-us "
      t.addInt s.maxReadyBatchUs
      t.add " batch-len "
      t.addInt s.maxReadyBatchLen
      t.add '\n'
      t.add "ready-us "
      t.addInt s.maxReadyCallbackUs
      t.add " timer-us "
      t.addInt s.maxTimerCallbackUs
      t.add " poll-us "
      t.addInt s.maxPollHookUs
      t.add " timed-us "
      t.addInt s.maxTimedHookUs
      t.add '\n'
      t.add "timer-late-us "
      t.addInt s.maxTimerLatenessUs
      t.add " late-over-15ms "
      t.addInt s.lateTimersOver15ms
      t.add " between-iterations-us "
      t.addInt s.maxBetweenIterationsUs
      t.add '\n'
      return true
  if path.has("/selftest/profile"):
    if isPost:
      t.add (if profileStart(circular = path.has("stall")): "profiling\n"
             else: "busy or no memory\n")
    elif profile != nil and not profileRunning and profileCount > 0 and path.has("info"):
      # For a `?stall` run: the stall's length and where the newest sample is.
      t.add "stall us "
      t.addInt profileStallUs
      t.add " newest "
      t.addInt (profileCount + ProfileSamples - 1) mod ProfileSamples
      t.add " count "
      t.addInt profileCount
      t.add '\n'
    elif profile != nil and not profileRunning and profileCount > 0:
      blob = Chunk(data: cast[ptr UncheckedArray[byte]](profile),
                   len: int(min(profileCount, ProfileSamples)) * 4)
    else:
      t.add "not ready: "
      t.addInt profileCount
      t.add " samples\n"
    return true
  if path.has("/selftest/stalls"):
    stallReport(t, isPost)
    return true
  if path.has("/selftest/slices"):
    sliceReport(t)
    return true
  if path.has("/selftest/bench"):
    when HasHwCrypto: benchReport(t, path)
    else: t.add "no hardware crypto in this build\n"
    return true
  if path.has("/selftest/crypto"):
    cryptoReport(t)
    return true
  if path.has("/selftest/i2s"):
    i2sReport(t)
    return true
  if path.has("/selftest/pulls"):
    pullScan(t)
    return true
  if path.has("/selftest/pins"):
    pinDump(t)
    return true
  if path.has("/selftest/ir"):
    if isPost: irSynth(t) else: t.add "POST it\n"
    return true
  if not path.has("/selftest/capture"): return false
  if not setUp():
    t.add "no memory\n"
    return true
  if cap.state == psRunning and not running(): finish()
  if isPost:
    if cap.state in {psArmedFrame, psArmedInit, psArmedFast, psRunning}:
      t.add "busy\n"
    elif path.has("t=frame"):
      cap.state = psArmedFrame
      t.add "armed: next frame\n"
    elif path.has("t=fast"):
      cap.state = psArmedFast
      t.add "armed: next frame at full speed\n"
    elif path.has("t=init"):
      cap.state = psArmedInit
      t.add "armed: panel init, then a frame\n"
    else:
      captureNow(if path.has("t=slow"): 8 else: 1)
      t.add "done: "
      t.addInt Samples
      t.add " samples in "
      t.addInt cap.header.elapsedUs
      t.add " us, "
      t.addInt cap.header.rateHz
      t.add " per second\n"
  elif cap.state == psDone:
    blob = Chunk(data: cast[ptr UncheckedArray[byte]](cap.block0),
                 len: PrefixBytes + Samples * 4)
  else:
    t.add (case cap.state
      of psIdle: "nothing captured\n"
      of psRunning: "running\n"
      else: "armed\n")
  true

proc pincapInit*() =
  cap.dma = openCoreDma()
  let channel = cap.dma.reserveChannel(Channel)
  doAssert channel == Channel
  diagExtra = route
