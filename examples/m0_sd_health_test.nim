## M0 SD card health/metadata test.
##
## Mounts the existing FatFs/exFAT volume without formatting, then queries the
## SD HAL health snapshot. The snapshot includes controller state, CMD13 card
## status, captured CID/CSD, decoded capacity, and optional ACMD13 SD Status.

import bl808/startup
import bl808/core
import bl808/glb, bl808/gpio, bl808/uart
import bl808/kernel/alloc
import bl808/kernel/fatfs
import bl808/kernel/sdblk

const
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz {.intdefine.} = 40_000_000'u32

var console: Uart

proc line(s: string) =
  discard console.sendLine(s)

proc pass(label: string) =
  discard console.sendString("[PASS] ")
  discard console.sendLine(label)

proc fail(label: string, value: uint32 = 0) =
  discard console.sendString("[FAIL] ")
  discard console.sendString(label)
  discard console.sendString(" value=")
  console.sendHex32(value)
  discard console.sendString(" sd_phase=")
  console.sendHex32(sdLastPhase)
  discard console.sendString(" sd_err=")
  console.sendHex32(sdLastError.ord.uint32)
  discard console.sendString(" sd_cmd=")
  console.sendHex32(sdLastCommand)
  discard console.sendLine("")

proc logWord(label: string, value: uint32) =
  discard console.sendString("  ")
  discard console.sendString(label)
  discard console.sendString("=")
  console.sendHex32(value)
  discard console.sendLine("")

proc logBool(label: string, value: bool) =
  logWord(label, if value: 1'u32 else: 0'u32)

proc main() {.exportc, cdecl.} =
  systemInit()
  heapInit()

  enablePeriphClock(periphUart0)
  setMcuXclkSource(mcuXclkXtal)
  setUartClock(true, uartClkXclk, 0)
  gpioSetupUart(14, 15)
  console = initUart(uart0, UartConfig(
    baudRate: ConsoleBaud, dataBits: data8,
    stopBits: stop1, parity: parityNone,
  ), ConsoleClkHz)

  line("")
  line("=== BL808 SD Health Test ===")

  var fs: SdFs
  let mountStatus = fs.mount()
  if mountStatus != frOk:
    fail("mounted existing filesystem without format", mountStatus.uint32)
    while true: wfi()
  pass("mounted existing filesystem without format")

  let h = sdSnapshotHealth()
  logBool("present", h.present)
  logBool("stable", h.stable)
  logBool("ready", h.ready)
  logBool("sdhc", h.sdhc)
  logWord("rca", h.rca)
  logWord("r1", h.r1Status)
  logWord("mid", h.cidManufacturerId.uint32)
  logWord("oid", h.cidOemId.uint32)
  logWord("prv", h.cidProductRevision.uint32)
  logWord("psn", h.cidSerialNumber)
  logWord("mdt", h.cidManufacturingDate.uint32)
  logWord("csdVersion", h.csdVersion.uint32)
  logWord("tranSpeed", h.csdTranSpeed.uint32)
  logWord("cmdClasses", h.csdCommandClasses.uint32)
  logWord("readBlockLen", h.readBlockLen)
  logWord("writeBlockLen", h.csdWriteBlockLen)
  logWord("eraseSectorSize", h.csdEraseSectorSize)
  logWord("capacityHi", (h.capacityBytes shr 32).uint32)
  logWord("capacityLo", (h.capacityBytes and 0xFFFF_FFFF'u64).uint32)
  logWord("sectors", h.sectorCount)
  logBool("sdStatusOk", h.sdStatusOk)
  logWord("sdStatus0", h.sdStatusRaw[0])
  logWord("sdBusWidth", h.sdStatusBusWidth.uint32)
  logWord("sdCardType", h.sdStatusCardType.uint32)
  logWord("sdSpeedClass", h.sdStatusSpeedClass.uint32)
  logWord("sdAuSize", h.sdStatusAuSize.uint32)
  logWord("readOps", h.readOps)
  logWord("writeOps", h.writeOps)
  logWord("readErrors", h.readErrors)
  logWord("writeErrors", h.writeErrors)

  if not h.present or not h.stable:
    fail("card present and stable")
    while true: wfi()
  pass("card present and stable")

  if not h.ready:
    fail("card ready")
    while true: wfi()
  pass("card ready")

  if not h.cmd13Ok:
    fail("CMD13 card status", h.lastError.ord.uint32)
    while true: wfi()
  pass("CMD13 card status")

  if not h.cidValid:
    fail("CID captured")
    while true: wfi()
  pass("CID captured")

  if not h.csdValid or h.capacityBytes == 0 or h.sectorCount == 0:
    fail("CSD capacity decoded", h.csdVersion.uint32)
    while true: wfi()
  pass("CSD capacity decoded")

  if h.sdStatusOk:
    pass("ACMD13 SD status captured")
  else:
    pass("ACMD13 SD status optional unavailable")

  fs.deinit()
  line("=== Test Complete ===")
  while true:
    wfi()
