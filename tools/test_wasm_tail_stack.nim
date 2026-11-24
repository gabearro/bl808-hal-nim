import std/os
import cps/wasm/[binary, runtime, types, validate]

let bytes = readFile(paramStr(1))
let name = paramStr(2)
let module = decodeModule(bytes.toOpenArrayByte(0, bytes.high), optimize = false)
validateModule(module)

var vm = initWasmVM()
var hostCalls = 0
proc finish(args: openArray[WasmValue]): seq[WasmValue] =
  inc hostCalls
  doAssert vm.valueStackTop == 1, "host must see only the wrapper's operand"
  doAssert args.len == 1 and args[0].kind == wvkI32 and args[0].i32 == 42
  @[args[0]]

let idx = vm.instantiate(module, [("env", "finish", ExternalVal(kind: ekFunc,
  funcType: FuncType(params: @[vtI32], results: @[vtI32]), hostFunc: finish))])
let entry = vm.getExport(idx, name).idx
var continuation: WasmContinuation
var results: seq[WasmValue]
while true:
  results = vm.executeSlice(entry, [], continuation, 1)
  if continuation.status == wesComplete: break
  doAssert continuation.status == wesYielded and continuation.instructions < 150_000
  # Check after each instruction so restoring the stack on final return cannot
  # hide growth. Five slots suffice for the wrapper and one recursive step.
  doAssert vm.valueStackTop <= 5, "operand stack grew past one call's working set"
  doAssert vm.callStackTop <= 2, "tail call pushed a guest frame"

doAssert results.len == 1 and results[0].kind == wvkI32 and results[0].i32 == 1042
doAssert vm.valueStackTop == 0 and vm.callStackTop == 0
if name in ["direct", "indirect"]:
  doAssert continuation.instructions >= 80_000
  doAssert hostCalls == 0
else:
  doAssert hostCalls == 1

# The regular run-to-completion entry point uses the same stack discipline.
let capacity = vm.valueStack.len
let uninterrupted = vm.execute(entry, [])
doAssert uninterrupted.len == 1 and uninterrupted[0].kind == wvkI32 and
  uninterrupted[0].i32 == 1042
doAssert vm.valueStack.len == capacity
