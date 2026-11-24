## Build-only target for the opt-in full-VM path through the existing bounded
## WASM task table. It has not been run on an Ox64.

import bl808/[startup, core, mmio, wasm_runtime, wasm_full_baseline,
              wasm_scheduler, wasm_store]
import bl808/kernel/alloc
when defined(bl808m0) or defined(bl808d0):
  import bl808/memmap

when not defined(bl808WasmFullScheduler):
  {.error: "build with -d:bl808WasmFullScheduler".}

when defined(bl808m0):
  const StatusAddr = XramBase + 0x3F10'u
elif defined(bl808d0):
  const StatusAddr = XramBase + 0x3F20'u
elif defined(bl808lp):
  const StatusAddr = 0x40002E90'u
else:
  {.error: "select a BL808 core".}

const
  SchedulerBaselineOk = 0x57534600'u32
  SchedulerBaselineFailed = 0x57534601'u32

proc main() {.exportc, cdecl, noreturn.} =
  systemInit()
  heapInit()
  regWrite(StatusAddr, 0x5753467F'u32)
  var status = SchedulerBaselineFailed
  var fuel = 0'u32
  var value = 0'i32
  if wasmRuntimeCapabilities().fullInterpreter:
    var image = newSeq[byte](WasmProgramHeaderLen.int + WasmFullBaselineModule.len)
    if initWasmProgramImage(
        cast[ptr UncheckedArray[byte]](addr image[0]), image.len.uint32,
        WasmFullBaselineModule) == wasmProgramOk:
      resetWasmScheduler()
      let started = startFullWasmImageTaskI32(
        cast[ptr UncheckedArray[byte]](addr image[0]), image.len.uint32,
        "indirect", [20'i32, 22'i32], maxTotalFuel = 64)
      if started.status == wasmSchedOk:
        var current = started
        var attempts = 0
        while current.state in {wasmTaskReady, wasmTaskYielded} and attempts < 32:
          current = resumeWasmTask(started.id, 2)
          inc attempts
        fuel = current.fuelUsed
        value = current.result
        if current.status == wasmSchedOk and current.state == wasmTaskExited and
            value == 42 and current.yields > 0:
          status = SchedulerBaselineOk
        discard killWasmTask(started.id)
  regWrite(StatusAddr + 4'u, heapStats().highWaterBytes.uint32)
  regWrite(StatusAddr + 8'u, fuel)
  regWrite(StatusAddr + 12'u, cast[uint32](value))
  regWrite(StatusAddr, status)
  when defined(bl808d0):
    dcacheFlushAll()
    fenceIo()
  while true:
    wfi()
