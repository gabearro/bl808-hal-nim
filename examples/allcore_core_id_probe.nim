## BL808 all-core core-ID probe.
##
## M0 reports its own CoreIdAddr read over UART, releases D0 and LP, then
## reports the values written by programs running on those cores.

import bl808/startup
import bl808/core
import bl808/mmio, bl808/memmap

when defined(bl808m0):
  import bl808/glb, bl808/gpio, bl808/uart

const
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz {.intdefine.} = 40_000_000'u32

  ProbeBase = XramBase + 0x2E40'u
  M0MagicAddr = ProbeBase + 0x00'u
  M0CoreIdAddr = ProbeBase + 0x04'u
  M0HartIdAddr = ProbeBase + 0x08'u
  D0MagicAddr = ProbeBase + 0x10'u
  D0CoreIdAddr = ProbeBase + 0x14'u
  D0HartIdAddr = ProbeBase + 0x18'u
  LpMagicAddr = ProbeBase + 0x20'u
  LpCoreIdAddr = ProbeBase + 0x24'u
  LpHartIdAddr = ProbeBase + 0x28'u

  M0Magic = 0x4D30_4944'u32 # "M0ID"
  D0Magic = 0x4430_4944'u32 # "D0ID"
  LpMagic = 0x4C50_4944'u32 # "LPID"

proc writeSelf(magicAddr, coreAddr, hartAddr: uint, magic: uint32) =
  regWrite(coreAddr, regRead(CoreIdAddr))
  regWrite(hartAddr, csrReadMhartid().uint32)
  regWrite(magicAddr, magic)
  core.fenceIo()

when defined(bl808m0):
  const
    JtagD0StatusAddr = XramBase + 0x3E00'u
    JtagD0RunMagic = 0x4430_5255'u32 # "D0RU"
    JtagD0RunPollLimit = 8_000_000
    PeerPollLimit = 16_000_000

  var console: Uart

  proc printHex(label: string, value: uint32) =
    discard console.sendString(label)
    console.sendHex32(value)
    discard console.sendLine("")
    delayMs(20)

  proc line(text: string) =
    discard console.sendLine(text)
    delayMs(20)

  proc sharedRead32(address: uint): uint32 =
    dcacheFlushAll()
    dcacheInvalidateAll()
    core.fence()
    regRead(address)

  proc clearProbeState() =
    var offset = 0'u
    while offset <= 0x28'u:
      regWrite(ProbeBase + offset, 0)
      offset += 4'u
    regWrite(JtagD0StatusAddr, 0)
    dcacheFlushAll()
    core.fenceIo()

  proc switchJtagMuxToD0() =
    const jtagD0Gpio =
      (27'u32 shl 8) or (1'u32 shl 22) or (1'u32 shl 1) or 1'u32
    regWrite(GpioConfigBase + 6'u * 4'u, jtagD0Gpio)
    regWrite(GpioConfigBase + 7'u * 4'u, jtagD0Gpio)
    regWrite(GpioConfigBase + 12'u * 4'u, jtagD0Gpio)
    regWrite(GpioConfigBase + 13'u * 4'u, jtagD0Gpio)
    core.fenceIo()

  proc spinDelay() =
    for _ in 0 ..< 100:
      {.emit: """asm volatile("");""".}

  proc waitForJtagD0RunMagic() =
    for _ in 0 ..< JtagD0RunPollLimit:
      if sharedRead32(JtagD0StatusAddr) == JtagD0RunMagic:
        regWrite(JtagD0StatusAddr, 0)
        dcacheFlushAll()
        core.fenceIo()
        line("[diag] D0 JTAG run magic observed")
        return
      spinDelay()
    line("[FAIL] D0 JTAG load handshake timeout")

  proc waitForPeer(magicAddr: uint, magic: uint32): bool =
    for _ in 0 ..< PeerPollLimit:
      if sharedRead32(magicAddr) == magic:
        return true
      spinDelay()
    false

  proc main() {.exportc, cdecl.} =
    systemInit()

    enablePeriphClock(periphUart0)
    setMcuXclkSource(mcuXclkXtal)
    setUartClock(true, uartClkXclk, 0)
    gpioSetupUart(14, 15)
    console = initUart(uart0, UartConfig(
      baudRate: ConsoleBaud, dataBits: data8,
      stopBits: stop1, parity: parityNone,
    ), ConsoleClkHz)

    line("")
    line("=== BL808 All-Core Core ID Probe ===")

    clearProbeState()
    writeSelf(M0MagicAddr, M0CoreIdAddr, M0HartIdAddr, M0Magic)

    mmPowerOn()
    when defined(bl808jtagram):
      releaseLP()
      releaseD0(forceLoad = false)
      line("[diag] Switching JTAG mux to D0")
      switchJtagMuxToD0()
      line("[diag] JTAG mux switched to D0")
      waitForJtagD0RunMagic()
    else:
      releaseD0()
      releaseLP()

    let d0Seen = waitForPeer(D0MagicAddr, D0Magic)
    let lpSeen = waitForPeer(LpMagicAddr, LpMagic)

    printHex("m0_core_id=", sharedRead32(M0CoreIdAddr))
    printHex("m0_mhartid=", sharedRead32(M0HartIdAddr))
    printHex("d0_magic=", sharedRead32(D0MagicAddr))
    printHex("d0_core_id=", sharedRead32(D0CoreIdAddr))
    printHex("d0_mhartid=", sharedRead32(D0HartIdAddr))
    printHex("lp_magic=", sharedRead32(LpMagicAddr))
    printHex("lp_core_id=", sharedRead32(LpCoreIdAddr))
    printHex("lp_mhartid=", sharedRead32(LpHartIdAddr))

    let ok = d0Seen and lpSeen and
      sharedRead32(M0CoreIdAddr) == CoreIdM0 and
      sharedRead32(D0CoreIdAddr) == CoreIdD0 and
      sharedRead32(LpCoreIdAddr) == CoreIdLP
    if ok:
      for _ in 0 ..< 3:
        line("CORE_ID_M0_E9070000")
        line("CORE_ID_D0_DEAD5500")
        line("CORE_ID_LP_DEADE902")
        line("CORE_IDS_OK")
      line("[OK] all core IDs matched")
    else:
      line("[FAIL] all core IDs did not match")

    while true:
      wfi()

elif defined(bl808d0):
  proc main() {.exportc, cdecl.} =
    systemInit()
    writeSelf(D0MagicAddr, D0CoreIdAddr, D0HartIdAddr, D0Magic)
    while true:
      wfi()

elif defined(bl808lp):
  proc main() {.exportc, cdecl.} =
    systemInit()
    writeSelf(LpMagicAddr, LpCoreIdAddr, LpHartIdAddr, LpMagic)
    while true:
      wfi()
