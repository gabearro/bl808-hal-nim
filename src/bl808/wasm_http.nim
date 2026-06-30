## Minimal HTTP-style adapter for managed WASM programs.
##
## This does not own a TCP listener. Network code can feed parsed method/path
## and request body bytes here, then write the returned status/body to lwIP.

import ./memmap
import ./wasm_control
import ./wasm_os
import ./wasm_peer_control

when defined(bl808m0) or defined(bl808d0) or defined(bl808lp):
  import ./os_storage
  import ./wasm_sd_store

type
  WasmHttpMethod* = enum
    wasmHttpGet
    wasmHttpPost
    wasmHttpDelete

  WasmHttpResponse* = object
    statusCode*: uint16
    contentType*: string
    body*: string
    control*: WasmControlResult

const
  ProgramsPath = "/wasm/programs"
  TasksPath = "/wasm/tasks"
  RepositoryPath = "/wasm/repository"
  CapabilitiesPath = "/wasm/capabilities"
  CoresPath = "/wasm/cores"
  SystemPath = "/wasm/system"
  EventsPath = "/wasm/events"
  EventsStreamPath = "/wasm/events/stream"
  TrapsPath = "/wasm/traps"
  PlacementPath = "/wasm/placement"
  NetStatusPath = "/wasm/net/status"
  MaxInvokeArgs = 8
  WasmHttpSdScratchSize {.intdefine.} = 4096
  WasmHttpPeerTimeoutPolls {.intdefine.} = 200_000'u32

type
  WasmHttpCoreStatusProvider* = proc(): string {.nimcall.}
  WasmHttpNetStatusProvider* = proc(): string {.nimcall.}
  WasmHttpEnclaveControlProvider* = proc(opcode: WasmPeerControlOpcode,
                                         slot, taskId, fuel: uint32,
                                         exportName: string,
                                         args: openArray[int32]):
                                           WasmPeerControlResult {.nimcall.}

var wasmHttpCoreStatusProvider: WasmHttpCoreStatusProvider
var wasmHttpNetStatusProvider: WasmHttpNetStatusProvider
var wasmHttpEnclaveControlProvider: WasmHttpEnclaveControlProvider

proc setWasmHttpCoreStatusProvider*(provider: WasmHttpCoreStatusProvider) =
  ## Optional board/example hook for exposing cross-core runtime state.
  wasmHttpCoreStatusProvider = provider

proc setWasmHttpNetStatusProvider*(provider: WasmHttpNetStatusProvider) =
  ## Optional board/example hook for exposing WiFi/IP state.
  wasmHttpNetStatusProvider = provider

proc setWasmHttpEnclaveControlProvider*(provider: WasmHttpEnclaveControlProvider) =
  ## Optional board/example hook for routing enclave WASM task control.
  wasmHttpEnclaveControlProvider = provider

when defined(bl808m0) or defined(bl808d0) or defined(bl808lp):
  when defined(bl808AllcoreWasmHttp):
    {.pragma: wasmHttpScratchMem, codegenDecl: "$# $# __attribute__((section(\".psrambss\"), aligned(16), used))".}
  else:
    {.pragma: wasmHttpScratchMem.}

  var
    wasmHttpSdScratch {.wasmHttpScratchMem.}: array[WasmHttpSdScratchSize, byte]

proc startsWithAt(s, prefix: string, at: int): bool =
  if at < 0 or at + prefix.len > s.len:
    return false
  for i in 0 ..< prefix.len:
    if s[at + i] != prefix[i]:
      return false
  true

proc startsWithAt(data: openArray[byte], prefix: string, at: int): bool =
  if at < 0 or at + prefix.len > data.len:
    return false
  for i in 0 ..< prefix.len:
    if data[at + i] != byte(prefix[i]):
      return false
  true

proc findHeaderEnd(data: openArray[byte]): int =
  if data.len < 4:
    return -1
  for i in 0 .. data.len - 4:
    if data[i] == byte('\r') and data[i + 1] == byte('\n') and
        data[i + 2] == byte('\r') and data[i + 3] == byte('\n'):
      return i
  -1

proc asciiSlice(data: openArray[byte], start, stop: int): string =
  if start < 0 or stop < start or stop > data.len:
    return ""
  result = newString(stop - start)
  for i in start ..< stop:
    result[i - start] = char(data[i])

proc parseU32Decimal(s: string, start: int, stop: int,
                     value: var uint32): bool =
  if start >= stop:
    return false
  var n = 0'u32
  for i in start ..< stop:
    let c = s[i]
    if c < '0' or c > '9':
      return false
    let digit = uint32(ord(c) - ord('0'))
    if n > (uint32.high - digit) div 10'u32:
      return false
    n = n * 10'u32 + digit
  value = n
  true

proc parseU32Decimal(data: openArray[byte], start: int, stop: int,
                     value: var uint32): bool =
  if start >= stop:
    return false
  var n = 0'u32
  for i in start ..< stop:
    let c = data[i]
    if c < byte('0') or c > byte('9'):
      return false
    let digit = uint32(c - byte('0'))
    if n > (uint32.high - digit) div 10'u32:
      return false
    n = n * 10'u32 + digit
  value = n
  true

