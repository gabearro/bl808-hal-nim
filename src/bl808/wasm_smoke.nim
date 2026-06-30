## Shared BL808 WebAssembly VM smoke test.
##
## This intentionally uses the low-level interpreter API and an embedded,
## integer-only module so it can run without a filesystem, WASI, or JIT support.

when defined(bl808lp) or defined(bl808WasmCompact):
  import cps/wasm/[flash_image, runtime_int]
  when defined(bl808lp) and defined(bl808WasmTrace):
    import mmio
else:
  import cps/wasm/[binary, runtime, types, validate]

const
  WasmSmokeOk* = 0x57534D00'u32
  WasmSmokeDecodeFailed* = 0x57534D01'u32
  WasmSmokeValidateFailed* = 0x57534D02'u32
  WasmSmokeInstantiateFailed* = 0x57534D03'u32
  WasmSmokeInvokeFailed* = 0x57534D04'u32
  WasmSmokeBadResult* = 0x57534D05'u32
  WasmSmokeFpBadResult* = 0x57534D06'u32
  WasmSmokeMemoryBadResult* = 0x57534D07'u32
  WasmSmokeInvokeAddFailed* = 0x57534D08'u32
  WasmSmokeInvokeF32AddFailed* = 0x57534D09'u32
  WasmSmokeInvokeF32MulFailed* = 0x57534D0A'u32
  WasmSmokeInvokeMemI32Failed* = 0x57534D0B'u32
  WasmSmokeInvokeMemF32Failed* = 0x57534D0C'u32
  WasmSmokeInvokeI32OpsFailed* = 0x57534D0D'u32
  WasmSmokeI32OpsBadResult* = 0x57534D0E'u32
  WasmSmokeInvokeCallFailed* = 0x57534D0F'u32
  WasmSmokeCallBadResult* = 0x57534D10'u32
  WasmSmokeInvokeIfFailed* = 0x57534D11'u32
  WasmSmokeIfBadResult* = 0x57534D12'u32
  WasmSmokeInvokeLoopFailed* = 0x57534D13'u32
  WasmSmokeLoopBadResult* = 0x57534D14'u32
  WasmSmokeStageAddr* = 0x40002E84'u

  AddModule = [
    byte 0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x07, 0x01, 0x60, 0x02, 0x7F, 0x7F, 0x01, 0x7F,
    0x03, 0x02, 0x01, 0x00,
    0x07, 0x07, 0x01, 0x03, 0x61, 0x64, 0x64, 0x00, 0x00,
    0x0A, 0x09, 0x01, 0x07, 0x00, 0x20, 0x00, 0x20, 0x01, 0x6A, 0x0B
  ]

  F32OpsBitsModule = [
    byte 0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7F,
    0x03, 0x03, 0x02, 0x00, 0x00,
    0x07, 0x16, 0x02,
    0x08, 0x66, 0x61, 0x64, 0x64, 0x62, 0x69, 0x74, 0x73, 0x00, 0x00,
    0x07, 0x66, 0x6D, 0x75, 0x6C, 0x63, 0x76, 0x74, 0x00, 0x01,
    0x0A, 0x1D, 0x02,
    0x0E, 0x00, 0x43, 0x00, 0x00, 0xC0, 0x3F, 0x43, 0x00, 0x00, 0x10, 0x40,
    0x92, 0xBC, 0x0B,
    0x0C, 0x00, 0x41, 0x7D, 0xB2, 0x43, 0x00, 0x00, 0x00, 0xC0, 0x94, 0xBC, 0x0B
  ]

  MemoryOpsModule = [
    byte 0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7F,
    0x03, 0x03, 0x02, 0x00, 0x00,
    0x05, 0x03, 0x01, 0x00, 0x01,
    0x07, 0x13, 0x02,
    0x06, 0x6D, 0x65, 0x6D, 0x69, 0x33, 0x32, 0x00, 0x00,
    0x06, 0x6D, 0x65, 0x6D, 0x66, 0x33, 0x32, 0x00, 0x01,
    0x0A, 0x2C, 0x02,
    0x17, 0x00, 0x41, 0x10, 0x28, 0x02, 0x00, 0x41, 0x01, 0x6A,
    0x41, 0x14, 0x41, 0x07, 0x36, 0x02, 0x00, 0x41, 0x14, 0x28, 0x02, 0x00,
    0x6A, 0x0B,
    0x12, 0x00, 0x41, 0x20, 0x43, 0x00, 0x00, 0xB0, 0x40, 0x38, 0x02, 0x00,
    0x41, 0x20, 0x2A, 0x02, 0x00, 0xBC, 0x0B,
    0x0B, 0x0A, 0x01, 0x00, 0x41, 0x10, 0x0B, 0x04, 0x29, 0x00, 0x00, 0x00
  ]

  I32OpsModule = [
    byte 0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00, 0x01, 0x05, 0x01, 0x60,
    0x00, 0x01, 0x7F, 0x03, 0x02, 0x01, 0x00, 0x07, 0x0A, 0x01, 0x06, 0x69,
    0x33, 0x32, 0x6F, 0x70, 0x73, 0x00, 0x00, 0x0A, 0x9D, 0x01, 0x01, 0x9A,
    0x01, 0x00, 0x41, 0x00, 0x45, 0x41, 0x07, 0x41, 0x07, 0x46, 0x6A, 0x41,
    0x07, 0x41, 0x08, 0x47, 0x6A, 0x41, 0x7F, 0x41, 0x01, 0x48, 0x6A, 0x41,
    0x01, 0x41, 0x7F, 0x49, 0x6A, 0x41, 0x02, 0x41, 0x7F, 0x4A, 0x6A, 0x41,
    0x7F, 0x41, 0x02, 0x4B, 0x6A, 0x41, 0x7F, 0x41, 0x7F, 0x4C, 0x6A, 0x41,
    0x7F, 0x41, 0x7F, 0x4F, 0x6A, 0x41, 0x79, 0x41, 0x02, 0x6D, 0x41, 0x7D,
    0x46, 0x6A, 0x41, 0x07, 0x41, 0x03, 0x6E, 0x41, 0x02, 0x46, 0x6A, 0x41,
    0x79, 0x41, 0x02, 0x6F, 0x41, 0x7F, 0x46, 0x6A, 0x41, 0x07, 0x41, 0x03,
    0x70, 0x41, 0x01, 0x46, 0x6A, 0x41, 0x80, 0x80, 0x02, 0x67, 0x41, 0x10,
    0x46, 0x6A, 0x41, 0x10, 0x68, 0x41, 0x04, 0x46, 0x6A, 0x41, 0xF0, 0x01,
    0x69, 0x41, 0x04, 0x46, 0x6A, 0x41, 0x12, 0x41, 0x08, 0x77, 0x41, 0x80,
    0x24, 0x46, 0x6A, 0x41, 0x80, 0x24, 0x41, 0x08, 0x78, 0x41, 0x12, 0x46,
    0x6A, 0x41, 0xFF, 0x01, 0xC0, 0x41, 0x7F, 0x46, 0x6A, 0x41, 0x81, 0x80,
    0x02, 0xC1, 0x41, 0x81, 0x80, 0xFE, 0xFF, 0x0F, 0x46, 0x6A, 0x0B
  ]

  DirectCallModule = [
    byte 0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00, 0x01, 0x0B, 0x02, 0x60,
    0x00, 0x01, 0x7F, 0x60, 0x02, 0x7F, 0x7F, 0x01, 0x7F, 0x03, 0x03, 0x02,
    0x00, 0x01, 0x07, 0x0A, 0x01, 0x06, 0x63, 0x61, 0x6C, 0x6C, 0x65, 0x72,
    0x00, 0x00, 0x0A, 0x15, 0x02, 0x0B, 0x00, 0x41, 0x01, 0x41, 0x14, 0x41,
    0x16, 0x10, 0x01, 0x6A, 0x0B, 0x07, 0x00, 0x20, 0x00, 0x20, 0x01, 0x6A,
    0x0B
  ]

  IfElseModule = [
    byte 0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00, 0x01, 0x06, 0x01, 0x60,
    0x01, 0x7F, 0x01, 0x7F, 0x03, 0x03, 0x02, 0x00, 0x00, 0x07, 0x13, 0x02,
    0x06, 0x63, 0x68, 0x6F, 0x6F, 0x73, 0x65, 0x00, 0x00, 0x06, 0x6E, 0x6F,
    0x65, 0x6C, 0x73, 0x65, 0x00, 0x01, 0x0A, 0x22, 0x02, 0x0C, 0x00, 0x20,
    0x00, 0x04, 0x7F, 0x41, 0x07, 0x05, 0x41, 0x0B, 0x0B, 0x0B, 0x13, 0x01,
    0x01, 0x7F, 0x41, 0x03, 0x21, 0x01, 0x20, 0x00, 0x04, 0x40, 0x41, 0x04,
    0x21, 0x01, 0x0B, 0x20, 0x01, 0x0B
  ]

  LoopModule = [
    byte 0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00, 0x01, 0x06, 0x01, 0x60,
    0x01, 0x7F, 0x01, 0x7F, 0x03, 0x02, 0x01, 0x00, 0x07, 0x09, 0x01, 0x05,
    0x73, 0x75, 0x6D, 0x74, 0x6F, 0x00, 0x00, 0x0A, 0x27, 0x01, 0x25, 0x01,
    0x02, 0x7F, 0x41, 0x00, 0x21, 0x01, 0x02, 0x40, 0x03, 0x40, 0x20, 0x00,
    0x45, 0x0D, 0x01, 0x20, 0x01, 0x20, 0x00, 0x6A, 0x21, 0x01, 0x20, 0x00,
    0x41, 0x01, 0x6B, 0x21, 0x00, 0x0C, 0x00, 0x0B, 0x0B, 0x20, 0x01, 0x0B
  ]

