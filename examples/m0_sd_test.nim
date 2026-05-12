## M0 FatFs SD card filesystem test.
##
## Build: nim c -d:bl808m0 -d:bl808kernel examples/m0_sd_test.nim
## Run:
##   dd if=/dev/zero of=sdcard.img bs=1M count=64
##   qemu-system-riscv32 -M bl808 -nographic \
##     -drive if=sd,format=raw,file=sdcard.img \
##     -icount shift=0,align=off,sleep=on \
##     -kernel examples/m0_sd_test

import bl808/startup
import bl808/core
import bl808/glb, bl808/gpio, bl808/uart
import bl808/kernel/alloc
import bl808/kernel/fatfs
import bl808/kernel/sdblk
import bl808/kernel/rtc

const
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz {.intdefine.} = 40_000_000'u32

var console: Uart

proc check(label: string, err: FResult) =
  if err != frOk:
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
  setMcuXclkSource(mcuXclkXtal)
  setUartClock(true, uartClkXclk, 0)
  gpioSetupUart(14, 15)
  console = initUart(uart0, UartConfig(
    baudRate: ConsoleBaud, dataBits: data8,
    stopBits: stop1, parity: parityNone,
  ), ConsoleClkHz)

  discard console.sendLine("")
  discard console.sendLine("=== BL808 FatFs SD Card Test ===")
  discard console.sendLine("")

  # Mount (formats FAT32 on first run)
  var fs: SdFs
  fs.init()
  if not fs.mounted:
    discard console.sendLine("[FAIL] Could not mount filesystem")
    while true: wfi()
  discard console.sendLine("[OK] Filesystem mounted")

  # Write a file
  var f: Fil
  check("open for write", fs.open(f, "test.txt", faWrite or faCreateAlways))

  let data = [0x48'u8, 0x65, 0x6C, 0x6C, 0x6F, 0x21]  # "Hello!"
  let written = fs.write(f, data)
  discard console.sendString("[OK] Wrote ")
  console.sendHex32(written.uint32)
  discard console.sendLine(" bytes")

  check("sync", fs.sync(f))
  check("seek start", fs.seek(f, 0))

  check("close", fs.close(f))

  # Directory and rename wrappers
  discard fs.remove("dir/renamed.txt")
  discard fs.remove("dir")
  check("mkdir", fs.mkdir("dir"))
  check("rename", fs.rename("test.txt", "dir/renamed.txt"))

  # Read it back
  var f2: Fil
  check("open for read", fs.open(f2, "dir/renamed.txt", faRead))
  check("read seek start", fs.seek(f2, 0))

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
  var info: Filinfo
  check("stat", fs.stat("dir/renamed.txt", info))
  discard console.sendString("  size=")
  console.sendHex32(info.fsize)
  discard console.sendString(" name=")
  discard console.sendString(infoName(info))
  discard console.sendLine("")

  var freeClusters: uint32
  check("getFree", fs.getFree("0:", freeClusters))
  discard console.sendString("  free clusters=")
  console.sendHex32(freeClusters)
  discard console.sendLine("")

  # Delete
  check("remove file", fs.remove("dir/renamed.txt"))
  check("remove dir", fs.remove("dir"))

  # Verify empty (only "." and ".." remain, which ls() filters)
  let entries2 = fs.ls("/")
  if entries2.len == 0:
    discard console.sendLine("[PASS] Directory empty after delete")
  else:
    discard console.sendLine("[FAIL] Directory not empty after delete")

  var sector0: array[128, uint32]
  let diskInit = disk_initialize(0)
  let diskStat = disk_status(0)
  var sectorCount: uint32
  var blockSize: uint32
  let ioctlSectors = disk_ioctl(0, 1, addr sectorCount)
  let ioctlBlock = disk_ioctl(0, 3, addr blockSize)
  let diskRead = disk_read(0, addr sector0[0], 0, 1)
  let diskWrite = disk_write(0, addr sector0[0], 0, 1)
  if diskInit == 0 and diskStat == 0 and ioctlSectors == 0 and
      ioctlBlock == 0 and sectorCount > 0 and blockSize > 0 and
      diskRead == 0 and diskWrite == 0:
    discard console.sendLine("[PASS] disk I/O callbacks")
  else:
    discard console.sendLine("[FAIL] disk I/O callbacks")

  # Cleanup
  fs.deinit()
  discard console.sendLine("")
  discard console.sendLine("=== Test Complete ===")

  while true: wfi()
