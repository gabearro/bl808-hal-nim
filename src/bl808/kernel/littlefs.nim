## LittleFS integration for the BL808 kernel.
##
## Provides a thin Nim wrapper over the LittleFS C library for
## persistent storage on SPI NOR flash:
##
##   var fs: FlashFs
##   fs.init()
##   var f: LfsFile
##   fs.open(f, "test.txt", LFS_O_WRONLY or LFS_O_CREAT)
##   fs.write(f, [0x48'u8, 0x69])  # "Hi"
##   fs.close(f)

import ./flashblk

# =============================================================================
# Compile LittleFS
# =============================================================================

{.passC: "-I vendor/littlefs".}
{.passC: "-DLFS_NO_DEBUG -DLFS_NO_WARN -DLFS_NO_ERROR -DLFS_NO_ASSERT".}
{.compile: "vendor/littlefs/lfs.c".}
{.compile: "vendor/littlefs/lfs_util.c".}

# =============================================================================
# C types
# =============================================================================

type
  Lfs* {.importc: "lfs_t", header: "lfs.h", incompleteStruct.} = object
  LfsFile* {.importc: "lfs_file_t", header: "lfs.h", incompleteStruct.} = object
  LfsDir* {.importc: "lfs_dir_t", header: "lfs.h", incompleteStruct.} = object

  LfsInfo* {.importc: "struct lfs_info", header: "lfs.h".} = object
    infoType* {.importc: "type".}: uint8
    size* {.importc: "size".}: uint32
    name* {.importc: "name".}: array[256, char]

# LfsConfig is already defined in flashblk.nim via importc

# =============================================================================
# Constants
# =============================================================================

const
  LFS_ERR_OK* = 0'i32
  LFS_ERR_IO* = -5'i32
  LFS_ERR_CORRUPT* = -84'i32
  LFS_ERR_NOENT* = -2'i32
  LFS_ERR_EXIST* = -17'i32
  LFS_ERR_NOTDIR* = -20'i32
  LFS_ERR_ISDIR* = -21'i32
  LFS_ERR_NOTEMPTY* = -39'i32
  LFS_ERR_NOSPC* = -28'i32

  LFS_O_RDONLY* = 1'i32
  LFS_O_WRONLY* = 2'i32
  LFS_O_RDWR* = 3'i32
  LFS_O_CREAT* = 0x0100'i32
  LFS_O_EXCL* = 0x0200'i32
  LFS_O_TRUNC* = 0x0400'i32
  LFS_O_APPEND* = 0x0800'i32

  LFS_TYPE_REG* = 0x001'u8
  LFS_TYPE_DIR* = 0x002'u8

  LFS_SEEK_SET* = 0'i32
  LFS_SEEK_CUR* = 1'i32
  LFS_SEEK_END* = 2'i32

# =============================================================================
# C function bindings
# =============================================================================

proc lfs_format*(lfs: ptr Lfs, config: ptr LfsConfig): cint
  {.importc, header: "lfs.h", cdecl.}

proc lfs_mount*(lfs: ptr Lfs, config: ptr LfsConfig): cint
  {.importc, header: "lfs.h", cdecl.}

proc lfs_unmount*(lfs: ptr Lfs): cint
  {.importc, header: "lfs.h", cdecl.}

proc lfs_file_open*(lfs: ptr Lfs, file: ptr LfsFile,
                    path: cstring, flags: cint): cint
  {.importc, header: "lfs.h", cdecl.}

proc lfs_file_close*(lfs: ptr Lfs, file: ptr LfsFile): cint
  {.importc, header: "lfs.h", cdecl.}

proc lfs_file_read*(lfs: ptr Lfs, file: ptr LfsFile,
                    buf: pointer, size: csize_t): cint
  {.importc, header: "lfs.h", cdecl.}

proc lfs_file_write*(lfs: ptr Lfs, file: ptr LfsFile,
                     buf: pointer, size: csize_t): cint
  {.importc, header: "lfs.h", cdecl.}

proc lfs_file_seek*(lfs: ptr Lfs, file: ptr LfsFile,
                    off: cint, whence: cint): cint
  {.importc, header: "lfs.h", cdecl.}

proc lfs_file_size*(lfs: ptr Lfs, file: ptr LfsFile): cint
  {.importc, header: "lfs.h", cdecl.}

proc lfs_file_sync*(lfs: ptr Lfs, file: ptr LfsFile): cint
  {.importc, header: "lfs.h", cdecl.}

proc lfs_mkdir*(lfs: ptr Lfs, path: cstring): cint
  {.importc, header: "lfs.h", cdecl.}

proc lfs_dir_open*(lfs: ptr Lfs, dir: ptr LfsDir, path: cstring): cint
  {.importc, header: "lfs.h", cdecl.}

proc lfs_dir_read*(lfs: ptr Lfs, dir: ptr LfsDir, info: ptr LfsInfo): cint
  {.importc, header: "lfs.h", cdecl.}

proc lfs_dir_close*(lfs: ptr Lfs, dir: ptr LfsDir): cint
  {.importc, header: "lfs.h", cdecl.}

proc lfs_remove*(lfs: ptr Lfs, path: cstring): cint
  {.importc, header: "lfs.h", cdecl.}

proc lfs_stat*(lfs: ptr Lfs, path: cstring, info: ptr LfsInfo): cint
  {.importc, header: "lfs.h", cdecl.}

