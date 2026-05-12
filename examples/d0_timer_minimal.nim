## Absolute minimal D0 timer interrupt test.

import bl808/startup
import bl808/mmio, bl808/core
import bl808/irq
import bl808/kernel/alloc

# Raw UART1 output (no HAL wrapper, just direct register writes)
const Uart1Base = 0x2000_A100'u

proc putch(ch: char) =
  regWrite(Uart1Base + 0x88, ch.uint32)  # FIFO_WDATA

proc puts(s: string) =
  for ch in s: putch(ch)

proc putnl() =
  putch('\r')
  putch('\n')

# Enable UART1 TX
proc initUart1() =
  regWrite(Uart1Base + 0x00, 1)  # UTX_CONFIG: enable

# Timer ISR
var isrCount: int = 0

proc timerIsr() {.cdecl.} =
  # Clear timer by setting mtimecmp to max — NO OUTPUT from ISR
  regWrite(0xE010_0004'u, 0xFFFF_FFFF'u32)
  regWrite(0xE010_0000'u, 0xFFFF_FFFF'u32)
  isrCount += 1

proc main() {.exportc, cdecl.} =
  systemInit()
  heapInit()
  initUart1()

  puts("D0 minimal timer test")
  putnl()

  # Register timer ISR
  registerTrapHandler(7, timerIsr)

  # Enable MTIE in mie
  let mie = csrReadMie()
  csrWriteMie(mie or (1'u shl 7))

  # Read current mtime
  let lo = regRead(0xE010_7FF8'u)
  puts("mtime lo=")
  regWrite(Uart1Base + 0x88, ((lo shr 12) and 0xF).uint32 + (if ((lo shr 12) and 0xF) < 10: 0x30'u32 else: 0x57'u32))
  regWrite(Uart1Base + 0x88, ((lo shr 8) and 0xF).uint32 + (if ((lo shr 8) and 0xF) < 10: 0x30'u32 else: 0x57'u32))
  regWrite(Uart1Base + 0x88, ((lo shr 4) and 0xF).uint32 + (if ((lo shr 4) and 0xF) < 10: 0x30'u32 else: 0x57'u32))
  regWrite(Uart1Base + 0x88, (lo and 0xF).uint32 + (if (lo and 0xF) < 10: 0x30'u32 else: 0x57'u32))
  putnl()

  # Disable interrupts while programming the timer
  disableInterrupts()

  # Clear any pending timer first
  regWrite(0xE010_0004'u, 0xFFFF_FFFF'u32)
  regWrite(0xE010_0000'u, 0xFFFF_FFFF'u32)

  # Re-read mtime AFTER clearing mtimecmp
  let fresh = regRead(0xE010_7FF8'u)

  # Set mtimecmp = fresh mtime + 50000 (50ms)
  let deadline = fresh.uint64 + 50000'u64
  regWrite(0xE010_0004'u, 0xFFFF_FFFF'u32)
  regWrite(0xE010_0000'u, (deadline and 0xFFFFFFFF'u64).uint32)
  regWrite(0xE010_0004'u, (deadline shr 32).uint32)

  puts("WFI...")
  putnl()

  # Re-enable interrupts and busy-wait (skip WFI to debug)
  enableInterrupts()
  while isrCount == 0:
    discard  # busy-wait for ISR
  puts("Awake! isrCount=")
  putch(chr(isrCount + ord('0')))
  putnl()

  while true: wfi()
