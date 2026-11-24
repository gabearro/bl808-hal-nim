## Central flash-layout contract for XIP consumers.
##
## Keep board flash offsets and per-core XIP aliases in one place so the WASM
## store, enclave partition, and core-specific flash readers do not duplicate
## address math.

import ./memmap

type
  FlashXipSpan* = object
    base*: uint
    len*: uint32

const
  WasmRepositoryFlashOffset* = Ox64WasmStoreOffset.uint32
  WasmRepositoryFlashLen* = Ox64WasmStoreSize.uint32
  WasmRepositoryFlashEnd* = (Ox64WasmStoreOffset + Ox64WasmStoreSize).uint32
  LpRuntimeFlashOffset* {.intdefine.} = 0x0C_0000'u32
  LpRuntimeFlashLen* = (Ox64D0BootOffset - LpRuntimeFlashOffset.uint).uint32

  McuXipAliasBase* = FlashXipBase
  D0XipAliasBase* = FlashXipBase
  D0FlashRemapAliasBase* = FlashRemapBase
  LpXipAliasBase* = FlashXipBase

static:
  doAssert LpRuntimeFlashOffset >= Ox64LPBootOffset.uint32
  doAssert LpRuntimeFlashOffset < Ox64D0BootOffset.uint32
  doAssert LpRuntimeFlashOffset mod 0x10000 == 0

proc flashXipBaseForCore*(): uint {.inline.} =
  when defined(bl808d0) and defined(bl808D0Xip):
    D0FlashRemapAliasBase
  elif defined(bl808d0):
    D0XipAliasBase
  elif defined(bl808lp):
    LpXipAliasBase
  else:
    McuXipAliasBase

proc flashXipAddrForCore*(offset: uint32, mappedOffset = 0'u32): uint {.inline.} =
  ## Translate a physical flash offset to the current core's XIP address.
  if offset >= mappedOffset:
    flashXipBaseForCore() + uint(offset - mappedOffset)
  else:
    flashXipBaseForCore() + uint(offset)

proc lpRuntimeFlashSpan*(): FlashXipSpan {.inline.} =
  ## Physical storage span for the LP image.
  FlashXipSpan(
    base: LpRuntimeFlashOffset,
    len: LpRuntimeFlashLen,
  )

proc lpRuntimeMappedFlashSpan*(): FlashXipSpan {.inline.} =
  ## Logical LP boot span as seen by SF/XIP policy before the boot2 image-offset
  ## remap is applied. The LP image executes at XIP 0x58080000 independently
  ## of the profile's sector-aligned physical storage offset.
  FlashXipSpan(
    base: Ox64LPBootOffset.uint32,
    len: (Ox64D0BootOffset - Ox64LPBootOffset).uint32,
  )

proc lpRuntimeXipSpan*(): FlashXipSpan {.inline.} =
  ## XIP boot span for the LP image.
  FlashXipSpan(
    base: FlashXipBase + Ox64LPBootOffset,
    len: LpRuntimeFlashLen,
  )

proc wasmRepositoryRawFlashSpan*(): FlashXipSpan {.inline.} =
  ## Raw serial-flash offset span for the shared WASM repository.
  FlashXipSpan(
    base: Ox64WasmStoreOffset,
    len: WasmRepositoryFlashLen,
  )

proc peerMcuXipFlashSpan*(): FlashXipSpan {.inline.} =
  ## MCU XIP alias span for the shared WASM repository.
  FlashXipSpan(
    base: McuXipAliasBase + Ox64WasmStoreOffset,
    len: WasmRepositoryFlashLen,
  )

proc peerD0WasmFlashSpan*(): FlashXipSpan {.inline.} =
  ## D0 XIP-execution alias for the shared WASM repository. RAM-loaded D0 uses
  ## the MCU XIP alias through flashXipAddrForCore.
  FlashXipSpan(
    base: D0FlashRemapAliasBase + Ox64WasmStoreOffset,
    len: WasmRepositoryFlashLen,
  )
