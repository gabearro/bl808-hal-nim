## Shared flash-slot WASM smoke helpers.
##
## M0 installs a tiny `.wasm` program into a flash-backed WASM slot. Other
## cores load the same slot and execute it through the compact flash-backed VM.

import ./memmap
import ./flash
import ./cache
import ./core
import ./mmio
import ./wasm_manager
import ./wasm_store

const
  WasmSlotSmokeSlot* = 2'u32
  WasmSlotMaxArgs* = 8
  WasmSlotMaxExportNameLen* = 32
  WasmSlotRequestMagic* = 0x5752_4551'u32 # "WREQ"
  WasmSlotD0RequestAddr* = XramBase + 0x3E40'u
  WasmSlotD0StatusAddr* = XramBase + 0x3EA0'u
  WasmSlotD0CapsAddr* = XramBase + 0x3EA4'u
  WasmSlotLpRequestAddr* = 0x40002E40'u
  WasmSlotLpStatusAddr* = 0x40002EA0'u
  WasmSlotLpCapsAddr* = 0x40002EA4'u

  WasmSlotSmokeOk* = 0x57534C00'u32
  WasmSlotInstallFailed* = 0x57534C01'u32
  WasmSlotLoadFailed* = 0x57534C02'u32
  WasmSlotInstantiateFailed* = 0x57534C03'u32
  WasmSlotInvokeFailed* = 0x57534C04'u32
  WasmSlotBadResult* = 0x57534C05'u32
  WasmSlotInstallStoreErrorBase* = 0x57534D00'u32
  WasmSlotInstallBadSlot* = 0x57534D10'u32
  WasmSlotInstallEraseFailed* = 0x57534D11'u32
  WasmSlotInstallPayloadWriteFailed* = 0x57534D12'u32
  WasmSlotInstallHeaderBuildFailed* = 0x57534D13'u32
  WasmSlotInstallHeaderWriteFailed* = 0x57534D14'u32
  WasmSlotInstallPayloadVerifyFailed* = 0x57534D15'u32
  WasmSlotInstallHeaderVerifyFailed* = 0x57534D16'u32
  WasmSlotInstallPayloadXipVerifyFailed* = 0x57534D17'u32
  WasmSlotBadRequest* = 0x57534E00'u32

  WasmSlotAddModule* = [
    byte 0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x07, 0x01, 0x60, 0x02, 0x7F, 0x7F, 0x01,
    0x7F, 0x03, 0x02, 0x01, 0x00, 0x07, 0x07, 0x01,
    0x03, 0x61, 0x64, 0x64, 0x00, 0x00, 0x0A, 0x09,
    0x01, 0x07, 0x00, 0x20, 0x00, 0x20, 0x01, 0x6A,
    0x0B
  ]

proc xipMatches(offset: uint32, data: openArray[byte]): bool =
  for i in 0 ..< data.len:
    if flashReadXipByte(offset + i.uint32) != data[i]:
      return false
  true

proc installWasmSlotSmoke*(slot = WasmSlotSmokeSlot): uint32 =
  initWasmProgramStore()
  let slotInfo = wasmProgramSlot(slot)
  if not slotInfo.valid:
    return WasmSlotInstallBadSlot
  let eraseErr = eraseWasmProgramSlot(slot)
  if eraseErr != wasmProgramOk:
    return WasmSlotInstallEraseFailed or eraseErr.ord.uint32
  if flashWrite(slotInfo.flashOffset + WasmProgramHeaderLen, WasmSlotAddModule) != flashOk:
    return WasmSlotInstallPayloadWriteFailed
  var headerBytes: array[WasmProgramHeaderLen.int, byte]
  let headerErr = writeWasmProgramHeader(
    cast[ptr UncheckedArray[byte]](addr headerBytes[0]),
    WasmProgramHeaderLen,
    WasmSlotAddModule.len.uint32,
    generation = 1'u32,
    checksum = wasmPayloadCrc32(WasmSlotAddModule),
  )
  if headerErr != wasmProgramOk:
    return WasmSlotInstallHeaderBuildFailed or headerErr.ord.uint32
  if flashWrite(slotInfo.flashOffset, headerBytes) != flashOk:
    return WasmSlotInstallHeaderWriteFailed
  discard l1cInvalidateAll()
  if not flashRawMatches(slotInfo.flashOffset + WasmProgramHeaderLen, WasmSlotAddModule):
    return WasmSlotInstallPayloadVerifyFailed
  if not flashRawMatches(slotInfo.flashOffset, headerBytes):
    return WasmSlotInstallHeaderVerifyFailed
  discard l1cInvalidateAll()
  if not xipMatches(slotInfo.flashOffset + WasmProgramHeaderLen, WasmSlotAddModule):
    return WasmSlotInstallPayloadXipVerifyFailed
  WasmSlotSmokeOk

