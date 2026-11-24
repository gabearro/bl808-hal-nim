import std/os
import cps/wasm/[binary, runtime, types, validate]

let bytes = readFile(paramStr(1))
let module = decodeModule(bytes.toOpenArrayByte(0, bytes.len - 1))
validateModule(module)
var vm = initWasmVM()
let idx = vm.instantiate(module, [])
for name in ["run", "ret"]:
  let values = vm.invoke(idx, name, [])
  doAssert values.len == 129
  for i, value in values:
    doAssert value.kind == wvkI32 and value.i32 == i.int32
echo "full WASM multi-value branch and return PASS: 129 ordered results"
