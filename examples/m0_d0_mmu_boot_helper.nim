## M0 reporter for the D0 Sv39 MMU smoke test.

import bl808/startup
import bl808/core, bl808/mmio, bl808/memmap
import bl808/glb, bl808/gpio, bl808/uart
import bl808/kernel/alloc

const
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz {.intdefine.} = 40_000_000'u32

  StatusAddr = XramBase + 0x3E00'u
  FailCodeAddr = XramBase + 0x3D04'u
  FailGotAddr = XramBase + 0x3D08'u
  FailExpectedAddr = XramBase + 0x3D0C'u

  StatusStarted = 1'u32 shl 0
  StatusTables = 1'u32 shl 1
  StatusSatp = 1'u32 shl 2
  StatusSupervisor = 1'u32 shl 3
  StatusIdentity = 1'u32 shl 4
  StatusAlias = 1'u32 shl 5
  StatusMmio = 1'u32 shl 6
  StatusPager = 1'u32 shl 7
  StatusVmReader = 1'u32 shl 8
  StatusRequired = StatusStarted or StatusTables or StatusSatp or
                   StatusSupervisor or StatusIdentity or StatusAlias or
                   StatusPager or StatusVmReader or StatusMmio
  StatusFailed = 1'u32 shl 30
  StatusDone = 1'u32 shl 31

  FaultRecordAddr = XramBase + 0x2E00'u
  JtagD0RunMagic = 0x4430_5255'u32 # "D0RU"
  JtagD0RunPollLimit = 8_000_000
  PollLimit = 2_000_000

var console: Uart

proc switchJtagMuxToD0() =
  const
    jtagD0Gpio = (27'u32 shl 8) or (1'u32 shl 22) or (1'u32 shl 1) or 1'u32
  regWrite(GpioConfigBase + 6'u * 4'u, jtagD0Gpio)
  regWrite(GpioConfigBase + 7'u * 4'u, jtagD0Gpio)
  regWrite(GpioConfigBase + 12'u * 4'u, jtagD0Gpio)
  regWrite(GpioConfigBase + 13'u * 4'u, jtagD0Gpio)
  fenceIo()

proc spinDelay() =
  for _ in 0 ..< 100:
    {.emit: """asm volatile("");""".}

proc sharedRead32(address: uint): uint32 =
  dcacheInvalidateAll()
  regRead(address)

proc printHex(label: string, value: uint32) =
  discard console.sendString(label)
  console.sendHex32(value)
  discard console.sendLine("")

proc dumpFaultRecord() =
  printHex("  fault_magic=", sharedRead32(FaultRecordAddr + 0'u))
  printHex("  fault_reason=", sharedRead32(FaultRecordAddr + 12'u))
  printHex("  fault_cause_lo=", sharedRead32(FaultRecordAddr + 16'u))
  printHex("  fault_epc_lo=", sharedRead32(FaultRecordAddr + 24'u))
  printHex("  fault_tval_lo=", sharedRead32(FaultRecordAddr + 32'u))

proc waitForJtagD0RunMagic() =
  for _ in 0 ..< JtagD0RunPollLimit:
    if sharedRead32(StatusAddr) == JtagD0RunMagic:
      regWrite(StatusAddr, 0)
      dcacheFlushAll()
      fenceIo()
      return
    spinDelay()
  discard console.sendLine("[FAIL] D0 JTAG load handshake timeout")

proc check(label: string, ok: bool) =
  discard console.sendString(if ok: "[PASS] " else: "[FAIL] ")
  discard console.sendLine(label)

proc main() {.exportc, cdecl.} =
  systemInit()
  heapInit()

  enablePeriphClock(periphUart0)
  setMcuXclkSource(mcuXclkXtal)
  setUartClock(true, uartClkXclk, 0)
  gpioSetupUart(14, 15)
  console = initUart(uart0, UartConfig(
    baudRate: ConsoleBaud, dataBits: data8,
    stopBits: stop1, parity: parityNone,
  ), ConsoleClkHz)

  discard console.sendLine("")
  discard console.sendLine("=== BL808 D0 Sv39 MMU Smoke Test ===")

  regWrite(StatusAddr, 0)
  regWrite(FailCodeAddr, 0)
  regWrite(FailGotAddr, 0)
  regWrite(FailExpectedAddr, 0)
  dcacheFlushAll()
  fenceIo()

  mmPowerOn()
  when defined(bl808jtagram):
    # JTAG-load attaches after D0 is clocked, so park it in M-mode first instead
    # of letting stale DRAM/flash firmware decide the current privilege level.
    regWrite(DramBase, 0x0000_006F'u32) # jal x0, 0
    dcacheFlushAll()
    fenceIo()
    releaseD0(forceLoad = false)
    discard console.sendLine("[INFO] Switching JTAG mux to D0")
    switchJtagMuxToD0()
    discard console.sendLine("[INFO] JTAG mux switched to D0")
    waitForJtagD0RunMagic()
  else:
    releaseD0()

  var status = 0'u32
  for _ in 0 ..< PollLimit:
    status = sharedRead32(StatusAddr)
    if (status and StatusDone) != 0:
      break
    spinDelay()

  if (status and StatusDone) == 0:
    printHex("  d0_mmu_status=", status)
    dumpFaultRecord()
    discard console.sendLine("[FAIL] D0 MMU status timeout")
  elif (status and StatusFailed) != 0:
    discard console.sendString("[FAIL] first code=")
    console.sendHex32(sharedRead32(FailCodeAddr))
    discard console.sendString(" got=")
    console.sendHex32(sharedRead32(FailGotAddr))
    discard console.sendString(" expected=")
    console.sendHex32(sharedRead32(FailExpectedAddr))
    discard console.sendLine("")
    discard console.sendLine("[FAIL] D0 MMU reported a failed check")
  elif (status and StatusRequired) != StatusRequired:
    discard console.sendLine("[FAIL] D0 MMU missing required status bits")

  check("D0 MMU started", (status and StatusStarted) != 0)
  check("D0 Sv39 page tables installed", (status and StatusTables) != 0)
  check("D0 satp enabled", (status and StatusSatp) != 0)
  check("D0 entered supervisor mode", (status and StatusSupervisor) != 0)
  check("D0 identity mapping works", (status and StatusIdentity) != 0)
  check("D0 virtual page alias works", (status and StatusAlias) != 0)
  check("D0 S-mode page fault pager works", (status and StatusPager) != 0)
  check("D0 reader-backed VM page works", (status and StatusVmReader) != 0)
  check("D0 MMIO under MMU works", (status and StatusMmio) != 0)

  if (status and StatusFailed) == 0 and (status and StatusRequired) == StatusRequired:
    discard console.sendLine("[PASS] D0 Sv39 MMU smoke complete")
    discard console.sendLine("=== Test Complete ===")

  while true:
    wfi()
