## M0 owner for unstarted full-VM jobs. The existing ipcbridge
## XRAM request/response slots are the bounded cross-core transport. Call
## offerM0WasmStealJob only from the M0 kernel loop, never from an ISR.

when not defined(bl808m0):
  {.error: "the WASM steal broker is owned by M0".}

import ./wasm_steal_broker
import ./ipc
import ./kernel/[clock, ipcbridge]

var
  broker: WasmStealBroker
  registered: bool

when defined(wasmSoftStealing):
  proc ownerTick(): uint64 {.nimcall.} = readTick()

proc processStealRequest(req: openArray[byte], resp: var openArray[byte],
                         source: uint32): int =
  let receive = readTick()
  when defined(wasmSoftStealing):
    let rate = min(clockGetTickRate(), high(uint32).uint64).uint32
    broker.processWasmStealWire(req, resp, receive, source, ownerTick, rate)
  else:
    broker.processWasmStealWire(req, resp, receive, source)

proc stealRequestHandler(tag: uint16,
                         reqData: ptr UncheckedArray[uint8], reqLen: int,
                         respData: ptr UncheckedArray[uint8],
                         respBufSize: int): int {.cdecl.} =
  if tag != WasmStealWireTag or reqData == nil or respData == nil or
      reqLen notin {WasmStealRequestBytes, WasmStealResponseBytes} or
      respBufSize < WasmStealResponseBytes:
    return 0
  let source = if ipcRequestFrom(reqData, ipcD0): WasmStealD0
               elif ipcRequestFrom(reqData, ipcLP): WasmStealLP
               else: return 0
  processStealRequest(reqData.toOpenArray(0, reqLen - 1),
    respData.toOpenArray(0, WasmStealResponseBytes - 1), source)

proc processLocalM0WasmStealWire*(req: openArray[byte],
                                 resp: var openArray[byte]): int =
  ## Both local calls and IPC handlers run on the M0 kernel loop.
  if not registered: return 0
  processStealRequest(req, resp, WasmStealM0)

proc initM0WasmStealServer*(leaseTicks: uint64, bootEpoch = 0'u32): bool =
  ## Initialize after schedulerInit and ipcBridgeInit. The M0 clock domain
  ## owns lease expiration; peers must not use their own uncorrelated ticks.
  if registered or leaseTicks == 0: return false
  when defined(wasmSoftStealing):
    if bootEpoch == 0: return false
  var epoch = if bootEpoch != 0: bootEpoch else: (readTick() xor 0x5753_544C'u64).uint32
  if epoch == 0: epoch = 1
  if not broker.initWasmStealBroker(epoch, leaseTicks): return false
  if not ipcTryRegisterHandler(WasmStealWireTag, stealRequestHandler): return false
  registered = true
  true

proc offerM0WasmStealJob*(job: WasmStealJob,
                          outId: var uint32): WasmStealStatus =
  if not registered: return wssInvalid
  when defined(wasmSoftStealing):
    let now = readTick()
    broker.reapWasmStealLeases(now)
    if job.soft.deadlineTick != 0 and job.soft.deadlineTick <= now: return wssInvalid
  broker.offerWasmStealJob(job, outId)

proc m0WasmStealTelemetry*(): WasmStealTelemetry = broker.telemetry

proc m0WasmStealJobState*(id: uint32): WasmStealState =
  broker.stateOfWasmStealJob(id)

proc retireStoppedM0WasmStealJob*(id: uint32,
                                  peerConfirmedStopped: bool): bool =
  ## Call only after a separate peer reset/health check confirms the peer
  ## cannot still be executing the job. A live submitter can read the failure.
  registered and broker.retireStoppedWasmStealJob(id, peerConfirmedStopped)
