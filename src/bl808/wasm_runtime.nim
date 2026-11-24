## Build-time WASM runtime profile for the current BL808 core image.

type
  WasmRuntimeCore* = enum
    wasmCoreUnknown
    wasmCoreM0
    wasmCoreD0
    wasmCoreLP

  WasmRuntimeIsa* = enum
    wasmIsaUnknown
    wasmIsaRv32ImAfC
    wasmIsaRv64ImAfDc
    wasmIsaRv32EmC

  WasmRuntimeAbi* = enum
    wasmAbiUnknown
    wasmAbiIlp32f
    wasmAbiLp64d
    wasmAbiIlp32e

  WasmRuntimeCapabilities* = object
    core*: WasmRuntimeCore
    isa*: WasmRuntimeIsa
    abi*: WasmRuntimeAbi
    compact*: bool
    fullInterpreter*: bool
    flashBacked*: bool
    nativeCodeXip*: bool
    softwareF32*: bool
    softwareF64*: bool
    supportsI32*: bool
    supportsI64*: bool
    supportsF32*: bool
    supportsF64*: bool
    supportsImports*: bool
    verifiedIsaExtensions*: uint32
    executionBackends*: uint32
    hostInterfaceMask*: uint32
    writableRamBytes*: uint32
    nativeStackBytes*: uint32

const
  WasmLpNativeStackBytes* {.intdefine.} = 4096
  WasmD0NativeStackBytes* {.intdefine.} = 8192
  WasmIsaExtM* = 1'u32 shl 0
  WasmIsaExtA* = 1'u32 shl 1
  WasmIsaExtF* = 1'u32 shl 2
  WasmIsaExtD* = 1'u32 shl 3
  WasmIsaExtC* = 1'u32 shl 4
  WasmIsaExtZicsr* = 1'u32 shl 5
  WasmBackendInterpreter* = 1'u32 shl 0

proc wasmRuntimeCapabilities*(): WasmRuntimeCapabilities =
  ## Describe the VM profile compiled into this image.
  ##
  ## Hardware ISA bits reflect the build flags, not speculative T-Head ops.
  ## Service availability is separate from the VM's ability to bind imports.
  when defined(bl808m0):
    result.core = wasmCoreM0
    result.isa = wasmIsaRv32ImAfC
    result.abi = wasmAbiIlp32f
    result.verifiedIsaExtensions = WasmIsaExtM or WasmIsaExtA or
      WasmIsaExtF or WasmIsaExtC
    result.nativeCodeXip = not defined(bl808jtagram)
    when not defined(bl808jtagram):
      result.writableRamBytes = 64 * 1024
      result.nativeStackBytes = 8 * 1024
  elif defined(bl808d0):
    result.core = wasmCoreD0
    result.isa = wasmIsaRv64ImAfDc
    result.abi = wasmAbiLp64d
    result.verifiedIsaExtensions = WasmIsaExtM or WasmIsaExtA or
      WasmIsaExtF or WasmIsaExtD or WasmIsaExtC
    result.nativeCodeXip = defined(bl808D0Xip)
    when not defined(bl808jtagram):
      result.writableRamBytes = 512 * 1024
      result.nativeStackBytes = WasmD0NativeStackBytes.uint32
  elif defined(bl808lp):
    result.core = wasmCoreLP
    result.isa = wasmIsaRv32EmC
    result.abi = wasmAbiIlp32e
    result.verifiedIsaExtensions = WasmIsaExtM or WasmIsaExtC or WasmIsaExtZicsr
    result.nativeCodeXip = not defined(bl808jtagram)
    result.writableRamBytes = 16 * 1024
    when defined(bl808WasmFull) and not defined(bl808jtagram):
      result.nativeStackBytes = WasmLpNativeStackBytes.uint32
    else:
      result.nativeStackBytes = 2 * 1024
  else:
    result.core = wasmCoreUnknown

  result.flashBacked = true
  result.executionBackends = WasmBackendInterpreter
  result.supportsI32 = true
  when defined(bl808WasmCompact) or (defined(bl808lp) and not defined(bl808WasmFull)):
    result.compact = true
    result.softwareF32 = true
    result.supportsF32 = true
    result.supportsF64 = false
    result.supportsImports = false
  else:
    result.compact = false
    result.fullInterpreter = true
    result.supportsI64 = true
    result.softwareF32 = defined(bl808lp)
    result.softwareF64 = defined(bl808lp)
    result.supportsF32 = true
    result.supportsF64 = true
    result.supportsImports = true

proc wasmRuntimeCapabilityWord*(caps: WasmRuntimeCapabilities): uint32 =
  ## Compact shared-memory signature for hardware smoke tests.
  result = caps.core.ord.uint32 shl 24
  if caps.compact: result = result or (1'u32 shl 0)
  if caps.flashBacked: result = result or (1'u32 shl 1)
  if caps.softwareF32: result = result or (1'u32 shl 2)
  if caps.supportsI32: result = result or (1'u32 shl 3)
  if caps.supportsF32: result = result or (1'u32 shl 4)
  if caps.supportsF64: result = result or (1'u32 shl 5)
  if caps.supportsImports: result = result or (1'u32 shl 6)

proc wasmRuntimeCapabilityWord*(): uint32 =
  wasmRuntimeCapabilityWord(wasmRuntimeCapabilities())
