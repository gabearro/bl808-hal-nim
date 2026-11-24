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
  GpioJtagM0 = 0x00401A03'u32

  M0DiagBase = XramBase + 0x2F60'u
  M0MagicAddr = M0DiagBase + 0x00'u
  M0StageAddr = M0DiagBase + 0x04'u
  M0CoreIdAddr = M0DiagBase + 0x08'u
  M0MhartidAddr = M0DiagBase + 0x0C'u
  M0LastLpStatusAddr = M0DiagBase + 0x10'u
  M0LastLpStageAddr = M0DiagBase + 0x14'u
  M0WaitLoopsAddr = M0DiagBase + 0x18'u
  M0TrapAddr = M0DiagBase + 0x1C'u

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
  Cgen0Addr = DiagBase + 0x34'u
  Cgen1Addr = DiagBase + 0x38'u
  Cgen2Addr = DiagBase + 0x3C'u
  SwrstCfg2Addr = DiagBase + 0x40'u
  PdsCfg0Addr = DiagBase + 0x44'u
  PdsCfg7Addr = DiagBase + 0x48'u
  PdsCfg8Addr = DiagBase + 0x4C'u
  PdsCfg13Addr = DiagBase + 0x50'u
  GlbDbgCfg0Addr = DiagBase + 0x54'u
  GlbDbgCfg1Addr = DiagBase + 0x58'u
  GlbDbgCfg2Addr = DiagBase + 0x5C'u
  GlbDbgCfg3Addr = DiagBase + 0x60'u
  GlbDbgCfg4Addr = DiagBase + 0x64'u
  CoreIdDiagAddr = DiagBase + 0x68'u
  MhartidAddr = DiagBase + 0x6C'u
  PadInitialAddr = DiagBase + 0x70'u
  PadLastAddr = DiagBase + 0x74'u
  TmsEdgesAddr = DiagBase + 0x78'u
  TdoEdgesAddr = DiagBase + 0x7C'u
  TckEdgesAddr = DiagBase + 0x80'u
  TdiEdgesAddr = DiagBase + 0x84'u
  Gpio2CfgAddr = DiagBase + 0x88'u
  Gpio3CfgAddr = DiagBase + 0x8C'u
  Gpio4CfgAddr = DiagBase + 0x90'u
  Gpio5CfgAddr = DiagBase + 0x94'u
  Gpio6CfgAddr = DiagBase + 0x98'u
  Gpio7CfgAddr = DiagBase + 0x9C'u
  Gpio12CfgAddr = DiagBase + 0xA0'u
  Gpio13CfgAddr = DiagBase + 0xA4'u
  Gpio27CfgAddr = DiagBase + 0xA8'u
  Gpio28CfgAddr = DiagBase + 0xAC'u
  CjtagInitialAddr = DiagBase + 0xB0'u
  CjtagLastAddr = DiagBase + 0xB4'u
  Gpio27EdgesAddr = DiagBase + 0xB8'u
  Gpio28EdgesAddr = DiagBase + 0xBC'u
  DiagClearBytes = 0xC0'u

  M0StatusMagic = 0xE907_4A54'u32
  StatusMagic = 0xE902_4A54'u32
  StageDone = 5'u32
  WaitLimit = 12_000

var console: Uart

proc markM0(stage: uint32) =
  regWrite(M0MagicAddr, M0StatusMagic)
  regWrite(M0StageAddr, stage)
  fenceIo()

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
  var offset = 0'u
  while offset < DiagClearBytes:
    regWrite(DiagBase + offset, 0)
    offset += 4'u
  regWrite(M0LastLpStatusAddr, 0)
  regWrite(M0LastLpStageAddr, 0)
  regWrite(M0WaitLoopsAddr, 0)
  regWrite(M0TrapAddr, 0)
  dcacheFlushAll()
  fenceIo()

proc spinDelay() =
  for _ in 0 ..< 20_000:
    {.emit: """asm volatile("");""".}

