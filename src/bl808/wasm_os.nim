## OS-level policy and observability helpers for the BL808 WASM runtime.
##
## This module intentionally stays transport-neutral. HTTP, UART, enclave, and
## future IPC command surfaces can share the same core names, resource limits,
## manifest parsing, event log, and trap reporting.

import ./wasm_runtime
import ./wasm_scheduler

type
  WasmOsCore* = enum
    wasmOsCoreUnknown
    wasmOsCoreM0
    wasmOsCoreD0
    wasmOsCoreLP
    wasmOsCoreEnclave

  WasmOsPlacementStatus* = enum
    wasmPlaceOk
    wasmPlaceBadCore
    wasmPlaceRemoteUnsupported
    wasmPlaceIncompatible
    wasmPlaceNoEligibleCore

  WasmOsResourceLimits* = object
    maxFuel*: uint32
    sliceFuel*: uint32
    maxMemoryPages*: uint32
    maxTasks*: uint32
    maxOpenHandles*: uint32
    maxStorageBytes*: uint32
    allowNetwork*: bool
    allowStorage*: bool
    allowIpc*: bool
    allowCrypto*: bool
    allowGpio*: bool
    requireEnclave*: bool

  WasmOsImportFlag* = enum
    wasmImportTime
    wasmImportSleep
    wasmImportLog
    wasmImportGpio
    wasmImportNet
    wasmImportStorage
    wasmImportIpc
    wasmImportRandom
    wasmImportCrypto
    wasmImportHttp

  WasmOsHostCall* = enum
    wasmHostSleep
    wasmHostLog
    wasmHostStorageRead
    wasmHostStorageWrite
    wasmHostIpcSend
    wasmHostIpcRecv
    wasmHostHttpRequest
    wasmHostNetSend
    wasmHostNetRecv
    wasmHostRandom
    wasmHostCrypto
    wasmHostGpio

  WasmOsProgramManifest* = object
    valid*: bool
    name*: string
    version*: string
    preferredCore*: WasmOsCore
    coreMask*: uint32
    importMask*: uint32
    limits*: WasmOsResourceLimits
    hash*: uint32
    signatureRequired*: bool

  WasmOsTaskStartRequest* = object
    core*: WasmOsCore
    slot*: uint32
    exportName*: string
    argc*: int
    args*: array[8, int32]
    limits*: WasmOsResourceLimits

  WasmOsPlacementDecision* = object
    status*: WasmOsPlacementStatus
    core*: WasmOsCore
    reason*: uint32

  WasmOsEventKind* = enum
    wasmEventNone
    wasmEventProgramInstalled
    wasmEventProgramUnloaded
    wasmEventTaskStarted
    wasmEventTaskYielded
    wasmEventTaskBlocked
    wasmEventTaskUnblocked
    wasmEventTaskExited
    wasmEventTaskKilled
    wasmEventTrap
    wasmEventHttpRequest
    wasmEventCoreMessage

  WasmOsEvent* = object
    id*: uint32
    kind*: WasmOsEventKind
    core*: WasmOsCore
    taskId*: uint32
    slot*: int32
    value*: int32
    code*: uint32

  WasmOsTrapRecord* = object
    valid*: bool
    id*: uint32
    core*: WasmOsCore
    taskId*: uint32
    slot*: int32
    trapCode*: uint32
    fuelUsed*: uint32
    state*: WasmSchedulerTaskState

const
  WasmOsCoreM0Bit* = 1'u32 shl wasmOsCoreM0.ord
  WasmOsCoreD0Bit* = 1'u32 shl wasmOsCoreD0.ord
  WasmOsCoreLPBit* = 1'u32 shl wasmOsCoreLP.ord
  WasmOsCoreEnclaveBit* = 1'u32 shl wasmOsCoreEnclave.ord
  WasmOsAllCoreMask* =
    WasmOsCoreM0Bit or WasmOsCoreD0Bit or WasmOsCoreLPBit or WasmOsCoreEnclaveBit
  WasmOsEventLogLen* {.intdefine.} = 32
  WasmOsTrapLogLen* {.intdefine.} = 16

var
  eventLog: array[WasmOsEventLogLen, WasmOsEvent]
  eventWrite = 0'u32
  nextEventId = 1'u32
  trapLog: array[WasmOsTrapLogLen, WasmOsTrapRecord]
  trapWrite = 0'u32
  nextTrapId = 1'u32

proc wasmOsCoreName*(core: WasmOsCore): string =
  case core
  of wasmOsCoreM0: "m0"
  of wasmOsCoreD0: "d0"
  of wasmOsCoreLP: "lp"
  of wasmOsCoreEnclave: "enclave"
  else: "unknown"

