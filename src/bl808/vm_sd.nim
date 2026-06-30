## SD/FatFs-backed virtual memory mappings for D0.
##
## This adapter lets the pager populate pages from an exFAT/FAT file on demand.
## It is synchronous by design; higher-level OS code can decide which files are
## safe to expose through demand paging and when to prefetch.

when not defined(bl808d0):
  {.error: "bl808/vm_sd is currently supported only on D0 (C906)".}

import ./vm
import ./mmu
import ./kernel/fatfs
import ./kernel/sd_swap_file

type
  D0VmSdFileMapping* = object
    file*: Fil
    open*: bool

  D0VmSdSwap* = object
    fs*: ptr SdFs
    swap*: SdSwapFile

proc sdFileReader(ctx: pointer, offset: uint64, dst: ptr UncheckedArray[byte],
                  len: uint): bool {.raises: [].} =
  if ctx == nil:
    return false
  let mapping = cast[ptr D0VmSdFileMapping](ctx)
  if not mapping.open:
    return false
  if f_lseek(addr mapping.file, offset) != frOk:
    return false
  var readBytes: cuint
  if f_read(addr mapping.file, dst, len.cuint, addr readBytes) != frOk:
    return false
  var i = readBytes.uint
  while i < len:
    dst[i.int] = 0
    inc i
  true

proc d0VmReserveSdFileBacked*(fs: var SdFs, mapping: var D0VmSdFileMapping,
                              path: string, virtualBase, length: uint,
                              sourceOffset: uint64 = 0,
                              flags: uint64 = PteKernelPage): D0VmStatus =
  if not fs.mounted:
    return d0VmReaderFailed
  let opened = fs.open(mapping.file, path, faRead)
  if opened != frOk:
    mapping.open = false
    return d0VmReaderFailed
  mapping.open = true
  let status = d0VmReserveReaderBacked(virtualBase, length, sdFileReader,
                                      addr mapping, sourceOffset, flags)
  if status != d0VmOk:
    discard fs.close(mapping.file)
    mapping.open = false
  status

proc d0VmCloseSdFileBacked*(fs: var SdFs, mapping: var D0VmSdFileMapping): FResult =
  if mapping.open:
    result = fs.close(mapping.file)
    mapping.open = false
  else:
    result = frOk

proc sdVmSwapRead(ctx: pointer, slot: uint32,
                  dst: ptr UncheckedArray[byte]): bool {.raises: [].} =
  if ctx == nil:
    return false
  let swap = cast[ptr D0VmSdSwap](ctx)
  if swap.fs == nil:
    return false
  sdSwapReadPage(swap.fs[], swap.swap, slot, dst) == sdSwapOk

proc sdVmSwapWrite(ctx: pointer, slot: uint32,
                   src: ptr UncheckedArray[byte]): bool {.raises: [].} =
  if ctx == nil:
    return false
  let swap = cast[ptr D0VmSdSwap](ctx)
  if swap.fs == nil:
    return false
  sdSwapWritePage(swap.fs[], swap.swap, slot, src) == sdSwapOk

proc d0VmUseSdSwapFile*(fs: var SdFs, swap: var D0VmSdSwap, path: string,
                        slots: uint32): D0VmStatus =
  ## Configure VM swap using a dedicated FatFs file.
  ##
  ## The card must already be mounted with `mount`, not `init`; this avoids
  ## formatting existing card contents on mount failure.
  let status = sdSwapOpenOrCreate(fs, swap.swap, path, slots)
  if status != sdSwapOk:
    return d0VmSwapUnavailable
  swap.fs = addr fs
  d0VmSetSwapProvider(D0VmSwapProvider(
    ctx: addr swap,
    slots: swap.swap.slots,
    readPage: sdVmSwapRead,
    writePage: sdVmSwapWrite,
  ))
  d0VmOk

proc d0VmCloseSdSwapFile*(swap: var D0VmSdSwap): SdSwapStatus =
  if swap.fs == nil:
    return sdSwapOk
  result = sdSwapClose(swap.fs[], swap.swap)
  swap.fs = nil
