## LP side of the all-core integration test.
##
## Signals alive via XRAM, registers an "add" RPC handler,
## and runs a heartbeat counter.
##
## Build: nim c -d:bl808lp -d:bl808kernel examples/lp_allcore_test.nim

import bl808/startup
import bl808/core
import bl808/mmio
import bl808/memmap
import bl808/kernel/cps
import bl808/kernel/clock
import bl808/kernel/ipcbridge
import bl808/kernel/sched

const
  RpcTagAdd       = 2'u16
  LpStatusAddr    = 0x40002F00'u
  LpHeartbeatAddr = 0x40002F04'u
  LpStageAddr     = 0x40002F08'u
  LpHandlerCountAddr = 0x40002F0C'u
  LpTickLoAddr    = 0x40002F10'u
  LpTickHiAddr    = 0x40002F14'u
  LpMtimecmpLoAddr = 0x40002F18'u
  LpMtimecmpHiAddr = 0x40002F1C'u
  LpSchedTicksAddr = 0x40002F20'u
  LpTimersFiredAddr = 0x40002F24'u
  LpTimerHeapLenAddr = 0x40002F28'u
  LpClicTimerAddr = 0x40002F2C'u
  LpMstatusAddr   = 0x40002F30'u
  LpMieAddr       = 0x40002F34'u
  LpAliveMarker   = 0xA11CE902'u32

var handlerCallCount = 0'u32

proc markStage(stage: uint32) =
  regWrite(LpStageAddr, stage)

proc lpDiagPoll() =
  let tick = readTick()
  regWrite(LpTickLoAddr, tick.uint32)
  regWrite(LpTickHiAddr, (tick shr 32).uint32)
  regWrite(LpMtimecmpLoAddr, regRead(LpClintMtimecmpBase))
  regWrite(LpMtimecmpHiAddr, regRead(LpClintMtimecmpBase + 4))
  let stats = schedulerStats()
  regWrite(LpSchedTicksAddr, stats.ticks.uint32)
  regWrite(LpTimersFiredAddr, stats.timersFired.uint32)
  regWrite(LpTimerHeapLenAddr, stats.timerHeapLen.uint32)
  regWrite(
    LpClicTimerAddr,
    regRead(ClicIntBase + MachineTimerIrq.uint * ClicIntStride),
  )
  regWrite(LpMstatusAddr, csrReadMstatus().uint32)
  regWrite(LpMieAddr, csrReadMie().uint32)

proc addHandler(tag: uint16, reqData: ptr UncheckedArray[uint8],
                reqLen: int, respData: ptr UncheckedArray[uint8],
                respBufSize: int): int {.cdecl.} =
  discard tag
  discard respBufSize
  markStage(0x20)
  handlerCallCount += 1
  regWrite(LpHandlerCountAddr, handlerCallCount)
  if reqLen < 4:
    markStage(0x2F)
    return 0
  let a = reqData[0].uint16 or (reqData[1].uint16 shl 8)
  let b = reqData[2].uint16 or (reqData[3].uint16 shl 8)
  let sum = a.uint32 + b.uint32
  respData[0] = (sum and 0xFF).uint8
  respData[1] = ((sum shr 8) and 0xFF).uint8
  respData[2] = ((sum shr 16) and 0xFF).uint8
  respData[3] = ((sum shr 24) and 0xFF).uint8
  markStage(0x21)
  4

proc heartbeat(): CpsVoidFuture {.cps.} =
  var count = 0'u32
  while true:
    await sleepMs(500)
    count += 1
    regWrite(LpHeartbeatAddr, count)

proc main() {.exportc, cdecl.} =
  systemInit()
  markStage(1)
  heapInit()
  markStage(2)
  schedulerInit()
  markStage(3)
  ipcBridgeInit()
  markStage(4)
  addSchedulerPollHook(lpDiagPoll)
  lpDiagPoll()

  # Signal alive
  regWrite(LpStatusAddr, LpAliveMarker)
  markStage(5)

  # Register RPC handler
  ipcRegisterHandler(RpcTagAdd, addHandler)
  regWrite(LpHandlerCountAddr, 1)
  markStage(6)

  # Start heartbeat
  discard heartbeat()
  markStage(7)

  runScheduler()
