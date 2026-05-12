## D0 side of the all-core integration test.
##
## Registers a "square" RPC handler and waits for requests from M0.
##
## Build: nim c -d:bl808d0 -d:bl808kernel examples/d0_allcore_test.nim

import bl808/startup
import bl808/kernel/cps
import bl808/kernel/ipcbridge

const
  RpcTagSquare = 1'u16

proc squareHandler(tag: uint16, reqData: ptr UncheckedArray[uint8],
                   reqLen: int, respData: ptr UncheckedArray[uint8],
                   respBufSize: int): int {.cdecl.} =
  if reqLen < 4: return 0
  let val = reqData[0].uint32 or (reqData[1].uint32 shl 8) or
            (reqData[2].uint32 shl 16) or (reqData[3].uint32 shl 24)
  let result = val * val
  respData[0] = (result and 0xFF).uint8
  respData[1] = ((result shr 8) and 0xFF).uint8
  respData[2] = ((result shr 16) and 0xFF).uint8
  respData[3] = ((result shr 24) and 0xFF).uint8
  4

proc main() {.exportc, cdecl.} =
  systemInit()

  heapInit()
  schedulerInit()
  ipcBridgeInit()
  ipcRegisterHandler(RpcTagSquare, squareHandler)

  runScheduler()
