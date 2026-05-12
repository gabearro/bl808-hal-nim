## LP (E902 RV32E) CPS kernel test.
##
## LP runs a lightweight CPS scheduler and communicates with M0 via IPC.
## Demonstrates:
##   - CPS scheduler on the 16-register E902 core
##   - Timer-based periodic tasks (heartbeat via XRAM flag)
##   - IPC bridge with M0 (LP registers an "add" RPC handler)
##
## LP has no UART — it writes status to XRAM for M0 to read.
##
## Build: nim c -d:bl808lp -d:bl808kernel examples/lp_kernel_test.nim

import bl808/startup
import bl808/mmio, bl808/core
import bl808/irq
import bl808/kernel/cps
import bl808/kernel/ipcbridge

const
  RpcTagAdd* = 2'u16  ## "add two numbers" RPC tag

  ## XRAM addresses for LP status (in the user region)
  LpStatusAddr     = 0x40002F00'u
  LpHeartbeatAddr  = 0x40002F04'u
  LpAliveMarker    = 0xA11CE902'u32

# ---------------------------------------------------------------------------
# RPC handler: add two uint16s packed in a uint32
# ---------------------------------------------------------------------------

proc addHandler(tag: uint16, reqData: ptr UncheckedArray[uint8],
                reqLen: int, respData: ptr UncheckedArray[uint8],
                respBufSize: int): int {.cdecl.} =
  if reqLen < 4: return 0
  let a = reqData[0].uint16 or (reqData[1].uint16 shl 8)
  let b = reqData[2].uint16 or (reqData[3].uint16 shl 8)
  let sum = a.uint32 + b.uint32
  respData[0] = (sum and 0xFF).uint8
  respData[1] = ((sum shr 8) and 0xFF).uint8
  respData[2] = ((sum shr 16) and 0xFF).uint8
  respData[3] = ((sum shr 24) and 0xFF).uint8
  4

# ---------------------------------------------------------------------------
# Heartbeat — writes counter to XRAM so M0 can verify LP is alive
# ---------------------------------------------------------------------------

proc heartbeat(): CpsVoidFuture {.cps.} =
  var count = 0'u32
  while true:
    await sleepMs(500)
    count += 1
    regWrite(LpHeartbeatAddr, count)

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

proc main() {.exportc, cdecl.} =
  systemInit()
  heapInit()
  schedulerInit()
  ipcBridgeInit()

  # Signal LP is alive
  regWrite(LpStatusAddr, LpAliveMarker)

  # Register RPC handler
  ipcRegisterHandler(RpcTagAdd, addHandler)

  # Start heartbeat
  discard heartbeat()

  # Enter scheduler — drives tasks and IPC polling
  runScheduler()