proc printDiagnostics() =
  printHex("  m0_status=", sharedRead32(M0MagicAddr))
  printHex("  m0_stage=", sharedRead32(M0StageAddr))
  printHex("  m0_core_id=", sharedRead32(M0CoreIdAddr))
  printHex("  m0_mhartid=", sharedRead32(M0MhartidAddr))
  printHex("  m0_last_lp_status=", sharedRead32(M0LastLpStatusAddr))
  printHex("  m0_last_lp_stage=", sharedRead32(M0LastLpStageAddr))
  printHex("  m0_wait_loops=", sharedRead32(M0WaitLoopsAddr))
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
  printHex("  glb_cgen_cfg0=", sharedRead32(Cgen0Addr))
  printHex("  glb_cgen_cfg1=", sharedRead32(Cgen1Addr))
  printHex("  glb_cgen_cfg2=", sharedRead32(Cgen2Addr))
  printHex("  glb_swrst_cfg2=", sharedRead32(SwrstCfg2Addr))
  printHex("  pds_cpu_core_cfg0=", sharedRead32(PdsCfg0Addr))
  printHex("  pds_cpu_core_cfg7=", sharedRead32(PdsCfg7Addr))
  printHex("  pds_cpu_core_cfg8=", sharedRead32(PdsCfg8Addr))
  printHex("  pds_cpu_core_cfg13=", sharedRead32(PdsCfg13Addr))
  printHex("  glb_dbg_cfg0=", sharedRead32(GlbDbgCfg0Addr))
  printHex("  glb_dbg_cfg1=", sharedRead32(GlbDbgCfg1Addr))
  printHex("  glb_dbg_cfg2=", sharedRead32(GlbDbgCfg2Addr))
  printHex("  glb_dbg_cfg3=", sharedRead32(GlbDbgCfg3Addr))
  printHex("  glb_dbg_cfg4=", sharedRead32(GlbDbgCfg4Addr))
  printHex("  lp_core_id=", sharedRead32(CoreIdDiagAddr))
  printHex("  lp_mhartid=", sharedRead32(MhartidAddr))
  printHex("  pad_initial=", sharedRead32(PadInitialAddr))
  printHex("  pad_last=", sharedRead32(PadLastAddr))
  printHex("  tms_edges=", sharedRead32(TmsEdgesAddr))
  printHex("  tdo_edges=", sharedRead32(TdoEdgesAddr))
  printHex("  tck_edges=", sharedRead32(TckEdgesAddr))
  printHex("  tdi_edges=", sharedRead32(TdiEdgesAddr))
  printHex("  cjtag_initial=", sharedRead32(CjtagInitialAddr))
  printHex("  cjtag_last=", sharedRead32(CjtagLastAddr))
  printHex("  gpio27_edges=", sharedRead32(Gpio27EdgesAddr))
  printHex("  gpio28_edges=", sharedRead32(Gpio28EdgesAddr))
  printHex("  gpio2_cfg=", sharedRead32(Gpio2CfgAddr))
  printHex("  gpio3_cfg=", sharedRead32(Gpio3CfgAddr))
  printHex("  gpio4_cfg=", sharedRead32(Gpio4CfgAddr))
  printHex("  gpio5_cfg=", sharedRead32(Gpio5CfgAddr))
  printHex("  gpio6_cfg=", sharedRead32(Gpio6CfgAddr))
  printHex("  gpio7_cfg=", sharedRead32(Gpio7CfgAddr))
  printHex("  gpio12_cfg=", sharedRead32(Gpio12CfgAddr))
  printHex("  gpio13_cfg=", sharedRead32(Gpio13CfgAddr))
  printHex("  gpio27_cfg=", sharedRead32(Gpio27CfgAddr))
  printHex("  gpio28_cfg=", sharedRead32(Gpio28CfgAddr))
  printHex("  lp_heartbeat=", sharedRead32(HeartbeatAddr))

