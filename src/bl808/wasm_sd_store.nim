## SD-card backed WASM program installer.
##
## SD/exFAT is used as durable block storage. Executable WASM programs are
## staged through caller-provided RAM, validated, then committed to the
## flash-backed WASM store so the compact VM can execute from XIP flash.

import ./kernel/fatfs
import ./flash
import ./wasm_manager
import ./wasm_store
import cps/wasm/flash_image

when defined(bl808kernel):
  import ./kernel/cps

when defined(bl808m0) or defined(bl808d0) or defined(bl808lp):
  import ./cache

type
  WasmSdInstallStatus* = enum
    wasmSdInstallOk
    wasmSdMountError
    wasmSdOpenError
    wasmSdReadError
    wasmSdCloseError
    wasmSdTooLarge
    wasmSdInvalidWasm
    wasmSdNoSlot
    wasmSdStoreError
    wasmSdBadName
    wasmSdDirError
    wasmSdWriteError
    wasmSdSyncError
    wasmSdDeleteError
    wasmSdRenameError

  WasmSdInstallResult* = object
    status*: WasmSdInstallStatus
    fsError*: FResult
    managerError*: WasmProgramManagerError
    storeError*: WasmProgramError
    bytes*: uint32
    slot*: int32

  WasmSdListResult* = object
    status*: WasmSdInstallStatus
    fsError*: FResult
    count*: uint32

const
  WasmSdProgramDir* = "0:/programs"
  WasmSdProgramNameMax* = 64
  WasmSdIoChunkBytes* = 512

proc okResult(bytes: uint32): WasmSdInstallResult =
  WasmSdInstallResult(status: wasmSdInstallOk, bytes: bytes)

proc fsResult(status: WasmSdInstallStatus, err: FResult): WasmSdInstallResult =
  WasmSdInstallResult(status: status, fsError: err)

proc storeResult(err: WasmProgramError, bytes: uint32): WasmSdInstallResult =
  WasmSdInstallResult(status: wasmSdStoreError, storeError: err, bytes: bytes)

proc managerResult(r: WasmProgramInstallResult,
                   bytes: uint32): WasmSdInstallResult =
  if r.status == wasmManagerNoSlot:
    return WasmSdInstallResult(status: wasmSdNoSlot, managerError: r.status,
                               bytes: bytes, slot: r.slot)
  if r.storeError == wasmProgramParseFailed:
    return WasmSdInstallResult(status: wasmSdInvalidWasm,
                               managerError: r.status,
                               storeError: r.storeError,
                               bytes: bytes,
                               slot: r.slot)
  WasmSdInstallResult(status: wasmSdStoreError,
                      managerError: r.status,
                      storeError: r.storeError,
                      bytes: bytes,
                      slot: r.slot)

proc validWasmSdName*(name: string): bool =
  ## Accept one filename within the managed SD program directory.
  if name.len == 0 or name.len > WasmSdProgramNameMax:
    return false
  for ch in name:
    if ch == '/' or ch == '\\' or ch == ':' or ch == '\0':
      return false
  name.len > 5 and name[name.len - 5 ..< name.len] == ".wasm"

proc validWasmSdManifestName*(name: string): bool =
  ## Accept one sidecar metadata filename within the managed SD program directory.
  if name.len == 0 or name.len > WasmSdProgramNameMax:
    return false
  for ch in name:
    if ch == '/' or ch == '\\' or ch == ':' or ch == '\0':
      return false
  name.len > 9 and name[name.len - 9 ..< name.len] == ".manifest"

proc wasmSdProgramPath*(name: string): string =
  WasmSdProgramDir & "/" & name

proc wasmSdTempPath(name: string): string =
  WasmSdProgramDir & "/." & name & ".tmp"

proc ensureWasmSdProgramDir*(fs: var SdFs): FResult =
  ## Mount the SD card and ensure the managed WASM directory exists.
  if not fs.mounted:
    result = fs.mount()
    if result != frOk:
      return
  result = fs.mkdir(WasmSdProgramDir)
  if result == frExist:
    result = frOk

