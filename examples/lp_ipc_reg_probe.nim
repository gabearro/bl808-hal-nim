## LP-side register probe server.
##
## Runs from LP WRAM and answers M0 IPC RPC requests of the form
## "read this 32-bit address from LP's bus view".

import bl808/startup
import bl808/core
import bl808/mmio, bl808/memmap
import bl808/kernel/cps
import bl808/kernel/ipcbridge
import bl808/kernel/sched

const
  RpcTagRead32 = 0x40'u16

  LpStatusAddr = XramBase + 0x2EC0'u
  LpStageAddr = XramBase + 0x2EC4'u
  LpHeartbeatAddr = XramBase + 0x2EC8'u
  LpLastReadAddr = XramBase + 0x2ECC'u
  LpLastReadValueAddr = XramBase + 0x2ED0'u
  LpAliveMarker = 0x1EC0_E902'u32

proc mark(stage: uint32) =
  regWrite(LpStageAddr, stage)
  fenceIo()

proc read32Handler(tag: uint16, reqData: ptr UncheckedArray[uint8],
                   reqLen: int, respData: ptr UncheckedArray[uint8],
                   respBufSize: int): int {.cdecl.} =
  discard tag
  if reqLen < 4 or respBufSize < 4:
    return 0

  let address =
    reqData[0].uint32 or
    (reqData[1].uint32 shl 8) or
    (reqData[2].uint32 shl 16) or
    (reqData[3].uint32 shl 24)
  let value = regRead(address.uint)

  regWrite(LpLastReadAddr, address)
  regWrite(LpLastReadValueAddr, value)

  respData[0] = (value and 0xFF).uint8
  respData[1] = ((value shr 8) and 0xFF).uint8
  respData[2] = ((value shr 16) and 0xFF).uint8
  respData[3] = ((value shr 24) and 0xFF).uint8
  4

proc heartbeat(): CpsVoidFuture {.cps.} =
  var count = 0'u32
  while true:
    await sleepMs(250)
    count += 1'u32
    regWrite(LpHeartbeatAddr, count)

proc main() {.exportc, cdecl.} =
  systemInit()
  mark(1)
  heapInit()
  mark(2)
  schedulerInit()
  mark(3)
  ipcBridgeInit()
  mark(4)
  ipcRegisterHandler(RpcTagRead32, read32Handler)
  mark(5)

  regWrite(LpStatusAddr, LpAliveMarker)
  discard heartbeat()
  mark(6)

  runScheduler()
