## Firmware probe for memoryless Component Model fixtures. Generate the
## selected fixture before cross-linking this image.
import bl808/[startup, core, mmio]
import bl808/kernel/alloc
import cps/wasm/component
when defined(bl808lp):
  import bl808/wasm_lp_softfloat
when defined(bl808m0) or defined(bl808d0):
  import bl808/memmap

when defined(wasmComponentErrorContextFirmware):
  import ../tools/wasm_component_error_context_fixture
  const Fixture = staticRead("../build/wasm-component/upstream/error-context-lp.wasm")
  const StatusPrefix = 0x57454300'u32
elif defined(wasmComponentResourceAscriptionFirmware):
  import ../tools/wasm_component_resource_ascription_fixture
  const Fixture = staticRead("../build/wasm-component/upstream/resource-ascription-lp.wasm")
  const StatusPrefix = 0x57524100'u32
elif defined(wasmComponentThreadSpawnFirmware):
  import ../tools/wasm_component_callback_fixture
  const Fixture = staticRead("../build/wasm-component/thread-spawn/probe.wasm")
  const StatusPrefix = 0x57535000'u32
elif defined(wasmComponentGuestThreadsFirmware):
  when not defined(wasmComponentThreads):
    {.error: "guest thread firmware requires wasmComponentThreads".}
  import ../tools/wasm_component_callback_fixture
  const Fixture = staticRead("../build/wasm-component/upstream/guest-threads-lp.stripped.wasm")
  const StatusPrefix = 0x57544800'u32
elif defined(wasmComponentHostEndpointFirmware):
  when not (defined(wasmComponentStreams) and defined(wasmComponentHostEndpoints)):
    {.error: "host endpoint firmware requires wasmComponentHostEndpoints and wasmComponentStreams".}
  import ../tools/wasm_component_callback_fixture
  const Fixture = staticRead("../build/wasm-component/upstream/host-endpoint.stripped.wasm")
  const StatusPrefix = 0x57484500'u32
elif defined(wasmComponentStreamFirmware):
  when not defined(wasmComponentStreams):
    {.error: "stream firmware requires wasmComponentStreams".}
  import ../tools/wasm_component_callback_fixture
  const Fixture = staticRead("../build/wasm-component/upstream/stream-lp.stripped.wasm")
  const StatusPrefix = 0x57535200'u32
elif defined(wasmComponentFutureWaitFirmware):
  when not (defined(wasmComponentFutures) and defined(wasmComponentStackful)):
    {.error: "future wait firmware requires wasmComponentFutures and wasmComponentStackful".}
  import ../tools/wasm_component_callback_fixture
  const Fixture = when defined(bl808lp):
    staticRead("../build/wasm-component/upstream/future-wait-lp.stripped.wasm")
  else:
    staticRead("../build/wasm-component/upstream/future-wait.stripped.wasm")
  const StatusPrefix = 0x57465700'u32
elif defined(wasmComponentAsyncBorrowsFirmware):
  when not defined(wasmComponentAsyncCallbacks):
    {.error: "async borrow firmware requires -d:wasmComponentAsyncCallbacks".}
  import ../tools/wasm_component_callback_fixture
  const Fixture = staticRead("../build/wasm-component/upstream/async-borrows-local-lp.stripped.wasm")
  const StatusPrefix = 0x57414200'u32
elif defined(wasmComponentSyncLowerFirmware) or defined(wasmComponentStackfulFirmware):
  when not defined(wasmComponentStackful):
    {.error: "stackful firmware requires -d:wasmComponentStackful".}
  import ../tools/wasm_component_callback_fixture
  when defined(wasmComponentSyncLowerFirmware):
    const Fixture = staticRead("../build/wasm-component/upstream/async-sync-lower-lp.stripped.wasm")
    const StatusPrefix = 0x57534C00'u32
  else:
    const Fixture = staticRead("../build/wasm-component/upstream/async-stackful-lp.stripped.wasm")
    const StatusPrefix = 0x57534600'u32