proc runWasmSlotSmoke*(slot = WasmSlotSmokeSlot): uint32 =
  discard l1cInvalidateAll()
  var handle: WasmProgramHandle
  let openErr = handle.openWasmProgramSlot(slot)
  if openErr != wasmManagerOk:
    return WasmSlotLoadFailed

  let runResult = handle.invokeI32("add", [19'i32, 23'i32])
  if runResult.status != wasmManagerOk:
    handle.close()
    return WasmSlotInvokeFailed

  handle.close()
  if runResult.value == 42'i32: WasmSlotSmokeOk else: WasmSlotBadResult

proc requestNameByteAddr(base: uint, index: int): uint =
  base + 48'u + index.uint

proc requestArgAddr(base: uint, index: int): uint =
  base + 12'u + (index.uint * 4'u)

proc writeWasmSlotInvokeRequest*(base: uint, slot: uint32, exportName: string,
                                 args: openArray[int32],
                                 expected: int32) =
  ## Write a compact cross-core WASM invocation request into shared memory.
  regWrite(base + 0'u, WasmSlotRequestMagic)
  regWrite(base + 4'u, slot)
  regWrite(base + 8'u, args.len.uint32)
  for i in 0 ..< WasmSlotMaxArgs:
    let value = if i < args.len: cast[uint32](args[i]) else: 0'u32
    regWrite(requestArgAddr(base, i), value)
  regWrite(base + 44'u, cast[uint32](expected))
  let nameLen =
    if exportName.len > WasmSlotMaxExportNameLen: WasmSlotMaxExportNameLen
    else: exportName.len
  regWrite(base + 40'u, nameLen.uint32)
  let namePtr = cast[ptr UncheckedArray[uint8]](requestNameByteAddr(base, 0))
  for i in 0 ..< WasmSlotMaxExportNameLen:
    namePtr[i] = if i < nameLen: exportName[i].uint8 else: 0'u8
  dcacheFlushAll()
  fenceIo()

proc runWasmSlotRequest*(base: uint): uint32 =
  ## Execute the shared-memory invocation request written by M0.
  discard l1cInvalidateAll()
  dcacheInvalidateAll()
  core.fence()
  if regRead(base + 0'u) != WasmSlotRequestMagic:
    return WasmSlotBadRequest
  let slot = regRead(base + 4'u)
  let argc = regRead(base + 8'u).int
  let nameLen = regRead(base + 40'u).int
  let expected = cast[int32](regRead(base + 44'u))
  if argc < 0 or argc > WasmSlotMaxArgs or
      nameLen <= 0 or nameLen > WasmSlotMaxExportNameLen:
    return WasmSlotBadRequest

  var args: array[WasmSlotMaxArgs, int32]
  for i in 0 ..< argc:
    args[i] = cast[int32](regRead(requestArgAddr(base, i)))

  var exportName = newString(nameLen)
  let namePtr = cast[ptr UncheckedArray[uint8]](requestNameByteAddr(base, 0))
  for i in 0 ..< nameLen:
    exportName[i] = char(namePtr[i])

  var program: LoadedWasmProgram
  let loadErr = loadWasmProgramSlot(slot, program)
  if loadErr != wasmProgramOk:
    return WasmSlotLoadFailed + (loadErr.ord.uint32 shl 8)
  program.unload()

  var handle: WasmProgramHandle
  let openErr = handle.openWasmProgramSlot(slot)
  if openErr != wasmManagerOk:
    return WasmSlotLoadFailed + (openErr.ord.uint32 shl 16)
  let runResult =
    if argc == 0:
      handle.invokeI32(exportName, [])
    else:
      handle.invokeI32(exportName, toOpenArray(args, 0, argc - 1))
  handle.close()
  if runResult.status != wasmManagerOk:
    return WasmSlotInvokeFailed
  if runResult.value == expected: WasmSlotSmokeOk else: WasmSlotBadResult
