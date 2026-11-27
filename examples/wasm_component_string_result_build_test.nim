## Build-only firmware entry for Canonical ABI composite results.
## Generate the WIT-derived fixture with tools/run_wasm_component.py first.
when not defined(wasmChunkedMemory):
  {.error: "build with -d:wasmChunkedMemory".}

import bl808/[startup, core, mmio]
import bl808/kernel/alloc
import cps/wasm/[component, linear_memory, types]
when defined(wasmComponentResourceBundleFirmware):
  import ../tools/wasm_component_resource_bundle_fixture
elif defined(wasmComponentNestedValueFirmware):
  import ../tools/wasm_component_nested_value_fixture
  when defined(bl808d0):
    {.passL: "-Wl,--defsym=__bl808_d0_stack_bytes=12288".}
elif defined(wasmComponentNestedListFirmware):
  import ../tools/wasm_component_nested_list_fixture
elif defined(wasmComponentMapFirmware):
  import ../tools/wasm_component_map_fixture
elif defined(wasmComponentFixedListFirmware):
  when not defined(wasmComponentFixedLists):
    {.error: "fixed-length list firmware requires -d:wasmComponentFixedLists".}
  import ../tools/wasm_component_fixed_list_fixture
elif defined(wasmComponentContextFirmware):
  when not defined(wasmComponentContext):
    {.error: "canonical context firmware requires -d:wasmComponentContext".}
  import ../tools/wasm_component_context_fixture
when defined(bl808lp):
  import bl808/wasm_lp_softfloat
when defined(bl808m0) or defined(bl808d0):
  import bl808/memmap

const Fixture = when defined(wasmComponentResourceBundleFirmware):
  staticRead("../build/wasm-component/resource_bundle.stripped.wasm")
elif defined(wasmComponentNestedValueFirmware):
  staticRead("../build/wasm-component/nested_value.stripped.wasm")
elif defined(wasmComponentNestedListFirmware):
  staticRead("../build/wasm-component/nested_list.stripped.wasm")
elif defined(wasmComponentRecordFirmware):
  staticRead("../build/wasm-component/record.component.wasm")
elif defined(wasmComponentMapFirmware):
  staticRead("../build/wasm-component/upstream/map.stripped.wasm")
elif defined(wasmComponentFixedListFirmware):
  when defined(wasmComponentFixedListIndirectFirmware):
    staticRead("../build/wasm-component/upstream/fixed_list_indirect.stripped.wasm")
  else:
    staticRead("../build/wasm-component/upstream/fixed_list.stripped.wasm")
elif defined(wasmComponentContextFirmware):
  when defined(wasmComponentContextPostReturnFirmware):
    staticRead("../build/wasm-component/upstream/context-post-return.stripped.wasm")
  elif defined(bl808lp):
    staticRead("../build/wasm-component/upstream/context-lp.stripped.wasm")
  else:
    staticRead("../build/wasm-component/upstream/context.stripped.wasm")
else:
  staticRead("../build/wasm-component/string_result.component.wasm")
const StatusPrefix = when defined(wasmComponentResourceBundleFirmware):
  0x57524200'u32
elif defined(wasmComponentNestedValueFirmware):
  0x574E5600'u32
elif defined(wasmComponentNestedListFirmware):
  0x574E4C00'u32
elif defined(wasmComponentRecordFirmware):
  0x57524300'u32
elif defined(wasmComponentMapFirmware):
  0x574D5000'u32
elif defined(wasmComponentFixedListFirmware):
  when defined(wasmComponentFixedListIndirectFirmware): 0x57464900'u32
  else: 0x57464C00'u32
elif defined(wasmComponentContextFirmware):
  when defined(wasmComponentContextPostReturnFirmware): 0x57435000'u32
  else: 0x57435400'u32
else:
  0x57435200'u32
var
  resident: array[WasmMemoryChunkBytes.int, byte]
  memory: ref LinearMemory

when defined(bl808m0):
  const StatusAddr = XramBase + 0x3F70'u
elif defined(bl808d0):
  const StatusAddr = XramBase + 0x3F80'u
elif defined(bl808lp):
  const StatusAddr = 0x40002EC0'u
else:
  {.error: "select a BL808 core".}

proc memoryFactory(ctx: pointer, memType: MemType): ref LinearMemory =
  discard ctx
  if memType.limits.min != 1: return nil
  memory

proc main() {.exportc, cdecl, noreturn.} =
  systemInit()
  heapInit()
  regWrite(StatusAddr, StatusPrefix or 0x7F'u32)
  try:
    new(memory)
    let cfg = LinearMemoryConfig(initialPages: 1, maxPages: 1,
      admissionPages: 1, maxCommittedChunks: 1, residentChunks: 1)
    if memory[].initLinearMemoryIn(cfg,
        cast[ptr UncheckedArray[byte]](addr resident[0]),
        resident.len.uint32) != lmOk:
      regWrite(StatusAddr, StatusPrefix or 1'u32)
    else:
      let noBindings: seq[ComponentHostBinding] = @[]
      let instance = block:
        let plan = decodeComponent(cast[seq[byte]](Fixture))
        instantiateComponent(plan, noBindings, memoryFactory, nil)
      when defined(wasmComponentResourceBundleFirmware):
        regWrite(StatusAddr,
          if checkResourceBundle(instance): StatusPrefix else: StatusPrefix or 2'u32)
      elif defined(wasmComponentNestedValueFirmware):
        regWrite(StatusAddr,
          if checkNestedValue(instance): StatusPrefix else: StatusPrefix or 2'u32)
      elif defined(wasmComponentNestedListFirmware):
        regWrite(StatusAddr,
          if checkNestedList(instance): StatusPrefix else: StatusPrefix or 2'u32)
      elif defined(wasmComponentMapFirmware):
        regWrite(StatusAddr,
          if checkMapRoundtrip(instance): StatusPrefix else: StatusPrefix or 2'u32)
      elif defined(wasmComponentFixedListFirmware):
        let passed = when defined(wasmComponentFixedListIndirectFirmware):
          checkFixedListIndirect(instance)
        else:
          checkFixedListDirect(instance)
        regWrite(StatusAddr, if passed: StatusPrefix else: StatusPrefix or 2'u32)
      elif defined(wasmComponentContextFirmware):
        let passed = when defined(wasmComponentContextPostReturnFirmware):
          checkContextPostReturn(instance)
        else:
          checkContext(instance)
        regWrite(StatusAddr, if passed: StatusPrefix else: StatusPrefix or 2'u32)
      elif defined(wasmComponentRecordFirmware):
        let sum = instance.invoke("sum-pair", [componentRecord([
          componentValue(cpU32, 19), componentValue(cpU32, 23)])])
        let made = instance.invoke("make-pair", [
          componentValue(cpU32, 12), componentValue(cpU32, 30)])
        regWrite(StatusAddr,
          if sum.len == 1 and sum[0].bits == 42 and
              made.len == 1 and made[0].kind == cpRecord and
              made[0].fields.len == 2 and made[0].fields[0].bits == 12 and
              made[0].fields[1].bits == 30:
            StatusPrefix else: StatusPrefix or 2'u32)
      else:
        let first = instance.invoke("greet", [])
        let second = instance.invoke("greet", [])
        regWrite(StatusAddr,
          if first.len == 1 and first[0].text == "Hello, Ox64" and
              second.len == 1 and second[0].text == "Post called":
            StatusPrefix else: StatusPrefix or 2'u32)
  except ComponentError:
    regWrite(StatusAddr, StatusPrefix or 3'u32)
  when defined(bl808d0):
    dcacheFlushAll()
    fenceIo()
  while true: wfi()
