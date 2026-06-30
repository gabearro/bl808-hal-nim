## LP worker for live all-core WASM+CPS smoke.

import bl808/startup
import bl808/core, bl808/mmio
import bl808/kernel/alloc
import bl808/kernel/cps
import bl808/memmap
import bl808/wasm_cps
import bl808/wasm_control
import bl808/wasm_live_smoke
import bl808/wasm_peer_control
import bl808/wasm_slot_smoke
import bl808/wasm_store

when defined(bl808lp):
  {.pragma: lpRam, codegenDecl: "$# __attribute__((section(\".ramfunc\"), noinline, used)) $#$#".}
else:
  {.pragma: lpRam.}

var heartbeat = 0'u32

proc bumpHeartbeat() {.inline.} =
  if heartbeat < high(uint32):
    inc heartbeat
  else:
    heartbeat = WasmLiveMinHeartbeat

proc publish(status: uint32, addValue = 0'i32, sumValue = 0'i32) =
  regWrite(WasmLiveLpAddValueAddr, cast[uint32](addValue))
  regWrite(WasmLiveLpSumValueAddr, cast[uint32](sumValue))
  regWrite(WasmLiveLpHeartbeatAddr, heartbeat)
  regWrite(WasmLiveLpStatusAddr, status)
  fenceIo()

proc peerControlPoll() =
  bumpHeartbeat()
  regWrite(WasmLiveLpHeartbeatAddr, heartbeat)
  fenceIo()
  servicePeerWasmControlCommand(WasmPeerControlLpAddr)

proc heartbeatTask(): CpsVoidFuture {.cps.} =
  while heartbeat < 128'u32:
    bumpHeartbeat()
    regWrite(WasmLiveLpHeartbeatAddr, heartbeat)
    fenceIo()
    await yieldNow()

proc workerTask(): CpsVoidFuture {.cps.} =
  regWrite(WasmLiveLpAddValueAddr, 0x1A00_0000'u32)
  fenceIo()
  discard heartbeatTask()
  regWrite(WasmLiveLpAddValueAddr, 0x1A00_000A'u32)
  fenceIo()
  await yieldNow()

  regWrite(WasmLiveLpAddValueAddr, 0x1A00_0001'u32)
  fenceIo()
  let addStatus = runWasmSlotRequest(WasmSlotLpRequestAddr)
  if addStatus != WasmSlotSmokeOk:
    let header = readWasmProgramHeader(wasmProgramSlot(WasmLiveAddSlot).xipPtr())
    publish(WasmLiveAddFailed, addStatus.int32, cast[int32](header.magic))
    return

  regWrite(WasmLiveLpAddValueAddr, 42'u32)
  regWrite(WasmLiveLpSumValueAddr, 0x1A00_0002'u32)
  fenceIo()
  let sumRun = await startAndRunWasmProgramTaskCps(
    WasmLiveSumSlot,
    "sum",
    [12'i32],
    sliceFuel = 2'u32,
    maxSlices = 256'u32,
    maxTotalFuel = 2048'u32,
  )
  if sumRun.status != wasmControlOk or sumRun.taskState != wasmTaskExited or
      sumRun.value != 66'i32:
    publish(WasmLiveSumFailed, 42'i32, sumRun.value)
    return
  discard killWasmProgramTask(sumRun.taskId)

  if heartbeat < WasmLiveMinHeartbeat:
    publish(WasmLiveHeartbeatStarved, 42'i32, sumRun.value)
  else:
    publish(WasmLiveOk, 42'i32, sumRun.value)

  while true:
    bumpHeartbeat()
    regWrite(WasmLiveLpHeartbeatAddr, heartbeat)
    fenceIo()
    servicePeerWasmControlCommand(WasmPeerControlLpAddr)
    await yieldNow()

proc waitForStartGate() {.lpRam.} =
  ## Stay in WRAM while M0 applies the enclave TZC partition. The normal LP
  ## worker can execute from XIP again after M0 publishes the gate.
  regWrite(WasmLiveLpAddValueAddr, 0x1A00_00F0'u32)
  fenceIo()
  while true:
    let gate = regRead(WasmLiveLpStartAddr)
    if gate == WasmLiveLpStartMagic:
      break
    bumpHeartbeat()
    regWrite(WasmLiveLpHeartbeatAddr, heartbeat)
    fenceIo()
    for _ in 0 ..< 100:
      {.emit: """asm volatile("");""".}
  regWrite(WasmLiveLpAddValueAddr, 0x1A00_00F1'u32)
  fenceIo()
  let xipWord = regRead(FlashXipBase + Ox64LPBootOffset)
  regWrite(WasmLiveLpSumValueAddr, xipWord)
  regWrite(WasmLiveLpAddValueAddr, 0x1A00_00F2'u32)
  fenceIo()
  fenceI()

proc main() {.exportc, cdecl.} =
  systemInit()
  waitForStartGate()
  heapInit()
  regWrite(WasmLiveLpAddValueAddr, 0x1A00_00F2'u32)
  fenceIo()
  schedulerInit()
  setSchedulerPollHook(peerControlPoll)
  regWrite(WasmLiveLpAddValueAddr, 0x1A00_00F3'u32)
  fenceIo()
  discard workerTask()
  regWrite(WasmLiveLpAddValueAddr, 0x1A00_00F4'u32)
  fenceIo()
  runScheduler()
  while true:
    bumpHeartbeat()
    regWrite(WasmLiveLpHeartbeatAddr, heartbeat)
    servicePeerWasmControlCommand(WasmPeerControlLpAddr)
    fenceIo()
