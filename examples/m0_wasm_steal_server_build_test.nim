## Build-only M0 job owner. A harness may set the trigger after installing the
## full baseline corpus into slot 2; this image itself never modifies flash.

when not defined(bl808m0) or not defined(bl808kernel):
  {.error: "build as M0 kernel firmware".}

import bl808/[startup, core, mmio, memmap, wasm_steal_broker,
  wasm_steal_server, wasm_store]
import bl808/kernel/[alloc, ipcbridge, sched]
when defined(wasmSoftStealing):
  import bl808/wasm_rt_policy
  import bl808/kernel/clock

const
  StatusAddr = XramBase + 0x2D40'u
  TriggerAddr = StatusAddr + 0x20'u
  TriggerValue = 0x5753_4F46'u32
  StatusReady = 0x5753_4D7F'u32
  StatusOffered = 0x5753_4D00'u32
  StatusFailed = 0x5753_4D01'u32
  BaselineSlot = 2'u32

when defined(wasmSoftStealing):
  const BootEpochAddr = TriggerAddr + 4'u

proc main() {.exportc, cdecl, noreturn.} =
  systemInit()
  heapInit()
  schedulerInit()
  ipcBridgeInit()
  let bootEpoch = when defined(wasmSoftStealing): regRead(BootEpochAddr) else: 0'u32
  if not initM0WasmStealServer(2_000_000'u64, bootEpoch):
    regWrite(StatusAddr, StatusFailed)
  else:
    regWrite(StatusAddr, StatusReady)
    if regRead(TriggerAddr) == TriggerValue:
      var loaded: LoadedWasmProgram
      if loadWasmProgramSlot(BaselineSlot, loaded) == wasmProgramOk:
        loaded.unload()
        var job = WasmStealJob(slot: BaselineSlot, argCount: 2,
          affinityMask: 2'u32 or 4'u32,
          requiredBackends: 1'u32, maxFuel: 64)
        for i, c in "indirect": job.exportName[i] = c
        job.args[0] = 20
        job.args[1] = 22
        when defined(wasmSoftStealing):
          let release = deadlineFromNow(1_500_000)
          job.soft = WasmStealSoftSpec(releaseTick: release,
            deadlineTick: release + usToTicks(1_500_000),
            budgetTicks: usToTicks(100_000), maxSliceTicks: usToTicks(25_000),
            overrun: wrStop)
        var id: uint32
        if offerM0WasmStealJob(job, id) == wssOk:
          regWrite(StatusAddr + 4'u, id)
          regWrite(StatusAddr, StatusOffered)
        else:
          regWrite(StatusAddr, StatusFailed)
      else:
        regWrite(StatusAddr, StatusFailed)
  fenceIo()
  runScheduler()
