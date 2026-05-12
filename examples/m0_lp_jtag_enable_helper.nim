## M0 launcher for the LP JTAG mux experiment.
##
## Loaded over M0 JTAG. It stages diagnostics, releases LP at the JTAG RAM
## entry, and reports the LP-side register writes over UART0.

import bl808/startup
import bl808/core
import bl808/mmio, bl808/memmap
import bl808/glb, bl808/gpio, bl808/uart

const
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz {.intdefine.} = 40_000_000'u32

  DiagBase = XramBase + 0x2F80'u
  StatusAddr = DiagBase + 0x00'u
  StageAddr = DiagBase + 0x04'u
  ParmBeforeAddr = DiagBase + 0x08'u
  ParmAfterAddr = DiagBase + 0x0C'u
  TmsCfgAddr = DiagBase + 0x10'u
  TdoCfgAddr = DiagBase + 0x14'u
  TckCfgAddr = DiagBase + 0x18'u
  TdiCfgAddr = DiagBase + 0x1C'u
  HeartbeatAddr = DiagBase + 0x20'u
  ParmRequestedAddr = DiagBase + 0x24'u
  JtagPinsAddr = DiagBase + 0x28'u
  SecDbgStatusAddr = DiagBase + 0x2C'u
  EfCfg0Addr = DiagBase + 0x30'u

  StatusMagic = 0xE902_4A54'u32
  StageDone = 5'u32
  WaitLimit = 12_000

var console: Uart

proc printHex(label: string, value: uint32) =
  discard console.sendString(label)
  console.sendHex32(value)
  discard console.sendLine("")

proc sharedRead32(address: uint): uint32 =
  dcacheFlushAll()
  dcacheInvalidateAll()
  core.fence()
  regRead(address)

proc clearDiagnostics() =
  const addrs = [
    StatusAddr,
    StageAddr,
    ParmBeforeAddr,
    ParmAfterAddr,
    TmsCfgAddr,
    TdoCfgAddr,
    TckCfgAddr,
    TdiCfgAddr,
    HeartbeatAddr,
    ParmRequestedAddr,
    JtagPinsAddr,
    SecDbgStatusAddr,
    EfCfg0Addr,
  ]
  for address in addrs:
    regWrite(address, 0)
  dcacheFlushAll()
  fenceIo()

proc spinDelay() =
  for _ in 0 ..< 20_000:
    {.emit: """asm volatile("");""".}

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

  discard console.sendLine("")
  discard console.sendLine("=== BL808 LP JTAG Enable Helper (M0) ===")
  discard console.sendLine("[M0] Clearing LP diagnostics")
  clearDiagnostics()

  discard console.sendLine("[M0] Releasing LP JTAG helper")
  mmPowerOn()
  releaseLP()

  var ok = false
  for _ in 0 ..< WaitLimit:
    let status = sharedRead32(StatusAddr)
    let stage = sharedRead32(StageAddr)
    if status == StatusMagic and stage >= StageDone:
      ok = true
      break
    spinDelay()

  printHex("  lp_status=", sharedRead32(StatusAddr))
  printHex("  lp_stage=", sharedRead32(StageAddr))
  printHex("  lp_parm_before=", sharedRead32(ParmBeforeAddr))
  printHex("  lp_parm_requested=", sharedRead32(ParmRequestedAddr))
  printHex("  lp_parm_after=", sharedRead32(ParmAfterAddr))
  printHex("  lp_jtag_pins=", sharedRead32(JtagPinsAddr))
  printHex("  tms_cfg=", sharedRead32(TmsCfgAddr))
  printHex("  tdo_cfg=", sharedRead32(TdoCfgAddr))
  printHex("  tck_cfg=", sharedRead32(TckCfgAddr))
  printHex("  tdi_cfg=", sharedRead32(TdiCfgAddr))
  printHex("  sec_dbg_status=", sharedRead32(SecDbgStatusAddr))
  printHex("  ef_cfg0=", sharedRead32(EfCfg0Addr))
  printHex("  lp_heartbeat=", sharedRead32(HeartbeatAddr))

  if ok:
    discard console.sendLine("[OK] LP JTAG helper ran")
    discard console.sendLine("[M0] LP pads are now configured for LP JTAG")
  else:
    discard console.sendLine("[FAIL] LP JTAG helper did not finish")

  while true:
    wfi()
