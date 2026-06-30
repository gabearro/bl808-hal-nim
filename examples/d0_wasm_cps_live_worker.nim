## D0 worker for live all-core WASM+CPS smoke.

import bl808/startup
import bl808/core, bl808/mmio
import bl808/kernel/alloc
import bl808/kernel/cps
import bl808/wasm_cps
import bl808/wasm_control
import bl808/wasm_live_smoke
import bl808/wasm_peer_control
import bl808/wasm_scheduler
import bl808/wasm_slot_smoke
import bl808/wasm_store
import bl808/memmap

var heartbeat = 0'u32

proc publishPeerMailboxProbe() =
  let magic = regRead(WasmPeerControlD0Addr + 0'u)
  let seq = regRead(WasmPeerControlD0Addr + 4'u)
  let opcode = regRead(WasmPeerControlD0Addr + 8'u)
  let state = regRead(WasmPeerControlD0Addr + 12'u)
  regWrite(WasmLiveD0Probe2Addr, magic)
  regWrite(WasmLiveD0Probe3Addr, (seq and 0xFFFF'u32) or
    ((opcode and 0xFF'u32) shl 16) or ((state and 0xFF'u32) shl 24))

proc publishSchedulerStage(stage: uint32) =
  regWrite(WasmPeerControlD0Addr + 36'u, stage)
  dcacheFlushAll()
  fenceIo()

proc publish(status: uint32, addValue = 0'i32, sumValue = 0'i32) =
  regWrite(WasmLiveD0AddValueAddr, cast[uint32](addValue))
  regWrite(WasmLiveD0SumValueAddr, cast[uint32](sumValue))
  regWrite(WasmLiveD0HeartbeatAddr, heartbeat)
  regWrite(WasmLiveD0StatusAddr, status)
  dcacheFlushAll()
  fenceIo()

proc publishProbes(status: uint32, p0, p1, p2, p3: uint32) =
  regWrite(WasmLiveD0AddValueAddr, p0)
  regWrite(WasmLiveD0SumValueAddr, p1)
  regWrite(WasmLiveD0Probe2Addr, p2)
  regWrite(WasmLiveD0Probe3Addr, p3)
  regWrite(WasmLiveD0HeartbeatAddr, heartbeat)
  regWrite(WasmLiveD0StatusAddr, status)
  dcacheFlushAll()
  fenceIo()

proc publishProbeProgress(step, p0, p1, p2, p3: uint32) =
  regWrite(WasmLiveD0AddValueAddr, step)
  regWrite(WasmLiveD0SumValueAddr, p0)
  regWrite(WasmLiveD0Probe2Addr, p1)
  regWrite(WasmLiveD0Probe3Addr, p2 xor p3)
  regWrite(WasmLiveD0HeartbeatAddr, heartbeat)
  dcacheFlushAll()
  fenceIo()

proc peerControlPoll() =
  if heartbeat < high(uint32):
    inc heartbeat
  regWrite(WasmLiveD0HeartbeatAddr, heartbeat)
  publishPeerMailboxProbe()
  servicePeerWasmControlCommand(WasmPeerControlD0Addr)

proc heartbeatTask(): CpsVoidFuture {.cps.} =
  while heartbeat < 128'u32:
    inc heartbeat
    regWrite(WasmLiveD0HeartbeatAddr, heartbeat)
    dcacheFlushAll()
    fenceIo()
    await yieldNow()

proc workerTask(): CpsVoidFuture {.cps.} =
  discard heartbeatTask()
  await yieldNow()

  regWrite(WasmLiveD0AddValueAddr, 0xD0A0_0001'u32)
  dcacheFlushAll()
  fenceIo()
  let slot = wasmProgramSlot(WasmLiveAddSlot)
  when defined(bl808LiveD0FlashProbeOnly):
    var p0 = 0'u32
    var p1 = 0'u32
    var p2 = 0'u32
    var p3 = 0'u32
    publishProbeProgress(0xD0A0_0010'u32, p0, p1, p2, p3)
    p0 = readWasmProgramHeader(slot.xipPtr()).magic
    publishProbeProgress(0xD0A0_0011'u32, p0, p1, p2, p3)
    p1 = regRead(FlashXipBase + slot.flashOffset.uint)
    publishProbeProgress(0xD0A0_0012'u32, p0, p1, p2, p3)
    p2 = regRead(FlashXip2Base + slot.flashOffset.uint)
    publishProbeProgress(0xD0A0_0013'u32, p0, p1, p2, p3)
    p3 = regRead(FlashRemapBase + slot.flashOffset.uint)
    publishProbes(WasmLiveProbeOnly, p0, p1, p2, p3)
    return
  let addStatus = runWasmSlotRequest(WasmSlotD0RequestAddr)
  if addStatus != WasmSlotSmokeOk:
    let headerCurrent = readWasmProgramHeader(slot.xipPtr()).magic
    publishProbes(WasmLiveAddFailed, addStatus,
                  regRead(WasmSlotD0RequestAddr + 0'u),
                  regRead(WasmSlotD0RequestAddr + 4'u),
                  headerCurrent)
    return

  regWrite(WasmLiveD0AddValueAddr, 42'u32)
  regWrite(WasmLiveD0SumValueAddr, 0xD0A0_0002'u32)
  dcacheFlushAll()
  fenceIo()
  let sumRun = await startAndRunWasmProgramTaskCps(
    WasmLiveSumSlot,
    "sum",
    [16'i32],
    sliceFuel = 2'u32,
    maxSlices = 256'u32,
    maxTotalFuel = 2048'u32,
  )
  if sumRun.status != wasmControlOk or sumRun.taskState != wasmTaskExited or
      sumRun.value != 120'i32:
    publish(WasmLiveSumFailed, 42'i32, sumRun.value)
    return
  discard killWasmProgramTask(sumRun.taskId)

  if heartbeat < WasmLiveMinHeartbeat:
    publish(WasmLiveHeartbeatStarved, 42'i32, sumRun.value)
  else:
    publish(WasmLiveOk, 42'i32, sumRun.value)

  while true:
    if heartbeat < high(uint32):
      inc heartbeat
    regWrite(WasmLiveD0HeartbeatAddr, heartbeat)
    publishPeerMailboxProbe()
    dcacheFlushAll()
    fenceIo()
    servicePeerWasmControlCommand(WasmPeerControlD0Addr)

proc main() {.exportc, cdecl.} =
  systemInit()
  heapInit()
  schedulerInit()
  setWasmSchedulerDebugHook(publishSchedulerStage)
  setSchedulerPollHook(peerControlPoll)
  discard workerTask()
  runScheduler()
  while true:
    publishPeerMailboxProbe()
    servicePeerWasmControlCommand(WasmPeerControlD0Addr)
    fenceIo()