proc parseWasmOsCore*(value: string): WasmOsCore =
  if value == "m0": wasmOsCoreM0
  elif value == "d0": wasmOsCoreD0
  elif value == "lp": wasmOsCoreLP
  elif value == "enclave": wasmOsCoreEnclave
  else: wasmOsCoreUnknown

proc wasmRuntimeCoreAsOsCore*(core: WasmRuntimeCore): WasmOsCore =
  case core
  of wasmCoreM0: wasmOsCoreM0
  of wasmCoreD0: wasmOsCoreD0
  of wasmCoreLP: wasmOsCoreLP
  else: wasmOsCoreUnknown

proc currentWasmOsCore*(): WasmOsCore =
  wasmRuntimeCoreAsOsCore(wasmRuntimeCapabilities().core)

proc defaultWasmOsResourceLimits*(): WasmOsResourceLimits =
  WasmOsResourceLimits(
    maxFuel: WasmSchedulerDefaultMaxTotalFuel,
    sliceFuel: WasmSchedulerDefaultFuel,
    maxMemoryPages: 1,
    maxTasks: WasmSchedulerMaxTasks.uint32,
    maxOpenHandles: 4,
    maxStorageBytes: 64 * 1024,
    allowNetwork: false,
    allowStorage: false,
    allowIpc: true,
    allowCrypto: false,
    allowGpio: false,
    requireEnclave: false,
  )

proc coreBit*(core: WasmOsCore): uint32 =
  if core == wasmOsCoreUnknown: 0'u32 else: 1'u32 shl core.ord

proc currentCoreCanRun*(core: WasmOsCore): WasmOsPlacementStatus =
  if core == wasmOsCoreUnknown:
    return wasmPlaceBadCore
  if core == currentWasmOsCore():
    return wasmPlaceOk
  wasmPlaceRemoteUnsupported

proc wasmPlacementStatusName*(status: WasmOsPlacementStatus): string =
  case status
  of wasmPlaceOk: "ok"
  of wasmPlaceBadCore: "bad_core"
  of wasmPlaceRemoteUnsupported: "remote_unsupported"
  of wasmPlaceIncompatible: "incompatible"
  of wasmPlaceNoEligibleCore: "no_eligible_core"

proc coreCompatibleWithCaps*(core: WasmOsCore,
                             caps: WasmRuntimeCapabilities): bool =
  case core
  of wasmOsCoreM0:
    caps.core == wasmCoreM0
  of wasmOsCoreD0:
    caps.core == wasmCoreD0
  of wasmOsCoreLP:
    caps.core == wasmCoreLP and caps.compact and caps.softwareF32 and not caps.supportsF64
  of wasmOsCoreEnclave:
    caps.compact and caps.flashBacked
  else:
    false

