## M0-owned file staging for portable full-VM snapshots.
## Use a dedicated preallocated swap file, exclusively, outside hard slots.

when not defined(bl808m0) or not defined(wasmStorageMigration):
  {.error: "SD snapshot staging requires M0 and -d:wasmStorageMigration".}

import cps/wasm/runtime
import ./kernel/[fatfs, sd_swap_file]

type WasmSdMigration* = object
  fs: ptr SdFs
  file: ptr SdSwapFile
  storage: WasmPortableStorage

proc readSnapshot(ctx: pointer, offset: int, buf: pointer, count: int): bool =
  let owner = cast[ptr WasmSdMigration](ctx)
  let bytes = cast[ptr UncheckedArray[byte]](buf)
  sdSwapReadRange(owner.fs[], owner.file[], offset.uint64,
    bytes.toOpenArray(0, count - 1)) == sdSwapOk

proc writeSnapshot(ctx: pointer, offset: int, buf: pointer, count: int): bool =
  let owner = cast[ptr WasmSdMigration](ctx)
  let bytes = cast[ptr UncheckedArray[byte]](buf)
  sdSwapWriteRange(owner.fs[], owner.file[], offset.uint64,
    bytes.toOpenArray(0, count - 1)) == sdSwapOk

proc sealSnapshot(ctx: pointer): bool =
  let owner = cast[ptr WasmSdMigration](ctx)
  sdSwapSync(owner.fs[], owner.file[]) == sdSwapOk

proc sdMigrationStaging*(owner: var WasmSdMigration, fs: ptr SdFs,
                         file: ptr SdSwapFile): WasmPortableStaging =
  ## Keep the owner and open file at fixed addresses until the capture or
  ## restore finishes. Never install this file as a guest page backing.
  if fs == nil or file == nil or not file[].open or file[].slots == 0: return
  owner = WasmSdMigration(fs: fs, file: file,
    storage: WasmPortableStorage(ctx: addr owner, read: readSnapshot,
      write: writeSnapshot, seal: sealSnapshot))
  let capacity = min(file[].slots.uint64 * SdSwapPageBytes.uint64,
    WasmPortableStagedMaxBytes.uint64)
  WasmPortableStaging(storage: addr owner.storage, len: capacity.int)
