## Async file I/O wrappers for the BL808 kernel.
##
## Post-deferred execution: each operation posts blocking FS work to the
## scheduler's ready queue and returns a CpsFuture. Between await points,
## other CPS tasks can run (shell, networking, watchdog).
##
##   let written = await asyncFlashWrite(addr fs, addr f, addr data[0], data.len)
##   let bytesRead = await asyncFlashRead(addr fs, addr f, addr buf[0], buf.len)

import ./runtime, ./sched
import ./littlefs, ./fatfs

# =============================================================================
# Flash FS (LittleFS) async wrappers
# =============================================================================

proc asyncFlashOpen*(fs: ptr FlashFs, f: ptr LfsFile,
                     path: string, flags: cint): CpsFuture[cint] =
  let fut = newLocalCpsFuture[cint]()
  post(proc() =
    let err = fs[].open(f[], path, flags)
    complete(fut, err)
  )
  fut

proc asyncFlashClose*(fs: ptr FlashFs, f: ptr LfsFile): CpsFuture[cint] =
  let fut = newLocalCpsFuture[cint]()
  post(proc() =
    let err = fs[].close(f[])
    complete(fut, err)
  )
  fut

proc asyncFlashWrite*(fs: ptr FlashFs, f: ptr LfsFile,
                      data: ptr UncheckedArray[uint8],
                      len: int): CpsFuture[int] =
  let fut = newLocalCpsFuture[int]()
  post(proc() =
    let written = fs[].write(f[], data.toOpenArray(0, len - 1))
    complete(fut, written)
  )
  fut

proc asyncFlashRead*(fs: ptr FlashFs, f: ptr LfsFile,
                     buf: ptr UncheckedArray[uint8],
                     len: int): CpsFuture[int] =
  let fut = newLocalCpsFuture[int]()
  post(proc() =
    let bytesRead = fs[].read(f[], buf.toOpenArray(0, len - 1))
    complete(fut, bytesRead)
  )
  fut

proc asyncFlashRemove*(fs: ptr FlashFs, path: string): CpsFuture[cint] =
  let fut = newLocalCpsFuture[cint]()
  post(proc() =
    let err = fs[].remove(path)
    complete(fut, err)
  )
  fut

# =============================================================================
# SD FS (FatFs) async wrappers
# =============================================================================

proc asyncSdOpen*(fs: ptr SdFs, f: ptr Fil,
                  path: string, mode: uint8): CpsFuture[FResult] =
  let fut = newLocalCpsFuture[FResult]()
  post(proc() =
    let err = fs[].open(f[], path, mode)
    complete(fut, err)
  )
  fut

proc asyncSdClose*(fs: ptr SdFs, f: ptr Fil): CpsFuture[FResult] =
  let fut = newLocalCpsFuture[FResult]()
  post(proc() =
    let err = fs[].close(f[])
    complete(fut, err)
  )
  fut

proc asyncSdWrite*(fs: ptr SdFs, f: ptr Fil,
                   data: ptr UncheckedArray[uint8],
                   len: int): CpsFuture[int] =
  let fut = newLocalCpsFuture[int]()
  post(proc() =
    let written = fs[].write(f[], data.toOpenArray(0, len - 1))
    complete(fut, written)
  )
  fut

proc asyncSdRead*(fs: ptr SdFs, f: ptr Fil,
                  buf: ptr UncheckedArray[uint8],
                  len: int): CpsFuture[int] =
  let fut = newLocalCpsFuture[int]()
  post(proc() =
    let bytesRead = fs[].read(f[], buf.toOpenArray(0, len - 1))
    complete(fut, bytesRead)
  )
  fut

proc asyncSdRemove*(fs: ptr SdFs, path: string): CpsFuture[FResult] =
  let fut = newLocalCpsFuture[FResult]()
  post(proc() =
    let err = fs[].remove(path)
    complete(fut, err)
  )
  fut
