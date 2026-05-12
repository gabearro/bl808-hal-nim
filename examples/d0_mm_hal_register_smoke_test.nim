## D0 register-level smoke test for MM-domain HAL modules.
##
## The M0 helper releases D0 and reports these XRAM status bits over UART.

import bl808/startup
import bl808/core
import bl808/mmio, bl808/memmap
import bl808/dbi, bl808/dvp, bl808/glb, bl808/h264, bl808/irq, bl808/mjpeg, bl808/npu, bl808/osd

const
  StatusAddr = XramBase + 0x3E00'u
  FailCodeAddr = XramBase + 0x3E04'u
  FailGotAddr = XramBase + 0x3E08'u
  FailExpectedAddr = XramBase + 0x3E0C'u
  StatusStarted = 1'u32 shl 0
  StatusDbi = 1'u32 shl 1
  StatusDvp = 1'u32 shl 2
  StatusOsd = 1'u32 shl 3
  StatusH264 = 1'u32 shl 4
  StatusMjpeg = 1'u32 shl 5
  StatusNpu = 1'u32 shl 6
  StatusFailed = 1'u32 shl 30
  StatusDone = 1'u32 shl 31
  ScratchBase = 0x3EFC_0000'u32

proc setStatus(mask: uint32) =
  regSet(StatusAddr, mask)
  fenceIo()

proc fail() =
  setStatus(StatusFailed)

proc failDetail(code, got, expected: uint32) =
  if regRead(FailCodeAddr) == 0:
    regWrite(FailCodeAddr, code)
    regWrite(FailGotAddr, got)
    regWrite(FailExpectedAddr, expected)
    fenceIo()
  fail()

proc check(code: uint32, ok: bool) =
  if not ok:
    failDetail(code, 0, 1)

proc checkEq(code, got, expected: uint32) =
  if got != expected:
    failDetail(code, got, expected)

