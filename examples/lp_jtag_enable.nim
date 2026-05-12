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

  StatusMagic = 0xE902_4A54'u32 # "E902 JT"
  StageStarted = 1'u32
  StageDebugClocks = 2'u32
  StageParmCfg = 3'u32
  StageGpioCfg = 4'u32
  StageDone = 5'u32

  GlbCgenCfg0 = GlbBase + 0x580'u
  GlbCgenCfg1 = GlbBase + 0x584'u
  GlbParmCfg0 = GlbBase + 0x510'u
  GpioConfigBase = GlbBase + 0x8C4'u

  WlJtgChainProbe = 1'u32 shl 6
  E902JtagSelProbe = 1'u32 shl 7
  P4AdcTestWithJtag = 1'u32 shl 20
  P5DacTestWithJtag = 1'u32 shl 21
  P7JtagUseIo2To5 = 1'u32 shl 23

  GpioFuncJtagLp = 25'u32
  GpioJtagLp =
    (GpioFuncJtagLp shl 8) or
    (1'u32 shl 22) or
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

proc recordDebugSecurityState() =
  regWrite(SecDbgStatusAddr, regRead(SecDbgBase + 0x18'u))
  regWrite(EfCfg0Addr, regRead(EfCtrlBase))

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
  mark(StageGpioCfg)

  mark(StageDone)
  var heartbeat = 0'u32
  while true:
    heartbeat += 1'u32
    regWrite(HeartbeatAddr, heartbeat)
    fenceIo()
    for _ in 0 ..< 10_000:
      {.emit: """asm volatile("");""".}
