## Flash block device for LittleFS.
##
## Bridges LittleFS's 4 block device callbacks to the flash.nim HAL.
## The filesystem partition starts at FlashFsOffset (8MB into flash),
## using 4KB sectors as LittleFS blocks.

import ../flash

const
  FlashFsOffset* = 0x800000'u32   ## Filesystem starts 8MB into flash
  FlashFsSize* = 0x800000'u32     ## 8MB partition
  FlashFsBlockSize* = 4096'u32    ## 4KB erase sectors
  FlashFsBlockCount* = FlashFsSize div FlashFsBlockSize  ## 2048 blocks
  FlashFsReadSize* = 256'u32      ## Read granularity
  FlashFsProgSize* = 256'u32      ## Program granularity (page size)

proc blockAddr(blk, off: uint32): uint32 {.inline.} =
  FlashFsOffset + blk * FlashFsBlockSize + off

# =============================================================================
# LittleFS block device callbacks (cdecl, called from C via function pointers)
# =============================================================================

type
  LfsConfig* {.importc: "struct lfs_config", header: "lfs.h".} = object

proc blkRead*(cfg: ptr LfsConfig, blk, off: uint32,
              buf: pointer, size: uint32): cint {.cdecl, exportc.} =
  ## Read `size` bytes from block `blk` at offset `off` into `buf`.
  ## Reads via XIP (memory-mapped flash). The QEMU SF controller keeps
  ## the XIP region in sync with its internal flash buffer on write/erase.
  let flashAddr = blockAddr(blk, off)
  let dst = cast[ptr UncheckedArray[uint8]](buf)
  flashReadXipBuffer(flashAddr, dst.toOpenArray(0, size.int - 1))
  0

proc blkProg*(cfg: ptr LfsConfig, blk, off: uint32,
              buf: pointer, size: uint32): cint {.cdecl, exportc.} =
  ## Program `size` bytes from `buf` into block `blk` at offset `off`.
  let base = blockAddr(blk, off)
  let src = cast[ptr UncheckedArray[uint8]](buf)
  let err = flashWrite(base, src.toOpenArray(0, size.int - 1))
  if err != flashOk: -5 else: 0

proc blkErase*(cfg: ptr LfsConfig, blk: uint32): cint {.cdecl, exportc.} =
  ## Erase block `blk` (one 4KB sector).
  let eraseAddr = FlashFsOffset + blk * FlashFsBlockSize
  let err = flashEraseSector(eraseAddr)
  if err != flashOk: -5 else: 0  # LFS_ERR_IO

proc blkSync*(cfg: ptr LfsConfig): cint {.cdecl, exportc.} =
  ## Sync — no-op since the SF controller completes synchronously.
  0