proc smokeDbi() =
  let before = regRead(StatusAddr)
  let display = dbi.initDbi(dbi.dbiSpi4Wire, dbi.dbiRgb666, clockDiv = 9)
  let cfg = regRead(dbi.DbiConfig)
  check(0xDB10'u32, (cfg and dbi.DbiTypeSelectMask) != 0 and
                    (cfg and dbi.DbiTc3WireModeMask) == 0)
  checkEq(0xDB11'u32, regRead(dbi.DbiPixCnt) and dbi.DbiPixFormatMask,
          dbi.DbiPixFormatMask)
  checkEq(0xDB12'u32, regRead(dbi.DbiPrd), 9)
  display.dbiWriteCmd(0x2A)
  checkEq(0xDB13'u32, (regRead(dbi.DbiConfig) and dbi.DbiCmdMask) shr dbi.DbiCmdShift, 0x2A)
  display.dbiWriteData(0x12)
  checkEq(0xDB15'u32, regRead(dbi.DbiWdata), 0x12)
  display.dbiWriteData16(0x3456)
  checkEq(0xDB16'u32, regRead(dbi.DbiWdata), 0x3456)
  display.dbiSetWindow(1, 2, 3, 4)
  checkEq(0xDB17'u32, (regRead(dbi.DbiConfig) and dbi.DbiCmdMask) shr dbi.DbiCmdShift, 0x2C)
  display.dbiWritePixels([0x1234'u16, 0x5678'u16])
  checkEq(0xDB18'u32, regRead(dbi.DbiFifoWdata), 0x5678)
  checkEq(0xDB14'u32, display.dbiFifoAddr().uint32, dbi.DbiFifoWdata.uint32)
  if (regRead(StatusAddr) and StatusFailed) == (before and StatusFailed):
    setStatus(StatusDbi)

proc smokeDvp() =
  let before = regRead(StatusAddr)
  let cam = dvp.initDvp(0, 0x3EF8_0000'u32, 4096)
  checkEq(0xD010'u32, regRead(Dvp0Base + dvp.Dvp2axiAddrStart), 0x3EF8_0000'u32)
  checkEq(0xD011'u32, (regRead(Dvp0Base + dvp.Dvp2axiConfigure) and dvp.DvpXlenMask) shr dvp.DvpXlenShift,
          dvp.dvpBurst8.uint32)
  cam.setCrop(2, 10, 3, 11)
  checkEq(0xD012'u32, regRead(Dvp0Base + dvp.Dvp2axiHsyncCrop), 0x0002_000A'u32)
  cam.setFrameSize(320, 240)
  checkEq(0xD013'u32, regRead(Dvp0Base + dvp.Dvp2axiFramExm), 0x00F0_0140'u32)
  cam.setFramePeriod(7)
  checkEq(0xD014'u32, regRead(Dvp0Base + dvp.Dvp2axiFramePeriod) and dvp.DvpFramePeriodMask, 7)
  cam.setFrameBuffer(0x3EF8_1000'u32)
  checkEq(0xD016'u32, regRead(Dvp0Base + dvp.Dvp2axiAddrStart), 0x3EF8_1000'u32)
  cam.setFrameStartAddr(2, 0x3EF8_2000'u32)
  let frameStart2 = regRead(Dvp0Base + dvp.Dvp2axiFrameStartAddr2)
  check(0xD017'u32, frameStart2 == 0x3EF8_2000'u32 or frameStart2 == 0)
  discard cam.getFrameByteCount()
  discard cam.frameDone()
  cam.clearFrameDone()
  cam.fifoPopFrame()
  cam.setFlip(horizontal = true, vertical = true)
  cam.setAlpha(0x7F)
  checkEq(0xD018'u32, regRead(Dvp0Base + dvp.Dvp2axiMisc) and dvp.DvpAlphaMask, 0x7F)
  cam.enableInterrupt(dvp.DvpIntFrameEn)
  check(0xD015'u32, (regRead(Dvp0Base + dvp.DvpStatusAndError) and (1'u32 shl dvp.DvpIntFrameEn)) != 0)
  cam.disableInterrupt(dvp.DvpIntFrameEn)
  cam.clearInterrupt(dvp.DvpIntFrameClr)
  cam.disable()
  if (regRead(StatusAddr) and StatusFailed) == (before and StatusFailed):
    setStatus(StatusDvp)

proc smokeOsd() =
  let before = regRead(StatusAddr)
  osd.osdConfigureLayer(osd.osdLayerA, 64, 32, 5, 6, ScratchBase + 0x6000'u32, osd.osdRgb565, 0x80)
  checkEq(0x0A10'u32, regRead(OsdABase + osd.OsdLayerXConfig), 0x0044_0005'u32)
  checkEq(0x0A11'u32, (regRead(OsdABase + osd.OsdLayerConfig0) and osd.OsdGlobalAlphaMask) shr
          osd.OsdGlobalAlphaShift, 0x80)
  osd.osdSetColorKey(osd.osdLayerA, 0x00FF_00FF'u32)
  check(0x0A12'u32, (regRead(OsdABase + osd.OsdLayerConfig6) and (1'u32 shl osd.OsdKeyColorEn)) != 0)
  osd.osdSetAlpha(osd.osdLayerA, 0x55)
  checkEq(0x0A14'u32, (regRead(OsdABase + osd.OsdLayerConfig0) and osd.OsdGlobalAlphaMask) shr
          osd.OsdGlobalAlphaShift, 0x55)
  osd.osdSetPosition(osd.osdLayerA, 7, 8)
  checkEq(0x0A15'u32, regRead(OsdABase + osd.OsdLayerXConfig), 0x0046_0007'u32)
  osd.osdDisableLayer(osd.osdLayerA)
  check(0x0A16'u32, (regRead(OsdABase + osd.OsdMemConfig0) and osd.OsdLayerEnMask) == 0)
  osd.osdEnableLayer(osd.osdLayerA)
  osd.osdDpInit(64, 32, 0x0000_0011'u32)
  checkEq(0x0A13'u32, regRead(osd.OsdDpBgColor), 0x0000_0011'u32)
  if (regRead(StatusAddr) and StatusFailed) == (before and StatusFailed):
    setStatus(StatusOsd)

proc smokeH264() =
  let before = regRead(StatusAddr)
  h264.h264Init(64, 32, qp = 20, gopSize = 15,
    srcYAddr = ScratchBase + 0x0000'u32, srcUvAddr = ScratchBase + 0x1000'u32,
    dstAddr = ScratchBase + 0x2000'u32, dstBufSize = 4096,
    refAddr = ScratchBase + 0x3000'u32, reconAddr = ScratchBase + 0x4000'u32)
  checkEq(0xA410'u32, regRead(h264.H264FrameSize), 0x0020_0040'u32)
  checkEq(0xA411'u32, regRead(h264.H264Qp), 20)
  h264.h264Start(h264.h264IOnly)
  check(0xA412'u32, (regRead(h264.H264Ctrl) and (1'u32 shl h264.H264En)) != 0)
  h264.h264ForceIFrame()
  check(0xA413'u32, (regRead(h264.H264Ctrl) and (1'u32 shl h264.H264ForceI)) != 0)
  let encErr = h264.h264EncodeFrame()
  check(0xA414'u32, encErr == h264.h264Ok or encErr == h264.h264Timeout)
  discard h264.h264GetBitstreamSize()
  discard h264.h264GetFrameCount()
  h264.h264Stop()
  if (regRead(StatusAddr) and StatusFailed) == (before and StatusFailed):
    setStatus(StatusH264)

proc smokeMjpeg() =
  let before = regRead(StatusAddr)
  mjpeg.mjpegInit(64, 32, quality = 55,
    yAddr = ScratchBase + 0x0000'u32, uvAddr = ScratchBase + 0x1000'u32,
    dstAddr = ScratchBase + 0x2000'u32, dstBufSize = 4096)
  checkEq(0xCA10'u32, regRead(mjpeg.MjpegFrameSize), 0x0002_0004'u32)
  checkEq(0xCA11'u32, regRead(mjpeg.MjpegDstBufSize), 32)
  mjpeg.mjpegStart(mjpeg.mjpegSnapshot)
  check(0xCA12'u32, (regRead(mjpeg.MjpegControl) and (1'u32 shl mjpeg.MjpegEn)) != 0)
  mjpeg.mjpegTrigger()
  discard mjpeg.mjpegFrameDone()
  mjpeg.mjpegClearFrameDone()
  discard mjpeg.mjpegGetFrameSize()
  discard mjpeg.mjpegGetFrameCount()
  let waitErr = mjpeg.mjpegWaitFrame(timeout = 1)
  check(0xCA13'u32, waitErr == mjpeg.mjpegOk or waitErr == mjpeg.mjpegTimeout)
  let decErr = mjpeg.mjpegDecDecode(ScratchBase + 0x2000'u32, 16,
    ScratchBase + 0x5000'u32, ScratchBase + 0x6000'u32, 64)
  check(0xCA14'u32, decErr == mjpeg.mjpegOk or decErr == mjpeg.mjpegTimeout)
  discard mjpeg.mjpegDecGetFrameSize()
  mjpeg.mjpegStop()
  if (regRead(StatusAddr) and StatusFailed) == (before and StatusFailed):
    setStatus(StatusMjpeg)

proc smokeNpu() =
  let before = regRead(StatusAddr)
  npu.npuInit()
  let clk = regRead(npu.MmCnnClock)
  let sram = regRead(npu.MmVramCtrl)
  check(0xB110'u32, (clk and npu.CnnClkDivEnMask) != 0)
  check(0xB112'u32, (regRead(npu.MmCnnReset) and npu.CnnResetMask) == 0)
  check(0xB113'u32, (sram and npu.BlaiSramRelMask) != 0)
  check(0xB114'u32, (sram and npu.SysramSetMask) == 0)
  check(0xB115'u32, npu.npuClockEnabled())
  check(0xB116'u32, npu.npuSramReleased())
  npu.npuSetCodecQos()
  npu.npuSetBusLimiters(3, 4)
  npu.npuConfigureConvLayer(ScratchBase, ScratchBase + 0x1000'u32, ScratchBase + 0x2000'u32,
    ScratchBase + 0x3000'u32, 8, 8, 1, 1, 3, 3, 1, 1, 1, 1)
  checkEq(0xB117'u32, npu.npuRunLayer(timeout = 1).uint32, npu.npuUnsupported.uint32)
  check(0xB118'u32, not npu.npuIsBusy())
  if (regRead(StatusAddr) and StatusFailed) == (before and StatusFailed):
    setStatus(StatusNpu)

proc smokeMmGlb() =
  glb.setMmUart3Clock(true, 2)
  check(0x6100'u32, (regRead(glb.MmClkCtrlPeri) and (1'u32 shl glb.MmUart3ClkDivEn)) != 0)
  glb.setMmSpi1Clock(true, 3)
  check(0x6101'u32, (regRead(glb.MmClkCtrlPeri) and (1'u32 shl glb.MmSpi1ClkDivEn)) != 0)
  glb.setMmI2c2Clock(true, divider = 5)
  check(0x6102'u32, (regRead(glb.MmClkCtrlPeri) and (1'u32 shl glb.MmI2c2ClkEn)) != 0)
  glb.setMmI2c3Clock(true, divider = 6)
  check(0x6103'u32, (regRead(glb.MmClkCtrlPeri3) and (1'u32 shl glb.MmI2c3ClkEn)) != 0)
  glb.enableMmUart3Clock()
  glb.enableMmSpi1Clock()
  glb.enableMmI2c2Clock()
  glb.enableMmI2c3Clock()
  glb.enableMmPeriphClock(glb.MmResetDma2)
  glb.resetMmDma2()
  glb.resetMmI2c2()
  glb.resetMmI2c3()
  glb.resetMmSpi1()
  glb.resetMmTimer1()

proc smokeD0Irq() =
  plicInit()
  plicSetPriority(IrqD0Timer1Wdt, 1)
  plicSetThreshold(0)
  plicSetThresholdS(0)
  plicEnableIrq(IrqD0Timer1Wdt)
  plicEnableIrqS(IrqD0Timer1Wdt)
  discard plicClaim()
  discard plicClaimS()
  plicComplete(0)
  plicCompleteS(0)
  plicDisableIrq(IrqD0Timer1Wdt)

proc main() {.exportc, cdecl.} =
  systemInit()
  regWrite(FailCodeAddr, 0)
  regWrite(FailGotAddr, 0)
  regWrite(FailExpectedAddr, 0)
  setStatus(StatusStarted)

  smokeMmGlb()
  smokeD0Irq()
  smokeDbi()
  smokeDvp()
  smokeOsd()
  smokeH264()
  smokeMjpeg()
  smokeNpu()

  setStatus(StatusDone)
  while true:
    wfi()
