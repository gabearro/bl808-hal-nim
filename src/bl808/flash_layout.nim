## Central flash-layout contract for XIP consumers.
##
## Keep board flash offsets and per-core XIP aliases in one place so the WASM
## store, enclave partition, and core-specific flash readers do not duplicate
## address math.
##
## Ox64 flash map (16 MB, physical offsets). The first three rows are what
## `tools/hw_validate.py` writes; nothing in the repository writes the rest
## except the owners named here.
##
## ::
##   0x00_0000   64 KB  boot2, partition tables at 0xE000 / 0xF000
##   0x01_0000  960 KB  M0 firmware; the LP image, when there is one, is
##                      stored inside it at LpRuntimeFlashOffset
##   0x10_0000    1 MB  D0 image (Ox64D0BootOffset)
##   0x20_0000  4.5 MB  unassigned
##   0x68_0000  512 KB  application data (AppDataFlashOffset)
##   0x70_0000    1 MB  WASM repository (wasm_store)
##   0x80_0000    8 MB  LittleFS (FlashFsFlashOffset, kernel/flashblk)

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

  AppDataFlashOffset* = 0x68_0000'u32
    ## Application data: raw sectors an application lays out itself. Use
    ## `flashEraseSector`, `flashProgramPage`/`flashWrite` and `flashReadRaw`
    ## with offsets in `AppDataFlashOffset ..< AppDataFlashEnd`.
  AppDataFlashLen* = 0x08_0000'u32
  AppDataFlashEnd* = AppDataFlashOffset + AppDataFlashLen

  FlashFsFlashOffset* = Ox64MainImageOffset.uint32
    ## LittleFS partition: everything above the WASM repository.
  FlashFsFlashLen* = Ox64FlashSize.uint32 - FlashFsFlashOffset

  McuXipAliasBase* = FlashXipBase
  D0XipAliasBase* = FlashXipBase
  D0FlashRemapAliasBase* = FlashRemapBase
  LpXipAliasBase* = FlashXipBase

static:
  doAssert LpRuntimeFlashOffset >= Ox64LPBootOffset.uint32
  doAssert LpRuntimeFlashOffset < Ox64D0BootOffset.uint32
  doAssert LpRuntimeFlashOffset mod 0x10000 == 0
  # Application data sits between the images the harness flashes (the D0
  # linker profile ends at 0x20_0000) and the WASM repository.
  doAssert AppDataFlashOffset >= Ox64D0BootOffset.uint32 + 0x10_0000'u32
  doAssert AppDataFlashEnd <= WasmRepositoryFlashOffset
  doAssert AppDataFlashOffset mod 0x10000 == 0 and AppDataFlashLen mod 0x10000 == 0
  doAssert WasmRepositoryFlashEnd <= FlashFsFlashOffset
  doAssert FlashFsFlashOffset + FlashFsFlashLen == Ox64FlashSize.uint32

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

proc appDataRawFlashSpan*(): FlashXipSpan {.inline.} =
  ## Raw serial-flash offset span of the application-data partition.
  FlashXipSpan(
    base: AppDataFlashOffset,
    len: AppDataFlashLen,
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
