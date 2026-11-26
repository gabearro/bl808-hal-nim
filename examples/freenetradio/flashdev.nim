## The flash store behind `presets.nim` and `settings.nim`: three operations
## on the 512 KB region laid out in `board.nim`, as callbacks so the logic
## above runs on a RAM fake in host tests.
##
## Offsets are relative to the start of the store. `eraseSector` takes a
## sector-aligned offset; `program` takes a page-aligned offset and at most
## one page, can only clear bits, and checks what it wrote.

import ./board

type
  FlashStatus* = enum
    fsOk, fsWriteFailed, fsVerifyFailed

  FlashDev* = object
    ctx*: pointer
    read*: proc(ctx: pointer; offset: uint32; buf: var openArray[byte]) {.nimcall.}
    eraseSector*: proc(ctx: pointer; offset: uint32): bool {.nimcall.}
    program*: proc(ctx: pointer; offset: uint32; data: openArray[byte]): FlashStatus {.nimcall.}

const
  FlashBusy* = "Flash busy"
  FlashWriteFailed* = "Flash write failed"
  FlashVerifyFailed* = "Flash verify failed"

func ready*(dev: FlashDev): bool {.inline.} =
  dev.read != nil and dev.eraseSector != nil and dev.program != nil

func sectorOffset*(sector: int): uint32 {.inline.} =
  uint32(sector * FlashSector)

proc writePage*(dev: FlashDev; offset: uint32; data: openArray[byte];
                erase: bool): string =
  ## Program one page at `offset`, erasing its sector first if `erase`.
  ## Returns "" or upstream's message for what went wrong.
  if not dev.ready: return FlashBusy
  if erase and not dev.eraseSector(dev.ctx, offset and not uint32(FlashSector - 1)):
    return FlashWriteFailed
  case dev.program(dev.ctx, offset, data)
  of fsOk: ""
  of fsWriteFailed: FlashWriteFailed
  of fsVerifyFailed: FlashVerifyFailed

when defined(bl808m0):
  import bl808/flash

  # Everything goes through the flash controller directly (from RAM, with
  # interrupts off for a page at a time), not the XIP window: a read through
  # the window right after a write can be stale.

  proc hwRead(ctx: pointer; offset: uint32; buf: var openArray[byte]) {.nimcall.} =
    flashReadRaw(StoreOffset.uint32 + offset, buf)

  proc hwErase(ctx: pointer; offset: uint32): bool {.nimcall.} =
    flashEraseSector(StoreOffset.uint32 + offset) == flashOk

  proc hwProgram(ctx: pointer; offset: uint32; data: openArray[byte]): FlashStatus {.nimcall.} =
    if flashProgramPage(StoreOffset.uint32 + offset, data) != flashOk:
      fsWriteFailed
    elif not flashRawMatches(StoreOffset.uint32 + offset, data):
      fsVerifyFailed
    else:
      fsOk

  proc hardwareFlash*(): FlashDev =
    FlashDev(ctx: nil, read: hwRead, eraseSector: hwErase, program: hwProgram)
