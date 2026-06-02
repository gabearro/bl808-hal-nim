## M0 BLE/WiFi HAL feature test.
##
## WiFi credentials are supplied by hardware validation with:
##   -d:WifiSsid=<ssid> -d:WifiPassword=<password>

import bl808/startup
import bl808/core
import bl808/irq
import bl808/glb, bl808/gpio, bl808/uart
import bl808/ble, bl808/wifi
import bl808/panicoverride
import bl808/kernel/alloc
import bl808/kernel/cps
from bl808/blecontroller import
  bleNimPeripheralDiscEventCount,
  bleNimPeripheralDiscReason,
  bleNimPeripheralDiscSource,
  bleNimDbgVendorLlcpRxCount,
  bleNimDbgVendorLlcpLastOpcode
when defined(BleDebugCounters):
  from bl808/blecontroller import
    bleNimDbgIsrCount, bleNimDbgStat8000Count, bleNimDbgPushCount,
    bleNimDbgRxReadyCount, bleNimDbgRxConnectIndCount,
    bleNimDbgVendorSchProgFifoCount, bleNimDbgVendorSchProgSkipCount,
    bleNimDbgVendorLlcpRxCount, bleNimDbgVendorLlcpTxCount,
    bleNimDbgVendorLlcpLastOpcode, bleNimDbgVendorLlcpLastStatus,
    bleNimDbgVendorConLastStatus,
    bleNimDbgVendorConLastAnchor, bleNimDbgVendorConLastInterval,
    bleNimDbgVendorConLastTimeout, bleNimDbgVendorAclEmptyTxCount,
    bleNimDbgVendorLldConStartCount,
    bleNimDbgVendorLldConStartStatus,
    bleNimDbgVendorLldConStartParamWord,
    bleNimDbgLldRxFreeCount, bleNimDbgLldRxLastStatus,
    bleNimDbgLldRxLastHeader, bleNimDbgLldRxLastMeta,
    bleNimDbgConnDeferredScheduleCount,
    bleNimDbgConnRxStatusRejectCount,
    bleNimDbgConnRxLastRejectedStatus,
    bleNimDbgConnRxLastRejectedHeader

const
  ConsoleUartTxPin = 14'u32
  ConsoleUartRxPin = 15'u32
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz {.intdefine.} = 40_000_000'u32
  WifiSsid {.strdefine.} = ""
  WifiPassword {.strdefine.} = ""
  WifiChannel {.intdefine.} = 0
  WifiScanOnly {.booldefine.} = false
  WifiBleSimultaneous {.booldefine.} = false
  WifiBleConnectPtaMode {.intdefine.} = wifiBleCoexBtPriority.int
  WifiBleCoexPtaMode {.intdefine.} = wifiBleCoexWifiPriority.int
  WifiBleCoexServicePeriodUs {.intdefine.} = 1000
  WifiBleCoexServiceIterations {.intdefine.} = 1
  WifiBleTrafficFrames {.intdefine.} = 0
  WifiBleTrafficAttemptBudget {.intdefine.} = 60
  WifiBleTrafficPeriodMs {.intdefine.} = 250
  WifiBleTrafficBusyRetryMs {.intdefine.} = 25
  WifiBleTrafficRequireAck {.booldefine.} = true
  WifiBlePostTrafficFrames {.intdefine.} = 0
  BleTrafficStartDelayMs {.intdefine.} = 2000
  BleRequireDisconnectedCallback {.booldefine.} = true
  BleDisconnectDrainMs {.intdefine.} = 5000
  BleDeviceName {.strdefine.} = "bl808-hal"
  BleHostWindowIterations {.intdefine.} = 35_000
  BleHostMinWindowIterations {.intdefine.} = 5_000
  BlePollIterations {.intdefine.} = 8
  BlePollDelayUs {.intdefine.} = 1_000
  BlePostAdvertiseQuietMs {.intdefine.} = 0

var
  console: Uart
  passed = 0
  failed = 0
  bleReadyCalled = false
  bleReadyErr: cint = -1
  hciPackets = 0
  bleConnectedCalled = false
  bleConnectedAtUs = 0'u64
  bleConnectedErr: uint8 = 0xFF'u8
  bleDisconnectedCalled = false
  bleConnCbStorage: BtConnCb

