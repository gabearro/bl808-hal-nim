import std/os
import cps/wasm/[binary, runtime, types, validate]

var vm = initWasmVM()
var ready, badType, tryReentry: bool
var requests, completions: int
var moduleIndex = -1
proc fixedTicks(): uint64 = 11
let host: HostFunc = proc(args: openArray[WasmValue]): seq[WasmValue] =
  inc requests
  if tryReentry:
    tryReentry = false
    for entry in ["direct", "host"]:
      try:
        discard vm.invoke(moduleIndex, entry, [wasmI32(0)])
        doAssert false
      except WasmTrap as error:
        doAssert error.msg == "host suspension requires sliced interpreter execution"
  let value = args[0]
  vm.suspendHostCall(WasmHostWait(
    ready: proc(): bool = ready,
    finish: proc(): seq[WasmValue] =
      inc completions
      if badType: @[wasmI64(value.i32)]
      else: @[value]))
let module = decodeModule(cast[seq[byte]](readFile(paramStr(1))))
validateModule(module)
let imports = @[("host", "wait", ExternalVal(kind: ekFunc,
  funcType: FuncType(params: @[vtI32], results: @[vtI32]), hostFunc: host))]
moduleIndex = vm.instantiate(module, imports)

for name in ["direct", "indirect", "tail", "indirect-tail", "nested-tail", "deep", "host"]:
  let address = vm.getExport(moduleIndex, name).idx
  let before = requests
  let completeBefore = completions
  var call: WasmContinuation
  ready = false
  tryReentry = name == "direct"
  let input = if name == "host": 42 else: 40
  discard vm.executeSlice(address, [wasmI32(input.int32)], call, 200)
  doAssert call.status == wesHostBlocked
  let blockedAt = call.instructions
  doAssert not call.executionHostReady()
  doAssert vm.executeSlice(address, [], call, 200).len == 0
  doAssert call.status == wesHostBlocked and call.instructions == blockedAt
  ready = true
  doAssert call.executionHostReady()
  if name == "direct":
    doAssert vm.capturePortableSnapshot(call, default(array[32, byte])).status == wpsNotSuspended
    discard vm.executeSlice(address, [], call, 200, deadlineClock = fixedTicks, deadlineTick = 11)
    doAssert call.status == wesHostBlocked and completions == completeBefore
  let answer = vm.executeSlice(address, [], call, 200)
  doAssert call.status == wesComplete and answer.len == 1 and answer[0].i32 == 42
  doAssert requests == before + (if name == "direct": 3 else: 1)
  doAssert completions == completeBefore + 1
  doAssert vm.localsTop == 0 and vm.callStackTop == 0 and
    vm.labelStackTop == 0 and vm.valueStackTop == 0

let address = vm.getExport(moduleIndex, "direct").idx
var continuation: WasmContinuation
ready = false
discard vm.executeSlice(address, [wasmI32(40)], continuation, 200)
var another = initWasmVM()
try:
  discard another.executeSlice(address, [], continuation, 200)
  doAssert false
except WasmTrap as error:
  doAssert error.msg == "stale interpreter host continuation"
let beforeAbort = completions
vm.abortExecution(continuation)
doAssert continuation.status == wesReady and vm.callStackTop == 0
doAssert not continuation.executionHostReady() and completions == beforeAbort

discard vm.executeSlice(address, [wasmI32(40)], continuation, 200)
ready = true
badType = true
try:
  discard vm.executeSlice(address, [], continuation, 200)
  doAssert false
except WasmTrap as error:
  doAssert error.msg == "suspended host call result type mismatch"
vm.abortExecution(continuation)
doAssert vm.callStackTop == 0 and continuation.status == wesReady
echo "WASM host suspension PASS: direct, indirect, tail, nested, abort and typed resume"
