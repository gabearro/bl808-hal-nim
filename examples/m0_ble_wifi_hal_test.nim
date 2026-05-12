## M0 BLE/WiFi HAL feature test.
##
## WiFi credentials are supplied by hardware validation with:
##   -d:WifiSsid=<ssid> -d:WifiPassword=<password>

import bl808/startup
import bl808/core
import bl808/glb, bl808/gpio, bl808/uart
import bl808/ble, bl808/wifi
import bl808/panicoverride
import bl808/kernel/alloc
when defined(bl808BleVendor):
  from bl808/bleblob import bleBlobPoll
else:
  from bl808/blecontroller import bflbip_schedule
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
      bleNimDbgVendorLldConStartParamWord
  when defined(bl808WifiNimFw):
    from bl808/wifi_fw import coex_pta_force_autocontrol_set

const
  ConsoleUartTxPin = 14'u32
  ConsoleUartRxPin = 15'u32
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz {.intdefine.} = 40_000_000'u32
  WifiSsid {.strdefine.} = ""
  WifiPassword {.strdefine.} = ""
  WifiChannel {.intdefine.} = 0
  WifiScanOnly {.booldefine.} = false
  BleDeviceName {.strdefine.} = "bl808-hal"
  BleHostWindowIterations {.intdefine.} = 35_000
  BleHostMinWindowIterations {.intdefine.} = 5_000
  BlePollIterations {.intdefine.} = 8
  BlePollDelayUs {.intdefine.} = 1_000

var
  console: Uart
  passed = 0
  failed = 0
  bleReadyCalled = false
  bleReadyErr: cint = -1
  hciPackets = 0
  bleConnectedCalled = false
  bleConnectedErr: uint8 = 0xFF'u8
  bleDisconnectedCalled = false
  bleConnCbStorage: BtConnCb

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
  bleConnectedErr = err

proc bleDisconnected(conn: ptr BtConn, reason: uint8) {.cdecl.} =
  discard conn
  discard reason
  bleDisconnectedCalled = true

proc pollBleController(iterations: uint32) =
  when defined(bl808BleVendor):
    bleBlobPoll(iterations)
  else:
    for _ in 0'u32 ..< iterations:
      bflbble_isr()
      bflbip_schedule()
      blePollHostEvents()

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
  when not defined(bl808BleVendor) and defined(BleDebugCounters):
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
    for i in 0'u32 ..< 12'u32:
      discard console.sendString(" p")
      console.sendHex32(i)
      discard console.sendString("=")
      console.sendHex32(bleNimDbgVendorLldConStartParamWord(i))
    discard console.sendLine("")

proc smokeBle() =
  when not defined(bl808BleVendor) and defined(bl808WifiNimFw):
    coex_pta_force_autocontrol_set(2)
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
  check("ble enable facade", bleEnable(bleReady) == bleOk and bleReadyCalled and bleReadyErr == 0)
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
  check("ble advertising start", bleStartAdvertising(addr advParam, addr advData, 0) == bleOk)
  printHciStatus("adv-start")
  when not defined(bl808BleVendor):
    for _ in 0 ..< 2000:
      pollBleController(BlePollIterations.uint32)
      delayUs(BlePollDelayUs.uint32)
  discard console.sendString("[BLE] advertising ")
  discard console.sendLine(BleDeviceName)
  printBleDebugCounters("adv")

  when defined(bl808BleVendor):
    for _ in 0 ..< 15000:
      pollBleController(8)
      delayUs(1000)
  else:
    for i in 0 ..< BleHostWindowIterations:
      pollBleController(BlePollIterations.uint32)
      delayUs(BlePollDelayUs.uint32)
      if i >= BleHostMinWindowIterations and
          bleConnectedCalled and bleDisconnectedCalled:
        break

    printBleDebugCounters("host-window")
    check("ble peripheral connected callback",
          bleConnectedCalled and bleConnectedErr == 0)
    check("ble peripheral disconnected callback", bleDisconnectedCalled)

  check("ble advertising stop", bleStopAdvertising() == bleOk)
  let sleepRc = ble_controller_sleep(7)
  discard console.sendString("[BLE] sleep rc=")
  console.sendHex32(cast[uint32](sleepRc))
  discard console.sendLine("")
  check("ble controller sleep callable", true)
  ble_controller_sleep_restore()
  check("ble controller sleep restore", true)
  bleControllerDeinit()
  check("ble controller deinit", true)

proc smokeWifi() =
  when not WifiScanOnly:
    check("wifi credentials supplied", WifiSsid.len > 0 and WifiPassword.len > 0)
  check("wifi init", wifiInit() == wifiOk)

  var iface = wifi_mgmr_sta_enable()
  check("wifi sta enable", iface != nil)
  check("wifi scan", wifi_mgmr_scan(addr iface, nil) == 0)
  when defined(bl808WifiVendor):
    for _ in 0 ..< 30000:
      bl808_wifi_vendor_poll(8)
      if bl808_wifi_vendor_scan_done_count() > 0'u32:
        break
      delayUs(1000)
    for _ in 0 ..< 500:
      bl808_wifi_vendor_poll(8)
      delayUs(1000)
    discard console.sendString("[WIFI] scan items=")
    console.sendHex32(bl808_wifi_vendor_scan_count())
    discard console.sendString(" done=")
    console.sendHex32(bl808_wifi_vendor_scan_done_count())
    discard console.sendLine("")
    check("wifi scan complete", bl808_wifi_vendor_scan_done_count() > 0'u32)
    check("wifi scan results", bl808_wifi_vendor_scan_count() > 0'u32)

  when WifiScanOnly:
    check("wifi ap start", wifiStartAp("bl808-hal-ap", "12345678", 1) == wifiOk)
    check("wifi ap stop", wifiStopAp() == wifiOk)
    discard rfReadRevision()
    check("wifi rf revision read", true)
    return

  discard console.sendString("[WIFI] connecting ssid=")
  discard console.sendLine(WifiSsid)
  check("wifi connect Frog", wifiConnect(WifiSsid, WifiPassword, WifiChannel.uint8) == wifiOk)
  check("wifi netif", wifiGetNetif() != nil)
  when defined(WifiTransitionDiag):
    discard console.sendLine("[WIFI] disconnect begin")
  let disconnectOk = wifiDisconnect() == wifiOk
  when defined(WifiTransitionDiag):
    discard console.sendLine("[WIFI] disconnect returned")
  check("wifi disconnect", disconnectOk)
  when defined(WifiTransitionDiag):
    discard console.sendLine("[WIFI] ap start begin")
  let apStartOk = wifiStartAp("bl808-hal-ap", "12345678", 1) == wifiOk
  when defined(WifiTransitionDiag):
    discard console.sendLine("[WIFI] ap start returned")
  check("wifi ap start", apStartOk)
  check("wifi ap stop", wifiStopAp() == wifiOk)
  discard rfReadRevision()
  check("wifi rf revision read", true)

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

  smokeWifi()
  smokeBle()

  printResult()