when defined(bl808kernel):
  proc fSize(fp: ptr Fil): uint64 {.importc: "f_size", header: "ff.h".}

  proc fatReadInto(f: ptr Fil, dst: pointer, len: int): int =
    var got: cuint
    let err = f_read(f, dst, len.cuint, addr got)
    if err != frOk: -1 else: got.int

  proc fatWriteFrom(f: ptr Fil, src: pointer, len: int): int =
    var wrote: cuint
    let err = f_write(f, src, len.cuint, addr wrote)
    if err != frOk: -1 else: wrote.int

  proc ensureWasmSdProgramDirAsync*(fs: ptr SdFs): CpsFuture[FResult] {.cps.} =
    ## Cooperative variant of `ensureWasmSdProgramDir`.
    var err = frOk
    if not fs[].mounted:
      err = f_mount(addr fs[].fatfs, "0:", 1)
      fs[].mounted = err == frOk
      await yieldNow()
      if err != frOk:
        return err
    err = f_mkdir(WasmSdProgramDir.cstring)
    await yieldNow()
    if err == frExist:
      err = frOk
    return err

proc validateWasmBytes(wasm: openArray[byte]): bool =
  if wasm.len == 0:
    return false
  try:
    discard parseFlashWasmModule(
      initWasmImageView(cast[ptr UncheckedArray[byte]](unsafeAddr wasm[0]), wasm.len)
    )
    true
  except CatchableError:
    false

proc validateWasmBytesPtr(wasm: ptr UncheckedArray[byte], wasmLen: int): bool =
  if wasm.isNil or wasmLen == 0:
    return false
  try:
    discard parseFlashWasmModule(initWasmImageView(wasm, wasmLen))
    true
  except CatchableError:
    false

proc syncWasmSdStoreXip() {.inline.} =
  when defined(bl808m0) or defined(bl808d0) or defined(bl808lp):
    discard l1cInvalidateAll()

proc writeAllToOpenFile(fs: var SdFs, f: var Fil,
                        data: openArray[byte]): WasmSdInstallResult =
  var offset = 0
  while offset < data.len:
    let written = fs.write(f, data.toOpenArray(offset, data.high))
    if written <= 0:
      discard fs.close(f)
      return fsResult(wasmSdWriteError, frDiskErr)
    offset += written
  let syncErr = fs.sync(f)
  if syncErr != frOk:
    discard fs.close(f)
    return fsResult(wasmSdSyncError, syncErr)
  let closeErr = fs.close(f)
  if closeErr != frOk:
    return fsResult(wasmSdCloseError, closeErr)
  okResult(data.len.uint32)

when defined(bl808kernel):
  proc writeAllToOpenFileAsync(fs: ptr SdFs, f: ptr Fil,
                               data: ptr UncheckedArray[byte],
                               dataLen: int):
      CpsFuture[WasmSdInstallResult] {.cps.} =
    var offset = 0
    while offset < dataLen:
      let chunkLen = min(dataLen - offset, WasmSdIoChunkBytes)
      let written = fatWriteFrom(f, addr data[offset], chunkLen)
      if written <= 0:
        discard f_close(f)
        return fsResult(wasmSdWriteError, frDiskErr)
      offset += written
      await yieldNow()
    let syncErr = f_sync(f)
    await yieldNow()
    if syncErr != frOk:
      discard f_close(f)
      return fsResult(wasmSdSyncError, syncErr)
    let closeErr = f_close(f)
    await yieldNow()
    if closeErr != frOk:
      return fsResult(wasmSdCloseError, closeErr)
    return okResult(dataLen.uint32)

proc saveWasmFileAtomic(fs: var SdFs, name: string,
                        data: openArray[byte]): WasmSdInstallResult =
  ## Commit through a temp file so interrupted writes do not leave a partial
  ## final repository entry. FAT/exFAT cannot atomically replace an existing
  ## file in one operation, so the final remove+rename is the narrow commit
  ## window; readers either see the old file, no file briefly, or the new file.
  let finalPath = wasmSdProgramPath(name)
  let tempPath = wasmSdTempPath(name)
  discard fs.remove(tempPath)

  var f: Fil
  let openErr = fs.open(f, tempPath, faWrite or faCreateAlways)
  if openErr != frOk:
    return fsResult(wasmSdOpenError, openErr)

  result = fs.writeAllToOpenFile(f, data)
  if result.status != wasmSdInstallOk:
    discard f_unlink(tempPath.cstring)
    return

  let removeErr = fs.remove(finalPath)
  if removeErr != frOk and removeErr != frNoFile:
    discard f_unlink(tempPath.cstring)
    return fsResult(wasmSdDeleteError, removeErr)
  let renameErr = fs.rename(tempPath, finalPath)
  if renameErr != frOk:
    discard f_unlink(tempPath.cstring)
    return fsResult(wasmSdRenameError, renameErr)
  result = okResult(data.len.uint32)

