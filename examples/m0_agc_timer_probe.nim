## RAM-loaded AGC timer-count measurement against M0 cycles and mtime.

import bl808/startup, bl808/core
import bl808/glb, bl808/gpio, bl808/uart
import bl808/mmio
import bl808/panicoverride
import bl808/kernel/alloc
import bl808/wifi
import bl808/wifi_fw

{.emit: """
static inline unsigned int agc_read_cycle32(void) {
  unsigned int value;
  __asm__ volatile("csrr %0, mcycle" : "=r"(value));
  return value;
}
""".}

proc agcReadCycle32(): uint32 {.importc: "agc_read_cycle32", nodecl.}

const
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz {.intdefine.} = 40_000_000'u32
  TimerCounts: array[11, uint32] = [2000'u32, 50, 100, 200, 500, 1000, 2000,
                                   50, 500, 1000, 2000]
  Terminal = 22
  AgcResetBit = 0x1000'u32
  RiuBank00Both = 0x00010001'u32

var console: Uart
var savedAgc: array[512, uint32]
var firstCycle: array[12, uint32]
var firstMtime: array[12, uint32]
var lastCycle: array[12, uint32]
var sampleCounts: array[12, uint32]
var observed: array[12, bool]

proc printHex(value: uint32) =
  console.sendHex32(value)

proc buildBench() =
  for index in 0 ..< 512:
    savedAgc[index] = agcmem[index]
    agcmem[index] = 0'u32
  for index in 0 ..< 11:
    let start = index * 2
    agcmem[start] = 0x2800008F'u32 or (TimerCounts[index] shl 15)
    if index >= 7:
      agcmem[start] = agcmem[start] or 0x04000000'u32
    agcmem[start + 1] = 0x08000000'u32 or (start + 2).uint32
  agcmem[Terminal] = 0x2800008F'u32 or (2000'u32 shl 15)
  agcmem[Terminal + 1] = 0x08000000'u32 or Terminal.uint32
  agcmem[511] = savedAgc[511]

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
  discard console.sendLine("AGC TIMER START")
  console.flushTx()

  rfc_init(40_000_000'u32)
  discard console.sendLine("AGC TIMER RF READY")
  console.flushTx()
  let savedRiu = regRead(0x24900078'u)
  let savedPd = regRead(0x24C0B390'u)
  regWrite(0x24900078'u, RiuBank00Both)
  buildBench()
  wifi_fw.phy_init(nil)
  discard console.sendLine("AGC TIMER IMAGE LOADED")
  console.flushTx()

  regWrite(0x24C0B390'u, savedPd or AgcResetBit)
  for delay in 0 ..< 1000:
    discard regRead(0x24C0B390'u)
  regWrite(0x24C0B390'u, savedPd and not AgcResetBit)
  let mtimeStart = regRead(0xE000BFF8'u)
  let cycleStart = agcReadCycle32()
  for sample in 0 ..< 2_000_000:
    let address = (regRead(0x24C0C920'u) shr 23) and 0x1FF'u32
    let cycle = agcReadCycle32()
    if address <= (Terminal + 1).uint32:
      let stateIndex = (address div 2'u32).int
      if not observed[stateIndex]:
        observed[stateIndex] = true
        firstCycle[stateIndex] = cycle
        firstMtime[stateIndex] = regRead(0xE000BFF8'u)
      lastCycle[stateIndex] = cycle
      inc sampleCounts[stateIndex]
  let cycleEnd = agcReadCycle32()
  let mtimeEnd = regRead(0xE000BFF8'u)

  regWrite(0x24C0B390'u, savedPd or AgcResetBit)
  for index in 0 ..< 512:
    agcmem[index] = savedAgc[index]
  wifi_fw.phy_init(nil)
  regWrite(0x24C0B390'u, savedPd and not AgcResetBit)
  regWrite(0x24900078'u, savedRiu)
  discard console.sendLine("AGC TIMER IMAGE RESTORED")
  discard console.sendString("AGC TIMER CLOCK ")
  printHex(cycleStart)
  discard console.sendString(" ")
  printHex(cycleEnd)
  discard console.sendString(" ")
  printHex(mtimeStart)
  discard console.sendString(" ")
  printHex(mtimeEnd)
  discard console.sendLine("")
  for index in 0 ..< 12:
    discard console.sendString("AGC TIMER CASE ")
    printHex(index.uint32)
    discard console.sendString(" ")
    printHex(if index < 11: TimerCounts[index] else: 2000'u32)
    discard console.sendString(" ")
    printHex(firstCycle[index])
    discard console.sendString(" ")
    printHex(lastCycle[index])
    discard console.sendString(" ")
    printHex(sampleCounts[index])
    discard console.sendString(" ")
    printHex(firstMtime[index])
    discard console.sendString(" ")
    printHex(if index >= 7 and index < 11: 1'u32 else: 0'u32)
    discard console.sendLine("")
  discard console.sendLine("AGC TIMER END")
  console.flushTx()
  while true:
    {.emit: "__asm__ volatile(\"wfi\");".}
