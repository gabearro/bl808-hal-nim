## RAM-loaded AGC bringup probe. It leaves the AGC program unmodified.

import bl808/startup, bl808/core
import bl808/glb, bl808/gpio, bl808/uart
import bl808/mmio
import bl808/panicoverride
import bl808/kernel/alloc
import bl808/wifi
import bl808/wifi_fw

const
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz {.intdefine.} = 40_000_000'u32

var console: Uart
var agcAddressCounts0: array[512, uint32]
var agcAddressCounts1: array[512, uint32]

proc emitValue(label: string; value: uint32) =
  discard console.sendString(label)
  discard console.sendString("=")
  console.sendHex32(value)
  discard console.sendLine("")

proc countFetches(): tuple[at4b, at4d, at52: uint32] =
  for sample in 0 ..< 1_000_000:
    let address = (regRead(0x24C0C920'u) shr 23) and 0x1FF'u32
    case address
    of 0x4B'u32: inc result.at4b
    of 0x4D'u32: inc result.at4d
    of 0x52'u32: inc result.at52
    else: discard

proc emitFetchCounts(label: string; counts: tuple[at4b, at4d, at52: uint32]) =
  discard console.sendString(label)
  discard console.sendString(" ")
  console.sendHex32(counts.at4b)
  discard console.sendString(" ")
  console.sendHex32(counts.at4d)
  discard console.sendString(" ")
  console.sendHex32(counts.at52)
  discard console.sendLine("")

proc main() {.exportc, cdecl.} =
  systemInit()
  heapInit()
  enablePeriphClock(periphUart0)
  setMcuXclkSource(mcuXclkXtal)
  setUartClock(true, uartClkXclk, 0)
  gpioSetupUart(14, 15)
  console = initUart(uart0, UartConfig(
    baudRate: ConsoleBaud, dataBits: data8, stopBits: stop1,
    parity: parityNone), ConsoleClkHz)
  discard console.sendLine("AGC PROBE START")
  console.flushTx()

  rfc_init(40_000_000'u32)
  discard console.sendLine("AGC PROBE RFC READY")
  console.flushTx()

  phySetChannel(1'u8, 0'u8, 2412'u16, 2412'u16, 0'u16, 0'u8)
  discard console.sendLine("AGC PROBE CHANNEL READY")
  emitValue("agc_word_0", regRead(0x24C0A000'u))
  emitValue("agc_word_1", regRead(0x24C0A004'u))
  emitValue("agc_word_511", regRead(0x24C0A7FC'u))
  emitValue("agc_enable", regRead(0x24C0B004'u))
  emitValue("agc_ctrl", regRead(0x24C0B100'u))
  let savedPhySel = regRead(0x24900074'u)
  let savedRiuSel = regRead(0x24900078'u)
  emitValue("phy_sel_before", savedPhySel)
  emitValue("riu_sel_before", savedRiuSel)
  for source in 0'u32 .. 3'u32:
    for pair in 0'u32 .. 7'u32:
      let bank0 = pair * 2'u32
      let bank1 = bank0 + 1'u32
      let selector = source or (bank0 shl 8) or
        (source shl 16) or (bank1 shl 24)
      regWrite(0x24900078'u, selector)
      discard console.sendString("DIAG ")
      console.sendHex32(selector)
      discard console.sendString(" ")
      console.sendHex32(regRead(0x2490006C'u))
      discard console.sendString(" ")
      console.sendHex32(regRead(0x24C0C920'u))
      discard console.sendString(" ")
      console.sendHex32(regRead(0x24C0C924'u))
      discard console.sendLine("")
  for bank in 0'u32 .. 15'u32:
    let selector = 0x00010001'u32 or (bank shl 8) or (bank shl 24)
    regWrite(0x24900078'u, selector)
    discard console.sendString("DIAG SAME ")
    console.sendHex32(selector)
    discard console.sendString(" ")
    console.sendHex32(regRead(0x24C0C918'u))
    discard console.sendString(" ")
    console.sendHex32(regRead(0x24C0C91C'u))
    discard console.sendString(" ")
    console.sendHex32(regRead(0x24C0C920'u))
    discard console.sendString(" ")
    console.sendHex32(regRead(0x24C0C924'u))
    discard console.sendLine("")
  regWrite(0x24900078'u, savedRiuSel)
  regWrite(0x24900074'u, savedPhySel)
  regWrite(0x24900078'u, 0x00010001'u)
  var changes0 = 0'u32
  var changes1 = 0'u32
  var previous0 = 0xFFFF'u32
  var previous1 = 0xFFFF'u32
  for sample in 0 ..< 1_000_000:
    let address0 = (regRead(0x24C0C920'u) shr 23) and 0x1FF'u32
    let address1 = (regRead(0x24C0C924'u) shr 23) and 0x1FF'u32
    inc agcAddressCounts0[address0]
    inc agcAddressCounts1[address1]
    if address0 != previous0:
      inc changes0
      previous0 = address0
    if address1 != previous1:
      inc changes1
      previous1 = address1
  regWrite(0x24900078'u, savedRiuSel)
  emitValue("agc_changes_0", changes0)
  emitValue("agc_changes_1", changes1)
  for index in 0 ..< 512:
    if agcAddressCounts0[index] != 0'u32:
      discard console.sendString("AGC ADDR0 ")
      console.sendHex32(index.uint32)
      discard console.sendString(" ")
      console.sendHex32(agcAddressCounts0[index])
      discard console.sendLine("")
    if agcAddressCounts1[index] != 0'u32:
      discard console.sendString("AGC ADDR1 ")
      console.sendHex32(index.uint32)
      discard console.sendString(" ")
      console.sendHex32(agcAddressCounts1[index])
      discard console.sendLine("")
  regWrite(0x24900078'u, 0x05010001'u)
  var equalAddresses = 0'u32
  var mismatchExamples: array[8, uint32]
  var exampleCount = 0
  for sample in 0 ..< 1_000_000:
    let word0 = regRead(0x24C0C920'u)
    let word5 = regRead(0x24C0C924'u)
    let address0 = (word0 shr 23) and 0x1FF'u32
    let address5 = (word5 shr 23) and 0x1FF'u32
    if address0 == address5:
      inc equalAddresses
    elif exampleCount < mismatchExamples.len:
      mismatchExamples[exampleCount] =
        (address0 shl 16) or address5
      inc exampleCount
  regWrite(0x24900078'u, savedRiuSel)
  emitValue("agc_bank0_bank5_equal", equalAddresses)
  for i in 0 ..< exampleCount:
    emitValue("agc_bank0_bank5_mismatch", mismatchExamples[i])
  regWrite(0x24900078'u, 0x00010001'u)
  emitFetchCounts("AGC FETCH BASE", countFetches())
  let originalWord52 = agcmem[0x52]
  emitValue("agc_word52_source", originalWord52)
  if originalWord52 == 0x0800004C'u32:
    agcmem[0x52] = 0x0800004A'u32
    wifi_fw.phy_init(nil)
    discard console.sendLine("AGC PATCH LOADED")
    console.flushTx()
    emitFetchCounts("AGC FETCH PATCHED", countFetches())
    agcmem[0x52] = originalWord52
    wifi_fw.phy_init(nil)
    emitFetchCounts("AGC FETCH RESTORED", countFetches())
  else:
    discard console.sendLine("AGC PATCH SKIPPED")
  regWrite(0x24900078'u, savedRiuSel)
  discard console.sendLine("AGC PATCH RESTORED")
  discard console.sendLine("AGC TRACE END")
  discard console.sendLine("AGC PROBE END")
  console.flushTx()
  while true:
    {.emit: "__asm__ volatile(\"wfi\");".}
