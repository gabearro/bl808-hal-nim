## Build-time WASM runtime profile for the current BL808 core image.

type
  WasmRuntimeCore* = enum
    wasmCoreUnknown
    wasmCoreM0
    wasmCoreD0
    wasmCoreLP

  WasmRuntimeCapabilities* = object
    core*: WasmRuntimeCore
    compact*: bool
    flashBacked*: bool
    softwareF32*: bool
    supportsI32*: bool
    supportsF32*: bool
    supportsF64*: bool
    supportsImports*: bool

proc wasmRuntimeCapabilities*(): WasmRuntimeCapabilities =
  ## Describe the VM profile compiled into this image.
  ##
  ## Loaders can use this to decide whether to install a compact/no-FP-safe
  ## module for LP/enclave, or a fuller module for cores with more runtime.
  when defined(bl808m0):
    result.core = wasmCoreM0
  elif defined(bl808d0):
    result.core = wasmCoreD0
  elif defined(bl808lp):
    result.core = wasmCoreLP
  else:
    result.core = wasmCoreUnknown

  result.flashBacked = true
  result.supportsI32 = true
  when defined(bl808lp) or defined(bl808WasmCompact):
    result.compact = true
    result.softwareF32 = true
    result.supportsF32 = true
    result.supportsF64 = false
    result.supportsImports = false
  else:
    result.compact = false
    result.softwareF32 = false
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