proc lfs_rename*(lfs: ptr Lfs, oldpath, newpath: cstring): cint
  {.importc, header: "lfs.h", cdecl.}

# =============================================================================
# FlashFs — thin Nim wrapper
# =============================================================================

type
  FlashFs* = object
    lfs*: Lfs
    cfg: LfsConfig
    mounted*: bool

# Static buffers for LittleFS caches (avoids heap allocation)
var
  readBuf: array[FlashFsReadSize, uint8]
  progBuf: array[FlashFsProgSize, uint8]
  lookaheadBuf: array[64, uint8]  # 512-bit lookahead

proc initConfig(cfg: ptr LfsConfig) =
  ## Set up the LfsConfig with flash block device callbacks and geometry.
  let rb = addr readBuf[0]
  let pb = addr progBuf[0]
  let lb = addr lookaheadBuf[0]
  {.emit: """
  extern int blkRead(const struct lfs_config*, uint32_t, uint32_t, void*, uint32_t);
  extern int blkProg(const struct lfs_config*, uint32_t, uint32_t, const void*, uint32_t);
  extern int blkErase(const struct lfs_config*, uint32_t);
  extern int blkSync(const struct lfs_config*);
  memset(`cfg`, 0, sizeof(*`cfg`));
  `cfg`->read  = (int (*)(const struct lfs_config*, uint32_t, uint32_t, void*, uint32_t))blkRead;
  `cfg`->prog  = (int (*)(const struct lfs_config*, uint32_t, uint32_t, const void*, uint32_t))blkProg;
  `cfg`->erase = (int (*)(const struct lfs_config*, uint32_t))blkErase;
  `cfg`->sync  = (int (*)(const struct lfs_config*))blkSync;
  `cfg`->read_size      = `FlashFsReadSize`;
  `cfg`->prog_size      = `FlashFsProgSize`;
  `cfg`->block_size     = `FlashFsBlockSize`;
  `cfg`->block_count    = `FlashFsBlockCount`;
  `cfg`->cache_size     = `FlashFsReadSize`;
  `cfg`->lookahead_size = 64;
  `cfg`->block_cycles   = 500;
  `cfg`->read_buffer    = `rb`;
  `cfg`->prog_buffer    = `pb`;
  `cfg`->lookahead_buffer = `lb`;
  """.}

proc init*(fs: var FlashFs) =
  ## Mount the flash filesystem, formatting first if needed.
  initConfig(addr fs.cfg)
  let err = lfs_mount(addr fs.lfs, addr fs.cfg)
  if err == 0:
    fs.mounted = true
    return
  # Mount failed — format and retry
  let fmtErr = lfs_format(addr fs.lfs, addr fs.cfg)
  if fmtErr != 0:
    return  # format failed
  let err2 = lfs_mount(addr fs.lfs, addr fs.cfg)
  if err2 == 0:
    fs.mounted = true

proc deinit*(fs: var FlashFs) =
  if fs.mounted:
    discard lfs_unmount(addr fs.lfs)
    fs.mounted = false

proc open*(fs: var FlashFs, f: var LfsFile, path: string,
           flags: cint): cint =
  lfs_file_open(addr fs.lfs, addr f, path.cstring, flags)

proc close*(fs: var FlashFs, f: var LfsFile): cint =
  lfs_file_close(addr fs.lfs, addr f)

proc read*(fs: var FlashFs, f: var LfsFile,
           buf: var openArray[uint8]): int =
  lfs_file_read(addr fs.lfs, addr f, addr buf[0], buf.len.csize_t).int

proc write*(fs: var FlashFs, f: var LfsFile,
            data: openArray[uint8]): int =
  lfs_file_write(addr fs.lfs, addr f,
                 unsafeAddr data[0], data.len.csize_t).int

proc seek*(fs: var FlashFs, f: var LfsFile, off: int,
           whence: cint = LFS_SEEK_SET): int =
  lfs_file_seek(addr fs.lfs, addr f, off.cint, whence).int

proc size*(fs: var FlashFs, f: var LfsFile): int =
  lfs_file_size(addr fs.lfs, addr f).int

proc sync*(fs: var FlashFs, f: var LfsFile): cint =
  lfs_file_sync(addr fs.lfs, addr f)

proc remove*(fs: var FlashFs, path: string): cint =
  lfs_remove(addr fs.lfs, path.cstring)

proc mkdir*(fs: var FlashFs, path: string): cint =
  lfs_mkdir(addr fs.lfs, path.cstring)

proc stat*(fs: var FlashFs, path: string, info: var LfsInfo): cint =
  lfs_stat(addr fs.lfs, path.cstring, addr info)

proc rename*(fs: var FlashFs, oldpath, newpath: string): cint =
  lfs_rename(addr fs.lfs, oldpath.cstring, newpath.cstring)

proc ls*(fs: var FlashFs, path: string): seq[string] =
  ## List directory entries. Returns filenames (excludes "." and "..").
  var dir: LfsDir
  if lfs_dir_open(addr fs.lfs, addr dir, path.cstring) != 0:
    return @[]
  var info: LfsInfo
  while lfs_dir_read(addr fs.lfs, addr dir, addr info) > 0:
    let name = $cast[cstring](addr info.name[0])
    if name != "." and name != "..":
      result.add(name)
  discard lfs_dir_close(addr fs.lfs, addr dir)

proc infoName*(info: LfsInfo): string =
  ## Extract the filename from an LfsInfo.
  $cast[cstring](unsafeAddr info.name[0])
