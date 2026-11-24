import bl808/[wasm_psram_frames, wasm_remote_page_corpus, wasm_scheduler, wasm_store]

proc runPsramFrameTask*(owner: var WasmPsramFrames): bool =
  var image: array[WasmProgramHeaderLen.int + WasmRemotePageCorpus.len, byte]
  let base = cast[ptr UncheckedArray[byte]](addr image[0])
  if initWasmProgramImage(base, image.len.uint32, WasmRemotePageCorpus) != wasmProgramOk:
    return false
  let task = startFullWasmImageTaskI32(base, image.len.uint32, "cross_page", [],
    maxTotalFuel = 64, maxMemoryPages = 2, memoryFactory = wasmPsramMemoryFactory,
    memoryFactoryContext = addr owner)
  if task.status != wasmSchedOk: return false
  defer: discard killWasmTask(task.id)
  let run = resumeWasmTask(task.id, 64)
  let stats = getWasmTaskMemoryTelemetry(task.id)
  run.status == wasmSchedOk and run.state == wasmTaskExited and run.result == 305419896 and
    stats.found and stats.fullInterpreter and stats.residentChunks == 2 and
    stats.sramResidentChunks == 1 and stats.psramResidentChunks == 1 and
    stats.pageIns == 0 and stats.pageOuts == 0 and stats.wouldBlock == 0