proc coreSupportsManifest(core: WasmOsCore,
                          manifest: WasmOsProgramManifest): bool =
  if (manifest.coreMask and coreBit(core)) == 0:
    return false
  if manifest.limits.requireEnclave and core != wasmOsCoreEnclave:
    return false
  if (manifest.importMask and (1'u32 shl wasmImportGpio.ord)) != 0 and
      core notin {wasmOsCoreM0, wasmOsCoreLP}:
    return false
  if (manifest.importMask and (1'u32 shl wasmImportNet.ord)) != 0 and
      core != wasmOsCoreM0:
    return false
  if (manifest.importMask and (1'u32 shl wasmImportHttp.ord)) != 0 and
      core != wasmOsCoreM0:
    return false
  if (manifest.importMask and (1'u32 shl wasmImportStorage.ord)) != 0 and
      core == wasmOsCoreLP:
    return false
  true

proc chooseWasmOsPlacement*(manifest: WasmOsProgramManifest): WasmOsPlacementDecision =
  ## Pick a deterministic core for a manifest. Runtime load balancing can layer
  ## on top later; this function captures hard capability and policy filters.
  if not manifest.valid:
    return WasmOsPlacementDecision(status: wasmPlaceIncompatible,
                                   core: wasmOsCoreUnknown, reason: 1)
  if manifest.preferredCore != wasmOsCoreUnknown and
      coreSupportsManifest(manifest.preferredCore, manifest):
    return WasmOsPlacementDecision(status: wasmPlaceOk,
                                   core: manifest.preferredCore, reason: 0)
  if manifest.limits.requireEnclave and coreSupportsManifest(wasmOsCoreEnclave, manifest):
    return WasmOsPlacementDecision(status: wasmPlaceOk,
                                   core: wasmOsCoreEnclave, reason: 2)
  let order = [wasmOsCoreM0, wasmOsCoreD0, wasmOsCoreLP, wasmOsCoreEnclave]
  for core in order:
    if coreSupportsManifest(core, manifest):
      return WasmOsPlacementDecision(status: wasmPlaceOk, core: core, reason: 3)
  WasmOsPlacementDecision(status: wasmPlaceNoEligibleCore,
                          core: wasmOsCoreUnknown, reason: 4)

proc appendWasmOsEvent*(kind: WasmOsEventKind, core = currentWasmOsCore(),
                        taskId = 0'u32, slot = -1'i32, value = 0'i32,
                        code = 0'u32): uint32 =
  let id = nextEventId
  inc nextEventId
  if nextEventId == 0:
    nextEventId = 1
  eventLog[eventWrite.int mod eventLog.len] = WasmOsEvent(
    id: id, kind: kind, core: core, taskId: taskId, slot: slot,
    value: value, code: code)
  eventWrite = (eventWrite + 1'u32) mod eventLog.len.uint32
  id

proc collectWasmOsEvents*(outEvents: var openArray[WasmOsEvent]): uint32 =
  let total = min(eventLog.len.uint32, outEvents.len.uint32)
  var copied = 0'u32
  var offset = 0'u32
  while copied < total:
    let idx = (eventWrite + offset) mod eventLog.len.uint32
    if eventLog[idx.int].id != 0:
      outEvents[copied.int] = eventLog[idx.int]
      inc copied
    inc offset
    if offset >= eventLog.len.uint32:
      break
  copied

proc appendWasmOsTrap*(core: WasmOsCore, taskId: uint32, slot: int32,
                       trapCode, fuelUsed: uint32,
                       state: WasmSchedulerTaskState): uint32 =
  let id = nextTrapId
  inc nextTrapId
  if nextTrapId == 0:
    nextTrapId = 1
  trapLog[trapWrite.int mod trapLog.len] = WasmOsTrapRecord(
    valid: true, id: id, core: core, taskId: taskId, slot: slot,
    trapCode: trapCode, fuelUsed: fuelUsed, state: state)
  trapWrite = (trapWrite + 1'u32) mod trapLog.len.uint32
  discard appendWasmOsEvent(wasmEventTrap, core, taskId, slot, 0, trapCode)
  id

proc collectWasmOsTraps*(outTraps: var openArray[WasmOsTrapRecord]): uint32 =
  let total = min(trapLog.len.uint32, outTraps.len.uint32)
  var copied = 0'u32
  var offset = 0'u32
  while copied < total:
    let idx = (trapWrite + offset) mod trapLog.len.uint32
    if trapLog[idx.int].valid:
      outTraps[copied.int] = trapLog[idx.int]
      inc copied
    inc offset
    if offset >= trapLog.len.uint32:
      break
  copied

proc importFlagBit*(flag: WasmOsImportFlag): uint32 =
  1'u32 shl flag.ord

proc importNameToFlag*(name: string; flag: var WasmOsImportFlag): bool =
  case name
  of "time": flag = wasmImportTime
  of "sleep": flag = wasmImportSleep
  of "log": flag = wasmImportLog
  of "gpio": flag = wasmImportGpio
  of "net": flag = wasmImportNet
  of "storage": flag = wasmImportStorage
  of "ipc": flag = wasmImportIpc
  of "random": flag = wasmImportRandom
  of "crypto": flag = wasmImportCrypto
  of "http": flag = wasmImportHttp
  else:
    return false
  true

proc parseU32DecimalLocal(s: string, value: var uint32): bool =
  if s.len == 0:
    return false
  var n = 0'u32
  for ch in s:
    if ch < '0' or ch > '9':
      return false
    let digit = uint32(ord(ch) - ord('0'))
    if n > (uint32.high - digit) div 10'u32:
      return false
    n = n * 10'u32 + digit
  value = n
  true

proc parseBoolLocal(s: string): bool =
  s == "1" or s == "true" or s == "yes"

proc trimAscii(s: string): string =
  var start = 0
  var stop = s.len
  while start < stop and (s[start] == ' ' or s[start] == '\t' or
      s[start] == '\r' or s[start] == '\n'):
    inc start
  while stop > start and (s[stop - 1] == ' ' or s[stop - 1] == '\t' or
      s[stop - 1] == '\r' or s[stop - 1] == '\n'):
    dec stop
  s[start ..< stop]

proc addImportList(mask: var uint32, value: string) =
  var start = 0
  while start <= value.len:
    var stop = start
    while stop < value.len and value[stop] != ',':
      inc stop
    let item = trimAscii(value[start ..< stop])
    var flag: WasmOsImportFlag
    if item.len > 0 and importNameToFlag(item, flag):
      mask = mask or importFlagBit(flag)
    start = stop + 1
    if stop >= value.len:
      break

proc parseWasmOsManifest*(text: string): WasmOsProgramManifest =
  ## Parse a compact line-oriented manifest:
  ## name=demo
  ## version=1
  ## preferredCore=lp
  ## cores=m0,d0,lp,enclave
  ## imports=time,log,storage
  ## maxFuel=4096
  ## maxMemoryPages=1
  result.valid = true
  result.preferredCore = wasmOsCoreUnknown
  result.coreMask = WasmOsAllCoreMask
  result.limits = defaultWasmOsResourceLimits()

  var lineStart = 0
  while lineStart < text.len:
    var lineEnd = lineStart
    while lineEnd < text.len and text[lineEnd] != '\n':
      inc lineEnd
    let line = trimAscii(text[lineStart ..< lineEnd])
    if line.len > 0 and line[0] != '#':
      var eq = 0
      while eq < line.len and line[eq] != '=':
        inc eq
      if eq > 0 and eq < line.len:
        let key = trimAscii(line[0 ..< eq])
        let value = trimAscii(line[eq + 1 ..< line.len])
        var n: uint32
        case key
        of "name": result.name = value
        of "version": result.version = value
        of "preferredCore": result.preferredCore = parseWasmOsCore(value)
        of "cores":
          result.coreMask = 0
          var start = 0
          while start <= value.len:
            var stop = start
            while stop < value.len and value[stop] != ',':
              inc stop
            result.coreMask = result.coreMask or coreBit(parseWasmOsCore(trimAscii(value[start ..< stop])))
            start = stop + 1
            if stop >= value.len:
              break
        of "imports": addImportList(result.importMask, value)
        of "maxFuel":
          if parseU32DecimalLocal(value, n): result.limits.maxFuel = n
        of "sliceFuel":
          if parseU32DecimalLocal(value, n): result.limits.sliceFuel = n
        of "maxMemoryPages":
          if parseU32DecimalLocal(value, n): result.limits.maxMemoryPages = n
        of "maxTasks":
          if parseU32DecimalLocal(value, n): result.limits.maxTasks = n
        of "maxOpenHandles":
          if parseU32DecimalLocal(value, n): result.limits.maxOpenHandles = n
        of "maxStorageBytes":
          if parseU32DecimalLocal(value, n): result.limits.maxStorageBytes = n
        of "allowNetwork": result.limits.allowNetwork = parseBoolLocal(value)
        of "allowStorage": result.limits.allowStorage = parseBoolLocal(value)
        of "allowIpc": result.limits.allowIpc = parseBoolLocal(value)
        of "allowCrypto": result.limits.allowCrypto = parseBoolLocal(value)
        of "allowGpio": result.limits.allowGpio = parseBoolLocal(value)
        of "requireEnclave":
          result.limits.requireEnclave = parseBoolLocal(value)
          result.signatureRequired = result.signatureRequired or result.limits.requireEnclave
        of "signatureRequired": result.signatureRequired = parseBoolLocal(value)
        of "hash":
          if parseU32DecimalLocal(value, n): result.hash = n
        else:
          discard
    lineStart = lineEnd + 1

  if result.name.len == 0:
    result.valid = false
  if result.preferredCore == wasmOsCoreUnknown:
    result.preferredCore = currentWasmOsCore()

proc manifestAllowsCurrentCore*(manifest: WasmOsProgramManifest): bool =
  (manifest.coreMask and coreBit(currentWasmOsCore())) != 0

proc blockedStateForHostCall*(call: WasmOsHostCall): WasmSchedulerTaskState =
  case call
  of wasmHostSleep:
    wasmTaskBlockedTimer
  of wasmHostStorageRead, wasmHostStorageWrite:
    wasmTaskBlockedSd
  of wasmHostIpcSend, wasmHostIpcRecv:
    wasmTaskBlockedIpc
  of wasmHostHttpRequest, wasmHostNetSend, wasmHostNetRecv:
    wasmTaskBlockedHttp
  of wasmHostCrypto:
    wasmTaskBlockedEnclave
  else:
    wasmTaskYielded

proc requestWasmOsHostCall*(taskId: uint32, call: WasmOsHostCall): WasmSchedulerResult =
  ## Mark a task blocked while a CPS host operation is outstanding.
  ##
  ## VM import handlers should call this after recording the request payload in
  ## their own service queue. The completing CPS task should call
  ## `completeWasmOsHostCall` to make the WASM task runnable again.
  let blockedState = blockedStateForHostCall(call)
  if blockedState == wasmTaskYielded:
    return getWasmTask(taskId)
  result = blockWasmTask(taskId, blockedState)
  if result.status == wasmSchedOk:
    discard appendWasmOsEvent(wasmEventTaskBlocked, taskId = taskId,
                              slot = result.slot, code = call.ord.uint32)

proc completeWasmOsHostCall*(taskId: uint32, value = 0'i32,
                             code = 0'u32): WasmSchedulerResult =
  result = unblockWasmTask(taskId)
  if result.status == wasmSchedOk:
    discard appendWasmOsEvent(wasmEventTaskUnblocked, taskId = taskId,
                              slot = result.slot, value = value, code = code)
