## M0 owner for peer chunk backing over the existing kernel XRAM IPC bridge.
## Initialize after ipcBridgeInit and after the dedicated SD swap file has
## been opened. The handler runs outside guest deadline slots; its FatFs I/O
## is synchronous, so callers must measure its interference with Wi-Fi.

when not defined(bl808m0):
  {.error: "the WASM page backing owner must be M0".}

import cps/wasm/linear_memory
import ./ipc
import ./wasm_page_wire
import ./wasm_sd_backing
import ./kernel/[clock, ipcbridge]

var
  lpPageServer: WasmPageWireServer
  d0PageServer: ref WasmPageWireServer
  handlerRegistered: bool

proc pageRequestHandler(tag: uint16,
                        reqData: ptr UncheckedArray[uint8], reqLen: int,
                        respData: ptr UncheckedArray[uint8],
                        respBufSize: int): int {.cdecl.} =
  if tag != WasmPageWireTag or reqData == nil or respData == nil or
      reqLen <= 0 or reqLen > WasmPageWirePayloadBytes or
      respBufSize < WasmPageWirePayloadBytes:
    return 0
  let server = if ipcRequestFrom(reqData, ipcLP): addr lpPageServer
               elif ipcRequestFrom(reqData, ipcD0) and d0PageServer != nil:
                 addr d0PageServer[]
               else: nil
  if server == nil: return 0
  server[].processWasmPageWire(reqData.toOpenArray(0, reqLen - 1),
    respData.toOpenArray(0, WasmPageWirePayloadBytes - 1))

proc initWasmPageServerWithSd*(owner: ptr WasmSdBacking,
                               d0Slots = 0'u32): bool =
  ## A missing card or closed swap file leaves this optional service absent.
  ## D0, if enabled, owns the last d0Slots. LP owns the earlier slots.
  if handlerRegistered or owner == nil: return false
  let backing = owner.linearMemoryBacking()
  if d0Slots > backing.slots: return false
  let lpSlots = backing.slots - d0Slots
  let seed = (readTick() xor 0x5750_4147'u64).uint32 or 1'u32
  let chunkBytes = WasmMemoryChunkBytes.uint16
  if lpSlots != 0 and not lpPageServer.initWasmPageWireRange(backing,
      seed, 0, lpSlots, chunkBytes):
    return false
  var d0Server: ref WasmPageWireServer
  if d0Slots != 0:
    new(d0Server)
    if not d0Server[].initWasmPageWireRange(backing,
        seed xor 0x8000_0000'u32, lpSlots, d0Slots, chunkBytes):
      return false
  elif lpSlots == 0:
    return false
  if not ipcTryRegisterHandler(WasmPageWireTag, pageRequestHandler):
    return false
  d0PageServer = d0Server
  handlerRegistered = true
  true