when defined(bl808kernel):
  proc saveWasmFileAtomicAsync(fs: ptr SdFs, name: string,
                               data: ptr UncheckedArray[byte],
                               dataLen: int):
      CpsFuture[WasmSdInstallResult] {.cps.} =
    ## Cooperative temp-file commit. The final unlink+rename commit window is
    ## intentionally small; large data transfer yields every 512 bytes.
    let finalPath = wasmSdProgramPath(name)
    let tempPath = wasmSdTempPath(name)
    discard f_unlink(tempPath.cstring)
    await yieldNow()

    var f: Fil
    let openErr = f_open(addr f, tempPath.cstring, faWrite or faCreateAlways)
    await yieldNow()
    if openErr != frOk:
      return fsResult(wasmSdOpenError, openErr)

    let writtenResult = await fs.writeAllToOpenFileAsync(addr f, data, dataLen)
    if writtenResult.status != wasmSdInstallOk:
      discard f_unlink(tempPath.cstring)
      await yieldNow()
      return writtenResult

    let removeErr = f_unlink(finalPath.cstring)
    await yieldNow()
    if removeErr != frOk and removeErr != frNoFile:
      discard f_unlink(tempPath.cstring)
      await yieldNow()
      return fsResult(wasmSdDeleteError, removeErr)
    let renameErr = f_rename(tempPath.cstring, finalPath.cstring)
    await yieldNow()
    if renameErr != frOk:
      discard f_unlink(tempPath.cstring)
      await yieldNow()
      return fsResult(wasmSdRenameError, renameErr)
    return okResult(dataLen.uint32)

proc saveWasmProgramToSd*(fs: var SdFs, name: string,
                          wasm: openArray[byte]): WasmSdInstallResult =
  ## Validate and persist a `.wasm` binary under 0:/programs.
  if not validWasmSdName(name):
    return WasmSdInstallResult(status: wasmSdBadName)
  if not validateWasmBytes(wasm):
    return WasmSdInstallResult(status: wasmSdInvalidWasm, bytes: wasm.len.uint32)

  let dirErr = fs.ensureWasmSdProgramDir()
  if dirErr != frOk:
    return fsResult(wasmSdDirError, dirErr)

  saveWasmFileAtomic(fs, name, wasm)

when defined(bl808kernel):
  proc saveWasmProgramToSdAsync*(fs: ptr SdFs, name: string,
                                 wasm: ptr UncheckedArray[byte],
                                 wasmLen: int):
      CpsFuture[WasmSdInstallResult] {.cps.} =
    if not validWasmSdName(name):
      return WasmSdInstallResult(status: wasmSdBadName)
    if not validateWasmBytesPtr(wasm, wasmLen):
      return WasmSdInstallResult(status: wasmSdInvalidWasm, bytes: wasmLen.uint32)
    await yieldNow()

    let dirErr = await fs.ensureWasmSdProgramDirAsync()
    if dirErr != frOk:
      return fsResult(wasmSdDirError, dirErr)

    await saveWasmFileAtomicAsync(fs, name, wasm, wasmLen)

proc saveWasmManifestToSd*(fs: var SdFs, name: string,
                           manifest: openArray[byte]): WasmSdInstallResult =
  ## Persist a line-oriented sidecar manifest next to `.wasm` binaries.
  if not validWasmSdManifestName(name):
    return WasmSdInstallResult(status: wasmSdBadName)
  if manifest.len == 0 or manifest.len > WasmSdProgramNameMax * 32:
    return WasmSdInstallResult(status: wasmSdTooLarge, bytes: manifest.len.uint32)

  let dirErr = fs.ensureWasmSdProgramDir()
  if dirErr != frOk:
    return fsResult(wasmSdDirError, dirErr)

  saveWasmFileAtomic(fs, name, manifest)

when defined(bl808kernel):
  proc saveWasmManifestToSdAsync*(fs: ptr SdFs, name: string,
                                  manifest: ptr UncheckedArray[byte],
                                  manifestLen: int):
      CpsFuture[WasmSdInstallResult] {.cps.} =
    if not validWasmSdManifestName(name):
      return WasmSdInstallResult(status: wasmSdBadName)
    if manifest.isNil or manifestLen == 0 or manifestLen > WasmSdProgramNameMax * 32:
      return WasmSdInstallResult(status: wasmSdTooLarge, bytes: manifestLen.uint32)

    let dirErr = await fs.ensureWasmSdProgramDirAsync()
    if dirErr != frOk:
      return fsResult(wasmSdDirError, dirErr)

    await saveWasmFileAtomicAsync(fs, name, manifest, manifestLen)

