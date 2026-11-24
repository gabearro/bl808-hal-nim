proc wifiRfCoreInitMode(xtalfreqHz: uint32, mode: RadioPhyMode) {.noinline.} =
  let apiMode = apiFromRadioPhyMode(mode)
  nimFwDbgRfPhase = 1
  nimFwDbgRfApiMode = apiMode.uint32
  nimFwConnectTrace2U32("[WIFI-CT] bl808_rf_core ", xtalfreqHz, apiMode.uint32)
  rfPriLoadConfiguredDeviceInfo()
  let cfg = wl_cfg_get(addr wifiBl808WlRmem)
  nimFwDbgRfPhase = 2
  nimFwConnectTrace2U32("[WIFI-CT] bl808_rf_cfg ", cast[uint32](cast[uint](cfg)), sizeof(WlRfConfig).uint32)
  if cfg != nil:
    let requestFullCalibration =
      if wifiBl808RfInited == 0'u32: 1'u8 else: 0'u8
    configureWlRfConfig(cfg, xtalfreqHz, mode, requestFullCalibration)
    nimFwConnectTrace2U32("[WIFI-CT] bl808_rf_cfg2 ", cfg.status, cfg.xtalfreqHz)
  nimFwDbgRfPhase = 3
  snapshotWifiRfCalibData()
  let restoreExistingCalibration =
    if wifiBl808RfInited == 0'u32: 0'u32 else: 1'u32
  nimFwDbgRfRestore = restoreExistingCalibration
  nimFwConnectTrace2U32(
    "[WIFI-CT] bl808_rf_modem ", xtalfreqHz, restoreExistingCalibration)
  nimFwDbgRfPhase = 4
  let initialized = wlInitModemAndPublish(true)
  snapshotWifiRfCalibData()
  if not initialized or not wlRfConfigInitialized():
    wifiBl808RfInited = 0'u32
    return
  nimFwDbgRfPhase = 5
  wifiBl808RfInited = 1'u32
  nimFwConnectTrace2U32(
    "[WIFI-CT] bl808_rf_done ", xtalfreqHz, restoreExistingCalibration)

proc wifiRfCoreInit*(xtalfreqHz: uint32) {.exportc, cdecl, noinline.} =
  wifiRfCoreInitMode(xtalfreqHz, wifiOnly)

proc wifiRfCoreReady*(): bool {.inline.} =
  wifiBl808RfInited != 0'u32 and wlRfConfigInitialized()

proc wifiRfCoreUsesNativeWlan*(): bool {.inline.} =
  when defined(bl808WifiNativeWlanCalibration):
    rfBankHasBl808WlanCal()
  else:
    false

proc phy_assert_rec*(fileOrCond, condOrFile: cstring, line: cint)
    {.exportc, cdecl, noinline.} =
  ## librf_bl808.a:arch.c.o phy_assert_rec is ret-only.
  discard fileOrCond
  discard condOrFile
  discard line

proc phy_assert_warn*(fileOrCond, condOrFile: cstring, line: cint)
    {.exportc, cdecl, noinline.} =
  ## librf_bl808.a:arch.c.o phy_assert_warn is ret-only.
  discard fileOrCond
  discard condOrFile
  discard line

proc phy_assert_err*(fileOrCond, condOrFile: cstring, line: cint)
    {.exportc, cdecl, noinline.} =
  ## arch.c.o phy_assert_err hard-spins. Keep the direct ABI symbol but route
  ## through the existing BL808 wrapper so known PHY clock diagnostics remain
  ## observable instead of blind hangs.
  wrapPhyAssertErr(fileOrCond, condOrFile, line)

proc wrapPhyAssertErr*(fileOrCond, condOrFile: cstring,
                       line: cint)
    {.exportc: "__wrap_phy_assert_err", cdecl, noinline.} =
  ## Match the RF archive's hard stop by default. Opt in to continuing past
  ## known diagnostics only when bisecting bring-up on hardware.
  let mdm = wifiModemRegs()
  let versionScratch3c = volatileLoad(addr mdm.versionScratch3c)
  inc nimFwDbgRfAssertCount
  nimFwDbgRfAssertLine = line.uint32
  nimFwDbgRfAssertReg3c = versionScratch3c
  nimFwConnectTrace2U32("[WIFI-CT] phy_assert ", line.uint32, versionScratch3c)
  when defined(bl808WifiDebugContinuePhyAssert):
    if line == 586.cint or line == 0x20FA.cint or line == 0x2A60.cint:
      return
  while true:
    discard fileOrCond
    discard condOrFile