var nimfw_dbg_nullframe_calls {.importc.}: uint32
var nimfw_dbg_nullframe_return {.importc.}: uint32
var nimfw_dbg_nullframe_txint_seen {.importc.}: uint32
var nimfw_dbg_nullframe_fake_seen {.importc.}: uint32
var nimfw_dbg_nullframe_fake_qidx {.importc.}: uint32
var nimfw_dbg_nullframe_fake_link {.importc.}: uint32
var nimfw_dbg_nullframe_busy_txcheck {.importc.}: uint32
var nimfw_dbg_nullframe_busy_pscheck {.importc.}: uint32
var nimfw_dbg_nullframe_txtrig_seen {.importc.}: uint32
var nimfw_dbg_nullframe_txtrig_internal {.importc.}: uint32
var nimfw_dbg_nullframe_pay_seen {.importc.}: uint32
var nimfw_dbg_nullframe_pay_payload {.importc.}: uint32
var nimfw_dbg_nullframe_pay_empty {.importc.}: uint32
var nimfw_dbg_nullframe_pay_nonempty {.importc.}: uint32
var nimfw_dbg_nullframe_pay_trig {.importc.}: uint32
var nimfw_dbg_nullframe_pay_current {.importc.}: uint32
var nimfw_dbg_nullframe_pay_pending {.importc.}: uint32
var nimfw_dbg_nullframe_pay_thd_status {.importc.}: uint32
var nimfw_dbg_nullframe_postponed {.importc.}: uint32
var nimfw_dbg_nullframe_queued {.importc.}: uint32
var nimfw_keepalive_inflight {.importc.}: uint32
var nimfw_keepalive_target_cfm {.importc.}: uint32
var nimfw_dbg_keepalive_rc {.importc.}: uint32
var nimfw_dbg_keepalive_post_before {.importc.}: uint32
var nimfw_dbg_keepalive_post_after {.importc.}: uint32

proc check(label: string, ok: bool) =
  discard console.sendString(if ok: "[PASS] " else: "[FAIL] ")
  discard console.sendLine(label)
  if ok: inc passed else: inc failed

proc printResult() =
  discard console.sendString("Result: ")
  console.sendHex32(passed.uint32)
  discard console.sendString(" passed, ")
  console.sendHex32(failed.uint32)
  discard console.sendLine(" failed")
  if failed == 0:
    discard console.sendLine("=== Test Complete ===")

proc wifiStaAssociated(): bool =
  bl808_wifi_backend_connected() != 0

proc bleReady(err: cint) {.cdecl.} =
  bleReadyCalled = true
  bleReadyErr = err

proc hciRecv(data: ptr uint8, len: uint16): uint8 {.cdecl.} =
  discard data
  discard len
  inc hciPackets
  0

proc bleConnected(conn: ptr BtConn, err: uint8) {.cdecl.} =
  discard conn
  bleConnectedCalled = true
  bleConnectedAtUs = clicReadMtime()
  bleConnectedErr = err

proc bleDisconnected(conn: ptr BtConn, reason: uint8) {.cdecl.} =
  discard conn
  discard reason
  bleDisconnectedCalled = true

proc hostWindowDurationUs(iterationsValue: int): uint64 =
  let iterations =
    if iterationsValue <= 0: 0'u64
    else: iterationsValue.uint64
  let delay =
    if BlePollDelayUs <= 0: 1'u64
    else: BlePollDelayUs.uint64
  iterations * delay

proc hostWindowDeadlineUs(): uint64 =
  clicReadMtime() + hostWindowDurationUs(BleHostWindowIterations)

