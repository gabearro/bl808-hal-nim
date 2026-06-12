## M0 PDS sleep — verifies timed wake from the PDS controller.
##
## Powers down the MM/DSP domain and clock-gates the M0 in WFI (xtal kept on so
## the UART survives), then the PDS sleep timer wakes it and execution resumes in
## place. The wake fix that made this work: pulse cr_pds_int_clr (don't leave it
## set, or ro_pds_wake_int is perpetually cleared) + power the f32k/RC32K wake
## clock on correctly. Root-caused with the LP/E902 as an external observer
## (lp_pds_observer) since the M0's JTAG goes dark in PDS.

import bl808/startup, bl808/core, bl808/irq
import bl808/glb, bl808/gpio, bl808/uart, bl808/mmio, bl808/pds
import bl808/kernel/log
import bl808/kernel/clock
from std/volatile import volatileLoad, volatileStore

const
  ConsoleBaud {.intdefine.} = 230_400'u32
  DefaultClkHz = 40_000_000'u32
  SleepMs = 100'u32

var
  console: Uart
  pdsWakeCountStorage: uint32

proc pdsWakeCount(): uint32 {.inline.} =
  volatileLoad(addr pdsWakeCountStorage)

proc onPdsWake() {.cdecl.} =
  volatileStore(addr pdsWakeCountStorage, volatileLoad(addr pdsWakeCountStorage) + 1)
  pdsClearIrq()

proc main() {.exportc, cdecl.} =
  systemInit()
  enableAllPeriphClocks(); enablePeriphClock(periphUart0)
  setMcuXclkSource(mcuXclkXtal); setUartClock(true, uartClkXclk, 0)
  gpioSetupUart(14, 15)
  console = initUart(uart0, UartConfig(
    baudRate: ConsoleBaud, dataBits: data8, stopBits: stop1, parity: parityNone), DefaultClkHz)
  delayUs(400_000)
  logInit(console)

  registerTrapHandler(IrqM0PdsWakeup, onPdsWake)
  clicSetLevel(IrqM0PdsWakeup, 1)
  clicEnableIrq(IrqM0PdsWakeup)
  csrWriteMie(csrReadMie() or (1'u32 shl 11))
  enableInterrupts()

  logInfo "=== BL808 PDS Test ==="
  logInfo "Requesting ": lU32(SleepMs); lStr(" ms timed PDS sleep")

  let t0 = ticksToMs(readTick())
  console.flushTx()
  pdsEnterLightTimerWake(SleepMs)
  let sleptMs = ticksToMs(readTick()) - t0
  let wakeIrqs = pdsWakeCount()

  logInfo "Slept ms: ": lU64(sleptMs)
  logInfo "PDS wake IRQ count: ": lU32(wakeIrqs)
  if wakeIrqs >= 1'u32:
    logInfo "[PASS] M0 woke from PDS sleep (MM powered down, timer wake)"
  else:
    logError "[FAIL] M0 did not wake from PDS"
  logInfo "=== Test Complete ==="
  while true: wfi()
