## Shared OS storage bootstrap for SD/FatFs-backed services.
##
## The WASM repository, VM swap, and file-backed mappings should all use the
## same mounted SD context so bus-mode negotiation happens once and status is
## observable from the OS management plane.

import ./kernel/fatfs
import ./kernel/sdblk
import ./sdh

type
  OsStorageStatus* = enum
    osStorageOk
    osStorageMountFailed
    osStorageHighSpeedFailed

  OsStorageState* = object
    initialized*: bool
    mounted*: bool
    tuned*: bool
    status*: OsStorageStatus
    mountError*: FResult
    highSpeedError*: SdhError
    health*: SdHealth

const
  OsStorageHighSpeedDiv* {.intdefine.} = 16'u32

when defined(bl808AllcoreWasmHttp):
  {.pragma: osStorageMem,
    codegenDecl: "$# $# __attribute__((section(\".psrambss\"), aligned(16), used))".}
else:
  {.pragma: osStorageMem.}

var
  osSdFs {.osStorageMem.}: SdFs
  osStorageState {.osStorageMem.}: OsStorageState

proc osStorageFs*(): var SdFs =
  osSdFs

proc osStorageRefreshHealth*() =
  osStorageState.health = sdSnapshotHealth()
  osStorageState.mounted = osSdFs.mounted

proc osStorageInit*(requireHighSpeed = false): OsStorageStatus =
  ## Mount the existing SD filesystem and tune the SD bus for OS services.
  ##
  ## This never formats the card. If high-speed negotiation fails, storage stays
  ## mounted unless the caller explicitly requires high-speed.
  if osStorageState.initialized and osSdFs.mounted:
    osStorageRefreshHealth()
    return osStorageState.status

  osStorageState.initialized = true
  osStorageState.tuned = false
  osStorageState.mountError = frOk
  osStorageState.highSpeedError = sdhOk

  let mountErr = osSdFs.mount()
  if mountErr != frOk:
    osStorageState.status = osStorageMountFailed
    osStorageState.mountError = mountErr
    osStorageRefreshHealth()
    return osStorageState.status

  discard sdEnable4BitBus()
  let hsErr = sdEnableHighSpeed(OsStorageHighSpeedDiv)
  osStorageState.highSpeedError = hsErr
  if hsErr == sdhOk:
    osStorageState.tuned = true
    osStorageState.status = osStorageOk
  elif requireHighSpeed:
    osStorageState.status = osStorageHighSpeedFailed
  else:
    osStorageState.status = osStorageOk

  osStorageRefreshHealth()
  osStorageState.status

proc osStorageStatus*(): OsStorageState =
  osStorageRefreshHealth()
  osStorageState

proc osStorageMounted*(): bool =
  osSdFs.mounted

proc osStorageReady*(): bool =
  osStorageInit() == osStorageOk and osSdFs.mounted
