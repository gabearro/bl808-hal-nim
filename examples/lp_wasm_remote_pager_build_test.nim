## Link-only LP check for the full task table, one small resident chunk,
## and the XRAM IPC page client. Hardware execution needs an M0 owner and a
## scoped harness test; this file is deliberately not in the default tier.

import cps/wasm/linear_memory

when not defined(bl808lp) or not defined(bl808WasmFullScheduler) or
    not defined(wasmChunkedMemory) or WasmMemoryChunkBytesConfig > 1024:
  {.error: "build LP full scheduler with 512 or 1024-byte chunks".}

import bl808/[startup, core, mmio, wasm_lp_page_client,
  wasm_lp_softfloat, wasm_remote_page_corpus, wasm_scheduler, wasm_store]
import bl808/kernel/alloc
import cps/wasm/types

const
  StatusAddr = 0x40002E90'u
  TriggerAddr = StatusAddr + 0x30'u
  TriggerValue = 0x5750_4745'u32

var
  client: WasmLpPageClient
  resident: array[WasmMemoryChunkBytes.int, byte]
  memory: ref LinearMemory

proc makeMemory(ctx: pointer, memType: MemType): ref LinearMemory =
  discard ctx
  if memType.limits.min != 2 or memType.limits.max != 2: return nil
  memory

proc main() {.exportc, cdecl, noreturn.} =
  systemInit()
  heapInit()
  regWrite(StatusAddr, 0x5750_477F'u32)
  if regRead(TriggerAddr) == TriggerValue:
    if not client.initWasmLpPageClient(8):
      regWrite(StatusAddr, 0x5750_4701'u32)
    else:
      new(memory)
      let config = LinearMemoryConfig(initialPages: 2, maxPages: 2,
        admissionPages: 2, maxCommittedChunks: 8, residentChunks: 1)
      if memory[].initLinearMemoryIn(config,
          cast[ptr UncheckedArray[byte]](addr resident[0]),
          resident.len.uint32, client.addr.linearMemoryBacking()) != lmOk:
        regWrite(StatusAddr, 0x5750_4702'u32)
      else:
        var image = newSeq[byte](WasmProgramHeaderLen.int +
          WasmRemotePageCorpus.len)
        if initWasmProgramImage(
            cast[ptr UncheckedArray[byte]](addr image[0]),
            image.len.uint32, WasmRemotePageCorpus) == wasmProgramOk:
          resetWasmScheduler()
          let started = startFullWasmImageTaskI32(
            cast[ptr UncheckedArray[byte]](addr image[0]),
            image.len.uint32, "cross_page", [], maxTotalFuel = 64,
            maxMemoryPages = 2, memoryFactory = makeMemory)
          regWrite(StatusAddr + 4'u, started.id)
          if started.status == wasmSchedOk:
            let step = resumeWasmTask(started.id, 10)
            regWrite(StatusAddr, if step.state == wasmTaskBlockedMemory:
              0x5750_4700'u32 else: 0x5750_4703'u32)
  while true: wfi()