proc parseI32Decimal(data: openArray[byte], start: int, stop: int,
                     value: var int32): bool =
  if start >= stop:
    return false
  var i = start
  var neg = false
  if data[i] == byte('-'):
    neg = true
    inc i
    if i >= stop:
      return false
  var n = 0'i64
  while i < stop:
    let c = data[i]
    if c < byte('0') or c > byte('9'):
      return false
    n = n * 10'i64 + int64(c - byte('0'))
    if (not neg and n > int64(int32.high)) or
       (neg and n > int64(int32.high) + 1'i64):
      return false
    inc i
  value = (if neg: int32(-n) else: int32(n))
  true

proc parseInvokeArgs(body: openArray[byte],
                     args: var array[MaxInvokeArgs, int32],
                     argc: var int): bool =
  ## Parse an ASCII body of `i32[,i32...]`, optionally prefixed by `args=`.
  ##
  ## Empty bodies keep the original smoke-test behavior for compatibility.
  argc = 0
  if body.len == 0:
    args[0] = 20'i32
    args[1] = 22'i32
    argc = 2
    return true

  var pos = 0
  while pos < body.len and (body[pos] == byte(' ') or body[pos] == byte('\t') or
      body[pos] == byte('\r') or body[pos] == byte('\n')):
    inc pos
  if pos + 5 <= body.len and body.startsWithAt("args=", pos):
    pos += 5

  while true:
    while pos < body.len and (body[pos] == byte(' ') or body[pos] == byte('\t')):
      inc pos
    if pos >= body.len:
      return argc > 0
    if argc >= MaxInvokeArgs:
      return false

    let start = pos
    if body[pos] == byte('-'):
      inc pos
    while pos < body.len and body[pos] >= byte('0') and body[pos] <= byte('9'):
      inc pos
    if pos == start or (pos == start + 1 and body[start] == byte('-')):
      return false

    if not parseI32Decimal(body, start, pos, args[argc]):
      return false
    inc argc

    while pos < body.len and (body[pos] == byte(' ') or body[pos] == byte('\t')):
      inc pos
    if pos >= body.len:
      return true
    if body[pos] == byte('\r') or body[pos] == byte('\n'):
      while pos < body.len and (body[pos] == byte('\r') or body[pos] == byte('\n')):
        inc pos
      return pos == body.len
    if body[pos] != byte(','):
      return false
    inc pos

proc parseSlotPath(path: string, slot: var uint32,
                   tailStart: var int): bool =
  if not path.startsWithAt(ProgramsPath & "/", 0):
    return false
  let start = ProgramsPath.len + 1
  var stop = start
  while stop < path.len and path[stop] >= '0' and path[stop] <= '9':
    inc stop
  if not parseU32Decimal(path, start, stop, slot):
    return false
  tailStart = stop
  true

proc response(code: uint16, contentType, body: string,
              control = WasmControlResult()): WasmHttpResponse =
  WasmHttpResponse(statusCode: code, contentType: contentType,
                   body: body, control: control)

proc reasonPhrase(code: uint16): string =
  case code
  of 202: "Accepted"
  of 200: "OK"
  of 201: "Created"
  of 400: "Bad Request"
  of 404: "Not Found"
  of 501: "Not Implemented"
  of 504: "Gateway Timeout"
  of 500: "Internal Server Error"
  else: "Error"

proc appendHeader(dst: var string, name, value: string) =
  dst.add(name)
  dst.add(": ")
  dst.add(value)
  dst.add("\r\n")

proc formatWasmHttpResponse*(r: WasmHttpResponse): string =
  ## Serialize a response for a raw TCP HTTP/1.1 writer.
  result = "HTTP/1.1 " & $r.statusCode & " " & reasonPhrase(r.statusCode) & "\r\n"
  result.appendHeader("Content-Type", r.contentType)
  result.appendHeader("Content-Length", $r.body.len)
  result.appendHeader("Connection", "close")
  result.add("\r\n")
  result.add(r.body)

proc statusText(r: WasmControlResult): string =
  "status=" & $r.status.ord &
    " manager=" & $r.managerError.ord &
    " store=" & $r.storeError.ord &
    " slot=" & $r.slot &
    " value=" & $r.value

proc statusText(r: WasmControlTaskResult): string =
  "status=" & $r.status.ord &
    " scheduler=" & $r.schedulerStatus.ord &
    " manager=" & $r.managerError.ord &
    " task=" & $r.taskId &
    " slot=" & $r.slot &
    " state=" & $r.taskState.ord &
    " value=" & $r.value &
    " trap=" & $r.trapCode &
    " resumes=" & $r.resumes &
    " yields=" & $r.yields &
    " fuelUsed=" & $r.fuelUsed &
    " fuelLimit=" & $r.fuelLimit

proc statusText(r: WasmPeerControlResult): string =
  if r.badCore:
    return "status=bad_core core=" & wasmOsCoreName(r.core)
  if r.timedOut:
    return "status=timeout core=" & wasmOsCoreName(r.core) &
      " seq=" & $r.seq &
      " opcode=" & $r.opcode.ord
  "status=" & $r.controlStatus.ord &
    " scheduler=" & $r.schedulerStatus.ord &
    " core=" & wasmOsCoreName(r.core) &
    " task=" & $r.taskId &
    " slot=" & $r.slot &
    " state=" & $r.taskState.ord &
    " value=" & $r.value &
    " trap=" & $r.trapCode &
    " resumes=" & $r.resumes &
    " yields=" & $r.yields &
    " fuelUsed=" & $r.fuelUsed &
    " fuelLimit=" & $r.fuelLimit

when defined(bl808m0) or defined(bl808d0) or defined(bl808lp):
  proc statusText(r: WasmSdInstallResult): string =
    "status=" & $r.status.ord &
      " fs=" & $r.fsError.ord &
      " manager=" & $r.managerError.ord &
      " store=" & $r.storeError.ord &
      " bytes=" & $r.bytes &
      " slot=" & $r.slot

  proc statusText(r: WasmSdListResult): string =
    "status=" & $r.status.ord &
      " fs=" & $r.fsError.ord &
      " count=" & $r.count

  proc storageStatusText(s: OsStorageState): string =
    "status=" & $s.status.ord &
      " mounted=" & $s.mounted &
      " tuned=" & $s.tuned &
      " mount=" & $s.mountError.ord &
      " highSpeed=" & $s.highSpeedError.ord &
      " sdErr=" & $s.health.lastError.ord &
      " phase=" & $s.health.lastPhase

  proc ensureHttpStorage(): bool =
    osStorageInit() == osStorageOk and osStorageMounted()

proc appendU32(dst: var string, value: uint32) =
  dst.add($value)

proc appendI32(dst: var string, value: int32) =
  dst.add($value)

proc appendSlotJson(dst: var string, slot: WasmControlSlot) =
  dst.add("{\"index\":")
  dst.appendU32(slot.index)
  dst.add(",\"state\":")
  dst.appendU32(slot.state.ord.uint32)
  dst.add(",\"imageLen\":")
  dst.appendU32(slot.imageLen)
  dst.add(",\"generation\":")
  dst.appendU32(slot.generation)
  dst.add(",\"flags\":")
  dst.appendU32(slot.flags)
  dst.add(",\"checksum\":")
  dst.appendU32(slot.checksum)
  dst.add(",\"validation\":")
  dst.appendU32(slot.validation.ord.uint32)
  dst.add("}")

proc appendTaskJson(dst: var string, task: WasmSchedulerTaskInfo) =
  dst.add("{\"id\":")
  dst.appendU32(task.id)
  dst.add(",\"slot\":")
  dst.add($task.slot)
  dst.add(",\"state\":")
  dst.appendU32(task.state.ord.uint32)
  dst.add(",\"value\":")
  dst.add($task.result)
  dst.add(",\"trap\":")
  dst.appendU32(task.trapCode)
  dst.add(",\"resumes\":")
  dst.appendU32(task.resumes)
  dst.add(",\"yields\":")
  dst.appendU32(task.yields)
  dst.add(",\"fuelUsed\":")
  dst.appendU32(task.fuelUsed)
  dst.add(",\"fuelLimit\":")
  dst.appendU32(task.fuelLimit)
  dst.add("}")

proc appendTaskJsonWithCore(dst: var string, core: WasmOsCore,
                            task: WasmSchedulerTaskInfo) =
  dst.add("{\"core\":\"")
  dst.add(wasmOsCoreName(core))
  dst.add("\",\"id\":")
  dst.appendU32(task.id)
  dst.add(",\"slot\":")
  dst.add($task.slot)
  dst.add(",\"state\":")
  dst.appendU32(task.state.ord.uint32)
  dst.add(",\"value\":")
  dst.add($task.result)
  dst.add(",\"trap\":")
  dst.appendU32(task.trapCode)
  dst.add(",\"resumes\":")
  dst.appendU32(task.resumes)
  dst.add(",\"yields\":")
  dst.appendU32(task.yields)
  dst.add(",\"fuelUsed\":")
  dst.appendU32(task.fuelUsed)
  dst.add(",\"fuelLimit\":")
  dst.appendU32(task.fuelLimit)
  dst.add("}")

when not (defined(bl808d0) or defined(bl808lp)):
  proc appendPeerTaskJsonWithCore(dst: var string, core: WasmOsCore,
                                  task: WasmPeerTaskRecord) =
    dst.add("{\"core\":\"")
    dst.add(wasmOsCoreName(core))
    dst.add("\",\"id\":")
    dst.appendU32(task.id)
    dst.add(",\"slot\":")
    dst.appendI32(task.slot)
    dst.add(",\"state\":")
    dst.appendU32(task.state.ord.uint32)
    dst.add(",\"value\":")
    dst.appendI32(task.value)
    dst.add(",\"trap\":")
    dst.appendU32(task.trapCode)
    dst.add(",\"resumes\":")
    dst.appendU32(task.resumes)
    dst.add(",\"yields\":")
    dst.appendU32(task.yields)
    dst.add(",\"fuelUsed\":")
    dst.appendU32(task.fuelUsed)
    dst.add(",\"fuelLimit\":")
    dst.appendU32(task.fuelLimit)
    dst.add("}")

  proc appendPeerTasksForCore(dst: var string, core: WasmOsCore,
                              first: var bool) =
    var appended = 0
    let r = dispatchPeerRequest(core, wasmPeerListTasks,
                                timeoutPolls = WasmHttpPeerTimeoutPolls)
    if not r.timedOut and not r.badCore and r.controlStatus == wasmControlOk:
      let count = min(r.taskCount.int, WasmPeerControlMaxTaskRecords)
      for i in 0 ..< count:
        var task: WasmPeerTaskRecord
        if readPeerTaskRecord(core, i, task) and task.id != 0'u32:
          if not first:
            dst.add(",")
          dst.appendPeerTaskJsonWithCore(core, task)
          first = false
          inc appended
    if appended == 0:
      for taskId in 1'u32 .. WasmSchedulerMaxTasks.uint32:
        let sr = dispatchPeerRequest(core, wasmPeerStatus, taskId = taskId,
                                     timeoutPolls = WasmHttpPeerTimeoutPolls)
        if not sr.timedOut and not sr.badCore and sr.controlStatus == wasmControlOk:
          let task = WasmPeerTaskRecord(
            id: sr.taskId,
            slot: sr.slot,
            state: sr.taskState,
            value: sr.value,
            trapCode: sr.trapCode,
            resumes: sr.resumes,
            yields: sr.yields,
            fuelUsed: sr.fuelUsed,
            fuelLimit: sr.fuelLimit,
          )
          if not first:
            dst.add(",")
          dst.appendPeerTaskJsonWithCore(core, task)
          first = false

proc appendBoolJson(dst: var string, value: bool) =
  if value:
    dst.add("true")
  else:
    dst.add("false")

proc capabilitiesResponse(): WasmHttpResponse =
  let caps = wasmRuntimeCapabilities()
  var body = "{\"core\":"
  body.appendU32(caps.core.ord.uint32)
  body.add(",\"compact\":")
  body.appendBoolJson(caps.compact)
  body.add(",\"flashBacked\":")
  body.appendBoolJson(caps.flashBacked)
  body.add(",\"softwareF32\":")
  body.appendBoolJson(caps.softwareF32)
  body.add(",\"supportsI32\":")
  body.appendBoolJson(caps.supportsI32)
  body.add(",\"supportsF32\":")
  body.appendBoolJson(caps.supportsF32)
  body.add(",\"supportsF64\":")
  body.appendBoolJson(caps.supportsF64)
  body.add(",\"supportsImports\":")
  body.appendBoolJson(caps.supportsImports)
  if wasmHttpCoreStatusProvider != nil:
    body.add(",\"cores\":")
    body.add(wasmHttpCoreStatusProvider())
  body.add("}")
  response(200, "application/json", body)

proc coresResponse(): WasmHttpResponse =
  if wasmHttpCoreStatusProvider == nil:
    return response(404, "text/plain", "core status unavailable")
  response(200, "application/json",
           "{\"cores\":" & wasmHttpCoreStatusProvider() & "}")

proc listProgramsResponse(): WasmHttpResponse =
  var slots: array[Ox64WasmSlotCount, WasmControlSlot]
  let count = listWasmPrograms(slots)
  var body = "{\"slots\":["
  for i in 0 ..< count.int:
    if i != 0:
      body.add(",")
    body.appendSlotJson(slots[i])
  body.add("]}")
  response(200, "application/json", body)

proc listTasksResponse(): WasmHttpResponse =
  var tasks: array[WasmSchedulerMaxTasks, WasmSchedulerTaskInfo]
  let count = collectWasmTasks(tasks)
  var body = "{\"tasks\":["
  for i in 0 ..< count.int:
    if i != 0:
      body.add(",")
    body.appendTaskJson(tasks[i])
  body.add("]}")
  response(200, "application/json", body)

proc listAllTasksResponse(): WasmHttpResponse =
  var tasks: array[WasmSchedulerMaxTasks, WasmSchedulerTaskInfo]
  let count = collectWasmTasks(tasks)
  var body = "{\"tasks\":["
  var first = true
  for i in 0 ..< count.int:
    if not first:
      body.add(",")
    body.appendTaskJsonWithCore(currentWasmOsCore(), tasks[i])
    first = false
  when not (defined(bl808d0) or defined(bl808lp)):
    appendPeerTasksForCore(body, wasmOsCoreD0, first)
    appendPeerTasksForCore(body, wasmOsCoreLP, first)
  body.add("]}")
  response(200, "application/json", body)

proc appendJsonEscaped(dst: var string, value: string) =
  dst.add("\"")
  for ch in value:
    case ch
    of '"':
      dst.add("\\\"")
    of '\\':
      dst.add("\\\\")
    else:
      dst.add(ch)
  dst.add("\"")

proc appendLimitsJson(dst: var string, limits: WasmOsResourceLimits) =
  dst.add("{\"maxFuel\":")
  dst.appendU32(limits.maxFuel)
  dst.add(",\"sliceFuel\":")
  dst.appendU32(limits.sliceFuel)
  dst.add(",\"maxMemoryPages\":")
  dst.appendU32(limits.maxMemoryPages)
  dst.add(",\"maxTasks\":")
  dst.appendU32(limits.maxTasks)
  dst.add(",\"maxOpenHandles\":")
  dst.appendU32(limits.maxOpenHandles)
  dst.add(",\"maxStorageBytes\":")
  dst.appendU32(limits.maxStorageBytes)
  dst.add(",\"allowNetwork\":")
  dst.appendBoolJson(limits.allowNetwork)
  dst.add(",\"allowStorage\":")
  dst.appendBoolJson(limits.allowStorage)
  dst.add(",\"allowIpc\":")
  dst.appendBoolJson(limits.allowIpc)
  dst.add(",\"allowCrypto\":")
  dst.appendBoolJson(limits.allowCrypto)
  dst.add(",\"allowGpio\":")
  dst.appendBoolJson(limits.allowGpio)
  dst.add(",\"requireEnclave\":")
  dst.appendBoolJson(limits.requireEnclave)
  dst.add("}")

proc appendEventJson(dst: var string, ev: WasmOsEvent) =
  dst.add("{\"id\":")
  dst.appendU32(ev.id)
  dst.add(",\"kind\":")
  dst.appendU32(ev.kind.ord.uint32)
  dst.add(",\"core\":\"")
  dst.add(wasmOsCoreName(ev.core))
  dst.add("\",\"taskId\":")
  dst.appendU32(ev.taskId)
  dst.add(",\"slot\":")
  dst.appendI32(ev.slot)
  dst.add(",\"value\":")
  dst.appendI32(ev.value)
  dst.add(",\"code\":")
  dst.appendU32(ev.code)
  dst.add("}")

proc appendTrapJson(dst: var string, trap: WasmOsTrapRecord) =
  dst.add("{\"id\":")
  dst.appendU32(trap.id)
  dst.add(",\"core\":\"")
  dst.add(wasmOsCoreName(trap.core))
  dst.add("\",\"taskId\":")
  dst.appendU32(trap.taskId)
  dst.add(",\"slot\":")
  dst.appendI32(trap.slot)
  dst.add(",\"trapCode\":")
  dst.appendU32(trap.trapCode)
  dst.add(",\"fuelUsed\":")
  dst.appendU32(trap.fuelUsed)
  dst.add(",\"state\":")
  dst.appendU32(trap.state.ord.uint32)
  dst.add("}")

proc appendPlacementDecisionJson(dst: var string, decision: WasmOsPlacementDecision) =
  dst.add("{\"status\":\"")
  dst.add(wasmPlacementStatusName(decision.status))
  dst.add("\",\"statusCode\":")
  dst.appendU32(decision.status.ord.uint32)
  dst.add(",\"core\":\"")
  dst.add(wasmOsCoreName(decision.core))
  dst.add("\",\"coreId\":")
  dst.appendU32(decision.core.ord.uint32)
  dst.add(",\"reason\":")
  dst.appendU32(decision.reason)
  dst.add("}")

proc placementPolicyResponse(): WasmHttpResponse =
  var body = "{\"order\":[\"m0\",\"d0\",\"lp\",\"enclave\"],"
  body.add("\"rules\":[\"requireEnclave->enclave\",\"net/http->m0\",")
  body.add("\"gpio->m0/lp\",\"storage avoids lp\"],\"endpoint\":\"")
  body.add(PlacementPath)
  body.add("\"}")
  response(200, "application/json", body)

proc placementDecisionResponse(bodyBytes: openArray[byte]): WasmHttpResponse =
  let text = if bodyBytes.len == 0: "" else: asciiSlice(bodyBytes, 0, bodyBytes.len)
  let manifest = parseWasmOsManifest(text)
  if not manifest.valid:
    return response(400, "text/plain", "bad manifest")
  let decision = chooseWasmOsPlacement(manifest)
  var body = "{\"placement\":"
  body.appendPlacementDecisionJson(decision)
  body.add(",\"preferredCore\":\"")
  body.add(wasmOsCoreName(manifest.preferredCore))
  body.add("\",\"coreMask\":")
  body.appendU32(manifest.coreMask)
  body.add(",\"requireEnclave\":")
  body.appendBoolJson(manifest.limits.requireEnclave)
  body.add("}")
  let status = if decision.status == wasmPlaceOk: 200'u16 else: 400'u16
  response(status, "application/json", body)

proc systemResponse(): WasmHttpResponse =
  let caps = wasmRuntimeCapabilities()
  let limits = defaultWasmOsResourceLimits()
  var body = "{\"runtimeCore\":\""
  body.add(wasmOsCoreName(currentWasmOsCore()))
  body.add("\",\"runtimeCoreId\":")
  body.appendU32(caps.core.ord.uint32)
  body.add(",\"placement\":[\"m0\",\"d0\",\"lp\",\"enclave\"]")
  body.add(",\"localPlacement\":\"")
  body.add(wasmOsCoreName(currentWasmOsCore()))
  body.add("\",\"remotePlacement\":\"peer-mailbox\"")
  body.add(",\"asyncHostCalls\":[\"sleep\",\"log\",\"storage\",\"ipc\",\"http\",\"net\",\"random\",\"crypto\",\"gpio\"]")
  when defined(bl808m0) or defined(bl808d0) or defined(bl808lp):
    discard osStorageInit()
    let storage = osStorageStatus()
    body.add(",\"storage\":{\"sd\":{")
    body.add("\"mounted\":")
    body.appendBoolJson(storage.mounted)
    body.add(",\"tuned\":")
    body.appendBoolJson(storage.tuned)
    body.add(",\"status\":")
    body.appendU32(storage.status.ord.uint32)
    body.add(",\"mountError\":")
    body.appendU32(storage.mountError.ord.uint32)
    body.add(",\"highSpeedError\":")
    body.appendU32(storage.highSpeedError.ord.uint32)
    body.add(",\"present\":")
    body.appendBoolJson(storage.health.present)
    body.add(",\"stable\":")
    body.appendBoolJson(storage.health.stable)
    body.add(",\"ready\":")
    body.appendBoolJson(storage.health.ready)
    body.add(",\"sdhc\":")
    body.appendBoolJson(storage.health.sdhc)
    body.add(",\"bus4Bit\":")
    body.appendBoolJson(storage.health.bus4Bit)
    body.add(",\"highSpeed\":")
    body.appendBoolJson(storage.health.highSpeed)
    body.add(",\"sectorCount\":")
    body.appendU32(storage.health.sectorCount)
    body.add(",\"lastError\":")
    body.appendU32(storage.health.lastError.ord.uint32)
    body.add(",\"lastPhase\":")
    body.appendU32(storage.health.lastPhase)
    body.add(",\"readOps\":")
    body.appendU32(storage.health.readOps)
    body.add(",\"writeOps\":")
    body.appendU32(storage.health.writeOps)
    body.add("}}")
  body.add(",\"defaultLimits\":")
  body.appendLimitsJson(limits)
  body.add(",\"routes\":[")
  body.appendJsonEscaped(CapabilitiesPath)
  body.add(",")
  body.appendJsonEscaped(CoresPath)
  body.add(",")
  body.appendJsonEscaped(SystemPath)
  body.add(",")
  body.appendJsonEscaped(EventsPath)
  body.add(",")
  body.appendJsonEscaped(EventsStreamPath)
  body.add(",")
  body.appendJsonEscaped(TrapsPath)
  body.add(",")
  body.appendJsonEscaped(PlacementPath)
  body.add(",")
  body.appendJsonEscaped(NetStatusPath)
  body.add(",")
  body.appendJsonEscaped(ProgramsPath)
  body.add(",")
  body.appendJsonEscaped(TasksPath)
  body.add(",")
  body.appendJsonEscaped(RepositoryPath)
  body.add("]}")
  response(200, "application/json", body)

proc eventsResponse(): WasmHttpResponse =
  var events: array[WasmOsEventLogLen, WasmOsEvent]
  let count = collectWasmOsEvents(events)
  var body = "{\"events\":["
  for i in 0 ..< count.int:
    if i != 0:
      body.add(",")
    body.appendEventJson(events[i])
  body.add("]}")
  response(200, "application/json", body)

proc eventsStreamResponse(): WasmHttpResponse =
  var events: array[WasmOsEventLogLen, WasmOsEvent]
  let count = collectWasmOsEvents(events)
  var body = ""
  for i in 0 ..< count.int:
    body.appendEventJson(events[i])
    body.add("\n")
  response(200, "application/x-ndjson", body)

proc netStatusResponse(): WasmHttpResponse =
  if wasmHttpNetStatusProvider != nil:
    return response(200, "application/json", wasmHttpNetStatusProvider())
  response(200, "application/json",
           "{\"available\":false,\"status\":\"unavailable\"}")

proc trapsResponse(): WasmHttpResponse =
  var traps: array[WasmOsTrapLogLen, WasmOsTrapRecord]
  let count = collectWasmOsTraps(traps)
  var body = "{\"traps\":["
  for i in 0 ..< count.int:
    if i != 0:
      body.add(",")
    body.appendTrapJson(traps[i])
  body.add("]}")
  response(200, "application/json", body)

when defined(bl808m0) or defined(bl808d0) or defined(bl808lp):
  proc listRepositoryResponse(): WasmHttpResponse =
    if not ensureHttpStorage():
      return response(503, "text/plain", storageStatusText(osStorageStatus()))
    var names: array[16, string]
    let listed = listWasmProgramsOnSd(osStorageFs(), names)
    if listed.status != wasmSdInstallOk:
      return response(500, "text/plain", statusText(listed))
    var manifestNames: array[16, string]
    let listedManifests = listWasmManifestsOnSd(osStorageFs(), manifestNames)
    if listedManifests.status != wasmSdInstallOk:
      return response(500, "text/plain", statusText(listedManifests))

    var body = "{\"programs\":["
    let n = min(listed.count.int, names.len)
    for i in 0 ..< n:
      if i != 0:
        body.add(",")
      body.appendJsonEscaped(names[i])
    body.add("],\"count\":")
    body.appendU32(listed.count)
    body.add(",\"manifests\":[")
    let manifestCount = min(listedManifests.count.int, manifestNames.len)
    for i in 0 ..< manifestCount:
      if i != 0:
        body.add(",")
      body.appendJsonEscaped(manifestNames[i])
    body.add("],\"manifestCount\":")
    body.appendU32(listedManifests.count)
    body.add("}")
    response(200, "application/json", body)

proc parseRepositoryPath(path: string, name: var string,
                         tailStart: var int): bool =
  if not path.startsWithAt(RepositoryPath & "/", 0):
    return false
  let start = RepositoryPath.len + 1
  var stop = start
  while stop < path.len and path[stop] != '/':
    inc stop
  if stop <= start:
    return false
  name = path[start ..< stop]
  when defined(bl808m0) or defined(bl808d0) or defined(bl808lp):
    if not validWasmSdName(name):
      return false
  else:
    if name.len == 0 or name.len > 64:
      return false
    for ch in name:
      if ch == '/' or ch == '\\' or ch == ':' or ch == '\0':
        return false
    if name.len <= 5 or name[name.len - 5 ..< name.len] != ".wasm":
      return false
  tailStart = stop
  true

proc parseRepositoryManifestPath(path: string, name: var string,
                                 tailStart: var int): bool =
  if not path.startsWithAt(RepositoryPath & "/", 0):
    return false
  let start = RepositoryPath.len + 1
  var stop = start
  while stop < path.len and path[stop] != '/':
    inc stop
  if stop <= start:
    return false
  name = path[start ..< stop]
  when defined(bl808m0) or defined(bl808d0) or defined(bl808lp):
    if not validWasmSdManifestName(name):
      return false
  else:
    if name.len <= 9 or name[name.len - 9 ..< name.len] != ".manifest":
      return false
  tailStart = stop
  true

proc parseRepositoryInstallPath(path: string, name: var string,
                                slot: var uint32): bool =
  var tail: int
  if not parseRepositoryPath(path, name, tail):
    return false
  const installPrefix = "/install/"
  if not path.startsWithAt(installPrefix, tail):
    return false
  let start = tail + installPrefix.len
  return parseU32Decimal(path, start, path.len, slot)

proc parseInvokePath(path: string, slot: var uint32,
                     exportName: var string): bool =
  var tail: int
  if not parseSlotPath(path, slot, tail):
    return false
  const invokePrefix = "/invoke/"
  if not path.startsWithAt(invokePrefix, tail):
    return false
  let start = tail + invokePrefix.len
  if start >= path.len:
    return false
  exportName = path[start ..< path.len]
  true

proc parseStartPath(path: string, slot: var uint32,
                    exportName: var string): bool =
  var tail: int
  if not parseSlotPath(path, slot, tail):
    return false
  const startPrefix = "/start/"
  if not path.startsWithAt(startPrefix, tail):
    return false
  let start = tail + startPrefix.len
  if start >= path.len:
    return false
  exportName = path[start ..< path.len]
  true

proc parseCoreStartPath(path: string, core: var WasmOsCore, slot: var uint32,
                        exportName: var string): bool =
  const prefix = CoresPath & "/"
  if not path.startsWithAt(prefix, 0):
    return false
  var nameStop = prefix.len
  while nameStop < path.len and path[nameStop] != '/':
    inc nameStop
  if nameStop <= prefix.len:
    return false
  core = parseWasmOsCore(path[prefix.len ..< nameStop])
  if core == wasmOsCoreUnknown:
    return false
  const programsPrefix = "/programs/"
  if not path.startsWithAt(programsPrefix, nameStop):
    return false
  let slotStart = nameStop + programsPrefix.len
  var slotStop = slotStart
  while slotStop < path.len and path[slotStop] >= '0' and path[slotStop] <= '9':
    inc slotStop
  if not parseU32Decimal(path, slotStart, slotStop, slot):
    return false
  const startPrefix = "/start/"
  if not path.startsWithAt(startPrefix, slotStop):
    return false
  let exportStart = slotStop + startPrefix.len
  if exportStart >= path.len:
    return false
  exportName = path[exportStart ..< path.len]
  true

proc parseCoreTaskPath(path: string, core: var WasmOsCore, taskId: var uint32,
                       tailStart: var int): bool =
  const prefix = CoresPath & "/"
  if not path.startsWithAt(prefix, 0):
    return false
  var nameStop = prefix.len
  while nameStop < path.len and path[nameStop] != '/':
    inc nameStop
  if nameStop <= prefix.len:
    return false
  core = parseWasmOsCore(path[prefix.len ..< nameStop])
  if core == wasmOsCoreUnknown:
    return false
  const tasksPrefix = "/tasks/"
  if not path.startsWithAt(tasksPrefix, nameStop):
    return false
  let idStart = nameStop + tasksPrefix.len
  var idStop = idStart
  while idStop < path.len and path[idStop] >= '0' and path[idStop] <= '9':
    inc idStop
  if not parseU32Decimal(path, idStart, idStop, taskId):
    return false
  tailStart = idStop
  true

proc peerStartResponse(core: WasmOsCore, slot: uint32, exportName: string,
                       body: openArray[byte]): WasmHttpResponse =
  var args: array[MaxInvokeArgs, int32]
  var argc: int
  if not parseInvokeArgs(body, args, argc):
    return response(400, "text/plain", "bad start args")
  let r =
    if argc == 0:
      dispatchPeerRequest(core, wasmPeerStart, slot = slot,
                          exportName = exportName,
                          args = [], fuel = WasmSchedulerDefaultMaxTotalFuel,
                          timeoutPolls = WasmHttpPeerTimeoutPolls)
    else:
      dispatchPeerRequest(core, wasmPeerStart, slot = slot,
                          exportName = exportName,
                          args = toOpenArray(args, 0, argc - 1),
                          fuel = WasmSchedulerDefaultMaxTotalFuel,
                          timeoutPolls = WasmHttpPeerTimeoutPolls)
  if r.timedOut:
    return response(504, "text/plain", statusText(r))
  if r.badCore:
    return response(400, "text/plain", statusText(r))
  if r.controlStatus == wasmControlOk:
    return response(201, "text/plain", statusText(r))
  response(500, "text/plain", statusText(r))

proc enclaveStartResponse(slot: uint32, exportName: string,
                          body: openArray[byte]): WasmHttpResponse =
  if wasmHttpEnclaveControlProvider == nil:
    return response(501, "text/plain", "enclave placement unavailable")
  var args: array[MaxInvokeArgs, int32]
  var argc: int
  if not parseInvokeArgs(body, args, argc):
    return response(400, "text/plain", "bad start args")
  let r =
    if argc == 0:
      wasmHttpEnclaveControlProvider(wasmPeerStart, slot, 0'u32,
                                     WasmSchedulerDefaultMaxTotalFuel,
                                     exportName, [])
    else:
      wasmHttpEnclaveControlProvider(wasmPeerStart, slot, 0'u32,
                                     WasmSchedulerDefaultMaxTotalFuel,
                                     exportName,
                                     toOpenArray(args, 0, argc - 1))
  if r.timedOut:
    return response(504, "text/plain", statusText(r))
  if r.badCore:
    return response(400, "text/plain", statusText(r))
  if r.controlStatus == wasmControlOk:
    return response(201, "text/plain", statusText(r))
  response(500, "text/plain", statusText(r))

proc parseTaskPath(path: string, taskId: var uint32,
                   tailStart: var int): bool =
  if not path.startsWithAt(TasksPath & "/", 0):
    return false
  let start = TasksPath.len + 1
  var stop = start
  while stop < path.len and path[stop] >= '0' and path[stop] <= '9':
    inc stop
  if not parseU32Decimal(path, start, stop, taskId):
    return false
  tailStart = stop
  true

proc parseFuel(body: openArray[byte], defaultFuel: uint32): uint32 =
  if body.len == 0:
    return defaultFuel
  var start = 0
  while start < body.len and (body[start] == byte(' ') or body[start] == byte('\t') or
      body[start] == byte('\r') or body[start] == byte('\n')):
    inc start
  if start + 5 <= body.len and body.startsWithAt("fuel=", start):
    start += 5
  var stop = start
  while stop < body.len and body[stop] >= byte('0') and body[stop] <= byte('9'):
    inc stop
  var value: uint32
  if stop > start and parseU32Decimal(body, start, stop, value):
    return value
  defaultFuel

proc handleWasmHttpRequest*(httpMethod: WasmHttpMethod, path: string,
                            body: openArray[byte]): WasmHttpResponse =
  ## Supported routes:
  ## - GET    /wasm/capabilities
  ## - GET    /wasm/cores
  ## - GET    /wasm/system
  ## - GET    /wasm/events
  ## - GET    /wasm/events/stream
  ## - GET    /wasm/traps
  ## - GET    /wasm/placement
  ## - GET    /wasm/net/status
  ## - GET    /wasm/programs
  ## - GET    /wasm/tasks
  ## - GET    /wasm/tasks/all
  ## - GET    /wasm/repository
  ## - POST   /wasm/programs/<slot>                  raw .wasm body
  ## - POST   /wasm/programs/<slot>/invoke/<export>  body: i32[,i32...]
  ## - POST   /wasm/programs/<slot>/start/<export>   body: i32[,i32...]
  ## - POST   /wasm/cores/<core>/programs/<slot>/start/<export>
  ##          placement-aware start; M0 executes locally, D0/LP via peer mailbox.
  ## - POST   /wasm/cores/<core>/tasks/<id>/resume   body: fuel=N
  ## - POST   /wasm/cores/<core>/tasks/<id>/status
  ## - POST   /wasm/cores/<core>/tasks/run           body: fuel=N
  ## - POST   /wasm/tasks/<id>/resume                body: fuel=N
  ## - POST   /wasm/tasks/run                        body: fuel=N
  ## - POST   /wasm/placement                        body: line manifest
  ## - POST   /wasm/repository/<name>.wasm           raw .wasm body saved to SD
  ## - POST   /wasm/repository/<name>.manifest       sidecar metadata manifest
  ## - POST   /wasm/repository/<name>.wasm/install/<slot>
  ##          install SD repository file into a flash-backed slot
  ## - DELETE /wasm/programs/<slot>
  ## - DELETE /wasm/repository/<name>.wasm
  ## - DELETE /wasm/repository/<name>.manifest
  ## - DELETE /wasm/cores/<core>/tasks/<id>
  case httpMethod
  of wasmHttpGet:
    if path == CapabilitiesPath:
      return capabilitiesResponse()
    if path == CoresPath:
      return coresResponse()
    if path == SystemPath:
      return systemResponse()
    if path == EventsPath:
      return eventsResponse()
    if path == EventsStreamPath:
      return eventsStreamResponse()
    if path == TrapsPath:
      return trapsResponse()
    if path == PlacementPath:
      return placementPolicyResponse()
    if path == NetStatusPath:
      return netStatusResponse()
    if path == ProgramsPath:
      return listProgramsResponse()
    if path == TasksPath & "/all":
      return listAllTasksResponse()
    if path == TasksPath:
      return listTasksResponse()
    if path == RepositoryPath:
      when defined(bl808m0) or defined(bl808d0) or defined(bl808lp):
        return listRepositoryResponse()
      else:
        return response(500, "text/plain", "sd repository unavailable")
    response(404, "text/plain", "not found")
  of wasmHttpPost:
    var slot: uint32
    var repositoryName = ""
    var placementCore: WasmOsCore
    var placementExport = ""
    if path == PlacementPath:
      return placementDecisionResponse(body)
    if parseCoreStartPath(path, placementCore, slot, placementExport):
      if placementCore == currentWasmOsCore():
        var args: array[MaxInvokeArgs, int32]
        var argc: int
        if not parseInvokeArgs(body, args, argc):
          return response(400, "text/plain", "bad start args")
        let r =
          if argc == 0:
            startWasmProgramTaskI32(slot, placementExport, [])
          else:
            startWasmProgramTaskI32(slot, placementExport,
                                    toOpenArray(args, 0, argc - 1))
        if r.status == wasmControlOk:
          return response(201, "text/plain", statusText(r))
        return response(500, "text/plain", statusText(r))
      elif placementCore in {wasmOsCoreD0, wasmOsCoreLP}:
        return peerStartResponse(placementCore, slot, placementExport, body)
      elif placementCore == wasmOsCoreEnclave:
        return enclaveStartResponse(slot, placementExport, body)
      elif placementCore == wasmOsCoreUnknown:
        return response(400, "text/plain", "bad core")
      else:
        return response(501, "text/plain",
                        "remote placement unavailable core=" & wasmOsCoreName(placementCore))
    var peerCore: WasmOsCore
    var peerTaskId: uint32
    var peerTaskTail: int
    if path == CoresPath & "/d0/tasks/run" or path == CoresPath & "/lp/tasks/run":
      peerCore = if path.startsWithAt(CoresPath & "/d0/", 0): wasmOsCoreD0 else: wasmOsCoreLP
      let r = dispatchPeerRequest(peerCore, wasmPeerRunScheduler,
                                  slot = 32'u32,
                                  fuel = parseFuel(body, WasmSchedulerDefaultFuel),
                                  timeoutPolls = WasmHttpPeerTimeoutPolls)
      if r.timedOut:
        return response(504, "text/plain", statusText(r))
      if r.controlStatus == wasmControlOk:
        return response(200, "text/plain", statusText(r))
      return response(400, "text/plain", statusText(r))
    if parseCoreTaskPath(path, peerCore, peerTaskId, peerTaskTail):
      if peerCore notin {wasmOsCoreD0, wasmOsCoreLP, wasmOsCoreEnclave}:
        return response(501, "text/plain",
                        "remote task control unavailable core=" & wasmOsCoreName(peerCore))
      let opcode =
        if path.startsWithAt("/resume", peerTaskTail) and peerTaskTail + 7 == path.len:
          wasmPeerResume
        elif path.startsWithAt("/status", peerTaskTail) and peerTaskTail + 7 == path.len:
          wasmPeerStatus
        else:
          wasmPeerNoop
      if opcode == wasmPeerNoop:
        return response(404, "text/plain", "not found")
      let r =
        if peerCore == wasmOsCoreEnclave:
          if wasmHttpEnclaveControlProvider == nil:
            return response(501, "text/plain", "enclave task control unavailable")
          wasmHttpEnclaveControlProvider(opcode, 0'u32, peerTaskId,
                                         parseFuel(body, WasmSchedulerDefaultFuel),
                                         "", [])
        else:
          dispatchPeerRequest(peerCore, opcode, taskId = peerTaskId,
                              fuel = parseFuel(body, WasmSchedulerDefaultFuel),
                              timeoutPolls = WasmHttpPeerTimeoutPolls)
      if r.timedOut:
        return response(504, "text/plain", statusText(r))
      if r.controlStatus == wasmControlOk:
        return response(200, "text/plain", statusText(r))
      return response(400, "text/plain", statusText(r))
    var manifestTail: int
    if parseRepositoryManifestPath(path, repositoryName, manifestTail) and
        manifestTail == path.len:
      let manifestText = if body.len == 0: "" else: asciiSlice(body, 0, body.len)
      let manifest = parseWasmOsManifest(manifestText)
      if not manifest.valid:
        return response(400, "text/plain", "bad manifest")
      when defined(bl808m0) or defined(bl808d0) or defined(bl808lp):
        if not ensureHttpStorage():
          return response(503, "text/plain", storageStatusText(osStorageStatus()))
        let r = saveWasmManifestToSd(osStorageFs(), repositoryName, body)
        if r.status == wasmSdInstallOk:
          return response(201, "text/plain", statusText(r))
        return response(400, "text/plain", statusText(r))
      else:
        return response(500, "text/plain", "sd repository unavailable")
    if parseRepositoryInstallPath(path, repositoryName, slot):
      when defined(bl808m0) or defined(bl808d0) or defined(bl808lp):
        if not ensureHttpStorage():
          return response(503, "text/plain", storageStatusText(osStorageStatus()))
        let r = installNamedWasmProgramFromSd(
          osStorageFs(),
          repositoryName,
          slot,
          wasmHttpSdScratch,
          generation = 1'u32,
        )
        if r.status == wasmSdInstallOk:
          return response(201, "text/plain", statusText(r))
        return response(400, "text/plain", statusText(r))
      else:
        return response(500, "text/plain", "sd repository unavailable")
    var repositoryTail: int
    if parseRepositoryPath(path, repositoryName, repositoryTail) and
        repositoryTail == path.len:
      when defined(bl808m0) or defined(bl808d0) or defined(bl808lp):
        if not ensureHttpStorage():
          return response(503, "text/plain", storageStatusText(osStorageStatus()))
        let r = saveWasmProgramToSd(osStorageFs(), repositoryName, body)
        if r.status == wasmSdInstallOk:
          return response(201, "text/plain", statusText(r))
        return response(400, "text/plain", statusText(r))
      else:
        return response(500, "text/plain", "sd repository unavailable")

    var exportName = ""
    if parseStartPath(path, slot, exportName):
      var args: array[MaxInvokeArgs, int32]
      var argc: int
      if not parseInvokeArgs(body, args, argc):
        return response(400, "text/plain", "bad start args")
      let r =
        if argc == 0:
          startWasmProgramTaskI32(slot, exportName, [])
        else:
          startWasmProgramTaskI32(slot, exportName, toOpenArray(args, 0, argc - 1))
      if r.status == wasmControlOk:
        return response(201, "text/plain", statusText(r))
      return response(500, "text/plain", statusText(r))

    var taskId: uint32
    var taskTail: int
    if path == TasksPath & "/run":
      let resumes = runWasmProgramScheduler(parseFuel(body, WasmSchedulerDefaultFuel), 32'u32)
      return response(200, "text/plain", "resumes=" & $resumes)
    if parseTaskPath(path, taskId, taskTail) and
        path.startsWithAt("/resume", taskTail) and taskTail + 7 == path.len:
      let r = resumeWasmProgramTask(taskId, parseFuel(body, WasmSchedulerDefaultFuel))
      if r.status == wasmControlOk:
        return response(200, "text/plain", statusText(r))
      return response(400, "text/plain", statusText(r))

    if parseInvokePath(path, slot, exportName):
      var args: array[MaxInvokeArgs, int32]
      var argc: int
      if not parseInvokeArgs(body, args, argc):
        return response(400, "text/plain", "bad invoke args")
      let r =
        if argc == 0:
          runWasmProgramI32(slot, exportName, [])
        else:
          runWasmProgramI32(slot, exportName, toOpenArray(args, 0, argc - 1))
      if r.status == wasmControlOk:
        return response(200, "text/plain", statusText(r), r)
      return response(500, "text/plain", statusText(r), r)
    var tail: int
    if parseSlotPath(path, slot, tail) and tail == path.len:
      let r = installWasmProgramBytes(slot, body, generation = 1'u32)
      if r.status == wasmControlOk:
        return response(201, "text/plain", statusText(r), r)
      return response(400, "text/plain", statusText(r), r)
    response(404, "text/plain", "not found")
  of wasmHttpDelete:
    var slot: uint32
    var tail: int
    var taskId: uint32
    var taskTail: int
    var repositoryName = ""
    var peerCore: WasmOsCore
    var peerTaskId: uint32
    var peerTaskTail: int
    if parseCoreTaskPath(path, peerCore, peerTaskId, peerTaskTail) and peerTaskTail == path.len:
      if peerCore notin {wasmOsCoreD0, wasmOsCoreLP, wasmOsCoreEnclave}:
        return response(501, "text/plain",
                        "remote task control unavailable core=" & wasmOsCoreName(peerCore))
      let r =
        if peerCore == wasmOsCoreEnclave:
          if wasmHttpEnclaveControlProvider == nil:
            return response(501, "text/plain", "enclave task control unavailable")
          wasmHttpEnclaveControlProvider(wasmPeerKill, 0'u32, peerTaskId,
                                         WasmSchedulerDefaultFuel, "", [])
        else:
          dispatchPeerRequest(peerCore, wasmPeerKill, taskId = peerTaskId,
                              timeoutPolls = WasmHttpPeerTimeoutPolls)
      if r.timedOut:
        return response(504, "text/plain", statusText(r))
      if r.controlStatus == wasmControlOk:
        return response(200, "text/plain", statusText(r))
      return response(400, "text/plain", statusText(r))
    var manifestTail: int
    if parseRepositoryManifestPath(path, repositoryName, manifestTail) and
        manifestTail == path.len:
      when defined(bl808m0) or defined(bl808d0) or defined(bl808lp):
        if not ensureHttpStorage():
          return response(503, "text/plain", storageStatusText(osStorageStatus()))
        let r = deleteWasmManifestFromSd(osStorageFs(), repositoryName)
        if r.status == wasmSdInstallOk:
          return response(200, "text/plain", statusText(r))
        return response(400, "text/plain", statusText(r))
      else:
        return response(500, "text/plain", "sd repository unavailable")
    if parseRepositoryPath(path, repositoryName, tail) and tail == path.len:
      when defined(bl808m0) or defined(bl808d0) or defined(bl808lp):
        if not ensureHttpStorage():
          return response(503, "text/plain", storageStatusText(osStorageStatus()))
        let r = deleteWasmProgramFromSd(osStorageFs(), repositoryName)
        if r.status == wasmSdInstallOk:
          return response(200, "text/plain", statusText(r))
        return response(400, "text/plain", statusText(r))
      else:
        return response(500, "text/plain", "sd repository unavailable")
    if parseSlotPath(path, slot, tail) and tail == path.len:
      let r = unloadWasmProgram(slot)
      if r.status == wasmControlOk:
        return response(200, "text/plain", statusText(r), r)
      return response(400, "text/plain", statusText(r), r)
    if parseTaskPath(path, taskId, taskTail) and taskTail == path.len:
      let r = killWasmProgramTask(taskId)
      if r.status == wasmControlOk:
        return response(200, "text/plain", statusText(r))
      return response(400, "text/plain", statusText(r))
    response(404, "text/plain", "not found")

proc parseHttpMethod(data: openArray[byte], lineStop: int,
                     parsedMethod: var WasmHttpMethod,
                     pathStart: var int): bool =
  if data.startsWithAt("GET ", 0):
    parsedMethod = wasmHttpGet
    pathStart = 4
    return true
  if data.startsWithAt("POST ", 0):
    parsedMethod = wasmHttpPost
    pathStart = 5
    return true
  if data.startsWithAt("DELETE ", 0):
    parsedMethod = wasmHttpDelete
    pathStart = 7
    return true
  false

proc contentLengthFromHeaders(data: openArray[byte], start, stop: int,
                              length: var uint32): bool =
  length = 0
  var line = start
  while line < stop:
    var lineEnd = line
    while lineEnd < stop and not (data[lineEnd] == byte('\r') and
        lineEnd + 1 < stop and data[lineEnd + 1] == byte('\n')):
      inc lineEnd
    const name = "Content-Length:"
    if lineEnd - line >= name.len and data.startsWithAt(name, line):
      var valueStart = line + name.len
      while valueStart < lineEnd and data[valueStart] == byte(' '):
        inc valueStart
      return parseU32Decimal(data, valueStart, lineEnd, length)
    line = lineEnd + 2
  true

proc handleWasmHttpBytes*(request: openArray[byte]): WasmHttpResponse =
  ## Parse a single complete HTTP/1.x request buffer and dispatch to WASM routes.
  let headerEnd = findHeaderEnd(request)
  if headerEnd < 0:
    return response(400, "text/plain", "bad request")

  var lineStop = 0
  while lineStop < headerEnd and not (request[lineStop] == byte('\r') and
      lineStop + 1 < headerEnd and request[lineStop + 1] == byte('\n')):
    inc lineStop

  var parsedMethod: WasmHttpMethod
  var pathStart: int
  if not parseHttpMethod(request, lineStop, parsedMethod, pathStart):
    return response(400, "text/plain", "bad method")

  var pathStop = pathStart
  while pathStop < lineStop and request[pathStop] != byte(' '):
    inc pathStop
  if pathStop <= pathStart:
    return response(400, "text/plain", "bad path")

  var contentLen: uint32
  if not contentLengthFromHeaders(request, lineStop + 2, headerEnd, contentLen):
    return response(400, "text/plain", "bad content length")
  let bodyStart = headerEnd + 4
  if bodyStart + contentLen.int > request.len:
    return response(400, "text/plain", "incomplete body")

  let path = asciiSlice(request, pathStart, pathStop)
  if contentLen == 0:
    return handleWasmHttpRequest(parsedMethod, path, [])
  handleWasmHttpRequest(
    parsedMethod,
    path,
    request.toOpenArray(bodyStart, bodyStart + contentLen.int - 1),
  )