elif defined(wasmComponentCallbackFirmware) or defined(wasmComponentSubtasksFirmware):
  when not defined(wasmComponentAsyncCallbacks):
    {.error: "callback firmware requires -d:wasmComponentAsyncCallbacks".}
  import ../tools/wasm_component_callback_fixture
  when defined(wasmComponentSubtasksFirmware):
    const Fixture = when defined(bl808lp):
      staticRead("../build/wasm-component/upstream/async-local-lp.stripped.wasm")
    else:
      staticRead("../build/wasm-component/upstream/async-subtasks-lp.stripped.wasm")
    const StatusPrefix = 0x57535400'u32
  else:
    const Fixture = staticRead("../build/wasm-component/upstream/callback_turns.stripped.wasm")
    const StatusPrefix = 0x57434100'u32
else:
  const Fixture = staticRead("../build/wasm-component/arithmetic.component.wasm")
  const StatusPrefix = 0x57434600'u32

when defined(bl808m0):
  const StatusAddr = XramBase + 0x3F30'u
elif defined(bl808d0):
  const StatusAddr = XramBase + 0x3F40'u
elif defined(bl808lp):
  const StatusAddr = 0x40002EA0'u
else:
  {.error: "select a BL808 core".}

proc main() {.exportc, cdecl, noreturn.} =
  systemInit()
  heapInit()
  regWrite(StatusAddr, StatusPrefix or 0x7F'u32)
  try:
    when not (defined(wasmComponentGuestThreadsFirmware) or defined(wasmComponentErrorContextFirmware) or
        defined(wasmComponentThreadSpawnFirmware)):
      let instance = block:
        let plan = decodeComponent(cast[seq[byte]](Fixture))
        instantiateComponent(plan)
    when defined(wasmComponentErrorContextFirmware):
      let passed = checkErrorContextFixture(Fixture)
    elif defined(wasmComponentResourceAscriptionFirmware):
      let passed = checkResourceAscription(instance)
    elif defined(wasmComponentThreadSpawnFirmware):
      const parallelism = staticRead("../build/wasm-component/thread-spawn/parallelism.wasm")
      let passed = checkThreadSpawnFixtures(Fixture, parallelism)
    elif defined(wasmComponentGuestThreadsFirmware):
      const syncModule = staticRead("../build/wasm-component/upstream/sync-threads-lp.stripped.wasm")
      let passed = checkGuestThreadFixtures(Fixture, syncModule)
    elif defined(wasmComponentHostEndpointFirmware):
      let passed = checkHostUnitStream(instance)
    elif defined(wasmComponentStreamFirmware):
      let passed = checkUnitStream(instance)
    elif defined(wasmComponentFutureWaitFirmware):
      let passed = checkFutureWait(instance)
    elif defined(wasmComponentAsyncBorrowsFirmware):
      let passed = checkLocalAsyncBorrow(instance)
    elif defined(wasmComponentSyncLowerFirmware):
      let passed = checkSyncLower(instance, ["run"], [componentValue(cpU32, 41)])
    elif defined(wasmComponentStackfulFirmware):
      let passed = checkStackfulTurns(instance)
    elif defined(wasmComponentSubtasksFirmware):
      let passed = when defined(bl808lp): checkLocalAsyncSubtask(instance)
        else: checkAsyncSubtasks(instance, full = false)
    elif defined(wasmComponentCallbackFirmware):
      let passed = checkCallbackTurns(instance)
    else:
      let values = instance.invoke("add", [componentValue(cpS32, 19),
                                           componentValue(cpS32, 23)])
      let passed = values.len == 1 and values[0].bits == 42
    regWrite(StatusAddr, if passed: StatusPrefix else: StatusPrefix or 1'u32)
  except ComponentError:
    regWrite(StatusAddr, StatusPrefix or 2'u32)
  when defined(bl808d0):
    dcacheFlushAll()
    fenceIo()
  while true: wfi()
