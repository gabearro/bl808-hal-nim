## Run the same guest corpus and full interpreter on ISA-matched QEMU CPUs.
## LP derives its heap from the 16 KiB writable budget after reserving
## native stack and each test mode's .data and .bss.
import std/volatile
import bl808/[wasm_full_baseline, wasm_runtime]
import bl808/kernel/alloc

when defined(wasmFunctionReferencesProbe):
  import wasm_function_references_fixture
proc line(s: string)
when defined(wasmD0JitQemu):
  when not defined(bl808d0) or not defined(riscv64):
    {.error: "the D0 JIT semantic test needs RV64".}
  import cps/wasm/[binary, validate, runtime, types]
  import cps/wasm/jit/[memory, pipeline, codegen_rv64]
  const JitFallbackModule = staticRead("../build/wasm-jit-d0-qemu/fallback.wasm")
  var jitCodeRegion: array[4096, uint64]

  proc qemuJitRegionControl(ctx: pointer, writable: bool): bool {.nimcall.} =
    ## QEMU test only; no BL808 protection hardware is modeled.
    discard ctx
    discard writable
    true

  type QemuJitFunc = proc(vsp, locals: ptr uint64,
                           memBase: ptr byte, memSize: uint64): ptr uint64 {.cdecl.}

  proc runD0Jit(): bool =
    let module = decodeModule(WasmFullBaselineModule)
    validateModule(module)
    var vm = initWasmVM()
    let idx = vm.instantiate(module, [])
    let interpreted = vm.invoke(idx, "add", [wasmI32(19), wasmI32(23)])
    if interpreted.len != 1 or interpreted[0].i32 != 42: return false
    var pool = initJitMemPoolIn(addr jitCodeRegion[0], sizeof(jitCodeRegion),
      qemuJitRegionControl)
    let compiled = pool.compileTier2Rv64(module, 0, 0,
      target = rv64BL808D0VerifiedTarget)
    if compiled.address == nil or compiled.size <= 0: return false
    let f = cast[QemuJitFunc](compiled.address)
    var locals: array[16, uint64]
    var values: array[64, uint64]
    locals[0] = 19
    locals[1] = 23
    let top = f(addr values[0], addr locals[0], nil, 0)
    if cast[uint](top) != cast[uint](addr values[1]) or
        values[0] != 42'u64: return false
    let interpretedFloat = vm.invoke(idx, "f64bits", [])
    if interpretedFloat.len != 1: return false
    let compiledFloat = pool.compileTier2Rv64(module, 1, 1,
      target = rv64BL808D0VerifiedTarget)
    if compiledFloat.address == nil: return false
    let floatFn = cast[QemuJitFunc](compiledFloat.address)
    values[0] = 0
    let floatTop = floatFn(addr values[0], addr locals[0], nil, 0)
    if cast[uint](floatTop) != cast[uint](addr values[1]) or
        values[0] != cast[uint64](interpretedFloat[0].i64): return false
    let fallback = decodeModule(cast[seq[byte]](JitFallbackModule))
    validateModule(fallback)
    for localIdx in 0 .. 2:
      var rejected = false
      try:
        discard pool.compileTier2Rv64(fallback, localIdx, localIdx,
          target = rv64BL808D0VerifiedTarget)
      except ValueError:
        rejected = true
      if not rejected: return false
    let fallbackIdx = vm.instantiate(fallback, [])
    for name in ["divide", "load"]:
      var trapped = false
      try:
        discard vm.invoke(fallbackIdx, name, [])
      except WasmTrap:
        trapped = true
      if not trapped: return false
    let grew = vm.invoke(fallbackIdx, "grow", [])
    result = grew.len == 1 and grew[0].i32 == 1
    pool.destroy()

when defined(wasmComponentHostDefinitionQemu):
  import cps/wasm/component
  import wasm_component_host_definition_fixture
  const ConsumerFixture = staticRead("../build/wasm-component/host_consumer.wasm")
  const ProviderFixture = staticRead("../build/wasm-component/host_provider.wasm")

  proc runHostDefinition(): bool =
    line("host component definition decode")
    let consumer = decodeComponent(cast[seq[byte]](ConsumerFixture))
    let provider = decodeComponent(cast[seq[byte]](ProviderFixture))
    var starts = 0
    let started: ComponentHostFunc =
      proc(args: openArray[ComponentValue]): seq[ComponentValue] = inc starts
    line("host component definition instantiate")
    let instance = instantiateComponent(consumer, hostDefinitionFunctions(started),
      components = [ComponentHostDefinition(name: "factory", plan: provider)])
    line("host component definition invoke")
    result = starts == 1 and checkHostDefinition(instance)
    closeComponent(instance)

when defined(wasmComponentCoreModuleQemu):
  import cps/wasm/component
  const CoreModuleHost = staticRead("../build/wasm-component/core_module_host.wasm")
  const CoreModuleProvider = staticRead("../build/wasm-component/core_module_provider.wasm")
  when defined(bl808lp):
    const InterfaceCoreModule = staticRead("../build/wasm-component/interface_module_lp.wasm")
  else:
    const CoreModuleRelay = staticRead("../build/wasm-component/core_module_link.wasm")
    const InterfaceCoreModule = staticRead("../build/wasm-component/interface_module_link.wasm")

  proc runHostCoreModule(): bool =
    line("host core module decode")
    let plan = decodeComponent(cast[seq[byte]](CoreModuleHost))
    line("host core module instantiate")
    let instance = instantiateComponent(plan, [], coreModules = [
      ComponentHostCoreModule(name: "engine", bytes: cast[seq[byte]](CoreModuleProvider))])
    let values = instance.invoke("run", [])
    result = values.len == 1 and values[0].kind == cpU32 and values[0].bits == 42
    closeComponent(instance)

  proc runLinkedCoreModule(fixture: string): bool =
    line("linked core module decode")
    let plan = decodeComponent(cast[seq[byte]](fixture))
    line("linked core module instantiate")
    let instance = instantiateComponent(plan)
    let values = instance.invoke("run", [])
    result = values.len == 1 and values[0].kind == cpU32 and values[0].bits == 42
    closeComponent(instance)

