## LP-side JTAG mux experiment.
##
## This program is loaded into LP WRAM by the hardware validation harness. It
## proves the E902 executed by writing XRAM diagnostics, then programs the
## reversible GLB/GPIO state that should expose the LP JTAG function.

import bl808/startup
import bl808/core
import bl808/mmio, bl808/memmap

const
  JtagTmsPin {.intdefine.} = 6
  JtagTdoPin {.intdefine.} = 7
  JtagTckPin {.intdefine.} = 12
  JtagTdiPin {.intdefine.} = 13
  LpJtagUseIo2To5 {.intdefine.} = 0
  LpKeepM0JtagPins {.intdefine.} = 0
  LpCjtagPullUpProbe {.intdefine.} = 0

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

  StatusMagic = 0xE902_4A54'u32 # "E902 JT"
  StageStarted = 1'u32
  StageDebugClocks = 2'u32
  StageParmCfg = 3'u32
  StageGpioCfg = 4'u32
  StageDone = 5'u32

  GlbCgenCfg0 = GlbBase + 0x580'u
  GlbCgenCfg1 = GlbBase + 0x584'u
  GlbCgenCfg2 = GlbBase + 0x588'u
  GlbParmCfg0 = GlbBase + 0x510'u
  GlbSwrstCfg2 = GlbBase + 0x548'u
  GlbDbgCfg0 = GlbBase + 0x2E0'u
  GlbDbgCfg1 = GlbBase + 0x2E4'u
  GlbDbgCfg2 = GlbBase + 0x2E8'u
  GlbDbgCfg3 = GlbBase + 0x2EC'u
  GlbDbgCfg4 = GlbBase + 0x2F0'u
  GpioConfigBase = GlbBase + 0x8C4'u
  PdsCpuCoreCfg0 = PdsBase + 0x110'u
  PdsCpuCoreCfg7 = PdsBase + 0x12C'u
  PdsCpuCoreCfg8 = PdsBase + 0x130'u
  PdsCpuCoreCfg13 = PdsBase + 0x144'u

  WlJtgChainProbe = 1'u32 shl 6
  E902JtagSelProbe = 1'u32 shl 7
  P4AdcTestWithJtag = 1'u32 shl 20
  P5DacTestWithJtag = 1'u32 shl 21
  P7JtagUseIo2To5 = 1'u32 shl 23

  GpioFuncJtagLp = 25'u32
  GpioFuncGpio = 11'u32
  GpioJtagLp =
    (GpioFuncJtagLp shl 8) or
    (1'u32 shl 22) or
    (1'u32 shl 1) or
    1'u32
  GpioInputPullUp =
    (GpioFuncGpio shl 8) or
    (1'u32 shl 22) or
    (1'u32 shl 4) or
    (1'u32 shl 1) or
    1'u32

proc mark(stage: uint32) =
  regWrite(StageAddr, stage)
  fenceIo()

proc configureDebugClocks() =
  regSet(GlbCgenCfg0, 1'u32 shl 2)
  regSet(GlbCgenCfg1, (1'u32 shl 3) or (1'u32 shl 4))
  fenceIo()

proc configureLpJtagRoute() =
  let before = regRead(GlbParmCfg0)
  regWrite(ParmBeforeAddr, before)

  var after = before
  # Bits 6 and 7 are BL616D JTAG route controls, not named in BL808's SDK.
  # Keep probing them, but record requested vs readback because BL808 may
  # ignore them.
  after = after or E902JtagSelProbe
  after = after and not WlJtgChainProbe
  after = after and not P4AdcTestWithJtag
  after = after and not P5DacTestWithJtag
  if LpJtagUseIo2To5 != 0:
    after = after or P7JtagUseIo2To5
  else:
    after = after and not P7JtagUseIo2To5

  regWrite(ParmRequestedAddr, after)
  regWrite(GlbParmCfg0, after)
  fenceIo()
  regWrite(ParmAfterAddr, regRead(GlbParmCfg0))

proc configurePadsForLpJtag() =
  when LpKeepM0JtagPins == 0:
    let pins = [
      JtagTmsPin.uint,
      JtagTdoPin.uint,
      JtagTckPin.uint,
      JtagTdiPin.uint,
    ]
    for pin in pins:
      regWrite(GpioConfigBase + pin * 4'u, GpioJtagLp)
  fenceIo()
  regWrite(TmsCfgAddr, regRead(GpioConfigBase + JtagTmsPin.uint * 4'u))
  regWrite(TdoCfgAddr, regRead(GpioConfigBase + JtagTdoPin.uint * 4'u))
  regWrite(TckCfgAddr, regRead(GpioConfigBase + JtagTckPin.uint * 4'u))
  regWrite(TdiCfgAddr, regRead(GpioConfigBase + JtagTdiPin.uint * 4'u))
  regWrite(JtagPinsAddr,
    JtagTmsPin.uint32 or
    (JtagTdoPin.uint32 shl 8) or
    (JtagTckPin.uint32 shl 16) or
    (JtagTdiPin.uint32 shl 24))

proc configureCjtagPullUps() =
  when LpCjtagPullUpProbe != 0:
    regWrite(GpioConfigBase + 27'u * 4'u, GpioInputPullUp)
    regWrite(GpioConfigBase + 28'u * 4'u, GpioInputPullUp)
    fenceIo()

proc recordDebugSecurityState() =
  regWrite(SecDbgStatusAddr, regRead(SecDbgBase + 0x18'u))
  regWrite(EfCfg0Addr, regRead(EfCtrlBase))

proc recordDebugState() =
  regWrite(Cgen0Addr, regRead(GlbCgenCfg0))
  regWrite(Cgen1Addr, regRead(GlbCgenCfg1))
  regWrite(Cgen2Addr, regRead(GlbCgenCfg2))
  regWrite(SwrstCfg2Addr, regRead(GlbSwrstCfg2))
  regWrite(PdsCfg0Addr, regRead(PdsCpuCoreCfg0))
  regWrite(PdsCfg7Addr, regRead(PdsCpuCoreCfg7))
  regWrite(PdsCfg8Addr, regRead(PdsCpuCoreCfg8))
  regWrite(PdsCfg13Addr, regRead(PdsCpuCoreCfg13))
  regWrite(GlbDbgCfg0Addr, regRead(GlbDbgCfg0))
  regWrite(GlbDbgCfg1Addr, regRead(GlbDbgCfg1))
  regWrite(GlbDbgCfg2Addr, regRead(GlbDbgCfg2))
  regWrite(GlbDbgCfg3Addr, regRead(GlbDbgCfg3))
  regWrite(GlbDbgCfg4Addr, regRead(GlbDbgCfg4))
  regWrite(CoreIdDiagAddr, regRead(CoreIdAddr))
  regWrite(MhartidAddr, csrReadMhartid().uint32)
  regWrite(Gpio2CfgAddr, regRead(GpioConfigBase + 2'u * 4'u))
  regWrite(Gpio3CfgAddr, regRead(GpioConfigBase + 3'u * 4'u))
  regWrite(Gpio4CfgAddr, regRead(GpioConfigBase + 4'u * 4'u))
  regWrite(Gpio5CfgAddr, regRead(GpioConfigBase + 5'u * 4'u))
  regWrite(Gpio6CfgAddr, regRead(GpioConfigBase + 6'u * 4'u))
  regWrite(Gpio7CfgAddr, regRead(GpioConfigBase + 7'u * 4'u))
  regWrite(Gpio12CfgAddr, regRead(GpioConfigBase + 12'u * 4'u))
  regWrite(Gpio13CfgAddr, regRead(GpioConfigBase + 13'u * 4'u))
  regWrite(Gpio27CfgAddr, regRead(GpioConfigBase + 27'u * 4'u))
  regWrite(Gpio28CfgAddr, regRead(GpioConfigBase + 28'u * 4'u))

proc pinLevel(pin: uint): uint32 =
  (regRead(GpioConfigBase + pin * 4'u) shr 28) and 1'u32

proc packedJtagPinLevels(): uint32 =
  pinLevel(JtagTmsPin.uint) or
    (pinLevel(JtagTdoPin.uint) shl 8) or
    (pinLevel(JtagTckPin.uint) shl 16) or
    (pinLevel(JtagTdiPin.uint) shl 24)

proc packedCjtagPinLevels(): uint32 =
  pinLevel(27'u) or (pinLevel(28'u) shl 8)

proc sampleJtagPins(iterations: uint32) =
  var prev = packedJtagPinLevels()
  var prevCjtag = packedCjtagPinLevels()
  var tmsEdges = regRead(TmsEdgesAddr)
  var tdoEdges = regRead(TdoEdgesAddr)
  var tckEdges = regRead(TckEdgesAddr)
  var tdiEdges = regRead(TdiEdgesAddr)
  var gpio27Edges = regRead(Gpio27EdgesAddr)
  var gpio28Edges = regRead(Gpio28EdgesAddr)

  if regRead(PadInitialAddr) == 0:
    regWrite(PadInitialAddr, prev)
  if regRead(CjtagInitialAddr) == 0:
    regWrite(CjtagInitialAddr, prevCjtag)
  regWrite(PadLastAddr, prev)
  regWrite(CjtagLastAddr, prevCjtag)

  for i in 0'u32 ..< iterations:
    let cur = packedJtagPinLevels()
    let curCjtag = packedCjtagPinLevels()
    let diff = cur xor prev
    let diffCjtag = curCjtag xor prevCjtag
    if (diff and 0x00000001'u32) != 0:
      tmsEdges += 1'u32
    if (diff and 0x00000100'u32) != 0:
      tdoEdges += 1'u32
    if (diff and 0x00010000'u32) != 0:
      tckEdges += 1'u32
    if (diff and 0x01000000'u32) != 0:
      tdiEdges += 1'u32
    if (diffCjtag and 0x00000001'u32) != 0:
      gpio27Edges += 1'u32
    if (diffCjtag and 0x00000100'u32) != 0:
      gpio28Edges += 1'u32
    prev = cur
    prevCjtag = curCjtag

    if (i and 0x3F'u32) == 0:
      regWrite(PadLastAddr, cur)
      regWrite(CjtagLastAddr, curCjtag)
      regWrite(TmsEdgesAddr, tmsEdges)
      regWrite(TdoEdgesAddr, tdoEdges)
      regWrite(TckEdgesAddr, tckEdges)
      regWrite(TdiEdgesAddr, tdiEdges)
      regWrite(Gpio27EdgesAddr, gpio27Edges)
      regWrite(Gpio28EdgesAddr, gpio28Edges)
      fenceIo()

  regWrite(PadLastAddr, prev)
  regWrite(CjtagLastAddr, prevCjtag)
  regWrite(TmsEdgesAddr, tmsEdges)
  regWrite(TdoEdgesAddr, tdoEdges)
  regWrite(TckEdgesAddr, tckEdges)
  regWrite(TdiEdgesAddr, tdiEdges)
  regWrite(Gpio27EdgesAddr, gpio27Edges)
  regWrite(Gpio28EdgesAddr, gpio28Edges)
  fenceIo()

proc main() {.exportc, cdecl.} =
  systemInit()

  regWrite(StatusAddr, StatusMagic)
  mark(StageStarted)

  configureDebugClocks()
  mark(StageDebugClocks)

  configureLpJtagRoute()
  mark(StageParmCfg)

  recordDebugSecurityState()
  configurePadsForLpJtag()
  configureCjtagPullUps()
  recordDebugState()
  mark(StageGpioCfg)

  mark(StageDone)
  var heartbeat = 0'u32
  while true:
    heartbeat += 1'u32
    regWrite(HeartbeatAddr, heartbeat)
    recordDebugSecurityState()
    recordDebugState()
    sampleJtagPins(4096)
    fenceIo()
    for _ in 0 ..< 1_000:
      {.emit: """asm volatile("");""".}
