## M0 BLE vendor blob direct binding test.

import bl808/startup
import bl808/core
import bl808/glb, bl808/gpio, bl808/uart
import bl808/bleblob
import bl808/panicoverride
import bl808/kernel/alloc

const
  ConsoleUartTxPin = 14'u32
  ConsoleUartRxPin = 15'u32
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz {.intdefine.} = 40_000_000'u32

var
  console: Uart
  passed = 0
  failed = 0
  hciPackets = 0

proc check(label: string, ok: bool) =
  discard console.sendString(if ok: "[PASS] " else: "[FAIL] ")
  discard console.sendLine(label)
  if ok: inc passed else: inc failed

proc hciRecv(pktType: uint8, srcId: uint16, param: ptr uint8,
             paramLen: uint8) {.cdecl.} =
  discard pktType
  discard srcId
  discard param
  discard paramLen
  inc hciPackets

proc smokeBleBlob() =
  let mainRef = cast[pointer](blecontroller_main)
  check("ble blob controller main symbol", mainRef != nil)

  bleBlobPrepareWirelessDomain()
  bleBlobAllowAssertReturn()
  check("ble blob wireless prep", true)

  ble_controller_init(5)
  check("ble blob controller init", true)
  check("ble blob controller version", ble_controller_get_lib_ver() != nil)

  ble_controller_set_tx_pwr(3)
  check("ble blob tx power direct", ble_controller_get_tx_pwr() == 3)

  check("ble blob hci interface init", bt_onchiphci_interface_init(hciRecv) == 0)
  check("ble blob hci command direct", bleBlobHciCommand(0x0C03'u16, nil, 0) == 0)
  bleBlobPoll(64)
  check("ble blob poll direct", true)

  let sleepRc = ble_controller_sleep(7)
  discard console.sendString("[BLEBLOB] sleep rc=")
  console.sendHex32(cast[uint32](sleepRc))
  discard console.sendLine("")
  check("ble blob sleep callable", true)
  ble_controller_sleep_restore()
  check("ble blob sleep restore", true)

  ble_controller_deinit()
  check("ble blob controller deinit", true)

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
  discard console.sendLine("=== BL808 BLE Blob Direct Test ===")

  smokeBleBlob()

  discard console.sendString("Result: ")
  console.sendHex32(passed.uint32)
  discard console.sendString(" passed, ")
  console.sendHex32(failed.uint32)
  discard console.sendLine(" failed")
  if failed == 0:
    discard console.sendLine("=== Test Complete ===")
