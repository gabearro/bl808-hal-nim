## Allocation, clock, ISR notify, and timeout adapter callbacks.

proc osMalloc(size: cuint): pointer {.cdecl.} =
  result = c_malloc(size.csize_t)
  if result == nil:
    vendorPutsRaw("[WIFI] malloc fail size=")
    vendorPrintU32(size.uint32, 10)
    vendorPutsRaw(" used=")
    vendorPrintU32(tlsf_get_used().uint32, 10)
    vendorPutsRaw(" total=")
    vendorPrintU32(tlsf_get_total().uint32, 10)
    vendorPutsRaw(" largest=")
    vendorPrintU32(tlsf_get_largest_free().uint32, 10)
    vendorPutsRaw(" fails=")
    vendorPrintU32(tlsf_get_alloc_fail_count().uint32, 10)
    vendorPutsRaw("\r\n")
proc osFree(p: pointer) {.cdecl.} = c_free(p)
proc osZalloc(size: cuint): pointer {.cdecl.} = c_calloc(1, size.csize_t)
proc osGetTimeMs(): uint64 {.cdecl.} = readMtimeUs() div 1000'u64
proc osGetTick(): uint32 {.cdecl.} = osGetTimeMs().uint32
proc osLogWrite(level: uint32; tag, file: cstring; line: cint; fmt: cstring)
    {.importc: "bl808_nim_os_log_write", cdecl, varargs.}
proc osTaskNotifyIsr(taskHandle: pointer): cint {.cdecl.} =
  discard taskHandle
  0
proc osYieldFromIsr(xYield: cint) {.cdecl.} = discard xYield
proc osMsToTick(ms: cuint): cuint {.cdecl.} = ms
proc osSetTimeout(): pointer {.cdecl.} = cast[pointer](osGetTick().uint)
proc osCheckTimeout(timeout: pointer; ticksToWait: ptr uint32): cint {.cdecl.} =
  discard timeout
  if ticksToWait != nil and ticksToWait[] != 0:
    dec ticksToWait[]
    return 0
  1