proc deleteWasmProgramFromSd*(fs: var SdFs,
                              name: string): WasmSdInstallResult =
  if not validWasmSdName(name):
    return WasmSdInstallResult(status: wasmSdBadName)
  let dirErr = fs.ensureWasmSdProgramDir()
  if dirErr != frOk:
    return fsResult(wasmSdDirError, dirErr)
  let err = fs.remove(wasmSdProgramPath(name))
  if err != frOk and err != frNoFile:
    return fsResult(wasmSdDeleteError, err)
  WasmSdInstallResult(status: wasmSdInstallOk)

proc deleteWasmManifestFromSd*(fs: var SdFs,
                               name: string): WasmSdInstallResult =
  if not validWasmSdManifestName(name):
    return WasmSdInstallResult(status: wasmSdBadName)
  let dirErr = fs.ensureWasmSdProgramDir()
  if dirErr != frOk:
    return fsResult(wasmSdDirError, dirErr)
  let err = fs.remove(wasmSdProgramPath(name))
  if err != frOk and err != frNoFile:
    return fsResult(wasmSdDeleteError, err)
  WasmSdInstallResult(status: wasmSdInstallOk)

proc listWasmProgramsOnSd*(fs: var SdFs,
                           outNames: var openArray[string]): WasmSdListResult =
  let dirErr = fs.ensureWasmSdProgramDir()
  if dirErr != frOk:
    return WasmSdListResult(status: wasmSdDirError, fsError: dirErr)
  let entries = fs.ls(WasmSdProgramDir)
  for name in entries:
    if validWasmSdName(name):
      if result.count < outNames.len.uint32:
        outNames[result.count.int] = name
      inc result.count
  result.status = wasmSdInstallOk

when defined(bl808kernel):
  proc listWasmProgramsOnSdAsync*(fs: ptr SdFs,
                                  outNames: ptr UncheckedArray[string],
                                  outCapacity: int):
      CpsFuture[WasmSdListResult] {.cps.} =
    let dirErr = await fs.ensureWasmSdProgramDirAsync()
    if dirErr != frOk:
      return WasmSdListResult(status: wasmSdDirError, fsError: dirErr)
    var dir: Dir
    let openErr = f_opendir(addr dir, WasmSdProgramDir.cstring)
    await yieldNow()
    if openErr != frOk:
      return WasmSdListResult(status: wasmSdDirError, fsError: openErr)
    var info: Filinfo
    var listed: WasmSdListResult
    while true:
      let readErr = f_readdir(addr dir, addr info)
      if readErr != frOk:
        discard f_closedir(addr dir)
        return WasmSdListResult(status: wasmSdDirError, fsError: readErr)
      if info.fname[0] == '\0':
        break
      let name = $cast[cstring](addr info.fname[0])
      if validWasmSdName(name):
        if not outNames.isNil and listed.count < outCapacity.uint32:
          outNames[listed.count.int] = name
        inc listed.count
      await yieldNow()
    discard f_closedir(addr dir)
    listed.status = wasmSdInstallOk
    return listed

proc listWasmManifestsOnSd*(fs: var SdFs,
                            outNames: var openArray[string]): WasmSdListResult =
  let dirErr = fs.ensureWasmSdProgramDir()
  if dirErr != frOk:
    return WasmSdListResult(status: wasmSdDirError, fsError: dirErr)
  let entries = fs.ls(WasmSdProgramDir)
  for name in entries:
    if validWasmSdManifestName(name):
      if result.count < outNames.len.uint32:
        outNames[result.count.int] = name
      inc result.count
  result.status = wasmSdInstallOk

when defined(bl808kernel):
  proc listWasmManifestsOnSdAsync*(fs: ptr SdFs,
                                   outNames: ptr UncheckedArray[string],
                                   outCapacity: int):
      CpsFuture[WasmSdListResult] {.cps.} =
    let dirErr = await fs.ensureWasmSdProgramDirAsync()
    if dirErr != frOk:
      return WasmSdListResult(status: wasmSdDirError, fsError: dirErr)
    var dir: Dir
    let openErr = f_opendir(addr dir, WasmSdProgramDir.cstring)
    await yieldNow()
    if openErr != frOk:
      return WasmSdListResult(status: wasmSdDirError, fsError: openErr)
    var info: Filinfo
    var listed: WasmSdListResult
    while true:
      let readErr = f_readdir(addr dir, addr info)
      if readErr != frOk:
        discard f_closedir(addr dir)
        return WasmSdListResult(status: wasmSdDirError, fsError: readErr)
      if info.fname[0] == '\0':
        break
      let name = $cast[cstring](addr info.fname[0])
      if validWasmSdManifestName(name):
        if not outNames.isNil and listed.count < outCapacity.uint32:
          outNames[listed.count.int] = name
        inc listed.count
      await yieldNow()
    discard f_closedir(addr dir)
    listed.status = wasmSdInstallOk
    return listed

