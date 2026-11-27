import cps/wasm/component

when defined(wasmComponentThreads):
  proc checkGuestThread*(instance: ComponentInstance): bool {.noinline.} =
    let call = instance.beginCallback("run", [])
    if call.pollCallback() != ccsThreadsWaiting: return false
    if not instance.pollComponentTasks(): return false
    if call.pollCallback() != ccsComplete: return false
    let values = call.takeCallbackResult()
    if values.len != 1 or values[0].bits != 42 or instance.pollComponentTasks(): return false
    instance.closeComponent()
    true

  proc checkGuestThreadFixtures*(asynchronous, synchronous: string): bool {.noinline.} =
    block:
      let instance = block:
        let plan = decodeComponent(cast[seq[byte]](asynchronous))
        instantiateComponent(plan)
      if not instance.checkGuestThread(): return false
    let instance = block:
      let plan = decodeComponent(cast[seq[byte]](synchronous))
      instantiateComponent(plan)
    let values = instance.invoke("run", [])
    if values.len != 1 or values[0].bits != 42 or instance.pollComponentTasks(): return false
    instance.closeComponent()
    true

when defined(wasmComponentThreadSpawn):
  proc checkThreadSpawnFixtures*(spawning, parallelism: string): bool {.noinline.} =
    block:
      let instance = block:
        let plan = decodeComponent(spawning.toOpenArrayByte(0, spawning.high))
        instantiateComponent(plan)
      if not instance.checkGuestThread(): return false
    let instance = block:
      let plan = decodeComponent(parallelism.toOpenArrayByte(0, parallelism.high))
      instantiateComponent(plan)
    defer: instance.closeComponent()
    for _ in 0 ..< 2:
      let values = instance.invoke("run", [])
      if values.len != 1 or values[0].kind != cpU32 or values[0].bits != 1: return false
    true

when defined(wasmComponentHostEndpoints) and defined(wasmComponentStreams):
  proc checkHostUnitStream*(instance: ComponentInstance): bool {.noinline.} =
    let pair = newComponentEndpointPair(cpStream)
    if pair.writable.writeComponentUnits(3).status != cesPending: return false
    let values = instance.invoke("run", [pair.readable])
    if values.len != 1 or values[0].bits != 42: return false
    let completed = pair.writable.pollComponentEndpoint()
    if completed.status != cesCompleted or completed.count != 3: return false
    pair.writable.closeComponentEndpoint()
    instance.closeComponent()
    true

when defined(wasmComponentStreams):
  proc checkUnitStream*(instance: ComponentInstance): bool {.noinline.} =
    let values = instance.invoke("run", [])
    if values.len != 1 or values[0].bits != 42: return false
    instance.closeComponent()
    true

