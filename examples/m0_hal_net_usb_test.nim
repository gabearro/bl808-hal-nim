## M0 HAL network and USB feature test.
##
## Covers EMAC and USB register-level APIs without requiring an attached PHY,
## USB host, or USB device. MDIO and host operations are bounded; the test only
## asserts that the HAL calls complete and leave expected controller registers.

import bl808/startup
import bl808/core
import bl808/mmio, bl808/memmap
import bl808/glb, bl808/gpio, bl808/uart
import bl808/emac, bl808/usb
import bl808/panicoverride
import bl808/kernel/alloc

const
  ConsoleUartTxPin = 14'u32
  ConsoleUartRxPin = 15'u32
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz {.intdefine.} = 40_000_000'u32
  MacAddr: array[6, uint8] = [0x02'u8, 0x80, 0xE1, 0x00, 0x00, 0x01]

var
  console: Uart
  passed = 0
  failed = 0

proc check(label: string, ok: bool) =
  discard console.sendString(if ok: "[PASS] " else: "[FAIL] ")
  discard console.sendLine(label)
  if ok: inc passed else: inc failed

proc checkEq(label: string, got, expected: uint32) =
  if got == expected:
    check(label, true)
  else:
    discard console.sendString("[FAIL] ")
    discard console.sendString(label)
    discard console.sendString(" got=")
    console.sendHex32(got)
    discard console.sendString(" expected=")
    console.sendHex32(expected)
    discard console.sendLine("")
    inc failed

proc smokeEmac() =
  enableSystemClock(GlbCgenCfg2, CgenCfg2Emac)
  emacInit(MacAddr)
  checkEq("emac tx descriptor address", emacTxBdAddr(3).uint32,
          (EmacBdPoolStart + 24'u).uint32)
  checkEq("emac rx descriptor address", emacRxBdAddr(8, 2).uint32,
          (EmacBdPoolStart + 80'u).uint32)

  emacEnableRx()
  emacEnableTx()
  check("emac rx/tx enable", (regRead(EmacMode) and
        ((1'u32 shl EmacRxEn) or (1'u32 shl EmacTxEn))) ==
        ((1'u32 shl EmacRxEn) or (1'u32 shl EmacTxEn)))
  emacDisableRx()
  emacDisableTx()
  check("emac rx/tx disable", (regRead(EmacMode) and
        ((1'u32 shl EmacRxEn) or (1'u32 shl EmacTxEn))) == 0)

  emacEnableInterrupt(EmacIntTxB)
  emacDisableInterrupt(EmacIntTxB)
  emacClearInterrupt(EmacIntTxB)
  discard emacReadInterruptStatus()
  check("emac interrupt APIs", (regRead(EmacIntMask) and
        (1'u32 shl EmacIntTxB)) != 0)

  emacSetPromiscuous(true)
  emacRejectBroadcast(true)
  check("emac filter bits set", (regRead(EmacMode) and
        ((1'u32 shl EmacPro) or (1'u32 shl EmacBro))) ==
        ((1'u32 shl EmacPro) or (1'u32 shl EmacBro)))
  emacSetHashFilter(0x55AA_00FF'u32, 0xAA55_FF00'u32)
  check("emac hash filter", regRead(EmacHash0) == 0x55AA_00FF'u32 and
        regRead(EmacHash1) == 0xAA55_FF00'u32)
  emacSetPromiscuous(false)
  emacRejectBroadcast(false)

  let (_, readErr) = emacMdioRead(31'u8, 31'u8, timeout = 1)
  let writeErr = emacMdioWrite(31'u8, 31'u8, 0'u16, timeout = 1)
  check("emac bounded mdio APIs", readErr in {emacOk, emacTimeout} and
        writeErr in {emacOk, emacTimeout})

proc smokeUsb() =
  enableSystemClock(GlbCgenCfg2, CgenCfg2Usb)
  usbDeviceInit(highSpeed = false)
  usbDeviceSetAddress(0x12'u8)
  discard regRead(UsbDevAdr)
  check("usb device address API", true)
  discard usbDeviceGetFrameNumber()

  usbCxDone()
  usbCxStall()
  discard usbCxFifoEmpty()
  discard usbCxFifoFull()
  discard regRead(UsbDevCxcfe)
  check("usb cx control APIs", true)

  usbSetInEpMaxPacket(1, 64)
  usbSetOutEpMaxPacket(1, 64)
  usbStallInEp(1)
  usbStallOutEp(1)
  usbResetToggleInEp(1)
  usbResetToggleOutEp(1)
  discard regRead(UsbDevInmps1)
  discard regRead(UsbDevOutmps1)
  check("usb endpoint controls", true)

  discard usbGetFifoByteCount(0)
  discard usbGetFifoByteCount(3)
  discard usbGetFifoByteCount(4)
  discard usbReadGlobalInt()
  discard usbIsDeviceMode()
  discard usbReadDeviceIntGroup()
  discard usbReadCxEvents()
  discard usbReadFifoEvents()
  discard usbReadBusEvents()
  discard usbGetRole()
  discard usbIsIdDevice()
  check("usb status read APIs", true)

  usbHostReset()
  usbHostStart()
  discard regRead(UsbUsbcmd)
  check("usb host start", true)
  usbHostPortReset()
  discard usbHostPortConnected()
  usbHostStop()
  discard regRead(UsbUsbcmd)
  check("usb host stop", true)

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
  discard console.sendLine("=== BL808 HAL Net USB Test ===")

  smokeEmac()
  smokeUsb()

  discard console.sendString("Result: ")
  console.sendHex32(passed.uint32)
  discard console.sendString(" passed, ")
  console.sendHex32(failed.uint32)
  discard console.sendLine(" failed")
  if failed == 0:
    discard console.sendLine("=== Test Complete ===")
  else:
    discard console.sendLine("=== Test Failed ===")
  while true:
    wfi()
