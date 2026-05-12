## Interactive debug shell for the BL808 kernel.
##
## Runs as a CPS task on an async UART. Type commands to inspect
## kernel state: heap, scheduler, ISR bridge, uptime.
##
##   let au = initAsyncUart(console, IrqM0Uart0, 0)
##   discard shellTask(au)
##   runScheduler()

import ./runtime, ./transform, ./alloc, ./clock, ./sched, ./isrbridge, ./boothealth
import ./asyncuart, ./log, ./watchdog, ./rtc

const
  MaxLineLen = 128
  Cr = 0x0D'u8
  Lf = 0x0A'u8
  Bs = 0x08'u8
  Del = 0x7F'u8

# =============================================================================
# Output helpers — write directly via log sink (zero allocation)
# =============================================================================

proc nl(au: AsyncUart) {.inline.} =
  au.sendString("\r\n")

# =============================================================================
# Built-in commands
# =============================================================================

proc cmdHelp(au: AsyncUart) =
  au.sendString("  help    — show this help\r\n")
  au.sendString("  mem     — heap memory stats\r\n")
  au.sendString("  sched   — scheduler stats\r\n")
  au.sendString("  isr     — ISR bridge stats\r\n")
  au.sendString("  tick    — raw tick count\r\n")
  au.sendString("  uptime  — time since boot\r\n")
  au.sendString("  boot    — retained boot/fault record\r\n")
  au.sendString("  wdt     — watchdog status\r\n")
  au.sendString("  time    — wall-clock time\r\n")

proc cmdMem(au: AsyncUart) =
  let s = heapStats()
  lStr("  used:   "); lU32(s.usedBytes.uint32); lStr(" bytes"); lLn()
  lStr("  free:   "); lU32(s.freeBytes.uint32); lStr(" bytes"); lLn()
  lStr("  total:  "); lU32(s.totalBytes.uint32); lStr(" bytes"); lLn()
  lStr("  high:   "); lU32(s.highWaterBytes.uint32); lStr(" bytes"); lLn()
  lStr("  minfree:"); lU32(s.minFreeBytes.uint32); lStr(" bytes"); lLn()
  lStr("  largest:"); lU32(s.largestFreeBytes.uint32); lStr(" bytes"); lLn()
  lStr("  allocs: "); lU32(s.allocCount.uint32);
  lStr("  frees: "); lU32(s.freeCount.uint32); lLn()
  lStr("  fails:  "); lU32(s.allocFailCount.uint32);
  lStr("  badfree: "); lU32(s.invalidFreeCount.uint32);
  lStr("  canary: "); lU32(s.canaryFailCount.uint32); lLn()
  lStr("  check:  "); lBool(heapCheck()); lLn()

proc cmdSched(au: AsyncUart) =
  let s = schedulerStats()
  lStr("  ticks:     "); lU64(s.ticks); lLn()
  lStr("  callbacks: "); lU64(s.callbacksRun); lLn()
  lStr("  timers:    "); lU64(s.timersFired); lLn()
  lStr("  ready Q:   "); lInt(s.readyQueueLen); lLn()
  lStr("  timer heap:"); lInt(s.timerHeapLen); lLn()

proc cmdIsr(au: AsyncUart) =
  lStr("  active slots: "); lInt(isrBridgeActiveSlotsCount()); lLn()
  lStr("  pending:      "); lInt(isrBridgePendingCompletions()); lLn()

proc cmdBoot(au: AsyncUart) =
  let bh = bootHealthSnapshot()
  let valid = bootHealthRecordValid()
  let hasFault = (bh.flags and BootHealthFlagPreviousFault) != 0'u32
  lStr("  valid:    "); lBool(valid); lLn()
  lStr("  boots:    "); lU32(bh.bootCount); lLn()
  lStr("  core:     "); lU32(bh.core); lLn()
  lStr("  cause:    "); lU32(bh.bootCause); lLn()
  lStr("  prevflt:  "); lBool(hasFault); lLn()
  if hasFault:
    lStr("  reason:   "); lU32(bh.previousFaultReason); lLn()
    lStr("  cause:    "); lHex(bh.previousFaultCauseLo); lLn()
    lStr("  epc:      "); lHex(bh.previousFaultEpcLo); lLn()
    lStr("  tval:     "); lHex(bh.previousFaultTvalLo); lLn()

