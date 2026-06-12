## Key-zeroization-on-fault test (M0).
##
## A trap from the U-mode app (PMP violation / illegal op) is treated as hostile:
## the enclave wipes all key material before halting. This drops to U-mode, has
## it read secure RAM (denied -> fault), and in the fault handler confirms a
## derived key was present beforehand and is gone after vaultZeroizeAll.

import bl808/startup, bl808/core
import bl808/mmio, bl808/memmap
import bl808/glb, bl808/gpio, bl808/uart
import bl808/umode
import bl808/enclave/enclave, bl808/enclave/partition, bl808/enclave/vault
import bl808/enclave/sha256
import bl808/panicoverride
import bl808/kernel/alloc
import std/volatile

const
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz {.intdefine.} = 40_000_000'u32
  SecureProbeAddr = OcramCachedBase + 0x5000'u

var
  console: Uart
  testKey: KeyHandle

proc line(s: string) = discard console.sendLine(s)
proc check(label: string, ok: bool) =
  discard console.sendString(if ok: "[PASS] " else: "[FAIL] ")
  discard console.sendLine(label)

proc onFault(cause, mepc, mtval: uint32) {.nimcall.} =
  ## Runs in M-mode on the U-mode trap. Verify the key was present, wipe, verify
  ## it is gone — the production hook (enclaveOnFault) does the wipe; here we
  ## also assert it took effect.
  var dig: Sha256Digest
  let present = vaultKeyDigest(testKey, dig)
  vaultZeroizeAll()
  let gone = not vaultKeyDigest(testKey, dig)
  check("key present before U-mode fault", present)
  check("vault zeroized after U-mode fault", gone)
  line("=== Test Complete ===")

proc umodeApp() {.exportc: "umode_app", cdecl.} =
  let p = cast[ptr uint32](SecureProbeAddr)
  let v = volatileLoad(p)          # PMP-denied -> fault
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
  gpioSetupUart(14, 15)
  console = initUart(uart0, UartConfig(
    baudRate: ConsoleBaud, dataBits: data8, stopBits: stop1, parity: parityNone), ConsoleClkHz)

  line("")
  line("=== BL808 Zeroize-on-Fault Test ===")

  let ok = enclaveInit(defaultPartition(lock = true), rkSoftDev)
  check("enclaveInit", ok)
  # A derived key to watch get wiped.
  testKey = vaultDeriveKey(vaultRoot(), [0x6b'u8, 0x65, 0x79], [0x31'u8], 32,
                           KeyPolicy(usage: {kuEncrypt}))
  check("derived a test key", testKey != InvalidHandle)
  enclaveSetFaultHook(onFault)     # verifying hook (production uses enclaveOnFault)
  line("[M0] entering U-mode (will fault on secure read)...")

  enclaveRunUmode(umodeAppAddr())