when defined(wasmComponentDefinitionRelayQemu):
  import cps/wasm/component
  const DefinitionFixture = when defined(bl808lp):
    staticRead("../build/wasm-component/definition_export_lp.wasm")
  else:
    staticRead("../build/wasm-component/definition_relay.wasm")
  const InterfaceDefinitionFixture = when defined(bl808lp):
    staticRead("../build/wasm-component/interface_component_lp.wasm")
  else:
    staticRead("../build/wasm-component/interface_component_link.wasm")

  proc runDefinitionRelay(fixture: string, control = "run-direct", expected = 42'u64): bool =
    line("component definition decode")
    let plan = decodeComponent(cast[seq[byte]](fixture))
    line("component definition instantiate")
    let instance = instantiateComponent(plan)
    let values = instance.invoke("run", [])
    result = values.len == 1 and values[0].kind == cpU32 and values[0].bits == 42
    when not defined(bl808lp):
      result = result and instance.invoke("run", [])[0].bits == 43 and
        instance.invoke("run-second", [])[0].bits == 42 and
        instance.invoke(control, [])[0].bits == expected
    closeComponent(instance)

when defined(wasmComponentFunctionEqualityQemu):
  import cps/wasm/component
  const FunctionEqualityFixture = when defined(bl808lp):
    staticRead("../build/wasm-component/function_equality_lp.wasm")
  else:
    staticRead("../build/wasm-component/function_equality.wasm")

  proc checkFunctionEquality(): bool =
    line("function type equality decode")
    let plan = decodeComponent(cast[seq[byte]](FunctionEqualityFixture))
    line("function type equality instantiate")
    let instance = instantiateComponent(plan)
    let values = instance.invoke("run", [])
    result = values.len == 1 and values[0].kind == cpU32 and values[0].bits == 42
    when not defined(bl808lp):
      let argument = componentRecord([componentValue(cpU32, 41)])
      result = result and instance.invoke("direct", [argument])[0].bits == 42
    closeComponent(instance)

when defined(wasmComponentContractEqualityQemu) or defined(wasmComponentInstanceEqualityQemu) or
     defined(wasmComponentContractCaptureQemu) or defined(wasmComponentLexicalResourceValueQemu) or
     defined(wasmComponentLocalLowerQemu):
  import cps/wasm/component
  const TypeEqualityStem = when defined(wasmComponentInstanceEqualityQemu): "instance_equality"
    elif defined(wasmComponentContractCaptureQemu): "contract_capture"
    elif defined(wasmComponentLexicalResourceValueQemu): "lexical_resource_value"
    elif defined(wasmComponentLocalLowerQemu): "local_lower"
    else: "contract_equality"
  const TypeEqualityFixture = staticRead("../build/wasm-component/" & TypeEqualityStem &
    (when defined(bl808lp): "_lp.wasm" else: ".wasm"))

  proc checkTypeEquality(): bool =
    let plan = decodeComponent(cast[seq[byte]](TypeEqualityFixture))
    let instance = instantiateComponent(plan)
    let values = instance.invoke("run", [])
    result = values.len == 1 and values[0].kind == cpU32 and values[0].bits == 42
    closeComponent(instance)

when defined(wasmComponentTagLinkQemu):
  import cps/wasm/component
  const TagLinkFixture = when defined(bl808lp):
      staticRead("../build/wasm-component/upstream/tag-link-lp.wasm")
    else: staticRead("../build/wasm-component/upstream/tag-link-3.wasm")

  proc checkTagLink(): bool =
    let plan = decodeComponent(cast[seq[byte]](TagLinkFixture))
    let instance = instantiateComponent(plan)
    when defined(bl808lp):
      result = instance.invoke("run", [componentValue(cpBool, 0)])[0].bits == 42 and
        instance.invoke("run", [componentValue(cpBool, 1)])[0].bits == 77
    else:
      result = instance.invoke("run-a", [componentValue(cpU32, 42)])[0].bits == 42 and
        instance.invoke("run-b", [componentValue(cpU32, 42)])[0].bits == 77
    closeComponent(instance)

when defined(wasmComponentCoreFunctionTypesQemu):
  import cps/wasm/component
  const
    TypedCoreImport = when defined(bl808lp):
      staticRead("../build/wasm-component/upstream/typed-core-import-lp.wasm")
    else:
      staticRead("../build/wasm-component/upstream/typed-core-import.wasm")
    TypedCoreIndirect = staticRead("../build/wasm-component/upstream/typed-core-indirect.wasm")

  proc checkCoreFunctionTypes(fixture: openArray[byte], indirect = false): bool =
    let plan = decodeComponent(fixture)
    let instance = instantiateComponent(plan)
    defer: closeComponent(instance)
    let values = instance.invoke("run", [])
    if values.len != 1 or values[0].kind != cpU32 or values[0].bits != 42: return false
    if not indirect: return true
    let tail = instance.invoke("tail", [])
    if tail.len != 1 or tail[0].kind != cpU32 or tail[0].bits != 42: return false
    try:
      discard instance.invoke("bad", [])
    except ComponentError:
      return true
    false

when defined(wasmComponentGeneratedCoreQemu):
  import cps/wasm/component
  const GeneratedCoreFixture = staticRead("../build/wasm-component/generated_core_host.wasm")

  proc checkGeneratedCore(): bool =
    let adjust = ComponentHostBinding(name: "adjust", signature: ComponentFuncType(
      params: @[cpBool], hasResult: true, resultType: cpU32),
      callback: proc(args: openArray[ComponentValue]): seq[ComponentValue] =
        if args.len != 1 or args[0].kind != cpBool or args[0].bits != 1: return @[]
        @[componentValue(cpU32, 42)])
    let plan = decodeComponent(cast[seq[byte]](GeneratedCoreFixture))
    let instance = instantiateComponent(plan, [adjust])
    let answer = instance.invoke("run", [componentValue(cpU32, 2)])
    result = answer.len == 1 and answer[0].kind == cpU32 and answer[0].bits == 42
    closeComponent(instance)

when defined(wasmComponentOuterCaptureQemu):
  import cps/wasm/component
  const CaptureFixture = when defined(bl808lp):
    staticRead("../build/wasm-component/outer_capture_lp.wasm")
  else:
    staticRead("../build/wasm-component/outer_capture.wasm")
  const CapturedEngineA = staticRead("../build/wasm-component/outer_capture_engine_a.wasm")
  const CapturedWorkerA = staticRead("../build/wasm-component/outer_capture_worker_a.wasm")
  when defined(bl808lp):
    const ModuleCaptureFixture = staticRead("../build/wasm-component/outer_capture_lp_module.wasm")

    proc runCapturedComponentLp(): bool =
      line("outer component capture")
      let plan = decodeComponent(cast[seq[byte]](CaptureFixture))
      let definition = ComponentHostDefinition(name: "worker",
        plan: decodeComponent(cast[seq[byte]](CapturedWorkerA)))
      let instance = instantiateComponent(plan, [], components = [definition])
      let values = instance.invoke("run", [])
      result = values.len == 1 and values[0].kind == cpU32 and values[0].bits == 22
      closeComponent(instance)

    proc runCapturedModuleLp(): bool =
      line("outer module capture")
      let plan = decodeComponent(cast[seq[byte]](ModuleCaptureFixture))
      let engine = ComponentHostCoreModule(name: "engine", bytes: cast[seq[byte]](CapturedEngineA))
      let instance = instantiateComponent(plan, [], coreModules = [engine])
      let values = instance.invoke("run", [])
      result = values.len == 1 and values[0].kind == cpU32 and values[0].bits == 20
      closeComponent(instance)
  else:
    const CapturedEngineB = staticRead("../build/wasm-component/outer_capture_engine_b.wasm")
    const CapturedWorkerB = staticRead("../build/wasm-component/outer_capture_worker_b.wasm")

    proc runOuterCapture(plan: ComponentPlan, engineBytes, workerBytes: string,
                         expected: uint64): bool =
      let worker = ComponentHostDefinition(name: "worker",
        plan: decodeComponent(cast[seq[byte]](workerBytes)))
      let engine = ComponentHostCoreModule(name: "engine", bytes: cast[seq[byte]](engineBytes))
      line("outer capture instantiate")
      let instance = instantiateComponent(plan, [], components = [worker], coreModules = [engine])
      let values = instance.invoke("run", [])
      result = values.len == 1 and values[0].kind == cpU32 and values[0].bits == expected
      result = result and instance.invoke("run", [])[0].bits == expected + 1 and
        instance.invoke("run-second", [])[0].bits == expected
      closeComponent(instance)

  proc checkOuterCapture(): bool =
    when defined(bl808lp):
      runCapturedComponentLp() and runCapturedModuleLp()
    else:
      line("outer capture decode")
      let plan = decodeComponent(cast[seq[byte]](CaptureFixture))
      runOuterCapture(plan, CapturedEngineA, CapturedWorkerA, 42) and
        runOuterCapture(plan, CapturedEngineB, CapturedWorkerB, 85)

when defined(wasmComponentErrorContextQemu):
  import wasm_component_error_context_fixture
  const ErrorContextFixture = staticRead("../build/wasm-component/upstream/error-context-lp.wasm")

when defined(wasmComponentNestedInstanceQemu):
  import cps/wasm/component
  when defined(bl808lp):
    const NestedInstanceFixture = staticRead("../build/wasm-component/nested_instance_lp.wasm")
  else:
    const NestedInstanceFixture = staticRead("../build/wasm-component/nested_instance.wasm")
    const TypedInstanceFixture = staticRead("../build/wasm-component/nested_instance_typed.wasm")
    const LexicalResourceFixture = staticRead("../build/wasm-component/lexical_resource.wasm")

  proc runNestedInstance(fixture: string): bool =
    line("nested instance decode")
    let plan = decodeComponent(cast[seq[byte]](fixture))
    line("nested instance instantiate")
    let instance = instantiateComponent(plan)
    let values = when defined(bl808lp): instance.invokeInterface(["api", "inner"], "run", [])
      else: instance.invoke("run", [])
    result = values.len == 1 and values[0].kind == cpU32 and values[0].bits == 42
    closeComponent(instance)

when defined(wasmComponentTypedImportQemu):
  import cps/wasm/component
  import wasm_component_named_fixture
  const TypedImportFixture = staticRead("../build/wasm-component/typed_import.wasm")
  const TypedReexportFixture = staticRead("../build/wasm-component/typed_reexport.wasm")
  const TypedInterfaceFixture = staticRead("../build/wasm-component/typed_interface.wasm")
  const TypedResourceInterfaceFixture = staticRead("../build/wasm-component/typed_interface_resource.wasm")
  const WitInterfaceProvider = staticRead("../build/wasm-component/named_interface.stripped.wasm")

  proc runTypedImport(fixture: string): bool =
    line("typed component import decode")
    let plan = decodeComponent(cast[seq[byte]](fixture))
    line("typed component import instantiate")
    let instance = instantiateComponent(plan)
    line("typed component import invoke")
    let values = instance.invoke("run", [])
    result = values.len == 1 and values[0].kind == cpU32 and values[0].bits == 42
    closeComponent(instance)

  proc runTypedInterface(): bool =
    line("typed WIT interface decode")
    let consumer = decodeComponent(cast[seq[byte]](TypedInterfaceFixture))
    let provider = decodeComponent(cast[seq[byte]](WitInterfaceProvider))
    line("typed WIT interface instantiate")
    let instance = instantiateComponent(consumer, [], interfaces = [biasBinding()],
      components = [ComponentHostDefinition(name: "factory", plan: provider)])
    result = checkNamedArithmetic(instance)
    closeComponent(instance)

when defined(wasmComponentForeignBorrowQemu):
  import cps/wasm/component
  const ForeignBorrowFixture = staticRead("../build/wasm-component/foreign_borrow.wasm")

  proc runForeignBorrow(): bool =
    line("foreign borrow decode")
    let plan = decodeComponent(cast[seq[byte]](ForeignBorrowFixture))
    line("foreign borrow instantiate")
    let instance = instantiateComponent(plan)
    line("foreign borrow invoke")
    let values = instance.invoke("run", [])
    values.len == 1 and values[0].kind == cpU32 and values[0].bits == 42

when defined(wasmComponentNestedQemu):
  import cps/wasm/component
  when defined(bl808lp):
    const NestedComponentFixture = staticRead("../build/wasm-component/upstream/nested-bool-lp.wasm")
  else:
    const NestedComponentFixture = staticRead("../build/wasm-component/upstream/nested-bool.wasm")

  proc runComponentNested(): bool =
    line("nested component decode")
    let plan = decodeComponent(cast[seq[byte]](NestedComponentFixture))
    line("nested component instantiate")
    let instance = instantiateComponent(plan)
    line("nested component invoke")
    let values = instance.invoke("run", [])
    values.len == 1 and values[0].kind == cpU32 and values[0].bits == 43

when defined(wasmComponentInterfaceQemu):
  import cps/wasm/component
  import wasm_component_named_fixture
  when defined(bl808lp):
    const InterfaceComponentFixture = staticRead("../build/wasm-component/named_interface.stripped.wasm")
  else:
    const InterfaceComponentFixture = staticRead("../build/wasm-component/named_composed.component.wasm")

  proc runComponentInterface(): bool =
    line("named interface decode")
    let plan = decodeComponent(cast[seq[byte]](InterfaceComponentFixture))
    line("named interface instantiate")
    let instance = when defined(bl808lp):
        instantiateComponent(plan, [], interfaces = [biasBinding()])
      else: instantiateComponent(plan)
    line("named interface invoke")
    checkNamedArithmetic(instance)

when defined(wasmComponentNameAttributesQemu):
  import wasm_component_named_fixture
  const NameAttributesFixture = staticRead("../build/wasm-component/name_attributes.wasm")

when defined(wasmComponentResourceQemu):
  import cps/wasm/component
  import wasm_component_resource_fixture
  when defined(bl808lp):
    const ResourceComponentFixture = staticRead("../build/wasm-component/resource-lp.wasm")
  else:
    const ResourceComponentFixture = staticRead("../build/wasm-component/resource.stripped.wasm")

  proc runComponentResource(): bool =
    line("component resource decode")
    let plan = decodeComponent(cast[seq[byte]](ResourceComponentFixture))
    line("component resource instantiate")
    let instance = instantiateComponent(plan)
    line("component resource invoke")
    checkGeneratedResource(instance, generatedInterface = not defined(bl808lp))

when defined(wasmComponentResourceVisibilityQemu):
  import cps/wasm/component
  when defined(bl808lp):
    const ResourceRelay = staticRead("../build/wasm-component/upstream/resource-relay-lp.wasm")
  else:
    const ResourceRelay = staticRead("../build/wasm-component/upstream/resource-relay.wasm")

  proc runResourceRelay(): bool =
    line("resource relay decode")
    let plan = decodeComponent(cast[seq[byte]](ResourceRelay))
    line("resource relay instantiate")
    let instance = instantiateComponent(plan)
    line("resource relay invoke")
    for expected in [42'u64, 84'u64]:
      when defined(bl808lp):
        let owner = instance.invoke("make", [componentValue(cpU32, 42)])
        if owner.len != 1 or owner[0].kind != cpOwnedResource: return false
        if instance.invokeInterface("api", "consume", owner).len != 0: return false
        try:
          discard borrowComponentResource(owner[0])
          return false
        except ComponentError as error:
          if error.msg != "invalid component owned value": return false
      else:
        let value = instance.invoke("run", [])
        if value.len != 1 or value[0].kind != cpU32 or value[0].bits != expected:
          return false
    true

when defined(wasmComponentResourceAscriptionQemu):
  import cps/wasm/component
  import wasm_component_resource_ascription_fixture
  const AscribedResource = when defined(bl808lp):
    staticRead("../build/wasm-component/upstream/resource-ascription-lp.wasm")
  else:
    staticRead("../build/wasm-component/upstream/resource-ascription.wasm")

  proc runResourceAscription(): bool =
    line("resource ascription decode")
    let plan = decodeComponent(cast[seq[byte]](AscribedResource))
    line("resource ascription instantiate")
    let instance = instantiateComponent(plan)
    line("resource ascription invoke")
    checkResourceAscription(instance)

when defined(wasmComponentCallbackQemu):
  import cps/wasm/component
  import wasm_component_callback_fixture
  const CallbackFixture = staticRead("../build/wasm-component/upstream/callback_turns.stripped.wasm")

  proc runCallbackTurns(): bool =
    let plan = decodeComponent(cast[seq[byte]](CallbackFixture))
    checkCallbackTurns(instantiateComponent(plan))

when defined(wasmComponentSubtasksQemu):
  import cps/wasm/component
  import wasm_component_callback_fixture
  when defined(wasmComponentAsyncBorrowsQemu):
    proc checkAsyncBorrows(instance: ComponentInstance): bool =
      when defined(wasmComponentAsyncBorrowsForeignQemu):
        let call = instance.beginCallback("run", [])
        if call.pollCallback() != ccsComplete: return false
        call.takeCallbackResult()[0].bits == 42 and not instance.pollComponentTasks()
      elif defined(bl808lp):
        checkLocalAsyncBorrow(instance)
      else:
        for mode in [0'u64, 4, 5, 6, 7, 8, 9, 10]:
          let call = instance.beginCallback("run", [componentValue(cpU32, mode)])
          for step in 0..<12:
            discard call.pollCallback()
            if call.callbackResultReady(): break
          if not call.callbackResultReady() or call.takeCallbackResult()[0].bits != 42:
            return false
        not instance.pollComponentTasks()
  when defined(wasmComponentCancellationQemu):
    proc checkCancellation(instance: ComponentInstance): bool =
      const lastMode = when defined(bl808lp): 1 else: 4
      for mode in 0..lastMode:
        let call = instance.beginCallback("run", [componentValue(cpU32, mode.uint64)])
        for step in 0..3:
          discard call.pollCallback()
          if call.callbackResultReady(): break
        if not call.callbackResultReady() or call.takeCallbackResult().len != 0: return false
      not instance.pollComponentTasks()
  when defined(wasmComponentGuestThreadsQemu):
    proc runGuestThreadFixtures(): bool =
      when defined(wasmComponentThreadSpawnQemu):
        const module = staticRead("../build/wasm-component/thread-spawn/probe.wasm")
        const parallelism = staticRead("../build/wasm-component/thread-spawn/parallelism.wasm")
        checkThreadSpawnFixtures(module, parallelism)
      else:
        const asyncModule = staticRead("../build/wasm-component/upstream/guest-threads-lp.stripped.wasm")
        const syncModule = staticRead("../build/wasm-component/upstream/sync-threads-lp.stripped.wasm")
        checkGuestThreadFixtures(asyncModule, syncModule)
  elif defined(bl808lp):
    const SubtaskFixture = when defined(wasmComponentHostEndpointQemu):
      staticRead("../build/wasm-component/upstream/host-endpoint.stripped.wasm")
    elif defined(wasmComponentStreamQemu):
      staticRead("../build/wasm-component/upstream/stream-lp.stripped.wasm")
    elif defined(wasmComponentFutureWaitQemu):
      staticRead("../build/wasm-component/upstream/future-wait-lp.stripped.wasm")
    elif defined(wasmComponentFutureTransferQemu):
      staticRead("../build/wasm-component/upstream/future-transfer-lp.stripped.wasm")
    elif defined(wasmComponentAsyncBorrowsForeignQemu):
      staticRead("../build/wasm-component/upstream/async-borrows-lp.stripped.wasm")
    elif defined(wasmComponentAsyncBorrowsQemu):
      staticRead("../build/wasm-component/upstream/async-borrows-local-lp.stripped.wasm")
    elif defined(wasmComponentSyncLowerQemu):
      staticRead("../build/wasm-component/upstream/async-sync-lower-lp.stripped.wasm")
    elif defined(wasmComponentStackfulQemu):
      staticRead("../build/wasm-component/upstream/async-stackful-lp.stripped.wasm")
    elif defined(wasmComponentCancellationQemu):
      staticRead("../build/wasm-component/upstream/async-subtask-cancellation-lp.stripped.wasm")
    elif defined(wasmComponentSubtasksDiagnosticQemu):
      staticRead("../build/wasm-component/upstream/async-subtasks-lp.stripped.wasm")
    else:
      staticRead("../build/wasm-component/upstream/async-local-lp.stripped.wasm")
    proc runSubtasks(): bool =
      line("async subtasks decode")
      let instance = block:
        let plan = decodeComponent(cast[seq[byte]](SubtaskFixture))
        line("async subtasks instantiate")
        instantiateComponent(plan)
      line("async subtasks execute")
      when defined(wasmComponentHostEndpointQemu):
        checkHostUnitStream(instance)
      elif defined(wasmComponentStreamQemu):
        checkUnitStream(instance)
      elif defined(wasmComponentFutureWaitQemu):
        checkFutureWait(instance)
      elif defined(wasmComponentFutureTransferQemu):
        let reader = instance.invoke("make", [])[0]
        let values = instance.invoke("consume", [reader])
        if values.len != 1 or values[0].bits != 42: return false
        instance.closeComponent()
        true
      elif defined(wasmComponentAsyncBorrowsQemu):
        checkAsyncBorrows(instance)
      elif defined(wasmComponentSyncLowerQemu):
        checkSyncLower(instance, ["run"], [componentValue(cpU32, 41)])
      elif defined(wasmComponentStackfulQemu):
        checkStackfulTurns(instance)
      elif defined(wasmComponentCancellationQemu):
        checkCancellation(instance)
      elif defined(wasmComponentSubtasksDiagnosticQemu):
        checkAsyncSubtasks(instance, full = false)
      else:
        checkLocalAsyncSubtask(instance)
  else:
    import cps/wasm/[linear_memory, types]
    const SubtaskFixture = when defined(wasmComponentHostEndpointQemu):
      staticRead("../build/wasm-component/upstream/host-endpoint.stripped.wasm")
    elif defined(wasmComponentStreamQemu):
      staticRead("../build/wasm-component/upstream/stream-partial.stripped.wasm")
    elif defined(wasmComponentFutureWaitQemu):
      staticRead("../build/wasm-component/upstream/future-wait.stripped.wasm")
    elif defined(wasmComponentFutureTransferQemu):
      staticRead("../build/wasm-component/upstream/future-transfer.stripped.wasm")
    elif defined(wasmComponentAsyncBorrowsQemu):
      staticRead("../build/wasm-component/upstream/async-borrows.stripped.wasm")
    elif defined(wasmComponentSyncLowerQemu):
      staticRead("../build/wasm-component/upstream/async-sync-lower.stripped.wasm")
    elif defined(wasmComponentStackfulQemu):
      staticRead("../build/wasm-component/upstream/async-stackful.stripped.wasm")
    elif defined(wasmComponentCancellationQemu):
      staticRead("../build/wasm-component/upstream/async-subtask-cancellation.stripped.wasm")
    else:
      staticRead("../build/wasm-component/upstream/async-subtasks.stripped.wasm")
    proc subtaskMemory(context: pointer, memType: MemType): ref LinearMemory =
      if memType.limits.min != 1: return nil
      new(result)
      if result[].initLinearMemory(LinearMemoryConfig(initialPages: 1,
          maxPages: 1, admissionPages: 1, maxCommittedChunks: 1, residentChunks: 1)) != lmOk:
        return nil
    proc runSubtasks(): bool =
      let plan = decodeComponent(cast[seq[byte]](SubtaskFixture))
      let instance = instantiateComponent(plan, [], subtaskMemory, nil)
      when defined(wasmComponentHostEndpointQemu):
        checkHostUnitStream(instance)
      elif defined(wasmComponentStreamQemu):
        for name in ["writer-buffer-pending", "drop-folds-into-partial-progress"]:
          let values = instance.invoke(name, [])
          if values.len != 1 or values[0].bits != 42: return false
        instance.closeComponent()
        true
      elif defined(wasmComponentFutureWaitQemu):
        checkFutureWait(instance)
      elif defined(wasmComponentFutureTransferQemu):
        for direction in [0'u64, 1'u64]:
          let result = instance.invoke("check", [componentValue(cpU32, direction)])
          if result.len != 1 or result[0].bits != 42: return false
        instance.closeComponent()
        true
      elif defined(wasmComponentAsyncBorrowsQemu):
        checkAsyncBorrows(instance)
      elif defined(wasmComponentSyncLowerQemu):
        checkSyncLower(instance, ["flat", "indirect", "priority"])
      elif defined(wasmComponentStackfulQemu):
        for (name, answer) in [("run", 42'u64), ("cancel", 4'u64), ("run", 42'u64)]:
          let call = instance.beginCallback(name, [])
          if call.pollCallback() != ccsCoreWaiting: return false
          for step in 0..<8:
            discard call.pollCallback()
            if call.callbackResultReady(): break
          if not call.callbackResultReady() or call.takeCallbackResult()[0].bits != answer:
            return false
        not instance.pollComponentTasks()
      elif defined(wasmComponentCancellationQemu):
        checkCancellation(instance)
      else:
        checkAsyncSubtasks(instance)

when defined(wasmComponentQemu):
  import cps/wasm/component
  const ComponentFixture = staticRead("../build/wasm-component/arithmetic.component.wasm")
  const ComponentImportFixture = staticRead("../build/wasm-component/multi_import.component.wasm")

  proc runComponentScalar(): bool =
    line("component scalar decode")
    let plan = decodeComponent(cast[seq[byte]](ComponentFixture))
    line("component scalar instantiate")
    let instance = instantiateComponent(plan)
    line("component scalar invoke")
    let values = instance.invoke("add", [componentValue(cpS32, 19),
                                         componentValue(cpS32, 23)])
    if values.len != 1 or values[0].bits != 42: return false
    let again = instance.invoke("add", [componentValue(cpS32, 1),
                                        componentValue(cpS32, 2)])
    again.len == 1 and again[0].bits == 3

  proc runComponentImports(): bool =
    line("component imports decode")
    let plan = decodeComponent(cast[seq[byte]](ComponentImportFixture))
    let sig = ComponentFuncType(params: @[cpS32],
      hasResult: true, resultType: cpS32)
    let doubleFn: ComponentHostFunc = proc(args: openArray[ComponentValue]):
        seq[ComponentValue] =
      @[componentValue(cpS32, args[0].bits * 2)]
    let tripleFn: ComponentHostFunc = proc(args: openArray[ComponentValue]):
        seq[ComponentValue] =
      @[componentValue(cpS32, args[0].bits * 3)]
    let instance = instantiateComponent(plan,
      [ComponentHostBinding(name: "double", signature: sig, callback: doubleFn),
       ComponentHostBinding(name: "triple", signature: sig, callback: tripleFn)])
    line("component imports invoke")
    let values = instance.invoke("combine", [componentValue(cpS32, 9)])
    values.len == 1 and values[0].bits == 45

when defined(wasmComponentCoreGraphQemu) or defined(wasmComponentIndirectQemu) or
     defined(wasmComponentFlatQemu) or defined(wasmComponentNestedListQemu) or
     defined(wasmComponentNestedValueQemu) or defined(wasmComponentResourceBundleQemu) or
     defined(wasmComponentLinkedResourceBundleQemu) or defined(wasmComponentCrossPostReturnQemu) or
     defined(wasmComponentStringQemu) or defined(wasmComponentStringResultQemu) or
     defined(wasmComponentMultiMemoryQemu) or defined(wasmComponentMapQemu) or
     defined(wasmComponentFixedListQemu) or defined(wasmComponentContextQemu) or
     defined(wasmComponentBytesQemu) or defined(wasmComponentWordsQemu) or
     defined(wasmComponentQwordsQemu) or
     defined(wasmComponentOptionStringQemu) or
     defined(wasmComponentRecordQemu) or
     defined(wasmComponentRecordMixedQemu) or
     defined(wasmComponentOptionQemu) or defined(wasmComponentVariantQemu) or
     defined(wasmComponentEnumQemu) or defined(wasmComponentResultQemu) or
     defined(wasmComponentTupleQemu) or defined(wasmComponentFlagsQemu) or
     defined(wasmComponentCharQemu):
  import cps/wasm/[component, linear_memory, types]
  when defined(wasmComponentLinkedResourceBundleQemu) or defined(wasmComponentCrossPostReturnQemu) or
      defined(wasmComponentMultiMemoryQemu):
    const ComponentStringFixture = when defined(wasmComponentMultiMemoryQemu):
        staticRead("../build/wasm-component/upstream/multi-memory.wasm")
      elif defined(wasmComponentCrossPostReturnQemu):
        staticRead("../build/wasm-component/cross_post_trap.wasm")
      else: staticRead("../build/wasm-component/resource_bundle_linked.wasm")
    var peerChunk: array[WasmMemoryChunkBytes.int, byte]
    var peerMemory: ref LinearMemory
    var memoryCount: int
  elif defined(wasmComponentResourceBundleQemu):
    import wasm_component_resource_bundle_fixture
    const ComponentStringFixture = staticRead("../build/wasm-component/resource_bundle.stripped.wasm")
  elif defined(wasmComponentNestedValueQemu):
    import wasm_component_nested_value_fixture
    const ComponentStringFixture = staticRead("../build/wasm-component/nested_value.stripped.wasm")
  elif defined(wasmComponentNestedListQemu):
    import wasm_component_nested_list_fixture
    const ComponentStringFixture = staticRead("../build/wasm-component/nested_list.stripped.wasm")
  elif defined(wasmComponentFlatQemu):
    import wasm_component_flat_fixture
    when defined(bl808lp):
      const ComponentStringFixture = staticRead("../build/wasm-component/flat_lp.stripped.wasm")
    else:
      const ComponentStringFixture = staticRead("../build/wasm-component/flat.stripped.wasm")
  elif defined(wasmComponentIndirectQemu):
    import wasm_component_indirect_fixture
    when defined(bl808lp):
      const ComponentStringFixture = staticRead("../build/wasm-component/indirect.stripped.wasm")
    else:
      const ComponentStringFixture = staticRead("../build/wasm-component/indirect_linked.stripped.wasm")
  elif defined(wasmComponentCoreGraphQemu):
    when defined(bl808lp):
      const ComponentStringFixture = staticRead("../build/wasm-component/core_graph_lp.component.wasm")
    else:
      const ComponentStringFixture = staticRead("../build/wasm-component/core_graph.component.wasm")
  elif defined(wasmComponentMapQemu):
    import wasm_component_map_fixture
    const ComponentStringFixture = staticRead("../build/wasm-component/upstream/map.stripped.wasm")
  elif defined(wasmComponentFixedListQemu):
    import wasm_component_fixed_list_fixture
    const ComponentStringFixture = staticRead("../build/wasm-component/upstream/fixed_list.stripped.wasm")
    const FixedListIndirectFixture = staticRead("../build/wasm-component/upstream/fixed_list_indirect.stripped.wasm")
  elif defined(wasmComponentContextQemu):
    import wasm_component_context_fixture
    const ComponentStringFixture = when defined(bl808lp):
      staticRead("../build/wasm-component/upstream/context-lp.stripped.wasm")
    else:
      staticRead("../build/wasm-component/upstream/context.stripped.wasm")
    when defined(bl808lp):
      const ContextPostReturnFixture = staticRead("../build/wasm-component/upstream/context-post-return.stripped.wasm")
  elif defined(wasmComponentStringResultQemu):
    const ComponentStringFixture = staticRead("../build/wasm-component/string_result.component.wasm")
  elif defined(wasmComponentBytesQemu):
    const ComponentStringFixture = staticRead("../build/wasm-component/bytes.component.wasm")
  elif defined(wasmComponentWordsQemu):
    const ComponentStringFixture = staticRead("../build/wasm-component/words.component.wasm")
  elif defined(wasmComponentQwordsQemu):
    const ComponentStringFixture = staticRead("../build/wasm-component/qwords.component.wasm")
  elif defined(wasmComponentOptionStringQemu):
    const ComponentStringFixture = staticRead("../build/wasm-component/option_string.component.wasm")
  elif defined(wasmComponentRecordQemu):
    const ComponentStringFixture = staticRead("../build/wasm-component/record.component.wasm")
  elif defined(wasmComponentRecordMixedQemu):
    const ComponentStringFixture = staticRead("../build/wasm-component/record_mixed.component.wasm")
  elif defined(wasmComponentOptionQemu):
    const ComponentStringFixture = staticRead("../build/wasm-component/option.component.wasm")
  elif defined(wasmComponentVariantQemu):
    const ComponentStringFixture = staticRead("../build/wasm-component/variant.component.wasm")
  elif defined(wasmComponentEnumQemu):
    const ComponentStringFixture = staticRead("../build/wasm-component/enum.component.wasm")
  elif defined(wasmComponentResultQemu):
    const ComponentStringFixture = staticRead("../build/wasm-component/result.component.wasm")
  elif defined(wasmComponentTupleQemu):
    const ComponentStringFixture = staticRead("../build/wasm-component/tuple.component.wasm")
  elif defined(wasmComponentFlagsQemu):
    const ComponentStringFixture = staticRead("../build/wasm-component/flags.component.wasm")
  elif defined(wasmComponentCharQemu):
    const ComponentStringFixture = staticRead("../build/wasm-component/char.component.wasm")
  else:
    const ComponentStringFixture = staticRead("../build/wasm-component/string.component.wasm")
  const ComponentTestChunks = when defined(wasmComponentIndirectQemu) and
    not defined(bl808lp): 2 else: 1
  var stringChunk: array[WasmMemoryChunkBytes.int * ComponentTestChunks, byte]
  var stringMemory: ref LinearMemory

  proc componentStringMemory(ctx: pointer, memType: MemType): ref LinearMemory =
    discard ctx
    if memType.limits.min != 1: return nil
    when defined(wasmComponentLinkedResourceBundleQemu) or defined(wasmComponentCrossPostReturnQemu) or
        defined(wasmComponentMultiMemoryQemu):
      inc memoryCount
      if memoryCount == 2: return peerMemory
      if memoryCount != 1: return nil
    stringMemory

  when defined(wasmComponentRecordQemu):
    proc checkRecordFixture(instance: ComponentInstance): bool {.noinline.} =
      block:
        let sum = instance.invoke("sum-pair", [componentRecord([
          componentValue(cpU32, 19), componentValue(cpU32, 23)])])
        if sum.len != 1 or sum[0].bits != 42: return false
      block:
        let made = instance.invoke("make-pair", [
          componentValue(cpU32, 12), componentValue(cpU32, 30)])
        if made.len != 1 or made[0].kind != cpRecord or
            made[0].fields.len != 2 or made[0].fields[0].bits != 12 or
            made[0].fields[1].bits != 30: return false
      let madeAgain = instance.invoke("make-pair", [
        componentValue(cpU32, 1), componentValue(cpU32, 2)])
      madeAgain.len == 1 and madeAgain[0].kind == cpRecord and
        madeAgain[0].fields.len == 2 and madeAgain[0].fields[0].bits == 1 and
        madeAgain[0].fields[1].bits == 2

  when defined(wasmComponentOptionStringQemu):
    proc openOptionStringFixture(): ComponentInstance {.noinline.} =
      let plan = decodeComponent(cast[seq[byte]](ComponentStringFixture))
      instantiateComponent(plan, [], componentStringMemory, nil)

    proc checkOptionStringFixture(instance: ComponentInstance): bool {.noinline.} =
      let present = instance.invoke("len", [componentOptionSome(
        componentString("Ox64"))])
      if present.len != 1 or present[0].bits != 4: return false
      let greeting = instance.invoke("get", [])
      greeting.len == 1 and greeting[0].kind == cpOption and
        greeting[0].caseIndex == 1 and greeting[0].fields.len == 1 and
        greeting[0].fields[0].kind == cpString and
        greeting[0].fields[0].text == "Ox64"

  proc runComponentString(fixture: static[string] = ComponentStringFixture,
                          secondaryFixture: static[bool] = false): bool =
    new(stringMemory)
    let cfg = LinearMemoryConfig(initialPages: 1, maxPages: 1,
      admissionPages: 1, maxCommittedChunks: ComponentTestChunks, residentChunks: ComponentTestChunks)
    if stringMemory[].initLinearMemoryIn(cfg,
        cast[ptr UncheckedArray[byte]](addr stringChunk[0]),
        stringChunk.len.uint32) != lmOk:
      return false
    when defined(wasmComponentLinkedResourceBundleQemu) or defined(wasmComponentCrossPostReturnQemu) or
        defined(wasmComponentMultiMemoryQemu):
      new(peerMemory)
      if peerMemory[].initLinearMemoryIn(cfg,
          cast[ptr UncheckedArray[byte]](addr peerChunk[0]),
          peerChunk.len.uint32) != lmOk:
        return false
    let instance =
      when defined(wasmComponentOptionStringQemu):
        openOptionStringFixture()
      else:
        block:
          when defined(wasmComponentIndirectQemu):
            line("indirect component decode")
          let plan = decodeComponent(cast[seq[byte]](fixture))
          when defined(wasmComponentIndirectQemu):
            line("indirect component instantiate")
          when defined(wasmComponentFlatQemu):
            instantiateComponent(plan,
              [flatArgumentsBinding(plan, memoryBacked = not defined(bl808lp))],
              componentStringMemory, nil)
          elif defined(wasmComponentIndirectQemu) and not defined(bl808lp):
            instantiateComponent(plan, [indirectArgumentsBinding(plan)], componentStringMemory, nil)
          else:
            instantiateComponent(plan, [], componentStringMemory, nil)
    when defined(wasmComponentMapQemu):
      checkMapRoundtrip(instance)
    elif defined(wasmComponentFixedListQemu):
      defer: closeComponent(instance)
      when secondaryFixture: checkFixedListIndirect(instance)
      else: checkFixedListDirect(instance)
    elif defined(wasmComponentContextQemu):
      defer: closeComponent(instance)
      when secondaryFixture: checkContextPostReturn(instance)
      else: checkContext(instance)
    elif defined(wasmComponentMultiMemoryQemu):
      let greeting = instance.invoke("run", [])
      memoryCount == 2 and greeting.len == 1 and
        greeting[0].kind == cpString and greeting[0].text == "Ox64"
    elif defined(wasmComponentCrossPostReturnQemu):
      try:
        discard instance.invoke("run", [])
        return false
      except ComponentError:
        var payload: byte
        if memoryCount != 2: return false
        let status = peerMemory[].readAt(64, cast[ptr UncheckedArray[byte]](addr payload), 1)
        status == lmOk and payload == 42
    elif defined(wasmComponentLinkedResourceBundleQemu):
      let values = instance.invoke("run", [])
      memoryCount == 2 and values.len == 1 and values[0].bits == 42
    elif defined(wasmComponentResourceBundleQemu):
      checkResourceBundle(instance)
    elif defined(wasmComponentNestedValueQemu):
      checkNestedValue(instance)
    elif defined(wasmComponentNestedListQemu):
      checkNestedList(instance)
    elif defined(wasmComponentFlatQemu):
      checkFlatArguments(instance)
    elif defined(wasmComponentIndirectQemu):
      line("indirect component invoke")
      checkIndirectArguments(instance)
    elif defined(wasmComponentCoreGraphQemu):
      let first = instance.invoke("increment", [componentValue(cpS32, 19)])
      if first.len != 1 or first[0].bits != 38: return false
      let second = instance.invoke("increment", [componentValue(cpS32, 2)])
      if second.len != 1 or second[0].bits != 42: return false
      let readback = instance.invoke("read", [])
      readback.len == 1 and readback[0].bits == 21
    elif defined(wasmComponentBytesQemu):
      let echoed = instance.invoke("echo-bytes",
        [componentBytes([0'u8, 1, 255, 0])])
      if echoed.len != 1 or echoed[0].kind != cpBytes or
          echoed[0].bytes != @[0'u8, 1, 255, 0]: return false
      let empty = instance.invoke("echo-bytes", [componentBytes([])])
      empty.len == 1 and empty[0].bytes.len == 0
    elif defined(wasmComponentWordsQemu):
      let echoed = instance.invoke("echo-words",
        [componentU32List([0'u32, 0x1020_3040'u32, high(uint32)])])
      if echoed.len != 1 or echoed[0].kind != cpU32List or
          echoed[0].fields.len != 3 or
          echoed[0].fields[1].bits != 0x1020_3040'u64 or
          echoed[0].fields[2].bits != high(uint32).uint64: return false
      let empty = instance.invoke("echo-words", [componentU32List([])])
      empty.len == 1 and empty[0].fields.len == 0
    elif defined(wasmComponentQwordsQemu):
      let echoed = instance.invoke("echo-qwords",
        [componentU64List([0'u64, 0x1020_3040_5060_7080'u64,
                           high(uint64)])])
      if echoed.len != 1 or echoed[0].kind != cpU64List or
          echoed[0].fields.len != 3 or
          echoed[0].fields[1].bits != 0x1020_3040_5060_7080'u64 or
          echoed[0].fields[2].bits != high(uint64): return false
      let empty = instance.invoke("echo-qwords", [componentU64List([])])
      empty.len == 1 and empty[0].fields.len == 0
    elif defined(wasmComponentOptionStringQemu):
      checkOptionStringFixture(instance)
    elif defined(wasmComponentOptionQemu):
      let absent = instance.invoke("choose", [componentOptionNone()])
      if absent.len != 1 or absent[0].bits != 0: return false
      let chosen = instance.invoke("choose", [componentOptionSome(
        componentValue(cpU32, 41))])
      if chosen.len != 1 or chosen[0].bits != 42: return false
      let made = instance.invoke("make-option", [componentValue(cpU32, 9)])
      made.len == 1 and made[0].kind == cpOption and
        made[0].caseIndex == 1 and made[0].fields.len == 1 and
        made[0].fields[0].bits == 9
    elif defined(wasmComponentVariantQemu):
      let empty = instance.invoke("describe", [componentVariant(0)])
      if empty.len != 1 or empty[0].bits != 0: return false
      let small = instance.invoke("describe", [componentVariant(1,
        [componentValue(cpU32, 17)])])
      if small.len != 1 or small[0].bits != 17: return false
      let floated = instance.invoke("describe", [componentVariant(3,
        [componentValue(cpF32, cast[uint32](1.25'f32).uint64)])])
      if floated.len != 1 or
          floated[0].bits != cast[uint32](1.25'f32).uint64: return false
      let made = instance.invoke("make-wide", [
        componentValue(cpU64, 0x8877_6655_4433_2211'u64)])
      made.len == 1 and made[0].kind == cpVariant and
        made[0].caseIndex == 2 and made[0].fields.len == 1 and
        made[0].fields[0].bits == 0x8877_6655_4433_2211'u64
    elif defined(wasmComponentEnumQemu):
      let mode = instance.invoke("echo-mode", [componentEnum(2)])
      mode.len == 1 and mode[0].kind == cpEnum and mode[0].caseIndex == 2
    elif defined(wasmComponentResultQemu):
      let okValue = instance.invoke("inspect", [componentResult(0,
        [componentValue(cpU32, 23)])])
      if okValue.len != 1 or okValue[0].bits != 23: return false
      let errorValue = instance.invoke("make-error", [
        componentValue(cpU64, 0x1234_5678_9abc_def0'u64)])
      errorValue.len == 1 and errorValue[0].kind == cpResult and
        errorValue[0].caseIndex == 1 and errorValue[0].fields.len == 1 and
        errorValue[0].fields[0].bits == 0x1234_5678_9abc_def0'u64
    elif defined(wasmComponentTupleQemu):
      let total = instance.invoke("sum-tuple", [componentTuple([
        componentValue(cpU32, 19), componentValue(cpU32, 23)])])
      if total.len != 1 or total[0].bits != 42: return false
      let made = instance.invoke("make-tuple", [
        componentValue(cpU32, 12), componentValue(cpU32, 30)])
      made.len == 1 and made[0].kind == cpTuple and
        made[0].fields.len == 2 and made[0].fields[0].bits == 12 and
        made[0].fields[1].bits == 30
    elif defined(wasmComponentFlagsQemu):
      let flags = instance.invoke("echo-flags", [componentFlags(5)])
      flags.len == 1 and flags[0].kind == cpFlags and flags[0].bits == 5
    elif defined(wasmComponentCharQemu):
      let scalar = instance.invoke("echo-char", [componentValue(cpChar,
        0x1f600'u64)])
      scalar.len == 1 and scalar[0].kind == cpChar and
        scalar[0].bits == 0x1f600'u64
    elif defined(wasmComponentRecordQemu):
      checkRecordFixture(instance)
    elif defined(wasmComponentRecordMixedQemu):
      let values = instance.invoke("echo-mixed", [componentRecord([
        componentValue(cpBool, 1),
        componentValue(cpU64, 0x1122_3344_5566_7788'u64),
        componentValue(cpS16, cast[uint64](-7'i64)),
        componentValue(cpF32, cast[uint32](1.25'f32).uint64)])])
      values.len == 1 and values[0].kind == cpRecord and
        values[0].fields.len == 4 and values[0].fields[0].bits == 1 and
        values[0].fields[1].bits == 0x1122_3344_5566_7788'u64 and
        cast[int64](values[0].fields[2].bits) == -7 and
        cast[float32](values[0].fields[3].bits.uint32) == 1.25'f32
    elif defined(wasmComponentStringResultQemu):
      let greeting = instance.invoke("greet", [])
      if greeting.len != 1 or greeting[0].kind != cpString or
          greeting[0].text != "Hello, Ox64": return false
      let afterPost = instance.invoke("greet", [])
      afterPost.len == 1 and afterPost[0].text == "Post called"
    else:
      let first = instance.invoke("first-byte", [componentString("Aha")])
      first.len == 1 and first[0].bits == 65
when defined(wasmFullThroughputBench):
  import cps/wasm/[binary, runtime, types, validate]
when defined(wasmFullManagerQemu):
  import bl808/[wasm_full_manager, wasm_manager, wasm_store]
  import cps/wasm/[runtime, types]
when defined(wasmFullSchedulerQemu):
  import bl808/[wasm_scheduler, wasm_store]
when defined(wasmMigrationQemu):
  import bl808/[wasm_migration_corpus, wasm_scheduler, wasm_store]
  when defined(wasmMutableMigrationQemu):
    import wasm_migration_state_fixture
  when defined(wasmStagedMigrationQemu):
    from cps/wasm/runtime import WasmPortableStaging
    import wasm_migration_dense_fixture
    when defined(bl808lp):
      var stagingRam: array[WasmDenseProbeCapacity, byte]

when defined(wasmPsramFramesQemu):
  import bl808/[wasm_psram_frames, wasm_scheduler]
  import cps/wasm/linear_memory
  import wasm_psram_frames_fixture
  var
    qemuHot, qemuCold: array[WasmMemoryChunkBytes.int, byte]
    qemuPsramOwner: WasmPsramFrames

  proc checkPsramFrames(): bool =
    let hot = cast[ptr UncheckedArray[byte]](addr qemuHot[0])
    let cold = cast[ptr UncheckedArray[byte]](addr qemuCold[0])
    if not qemuPsramOwner.reserveEmulatedPsramFrames(hot, cold, WasmMemoryChunkBytes,
        WasmMemoryChunkBytes, 2, 2):
      return false
    resetWasmScheduler()
    runPsramFrameTask(qemuPsramOwner) and qemuHot[^1] == 0x78 and
      qemuCold[0 .. 2] == [0x56'u8, 0x34, 0x12] and runPsramFrameTask(qemuPsramOwner)

when defined(wasmRtResidentQemu):
  import bl808/[wasm_rt_kernel, wasm_rt_policy, wasm_rt_resident, wasm_scheduler, wasm_store]
  import cps/wasm/[linear_memory, types]
  var
    rtResidentChunk: array[WasmMemoryChunkBytes.int, byte]
    rtResidentMemory: ref LinearMemory
    rtHook: TestTimedHook
    rtWakeTick: uint64

  proc makeRtResidentMemory(ctx: pointer, memType: MemType): ref LinearMemory =
    discard ctx
    if memType.limits.min != 1 or not memType.limits.hasMax or
        memType.limits.max != 1:
      return nil
    rtResidentMemory

  proc installRtHook(hook: TestTimedHook, deadline: uint64): bool {.nimcall.} =
    if rtHook != nil: return false
    rtHook = hook
    rtWakeTick = deadline
    true

  proc rearmRtHook(hook: TestTimedHook, deadline: uint64): bool {.nimcall.} =
    if rtHook != hook: return false
    rtWakeTick = deadline
    true

when defined(wasmStealClientQemu):
  import bl808/[wasm_full_manager, wasm_scheduler, wasm_store, wasm_steal_broker,
    wasm_steal_client]
  import bl808/kernel/runtime
  const
    QemuStealBrokerAddr = 0x8102_0000'u
    QemuStealCore = when defined(bl808m0): WasmStealM0
                    elif defined(bl808d0): WasmStealD0
                    else: WasmStealLP
  var
    stealClient: WasmStealClient
    stealImage: seq[byte]
    stealNow = 1'u64
  when defined(wasmSoftStealing):
    import bl808/[wasm_rt_clock, wasm_rt_policy]
    proc stealClock(): uint64 {.nimcall.} = stealNow
    proc stealOwnerReplyTick(): uint64 {.nimcall.} = stealNow + 50_007
    proc stealClockRate(): uint32 {.nimcall.} = 1

  proc stealBroker(): ptr WasmStealBroker =
    cast[ptr WasmStealBroker](QemuStealBrokerAddr)

  proc qemuStealRpc(request: openArray[byte], response: pointer,
                    responseBytes: int, responseLen: ptr int,
                    timeoutMs: uint64): CpsVoidFuture =
    discard timeoutMs
    result = newCpsVoidFuture()
    let dst = cast[ptr UncheckedArray[byte]](response)
    when defined(wasmSoftStealing):
      let isHello = request[3] == wsoHello.ord.byte
      let size = stealBroker()[].processWasmStealWire(request,
        dst.toOpenArray(0, responseBytes - 1), stealNow + 50_006,
        QemuStealCore, stealOwnerReplyTick, 1)
      stealNow += (if isHello: 30'u64 else: 1'u64)
    else:
      let size = stealBroker()[].processWasmStealWire(request,
        dst.toOpenArray(0, responseBytes - 1), stealNow, QemuStealCore)
      inc stealNow
    if size != WasmStealResponseBytes:
      result.fail(newException(IOError, "bad steal RPC"))
    else:
      responseLen[] = size
      result.complete()

  proc qemuStealPrepare(job: WasmStealJob,
                        admission: FullWasmAdmission, memoryFactory: FullMemoryFactory,
                        memoryFactoryContext: pointer): WasmSchedulerResult =
    var name = ""
    for c in job.exportName:
      if c == '\0': break
      name.add(c)
    if job.argCount != 2 or stealImage.len == 0:
      return WasmSchedulerResult(status: wasmSchedOpenFailed)
    startFullWasmImageTaskI32(
      cast[ptr UncheckedArray[byte]](addr stealImage[0]),
      stealImage.len.uint32, name, [job.args[0], job.args[1]],
      maxTotalFuel = job.maxFuel, slotLabel = job.slot.int32,
      maxMemoryPages = job.maxMemoryPages, requireNoStart = true,
      memoryFactory = memoryFactory, memoryFactoryContext = memoryFactoryContext,
      admission = admission, allowPortableMigration = false, retainTrappedTask = true)

when defined(wasmLpPagerQemu) or defined(wasmD0PagerClientQemu):
  import bl808/wasm_scheduler
  import cps/wasm/linear_memory
  when defined(wasmLpPagerClientQemu) or defined(wasmD0PagerClientQemu):
    import bl808/[wasm_page_client, wasm_page_wire]
    import cps/runtime
    var pageClient: WasmPageClient
  when defined(wasmD0PagerClientQemu):
    import bl808/wasm_psram_frames
    import wasm_d0_page_fixture
    var coldChunk: array[WasmMemoryChunkBytes.int, byte]
    var pageOwner: WasmPsramFrames
  else:
    import bl808/[wasm_remote_page_corpus, wasm_store]
    import cps/wasm/types
    var pagerMemory: ref LinearMemory

  const QemuPageBackingAddr = 0x8100_0000'u
  const QemuPageSlots = when defined(wasmD0PagerClientQemu): 8'u32 else: 4'u32
  var residentChunk: array[WasmMemoryChunkBytes.int, byte]

  when defined(wasmLpPagerClientQemu) or defined(wasmD0PagerClientQemu):
    const QemuPageServerAddr = 0x8101_0000'u
    proc fakePageRpc(request: openArray[uint8], response: pointer,
                     responseBytes: int, responseLen: ptr int,
                     timeoutMs: uint64): CpsVoidFuture =
      discard timeoutMs
      result = newCpsVoidFuture()
      let server = cast[ptr WasmPageWireServer](QemuPageServerAddr)
      let outBuf = cast[ptr UncheckedArray[byte]](response)
      let size = server[].processWasmPageWire(request,
        outBuf.toOpenArray(0, responseBytes - 1))
      if size <= 0:
        result.fail(newException(IOError, "page RPC failed"))
      else:
        responseLen[] = size
        result.complete()

  proc qemuPageRead(ctx: pointer, slot: uint32,
                    dst: ptr UncheckedArray[byte]): bool =
    discard ctx
    if slot >= QemuPageSlots: return false
    copyMem(dst, cast[pointer](QemuPageBackingAddr + slot.uint * 4096'u),
      WasmMemoryChunkBytes.int)
    true

  proc qemuPageWrite(ctx: pointer, slot: uint32,
                     src: ptr UncheckedArray[byte]): bool =
    discard ctx
    if slot >= QemuPageSlots: return false
    let destination = cast[pointer](QemuPageBackingAddr + slot.uint * 4096'u)
    zeroMem(destination, 4096)
    copyMem(destination, src, WasmMemoryChunkBytes.int)
    true

  when defined(wasmLpPagerQemu):
    proc makePagerMemory(ctx: pointer, memType: MemType): ref LinearMemory =
      discard ctx
      if memType.limits.min != 2 or memType.limits.max != 2: return nil
      pagerMemory

  when defined(wasmPagedMigrationQemu):
    when not defined(wasmLpPagerQemu): import cps/wasm/types
    when defined(wasmStreamMigration):
      from cps/wasm/runtime import WasmPortableStaging

    proc makePagerDestination(ctx: pointer, memType: MemType): ref LinearMemory =
      if memType.limits.min != 2 or memType.limits.max != 2: return nil
      const chunks = when defined(bl808lp): 2'u32 else: 3'u32
      let config = LinearMemoryConfig(initialPages: 2, maxPages: 2, admissionPages: 2,
        maxCommittedChunks: chunks, residentChunks: 1)
      new(result)
      let storage = cast[ptr UncheckedArray[byte]](addr residentChunk[0])
      let status = result[].initLinearMemoryIn(config, storage, residentChunk.len.uint32,
        pageClient.addr.linearMemoryBacking())
      if status != lmOk: return nil

    proc migratePagedTask(base: ptr UncheckedArray[byte], size, id: uint32): bool =
      let before = getWasmTaskMemoryTelemetry(id)
      if before.pageOuts == 0 or before.pageIns != 0: return false
      var polls = 0
      when defined(wasmStreamMigration):
        const
          stageCapacity = 4096
          stageAddr = QemuPageBackingAddr + 0x20000'u
        var capture = beginWasmTaskMigrationStream(id, maxBytes = stageCapacity)
        if capture.status != wasmMigrationOk or
            retireWasmTaskMigration(id) != wasmMigrationBadState:
          return false
        capture.staged = WasmPortableStaging(data: cast[ptr UncheckedArray[byte]](stageAddr))
        var part: array[460, byte]
        var status = wasmMigrationPending
        while status == wasmMigrationPending and polls < 32:
          var count: int
          status = readWasmTaskMigrationStream(id, part, count)
          if count > stageCapacity - capture.staged.len: return false
          if count > 0:
            copyMem(addr capture.staged.data[capture.staged.len], addr part[0], count)
            capture.staged.len += count
          inc polls
        if status != wasmMigrationOk or capture.staged.len == 0: return false
      else:
        var capture = beginWasmTaskMigrationCapture(id, maxBytes = 512)
        if capture.status != wasmMigrationPending or
            retireWasmTaskMigration(id) != wasmMigrationBadState:
          return false
        while capture.status == wasmMigrationPending and polls < 32:
          capture = pollWasmTaskMigrationCapture(id)
          inc polls
      if capture.status != wasmMigrationOk or getWasmTaskMemoryTelemetry(id) != before or
          retireWasmTaskMigration(id) != wasmMigrationOk:
        return false
      when defined(wasmLpPagerQemu): pagerMemory = nil
      var dest = prepareFullWasmMigrationImage(base, size, move capture,
        memoryFactory = makePagerDestination, allowPagedRestore = true)
      if dest.status != wasmSchedRestorePending or
          activateWasmTaskMigration(dest.id) != wasmMigrationBadState:
        return false
      polls = 0
      while dest.status == wasmSchedRestorePending and polls < 40:
        dest = pollFullWasmMigrationRestore(dest.id)
        inc polls
      let restored = getWasmTaskMemoryTelemetry(dest.id)
      if dest.status != wasmSchedOk or dest.state != wasmTaskMigrating or
          restored.residentChunks != 1 or restored.pageOuts == 0 or restored.pageIns != 0 or
          activateWasmTaskMigration(dest.id) != wasmMigrationOk:
        return false
      var current = getWasmTask(dest.id)
      polls = 0
      while current.state in {wasmTaskYielded, wasmTaskBlockedMemory} and polls < 80:
        current = if current.state == wasmTaskBlockedMemory: serviceWasmTaskMemoryFault(dest.id)
                  else: resumeWasmTask(dest.id, 32)
        inc polls
      current.status == wasmSchedOk and current.state == wasmTaskExited and
        current.result == 305419896'i32 and getWasmTaskMemoryTelemetry(dest.id).pageIns > 0

when defined(wasmFullThroughputBench):
  {.emit: """
  static inline unsigned int wasm_bench_cycles(void) {
    unsigned int value;
    __asm__ volatile("csrr %0, mcycle" : "=r"(value));
    return value;
  }
  """.}
  proc benchCycles(): uint32 {.importc: "wasm_bench_cycles", nodecl.}

when defined(wasmRtResidentQemu):
  {.emit: """
  static unsigned long long wasm_rt_virt_time(void) {
    const volatile unsigned int * const time = (void *)0x0200bff8UL;
    unsigned int hi, lo, end;
    do {
      hi = time[1];
      lo = time[0];
      end = time[1];
    } while (hi != end);
    return ((unsigned long long)hi << 32) | lo;
  }

  static int wasm_rt_virt_wait(unsigned long long deadline) {
    volatile unsigned int * const compare = (void *)0x02004000UL;
    const unsigned long timer_bit = 1UL << 7;
    unsigned long pending;
    int waited = 0;
    /* With global MIE clear, the locally enabled timer wakes WFI and
       remains pending for the test driver to observe. */
    __asm__ volatile("csrc mstatus, %0" :: "r"(8UL) : "memory");
    compare[1] = ~0U;
    compare[0] = (unsigned int)deadline;
    compare[1] = (unsigned int)(deadline >> 32);
    __asm__ volatile("csrs mie, %0" :: "r"(timer_bit) : "memory");
    while (wasm_rt_virt_time() < deadline) {
      __asm__ volatile("wfi" ::: "memory");
      waited = 1;
    }
    __asm__ volatile("csrr %0, mip" : "=r"(pending));
    __asm__ volatile("csrc mie, %0" :: "r"(timer_bit) : "memory");
    compare[1] = ~0U;
    compare[0] = ~0U;
    return waited && (pending & timer_bit) != 0;
  }
  """.}
  proc virtRtTime(): uint64 {.importc: "wasm_rt_virt_time", nodecl.}
  proc waitForRtTimer(deadline: uint64): cint {.importc: "wasm_rt_virt_wait", nodecl.}
  proc rtTick(): uint64 {.nimcall.} = virtRtTime()

{.emit: """
__asm__(
  ".section .init,\"ax\"\n.globl _start\n_start:\n"
  ".option push\n.option norelax\nla gp, __global_pointer$\n.option pop\n"
  "la sp, _estack\ncsrw mie, zero\nli t0, 0x6000\ncsrs mstatus, t0\n"
  "la t0, _sbss\nla t1, _ebss\n"
  "1: bgeu t0, t1, 2f\nsw zero, 0(t0)\naddi t0, t0, 4\nj 1b\n"
  "2: la t0, _sstack\nla t1, _estack\nli t2, 0xA5A5A5A5\n"
  "4: bgeu t0, t1, 5f\nsw t2, 0(t0)\naddi t0, t0, 4\nj 4b\n"
  "5: call wasmQemuHeapInit\ncall NimMain\ncall wasmQemuMain\n"
  "3: wfi\nj 3b\n.text\n"
);
""".}

proc wasmQemuHeapInit() {.exportc, cdecl.} = heapInit()

proc putChar(c: char) =
  while (volatileLoad(cast[ptr uint8](0x10000005'u)) and 0x20) == 0: discard
  volatileStore(cast[ptr uint8](0x10000000'u), uint8(c))

proc line(s: string) =
  for c in s: putChar(c)
  putChar('\n')

proc hex32(value: uint32) =
  const digits = "0123456789abcdef"
  for shift in countdown(7, 0):
    putChar(digits[int((value shr (shift * 4)) and 15'u32)])

{.emit: "extern unsigned int _sstack, _estack;".}
var stackStart {.importc: "_sstack", nodecl.}: uint32
var stackEnd {.importc: "_estack", nodecl.}: uint32

proc stackUsed(): uint32 =
  let stackBytes = (cast[uint](addr stackEnd) - cast[uint](addr stackStart)).uint32
  let words = cast[ptr UncheckedArray[uint32]](addr stackStart)
  var untouched = 0'u32
  while untouched < stackBytes and words[int(untouched div 4)] == 0xA5A5_A5A5'u32:
    untouched += 4
  stackBytes - untouched

proc finish(ok: bool) {.noreturn.} =
  volatileStore(cast[ptr uint32](0x100000'u), if ok: 0x5555'u32 else: 0x3333'u32)
  while true: discard

when defined(wasmFullThroughputBench):
  proc throughputBench() =
    let module = decodeModule(WasmFullBaselineModule)
    validateModule(module)
    var vm = initWasmVM()
    let idx = vm.instantiate(module, [])
    const iterations = 128
    for i in 0 ..< 16:
      discard vm.invoke(idx, "add", [wasmI32(i.int32), wasmI32(23)])
      discard vm.invoke(idx, "f64bits", [])
      discard vm.invoke(idx, "indirect", [wasmI32(i.int32), wasmI32(23)])
    let addStart = benchCycles()
    for i in 0 ..< iterations:
      discard vm.invoke(idx, "add", [wasmI32(i.int32), wasmI32(23)])
    let addCycles = benchCycles() - addStart
    let f64Start = benchCycles()
    for i in 0 ..< iterations:
      discard vm.invoke(idx, "f64bits", [])
    let f64Cycles = benchCycles() - f64Start
    let indirectStart = benchCycles()
    for i in 0 ..< iterations:
      discard vm.invoke(idx, "indirect", [wasmI32(i.int32), wasmI32(23)])
    let indirectCycles = benchCycles() - indirectStart
    line("bench iterations=0x")
    hex32(iterations)
    putChar('\n')
    line("bench add cycles=0x")
    hex32(addCycles)
    putChar('\n')
    line("bench f64 cycles=0x")
    hex32(f64Cycles)
    putChar('\n')
    line("bench indirect cycles=0x")
    hex32(indirectCycles)
    putChar('\n')
    line("bench heap peak bytes=0x")
    hex32(heapStats().highWaterBytes.uint32)
    putChar('\n')
    line("bench native stack used bytes=0x")
    hex32(stackUsed())
    putChar('\n')

proc wasmQemuMain() {.exportc, cdecl.} =
  let caps = wasmRuntimeCapabilities()
  when defined(wasmFunctionReferencesProbe):
    when defined(wasmAtomicWaitProbe):
      if not caps.supportsAtomicWait:
        line("[FAIL] atomic wait capability")
        finish(false)
    if not caps.fullInterpreter or not runFunctionReferenceProbe() or not heapCheck():
      line("[FAIL] function reference probe")
      finish(false)
    line("heap peak bytes=0x")
    hex32(heapStats().highWaterBytes.uint32)
    putChar('\n')
    line("native stack used bytes=0x")
    hex32(stackUsed())
    putChar('\n')
    const corpus = when defined(wasmAtomicWaitProbe): " atomic wait"
      elif defined(wasmSharedMemoryProbe): " shared memory"
      elif defined(wasmSharedCoreTypes): " shared core types"
      else: " function references"
    when defined(bl808lp): line("[PASS] LP RV32E" & corpus)
    elif defined(bl808d0): line("[PASS] D0 RV64" & corpus)
    else: line("[PASS] M0 RV32" & corpus)
    finish(true)
  when defined(wasmMigrationQemu):
    when defined(wasmStagedMigrationQemu):
      const moduleBytes = WasmDenseModule
      const sliceFuel = WasmDenseCheckpoint
      const expected = WasmDenseResult
      const factory = denseMemoryFactory
      const args = [WasmDenseProbeBytes]
    elif defined(wasmMutableMigrationQemu):
      const moduleBytes = WasmMutableModule
      const sliceFuel = WasmMutableInstructionsBeforeCapture
      const expected = WasmMutableResult
      const factory = mutableMemoryFactory
      const args = default(array[0, int32])
    else:
      const moduleBytes = WasmMigrationModule
      const sliceFuel = 1'u32
      const expected = 42'i32
      const factory = nil
      const args = default(array[0, int32])
    var image = newSeq[byte](WasmProgramHeaderLen.int + moduleBytes.len)
    if initWasmProgramImage(
        cast[ptr UncheckedArray[byte]](addr image[0]), image.len.uint32,
        moduleBytes) != wasmProgramOk:
      finish(false)
    let base = cast[ptr UncheckedArray[byte]](addr image[0])
    resetWasmScheduler()
    let source = startFullWasmImageTaskI32(base, image.len.uint32,
      "run", args, maxTotalFuel = 64, slotLabel = 2, memoryFactory = factory)
    if source.status != wasmSchedOk or
        resumeWasmTask(source.id, sliceFuel).state != wasmTaskYielded:
      line("[FAIL] migration source execution")
      finish(false)
    when defined(wasmStagedMigrationQemu):
      let address = when defined(bl808lp): cast[uint](addr stagingRam[0]) else: 0x8100_0000'u
      let staging = WasmPortableStaging(data: cast[ptr UncheckedArray[byte]](address),
        len: WasmDenseProbeCapacity)
      if captureWasmTaskMigration(source.id, maxBytes = WasmDenseInlineLimit).status != wasmMigrationTooLarge:
        line("[FAIL] migration inline admission")
        finish(false)
      let state = captureWasmTaskMigration(source.id, maxBytes = staging.len, staging = staging)
      if state.bytes.len != 0 or state.staged.data != staging.data or
          state.staged.len <= WasmDenseInlineLimit:
        line("[FAIL] migration staging")
        finish(false)
      line("migration staged bytes=0x")
      hex32(state.staged.len.uint32)
      putChar('\n')
    else:
      let state = captureWasmTaskMigration(source.id, maxBytes = 512)
    if state.status != wasmMigrationOk or
        getWasmTask(source.id).state != wasmTaskMigrating or
        retireWasmTaskMigration(source.id) != wasmMigrationOk:
      line("[FAIL] migration snapshot or retirement")
      finish(false)
    let dest = prepareFullWasmMigrationImage(base, image.len.uint32, state,
      memoryFactory = factory)
    if dest.status != wasmSchedOk or dest.state != wasmTaskMigrating or
        activateWasmTaskMigration(dest.id) != wasmMigrationOk:
      line("[FAIL] migration destination restore")
      finish(false)
    var current = getWasmTask(dest.id)
    var attempts = 0
    while current.state == wasmTaskYielded and attempts < 16:
      current = resumeWasmTask(dest.id, 2)
      inc attempts
    if current.status != wasmSchedOk or current.state != wasmTaskExited or
        current.result != expected or current.fuelUsed <= state.fuelUsed:
      line("[FAIL] migration destination execution")
      finish(false)
    line("migration heap peak bytes=0x")
    hex32(heapStats().highWaterBytes.uint32)
    putChar('\n')
    line("migration native stack used bytes=0x")
    hex32(stackUsed())
    putChar('\n')
    when defined(bl808lp): line("[PASS] LP full WASM migration")
    elif defined(bl808d0): line("[PASS] D0 full WASM migration")
    else: line("[PASS] M0 full WASM migration")
    finish(true)
  when defined(wasmD0JitQemu):
    let passed = runD0Jit()
    line("D0 JIT heap peak bytes=0x")
    hex32(heapStats().highWaterBytes.uint32)
    putChar('\n')
    line("D0 JIT native stack used bytes=0x")
    hex32(stackUsed())
    putChar('\n')
    if passed and heapCheck():
      line("[PASS] D0 RV64 JIT add/f64/fallback")
      finish(true)
    line("[FAIL] D0 RV64 JIT add/f64/fallback")
    finish(false)
  when defined(wasmComponentCoreGraphQemu) or defined(wasmComponentIndirectQemu) or
       defined(wasmComponentFlatQemu) or defined(wasmComponentNestedListQemu) or
       defined(wasmComponentNestedValueQemu) or defined(wasmComponentResourceBundleQemu) or
       defined(wasmComponentLinkedResourceBundleQemu) or defined(wasmComponentCrossPostReturnQemu) or
       defined(wasmComponentStringQemu) or defined(wasmComponentStringResultQemu) or
       defined(wasmComponentMultiMemoryQemu) or defined(wasmComponentMapQemu) or
       defined(wasmComponentFixedListQemu) or defined(wasmComponentContextQemu) or
       defined(wasmComponentBytesQemu) or defined(wasmComponentWordsQemu) or
       defined(wasmComponentQwordsQemu) or
       defined(wasmComponentOptionStringQemu) or
       defined(wasmComponentRecordQemu) or
       defined(wasmComponentRecordMixedQemu) or
       defined(wasmComponentOptionQemu) or defined(wasmComponentVariantQemu) or
       defined(wasmComponentEnumQemu) or defined(wasmComponentResultQemu) or
       defined(wasmComponentTupleQemu) or defined(wasmComponentFlagsQemu) or
       defined(wasmComponentCharQemu):
    let passed = runComponentString() and (when defined(wasmComponentFixedListQemu):
      runComponentString(FixedListIndirectFixture, secondaryFixture = true)
    elif defined(wasmComponentContextQemu) and defined(bl808lp):
      runComponentString(ContextPostReturnFixture, secondaryFixture = true)
    else: true)
    line("component heap peak bytes=0x")
    hex32(heapStats().highWaterBytes.uint32)
    putChar('\n')
    line("component native stack used bytes=0x")
    hex32(stackUsed())
    putChar('\n')
    if passed and heapCheck():
      when defined(wasmComponentMapQemu):
        when defined(bl808lp): line("[PASS] LP RV32E component map")
        elif defined(bl808d0): line("[PASS] D0 RV64 component map")
        else: line("[PASS] M0 RV32 component map")
      elif defined(wasmComponentFixedListQemu):
        when defined(bl808lp): line("[PASS] LP RV32E component fixed-list")
        elif defined(bl808d0): line("[PASS] D0 RV64 component fixed-list")
        else: line("[PASS] M0 RV32 component fixed-list")
      elif defined(wasmComponentContextQemu):
        when defined(bl808lp): line("[PASS] LP RV32E component context")
        elif defined(bl808d0): line("[PASS] D0 RV64 component context")
        else: line("[PASS] M0 RV32 component context")
      elif defined(wasmComponentMultiMemoryQemu):
        when defined(bl808lp): line("[PASS] LP RV32E component multi-memory")
        elif defined(bl808d0): line("[PASS] D0 RV64 component multi-memory")
        else: line("[PASS] M0 RV32 component multi-memory")
      elif defined(wasmComponentCrossPostReturnQemu):
        when defined(bl808lp): line("[PASS] LP RV32E component cross-post-return")
        elif defined(bl808d0): line("[PASS] D0 RV64 component cross-post-return")
        else: line("[PASS] M0 RV32 component cross-post-return")
      elif defined(wasmComponentLinkedResourceBundleQemu):
        when defined(bl808d0): line("[PASS] D0 RV64 component linked-resource-bundle")
        else: line("[PASS] M0 RV32 component linked-resource-bundle")
      elif defined(wasmComponentResourceBundleQemu):
        when defined(bl808d0): line("[PASS] D0 RV64 component resource-bundle")
        else: line("[PASS] M0 RV32 component resource-bundle")
      elif defined(wasmComponentNestedValueQemu):
        when defined(bl808lp): line("[PASS] LP RV32E component nested-value")
        elif defined(bl808d0): line("[PASS] D0 RV64 component nested-value")
        else: line("[PASS] M0 RV32 component nested-value")
      elif defined(wasmComponentNestedListQemu):
        when defined(bl808lp): line("[PASS] LP RV32E component nested-list")
        elif defined(bl808d0): line("[PASS] D0 RV64 component nested-list")
        else: line("[PASS] M0 RV32 component nested-list")
      elif defined(wasmComponentFlatQemu):
        when defined(bl808lp): line("[PASS] LP RV32E component flat-aggregates")
        elif defined(bl808d0): line("[PASS] D0 RV64 component flat-aggregates")
        else: line("[PASS] M0 RV32 component flat-aggregates")
      elif defined(wasmComponentIndirectQemu):
        when defined(bl808lp): line("[PASS] LP RV32E component indirect")
        elif defined(bl808d0): line("[PASS] D0 RV64 component indirect")
        else: line("[PASS] M0 RV32 component indirect")
      elif defined(wasmComponentCoreGraphQemu):
        when defined(bl808lp): line("[PASS] LP RV32E component core-graph")
        elif defined(bl808d0): line("[PASS] D0 RV64 component core-graph")
        else: line("[PASS] M0 RV32 component core-graph")
      elif defined(wasmComponentRecordMixedQemu):
        when defined(bl808lp): line("[PASS] LP RV32E component record-mixed")
        elif defined(bl808d0): line("[PASS] D0 RV64 component record-mixed")
        else: line("[PASS] M0 RV32 component record-mixed")
      elif defined(wasmComponentFlagsQemu):
        when defined(bl808lp): line("[PASS] LP RV32E component flags")
        elif defined(bl808d0): line("[PASS] D0 RV64 component flags")
        else: line("[PASS] M0 RV32 component flags")
      elif defined(wasmComponentCharQemu):
        when defined(bl808lp): line("[PASS] LP RV32E component char")
        elif defined(bl808d0): line("[PASS] D0 RV64 component char")
        else: line("[PASS] M0 RV32 component char")
      elif defined(wasmComponentTupleQemu):
        when defined(bl808lp): line("[PASS] LP RV32E component tuple")
        elif defined(bl808d0): line("[PASS] D0 RV64 component tuple")
        else: line("[PASS] M0 RV32 component tuple")
      elif defined(wasmComponentResultQemu):
        when defined(bl808lp): line("[PASS] LP RV32E component result")
        elif defined(bl808d0): line("[PASS] D0 RV64 component result")
        else: line("[PASS] M0 RV32 component result")
      elif defined(wasmComponentEnumQemu):
        when defined(bl808lp): line("[PASS] LP RV32E component enum")
        elif defined(bl808d0): line("[PASS] D0 RV64 component enum")
        else: line("[PASS] M0 RV32 component enum")
      elif defined(wasmComponentVariantQemu):
        when defined(bl808lp): line("[PASS] LP RV32E component variant")
        elif defined(bl808d0): line("[PASS] D0 RV64 component variant")
        else: line("[PASS] M0 RV32 component variant")
      elif defined(wasmComponentOptionQemu):
        when defined(bl808lp): line("[PASS] LP RV32E component option")
        elif defined(bl808d0): line("[PASS] D0 RV64 component option")
        else: line("[PASS] M0 RV32 component option")
      elif defined(wasmComponentRecordQemu):
        when defined(bl808lp): line("[PASS] LP RV32E component record")
        elif defined(bl808d0): line("[PASS] D0 RV64 component record")
        else: line("[PASS] M0 RV32 component record")
      elif defined(wasmComponentBytesQemu):
        when defined(bl808lp): line("[PASS] LP RV32E component bytes")
        elif defined(bl808d0): line("[PASS] D0 RV64 component bytes")
        else: line("[PASS] M0 RV32 component bytes")
      elif defined(wasmComponentWordsQemu):
        when defined(bl808lp): line("[PASS] LP RV32E component words")
        elif defined(bl808d0): line("[PASS] D0 RV64 component words")
        else: line("[PASS] M0 RV32 component words")
      elif defined(wasmComponentQwordsQemu):
        when defined(bl808lp): line("[PASS] LP RV32E component qwords")
        elif defined(bl808d0): line("[PASS] D0 RV64 component qwords")
        else: line("[PASS] M0 RV32 component qwords")
      elif defined(wasmComponentOptionStringQemu):
        when defined(bl808lp): line("[PASS] LP RV32E component option-string")
        elif defined(bl808d0): line("[PASS] D0 RV64 component option-string")
        else: line("[PASS] M0 RV32 component option-string")
      elif defined(wasmComponentStringResultQemu):
        when defined(bl808lp): line("[PASS] LP RV32E component string-result")
        elif defined(bl808d0): line("[PASS] D0 RV64 component string-result")
        else: line("[PASS] M0 RV32 component string-result")
      else:
        when defined(bl808lp): line("[PASS] LP RV32E component string")
        elif defined(bl808d0): line("[PASS] D0 RV64 component string")
        else: line("[PASS] M0 RV32 component string")
      finish(true)
    line("[FAIL] component string")
    finish(false)
  when defined(wasmComponentNestedQemu) or defined(wasmComponentInterfaceQemu) or
       defined(wasmComponentResourceQemu) or defined(wasmComponentForeignBorrowQemu) or
       defined(wasmComponentCoreModuleQemu) or defined(wasmComponentDefinitionRelayQemu) or
       defined(wasmComponentNestedInstanceQemu) or defined(wasmComponentOuterCaptureQemu) or
       defined(wasmComponentFunctionEqualityQemu) or defined(wasmComponentContractEqualityQemu) or
       defined(wasmComponentInstanceEqualityQemu) or defined(wasmComponentContractCaptureQemu) or
       defined(wasmComponentLexicalResourceValueQemu) or defined(wasmComponentLocalLowerQemu) or
       defined(wasmComponentGeneratedCoreQemu) or defined(wasmComponentTagLinkQemu) or
       defined(wasmComponentHostDefinitionQemu) or defined(wasmComponentTypedImportQemu) or
       defined(wasmComponentResourceVisibilityQemu) or defined(wasmComponentNameAttributesQemu) or
       defined(wasmComponentCoreFunctionTypesQemu) or defined(wasmComponentResourceAscriptionQemu) or
       defined(wasmComponentCallbackQemu) or defined(wasmComponentSubtasksQemu) or
       defined(wasmComponentErrorContextQemu):
    when defined(wasmComponentErrorContextQemu):
      const fixtureLabel = "error-context"
      let passed = checkErrorContextFixture(ErrorContextFixture)
    elif defined(wasmComponentNestedInstanceQemu):
      const fixtureLabel = "nested-instance"
      let passed = runNestedInstance(NestedInstanceFixture) and
        (when defined(bl808lp): true
         else: runNestedInstance(TypedInstanceFixture) and runNestedInstance(LexicalResourceFixture))
    elif defined(wasmComponentDefinitionRelayQemu):
      const fixtureLabel = "definition-relay"
      let passed = runDefinitionRelay(DefinitionFixture) and
        runDefinitionRelay(InterfaceDefinitionFixture, "run-control", 85)
    elif defined(wasmComponentOuterCaptureQemu):
      const fixtureLabel = "outer-capture"
      let passed = checkOuterCapture()
    elif defined(wasmComponentFunctionEqualityQemu):
      const fixtureLabel = "function-equality"
      let passed = checkFunctionEquality()
    elif defined(wasmComponentContractEqualityQemu):
      const fixtureLabel = "contract-equality"
      let passed = checkTypeEquality()
    elif defined(wasmComponentInstanceEqualityQemu):
      const fixtureLabel = "instance-equality"
      let passed = checkTypeEquality()
    elif defined(wasmComponentContractCaptureQemu):
      const fixtureLabel = "contract-capture"
      let passed = checkTypeEquality()
    elif defined(wasmComponentLexicalResourceValueQemu):
      const fixtureLabel = "lexical-resource-value"
      let passed = checkTypeEquality()
    elif defined(wasmComponentLocalLowerQemu):
      const fixtureLabel = "local-lower"
      let passed = checkTypeEquality()
    elif defined(wasmComponentGeneratedCoreQemu):
      const fixtureLabel = "generated-core"
      let passed = checkGeneratedCore()
    elif defined(wasmComponentTagLinkQemu):
      const fixtureLabel = "tag-link"
      let passed = checkTagLink()
    elif defined(wasmComponentCoreFunctionTypesQemu):
      const fixtureLabel = "core-function-types"
      let passed = checkCoreFunctionTypes(cast[seq[byte]](TypedCoreImport)) and
        checkCoreFunctionTypes(cast[seq[byte]](TypedCoreIndirect), indirect = true)
    elif defined(wasmComponentCoreModuleQemu):
      const fixtureLabel = "core-module"
      let passed = runHostCoreModule() and runLinkedCoreModule(InterfaceCoreModule) and
        (when defined(bl808lp): true else: runLinkedCoreModule(CoreModuleRelay))
    elif defined(wasmComponentHostDefinitionQemu):
      const fixtureLabel = "host-definition"
      let passed = runHostDefinition()
    elif defined(wasmComponentTypedImportQemu):
      const fixtureLabel = "typed-import"
      let passed = runTypedImport(TypedImportFixture) and
        runTypedImport(TypedReexportFixture) and
        runTypedImport(TypedResourceInterfaceFixture) and runTypedInterface()
    elif defined(wasmComponentForeignBorrowQemu):
      const fixtureLabel = "foreign-borrow"
      let passed = runForeignBorrow()
    elif defined(wasmComponentResourceQemu):
      const fixtureLabel = "resource"
      let passed = runComponentResource()
    elif defined(wasmComponentResourceVisibilityQemu):
      const fixtureLabel = "resource-visibility"
      let passed = runResourceRelay()
    elif defined(wasmComponentResourceAscriptionQemu):
      const fixtureLabel = "resource-ascription"
      let passed = runResourceAscription()
    elif defined(wasmComponentCallbackQemu):
      const fixtureLabel = "callback-turns"
      let passed = runCallbackTurns()
    elif defined(wasmComponentSubtasksQemu):
      const fixtureLabel = when defined(wasmComponentThreadSpawnQemu):
        "thread-spawn"
      elif defined(wasmComponentGuestThreadsQemu):
        "guest-threads"
      elif defined(wasmComponentHostEndpointQemu):
        "host-endpoint"
      elif defined(wasmComponentStreamQemu):
        "stream-partial"
      elif defined(wasmComponentFutureWaitQemu):
        "future-wait"
      elif defined(wasmComponentFutureTransferQemu):
        "future-transfer"
      elif defined(wasmComponentAsyncBorrowsForeignQemu):
        "async-borrows-cross-component"
      elif defined(wasmComponentAsyncBorrowsQemu):
        "async-borrows"
      elif defined(wasmComponentSyncLowerQemu):
        "async-sync-lower"
      elif defined(wasmComponentStackfulQemu):
        "async-stackful"
      elif defined(wasmComponentCancellationQemu):
        "async-subtask-cancellation"
      elif defined(wasmComponentSubtasksDiagnosticQemu):
        "async-subtasks-cross-component"
      else: "async-subtasks"
      let passed = try:
        when defined(wasmComponentGuestThreadsQemu): runGuestThreadFixtures()
        else: runSubtasks()
      except ComponentError as error:
        line(error.msg)
        false
    elif defined(wasmComponentInterfaceQemu):
      const fixtureLabel = "named-interface"
      let passed = runComponentInterface()
    elif defined(wasmComponentNameAttributesQemu):
      const fixtureLabel = "name-attributes"
      let passed = checkNameAttributes(cast[seq[byte]](NameAttributesFixture))
    else:
      const fixtureLabel = "nested-bool"
      let passed = runComponentNested()
    line("component heap peak bytes=0x")
    hex32(heapStats().highWaterBytes.uint32)
    putChar('\n')
    line("component native stack used bytes=0x")
    hex32(stackUsed())
    putChar('\n')
    if passed and heapCheck():
      when defined(bl808lp): line("[PASS] LP RV32E component " & fixtureLabel)
      elif defined(bl808d0): line("[PASS] D0 RV64 component " & fixtureLabel)
      else: line("[PASS] M0 RV32 component " & fixtureLabel)
      finish(true)
    line("[FAIL] component " & fixtureLabel)
    finish(false)
  when defined(wasmComponentQemu):
    let passed = runComponentScalar() and runComponentImports()
    line("component heap peak bytes=0x")
    hex32(heapStats().highWaterBytes.uint32)
    putChar('\n')
    line("component native stack used bytes=0x")
    hex32(stackUsed())
    putChar('\n')
    if passed and heapCheck():
      when defined(bl808lp): line("[PASS] LP RV32E component scalar")
      elif defined(bl808d0): line("[PASS] D0 RV64 component scalar")
      else: line("[PASS] M0 RV32 component scalar")
      finish(true)
    line("[FAIL] component scalar")
    finish(false)
  when defined(wasmLpPagerQemu) or defined(wasmD0PagerClientQemu):
    let serverBacking = LinearMemoryBacking(slots: QemuPageSlots,
      readPage: qemuPageRead, writePage: qemuPageWrite)
    when defined(wasmLpPagerClientQemu) or defined(wasmD0PagerClientQemu):
      let server = cast[ptr WasmPageWireServer](QemuPageServerAddr)
      if not server[].initWasmPageWireRange(serverBacking, 17, QemuPageSlots - 4,
          4, WasmMemoryChunkBytes.uint16):
        line("[FAIL] pager server initialization")
        finish(false)
      wasmPageRpc = fakePageRpc
      if not pageClient.initWasmPageClient(4):
        line("[FAIL] pager client initialization")
        finish(false)
      let backing = pageClient.addr.linearMemoryBacking()
    else:
      let backing = serverBacking
    let resident = cast[ptr UncheckedArray[byte]](addr residentChunk[0])
    resetWasmScheduler()
    when defined(wasmD0PagerClientQemu):
      if not pageOwner.reserveEmulatedPsramFrames(resident,
          cast[ptr UncheckedArray[byte]](addr coldChunk[0]), WasmMemoryChunkBytes,
          WasmMemoryChunkBytes, 2, 3, backing, swapSlots = 4):
        line("[FAIL] pager frame reservation")
        finish(false)
      var image: D0PageImage
      let started = startD0PageRoundtrip(image, pageOwner, slotLabel = 2)
    else:
      new(pagerMemory)
      let config = LinearMemoryConfig(initialPages: 2, maxPages: 2,
        admissionPages: 2, maxCommittedChunks: 4, residentChunks: 1)
      if pagerMemory[].initLinearMemoryIn(config, resident,
          residentChunk.len.uint32, backing) != lmOk:
        finish(false)
      var image = newSeq[byte](WasmProgramHeaderLen.int + WasmRemotePageCorpus.len)
      if initWasmProgramImage(cast[ptr UncheckedArray[byte]](addr image[0]),
          image.len.uint32, WasmRemotePageCorpus) != wasmProgramOk:
        finish(false)
      let started = startFullWasmImageTaskI32(
        cast[ptr UncheckedArray[byte]](addr image[0]), image.len.uint32,
        "cross_page", [], maxTotalFuel = 64, maxMemoryPages = 2, slotLabel = 2,
        memoryFactory = makePagerMemory)
    if started.status != wasmSchedOk:
      line("[FAIL] pager task initialization status=0x")
      hex32(started.status.ord.uint32)
      putChar('\n')
      finish(false)
    var current = started
    var attempts = 0
    while current.state in {wasmTaskReady, wasmTaskYielded, wasmTaskBlockedMemory}:
      if current.state == wasmTaskBlockedMemory:
        current = serviceWasmTaskMemoryFault(started.id)
      else:
        when defined(wasmPagedMigrationQemu):
          const checkpoint = when defined(wasmD0PagerClientQemu): 6'u32 else: 3'u32
          if current.fuelUsed == checkpoint: break
          current = resumeWasmTask(started.id, checkpoint - current.fuelUsed)
        else:
          current = resumeWasmTask(started.id, 10)
      inc attempts
      if attempts > 100:
        line("[FAIL] pager task poll limit")
        finish(false)
    when defined(wasmPagedMigrationQemu):
      if current.state != wasmTaskYielded or not migratePagedTask(
          cast[ptr UncheckedArray[byte]](addr image[0]), image.len.uint32, started.id):
        line("[FAIL] paged WASM migration")
        finish(false)
      line("pager heap peak bytes=0x")
      hex32(heapStats().highWaterBytes.uint32)
      putChar('\n')
      line("pager native stack used bytes=0x")
      hex32(stackUsed())
      putChar('\n')
      when defined(wasmStreamMigration):
        when defined(bl808d0): line("[PASS] D0 full WASM streamed migration")
        else: line("[PASS] LP full WASM streamed migration")
      else:
        when defined(bl808d0): line("[PASS] D0 full WASM paged migration")
        else: line("[PASS] LP full WASM paged migration")
      finish(true)
    if current.status != wasmSchedOk or current.state != wasmTaskExited or
        current.result != 305419896'i32:
      line("[FAIL] pager task status/state/trap/result=0x")
      hex32(current.status.ord.uint32)
      hex32(current.state.ord.uint32)
      hex32(current.trapCode.uint32)
      hex32(current.result.uint32)
      putChar('\n')
      finish(false)
    let telemetry = getWasmTaskMemoryTelemetry(started.id)
    if telemetry.pageIns == 0 or telemetry.pageOuts == 0:
      line("[FAIL] pager did not swap out and back in")
      finish(false)
    when defined(wasmD0PagerClientQemu):
      if not d0PageRoundtripPassed(current, telemetry):
        line("[FAIL] D0 pager telemetry")
        finish(false)
      line("pager page ins=0x")
      hex32(telemetry.pageIns)
      putChar('\n')
      line("pager page outs=0x")
      hex32(telemetry.pageOuts)
      putChar('\n')
    line("pager heap peak bytes=0x")
    hex32(heapStats().highWaterBytes.uint32)
    putChar('\n')
    line("pager native stack used bytes=0x")
    hex32(stackUsed())
    putChar('\n')
    when defined(wasmD0PagerClientQemu):
      line("[PASS] D0 full WASM page client task")
    elif defined(wasmLpPagerClientQemu):
      line("[PASS] LP full WASM page client task")
    else:
      line("[PASS] LP full WASM paged task")
    finish(true)
  when defined(wasmStealClientQemu):
    stealImage = newSeq[byte](WasmProgramHeaderLen.int +
                             WasmFullBaselineModule.len)
    if initWasmProgramImage(
        cast[ptr UncheckedArray[byte]](addr stealImage[0]),
        stealImage.len.uint32, WasmFullBaselineModule) != wasmProgramOk:
      finish(false)
    resetWasmScheduler()
    if not stealBroker()[].initWasmStealBroker(17, 100):
      finish(false)
    var job: WasmStealJob
    for i, c in "indirect": job.exportName[i] = c
    job.slot = 2
    job.argCount = 2
    job.args[0] = 20
    job.args[1] = 22
    job.affinityMask = QemuStealCore
    job.requiredBackends = WasmBackendInterpreter
    job.maxFuel = 64
    when defined(wasmSoftStealing):
      job.soft = WasmStealSoftSpec(releaseTick: 50_200, deadlineTick: 50_500,
        budgetTicks: 50, maxSliceTicks: 10, overrun: wrStop)
    wasmStealRpc = qemuStealRpc
    wasmStealPrepareHook = qemuStealPrepare
    if not stealClient.initWasmStealClient(123, 0):
      finish(false)
    if not stealClient.beginWasmStealSession() or stealClient.pollWasmSteal() != wscIdle or
        not stealClient.beginWasmStealOffer(job, 1, 17) or
        stealClient.pollWasmSteal() != wscIdle or stealClient.offerStatus != wssOk:
      finish(false)
    let jobId = stealClient.offeredJobId
    when defined(wasmSoftStealing):
      wasmStealClockNow = stealClock
      wasmStealClockRate = stealClockRate
      if initWasmRtScheduler(job.affinityMask, stealNow, 1000) != wrOk or
          not stealClient.enableWasmSoftStealing(WasmClockLimits(maxRoundTripTicks: 64,
            maxAgeTicks: 100, maxProjectionTicks: 1000, maxUncertaintyTicks: 64)):
        finish(false)
    if not stealClient.beginWasmSteal():
      finish(false)
    var polls = 0
    while stealClient.state == wscPending and polls < 10:
      discard stealClient.pollWasmSteal()
      inc polls
    if stealClient.state != wscReady or stealClient.jobId != jobId:
      finish(false)
    when defined(wasmSoftStealing):
      if nextWasmSchedulerRtWakeTick(stealNow, 0) != 225 or
          runWasmSchedulerRt(stealClock, 0) != 0:
        finish(false)
      stealNow = 225
      if runWasmSchedulerRt(stealClock, 0) != 1 or
          stealClient.softTelemetry.clockSamples != 1:
        finish(false)
    var current = getWasmTask(stealClient.taskId)
    var attempts = 0
    while current.state in {wasmTaskReady, wasmTaskYielded}:
      current = resumeWasmTask(stealClient.taskId, 2)
      inc attempts
      if attempts > 32: finish(false)
    if current.status != wasmSchedOk or current.state != wasmTaskExited or
        current.result != 42 or not stealClient.finishWasmSteal() or
        stealClient.pollWasmSteal() != wscIdle:
      finish(false)
    discard killWasmTask(current.id)
    if not stealClient.beginWasmStealReadOutcome(jobId, 17) or
        stealClient.pollWasmSteal() != wscIdle or stealClient.outcomeStatus != wssOk or
        stealClient.outcome.kind != wokReturned or stealClient.outcome.returnedI32() != 42 or
        stealClient.outcome.workerCoreBit != QemuStealCore or
        stealClient.outcome.fuelUsed != current.fuelUsed:
      finish(false)
    if not stealClient.beginWasmStealAckOutcome(jobId, 17) or
        stealClient.pollWasmSteal() != wscIdle or stealClient.outcomeStatus != wssOk or
        stealBroker()[].stateOfWasmStealJob(jobId) != wstEmpty:
      finish(false)
    line("steal client heap peak bytes=0x")
    hex32(heapStats().highWaterBytes.uint32)
    putChar('\n')
    line("steal client native stack used bytes=0x")
    hex32(stackUsed())
    putChar('\n')
    when defined(wasmSoftStealing):
      when defined(bl808m0): line("[PASS] M0 full WASM soft steal client")
      elif defined(bl808lp): line("[PASS] LP full WASM soft steal client")
      else: line("[PASS] D0 full WASM soft steal client")
    else:
      when defined(bl808m0): line("[PASS] M0 full WASM steal client")
      elif defined(bl808d0): line("[PASS] D0 full WASM steal client")
      else: line("[PASS] LP full WASM steal client")
    finish(true)
  when defined(wasmPsramFramesQemu):
    let passed = checkPsramFrames()
    line("PSRAM frame heap peak bytes=0x")
    hex32(heapStats().highWaterBytes.uint32)
    putChar('\n')
    line("PSRAM frame native stack used bytes=0x")
    hex32(stackUsed())
    putChar('\n')
    if passed and heapCheck():
      when defined(bl808d0): line("[PASS] D0 RV64 SRAM/PSRAM frames")
      else: line("[PASS] M0 RV32 SRAM/PSRAM frames")
      finish(true)
    line("[FAIL] SRAM/PSRAM frames")
    finish(false)
  when defined(wasmRtResidentQemu):
    new(rtResidentMemory)
    if rtResidentMemory[].initLinearMemoryIn(LinearMemoryConfig(
        initialPages: 1, maxPages: 1, admissionPages: 1,
        maxCommittedChunks: 1, residentChunks: 1),
        cast[ptr UncheckedArray[byte]](addr rtResidentChunk[0]),
        rtResidentChunk.len.uint32) != lmOk or
        rtResidentMemory[].pinRange(256, 4, writable = true) != lmOk:
      line("rt resident memory failed")
      finish(false)
    var image = newSeq[byte](WasmProgramHeaderLen.int + WasmRtResidentModule.len)
    if initWasmProgramImage(
        cast[ptr UncheckedArray[byte]](addr image[0]), image.len.uint32,
        WasmRtResidentModule) != wasmProgramOk:
      line("rt resident image failed")
      finish(false)
    resetWasmScheduler()
    let started = startFullWasmImageTaskI32(
      cast[ptr UncheckedArray[byte]](addr image[0]), image.len.uint32,
      "hard-slot", [], maxTotalFuel = 64, maxMemoryPages = 1,
      memoryFactory = makeRtResidentMemory)
    if started.status != wasmSchedOk:
      line("rt resident start failed")
      finish(false)
    wasmRtTestTick = rtTick
    wasmRtTestInstall = installRtHook
    wasmRtTestRearm = rearmRtHook
    let epoch = rtTick() + 500_000
    if initWasmRtScheduler(1, epoch, 10_000_000) != wrOk or
        admitWasmTaskRt(started.id, WasmRtSpec(
          class: wrHard, releaseTick: epoch, budgetTicks: 1_000_000,
          maxSliceTicks: 1_000_000, startJitterTicks: 1_000_000,
          affinityMask: 1, slotOffsetTicks: 0, slotLengthTicks: 5_000_000,
          residentWorkingSet: true, boundedImports: true,
          noPeerDependency: true, noFlashMutation: true)) != wrOk or
        not attachWasmRtKernel():
      line("rt resident admission failed")
      finish(false)
    if rtWakeTick != epoch or getWasmTask(started.id).resumes != 0 or
        waitForRtTimer(rtWakeTick) == 0:
      line("rt compare did not wake WFI")
      finish(false)
    rtWakeTick = rtHook(rtTick())
    let task = getWasmTask(started.id)
    let rtMemoryStats = getWasmTaskMemoryTelemetry(started.id)
    let telemetry = wasmSchedulerRtTelemetry()
    if task.status != wasmSchedOk or task.state != wasmTaskExited or
        task.result != 305419899'i32 or not rtMemoryStats.found or
        rtMemoryStats.committedChunks != 1 or
        rtMemoryStats.residentChunks != 1 or
        rtMemoryStats.wouldBlock != 0 or rtMemoryStats.pageIns != 0 or
        rtMemoryStats.pageOuts != 0 or telemetry.hardFaults != 0 or
        telemetry.deadlineMisses != 0 or telemetry.sliceOverruns != 0 or
        telemetry.startJitterMisses != 0 or telemetry.starts != 1 or rtWakeTick != 0:
      line("rt resident result failed")
      finish(false)
    line("rt slice ticks=0x")
    hex32(telemetry.maxSliceTicks.uint32)
    putChar('\n')
    line("rt start jitter ticks=0x")
    hex32(telemetry.maxStartJitterTicks.uint32)
    putChar('\n')
    line("rt heap peak bytes=0x")
    hex32(heapStats().highWaterBytes.uint32)
    putChar('\n')
    line("rt native stack used bytes=0x")
    hex32(stackUsed())
    putChar('\n')
    when defined(bl808lp): line("[PASS] LP RV32E resident hard slot")
    elif defined(bl808d0): line("[PASS] D0 RV64 resident hard slot")
    else: line("[PASS] M0 RV32 resident hard slot")
    finish(true)
  when defined(wasmFullSchedulerQemu):
    var image = newSeq[byte](WasmProgramHeaderLen.int + WasmFullBaselineModule.len)
    if initWasmProgramImage(
        cast[ptr UncheckedArray[byte]](addr image[0]), image.len.uint32,
        WasmFullBaselineModule) != wasmProgramOk:
      finish(false)
    resetWasmScheduler()
    let started = startFullWasmImageTaskI32(
      cast[ptr UncheckedArray[byte]](addr image[0]), image.len.uint32,
      "indirect", [20'i32, 22'i32], maxTotalFuel = 64)
    if started.status != wasmSchedOk: finish(false)
    var current = started
    var attempts = 0
    while current.state in {wasmTaskReady, wasmTaskYielded}:
      current = resumeWasmTask(started.id, 2)
      inc attempts
      if attempts > 32: finish(false)
    if current.status != wasmSchedOk or current.state != wasmTaskExited or
        current.result != 42:
      finish(false)
    line("scheduler heap peak bytes=0x")
    hex32(heapStats().highWaterBytes.uint32)
    putChar('\n')
    line("scheduler native stack used bytes=0x")
    hex32(stackUsed())
    putChar('\n')
    when defined(bl808lp):
      line("[PASS] LP full WASM scheduler")
    elif defined(bl808m0):
      line("[PASS] M0 full WASM scheduler")
    else:
      line("[PASS] D0 full WASM scheduler")
    finish(true)
  when defined(wasmFullManagerQemu):
    var image = newSeq[byte](WasmProgramHeaderLen.int + WasmFullBaselineModule.len)
    if initWasmProgramImage(
        cast[ptr UncheckedArray[byte]](addr image[0]), image.len.uint32,
        WasmFullBaselineModule) != wasmProgramOk:
      finish(false)
    var handle: FullWasmProgramHandle
    if handle.openFullWasmProgramImage(
        cast[ptr UncheckedArray[byte]](addr image[0]), image.len.uint32) !=
        wasmManagerOk:
      finish(false)
    let values = handle.vm[].invoke(handle.moduleIdx, "indirect",
                                    [wasmI32(20), wasmI32(22)])
    if values.len != 1 or values[0].kind != wvkI32 or values[0].i32 != 42:
      finish(false)
    line("manager heap peak bytes=0x")
    hex32(heapStats().highWaterBytes.uint32)
    putChar('\n')
    line("manager native stack used bytes=0x")
    hex32(stackUsed())
    putChar('\n')
    handle.close()
    when defined(bl808lp):
      line("[PASS] LP full WASM store adapter")
    elif defined(bl808m0):
      line("[PASS] M0 full WASM store adapter")
    else:
      line("[PASS] D0 full WASM store adapter")
    finish(true)
  when defined(wasmFullThroughputBench):
    if not caps.fullInterpreter: finish(false)
    throughputBench()
    finish(true)
  var memory: WasmFullBaselineMemory
  let status = runWasmFullBaseline(addr memory)
  let heap = heapStats()
  line("validation bytes=0x")
  hex32(memory.validationBytes)
  putChar('\n')
  line("VM arena bytes=0x")
  hex32(memory.vmBytes)
  putChar('\n')
  line("instance bytes=0x")
  hex32(memory.instanceBytes)
  putChar('\n')
  line("heap peak bytes=0x")
  hex32(heap.highWaterBytes.uint32)
  putChar('\n')
  line("native stack used bytes=0x")
  hex32(stackUsed())
  putChar('\n')
  when defined(bl808lp):
    const expectedCore = wasmCoreLP
    const expectedIsa = wasmIsaRv32EmC
    const expectedAbi = wasmAbiIlp32e
    const expectedRam = 16 * 1024'u32
    const expectedStack = 4 * 1024'u32
  elif defined(bl808m0):
    const expectedCore = wasmCoreM0
    const expectedIsa = wasmIsaRv32ImAfC
    const expectedAbi = wasmAbiIlp32f
    const expectedRam = 64 * 1024'u32
    const expectedStack = 8 * 1024'u32
  else:
    const expectedCore = wasmCoreD0
    const expectedIsa = wasmIsaRv64ImAfDc
    const expectedAbi = wasmAbiLp64d
    const expectedRam = 512 * 1024'u32
    const expectedStack = 8 * 1024'u32
  if caps.core == expectedCore and caps.isa == expectedIsa and
      caps.abi == expectedAbi and caps.writableRamBytes == expectedRam and
      caps.nativeStackBytes == expectedStack and caps.fullInterpreter and
      status == WasmFullBaselineOk and heapCheck():
    when defined(bl808lp):
      line("[PASS] LP RV32E full WASM i32 f64 indirect")
    elif defined(bl808m0):
      line("[PASS] M0 RV32 full WASM i32 f64 indirect")
    else:
      line("[PASS] D0 RV64 full WASM i32 f64 indirect")
    finish(true)
  else:
    line("[FAIL] full WASM baseline")
    hex32(status)
    putChar('\n')
    finish(false)
