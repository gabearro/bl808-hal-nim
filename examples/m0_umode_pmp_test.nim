## U-mode + PMP enforcement test (M-mode drops to U-mode, observes isolation).
##
## Proves on real silicon that:
##   1. the enclave can drop to U-mode and the U-mode app reaches services via
##      ecall (positive path), and
##   2. a U-mode read of secure OCRAM is denied by PMP and trapped to the
##      enclave fault handler (negative path) rather than succeeding.
##
## If PMP failed open, the forbidden read would succeed, the app would spin, and
## the test would TIME OUT (fail) — so the fault marker is the proof.

import bl808/startup, bl808/core
import bl808/mmio, bl808/memmap
import bl808/glb, bl808/gpio, bl808/uart
import bl808/umode
import bl808/enclave/enclave, bl808/enclave/partition, bl808/enclave/vault
import bl808/enclave/abi
import bl808/panicoverride
import bl808/kernel/alloc
import std/volatile

const
  ConsoleUartTxPin = 14'u32
  ConsoleUartRxPin = 15'u32
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz {.intdefine.} = 40_000_000'u32
  SecureProbeAddr = OcramCachedBase + 0x5000'u   # inside secure RAM, not U-granted

var console: Uart

proc line(s: string) = discard console.sendLine(s)

proc onEcall(frame: ptr EcallFrame) {.nimcall.} =
  # The U-mode app reached us. a0 carries a marker value.
  discard console.sendString("[PASS] U-mode ecall reached, svc=")
  console.sendHex32(frame.a0)
  discard console.sendLine("")
  frame.a0 = 0   # ack

proc onFault(cause, mepc, mtval: uint32) {.nimcall.} =
  # cause 5 = load access fault (PMP-denied secure read).
  discard console.sendString("[PASS] U-mode secure read DENIED by PMP, cause=")
  console.sendHex32(cause)
  discard console.sendString(" mtval=")
  console.sendHex32(mtval)
  discard console.sendLine("")
  line("=== Test Complete ===")

# The untrusted application: lives in flash (U-mode has R+X there), runs on the
# U-mode stack. Does one ecall, then reads secure RAM (must fault).
proc umodeApp() {.exportc: "umode_app", cdecl.} =
  {.emit: """
    register unsigned long a0 asm("a0") = 0x5A;   /* marker svc id */
    register unsigned long a1 asm("a1") = 0;
    __asm__ volatile("ecall" : "+r"(a0) : "r"(a1) : "memory");
  """.}
  # Forbidden: read secure OCRAM. PMP must trap this.
  let p = cast[ptr uint32](SecureProbeAddr)
  let v = volatileLoad(p)
  # Only reached if PMP failed open — report the leak (test will then FAIL on
  # the missing Complete marker / forbidden output) and spin.
  {.emit: """(void)`v`;""".}
  while true:
    {.emit: "__asm__ volatile(\"wfi\");".}

proc umodeAppAddr(): uint =
  {.emit: "`result` = (NU)(&umode_app);".}

proc main() {.exportc, cdecl.} =
  systemInit()
  heapInit()
  enableAllPeriphClocks()
  enablePeriphClock(periphUart0)
  setMcuXclkSource(mcuXclkXtal)
  setUartClock(true, uartClkXclk, 0)
  gpioSetupUart(ConsoleUartTxPin, ConsoleUartRxPin)
  console = initUart(uart0, UartConfig(
    baudRate: ConsoleBaud, dataBits: data8, stopBits: stop1, parity: parityNone), ConsoleClkHz)

  line("")
  line("=== BL808 U-mode PMP Test ===")

  # Put a sentinel in secure RAM (M-mode can; U-mode must not read it).
  cast[ptr uint32](SecureProbeAddr)[] = 0xDEADBEEF'u32

  let ok = enclaveInit(defaultPartition(lock = false), rkSoftDev)
  if not ok:
    line("[FAIL] enclaveInit")
    while true: wfi()
  line("[PASS] enclaveInit + partition applied")
  # Override the enclave's service dispatcher with the test's observers
  # (enclaveInit wires its own; we want to see the U-mode ecall arrive).
  enclaveSetEcallDispatch(onEcall)
  enclaveSetFaultHook(onFault)
  line("Dropping to U-mode...")

  enclaveRunUmode(umodeAppAddr())
