## FreeNetRadio for the Pine64 Ox64 (BL808, M0 core): a Nim port of
## https://github.com/alexhorner/freenetradio.
##
## Plays MP3 internet radio (http and https, playlists, ICY titles) through
## a PCM5102A I2S DAC, shows it on a 256x64 SSD1322 OLED, and is controlled
## from a web page over Wi-Fi or an NEC infrared remote. See README.md for
## wiring, the build command and what differs from the CH32V307 original.

import bl808/startup
import bl808/core
import bl808/glb, bl808/gpio, bl808/uart
import bl808/panicoverride
import bl808/psram
import bl808/kernel/cps
import bl808/kernel/log

import ./board, ./timebase, ./diag, ./status, ./pipe, ./prefs, ./menu,
       ./spectrum, ./wallclock
import ./net_task, ./stream_task, ./audio_task, ./display_task,
       ./controls_task, ./http_task
when DiagEnabled:
  import ./httpd, ./pincap

const ConsoleClkHz = 40_000_000'u32

var
  console: Uart
  psramBssStart {.importc: "__psram_bss_start".}: byte
  psramBssEnd {.importc: "__psram_bss_end".}: byte

proc kernelNowUs(): uint64 {.nimcall.} = ticksToUs(readTick())

when DiagEnabled:
  # Stack high-water mark for `/stats` (upstream's `stack_usage`): fill the
  # unused stack with a pattern at boot, later count how much of it is still
  # intact. The stack is the linker profile's (`__bl808_app_stack_bytes`,
  # set in freenetradio.nims), from the kernel's guard words at its low end
  # to the top of on-chip RAM; every task runs on it.
  const StackPattern = 0xA5A5_A5A5'u32

  var
    stackStart {.importc: "_sstack".}: uint32
    stackTop {.importc: "_estack".}: uint32

  proc stackFloor(): uint {.inline.} =
    ## The first word above the kernel's guard words (kernel/fault.nim).
    cast[uint](addr stackStart) + 32 * 4

  proc paintStack() {.noinline.} =
    var here: uint32       # a local: its address is where the stack is now
    let limit = cast[uint](addr here) - 256
    var p = stackFloor()
    while p < limit:
      cast[ptr uint32](p)[] = StackPattern
      p += 4

  proc stackUnused(unused, total: var int) {.nimcall.} =
    ## Bytes never touched, and the stack's size.
    let bottom = stackFloor()
    let top = cast[uint](addr stackTop)
    var p = bottom
    while p < top and cast[ptr uint32](p)[] == StackPattern:
      p += 4
    unused = int(p - bottom)
    total = int(top - bottom)

proc setupMemory() =
  ## What the linker profile (`src/linker/bl808_m0_wifi_app.ld`) asks of
  ## main: PSRAM, then zero the window that holds this directory's globals,
  ## then the 1 MB heap. Nothing above this line may touch either.
  psramInit(psram64mb, psramBurst64)
  psramEnable()
  let bssLen = cast[uint](addr psramBssEnd) - cast[uint](addr psramBssStart)
  if bssLen > 0:
    zeroMem(addr psramBssStart, bssLen)
  heapInit()

proc setupConsole() =
  enableAllPeriphClocks()
  enablePeriphClock(periphUart0)
  setMcuXclkSource(mcuXclkXtal)
  setUartClock(true, uartClkXclk, 0)
  gpioSetupUart(ConsoleTxPin, ConsoleRxPin)
  console = initUart(uart0, UartConfig(
    baudRate: ConsoleBaud.uint32, dataBits: data8,
    stopBits: stop1, parity: parityNone,
  ), ConsoleClkHz)
  logInit(console)

proc main() {.exportc, cdecl.} =
  when DiagEnabled:
    paintStack()
  systemInit()
  setupMemory()
  setupConsole()
  logInfo "=== FreeNetRadio (BL808) ==="
  schedulerInit()
  setClock(kernelNowUs)

  # Wi-Fi first: wifiInit() runs Nim's module initialisers (PreMain), which
  # this bare-metal startup otherwise never runs. Everything below sets its
  # state explicitly, after that has happened.
  netStart()

  diagInit()
  statusInit()
  pipeInit()
  prefsInit()
  menuInit()
  spectrumInit()
  wallclockInit()
  when DiagEnabled:
    stackUsage = stackUnused
    pincapInit()

  displayStart()      # the boot animation
  audioStart()
  controlsStart()     # flash store, saved settings, IR, digits, NTP
  streamStart()       # after the settings are restored: it may start playing
  httpStart()
  runScheduler()
