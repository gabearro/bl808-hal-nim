## The display task (upstream `display::display_task`): brings up the
## SSD1322, then draws frames from the shared state with `display.renderFrame`
## and sends them to the panel. Allocates the framebuffer and publishes it as
## `ui.screen`.
##
## Redrawn at 50 fps on a fixed grid while something is moving (a stream is
## active, text is scrolling, the menu is open, a fade is running) and five
## times a second otherwise; an idle screen is woken at once by
## `ui.wakeRequested`. Firmware only.

import bl808/kernel/cps
import ./timebase, ./status, ./ui, ./netstate, ./diag, ./wallclock, ./presets,
       ./text, ./framebuf, ./ssd1322, ./display
when DiagEnabled and defined(bl808m0):
  import ./pincap

const
  FlushTimeoutMs = 100
    ## A frame takes about 12 ms to send; anything near this means the SPI
    ## transfer is stuck. It is abandoned and the next frame starts a fresh
    ## one, so a glitch costs a frame instead of the display (as upstream:
    ## nothing is held per frame, so this can happen any number of times).
  CaptureTimeoutMs = 500
  IdlePollUs = 5_000
    ## How often an idle screen looks for a wake request.

static: doAssert presets.NameMax == display.PresetNameMax

type
  Screen = object
    fb: FrameBuf
    oled: Oled
    display: Display
    inputs: FrameInputs
    frame: FrameResult          # what the last drawn frame asked for
    dim: float32                # the dimming last sent to the panel
    presetUrlHash: uint32       # FNV-1a of the URL the preset name was looked up for
    seenPresetsGen: uint32
    flushStartMs: uint64
    captureStartMs: uint64
    nextFrameUs: uint64
    lastFrameMs: uint64

var scr: ptr Screen

proc panelInit(s: var Screen) =
  s.oled.send initCommands()
  s.fb.clear()

proc panelOn(s: var Screen) =
  s.oled.command CmdDisplayOn
  s.display.initDisplay(nowMs())
  s.nextFrameUs = nowUs()

proc lookUpPreset(s: var Screen) =
  ## Which preset is playing: looked up only when the URL or the presets
  ## change (scanning 99 slots every frame would waste time).
  var hash = 0x811C_9DC5'u32
  for c in player.url.chars:
    hash = (hash xor c.uint32) * 0x0100_0193'u32
  let gen = presets.generation()
  if hash == s.presetUrlHash and gen == s.seenPresetsGen: return
  s.presetUrlHash = hash
  s.seenPresetsGen = gen
  s.inputs.presetName.clear()
  let index = presets.find(player.url.chars)
  if index >= 0:
    let preset = presets.get(index)
    s.inputs.presetName.set preset.name.chars

proc drawFrame(s: var Screen) =
  stats.displayStage = 1
  s.inputs.status = player
  s.inputs.net = net
  s.inputs.nowMs = nowMs()
  s.lookUpPreset()
  s.inputs.hasClock = wallclock.hourMinute(s.inputs.clock)
  s.frame = s.display.renderFrame(s.fb, s.inputs)
  if s.frame.dim != s.dim:
    s.dim = s.frame.dim
    s.oled.send dimCommands(s.dim)

# Screen recording (GET /screen/stream): each finished frame is handed to the
# web task, and the display waits while it is copied out, so every captured
# frame is whole.
proc captureBegin(s: var Screen): bool =
  if not ui.capture.on: return false
  ui.capture.snapReady = true
  s.captureStartMs = nowMs()
  true

proc capturePending(s: Screen): bool =
  not ui.capture.snapDone and elapsedMs(s.captureStartMs, nowMs()) < CaptureTimeoutMs

proc captureEnd() =
  ui.capture.snapDone = false
  inc ui.capture.frames

proc flushBegin(s: var Screen) =
  stats.displayStage = 2
  s.flushStartMs = nowMs()
  s.oled.flushStart(s.fb.buf)

proc flushPending(s: Screen): bool =
  not s.oled.flushDone() and elapsedMs(s.flushStartMs, nowMs()) < FlushTimeoutMs

proc flushEnd(s: var Screen) =
  if s.oled.flushDone():
    s.oled.flushEnd()
  else:
    inc stats.flushTimeouts
    s.oled.flushAbort()

proc frameDone(s: var Screen) =
  ## Count the frame and put the next one on the grid.
  let now = nowMs()
  if s.lastFrameMs != 0:
    let gap = uint32(now - s.lastFrameMs)
    stats.frameGapMaxMs = max(stats.frameGapMaxMs, gap)
    stats.frameGapMinMs = min(stats.frameGapMinMs, gap)
  s.lastFrameMs = now
  inc stats.displayFrames
  stats.displayStage = 3
  s.nextFrameUs += (if s.frame.fast: FrameActiveMs else: FrameIdleMs).uint64 * 1000
  s.nextFrameUs = max(s.nextFrameUs, nowUs())

proc frameWaitUs(s: Screen): uint64 =
  ## How long to sleep before looking again; 0 when the next frame is due.
  ## While animating the grid is fixed (an early extra frame makes scrolling
  ## judder; a new message appears on the next frame, within 20 ms). An idle
  ## screen shows a new message straight away.
  let now = nowUs()
  if now >= s.nextFrameUs: return 0
  if s.frame.animating: return s.nextFrameUs - now
  if ui.wakeRequested: return 0
  min(s.nextFrameUs - now, IdlePollUs)

proc frameStart(s: var Screen) =
  ui.wakeRequested = false
  if not s.frame.animating:
    s.nextFrameUs = nowUs()

proc displayTask(): CpsVoidFuture {.cps.} =
  var wait = 0'u64
  stats.displayStage = 10
  # Hardware reset, the init sequence, a black frame, then display on.
  scr.oled.resetPin(false)
  await sleepMs(1)
  scr.oled.resetPin(true)
  await sleepMs(10)
  panelInit(scr[])
  flushBegin(scr[])
  while flushPending(scr[]):
    await sleepMs(1)
  flushEnd(scr[])
  panelOn(scr[])

  while true:
    drawFrame(scr[])
    if captureBegin(scr[]):
      while capturePending(scr[]):
        await sleepMs(1)
      captureEnd()
    when DiagEnabled and defined(bl808m0):
      # Pin self-test: start the capture, then send as usual.
      # The whole frame goes out at 1 MHz so every bit can be read.
      case pincapWants()
      of pwInit:
        scr.oled.setSlow(true)
        pincapBegin()
        scr.oled.send initCommands()
      of pwFrame:
        scr.oled.setSlow(true)
        pincapBegin()
      of pwFast:
        pincapBegin()
      of pwNone:
        discard
    flushBegin(scr[])
    while flushPending(scr[]):
      await sleepMs(1)
    flushEnd(scr[])
    when DiagEnabled and defined(bl808m0):
      scr.oled.setSlow(false)
    frameDone(scr[])
    wait = frameWaitUs(scr[])
    while wait > 0:
      await sleepUs(wait)
      wait = frameWaitUs(scr[])
    frameStart(scr[])

proc displayStart*() =
  ## Allocate the screen state and the framebuffer, set up the pins and
  ## SPI, and start the task (the boot animation begins once the panel
  ## answers).
  scr = createShared(Screen)
  ui.screen = cast[ptr array[ScreenBytes, byte]](allocShared0(ScreenBytes))
  scr.fb = initFrameBuf(ui.screen)
  scr.seenPresetsGen = high(uint32)
  scr.oled = oledOpen()
  discard displayTask()