when defined(wasmComponentAsyncCallbacks):
  proc checkLocalAsyncBorrow*(instance: ComponentInstance): bool {.noinline.} =
    let owner = instance.invoke("new", [componentValue(cpU32, 42)])[0]
    let call = instance.beginCallback("use", [owner.borrowComponentResource()])
    if call.pollCallback() != ccsYielded: return false
    var pinned = false
    try:
      owner.dropComponentResource()
    except ComponentError as error:
      pinned = error.msg == "cannot remove owned resource while borrowed"
    if not pinned or call.pollCallback() != ccsComplete: return false
    let answer = call.takeCallbackResult()
    owner.dropComponentResource()
    answer.len == 1 and answer[0].kind == cpU32 and answer[0].bits == 42

  when defined(wasmComponentStackful):
    when defined(wasmComponentFutures):
      proc checkFutureWait*(instance: ComponentInstance): bool {.noinline.} =
        let call = instance.beginCallback("run", [])
        if call.pollCallback() != ccsCoreWaiting: return false
        when defined(bl808lp):
          let sender = instance.beginCallback("fill", [])
          if sender.pollCallback() != ccsComplete or sender.takeCallbackResult().len != 0:
            return false
        for _ in 0..<6:
          discard call.pollCallback()
          if call.callbackResultReady(): break
        if not call.callbackResultReady(): return false
        let values = call.takeCallbackResult()
        if values.len != 1 or values[0].bits != 42 or instance.pollComponentTasks(): return false
        instance.closeComponent()
        true

    proc checkSyncLower*(instance: ComponentInstance, entries: openArray[string],
                         args: openArray[ComponentValue] = []): bool {.noinline.} =
      for name in entries:
        let call = instance.beginCallback(name, args)
        if call.pollCallback() != ccsCoreWaiting: return false
        for step in 0..<12:
          discard call.pollCallback()
          if call.callbackResultReady(): break
        if not call.callbackResultReady(): return false
        let value = call.takeCallbackResult()
        if value.len != 1 or value[0].kind != cpU32 or value[0].bits != 42: return false
      not instance.pollComponentTasks()

    proc checkStackfulTurns*(instance: ComponentInstance): bool {.noinline.} =
      let first = instance.beginCallback("run", [componentValue(cpU32, 41)])
      let second = instance.beginCallback("run", [componentValue(cpU32, 8)])
      if first.pollCallback() != ccsCoreWaiting or second.pollCallback() != ccsCoreWaiting:
        return false
      if first.pollCallback() != ccsComplete or second.pollCallback() != ccsComplete: return false
      first.takeCallbackResult()[0].bits == 42 and second.takeCallbackResult()[0].bits == 9

  proc checkCallbackTurns*(instance: ComponentInstance): bool {.noinline.} =
    let first = instance.beginCallback("run", [componentValue(cpU32, 41)])
    let second = instance.beginCallback("run", [componentValue(cpU32, 8)])
    if first.pollCallback() != ccsYielded or second.pollCallback() != ccsYielded or
        first.callbackResultReady() or second.callbackResultReady():
      return false
    if first.pollCallback() != ccsYielded or not first.callbackResultReady(): return false
    let answer = first.takeCallbackResult()
    if answer.len != 1 or answer[0].kind != cpU32 or answer[0].bits != 42 or
        first.callbackResultReady(): return false
    if second.pollCallback() != ccsYielded or not second.callbackResultReady(): return false
    let other = second.takeCallbackResult()
    other.len == 1 and other[0].kind == cpU32 and other[0].bits == 9 and
      second.pollCallback() == ccsComplete and first.pollCallback() == ccsComplete

  proc checkAsyncSubtasks*(instance: ComponentInstance, full = true): bool {.noinline.} =
    let call = instance.beginCallback("run", [])
    if call.pollCallback() != ccsWaiting or call.callbackResultReady(): return false
    if full and (call.pollCallback() != ccsWaiting or call.callbackResultReady()): return false
    if call.pollCallback() != ccsComplete or not call.callbackResultReady(): return false
    let answer = call.takeCallbackResult()
    if answer.len != 1 or answer[0].kind != cpU32 or answer[0].bits != 42: return false
    if not full: return true
    if instance.invoke("finished", [])[0].bits != 0 or not instance.pollComponentTasks(): return false
    instance.invoke("finished", [])[0].bits == 1 and not instance.pollComponentTasks()

  proc checkLocalAsyncSubtask*(instance: ComponentInstance): bool {.noinline.} =
    let call = instance.beginCallback("run", [])
    if call.pollCallback() != ccsWaiting or call.callbackResultReady(): return false
    if call.pollCallback() != ccsComplete or not call.callbackResultReady(): return false
    call.takeCallbackResult().len == 0 and not instance.pollComponentTasks()

