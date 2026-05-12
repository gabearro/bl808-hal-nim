## M0 BLE central link validation.

import bl808/startup
import bl808/core
import bl808/glb, bl808/gpio, bl808/uart
import bl808/ble
import bl808/panicoverride
import bl808/kernel/alloc
when defined(bl808BleNimUseClicIrq) and not defined(bl808BleVendor):
  import bl808/irq
when defined(bl808BleVendor):
  from bl808/bleblob import
    bleBlobPoll,
    bleBlobDbgQueueNewCount,
    bleBlobDbgQueueNewLastSize,
    bleBlobDbgQueueNewLastMaxMsg,
    bleBlobDbgQueueNewLastStatus

const
  ConsoleUartTxPin = 14'u32
  ConsoleUartRxPin = 15'u32
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz {.intdefine.} = 40_000_000'u32
  BleDeviceName {.strdefine.} = "bl808-hal-central"
  BleCentralName {.strdefine.} = "bl808-host"
  BleCentralTimeoutMs {.intdefine.} = 20_000
  BleCentralHostStartDelayMs {.intdefine.} = 3_000

var
  console: Uart
  passed = 0
  failed = 0
  bleReadyCalled = false
  bleReadyErr: cint = -1
  bleConnectedCalled = false
  bleConnectedErr: uint8 = 0xFF'u8