proc cmdTick(au: AsyncUart) =
  let t = readTick()
  lStr("  "); lU64(t); lStr(" ticks"); lLn()

proc lPad2(v: uint32) {.inline.} =
  ## Print a 2-digit zero-padded number.
  if v < 10: lChar('0')
  lU32(v)

proc cmdTime(au: AsyncUart) =
  let dt = rtcGetTime()
  lStr("  ")
  lU32(dt.year.uint32); lChar('-'); lPad2(dt.month.uint32); lChar('-'); lPad2(dt.day.uint32)
  lChar(' ')
  lPad2(dt.hour.uint32); lChar(':'); lPad2(dt.minute.uint32); lChar(':'); lPad2(dt.second.uint32)
  lLn()
  lStr("  unix="); lInt(rtcGetUnix().int); lLn()

proc cmdWdt(au: AsyncUart) =
  lStr("  active:  "); lBool(watchdogIsActive()); lLn()
  lStr("  feeds:   "); lU64(watchdogFeedCount()); lLn()
  lStr("  counter: "); lU32(watchdogCounter()); lLn()

proc cmdUptime(au: AsyncUart) =
  let ms = ticksToMs(readTick())
  let secs = ms div 1000
  let mins = secs div 60
  lStr("  "); lU64(ms); lStr(" ms")
  if secs >= 1:
    lStr(" ("); lU64(secs); lStr("s")
    if mins >= 1:
      lStr(" = "); lU64(mins); lStr("m "); lU64(secs mod 60); lStr("s")
    lStr(")")
  lLn()

# =============================================================================
# Command dispatcher
# =============================================================================

proc handleCommand(au: AsyncUart, line: string) =
  # Find first space to split command from args
  var spaceIdx = -1
  for i in 0 ..< line.len:
    if line[i] == ' ':
      spaceIdx = i
      break

  let cmd = if spaceIdx < 0: line else: line[0 ..< spaceIdx]

  case cmd
  of "help":   cmdHelp(au)
  of "mem":    cmdMem(au)
  of "sched":  cmdSched(au)
  of "isr":    cmdIsr(au)
  of "boot":   cmdBoot(au)
  of "tick":   cmdTick(au)
  of "uptime": cmdUptime(au)
  of "wdt":    cmdWdt(au)
  of "time":   cmdTime(au)
  of "":       discard
  else:
    au.sendString("unknown: ")
    au.sendString(cmd)
    au.sendString("\r\n")

# =============================================================================
# Shell task — runs as a CPS green thread
# =============================================================================

proc shellTask*(au: AsyncUart): CpsVoidFuture {.cps.} =
  ## Interactive debug shell. Reads commands from UART, dispatches handlers.
  au.sendString("\r\nBL808 Shell — type 'help' for commands\r\n> ")

  var lineBuf: array[MaxLineLen, char]
  var lineLen: int = 0

  while true:
    let ch = await au.recv()

    case ch
    of Cr, Lf:
      au.sendString("\r\n")
      if lineLen > 0:
        var line = newStringOfCap(lineLen)
        for i in 0 ..< lineLen:
          line.add(lineBuf[i])
        handleCommand(au, line)
        lineLen = 0
      au.sendString("> ")

    of Bs, Del:
      if lineLen > 0:
        lineLen.dec
        au.sendString("\x08 \x08")

    of 0x20'u8 .. 0x7E'u8:
      if lineLen < MaxLineLen:
        lineBuf[lineLen] = ch.char
        lineLen.inc
        au.sendByte(ch)

    else:
      discard  # ignore control characters