when isMainModule:
  import std/os

  let turns = cast[seq[byte]](readFile(paramStr(1)))
  when defined(wasmComponentAsyncCallbacks):
    doAssert paramCount() == 6
    doAssert checkCallbackTurns(instantiateComponent(decodeComponent(turns)))
    let failures = decodeComponent(cast[seq[byte]](readFile(paramStr(2))))
    let waiting = instantiateComponent(failures)
    block:
      let abandoned = waiting.beginCallback("wait", [])
      doAssert abandoned.pollCallback() == ccsWaiting and not abandoned.callbackResultReady()
    doAssert waiting.invoke("drop-set", []).len == 0
    for (name, detail) in [
        ("two-returns", "canonical task already resolved"),
        ("wrong-type", "canonical task.return type mismatch"),
        ("wrong-option", "canonical task.return options mismatch"),
        ("bad-code", "invalid canonical callback code")]:
      let instance = instantiateComponent(failures)
      let call = instance.beginCallback(name, [])
      var trapped = false
      try:
        discard call.pollCallback()
      except ComponentError as error:
        trapped = error.msg == detail
      doAssert trapped and call.pollCallback() == ccsTrapped and not call.callbackResultReady()
    let instance = instantiateComponent(failures)
    let unresolved = instance.beginCallback("unresolved", [])
    doAssert unresolved.pollCallback() == ccsUnresolved and not unresolved.callbackResultReady()
    var trapped = false
    try:
      discard instance.invoke("sync-return", [])
    except ComponentError as error:
      trapped = error.msg == "canonical task.return requires an active async task"
    doAssert trapped
    let payload = instantiateComponent(decodeComponent(cast[seq[byte]](readFile(paramStr(3)))))
    let text = payload.beginCallback(["api", "inner"], "text", [])
    doAssert text.pollCallback() == ccsYielded and text.pollCallback() == ccsComplete
    let value = text.takeCallbackResult()
    doAssert value.len == 1 and value[0].kind == cpString and value[0].text == "Ox64"
    let flat = payload.beginCallback("pair", [])
    doAssert flat.pollCallback() == ccsYielded and flat.pollCallback() == ccsComplete
    let pair = flat.takeCallbackResult()
    doAssert pair.len == 1 and pair[0].kind == cpTuple and pair[0].fields.len == 2 and
      pair[0].fields[0].bits == 42 and pair[0].fields[1].bits == 4294967297'u64
    let indirect = payload.beginCallback("wide", [])
    doAssert indirect.pollCallback() == ccsYielded and indirect.pollCallback() == ccsComplete
    let wide = indirect.takeCallbackResult()
    doAssert wide.len == 1 and wide[0].kind == cpTuple and wide[0].fields.len == 17
    doAssert wide[0].fields[0].bits == 1 and wide[0].fields[16].bits == 17
    let owned = payload.beginCallback("owned", [])
    doAssert owned.pollCallback() == ccsYielded and owned.pollCallback() == ccsComplete
    let ticket = owned.takeCallbackResult()
    doAssert ticket.len == 1 and ticket[0].kind == cpOwnedResource
    dropComponentResource(ticket[0])
    doAssert payload.invoke("observed", [])[0].bits == 42
    let wrongMemory = payload.beginCallback("wrong-memory", [])
    doAssert wrongMemory.pollCallback() == ccsYielded
    trapped = false
    try:
      discard wrongMemory.pollCallback()
    except ComponentError as error:
      trapped = error.msg == "canonical task.return options mismatch"
    doAssert trapped
    echo "Component callback PASS: interleaving, early results, ABI payloads and traps"
    let subtasks = decodeComponent(cast[seq[byte]](readFile(paramStr(4))))
    doAssert checkAsyncSubtasks(instantiateComponent(subtasks))
    let small = decodeComponent(cast[seq[byte]](readFile(paramStr(5))))
    doAssert checkAsyncSubtasks(instantiateComponent(small), full = false)
    let local = instantiateComponent(decodeComponent(cast[seq[byte]](readFile(paramStr(6)))))
    doAssert checkLocalAsyncSubtask(local)
    closeComponent(local)
    echo "Component subtasks PASS: backpressure, WAIT events, result buffer, handle reuse and background exit"
  else:
    var rejected = false
    try:
      discard decodeComponent(turns)
    except ComponentError as error:
      rejected = error.msg == "unsupported canonical definition" or
        error.msg == "async component function types are disabled"
    doAssert rejected
    echo "Component callback opt-in gate PASS"
