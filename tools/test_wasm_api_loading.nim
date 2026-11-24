import cps/wasm/[api,types,binary,runtime]

proc sample(value: byte): seq[byte] =
  @[0'u8,97,115,109,1,0,0,0,1,5,1,96,0,1,127,3,2,1,0,
    7,7,1,3,114,117,110,0,0,10,6,1,4,0,65,value,11]

proc main() =
  let engine = newWasmEngine(jit = false)
  defer: engine.destroy()
  let first = engine.loadValidatedBytes(sample(7))
  let second = engine.loadValidatedBytes(sample(42))
  doAssert first.callI32("run") == 7
  doAssert second.callI32("run") == 42
  let third = engine.loadBytes(sample(11))
  doAssert third.callI32("run") == 11
  proc globalModule(value: byte): seq[byte] =
    @[0'u8,97,115,109,1,0,0,0,6,6,1,127,1,65,value,11,7,5,1,1,103,3,0]
  let left = engine.loadValidatedBytes(globalModule(13))
  let right = engine.loadValidatedBytes(globalModule(17))
  doAssert left.getGlobal("g").i32 == 13 and right.getGlobal("g").i32 == 17
  right.setGlobal("g",wasmI32(23))
  doAssert left.getGlobal("g").i32 == 13 and right.getGlobal("g").i32 == 23
  var vm = initWasmVM()
  var source = decodeModule(sample(19),optimize = false)
  let sourceId = vm.instantiate(source,[])
  source.codes[0].code.code[0].imm1 = 55
  doAssert vm.invoke(sourceId,"run",[])[0].i32 == 19,"instantiation must own its code"
  for value in 0..31:
    discard vm.instantiate(decodeModule(sample(byte(value))),[])
  for value in 0..31:
    doAssert vm.invoke(value+1,"run",[])[0].i32 == int32(value),"temporary module code expired"
  var calling = decodeModule(@[0'u8,97,115,109,1,0,0,0,1,5,1,96,0,1,127,3,3,2,0,0,
    7,7,1,3,114,117,110,0,1,10,11,2,4,0,65,7,11,4,0,16,0,11],optimize = false)
  let callingId = vm.instantiate(calling,[])
  doAssert calling.codes[1].code.code[0].imm1 == 0,"call patching changed caller-owned code"
  calling.codes[0].code.code[0].imm1 = 57
  doAssert vm.invoke(callingId,"run",[])[0].i32 == 7
  var calls = 0
  engine.addHostFunc("h","g",FuncType(),proc(args: openArray[WasmValue]): seq[WasmValue] =
    inc calls
    @[])
  let malformed = @[0'u8,97,115,109,1,0,0,0,1,4,1,96,0,0,
    2,7,1,1,104,1,103,0,0,8,1,1] # start function 1 does not exist
  var rejected = false
  try: discard engine.loadValidatedBytes(malformed)
  except CatchableError: rejected = true
  doAssert rejected and calls == 0
  echo "WASM API loading PASS: store-resolved exports and validation before host execution"

main()