proc wasmSmokeStage(code: uint32) {.inline.} =
  when defined(bl808lp) and defined(bl808WasmTrace):
    regWrite(WasmSmokeStageAddr, code)
  else:
    discard code

when defined(bl808lp) or defined(bl808WasmCompact):
  proc loadFlash(data: openArray[byte], module: var FlashWasmModule): uint32 =
    wasmSmokeStage(0x57530F10'u32)
    try:
      module = parseFlashWasmModule(data)
    except CatchableError:
      return WasmSmokeDecodeFailed
    WasmSmokeOk
else:
  proc loadAndValidate(data: openArray[byte], module: var WasmModule): uint32 =
    wasmSmokeStage(0x57530D10'u32)
    try:
      module = decodeModule(data)
    except CatchableError:
      return WasmSmokeDecodeFailed

    wasmSmokeStage(0x57530D20'u32)
    try:
      validateModule(module)
    except CatchableError:
      return WasmSmokeValidateFailed

    wasmSmokeStage(0x57530D30'u32)
    WasmSmokeOk

proc runWasmSmoke*(): uint32 =
  wasmSmokeStage(0x57530100'u32)

  when defined(bl808lp) or defined(bl808WasmCompact):
    var module: FlashWasmModule
    var status = loadFlash(AddModule, module)
    if status != WasmSmokeOk:
      return status

    wasmSmokeStage(0x57530110'u32)
    var vm = initIntWasmVM()
    var moduleIdx: int
    try:
      moduleIdx = vm.instantiateFlashIntOnly(module)
    except CatchableError:
      return WasmSmokeInstantiateFailed

    wasmSmokeStage(0x57530120'u32)
    var value: int32
    try:
      value = vm.invokeI32(moduleIdx, "add", [19'i32, 23'i32])
    except CatchableError:
      return WasmSmokeInvokeAddFailed

    if value != 42'i32:
      return WasmSmokeBadResult

    wasmSmokeStage(0x57530200'u32)
    var fpModule: FlashWasmModule
    status = loadFlash(F32OpsBitsModule, fpModule)
    if status != WasmSmokeOk:
      return status

    wasmSmokeStage(0x57530210'u32)
    var fpVm = initIntWasmVM()
    var fpModuleIdx: int
    try:
      fpModuleIdx = fpVm.instantiateFlashIntOnly(fpModule)
    except CatchableError:
      return WasmSmokeInstantiateFailed

    wasmSmokeStage(0x57530220'u32)
    var fpBits: int32
    try:
      fpBits = fpVm.invokeI32(fpModuleIdx, "faddbits", [])
    except CatchableError:
      return WasmSmokeInvokeF32AddFailed

    if cast[uint32](fpBits) != 0x4070_0000'u32:
      return WasmSmokeFpBadResult

    wasmSmokeStage(0x57530230'u32)
    try:
      fpBits = fpVm.invokeI32(fpModuleIdx, "fmulcvt", [])
    except CatchableError:
      return WasmSmokeInvokeF32MulFailed

    if cast[uint32](fpBits) != 0x40C0_0000'u32:
      return WasmSmokeFpBadResult

    wasmSmokeStage(0x57530300'u32)
    var memModule: FlashWasmModule
    status = loadFlash(MemoryOpsModule, memModule)
    if status != WasmSmokeOk:
      return status

    wasmSmokeStage(0x57530310'u32)
    var memVm = initIntWasmVM()
    var memModuleIdx: int
    try:
      memModuleIdx = memVm.instantiateFlashIntOnly(memModule)
    except CatchableError:
      return WasmSmokeInstantiateFailed

    wasmSmokeStage(0x57530320'u32)
    var memValue: int32
    try:
      memValue = memVm.invokeI32(memModuleIdx, "memi32", [])
    except CatchableError:
      return WasmSmokeInvokeMemI32Failed

    if memValue != 49'i32:
      return WasmSmokeMemoryBadResult

    wasmSmokeStage(0x57530330'u32)
    try:
      memValue = memVm.invokeI32(memModuleIdx, "memf32", [])
    except CatchableError:
      return WasmSmokeInvokeMemF32Failed

    if cast[uint32](memValue) != 0x40B0_0000'u32:
      return WasmSmokeMemoryBadResult

    wasmSmokeStage(0x57530400'u32)
    var i32OpsModule: FlashWasmModule
    status = loadFlash(I32OpsModule, i32OpsModule)
    if status != WasmSmokeOk:
      return status

    wasmSmokeStage(0x57530410'u32)
    var i32OpsVm = initIntWasmVM()
    var i32OpsModuleIdx: int
    try:
      i32OpsModuleIdx = i32OpsVm.instantiateFlashIntOnly(i32OpsModule)
    except CatchableError:
      return WasmSmokeInstantiateFailed

    wasmSmokeStage(0x57530420'u32)
    var i32OpsValue: int32
    try:
      i32OpsValue = i32OpsVm.invokeI32(i32OpsModuleIdx, "i32ops", [])
    except CatchableError:
      return WasmSmokeInvokeI32OpsFailed

    if i32OpsValue != 20'i32:
      return WasmSmokeI32OpsBadResult

    wasmSmokeStage(0x57530500'u32)
    var callModule: FlashWasmModule
    status = loadFlash(DirectCallModule, callModule)
    if status != WasmSmokeOk:
      return status

    wasmSmokeStage(0x57530510'u32)
    var callVm = initIntWasmVM()
    var callModuleIdx: int
    try:
      callModuleIdx = callVm.instantiateFlashIntOnly(callModule)
    except CatchableError:
      return WasmSmokeInstantiateFailed

    wasmSmokeStage(0x57530520'u32)
    var callValue: int32
    try:
      callValue = callVm.invokeI32(callModuleIdx, "caller", [])
    except CatchableError:
      return WasmSmokeInvokeCallFailed

    if callValue != 43'i32:
      return WasmSmokeCallBadResult

    wasmSmokeStage(0x57530600'u32)
    var ifModule: FlashWasmModule
    status = loadFlash(IfElseModule, ifModule)
    if status != WasmSmokeOk:
      return status

    wasmSmokeStage(0x57530610'u32)
    var ifVm = initIntWasmVM()
    var ifModuleIdx: int
    try:
      ifModuleIdx = ifVm.instantiateFlashIntOnly(ifModule)
    except CatchableError:
      return WasmSmokeInstantiateFailed

    wasmSmokeStage(0x57530620'u32)
    try:
      if ifVm.invokeI32(ifModuleIdx, "choose", [1'i32]) != 7'i32:
        return WasmSmokeIfBadResult
      if ifVm.invokeI32(ifModuleIdx, "choose", [0'i32]) != 11'i32:
        return WasmSmokeIfBadResult
      if ifVm.invokeI32(ifModuleIdx, "noelse", [1'i32]) != 4'i32:
        return WasmSmokeIfBadResult
      if ifVm.invokeI32(ifModuleIdx, "noelse", [0'i32]) != 3'i32:
        return WasmSmokeIfBadResult
    except CatchableError:
      return WasmSmokeInvokeIfFailed

    wasmSmokeStage(0x57530700'u32)
    var loopModule: FlashWasmModule
    status = loadFlash(LoopModule, loopModule)
    if status != WasmSmokeOk:
      return status

    wasmSmokeStage(0x57530710'u32)
    var loopVm = initIntWasmVM()
    var loopModuleIdx: int
    try:
      loopModuleIdx = loopVm.instantiateFlashIntOnly(loopModule)
    except CatchableError:
      return WasmSmokeInstantiateFailed

    wasmSmokeStage(0x57530720'u32)
    try:
      if loopVm.invokeI32(loopModuleIdx, "sumto", [5'i32]) != 15'i32:
        return WasmSmokeLoopBadResult
      if loopVm.invokeI32(loopModuleIdx, "sumto", [0'i32]) != 0'i32:
        return WasmSmokeLoopBadResult
    except CatchableError:
      return WasmSmokeInvokeLoopFailed
    wasmSmokeStage(0x5753FFFF'u32)
    return WasmSmokeOk
  else:
    var module: WasmModule
    var status = loadAndValidate(AddModule, module)
    if status != WasmSmokeOk:
      return status

    var vm = initWasmVM()
    var moduleIdx: int
    try:
      moduleIdx = vm.instantiate(module, [])
    except CatchableError:
      return WasmSmokeInstantiateFailed

    var values: seq[WasmValue]
    try:
      values = vm.invoke(moduleIdx, "add", [wasmI32(19), wasmI32(23)])
    except CatchableError:
      return WasmSmokeInvokeFailed

    if values.len != 1 or values[0].kind != wvkI32 or values[0].i32 != 42:
      return WasmSmokeBadResult

    var fpModule: WasmModule
    status = loadAndValidate(F32OpsBitsModule, fpModule)
    if status != WasmSmokeOk:
      return status

    var fpModuleIdx: int
    try:
      fpModuleIdx = vm.instantiate(fpModule, [])
    except CatchableError:
      return WasmSmokeInstantiateFailed

    var fpValues: seq[WasmValue]
    try:
      fpValues = vm.invoke(fpModuleIdx, "faddbits", [])
    except CatchableError:
      return WasmSmokeInvokeFailed

    if fpValues.len != 1 or fpValues[0].kind != wvkI32 or
        cast[uint32](fpValues[0].i32) != 0x4070_0000'u32:
      return WasmSmokeFpBadResult

    try:
      fpValues = vm.invoke(fpModuleIdx, "fmulcvt", [])
    except CatchableError:
      return WasmSmokeInvokeFailed

    if fpValues.len != 1 or fpValues[0].kind != wvkI32 or
        cast[uint32](fpValues[0].i32) != 0x40C0_0000'u32:
      return WasmSmokeFpBadResult

    var memModule: WasmModule
    status = loadAndValidate(MemoryOpsModule, memModule)
    if status != WasmSmokeOk:
      return status

    var memModuleIdx: int
    try:
      memModuleIdx = vm.instantiate(memModule, [])
    except CatchableError:
      return WasmSmokeInstantiateFailed

    var memValues: seq[WasmValue]
    try:
      memValues = vm.invoke(memModuleIdx, "memi32", [])
    except CatchableError:
      return WasmSmokeInvokeFailed

    if memValues.len != 1 or memValues[0].kind != wvkI32 or memValues[0].i32 != 49:
      return WasmSmokeMemoryBadResult

    try:
      memValues = vm.invoke(memModuleIdx, "memf32", [])
    except CatchableError:
      return WasmSmokeInvokeFailed

    if memValues.len != 1 or memValues[0].kind != wvkI32 or
        cast[uint32](memValues[0].i32) != 0x40B0_0000'u32:
      return WasmSmokeMemoryBadResult

    WasmSmokeOk
