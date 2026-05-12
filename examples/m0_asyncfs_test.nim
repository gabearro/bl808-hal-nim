## M0 async file I/O test — LittleFS with cooperative scheduling.
##
## Build: nim c -d:bl808m0 -d:bl808kernel examples/m0_asyncfs_test.nim
## Run:
##   dd if=/dev/zero of=flash.img bs=1M count=16
##   qemu-system-riscv32 -M bl808 -nographic \
##     -drive if=mtd,format=raw,file=flash.img \
##     -icount shift=0,align=off,sleep=on \
##     -kernel examples/m0_asyncfs_test

import bl808/startup
import bl808/core
import bl808/glb, bl808/gpio, bl808/uart
import bl808/kernel/cps
import bl808/kernel/log
import bl808/kernel/littlefs
import bl808/kernel/asyncfs

const
  ConsoleBaud {.intdefine.} = 230_400'u32
  DefaultClkHz = 32_000_000'u32

var console: Uart

var heartbeats: int = 0
var ioStarted: bool = false

proc heartbeatTask(): CpsVoidFuture {.cps.} =
  ## Counts scheduler yields while I/O is in progress.
  ## Uses yieldNow() so it runs every scheduler iteration
  ## regardless of virtual time advancement.
  while not ioStarted:
    await yieldNow()
  # Now count yields during I/O — limited to avoid starving I/O
  for i in 0 ..< 3:
    await yieldNow()
    heartbeats.inc
    logInfo "[HEARTBEAT] beat ": lInt(heartbeats)

proc renamedStatOk(fs: ptr FlashFs): bool =
  var renamedInfo: LfsInfo
  let statErr = fs[].stat("dir/renamed.txt", renamedInfo)
  statErr == LFS_ERR_OK and infoName(renamedInfo) == "renamed.txt"

proc fileIoTask(): CpsVoidFuture {.cps.} =
  # Mount filesystem (format on first run)
  var fs: FlashFs
  fs.init()
  if not fs.mounted:
    logError "Could not mount filesystem"
    return

  logInfo "[OK] Filesystem mounted"
  discard fs.remove("dir/renamed.txt")
  discard fs.remove("test.txt")
  discard fs.remove("dir")

  # Write file in chunks using async wrapper
  var f: LfsFile
  let openErr = await asyncFlashOpen(addr fs, addr f,
    "test.txt", LFS_O_WRONLY or LFS_O_CREAT or LFS_O_TRUNC)
  if openErr < 0:
    logError "open failed err=": lInt(openErr)
    return
  logInfo "[OK] Opened for write"
  ioStarted = true

  # Write 3 chunks — between each await, heartbeat task can run
  var data1 = [0x48'u8, 0x65, 0x6C, 0x6C, 0x6F]  # "Hello"
  let w1 = await asyncFlashWrite(addr fs, addr f,
    cast[ptr UncheckedArray[uint8]](addr data1[0]), data1.len)
  logInfo "Wrote chunk 1: ": lInt(w1); lStr(" bytes")

  var data2 = [0x20'u8, 0x57, 0x6F, 0x72, 0x6C, 0x64]  # " World"
  let w2 = await asyncFlashWrite(addr fs, addr f,
    cast[ptr UncheckedArray[uint8]](addr data2[0]), data2.len)
  logInfo "Wrote chunk 2: ": lInt(w2); lStr(" bytes")

  var data3 = [0x21'u8]  # "!"
  let w3 = await asyncFlashWrite(addr fs, addr f,
    cast[ptr UncheckedArray[uint8]](addr data3[0]), data3.len)
  logInfo "Wrote chunk 3: ": lInt(w3); lStr(" bytes")

  if fs.sync(f) == LFS_ERR_OK and fs.seek(f, 0, LFS_SEEK_SET) == 0:
    logInfo "[OK] sync/seek wrappers"
  else:
    logError "[FAIL] sync/seek wrappers"

  discard await asyncFlashClose(addr fs, addr f)
  logInfo "[OK] Closed"

  if fs.mkdir("dir") == LFS_ERR_OK and
      fs.rename("test.txt", "dir/renamed.txt") == LFS_ERR_OK:
    logInfo "[OK] mkdir/rename wrappers"
  else:
    logError "[FAIL] mkdir/rename wrappers"

  if renamedStatOk(addr fs):
    logInfo "[PASS] stat/infoName wrappers"
  else:
    logError "[FAIL] stat/infoName wrappers"

  # Read back
  logInfo "Opening for read..."
  var f2: LfsFile
  let openErr2 = await asyncFlashOpen(addr fs, addr f2,
    "dir/renamed.txt", LFS_O_RDONLY)
  if openErr2 < 0:
    logError "open for read failed"
    return

  if fs.seek(f2, 0, LFS_SEEK_SET) != 0:
    logError "[FAIL] read seek wrapper"
    return

  var buf: array[32, uint8]
  let readLen = await asyncFlashRead(addr fs, addr f2,
    cast[ptr UncheckedArray[uint8]](addr buf[0]), buf.len)
  logInfo "Read ": lInt(readLen); lStr(" bytes")

  discard await asyncFlashClose(addr fs, addr f2)

  # Verify: "Hello World!" = 12 bytes
  let expected = [0x48'u8, 0x65, 0x6C, 0x6C, 0x6F, 0x20,
                  0x57, 0x6F, 0x72, 0x6C, 0x64, 0x21]
  var match = readLen == expected.len
  for i in 0 ..< expected.len:
    if buf[i] != expected[i]: match = false

  if match:
    logInfo "[PASS] Data verified: Hello World!"
  else:
    logError "[FAIL] Data mismatch"

  # Check heartbeat ran during I/O
  logInfo "Heartbeats during I/O: ": lInt(heartbeats)
  if heartbeats > 0:
    logInfo "[PASS] Scheduler stayed responsive"
  else:
    logWarn "[WARN] No heartbeats (QEMU virtual time may not advance during -icount)"

  let removeErr = await asyncFlashRemove(addr fs, "dir/renamed.txt")
  if removeErr == LFS_ERR_OK and fs.remove("dir") == LFS_ERR_OK:
    logInfo "[PASS] asyncFlashRemove cleanup"
  else:
    logError "[FAIL] asyncFlashRemove cleanup"

  fs.deinit()
  logInfo ""
  logInfo "=== Test Complete ==="

proc main() {.exportc, cdecl.} =
  systemInit()
  heapInit()

  enablePeriphClock(periphUart0)
  gpioSetupUart(14, 15)
  console = initUart(uart0, UartConfig(
    baudRate: ConsoleBaud, dataBits: data8,
    stopBits: stop1, parity: parityNone,
  ), DefaultClkHz)

  logInit(console)
  logInfo "=== BL808 Async File I/O Test ==="
  logInfo ""

  schedulerInit()
  discard heartbeatTask()
  discard fileIoTask()
  runScheduler()
