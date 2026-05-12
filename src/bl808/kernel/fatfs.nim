## FatFs integration for the BL808 kernel.
##
## Provides a thin Nim wrapper over ChaN's FatFs library for
## FAT32 filesystem access on SD cards:
##
##   var fs: SdFs
##   fs.init()
##   var f: Fil
##   fs.open(f, "test.txt", faWrite or faCreateAlways)
##   fs.write(f, [0x48'u8, 0x69])  # "Hi"
##   fs.close(f)

import ./sdblk

# =============================================================================
# Compile FatFs
# =============================================================================

{.passC: "-I vendor/fatfs".}
{.compile: "vendor/fatfs/ff.c".}
{.compile: "vendor/fatfs/ffunicode.c".}

# =============================================================================
# C types
# =============================================================================

type
  FatFs* {.importc: "FATFS", header: "ff.h", incompleteStruct.} = object
  Fil* {.importc: "FIL", header: "ff.h", incompleteStruct.} = object
  Dir* {.importc: "DIR", header: "ff.h", incompleteStruct.} = object

  Filinfo* {.importc: "FILINFO", header: "ff.h".} = object
    fsize* {.importc: "fsize".}: uint32
    fdate* {.importc: "fdate".}: uint16
    ftime* {.importc: "ftime".}: uint16
    fattrib* {.importc: "fattrib".}: uint8
    fname* {.importc: "fname".}: array[13, char]  # 8.3 name

  FResult* {.importc: "FRESULT", header: "ff.h".} = enum
    frOk = 0
    frDiskErr = 1
    frIntErr = 2
    frNotReady = 3
    frNoFile = 4
    frNoPath = 5
    frInvalidName = 6
    frDenied = 7
    frExist = 8
    frInvalidObject = 9
    frWriteProtected = 10
    frInvalidDrive = 11
    frNotEnabled = 12
    frNoFilesystem = 13
    frMkfsAborted = 14
    frTimeout = 15
    frLocked = 16
    frNotEnoughCore = 17
    frTooManyOpenFiles = 18
    frInvalidParameter = 19

# =============================================================================
# File access flags
# =============================================================================

const
  faRead*         = 0x01'u8
  faWrite*        = 0x02'u8
  faOpenExisting* = 0x00'u8
  faCreateNew*    = 0x04'u8
  faCreateAlways* = 0x08'u8
  faOpenAlways*   = 0x10'u8
  faOpenAppend*   = 0x30'u8

# =============================================================================
# C function bindings
# =============================================================================

proc f_mount*(fs: ptr FatFs, path: cstring, opt: uint8): FResult
  {.importc, header: "ff.h", cdecl.}

proc f_mkfs*(path: cstring, opt: pointer, work: pointer,
             len: cuint): FResult
  {.importc, header: "ff.h", cdecl.}

proc f_open*(fp: ptr Fil, path: cstring, mode: uint8): FResult
  {.importc, header: "ff.h", cdecl.}

proc f_close*(fp: ptr Fil): FResult
  {.importc, header: "ff.h", cdecl.}

proc f_read*(fp: ptr Fil, buff: pointer, btr: cuint,
             br: ptr cuint): FResult
  {.importc, header: "ff.h", cdecl.}

proc f_write*(fp: ptr Fil, buff: pointer, btw: cuint,
              bw: ptr cuint): FResult
  {.importc, header: "ff.h", cdecl.}

proc f_lseek*(fp: ptr Fil, ofs: uint32): FResult
  {.importc, header: "ff.h", cdecl.}

proc f_sync*(fp: ptr Fil): FResult
  {.importc, header: "ff.h", cdecl.}

proc f_opendir*(dp: ptr Dir, path: cstring): FResult
  {.importc, header: "ff.h", cdecl.}

proc f_readdir*(dp: ptr Dir, fno: ptr Filinfo): FResult
  {.importc, header: "ff.h", cdecl.}

proc f_closedir*(dp: ptr Dir): FResult
  {.importc, header: "ff.h", cdecl.}