proc readWasmFileIntoScratch*(fs: var SdFs, path: string,
                              scratch: var openArray[byte],
                              outLen: var uint32): WasmSdInstallResult =
  ## Read a whole WASM file into caller-owned scratch RAM.
  ##
  ## The scratch buffer must be large enough for the entire `.wasm`; the compact
  ## runtime still executes from flash after installation, so this buffer is only
  ## an upload/staging buffer.
  outLen = 0
  if not fs.mounted:
    let mountErr = fs.mount()
    if mountErr != frOk:
      return fsResult(wasmSdMountError, mountErr)

  var f: Fil
  let openErr = fs.open(f, path, faRead or faOpenExisting)
  if openErr != frOk:
    return fsResult(wasmSdOpenError, openErr)

  let fileSize = f.size()
  if fileSize == 0 or fileSize > scratch.len.uint64 or fileSize > uint32.high.uint64:
    discard fs.close(f)
    return WasmSdInstallResult(status: wasmSdTooLarge)

  let wanted = fileSize.uint32
  var offset = 0'u32
  while offset < wanted:
    let n = fs.read(f, scratch.toOpenArray(offset.int, wanted.int - 1))
    if n <= 0:
      discard fs.close(f)
      return fsResult(wasmSdReadError, frDiskErr)
    offset += n.uint32

  let closeErr = fs.close(f)
  if closeErr != frOk:
    return fsResult(wasmSdCloseError, closeErr)

  outLen = wanted
  okResult(wanted)

when defined(bl808kernel):
  proc readWasmFileIntoScratchAsync*(fs: ptr SdFs, path: string,
                                     scratch: ptr UncheckedArray[byte],
                                     scratchLen: int,
                                     outLen: ptr uint32):
      CpsFuture[WasmSdInstallResult] {.cps.} =
    if not outLen.isNil:
      outLen[] = 0
    if scratch.isNil or outLen.isNil:
      return WasmSdInstallResult(status: wasmSdTooLarge)
    if not fs[].mounted:
      let mountErr = f_mount(addr fs[].fatfs, "0:", 1)
      fs[].mounted = mountErr == frOk
      await yieldNow()
      if mountErr != frOk:
        return fsResult(wasmSdMountError, mountErr)

    var f: Fil
    let openErr = f_open(addr f, path.cstring, faRead or faOpenExisting)
    await yieldNow()
    if openErr != frOk:
      return fsResult(wasmSdOpenError, openErr)

    let fileSize = fSize(addr f)
    if fileSize == 0 or fileSize > scratchLen.uint64 or fileSize > uint32.high.uint64:
      discard f_close(addr f)
      await yieldNow()
      return WasmSdInstallResult(status: wasmSdTooLarge)

    let wanted = fileSize.uint32
    var offset = 0'u32
    while offset < wanted:
      let stop = min(wanted.int - 1, offset.int + WasmSdIoChunkBytes - 1)
      let n = fatReadInto(addr f, addr scratch[offset.int], stop - offset.int + 1)
      if n <= 0:
        discard f_close(addr f)
        await yieldNow()
        return fsResult(wasmSdReadError, frDiskErr)
      offset += n.uint32
      await yieldNow()

    let closeErr = f_close(addr f)
    await yieldNow()
    if closeErr != frOk:
      return fsResult(wasmSdCloseError, closeErr)

    outLen[] = wanted
    return okResult(wanted)