proc waitBleDisconnectedCallback(timeoutMs: uint32): CpsVoidFuture {.cps.} =
  if bleDisconnectedCalled:
    return
  discard await bleWaitPeripheralDisconnectedServicedAsync(
    timeoutMs, BlePollDelayUs.uint32, BlePollIterations.uint32)
  if not bleDisconnectedCalled and bleHostDbgConnActive() != 0'u32:
    discard await bleDisconnectAsync(0x13'u8, 2_000)
    for _ in 0'u32 ..< 100'u32:
      if bleDisconnectedCalled:
        break
      await sleepUs(1000'u64)

proc printHciStatus(label: string) =
  discard console.sendString("[BLE] ")
  discard console.sendString(label)
  discard console.sendString(" type=")
  console.sendHex32(bleLastHciPktType().uint32)
  discard console.sendString(" len=")
  console.sendHex32(bleLastHciLen().uint32)
  discard console.sendString(" opcode=")
  console.sendHex32(bleLastHciOpcode().uint32)
  discard console.sendString(" status=")
  console.sendHex32(cast[uint32](bleLastHciStatus()))
  discard console.sendString(" w0=")
  console.sendHex32(bleLastHciWord0())
  discard console.sendString(" w1=")
  console.sendHex32(bleLastHciWord1())
  discard console.sendLine("")

proc printBleDebugCounters(label: string) =
  when defined(BleDebugCounters):
    discard console.sendString("[BLEDBG] ")
    discard console.sendString(label)
    discard console.sendString(" isr=")
    console.sendHex32(bleNimDbgIsrCount())
    discard console.sendString(" stat8000=")
    console.sendHex32(bleNimDbgStat8000Count())
    discard console.sendString(" push=")
    console.sendHex32(bleNimDbgPushCount())
    discard console.sendString(" rxReady=")
    console.sendHex32(bleNimDbgRxReadyCount())
    discard console.sendString(" connInd=")
    console.sendHex32(bleNimDbgRxConnectIndCount())
    discard console.sendString(" progFifo=")
    console.sendHex32(bleNimDbgVendorSchProgFifoCount())
    discard console.sendString(" progSkip=")
    console.sendHex32(bleNimDbgVendorSchProgSkipCount())
    discard console.sendString(" llcpRx=")
    console.sendHex32(bleNimDbgVendorLlcpRxCount())
    discard console.sendString(" llcpTx=")
    console.sendHex32(bleNimDbgVendorLlcpTxCount())
    discard console.sendString(" aclEmpty=")
    console.sendHex32(bleNimDbgVendorAclEmptyTxCount())
    discard console.sendString(" llcpLast=")
    console.sendHex32(bleNimDbgVendorLlcpLastStatus())
    discard console.sendString(" llcpOp=")
    console.sendHex32(bleNimDbgVendorLlcpLastOpcode())
    discard console.sendString(" conStatus=")
    console.sendHex32(bleNimDbgVendorConLastStatus())
    discard console.sendString(" anchor=")
    console.sendHex32(bleNimDbgVendorConLastAnchor())
    discard console.sendString(" intv=")
    console.sendHex32(bleNimDbgVendorConLastInterval())
    discard console.sendString(" timeout=")
    console.sendHex32(bleNimDbgVendorConLastTimeout())
    discard console.sendString(" lldStart=")
    console.sendHex32(bleNimDbgVendorLldConStartCount())
    discard console.sendString(" lldRc=")
    console.sendHex32(bleNimDbgVendorLldConStartStatus())
    discard console.sendString(" defer=")
    console.sendHex32(bleNimDbgConnDeferredScheduleCount())
    discard console.sendString(" rxReject=")
    console.sendHex32(bleNimDbgConnRxStatusRejectCount())
    discard console.sendString(" rejSt=")
    console.sendHex32(bleNimDbgConnRxLastRejectedStatus())
    discard console.sendString(" rejHdr=")
    console.sendHex32(bleNimDbgConnRxLastRejectedHeader())
    discard console.sendString(" rxFree=")
    console.sendHex32(bleNimDbgLldRxFreeCount())
    discard console.sendString(" rxSt=")
    console.sendHex32(bleNimDbgLldRxLastStatus())
    discard console.sendString(" rxHdr=")
    console.sendHex32(bleNimDbgLldRxLastHeader())
    discard console.sendString(" rxMeta=")
    console.sendHex32(bleNimDbgLldRxLastMeta())
    for i in 0'u32 ..< 12'u32:
      discard console.sendString(" p")
      console.sendHex32(i)
      discard console.sendString("=")
      console.sendHex32(bleNimDbgVendorLldConStartParamWord(i))
    discard console.sendLine("")

proc smokeBle(): CpsVoidFuture {.cps.} =
  when WifiBleSimultaneous:
    wifiSetBleCoexistenceMode(WifiBleConnectPtaMode.uint32)
    discard console.sendString("[WIFI] PTA connect mode=")
    console.sendHex32(WifiBleConnectPtaMode.uint32)
    discard console.sendLine("")
  else:
    wifiSetBleCoexistenceMode(wifiBleCoexBtPriority)
    discard console.sendLine("[WIFI] PTA BT-priority for BLE")

  let mainRef = cast[pointer](blecontroller_main)
  check("ble controller main symbol", mainRef != nil)

  bleControllerInitRaw(5)
  check("ble controller init", true)
  check("ble controller version", ble_controller_get_lib_ver() != nil)

  ble_controller_set_tx_pwr(3)
  check("ble controller tx power direct", ble_controller_get_tx_pwr() == 3)

  var hciPacket = [0x03'u8, 0x0C, 0x00]
  check("ble hci interface init", bt_onchiphci_interface_init(hciRecv) == 0)
  check("ble hci send", bt_onchiphci_send(0, hciPacket.len.uint16, addr hciPacket[0]) == 0)
  printHciStatus("reset")

  bflbble_init()
  bflbble_isr()
  bflbble_reset()
  check("ble controller isr/reset", bflbble_sleep_check() >= 0)

  bleControllerInit(5)
  bleSetTxPower(4)
  check("ble tx power facade", bleGetTxPower() == 4)
  check("ble version facade", bleGetVersion().len > 0)
  check("ble enable facade",
        (await bleEnableAsync(bleReady)) == bleOk and
        bleReadyCalled and bleReadyErr == 0)
  check("ble set name", bleSetName(BleDeviceName) == bleOk)
  check("ble get name", $bt_get_name() == BleDeviceName)
  check("ble scan start", bt_le_scan_start(nil, nil) == 0)
  check("ble scan stop", bt_le_scan_stop() == 0)

  bleConnCbStorage.connected = bleConnected
  bleConnCbStorage.disconnected = bleDisconnected
  bt_conn_cb_register(addr bleConnCbStorage)
  check("ble conn callback register", true)

  var advParam: BtLeAdvParam
  var advData: BtData
  check("ble advertising start",
        (await bleStartAdvertisingAsync(addr advParam, addr advData, 0)) == bleOk)
  printHciStatus("adv-start")
  for _ in 0 ..< 2000:
    await sleepUs(BlePollDelayUs.uint64)
  discard console.sendString("[BLE] advertising ")
  discard console.sendLine(BleDeviceName)
  when WifiBleSimultaneous:
    check("wifi still connected during ble advertising", wifiStaAssociated())
  when BlePostAdvertiseQuietMs > 0:
    await sleepMs(BlePostAdvertiseQuietMs.uint64)
  printBleDebugCounters("adv")

  let hostDeadline = hostWindowDeadlineUs()
  let minDeadline = clicReadMtime() +
    hostWindowDurationUs(BleHostMinWindowIterations)
  var hostLoop = 0'u32
  var wifiTxStats: WifiKeepaliveStats
  var wifiTxStarted = false
  while clicReadMtime() < hostDeadline:
    await sleepUs(BlePollDelayUs.uint64)
    when WifiBleSimultaneous and WifiBleTrafficFrames > 0:
      let trafficDelayUs = BleTrafficStartDelayMs.uint64 * 1000'u64
      let trafficWindowOpen =
        bleConnectedCalled and not bleDisconnectedCalled and
        clicReadMtime() - bleConnectedAtUs >= trafficDelayUs
      if trafficWindowOpen and not wifiTxStarted:
        wifiTxStarted = true
        wifiSetBleCoexistenceMode(WifiBleCoexPtaMode.uint32)
        discard console.sendString("[WIFI] PTA traffic mode=")
        console.sendHex32(WifiBleCoexPtaMode.uint32)
        discard console.sendLine("")
        wifiTxStats = await wifiSendStaKeepaliveUntilAckAsync(
          WifiBleTrafficFrames.uint32,
          WifiBleTrafficAttemptBudget.uint32,
          WifiBleTrafficPeriodMs.uint32,
          WifiBleTrafficBusyRetryMs.uint32,
          500'u32,
          WifiBleCoexServiceIterations.uint32)
        wifiSetBleCoexistenceMode(WifiBleConnectPtaMode.uint32)
        discard console.sendString("[WIFI] PTA post-traffic mode=")
        console.sendHex32(WifiBleConnectPtaMode.uint32)
        discard console.sendLine("")
    when defined(BleHostLoopDiag):
      inc hostLoop
      if (hostLoop mod 5000'u32) == 0'u32:
        printBleDebugCounters("host-loop")
    if clicReadMtime() >= minDeadline and
        bleConnectedCalled and bleDisconnectedCalled:
      break

  printBleDebugCounters("host-window")
  when WifiBleSimultaneous and WifiBleTrafficFrames > 0:
    discard console.sendString("[WIFI] coex tx frames=")
    console.sendHex32(wifiTxStats.frames)
    discard console.sendString(" attempts=")
    console.sendHex32(wifiTxStats.attempts)
    discard console.sendString(" busy=")
    console.sendHex32(wifiTxStats.busy)
    discard console.sendString(" failures=")
    console.sendHex32(wifiTxStats.failures)
    discard console.sendString(" cfm=")
    console.sendHex32(wifiTxStats.cfmDelta)
    discard console.sendString(" ack=")
    console.sendHex32(wifiTxStats.ackDelta)
    discard console.sendString(" nack=")
    console.sendHex32(wifiTxStats.failDelta)
    discard console.sendLine("")
    let wifiTxDuringBleOk =
      wifiTxStats.frames >= WifiBleTrafficFrames.uint32 and
      wifiTxStats.failures == 0'u32 and
      wifiTxStats.ackDelta >= WifiBleTrafficFrames.uint32 and
      wifiTxStats.cfmDelta >= wifiTxStats.frames
    when WifiBleTrafficRequireAck:
      check("wifi tx during ble connection", wifiTxDuringBleOk)
    else:
      check("wifi tx during ble connection attempted",
            wifiTxStats.frames > 0'u32 and wifiTxStats.failures == 0'u32)
    if wifiTxStats.failures != 0'u32 or
        wifiTxStats.ackDelta < WifiBleTrafficFrames.uint32:
      discard console.sendString("[WIFI-NIMFW] null calls=")
      console.sendHex32(nimfw_dbg_nullframe_calls)
      discard console.sendString(" return=")
      console.sendHex32(nimfw_dbg_nullframe_return)
      discard console.sendString(" txint=")
      console.sendHex32(nimfw_dbg_nullframe_txint_seen)
      discard console.sendString(" fake=")
      console.sendHex32(nimfw_dbg_nullframe_fake_seen)
      discard console.sendString(" qidx=")
      console.sendHex32(nimfw_dbg_nullframe_fake_qidx)
      discard console.sendString(" link=")
      console.sendHex32(nimfw_dbg_nullframe_fake_link)
      discard console.sendString(" busy_tx=")
      console.sendHex32(nimfw_dbg_nullframe_busy_txcheck)
      discard console.sendString(" busy_ps=")
      console.sendHex32(nimfw_dbg_nullframe_busy_pscheck)
      discard console.sendString(" postponed=")
      console.sendHex32(nimfw_dbg_nullframe_postponed)
      discard console.sendString(" queued=")
      console.sendHex32(nimfw_dbg_nullframe_queued)
      discard console.sendLine("")
      discard console.sendString("[WIFI-NIMFW] payload seen=")
      console.sendHex32(nimfw_dbg_nullframe_pay_seen)
      discard console.sendString(" payload=")
      console.sendHex32(nimfw_dbg_nullframe_pay_payload)
      discard console.sendString(" empty=")
      console.sendHex32(nimfw_dbg_nullframe_pay_empty)
      discard console.sendString(" nonempty=")
      console.sendHex32(nimfw_dbg_nullframe_pay_nonempty)
      discard console.sendString(" trig=")
      console.sendHex32(nimfw_dbg_nullframe_pay_trig)
      discard console.sendString(" current=")
      console.sendHex32(nimfw_dbg_nullframe_pay_current)
      discard console.sendString(" pending=")
      console.sendHex32(nimfw_dbg_nullframe_pay_pending)
      discard console.sendString(" thd=")
      console.sendHex32(nimfw_dbg_nullframe_pay_thd_status)
      discard console.sendString(" txtrig=")
      console.sendHex32(nimfw_dbg_nullframe_txtrig_seen)
      discard console.sendString(" txtrig_int=")
      console.sendHex32(nimfw_dbg_nullframe_txtrig_internal)
      discard console.sendLine("")
      discard console.sendString("[WIFI-NIMFW] keepalive inflight=")
      console.sendHex32(nimfw_keepalive_inflight)
      discard console.sendString(" target=")
      console.sendHex32(nimfw_keepalive_target_cfm)
      discard console.sendString(" rc=")
      console.sendHex32(nimfw_dbg_keepalive_rc)
      discard console.sendString(" post_before=")
      console.sendHex32(nimfw_dbg_keepalive_post_before)
      discard console.sendString(" post_after=")
      console.sendHex32(nimfw_dbg_keepalive_post_after)
      discard console.sendLine("")
  check("ble peripheral connected callback",
        bleConnectedCalled and bleConnectedErr == 0)
  when BleRequireDisconnectedCallback:
    await waitBleDisconnectedCallback(BleDisconnectDrainMs.uint32)
    discard console.sendString("[BLEDBG] host active=")
    console.sendHex32(bleHostDbgConnActive())
    discard console.sendString(" connected_notified=")
    console.sendHex32(bleHostDbgPeripheralConnectedNotified())
    discard console.sendString(" disconnected_notified=")
    console.sendHex32(bleHostDbgPeripheralDisconnectedNotified())
    discard console.sendString(" idle_polls=")
    console.sendHex32(bleHostDbgPeripheralIdlePolls())
    discard console.sendString(" last_rx_event=")
    console.sendHex32(bleHostDbgPeripheralLastRxEventCounter())
    discard console.sendString(" disc_events=")
    console.sendHex32(bleNimPeripheralDiscEventCount())
    discard console.sendString(" disc_source=")
    console.sendHex32(bleNimPeripheralDiscSource())
    discard console.sendString(" disc_reason=")
    console.sendHex32(bleNimPeripheralDiscReason())
    discard console.sendString(" llcp_rx=")
    console.sendHex32(bleNimDbgVendorLlcpRxCount())
    discard console.sendString(" llcp_last=")
    console.sendHex32(bleNimDbgVendorLlcpLastOpcode())
    discard console.sendLine("")
    check("ble peripheral disconnected callback", bleDisconnectedCalled)
  else:
    check("ble peripheral connected callback retained", bleConnectedCalled)
  when WifiBleSimultaneous:
    check("wifi still connected after ble", wifiStaAssociated())

  check("ble advertising stop", (await bleStopAdvertisingAsync()) == bleOk)
  let sleepRc = ble_controller_sleep(7)
  discard console.sendString("[BLE] sleep rc=")
  console.sendHex32(cast[uint32](sleepRc))
  discard console.sendLine("")
  check("ble controller sleep callable", true)
  ble_controller_sleep_restore()
  check("ble controller sleep restore", true)
  bleControllerDeinit()
  check("ble controller deinit", true)

proc smokeWifi(): CpsVoidFuture {.cps.} =
  when not WifiScanOnly:
    check("wifi credentials supplied", WifiSsid.len > 0 and WifiPassword.len > 0)
  check("wifi init", (await wifiInitAsync()) == wifiOk)

  var iface = wifi_mgmr_sta_enable()
  check("wifi sta enable", iface != nil)
  let scanItems = await wifiScanAsync(30_000)
  check("wifi scan", true)
  discard console.sendString("[WIFI] scan items=")
  console.sendHex32(scanItems)
  discard console.sendString(" done=")
  console.sendHex32(bl808_wifi_backend_scan_done_count())
  discard console.sendLine("")
  check("wifi scan complete", bl808_wifi_backend_scan_done_count() > 0'u32)
  check("wifi scan results", scanItems > 0'u32)

  when WifiScanOnly:
    check("wifi ap start",
          (await wifiStartApAsync("bl808-hal-ap", "12345678", 1)) == wifiOk)
    check("wifi ap stop", (await wifiStopApAsync()) == wifiOk)
    discard rfReadRevision()
    check("wifi rf revision read", true)
    return

  discard console.sendString("[WIFI] connecting ssid=")
  discard console.sendLine(WifiSsid)
  check("wifi connect Frog",
        (await wifiConnectAsync(WifiSsid, WifiPassword, WifiChannel.uint8)) == wifiOk)
  check("wifi netif", wifiGetNetif() != nil)
  when WifiBleSimultaneous:
    check("wifi still connected before ble", wifiStaAssociated())
    wifiConfigureServiceHook(WifiBleCoexServicePeriodUs.uint32,
                             WifiBleCoexServiceIterations.uint32)
    discard rfReadRevision()
    check("wifi rf revision read", true)
    return
  when defined(WifiTransitionDiag):
    discard console.sendLine("[WIFI] disconnect begin")
  let disconnectOk = (await wifiDisconnectAsync()) == wifiOk
  when defined(WifiTransitionDiag):
    discard console.sendLine("[WIFI] disconnect returned")
  check("wifi disconnect", disconnectOk)
  when defined(WifiTransitionDiag):
    discard console.sendLine("[WIFI] ap start begin")
  let apStartOk = (await wifiStartApAsync("bl808-hal-ap", "12345678", 1)) == wifiOk
  when defined(WifiTransitionDiag):
    discard console.sendLine("[WIFI] ap start returned")
  check("wifi ap start", apStartOk)
  check("wifi ap stop", (await wifiStopApAsync()) == wifiOk)
  discard rfReadRevision()
  check("wifi rf revision read", true)

proc finishWifiAfterBle(): CpsVoidFuture {.cps.} =
  when WifiBleSimultaneous:
    when WifiBlePostTrafficFrames > 0:
      wifiSetBleCoexistenceMode(wifiBleCoexWifiPriority)
      wifiSetStaKeepaliveQosNull(true)
      wifiReclaimStaTxChannel()
      let txStats = await wifiSendStaKeepaliveUntilAckAsync(
        WifiBlePostTrafficFrames.uint32,
        5000'u32,
        1'u32,
        1'u32,
        500'u32,
        WifiBleCoexServiceIterations.uint32)
      discard console.sendString("[WIFI] post-ble tx frames=")
      console.sendHex32(txStats.frames)
      discard console.sendString(" attempts=")
      console.sendHex32(txStats.attempts)
      discard console.sendString(" busy=")
      console.sendHex32(txStats.busy)
      discard console.sendString(" failures=")
      console.sendHex32(txStats.failures)
      discard console.sendString(" cfm_delta=")
      console.sendHex32(txStats.cfmDelta)
      discard console.sendString(" ack_delta=")
      console.sendHex32(txStats.ackDelta)
      discard console.sendString(" nack_delta=")
      console.sendHex32(txStats.failDelta)
      discard console.sendLine("")
      check("wifi tx after ble", txStats.frames > 0'u32 and
            txStats.failures == 0'u32 and
            txStats.cfmDelta >= txStats.frames and
            txStats.ackDelta >= WifiBlePostTrafficFrames.uint32)
    when defined(WifiTransitionDiag):
      discard console.sendLine("[WIFI] post-ble disconnect begin")
    check("wifi disconnect after ble", (await wifiDisconnectAsync()) == wifiOk)

proc mainWorkflow(): CpsVoidFuture {.cps.} =
  await smokeWifi()
  when WifiBleSimultaneous:
    bleInstallHostServiceHook(BlePollDelayUs.uint32, BlePollIterations.uint32)
  else:
    discard bleHostServiceTask(BlePollDelayUs.uint32, BlePollIterations.uint32)
  await smokeBle()
  await finishWifiAfterBle()
  printResult()

proc main() {.exportc, cdecl.} =
  systemInit()
  heapInit()

  enableAllPeriphClocks()
  enablePeriphClock(periphUart0)
  setMcuXclkSource(mcuXclkXtal)
  setUartClock(true, uartClkXclk, 0)
  gpioSetupUart(ConsoleUartTxPin, ConsoleUartRxPin)
  console = initUart(uart0, UartConfig(
    baudRate: ConsoleBaud, dataBits: data8,
    stopBits: stop1, parity: parityNone,
  ), ConsoleClkHz)

  discard console.sendLine("")
  discard console.sendLine("=== BL808 BLE/WiFi HAL Test ===")

  schedulerInit()
  wifiInstallServiceHook()
  discard mainWorkflow()
  runScheduler()