proc f_unlink*(path: cstring): FResult
  {.importc, header: "ff.h", cdecl.}

proc f_mkdir*(path: cstring): FResult
  {.importc, header: "ff.h", cdecl.}

proc f_rename*(oldpath, newpath: cstring): FResult
  {.importc, header: "ff.h", cdecl.}

proc f_stat*(path: cstring, fno: ptr Filinfo): FResult
  {.importc, header: "ff.h", cdecl.}

proc f_getfree*(path: cstring, nclst: ptr uint32,
                fatfs: ptr ptr FatFs): FResult
  {.importc, header: "ff.h", cdecl.}

# =============================================================================
# SdFs — thin Nim wrapper
# =============================================================================

type
  SdFs* = object
    fatfs*: FatFs
    mounted*: bool

# Work buffer for f_mkfs (needs >= sector size)
var mkfsWork: array[512, uint8]

proc init*(fs: var SdFs) =
  ## Mount the SD card filesystem, formatting FAT32 if needed.
  let err = f_mount(addr fs.fatfs, "0:", 1)
  if err == frOk:
    fs.mounted = true
    return
  # Mount failed — format and retry
  let fmtErr = f_mkfs("0:", nil, addr mkfsWork[0], mkfsWork.len.cuint)
  if fmtErr != frOk:
    return
  let err2 = f_mount(addr fs.fatfs, "0:", 1)
  if err2 == frOk:
    fs.mounted = true

proc deinit*(fs: var SdFs) =
  if fs.mounted:
    discard f_mount(nil, "0:", 0)
    fs.mounted = false

proc open*(fs: var SdFs, f: var Fil, path: string,
           mode: uint8): FResult =
  f_open(addr f, path.cstring, mode)

proc close*(fs: var SdFs, f: var Fil): FResult =
  f_close(addr f)

proc read*(fs: var SdFs, f: var Fil,
           buf: var openArray[uint8]): int =
  var br: cuint
  let err = f_read(addr f, addr buf[0], buf.len.cuint, addr br)
  if err != frOk: -1 else: br.int

proc write*(fs: var SdFs, f: var Fil,
            data: openArray[uint8]): int =
  var bw: cuint
  let err = f_write(addr f, unsafeAddr data[0], data.len.cuint, addr bw)
  if err != frOk: -1 else: bw.int

proc seek*(fs: var SdFs, f: var Fil, offset: uint32): FResult =
  f_lseek(addr f, offset)

proc sync*(fs: var SdFs, f: var Fil): FResult =
  f_sync(addr f)

proc f_size_helper(fp: ptr Fil): uint32 {.importc: "f_size", header: "ff.h".}

proc size*(f: var Fil): uint32 =
  f_size_helper(addr f)

proc remove*(fs: var SdFs, path: string): FResult =
  f_unlink(path.cstring)

proc mkdir*(fs: var SdFs, path: string): FResult =
  f_mkdir(path.cstring)

proc stat*(fs: var SdFs, path: string, info: var Filinfo): FResult =
  f_stat(path.cstring, addr info)

proc getFree*(fs: var SdFs, path: string, clusters: var uint32): FResult =
  var mounted: ptr FatFs
  f_getfree(path.cstring, addr clusters, addr mounted)

proc rename*(fs: var SdFs, oldpath, newpath: string): FResult =
  f_rename(oldpath.cstring, newpath.cstring)

proc ls*(fs: var SdFs, path: string): seq[string] =
  ## List directory entries. Returns filenames (excludes "." and "..").
  var dir: Dir
  if f_opendir(addr dir, path.cstring) != frOk:
    return @[]
  var info: Filinfo
  while f_readdir(addr dir, addr info) == frOk:
    if info.fname[0] == '\0': break  # End of directory
    let name = $cast[cstring](addr info.fname[0])
    if name != "." and name != "..":
      result.add(name)
  discard f_closedir(addr dir)

proc infoName*(info: Filinfo): string =
  $cast[cstring](unsafeAddr info.fname[0])
