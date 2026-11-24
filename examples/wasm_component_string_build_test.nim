## Build-only entry for canonical UTF-8 lowering through the shared chunked
## memory backend. Generate the component fixture before cross-linking.
when not defined(wasmChunkedMemory):
  {.error: "build with -d:wasmChunkedMemory".}

import bl808/[startup, core, mmio]
import bl808/kernel/alloc
import cps/wasm/[component, linear_memory, types]
when defined(bl808lp):
  import bl808/wasm_lp_softfloat
when defined(bl808m0) or defined(bl808d0):
  import bl808/memmap

const Fixture = staticRead("../build/wasm-component/string.component.wasm")
var
  resident: array[WasmMemoryChunkBytes.int, byte]
  memory: ref LinearMemory

when defined(bl808m0):
  const StatusAddr = XramBase + 0x3F50'u
elif defined(bl808d0):
  const StatusAddr = XramBase + 0x3F60'u
elif defined(bl808lp):
  const StatusAddr = 0x40002EB0'u
else:
  {.error: "select a BL808 core".}

proc memoryFactory(ctx: pointer, memType: MemType): ref LinearMemory =
  discard ctx
  if memType.limits.min != 1: return nil
  memory

proc main() {.exportc, cdecl, noreturn.} =
  systemInit()
  heapInit()
  regWrite(StatusAddr, 0x5743537F'u32)
  try:
    new(memory)
    let cfg = LinearMemoryConfig(initialPages: 1, maxPages: 1,
      admissionPages: 1, maxCommittedChunks: 1, residentChunks: 1)
    if memory[].initLinearMemoryIn(cfg,
        cast[ptr UncheckedArray[byte]](addr resident[0]),
        resident.len.uint32) != lmOk:
      regWrite(StatusAddr, 0x57435301'u32)
    else:
      let plan = decodeComponent(cast[seq[byte]](Fixture))
      let noBindings: seq[ComponentHostBinding] = @[]
      let instance = instantiateComponent(plan, noBindings,
        memoryFactory, nil)
      let values = instance.invoke("first-byte", [componentString("Aha")])
      regWrite(StatusAddr, if values.len == 1 and values[0].bits == 65:
        0x57435300'u32 else: 0x57435302'u32)
  except ComponentError:
    regWrite(StatusAddr, 0x57435303'u32)
  when defined(bl808d0):
    dcacheFlushAll()
    fenceIo()
  while true: wfi()
