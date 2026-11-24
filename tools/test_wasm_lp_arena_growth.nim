import std/os
import cps/wasm/[binary, runtime, types, validate]

let bytes = readFile(paramStr(1))
let module = decodeModule(bytes.toOpenArrayByte(0, bytes.len - 1))
validateModule(module)
var vm = initWasmVM()
let moduleIdx = vm.instantiate(module, [])
for iteration in 0 ..< 3:
  let deep = vm.invoke(moduleIdx, "deep", [])
  doAssert deep.len == 1 and deep[0].kind == wvkI32 and deep[0].i32 == 42
  let wide = vm.invoke(moduleIdx, "wide", [])
  doAssert wide.len == 1 and wide[0].kind == wvkI32 and wide[0].i32 == 41
for item in [("deep", 42'i32), ("wide", 41'i32)]:
  let name = item[0]
  let expected = item[1]
  let funcAddr = vm.getExport(moduleIdx, name).idx
  var continuation: WasmContinuation
  var yields = 0
  var values: seq[WasmValue]
  while true:
    values = vm.executeSlice(funcAddr, [], continuation, 3)
    if continuation.status == wesComplete: break
    doAssert continuation.status == wesYielded
    doAssert values.len == 0
    inc yields
    doAssert yields < 500
  doAssert yields > 0 and continuation.instructions > 3
  doAssert values.len == 1 and values[0].kind == wvkI32 and
    values[0].i32 == expected
  doAssert vm.callStackTop == 0 and vm.labelStackTop == 0 and vm.localsTop == 0

var abandoned: WasmContinuation
discard vm.executeSlice(vm.getExport(moduleIdx, "deep").idx, [], abandoned, 1)
doAssert abandoned.status == wesYielded
vm.abortExecution(abandoned)
doAssert abandoned.status == wesReady
doAssert vm.callStackTop == 0 and vm.labelStackTop == 0 and vm.localsTop == 0
let restarted = vm.invoke(moduleIdx, "deep", [])
doAssert restarted.len == 1 and restarted[0].i32 == 42
var trapped: WasmContinuation
var sawTrap = false
try:
  discard vm.executeSlice(vm.getExport(moduleIdx, "trap").idx, [], trapped, 10)
except WasmTrap:
  sawTrap = true
doAssert sawTrap and trapped.status == wesRunning
vm.abortExecution(trapped)
doAssert trapped.status == wesReady
doAssert vm.invoke(moduleIdx, "deep", [])[0].i32 == 42
doAssert vm.callStackTop == 0 and vm.labelStackTop == 0 and vm.localsTop == 0
echo "LP-sized full interpreter arenas PASS: growth and sliced local execution"
