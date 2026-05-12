## D0 side of the Phase 6 IPC bridge test.
##
## D0 registers an RPC handler that squares numbers and sends them back.
##
## Build: nim c -d:bl808d0 -d:bl808kernel examples/d0_ipc_test.nim
## Run with M0:
##   timeout 60s qemu-system-riscv64 -M bl808 -nographic \
##     -serial file:/tmp/m0.txt -serial mon:stdio \
##     -device loader,file=examples/d0_ipc_test,cpu-num=1 \
##     -kernel examples/m0_ipc_test

import bl808/startup
import bl808/core
import bl808/memmap, bl808/mmio
import bl808/kernel/cps
import bl808/kernel/ipcbridge

const
  RpcTagSquare = 1'u16
  D0IpcDebugAddr = XramBase + 0x00C'u
  D0DebugMain = 1'u32 shl 0
  D0DebugScheduler = 1'u32 shl 1
  D0DebugBridge = 1'u32 shl 2
  D0DebugHandler = 1'u32 shl 3
  D0DebugRequest = 1'u32 shl 4
  D0DebugHeap = 1'u32 shl 5

var debugBits: uint32 = 0

proc markDebug(mask: uint32) =
  debugBits = debugBits or mask
  regWrite(D0IpcDebugAddr, debugBits)
  dcacheFlushAll()
  fenceIo()

# ---------------------------------------------------------------------------
# RPC handler: square a uint32
# ---------------------------------------------------------------------------

proc squareHandler(tag: uint16, reqData: ptr UncheckedArray[uint8],
                   reqLen: int, respData: ptr UncheckedArray[uint8],
                   respBufSize: int): int {.cdecl.} =
  ## Read a uint32 from request, square it, write to response.
  markDebug(D0DebugRequest)
  if reqLen < 4:
    return 0

  let val = reqData[0].uint32 or
            (reqData[1].uint32 shl 8) or
            (reqData[2].uint32 shl 16) or
            (reqData[3].uint32 shl 24)

  let result = val * val

  # Write result
  respData[0] = (result and 0xFF).uint8
  respData[1] = ((result shr 8) and 0xFF).uint8
  respData[2] = ((result shr 16) and 0xFF).uint8
  respData[3] = ((result shr 24) and 0xFF).uint8
  4  # response length

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

proc main() {.exportc, cdecl.} =
  systemInit()
  markDebug(D0DebugMain)

  heapInit()
  markDebug(D0DebugHeap)
  schedulerInit()
  markDebug(D0DebugScheduler)
  ipcBridgeInit()
  markDebug(D0DebugBridge)

  # Register the square RPC handler
  ipcRegisterHandler(RpcTagSquare, squareHandler)
  markDebug(D0DebugHandler)

  runScheduler()