proc enableBleControllerIrq() =
  when defined(bl808BleNimUseClicIrq) and not defined(bl808BleVendor):
    registerTrapHandler(IrqM0Ble, bflbble_isr)
    bflbble_isr_clear()
    clicClearPending(IrqM0Ble)
    clicSetLevel(IrqM0Ble, 1)
    clicEnableIrq(IrqM0Ble)
    csrWriteMie(csrReadMie() or (1'u32 shl 11))
    enableInterrupts()

proc check(label: string, ok: bool) =
  discard console.sendString(if ok: "[PASS] " else: "[FAIL] ")
  discard console.sendLine(label)
  if ok: inc passed else: inc failed

proc bleReady(err: cint) {.cdecl.} =
  bleReadyCalled = true
  bleReadyErr = err

proc bleConnected(conn: ptr BtConn, err: uint8) {.cdecl.} =
  discard conn
  bleConnectedCalled = true
  bleConnectedErr = err

proc bleDisconnected(conn: ptr BtConn, reason: uint8) {.cdecl.} =
  discard conn
  discard reason

proc bleInitStage(stage: cstring) {.cdecl.} =
  discard console.sendString("[BLEDBG] init ")
  discard console.sendLine($stage)

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
  discard console.sendLine("")

proc printQueueDiag(label: string) =
  when defined(bl808BleVendor):
    discard console.sendString("[BLEDBG] ")
    discard console.sendString(label)
    discard console.sendString(" qnew=")
    console.sendHex32(bleBlobDbgQueueNewCount())
    discard console.sendString(" size=")
    console.sendHex32(bleBlobDbgQueueNewLastSize())
    discard console.sendString(" max=")
    console.sendHex32(bleBlobDbgQueueNewLastMaxMsg())
    discard console.sendString(" status=")
    console.sendHex32(bleBlobDbgQueueNewLastStatus())
    discard console.sendLine("")

proc printScanProbeDiag() =
  when defined(bl808BleVendorLldScanProbe):
    discard console.sendString("[BLEDBG] scan_probe reports=")
    console.sendHex32(bleControllerScanProbeReportCount())
    discard console.sendString(" start_status=")
    console.sendHex32(bleControllerScanProbeStartStatus())
    discard console.sendString(" arb_insert=")
    console.sendHex32(bleControllerScanProbeArbInsertCount())
    discard console.sendString(" arb_cb=")
    console.sendHex32(bleControllerScanProbeArbCallbackCount())
    discard console.sendString(" sw_int=")
    console.sendHex32(bleControllerScanProbeSwIntCount())
    discard console.sendString(" restarts=")
    console.sendHex32(bleControllerScanProbeRestartCount())
    discard console.sendString(" isr=")
    console.sendHex32(bleControllerIsrCount())
    discard console.sendString(" stat_or=")
    console.sendHex32(bleControllerIsrStatOr())
    discard console.sendString(" stat20=")
    console.sendHex32(bleControllerStat20Count())
    discard console.sendString(" stat8000=")
    console.sendHex32(bleControllerStat8000Count())
    discard console.sendString(" sch_fifo=")
    console.sendHex32(bleControllerSchProgFifoCount())
    discard console.sendString(" sch_skip=")
    console.sendHex32(bleControllerSchProgSkipCount())
    discard console.sendString(" rxcheck=")
    console.sendHex32(bleControllerRxCheckCount())
    discard console.sendString(" rxhit=")
    console.sendHex32(bleControllerRxCheckHitCount())
    discard console.sendString(" rxfree=")
    console.sendHex32(bleControllerRxFreeCount())
    discard console.sendString(" last_status=")
    console.sendHex32(bleControllerRxLastStatus())
    discard console.sendString(" last_header=")
    console.sendHex32(bleControllerRxLastHeader())
    discard console.sendLine("")
    discard console.sendString("[BLEDBG] scan_unsupported count=")
    console.sendHex32(bleControllerScanProbeUnsupportedCount())
    discard console.sendString(" header=")
    console.sendHex32(bleControllerScanProbeUnsupportedHeader())
    discard console.sendString(" len=")
    let dataLen = bleControllerScanProbeUnsupportedLen()
    console.sendHex32(dataLen)
    discard console.sendString(" data=")
    var i = 0'u8
    while i < dataLen.uint8 and i < 31'u8:
      console.sendHex32(bleControllerScanProbeUnsupportedByte(i).uint32)
      inc i
    discard console.sendLine("")
  when defined(bl808BleVendorLldInitProbe):
    discard console.sendString("[BLEDBG] init_probe start_status=")
    console.sendHex32(bleControllerInitProbeStartStatus())
    discard console.sendString(" msg=")
    console.sendHex32(bleControllerInitProbeMessageCount())
    discard console.sendString(" ok=")
    console.sendHex32(bleControllerInitProbeSuccessCount())
    discard console.sendString(" fail=")
    console.sendHex32(bleControllerInitProbeFailureCount())
    discard console.sendString(" act=")
    console.sendHex32(bleControllerInitProbeLastActivity())
    discard console.sendString(" msg_status=")
    console.sendHex32(bleControllerInitProbeLastMessageStatus())
    discard console.sendString(" cancel_status=")
    console.sendHex32(bleControllerInitProbeCancelStatus())
    discard console.sendString(" cancel_count=")
    console.sendHex32(bleControllerInitProbeCancelCount())
    discard console.sendString(" header_fix=")
    console.sendHex32(bleControllerInitProbeHeaderFixCount())
    discard console.sendLine("")
    discard console.sendString("[BLEDBG] init_arb insert=")
    console.sendHex32(bleControllerInitProbeArbInsertCount())
    discard console.sendString(" cb=")
    console.sendHex32(bleControllerInitProbeArbCallbackCount())
    discard console.sendString(" w1=")
    console.sendHex32(bleControllerInitProbeArbLastWord(1))
    discard console.sendString(" w2=")
    console.sendHex32(bleControllerInitProbeArbLastWord(2))
    discard console.sendString(" w7=")
    console.sendHex32(bleControllerInitProbeArbLastWord(7))
    discard console.sendString(" w24=")
    console.sendHex32(bleControllerInitProbeArbLastWord(24))
    discard console.sendString(" w28=")
    console.sendHex32(bleControllerInitProbeArbLastWord(28))
    discard console.sendLine("")
    discard console.sendString("[BLEDBG] init_peer_rx count=")
    console.sendHex32(bleControllerInitProbePeerRxCount())
    discard console.sendString(" hit=")
    console.sendHex32(bleControllerInitProbePeerHitCount())
    discard console.sendString(" header=")
    console.sendHex32(bleControllerInitProbePeerRxLastHeader())
    discard console.sendString(" status=")
    console.sendHex32(bleControllerInitProbePeerRxLastStatus())
    discard console.sendString(" meta=")
    console.sendHex32(bleControllerInitProbePeerRxLastMeta())
    discard console.sendString(" status_fix=")
    console.sendHex32(bleControllerInitProbeStatusFixCount())
    discard console.sendString(" status_last=")
    console.sendHex32(bleControllerInitProbeStatusFixLast())
    discard console.sendLine("")
    discard console.sendString("[BLEDBG] init_msg_alloc count=")
    console.sendHex32(bleControllerInitProbeMessageAllocCount())
    discard console.sendString(" len=")
    console.sendHex32(bleControllerInitProbeMessageAllocLen())
    discard console.sendString(" dest=")
    console.sendHex32(bleControllerInitProbeMessageAllocDest())
    discard console.sendString(" src=")
    console.sendHex32(bleControllerInitProbeMessageAllocSrc())
    discard console.sendString(" aa_count=")
    console.sendHex32(bleControllerInitProbeAccessAddressCount())
    discard console.sendString(" aa_seed=")
    console.sendHex32(bleControllerInitProbeAccessAddressSeed())
    discard console.sendString(" aa=")
    console.sendHex32(bleControllerInitProbeAccessAddress())
    discard console.sendString(" dur_count=")
    console.sendHex32(bleControllerInitProbePacketDurationCount())
    discard console.sendString(" dur_len=")
    console.sendHex32(bleControllerInitProbePacketDurationLen())
    discard console.sendString(" dur_rate=")
    console.sendHex32(bleControllerInitProbePacketDurationRate())
    discard console.sendLine("")

proc waitForHostAdvertiser() =
  when BleCentralHostStartDelayMs > 0:
    for _ in 0 ..< BleCentralHostStartDelayMs:
      when defined(bl808BleVendor):
        bleBlobPoll(8)
      delayUs(1000)

proc printLastAdvReportDiag() =
  when defined(bl808BleVendorLldScanProbe):
    discard console.sendString("[BLEDBG] last_adv ev=")
    console.sendHex32(bleScanLastReportEventType().uint32)
    discard console.sendString(" addr_type=")
    console.sendHex32(bleScanLastReportAddrType().uint32)
    discard console.sendString(" rssi=")
    console.sendHex32(bleScanLastReportRssiRaw().uint32)
    discard console.sendString(" addr=")
    for i in 0'u8 ..< 6'u8:
      console.sendHex32(bleScanLastReportAddrByte(i).uint32)
    discard console.sendString(" data_len=")
    let dataLen = bleScanLastReportDataLen()
    console.sendHex32(dataLen.uint32)
    discard console.sendString(" data=")
    var i = 0'u8
    while i < dataLen and i < 31'u8:
      console.sendHex32(bleScanLastReportDataByte(i).uint32)
      inc i
    discard console.sendLine("")

proc printMatchedAdvReportDiag() =
  when defined(bl808BleVendorLldScanProbe):
    discard console.sendString("[BLEDBG] matched_adv ev=")
    console.sendHex32(bleScanMatchedReportEventType().uint32)
    discard console.sendString(" addr_type=")
    console.sendHex32(bleScanMatchedReportAddrType().uint32)
    discard console.sendString(" addr=")
    for i in 0'u8 ..< 6'u8:
      console.sendHex32(bleScanMatchedReportAddrByte(i).uint32)
    discard console.sendString(" data_len=")
    let dataLen = bleScanMatchedReportDataLen()
    console.sendHex32(dataLen.uint32)
    discard console.sendString(" data=")
    var i = 0'u8
    while i < dataLen and i < 31'u8:
      console.sendHex32(bleScanMatchedReportDataByte(i).uint32)
      inc i
    discard console.sendLine("")

proc printInitParamDiag() =
  when defined(bl808BleVendorLldInitProbe):
    discard console.sendString("[BLEDBG] init_params data=")
    for i in 0'u8 ..< 36'u8:
      console.sendHex32(bleControllerInitProbeParamByte(i).uint32)
    discard console.sendLine("")

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
  discard console.sendLine("=== BL808 BLE Central HAL Test ===")

  bleControllerInitRawWithStage(5, bleInitStage)
  enableBleControllerIrq()
  printQueueDiag("after-init")
  check("ble controller init", true)
  check("ble controller version", ble_controller_get_lib_ver() != nil)

  bleReadyCalled = false
  bleReadyErr = -1
  check("ble enable", bt_enable(bleReady) == 0 and bleReadyCalled and bleReadyErr == 0)
  printHciStatus("enable")
  check("ble set name", bt_set_name(BleDeviceName) == 0)

  var connCb: BtConnCb
  connCb.connected = bleConnected
  connCb.disconnected = bleDisconnected
  bt_conn_cb_register(addr connCb)
  check("ble conn callback register", true)

  for _ in 0 ..< 200:
    when defined(bl808BleVendor):
      bleBlobPoll(8)
    delayUs(1000)

  bleConnectedCalled = false
  bleConnectedErr = 0xFF'u8
  discard console.sendString("[BLE] central scan ")
  discard console.sendLine(BleCentralName)
  waitForHostAdvertiser()
  when BleCentralHostStartDelayMs > 0:
    discard console.sendString("[BLE] central scan ")
    discard console.sendLine(BleCentralName)
  let centralOk =
    bleCentralConnect(BleCentralName, BleCentralTimeoutMs.uint32) == bleOk
  printHciStatus("central")
  discard console.sendString("[BLE] central reports=")
  console.sendHex32(bleScanReportCount())
  discard console.sendString(" matches=")
  console.sendHex32(bleScanNameMatchCount())
  discard console.sendLine("")
  printLastAdvReportDiag()
  printMatchedAdvReportDiag()
  printInitParamDiag()
  printScanProbeDiag()
  check("ble central connect",
        centralOk and bleConnectedCalled and bleConnectedErr == 0)
  if centralOk:
    discard bleDisconnect()

  discard console.sendString("Result: ")
  console.sendHex32(passed.uint32)
  discard console.sendString(" passed, ")
  console.sendHex32(failed.uint32)
  discard console.sendLine(" failed")
  if failed == 0:
    discard console.sendLine("=== Test Complete ===")