proc restoreM0JtagPads() =
  regWrite(GpioConfigBase + 6'u * 4'u, GpioJtagM0)
  regWrite(GpioConfigBase + 7'u * 4'u, GpioJtagM0)
  regWrite(GpioConfigBase + 12'u * 4'u, GpioJtagM0)
  regWrite(GpioConfigBase + 13'u * 4'u, GpioJtagM0)
  fenceIo()

proc main() {.exportc, cdecl.} =
  markM0(1)
  systemInit()
  markM0(2)
  regWrite(M0CoreIdAddr, regRead(CoreIdAddr))
  regWrite(M0MhartidAddr, csrReadMhartid().uint32)

  enablePeriphClock(periphUart0)
  setMcuXclkSource(mcuXclkXtal)
  setUartClock(true, uartClkXclk, 0)
  gpioSetupUart(14, 15)
  markM0(3)
  console = initUart(uart0, UartConfig(
    baudRate: ConsoleBaud, dataBits: data8,
    stopBits: stop1, parity: parityNone,
  ), ConsoleClkHz)
  markM0(4)

  discard console.sendLine("")
  discard console.sendLine("=== BL808 LP JTAG Enable Helper (M0) ===")
  discard console.sendLine("[M0] Clearing LP diagnostics")
  clearDiagnostics()
  markM0(5)

  discard console.sendLine("[M0] Releasing LP JTAG helper")
  delayMs(1000)
  mmPowerOn()
  markM0(6)
  releaseLP()
  markM0(7)

  var ok = false
  for i in 0 ..< WaitLimit:
    let status = sharedRead32(StatusAddr)
    let stage = sharedRead32(StageAddr)
    regWrite(M0LastLpStatusAddr, status)
    regWrite(M0LastLpStageAddr, stage)
    regWrite(M0WaitLoopsAddr, i.uint32 + 1'u32)
    fenceIo()
    if status == StatusMagic and stage >= StageDone:
      ok = true
      markM0(8)
      break
    spinDelay()

  if not ok:
    markM0(0x80'u32)

  printDiagnostics()

  if ok:
    discard console.sendLine("[OK] LP JTAG helper ran")
    discard console.sendLine("[M0] LP pads are now configured for LP JTAG")
  else:
    discard console.sendLine("[FAIL] LP JTAG helper did not finish")

  when defined(LpJtagActivityProbe):
    for _ in 0 ..< 3:
      discard console.sendLine("LP_ACTIVITY_WINDOW")
    discard console.sendLine("[M0] LP JTAG activity window start")
    when defined(LpJtagShortActivityProbe):
      const ActivitySeconds = 15
    elif defined(LpJtagVendorActivityProbe):
      const ActivitySeconds = 60
    else:
      const ActivitySeconds = 12
    for _ in 0 ..< ActivitySeconds:
      delayMs(1000)
      printHex("  activity_heartbeat=", sharedRead32(HeartbeatAddr))
      printHex("  activity_pad_last=", sharedRead32(PadLastAddr))
      printHex("  activity_tms_edges=", sharedRead32(TmsEdgesAddr))
      printHex("  activity_tdo_edges=", sharedRead32(TdoEdgesAddr))
      printHex("  activity_tck_edges=", sharedRead32(TckEdgesAddr))
      printHex("  activity_tdi_edges=", sharedRead32(TdiEdgesAddr))
      printHex("  activity_cjtag_last=", sharedRead32(CjtagLastAddr))
      printHex("  activity_gpio27_edges=", sharedRead32(Gpio27EdgesAddr))
      printHex("  activity_gpio28_edges=", sharedRead32(Gpio28EdgesAddr))
    when defined(LpJtagVendorActivityProbe):
      restoreM0JtagPads()
      markM0(9)
    discard console.sendLine("[M0] LP JTAG activity window end")
    printDiagnostics()
    discard console.sendLine("[OK] LP JTAG activity probe complete")

  while true:
    wfi()
