import std/os
import cps/wasm/[binary, runtime, types, validate]

let bytes = readFile(paramStr(1))
let module = decodeModule(bytes.toOpenArrayByte(0, bytes.high), optimize = false)
validateModule(module)

var vm = initWasmVM()
var moduleIndex: int
let initialValues = vm.valueStack.len
let initialLocals = vm.locals.len

proc callGuest(args: openArray[WasmValue]): seq[WasmValue] =
  doAssert args.len == 0
  let tops = (vm.valueStackTop, vm.callStackTop, vm.labelStackTop, vm.localsTop)
  var trapped = false
  try:
    discard vm.invoke(moduleIndex, "trap", [])
  except WasmTrap:
    trapped = true
  doAssert trapped
  doAssert tops == (vm.valueStackTop, vm.callStackTop,
                    vm.labelStackTop, vm.localsTop)
  vm.invoke(moduleIndex, "nested", [])

moduleIndex = vm.instantiate(module, [("env", "call-guest",
  ExternalVal(kind: ekFunc, funcType: FuncType(results: @[vtI32]),
    hostFunc: callGuest))])
let output = vm.invoke(moduleIndex, "run", [wasmI32(17)])
doAssert output.len == 1 and output[0].i32 == 1052
doAssert vm.valueStack.len > initialValues and vm.locals.len > initialLocals
doAssert vm.valueStackTop == 0 and vm.callStackTop == 0 and
  vm.labelStackTop == 0 and vm.localsTop == 0
echo "WASM nested guest call restores arenas and trap state"
