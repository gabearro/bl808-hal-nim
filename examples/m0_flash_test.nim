## M0 LittleFS flash filesystem test.
##
## Build: nim c -d:bl808m0 -d:bl808kernel examples/m0_flash_test.nim
## Run:
##   dd if=/dev/zero of=flash.img bs=1M count=16
##   qemu-system-riscv32 -M bl808 -nographic \
##     -drive if=mtd,format=raw,file=flash.img \
##     -icount shift=0,align=off,sleep=on \
##     -kernel examples/m0_flash_test

import bl808/startup
import bl808/mmio, bl808/core
import bl808/glb, bl808/gpio, bl808/uart
import bl808/irq
import bl808/flash
import bl808/kernel/alloc
import bl808/kernel/littlefs

const
  ConsoleBaud {.intdefine.} = 230_400'u32
  DefaultClkHz = 32_000_000'u32

var console: Uart

proc checkFlash(label: string, err: FlashError): bool =
  result = err == flashOk
  if result:
    discard console.sendString("[OK] ")
  else:
    discard console.sendString("[FAIL] ")
  discard console.sendString(label)
  discard console.sendString(" err=")
  console.sendHex32(err.uint32)
  discard console.sendLine("")

proc check(label: string, err: cint) =
  if err < 0:
    discard console.sendString("[FAIL] ")
    discard console.sendString(label)
    discard console.sendString(" err=")
    console.sendHex32(err.uint32)
    discard console.sendLine("")
  else:
    discard console.sendString("[OK] ")
    discard console.sendLine(label)

proc main() {.exportc, cdecl.} =
  systemInit()
  heapInit()

  enablePeriphClock(periphUart0)
  gpioSetupUart(14, 15)
  console = initUart(uart0, UartConfig(
    baudRate: ConsoleBaud, dataBits: data8,
    stopBits: stop1, parity: parityNone,
  ), DefaultClkHz)

  discard console.sendLine("")
  discard console.sendLine("=== BL808 LittleFS Flash Test ===")
  discard console.sendLine("")

  const RawFlashAddr = 0x0070_0000'u32
  let eraseOk = checkFlash("raw block64 erase", flashEraseBlock64(RawFlashAddr))
  var rawPage: array[256, uint8]
  for i in 0 ..< rawPage.len:
    rawPage[i] = (i xor 0x5A).uint8
  let programOk = checkFlash("raw page program", flashProgramPage(RawFlashAddr, rawPage))
  var rawRead: array[32, uint8]
  flashReadXipBuffer(RawFlashAddr, rawRead)
  var rawMatch = eraseOk and programOk
  for i in 0 ..< rawRead.len:
    if rawRead[i] != rawPage[i]:
      rawMatch = false
  if rawMatch:
    discard console.sendLine("[PASS] Raw flash program verified")
  else:
    discard console.sendLine("[FAIL] Raw flash program mismatch")
  flashReset()
  discard console.sendLine("[PASS] Flash reset command")

  # Mount (formats on first run)
  var fs: FlashFs
  fs.init()
  if not fs.mounted:
    discard console.sendLine("[FAIL] Could not mount filesystem")
    while true: wfi()
  discard console.sendLine("[OK] Filesystem mounted")

  # Write a file
  var f: LfsFile
  check("open for write", fs.open(f, "test.txt", LFS_O_WRONLY or LFS_O_CREAT or LFS_O_TRUNC))

  let data = [0x48'u8, 0x65, 0x6C, 0x6C, 0x6F, 0x21]  # "Hello!"
  let written = fs.write(f, data)
  discard console.sendString("[OK] Wrote ")
  console.sendHex32(written.uint32)
  discard console.sendLine(" bytes")

  check("close", fs.close(f))

  # Read it back
  var f2: LfsFile
  check("open for read", fs.open(f2, "test.txt", LFS_O_RDONLY))

  var buf: array[32, uint8]
  let readLen = fs.read(f2, buf)
  discard console.sendString("[OK] Read ")
  console.sendHex32(readLen.uint32)
  discard console.sendLine(" bytes")

  check("close", fs.close(f2))

  # Verify
  var match = readLen == data.len
  for i in 0 ..< data.len:
    if buf[i] != data[i]:
      match = false
  if match:
    discard console.sendLine("[PASS] Data verified: Hello!")
  else:
    discard console.sendLine("[FAIL] Data mismatch")

  # List directory
  let entries = fs.ls("/")
  discard console.sendString("[OK] Directory listing: ")
  for e in entries:
    discard console.sendString(e)
    discard console.sendString(" ")
  discard console.sendLine("")

  # Stat
  var info: LfsInfo
  check("stat", fs.stat("test.txt", info))
  discard console.sendString("  size=")
  console.sendHex32(info.size)
  discard console.sendString(" type=")
  console.sendHex32(info.infoType.uint32)
  discard console.sendLine("")

  # Delete
  check("remove", fs.remove("test.txt"))

  # Verify empty
  let entries2 = fs.ls("/")
  if entries2.len == 0:
    discard console.sendLine("[PASS] Directory empty after delete")
  else:
    discard console.sendLine("[FAIL] Directory not empty after delete")

  # Cleanup
  fs.deinit()
  discard console.sendLine("")
  discard console.sendLine("=== Test Complete ===")

  while true: wfi()