proc installWasmProgramFromSd*(fs: var SdFs, path: string, slot: uint32,
                               scratch: var openArray[byte],
                               generation = 1'u32,
                               flags = 0'u32): WasmSdInstallResult =
  ## Install one `.wasm` file from SD/exFAT into a flash-backed WASM slot.
  var imageLen: uint32
  result = readWasmFileIntoScratch(fs, path, scratch, imageLen)
  if result.status != wasmSdInstallOk:
    return

  if not validateWasmBytes(scratch.toOpenArray(0, imageLen.int - 1)):
    return WasmSdInstallResult(status: wasmSdInvalidWasm, bytes: imageLen)

  let install = installWasmProgram(
    slot,
    scratch.toOpenArray(0, imageLen.int - 1),
    generation = generation,
    flags = flags,
  )
  if install.status != wasmManagerOk:
    return managerResult(install, imageLen)

  result = okResult(imageLen)
  result.slot = slot.int32

proc installWasmProgramFromSdStreamed*(fs: var SdFs, path: string, slot: uint32,
                                       scratch: var openArray[byte],
                                       generation = 1'u32,
                                       flags = 0'u32): WasmSdInstallResult =
  ## Install one `.wasm` file from SD/exFAT into a flash-backed WASM slot without
  ## staging the whole file in RAM.
  if scratch.len == 0:
    return WasmSdInstallResult(status: wasmSdTooLarge, slot: slot.int32)
  if not fs.mounted:
    let mountErr = fs.mount()
    if mountErr != frOk:
      return fsResult(wasmSdMountError, mountErr)

  var f: Fil
  let openErr = fs.open(f, path, faRead or faOpenExisting)
  if openErr != frOk:
    return fsResult(wasmSdOpenError, openErr)

  let fileSize = f.size()
  if fileSize == 0 or fileSize > uint32.high.uint64:
    discard fs.close(f)
    return WasmSdInstallResult(status: wasmSdTooLarge, slot: slot.int32)
  let imageLen = fileSize.uint32

  if imageLen.int <= scratch.len:
    var offset = 0'u32
    while offset < imageLen:
      let n = fs.read(f, scratch.toOpenArray(offset.int, imageLen.int - 1))
      if n <= 0:
        discard fs.close(f)
        return fsResult(wasmSdReadError, frDiskErr)
      offset += n.uint32
    let closeErr = fs.close(f)
    if closeErr != frOk:
      return fsResult(wasmSdCloseError, closeErr)
    if not validateWasmBytes(scratch.toOpenArray(0, imageLen.int - 1)):
      return WasmSdInstallResult(status: wasmSdInvalidWasm,
                                 storeError: wasmProgramParseFailed,
                                 bytes: imageLen,
                                 slot: slot.int32)
    let install = installWasmProgram(
      slot,
      scratch.toOpenArray(0, imageLen.int - 1),
      generation = generation,
      flags = flags,
    )
    if install.status != wasmManagerOk:
      return managerResult(install, imageLen)
    result = okResult(imageLen)
    result.slot = slot.int32
    return

  let programSlot = wasmProgramSlot(slot)
  if not programSlot.valid:
    discard fs.close(f)
    return WasmSdInstallResult(status: wasmSdStoreError,
                               storeError: wasmProgramBadSlot,
                               bytes: imageLen,
                               slot: slot.int32)
  if imageLen > programSlot.slotPayloadCapacity:
    discard fs.close(f)
    return WasmSdInstallResult(status: wasmSdTooLarge,
                               bytes: imageLen,
                               slot: slot.int32)

  var err = eraseWasmProgramSlot(slot)
  if err != wasmProgramOk:
    discard fs.close(f)
    return storeResult(err, imageLen)

  var remaining = imageLen
  var offset = 0'u32
  var crc = wasmPayloadCrc32Init()
  while remaining > 0:
    let maxChunk = min(remaining.int, scratch.len)
    let n = fs.read(f, scratch.toOpenArray(0, maxChunk - 1))
    if n <= 0:
      discard eraseWasmProgramSlot(slot)
      discard fs.close(f)
      return fsResult(wasmSdReadError, frDiskErr)
    crc = wasmPayloadCrc32Update(crc, scratch.toOpenArray(0, n - 1))
    if flashWrite(programSlot.flashOffset + WasmProgramHeaderLen + offset,
                  scratch.toOpenArray(0, n - 1)) != flashOk:
      discard eraseWasmProgramSlot(slot)
      discard fs.close(f)
      return storeResult(wasmProgramFlashError, imageLen)
    if not flashRawMatches(programSlot.flashOffset + WasmProgramHeaderLen + offset,
                           scratch.toOpenArray(0, n - 1)):
      discard eraseWasmProgramSlot(slot)
      discard fs.close(f)
      return storeResult(wasmProgramVerifyFailed, imageLen)
    offset += n.uint32
    remaining -= n.uint32

  let closeErr = fs.close(f)
  if closeErr != frOk:
    return fsResult(wasmSdCloseError, closeErr)

  syncWasmSdStoreXip()
  try:
    discard parseFlashWasmModule(
      initWasmImageView(programSlot.xipPtr(WasmProgramHeaderLen), imageLen.int)
    )
  except CatchableError:
    discard eraseWasmProgramSlot(slot)
    return WasmSdInstallResult(status: wasmSdInvalidWasm,
                               storeError: wasmProgramParseFailed,
                               bytes: imageLen,
                               slot: slot.int32)

  var headerBytes: array[WasmProgramHeaderLen.int, byte]
  err = writeWasmProgramHeader(
    cast[ptr UncheckedArray[byte]](addr headerBytes[0]),
    WasmProgramHeaderLen,
    imageLen,
    generation,
    flags,
    checksum = wasmPayloadCrc32Finish(crc),
  )
  if err == wasmProgramParseFailed:
    return WasmSdInstallResult(status: wasmSdInvalidWasm,
                               storeError: err,
                               bytes: imageLen,
                               slot: slot.int32)
  if err != wasmProgramOk:
    return storeResult(err, imageLen)
  if flashWrite(programSlot.flashOffset, headerBytes) != flashOk:
    discard eraseWasmProgramSlot(slot)
    return storeResult(wasmProgramFlashError, imageLen)

  syncWasmSdStoreXip()
  var loaded: LoadedWasmProgram
  err = loadWasmProgramSlot(slot, loaded)
  loaded.unload()
  if err != wasmProgramOk:
    discard eraseWasmProgramSlot(slot)
    return storeResult(err, imageLen)

  result = okResult(imageLen)
  result.slot = slot.int32

when defined(bl808kernel):
  proc installWasmProgramFromSdStreamedAsync*(fs: ptr SdFs, path: string,
                                             slot: uint32,
                                             scratch: ptr UncheckedArray[byte],
                                             scratchLen: int,
                                             generation = 1'u32,
                                             flags = 0'u32):
      CpsFuture[WasmSdInstallResult] {.cps.} =
    if scratch.isNil or scratchLen == 0:
      return WasmSdInstallResult(status: wasmSdTooLarge, slot: slot.int32)
    if not fs[].mounted:
      let mountErr = f_mount(addr fs[].fatfs, "0:", 1)
      fs[].mounted = mountErr == frOk
      await yieldNow()
      if mountErr != frOk:
        return fsResult(wasmSdMountError, mountErr)

    var f: Fil
    let openErr = f_open(addr f, path.cstring, faRead or faOpenExisting)
    await yieldNow()
    if openErr != frOk:
      return fsResult(wasmSdOpenError, openErr)

    let fileSize = fSize(addr f)
    if fileSize == 0 or fileSize > uint32.high.uint64:
      discard f_close(addr f)
      await yieldNow()
      return WasmSdInstallResult(status: wasmSdTooLarge, slot: slot.int32)
    let imageLen = fileSize.uint32

    let programSlot = wasmProgramSlot(slot)
    if not programSlot.valid:
      discard f_close(addr f)
      await yieldNow()
      return WasmSdInstallResult(status: wasmSdStoreError,
                                 storeError: wasmProgramBadSlot,
                                 bytes: imageLen,
                                 slot: slot.int32)
    if imageLen > programSlot.slotPayloadCapacity:
      discard f_close(addr f)
      await yieldNow()
      return WasmSdInstallResult(status: wasmSdTooLarge,
                                 bytes: imageLen,
                                 slot: slot.int32)

    var err = eraseWasmProgramSlot(slot)
    await yieldNow()
    if err != wasmProgramOk:
      discard f_close(addr f)
      await yieldNow()
      return storeResult(err, imageLen)

    var remaining = imageLen
    var offset = 0'u32
    var crc = wasmPayloadCrc32Init()
    var ioChunk: array[WasmSdIoChunkBytes, byte]
    while remaining > 0:
      let maxChunk = min(remaining.int, ioChunk.len)
      let n = fatReadInto(addr f, addr ioChunk[0], maxChunk)
      if n <= 0:
        discard eraseWasmProgramSlot(slot)
        discard f_close(addr f)
        await yieldNow()
        return fsResult(wasmSdReadError, frDiskErr)
      crc = wasmPayloadCrc32Update(crc, ioChunk.toOpenArray(0, n - 1))
      if flashWrite(programSlot.flashOffset + WasmProgramHeaderLen + offset,
                    ioChunk.toOpenArray(0, n - 1)) != flashOk:
        discard eraseWasmProgramSlot(slot)
        discard f_close(addr f)
        await yieldNow()
        return storeResult(wasmProgramFlashError, imageLen)
      if not flashRawMatches(programSlot.flashOffset + WasmProgramHeaderLen + offset,
                             ioChunk.toOpenArray(0, n - 1)):
        discard eraseWasmProgramSlot(slot)
        discard f_close(addr f)
        await yieldNow()
        return storeResult(wasmProgramVerifyFailed, imageLen)
      offset += n.uint32
      remaining -= n.uint32
      await yieldNow()

    let closeErr = f_close(addr f)
    await yieldNow()
    if closeErr != frOk:
      return fsResult(wasmSdCloseError, closeErr)

    syncWasmSdStoreXip()
    await yieldNow()
    try:
      discard parseFlashWasmModule(
        initWasmImageView(programSlot.xipPtr(WasmProgramHeaderLen), imageLen.int)
      )
    except CatchableError:
      discard eraseWasmProgramSlot(slot)
      await yieldNow()
      return WasmSdInstallResult(status: wasmSdInvalidWasm,
                                 storeError: wasmProgramParseFailed,
                                 bytes: imageLen,
                                 slot: slot.int32)

    var headerBytes: array[WasmProgramHeaderLen.int, byte]
    err = writeWasmProgramHeader(
      cast[ptr UncheckedArray[byte]](addr headerBytes[0]),
      WasmProgramHeaderLen,
      imageLen,
      generation,
      flags,
      checksum = wasmPayloadCrc32Finish(crc),
    )
    if err == wasmProgramParseFailed:
      return WasmSdInstallResult(status: wasmSdInvalidWasm,
                                 storeError: err,
                                 bytes: imageLen,
                                 slot: slot.int32)
    if err != wasmProgramOk:
      return storeResult(err, imageLen)
    if flashWrite(programSlot.flashOffset, headerBytes) != flashOk:
      discard eraseWasmProgramSlot(slot)
      await yieldNow()
      return storeResult(wasmProgramFlashError, imageLen)

    syncWasmSdStoreXip()
    await yieldNow()
    var loaded: LoadedWasmProgram
    err = loadWasmProgramSlot(slot, loaded)
    loaded.unload()
    if err != wasmProgramOk:
      discard eraseWasmProgramSlot(slot)
      await yieldNow()
      return storeResult(err, imageLen)

    var installedResult = okResult(imageLen)
    installedResult.slot = slot.int32
    return installedResult

proc installWasmProgramFromSdAuto*(fs: var SdFs, path: string,
                                   outSlot: var uint32,
                                   scratch: var openArray[byte],
                                   startIndex = 0'u32,
                                   generation = 1'u32,
                                   flags = 0'u32): WasmSdInstallResult =
  ## Install one `.wasm` file from SD/exFAT into the first erased flash slot.
  var imageLen: uint32
  result = readWasmFileIntoScratch(fs, path, scratch, imageLen)
  if result.status != wasmSdInstallOk:
    return

  if not validateWasmBytes(scratch.toOpenArray(0, imageLen.int - 1)):
    return WasmSdInstallResult(status: wasmSdInvalidWasm, bytes: imageLen)

  let install = installWasmProgramAuto(
    scratch.toOpenArray(0, imageLen.int - 1),
    outSlot,
    startIndex = startIndex,
    generation = generation,
    flags = flags,
  )
  if install.status != wasmManagerOk:
    return managerResult(install, imageLen)

  result = okResult(imageLen)
  result.slot = outSlot.int32

proc installNamedWasmProgramFromSd*(fs: var SdFs, name: string, slot: uint32,
                                    scratch: var openArray[byte],
                                    generation = 1'u32,
                                    flags = 0'u32): WasmSdInstallResult =
  if not validWasmSdName(name):
    return WasmSdInstallResult(status: wasmSdBadName)
  installWasmProgramFromSdStreamed(
    fs,
    wasmSdProgramPath(name),
    slot,
    scratch,
    generation = generation,
    flags = flags,
  )

when defined(bl808kernel):
  proc installNamedWasmProgramFromSdAsync*(fs: ptr SdFs, name: string,
                                          slot: uint32,
                                          scratch: ptr UncheckedArray[byte],
                                          scratchLen: int,
                                          generation = 1'u32,
                                          flags = 0'u32):
      CpsFuture[WasmSdInstallResult] {.cps.} =
    if not validWasmSdName(name):
      return WasmSdInstallResult(status: wasmSdBadName)
    await installWasmProgramFromSdStreamedAsync(
      fs,
      wasmSdProgramPath(name),
      slot,
      scratch,
      scratchLen,
      generation = generation,
      flags = flags,
    )

proc installNamedWasmProgramFromSdAuto*(fs: var SdFs, name: string,
                                        outSlot: var uint32,
                                        scratch: var openArray[byte],
                                        startIndex = 0'u32,
                                        generation = 1'u32,
                                        flags = 0'u32): WasmSdInstallResult =
  if not validWasmSdName(name):
    return WasmSdInstallResult(status: wasmSdBadName)
  installWasmProgramFromSdAuto(
    fs,
    wasmSdProgramPath(name),
    outSlot,
    scratch,
    startIndex = startIndex,
    generation = generation,
    flags = flags,
  )
